import Foundation

/// What happens once a meeting's transcript is in its note: Claude names and files it (title, tags, client links,
/// one-line summary, a series *suggestion*), the note is renamed to the title, then Claude's expansion streams into
/// the Expanded section. My notes is never written. Each step is saved before the next starts, so a failure keeps
/// what came before; failures are recorded in `meeting.json` (`insightsError`, `expandError`) for the UI's Retry.
public struct AfterMeeting: Sendable {
    private static let recentTitlesPerSeries = 5

    private let index: NoteIndex
    private let claude: any ClaudeRunning
    private let expander: Expander
    private let vaultRoot: URL
    private let saveInterval: Duration

    /// `saveInterval` is how often the streaming expansion is written to the note (and once more at the end).
    public init(index: NoteIndex, claude: any ClaudeRunning, expander: Expander, vaultRoot: URL,
                saveInterval: Duration = .seconds(1)) {
        self.index = index; self.claude = claude; self.expander = expander
        self.vaultRoot = vaultRoot; self.saveInterval = saveInterval
    }

    /// Safe to run again (Retry): insights run only until they first succeed, and an Expanded section that already
    /// has text is left alone (Re-expand is a separate action). `onExpansion` gets the whole Expanded list as it grows.
    public func run(folder: URL, onExpansion: @Sendable ([NoteBlock]) async -> Void = { _ in }) async throws {
        var meeting = try Meeting.load(from: folder)
        let lines = try JSONDecoder().decode([TranscriptLine].self, from: Data(contentsOf: folder.appendingPathComponent("transcript.json")))
        var note: LoadedNote
        do { note = try index.load(meeting.id, hint: meeting.notePath.map { URL(fileURLWithPath: $0) }) } catch {
            meeting.expandError = error.localizedDescription
            try meeting.save(in: folder)
            throw error
        }

        if note.document.front.summary == nil {
            note = try await fileMeeting(&meeting, note: note, lines: lines, folder: folder)
        }
        guard note.document.expanded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        do {
            let final = try await expand(note, lines: lines, onExpansion: onExpansion)
            meeting.expandedHashes = ExpandedMerge.hashes(of: final)
            meeting.expandError = nil
            try meeting.save(in: folder)
        } catch {
            meeting.expandError = error.localizedDescription
            try meeting.save(in: folder)
            throw error
        }
    }

    // MARK: Title, tags, links, series

    /// Insights into the frontmatter, then the file renamed to the new title. A failure is recorded and the
    /// note keeps the window title, so expansion can still go ahead.
    private func fileMeeting(_ meeting: inout Meeting, note: LoadedNote, lines: [TranscriptLine], folder: URL) async throws -> LoadedNote {
        let notes = index.allNotes()
        let summaries = SeriesLibrary.summaries(notes: notes, meetingsByID: [:], notesRoot: index.notesRoot)
        let input = InsightsInput(
            windowTitle: note.document.front.title, screenText: meeting.screenText ?? [], transcript: lines,
            myNotes: note.document.myNotes,
            existingSeries: SeriesLibrary.groups(summaries).reduce(into: [:]) { $0[$1.name] = $1.meetings.prefix(Self.recentTitlesPerSeries).map(\.title) },
            knownTags: InsightsService.knownTags(in: notes), clients: InsightsService.clients(inVault: vaultRoot),
            people: Self.namedSpeakers(lines))
        let insights: MeetingInsights
        do { insights = try await InsightsService.run(input, claude: claude) } catch {
            meeting.insightsError = error.localizedDescription
            try meeting.save(in: folder)
            return note
        }

        var saved = try index.update(note) { doc in
            doc.front.title = insights.title
            doc.front.tags = Self.union(doc.front.tags, insights.tags)
            doc.front.links = Self.union(doc.front.links, insights.clients)
            if !insights.summary.isEmpty { doc.front.summary = insights.summary }
        }
        meeting.seriesSuggestion = insights.series
        meeting.insightsError = nil
        // The series it is already in (a folder Aidan moved it to counts), so the rename never pulls it out.
        let series = SeriesLibrary.summaries(notes: [saved], meetingsByID: [:], notesRoot: index.notesRoot).first?.series
        let moved = try index.relocateReportingSkips(saved, title: saved.document.front.title, series: series)
        saved = moved.note
        if !moved.skippedLinkFiles.isEmpty {
            meeting.warn("Lyra renamed the note but couldn't update links to it in: "
                         + moved.skippedLinkFiles.map(\.lastPathComponent).joined(separator: ", "))
        }
        meeting.notePath = saved.url.path
        try meeting.save(in: folder)
        return saved
    }

