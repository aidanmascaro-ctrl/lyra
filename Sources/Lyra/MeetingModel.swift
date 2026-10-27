import AppKit
import LyraCore
import SwiftUI

enum MeetingTab: Hashable { case myNotes, expanded, transcript }

/// The note changed in Obsidian while Aidan had edits in Lyra that weren't saved yet.
struct NoteConflict {
    let section: NoteSection
    var mine: [NoteBlock]
    var disk: LoadedNote
}

/// One meeting window's state: the note (found by `lyra_id`, watched on disk), the two editable sections, the
/// transcript with Phase 2's speaker renaming, and Claude's in-window actions (in `MeetingModel+Claude`).
///
/// The editors get back exactly the blocks they sent out, so their undo history survives; new blocks are pushed
/// only for real outside changes: the file changed on disk, Claude added something.
@MainActor
final class MeetingModel: ObservableObject {
    /// How long a pushed outside change waits for an editor's unsent edits before it counts as accepted.
    private static let unsentGrace: Duration = .milliseconds(300)

    let folder: URL
    let notes: NoteIndex
    let app: AppModel
    private let service: RenameService
    /// meeting.json as last read; Retry clears its errors here at once, before Claude starts.
    @Published var meeting: Meeting?
    @Published private(set) var loaded: LoadedNote?
    @Published private(set) var lines: [TranscriptLine] = []
    @Published private(set) var loadError: String?
    @Published var myBlocks: [NoteBlock] = []
    @Published var expandedBlocks: [NoteBlock] = []
    @Published var tab: MeetingTab
    @Published var titleDraft = ""
    @Published private(set) var conflict: NoteConflict?
    /// Plain-English problems (a save, a series move); shown in a banner until dismissed.
    @Published var notice: String?
    @Published private(set) var knownSeries: [String] = []
    // Claude
    @Published var working: String?
    @Published var claudeError: String?
    @Published var answer: (question: String, text: String)?
    @Published var inlineAsk: (selection: String, block: Int)?
    @Published var highlighted: [Int] = []
    // Speaker renaming (Phase 2)
    @Published private(set) var renaming = false
    @Published private(set) var renameMessage: String?
    @Published var askToReplace = false
    private var confirmAfterMessage = false

    private var watcher: NoteWatcher?
    /// An outside change pushed to the editors, not yet accepted: unsent edits arriving now are a conflict.
    private var pendingExternal: (disk: LoadedNote, changed: [NoteSection])?

    init(folder: URL, app: AppModel) {
        self.folder = folder
        self.app = app
        notes = app.notes
        service = RenameService(people: app.people)
        tab = .expanded
        reload()
        // Live: ready to type. Nothing written yet (a Phase 2 meeting): the transcript is all there is.
        if app.liveMeeting?.folder == folder { tab = .myNotes }
        else if expandedBlocks.isEmpty && myBlocks.isEmpty { tab = .transcript }
        loadSeriesNames()
    }

    var isLive: Bool { app.liveMeeting?.folder == folder }
    var streaming: [NoteBlock]? { meeting.flatMap { app.liveExpansion[$0.id] } }
    var speakers: [SpeakerSummary] { MeetingOverview.speakers(in: lines) }
    var series: String? { loaded.flatMap { SeriesActions.currentSeries(of: $0, index: notes) } }
    var suggestion: String? {
        guard series == nil, meeting?.seriesRejected != true else { return nil }
        return meeting?.seriesSuggestion
    }
    var newNotesCount: Int {
        guard !expandedBlocks.isEmpty, streaming == nil else { return 0 }
        return ExpandedMerge.newNotes(myNotes: myBlocks, expanded: expandedBlocks).count
    }
    var expandFailure: String? {
        guard streaming == nil, let meeting else { return nil }
        return meeting.expandError ?? meeting.insightsError
    }

    // MARK: Loading and watching

    /// Re-reads meeting.json and the transcript; the note goes through the outside-change path.
    func reload() {
        do {
            let meeting = try Meeting.load(from: folder)
            self.meeting = meeting
            let transcript = folder.appendingPathComponent("transcript.json")
            // No transcript yet while recording: that's not an error.
            lines = FileManager.default.fileExists(atPath: transcript.path)
                ? try JSONDecoder().decode([TranscriptLine].self, from: Data(contentsOf: transcript)) : []
            loadError = nil
        } catch {
            loadError = "Couldn't read this meeting: \(error.localizedDescription)"
            return
        }
        noteChangedOnDisk()
    }

    func noteChangedOnDisk() {
        // The after-meeting step writes meeting.json alongside the note (errors, series suggestion).
        if let fresh = try? Meeting.load(from: folder) { meeting = fresh }
        guard let meeting else { return }
        let hint = loaded?.url ?? (try? RenameService.noteURL(inMeetingFolder: folder, index: notes))
        let disk: LoadedNote
        do { disk = try notes.load(meeting.id, hint: hint) } catch {
            loadError = "Couldn't open this meeting's note: \(error.localizedDescription)"
            return
        }
        loadError = nil
        watch(disk.url)
        guard let loaded else { return adopt(disk) }
        guard disk.fingerprint != loaded.fingerprint else { return }  // Lyra's own save
        let changed = [NoteSection.myNotes, .expanded].filter { $0.text(in: disk.document) != $0.text(in: loaded.document) }
        if titleDraft == loaded.document.front.title { titleDraft = disk.document.front.title }
        if conflict != nil { conflict?.disk = disk; self.loaded = disk; return }
        guard !changed.isEmpty else { self.loaded = disk; return }
        pendingExternal = (disk, changed)
        for section in changed { push(NoteMarkdown.parse(section.text(in: disk.document)), to: section) }
        Task {
            try? await Task.sleep(for: Self.unsentGrace)
            guard pendingExternal?.disk.fingerprint == disk.fingerprint else { return }
            pendingExternal = nil
            self.loaded = disk
        }
    }

