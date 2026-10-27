import Foundation

/// What happens once a meeting's transcript is in its note: Claude names and files it (title, tags, client links,
/// one-line summary, a series *suggestion*), the note is renamed to the title, then Claude's expansion streams into
/// the Expanded section. My notes is never written. Each step is saved before the next starts, so a failure keeps
/// what came before; failures are recorded in `meeting.json` (`insightsError`, `expandError`) for the UI's Retry.
///
/// Renames run alongside this (from the meeting window), so every `meeting.json` write re-reads the file and
/// changes only this step's own fields, and the transcript is read again just before expanding.
public struct AfterMeeting: Sendable {
    /// Saved as `expandError` while the expansion streams: if Lyra quits, the meeting shows Retry.
    public static let unfinishedMessage = "Lyra stopped before finishing these notes."
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

    /// Safe to run again (Retry): insights run only until they first succeed, and Expanded is only written when it
    /// is empty or still exactly Lyra's unfinished stream (Re-expand is a separate action). Any failure is recorded
    /// as `expandError` before it is rethrown. `onExpansion` gets the whole Expanded list as it grows.
    public func run(folder: URL, onExpansion: @Sendable ([NoteBlock]) async -> Void = { _ in }) async throws {
        do {
            try await steps(folder: folder, onExpansion: onExpansion)
        } catch {
            try? Self.updateMeeting(in: folder) { $0.expandError = Self.plainEnglish(error) }
            throw error
        }
    }