    // MARK: Expansion

    /// Streams the expansion into the note, at most once per `saveInterval` and at the end. On failure the
    /// Expanded section goes back to what it was, so no half-written grey is left behind.
    private func expand(_ note: LoadedNote, lines: [TranscriptLine], onExpansion: @Sendable ([NoteBlock]) async -> Void) async throws -> [NoteBlock] {
        let ctx = MeetingContext(title: note.document.front.title, myNotes: NoteMarkdown.parse(note.document.myNotes),
                                 transcript: lines, earlier: earlierMeetings(than: note))
        let original = note.document.expanded
        var current = note
        var latest: [NoteBlock] = []
        var lastSave = ContinuousClock.now
        do {
            for try await blocks in expander.expandAll(ctx) {
                latest = blocks
                await onExpansion(blocks)
                if ContinuousClock.now - lastSave >= saveInterval {
                    current = try writeExpanded(NoteMarkdown.render(blocks), over: current)
                    lastSave = .now
                }
            }
            _ = try writeExpanded(NoteMarkdown.render(latest), over: current)
            return latest
        } catch {
            if current.document.expanded != original { try? restoreExpanded(original, over: current) }
            throw error
        }
    }

    private func writeExpanded(_ text: String, over note: LoadedNote) throws -> LoadedNote {
        try index.update(note) { $0.expanded = text }
    }

    /// Puts back the section as it was before expanding, unless someone has edited it since Lyra last wrote it.
    private func restoreExpanded(_ original: String, over note: LoadedNote) throws {
        let onDisk = try index.load(note.document.front.lyraID, hint: note.url)
        guard onDisk.document.expanded == note.document.expanded else { return }
        _ = try writeExpanded(original, over: onDisk)
    }

    /// Earlier meetings in this note's confirmed series (none while the series is only a suggestion), as context.
    private func earlierMeetings(than note: LoadedNote) -> [EarlierMeeting] {
        let notes = index.allNotes()
        let summaries = SeriesLibrary.summaries(notes: notes, meetingsByID: [:], notesRoot: index.notesRoot)
        let id = note.document.front.lyraID
        guard let series = summaries.first(where: { $0.id == id })?.series else { return [] }
        let byID = Dictionary(notes.map { ($0.document.front.lyraID, $0) }, uniquingKeysWith: { first, _ in first })
        return summaries
            .filter { $0.series == series && $0.id != id && $0.date < note.document.front.date }
            .compactMap { summary in
                byID[summary.id].map { EarlierMeeting(title: summary.title, date: summary.date,
                                                      expanded: $0.document.expanded, transcript: $0.document.transcript) }
            }
    }

    // MARK: Helpers

    /// Speakers with a real name (not Lyra's "Speaker N" placeholder), in order of first appearance.
    private static func namedSpeakers(_ lines: [TranscriptLine]) -> [String] {
        union([], lines.map(\.speakerLabel).filter { $0.range(of: #"^Speaker \d+$"#, options: .regularExpression) == nil })
    }

    private static func union(_ a: [String], _ b: [String]) -> [String] {
        b.reduce(into: a) { if !$0.contains($1) { $0.append($1) } }
    }
}

extension NoteIndex {
    static let saveAttempts = 3

    /// Applies `change` to the note as it is on disk and saves it. If the file changes in between (Aidan typing in
    /// Obsidian or in Lyra), reloads and applies `change` again, so only the parts `change` touches are Lyra's.
    func update(_ loaded: LoadedNote, _ change: (inout NoteDocument) -> Void) throws -> LoadedNote {
        var current = loaded
        for attempt in 1...Self.saveAttempts {
            var document = current.document
            change(&document)
            if document == current.document { return current }
            do { return try save(document, over: current) } catch NoteIndexError.changedOnDisk(let url) where attempt < Self.saveAttempts {
                current = try load(current.document.front.lyraID, hint: url)
            }
        }
        preconditionFailure("the last attempt returns or throws")
    }
}