    private func adopt(_ note: LoadedNote) {
        loaded = note
        titleDraft = note.document.front.title
        myBlocks = NoteMarkdown.parse(note.document.myNotes)
        expandedBlocks = NoteMarkdown.parse(note.document.expanded)
    }

    private func watch(_ url: URL) {
        if let watcher { return watcher.watch(url) }
        watcher = NoteWatcher(url: url) { [weak self] in
            MainActor.assumeIsolated { self?.noteChangedOnDisk() }
        }
    }

    func close() { watcher?.stop() }

    private func push(_ blocks: [NoteBlock], to section: NoteSection) {
        switch section {
        case .myNotes: myBlocks = blocks
        case .expanded: expandedBlocks = blocks
        }
    }

    // MARK: Saving

    /// An editor's debounced change. Saved straight away unless it collides with an edit made in Obsidian.
    func edited(_ blocks: [NoteBlock], in section: NoteSection) {
        push(blocks, to: section)
        if let pending = pendingExternal, pending.changed.contains(section) {
            pendingExternal = nil
            loaded = pending.disk
            conflict = NoteConflict(section: section, mine: blocks, disk: pending.disk)
            return
        }
        if conflict?.section == section { conflict?.mine = blocks; return }
        save(blocks, to: section)
    }

    func save(_ blocks: [NoteBlock], to section: NoteSection) {
        guard let loaded else { return }
        do {
            switch try NoteEdits.save(blocks, to: section, over: loaded, index: notes) {
            case .saved(let note): self.loaded = note; watch(note.url)
            case .conflict(let disk): conflict = NoteConflict(section: section, mine: blocks, disk: disk)
            }
        } catch { notice = "Lyra couldn't save this note: \(error.localizedDescription)" }
    }

    /// "Reload": Obsidian's version wins.
    func takeDisk() {
        guard let conflict else { return }
        self.conflict = nil
        loaded = conflict.disk
        push(NoteMarkdown.parse(conflict.section.text(in: conflict.disk.document)), to: conflict.section)
    }

    /// "Keep mine": this section is written over Obsidian's, as the file is right now.
    func keepMine() {
        guard let conflict, let meeting else { return }
        self.conflict = nil
        do {
            let disk = try notes.load(meeting.id, hint: conflict.disk.url)
            loaded = try NoteEdits.keepMine(conflict.mine, section: conflict.section, over: disk, index: notes)
        } catch { notice = "Lyra couldn't save your version: \(error.localizedDescription)" }
    }

    // MARK: Title and series

    func commitTitle() {
        guard let loaded, titleDraft != loaded.document.front.title else { return }
        apply { try SeriesActions.retitle(loaded, to: titleDraft, index: notes) }
        titleDraft = self.loaded?.document.front.title ?? titleDraft
    }

    func move(to series: String?) {
        guard let loaded else { return }
        apply { try SeriesActions.move(loaded, to: series, index: notes) }
        loadSeriesNames()
    }

    func notRelated() {
        do { try SeriesActions.reject(meetingFolder: folder) } catch {
            notice = "Lyra couldn't save that: \(error.localizedDescription)"
        }
        reload()
    }

    private func apply(_ change: () throws -> SeriesOutcome) {
        do {
            let outcome = try change()
            loaded = outcome.note
            watch(outcome.note.url)
            if !outcome.problems.isEmpty { notice = outcome.problems.joined(separator: "\n") }
        } catch { notice = error.localizedDescription }
    }

    private func loadSeriesNames() {
        let notes = notes
        Task {
            let names = await Task.detached {
                SeriesLibrary.groups(SeriesLibrary.summaries(notes: notes.allNotes(), meetingsByID: [:], notesRoot: notes.notesRoot)).map(\.name)
            }.value
            knownSeries = names.sorted()
        }
    }

    // MARK: Speaker renaming (Phase 2)

    func rename(_ label: String, to name: String) {
        renaming = true
        let (service, folder, notes) = (service, folder, notes)
        Task {
            let result = await Task.detached { () -> Result<RenameOutcome, Error> in
                do { return .success(try service.rename(speakerLabel: label, to: name, inMeetingFolder: folder, index: notes)) }
                catch { return .failure(error) }
            }.value
            renaming = false
            switch result {
            case .success(let outcome): if outcome == .needsConfirmation { askToReplace = true }
            case .failure(RenameError.notLearned(let outcome, let underlying)):
                renameMessage = RenameError.notLearned(outcome: outcome, underlying: underlying).localizedDescription
                confirmAfterMessage = outcome == .needsConfirmation
            case .failure(let error): renameMessage = error.localizedDescription
            }
            reload()
        }
    }

    func dismissRenameMessage() {
        renameMessage = nil
        guard confirmAfterMessage else { return }
        confirmAfterMessage = false
        Task { askToReplace = true }  // next turn: the error alert has to finish closing first
    }

    /// "Replace" in the edited-note alert.
    func replaceNote() {
        let (service, folder, notes) = (service, folder, notes)
        Task {
            let error = await Task.detached { () -> Error? in
                do { try service.rewriteNote(inMeetingFolder: folder, index: notes); return nil } catch { return error }
            }.value
            if let error { renameMessage = error.localizedDescription }
            reload()
        }
    }
}