    /// Recordings folders whose after-meeting step never finished (Lyra quit before or while it ran) and never
    /// failed: processed (`transcript.json`), with a Phase 3 note (`notePath`), and no outcome recorded.
    public static func pendingFolders(in root: URL) -> [URL] {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.filter { folder in
            guard fm.fileExists(atPath: folder.appendingPathComponent("transcript.json").path),
                  let meeting = try? Meeting.load(from: folder) else { return false }
            return meeting.notePath != nil && meeting.afterMeetingDone != true
                && meeting.expandError == nil && meeting.expandedHashes == nil
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func steps(folder: URL, onExpansion: @Sendable ([NoteBlock]) async -> Void) async throws {
        let meeting = try Meeting.load(from: folder)
        var note = try index.load(meeting.id, hint: meeting.notePath.map { URL(fileURLWithPath: $0) })
        if meeting.insightsDone != true {
            note = try await fileMeeting(meeting, note: note, lines: Self.transcript(in: folder), folder: folder)
        }

        let current = try Meeting.load(from: folder)
        guard Self.mayWriteExpanded(note.document, meeting: current) else {
            // Aidan's own Expanded text (or Lyra's, edited since): nothing to do here; Re-expand is for that.
            try Self.updateMeeting(in: folder) { $0.expandError = nil; $0.afterMeetingDone = true }
            return
        }
        let previousHashes = current.expandedHashes
        try Self.updateMeeting(in: folder) { $0.expandError = Self.unfinishedMessage }
        do {
            let final = try await expand(note, lines: Self.transcript(in: folder), folder: folder, onExpansion: onExpansion)
            try Self.updateMeeting(in: folder) {
                $0.expandedHashes = ExpandedMerge.hashes(of: final)
                $0.expandError = nil
                $0.afterMeetingDone = true
            }
        } catch {
            try? Self.updateMeeting(in: folder) { $0.expandedHashes = previousHashes }
            throw error
        }
    }

    // MARK: Title, tags, links, series

    /// Insights into the frontmatter, then the file renamed to the new title. A Claude failure is recorded and the
    /// note keeps the window title, so expansion can still go ahead; a file failure ends the run.
    private func fileMeeting(_ meeting: Meeting, note: LoadedNote, lines: [TranscriptLine], folder: URL) async throws -> LoadedNote {
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
            try Self.updateMeeting(in: folder) { $0.insightsError = error.localizedDescription }
            return note
        }

        let saved = try index.update(note) { doc in
            doc.front.title = insights.title
            doc.front.tags = Self.union(doc.front.tags, insights.tags)
            doc.front.links = Self.union(doc.front.links, insights.clients)
            if !insights.summary.isEmpty { doc.front.summary = insights.summary }
        }
        // The series it is already in (a folder Aidan moved it to counts), so the rename never pulls it out.
        let series = SeriesLibrary.summaries(notes: [saved], meetingsByID: [:], notesRoot: index.notesRoot).first?.series
        let moved = try index.relocateReportingSkips(saved, title: saved.document.front.title, series: series)
        try Self.updateMeeting(in: folder) {
            $0.seriesSuggestion = insights.series
            $0.insightsError = nil
            $0.insightsDone = true
            $0.notePath = moved.note.url.path
            if !moved.skippedLinkFiles.isEmpty {
                $0.warn("Lyra renamed the note but couldn't update links to it in: "
                        + moved.skippedLinkFiles.map(\.lastPathComponent).joined(separator: ", "))
            }
        }
        return moved.note
    }

    // MARK: Expansion

    /// Streams the expansion into the note, at most once per `saveInterval` and at the end. The grey written so far
    /// is recorded (before the note is written) so Retry can tell an unfinished stream from edited text. On failure
    /// the Expanded section goes back to what it was, so no half-written grey is left behind.
    private func expand(_ note: LoadedNote, lines: [TranscriptLine], folder: URL,
                        onExpansion: @Sendable ([NoteBlock]) async -> Void) async throws -> [NoteBlock] {
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
                    current = try writeExpanded(blocks, over: current, folder: folder)
                    lastSave = .now
                }
            }
            _ = try writeExpanded(latest, over: current, folder: folder)
            return latest
        } catch {
            if current.document.expanded != original { try? restoreExpanded(original, lastWritten: current) }
            throw error
        }
    }

    private func writeExpanded(_ blocks: [NoteBlock], over note: LoadedNote, folder: URL) throws -> LoadedNote {
        try Self.updateMeeting(in: folder) { $0.expandedHashes = Self.union($0.expandedHashes ?? [], ExpandedMerge.hashes(of: blocks)) }
        let text = NoteMarkdown.render(blocks)
        return try index.update(note) { $0.expanded = text }
    }

    /// Puts back the section as it was before expanding, unless it changed since Lyra last wrote it. The check is
    /// made on the note as freshly read inside the save, so an edit landing meanwhile is never overwritten.
    private func restoreExpanded(_ original: String, lastWritten: LoadedNote) throws {
        let written = lastWritten.document.expanded
        let onDisk = try index.load(lastWritten.document.front.lyraID, hint: lastWritten.url)
        _ = try index.update(onDisk) { doc in
            if doc.expanded == written { doc.expanded = original }
        }
    }

    /// Expanded may be (re)written when it is empty, or when it is Lyra's unfinished stream untouched: every grey
    /// block is one Lyra recorded writing, and every white block is one of Aidan's My notes points carried over.
    static func mayWriteExpanded(_ doc: NoteDocument, meeting: Meeting) -> Bool {
        if doc.expanded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        guard meeting.expandError == unfinishedMessage else { return false }
        let blocks = NoteMarkdown.parse(doc.expanded)
        let lyraWrote = Set(meeting.expandedHashes ?? [])
        let greyUntouched = ExpandedMerge.hashes(of: blocks).allSatisfy(lyraWrote.contains)
        let mine = Set(NoteMarkdown.parse(doc.myNotes).map { NoteMarkdown.render([$0]) })
        let whiteFromMyNotes = blocks.filter { !$0.byClaude }.allSatisfy { mine.contains(NoteMarkdown.render([$0])) }
        return greyUntouched && whiteFromMyNotes
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

    // MARK: Files

    /// Re-reads meeting.json and applies only `change`, so fields written meanwhile (a rename's hash) survive.
    static func updateMeeting(in folder: URL, _ change: (inout Meeting) -> Void) throws {
        var meeting = try Meeting.load(from: folder)
        change(&meeting)
        try meeting.save(in: folder)
    }

    private static func transcript(in folder: URL) throws -> [TranscriptLine] {
        try JSONDecoder().decode([TranscriptLine].self, from: Data(contentsOf: folder.appendingPathComponent("transcript.json")))
    }

    /// Lyra's own errors already read as plain English; anything else (a decode or file error) is wrapped.
    private static func plainEnglish(_ error: Error) -> String {
        if error is ClaudeError || error is InsightsError || error is NoteIndexError || error is NoteDocumentError {
            return error.localizedDescription
        }
        return "Lyra couldn't read or save this meeting's files. (\(error.localizedDescription))"
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
