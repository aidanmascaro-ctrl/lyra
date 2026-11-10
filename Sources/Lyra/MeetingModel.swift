import AppKit
import LyraCore
import SwiftUI

enum MeetingTab: Hashable { case myNotes, expanded, transcript }

/// One meeting page's state: the note (found by `lyra_id`, watched on disk), the two editable sections, the
/// transcript with Phase 2's speaker renaming, and Claude's in-window actions (in `MeetingModel+Claude`).
///
/// Which version of the note each editor shows, and when a change is a conflict, is `NoteSync`'s job: the editors
/// get back exactly the blocks they sent out (so their undo history survives), and new blocks are pushed only for
/// real outside changes, each answered by the editor (`acknowledged`).
@MainActor
final class MeetingModel: ObservableObject {
    let folder: URL
    let notes: NoteIndex
    let app: AppModel
    private let service: RenameService
    /// meeting.json as last read; Retry clears its errors here at once, before Claude starts.
    @Published var meeting: Meeting?
    @Published private(set) var sync: NoteSync?
    @Published private(set) var lines: [TranscriptLine] = []
    @Published private(set) var loadError: String?
    @Published var myBlocks: [NoteBlock] = []
    @Published var expandedBlocks: [NoteBlock] = []
    /// Raised to make an editor show its blocks over unsent typing (Reload).
    @Published private(set) var forceLoad: [NoteSection: Int] = [:]
    /// The id of the latest push to each editor, which it answers through `acknowledged`.
    @Published private(set) var pushID: [NoteSection: Int] = [:]
    @Published var tab: MeetingTab
    @Published var titleDraft = ""
    /// While the title field has focus, the file's title doesn't overwrite what is being typed.
    var editingTitle = false
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
    // Names from the conversation
    /// heardnames.json: every checked name, applied or a suggestion, with its quotes.
    @Published private(set) var heardNames: [HeardName] = []
    /// Suggest names is asking Claude.
    @Published private(set) var naming = false

    private var watcher: NoteWatcher?
    /// The page has gone; the editors' last flush can still arrive after this.
    private var closed = false

    init(folder: URL, app: AppModel) {
        self.folder = folder
        self.app = app
        notes = app.notes
        service = RenameService(people: app.people)
        tab = .expanded
        reload()
        // Live, or a New note not yet recorded: ready to type. Nothing written yet (a Phase 2 meeting): the
        // transcript is all there is.
        if app.liveMeeting?.folder == folder || (!wasRecorded && lines.isEmpty) { tab = .myNotes }
        else if expandedBlocks.isEmpty && myBlocks.isEmpty { tab = .transcript }
        #if DEBUG
        if let debugTab = DebugLaunch.tab { tab = debugTab }
        #endif
        loadSeriesNames()
    }

    var loaded: LoadedNote? { sync?.loaded }
    /// Where this meeting's note is, for the editors' pictures.
    var noteURL: URL? { loaded?.url }
    var vaultRoot: URL { notes.vaultRoot }
    /// Sections changed elsewhere while they had typing Lyra hadn't saved; each waits for Reload or Keep mine.
    var conflicts: [NoteSection: NoteSync.Conflict] { sync?.conflicts ?? [:] }
    var isLive: Bool { app.liveMeeting?.folder == folder }
    /// Nothing recording or being written up here, and nothing else recording: the bottom bar offers Record.
    var canRecord: Bool { app.canRecord(in: folder) }
    /// Recorded before (and ended): Record carries on in this note, so it reads Resume.
    var wasRecorded: Bool { meeting?.endedAt != nil || meeting?.earlierParts != nil }
    /// Only once a recording has ended: while recording (or paused) the transcript is in the bottom bar's panel, and
    /// a New note never recorded has none. Resuming adds to it.
    var showsTranscriptTab: Bool { !isLive && (wasRecorded || !lines.isEmpty) }
    /// The recording just ended is being written up (transcript, then Claude); Resume waits for it.
    var isWritingUp: Bool { !isLive && app.isBusy(folder: folder, id: meeting?.id) }
    var isStartingRecording: Bool { app.startingFolder == folder }
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

    /// Re-reads meeting.json and the transcript, then the note.
    func reload() {
        do {
            let meeting = try Meeting.load(from: folder)
            self.meeting = meeting
            let transcript = folder.appendingPathComponent("transcript.json")
            // No transcript yet while recording: that's not an error. Recording again after End, the earlier
            // parts' transcript is filed under parts/ until the new part is written up.
            if FileManager.default.fileExists(atPath: transcript.path) {
                lines = try JSONDecoder().decode([TranscriptLine].self, from: Data(contentsOf: transcript))
            } else if let part = meeting.earlierParts, part > 0 {
                lines = try RecordingParts.earlier(in: folder, part: part).lines
            } else {
                lines = []
            }
            heardNames = HeardNames.load(from: folder)
            loadError = nil
        } catch {
            loadError = "Couldn't read this meeting: \(error.localizedDescription)"
            return
        }
        noteChangedOnDisk()
    }

    /// The watcher's call, and after anything else wrote the note.
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
        guard var sync else {
            var fresh = NoteSync(loaded: disk)
            myBlocks = NoteMarkdown.parse(disk.document.myNotes)
            expandedBlocks = NoteMarkdown.parse(disk.document.expanded)
            // Typing left in a conflict when the page last closed: shown again, waiting for Reload or Keep mine.
            for (section, mine) in UnsavedTyping.load(from: folder) {
                fresh.restoreConflict(section, mine: mine)
                setBlocks(mine, for: section)
            }
            self.sync = fresh
            titleDraft = disk.document.front.title
            watch(disk.url)
            return
        }
        let effects = sync.diskChanged(disk)
        self.sync = sync
        apply(effects)
    }

    private func watch(_ url: URL) {
        if let watcher { return watcher.watch(url) }
        watcher = NoteWatcher(url: url) { [weak self] in
            MainActor.assumeIsolated { self?.noteChangedOnDisk() }
        }
    }

    func close() {
        closed = true
        watcher?.stop()
        keepUnsavedTyping()
    }

    /// Once the page has gone nobody can answer a conflict banner, so the typing in each conflict is kept beside
    /// the recording and asked about next time the meeting opens.
    private func keepUnsavedTyping() {
        guard let conflicts = sync?.conflicts, !conflicts.isEmpty else { return }
        do { try UnsavedTyping.save(conflicts.mapValues(\.mine), in: folder) } catch {
            notice = "Lyra couldn't keep your unsaved typing: \(error.localizedDescription)"
        }
    }

    /// The conflict for `section` is settled: typing kept from an earlier visit is done with.
    private func settled(_ section: NoteSection) {
        do { try UnsavedTyping.clear(section, in: folder) } catch {
            notice = "Lyra couldn't tidy up kept typing: \(error.localizedDescription)"
        }
    }

    /// Pushes blocks to the editors and follows the note to wherever it now is.
    private func apply(_ effects: [NoteSync.Effect]) {
        for effect in effects {
            switch effect {
            case .push(let section, let blocks, let id):
                setBlocks(blocks, for: section)
                pushID[section] = id
            case .forcePush(let section, let blocks):
                setBlocks(blocks, for: section)
                forceLoad[section, default: 0] += 1
            }
        }
        guard let loaded else { return }
        watch(loaded.url)
        if !editingTitle { titleDraft = loaded.document.front.title }
    }

    private func setBlocks(_ blocks: [NoteBlock], for section: NoteSection) {
        switch section {
        case .myNotes: myBlocks = blocks
        case .expanded: expandedBlocks = blocks
        }
    }

    // MARK: Editing

    /// An editor's debounced change, saved unless it collides with an edit made elsewhere.
    func edited(_ blocks: [NoteBlock], in section: NoteSection) {
        setBlocks(blocks, for: section)
        guard var sync else { return }
        do {
            let effects = try sync.edited(blocks, in: section, index: notes)
            self.sync = sync
            apply(effects)
        } catch {
            self.sync = sync
            notice = "Lyra couldn't save this note: \(error.localizedDescription)"
        }
        if closed { keepUnsavedTyping() }
    }

    /// An editor's answer to push `id`: shown, or refused because of unsent typing.
    func acknowledged(_ section: NoteSection, id: Int, accepted: Bool) {
        sync?.ack(section, id: id, accepted: accepted)
    }

    /// Lyra writing Expanded itself (Claude's additions; never My notes). False when the section is unsettled (a
    /// conflict, or a change it hasn't shown yet), in which case nothing is written.
    func lyraWriteExpanded(_ blocks: [NoteBlock]) -> Bool {
        guard var sync else { return false }
        do {
            let result = try sync.writeExpanded(blocks, index: notes)
            self.sync = sync
            apply(result.effects)
            return result.written
        } catch {
            notice = "Lyra couldn't save this note: \(error.localizedDescription)"
            return false
        }
    }

    /// "Reload": the file's version wins, even over typing not yet sent.
    func takeDisk(_ section: NoteSection) {
        guard var sync else { return }
        let effects = sync.reload(section)
        self.sync = sync
        apply(effects)
        settled(section)
    }

    /// "Keep mine": this section is written over Obsidian's, as the file is right now.
    func keepMine(_ section: NoteSection) {
        guard var sync else { return }
        do {
            let effects = try sync.keepMine(section, index: notes)
            self.sync = sync
            apply(effects)
            settled(section)
        } catch { notice = "Lyra couldn't save your version: \(error.localizedDescription)" }
    }

    // MARK: Title and series (vault-wide file work, off the main actor)

    func commitTitle() {
        editingTitle = false
        let title = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let loaded, !title.isEmpty, title != loaded.document.front.title else {
            titleDraft = loaded?.document.front.title ?? titleDraft
            return
        }
        let notes = notes
        vaultWork { try SeriesActions.retitle(loaded, to: title, index: notes).problems }
    }

    func move(to series: String?) {
        guard let loaded else { return }
        let notes = notes
        vaultWork { try SeriesActions.move(loaded, to: series, index: notes).problems }
    }

    /// Confirmed "Move to Trash": back to Home once the note and recordings are in the Trash; problems stay here.
    func trash() {
        guard let meeting, !app.isBusy(folder: folder, id: meeting.id) else { notice = HomeModel.stillWorking; return }
        let (id, folder, notes) = (meeting.id, folder, notes)
        Task {
            let problems = await Task.detached { MeetingTrash.trash(id: id, folder: folder, index: notes) }.value
            if problems.isEmpty { app.route = .home } else { notice = problems.joined(separator: "\n") }
        }
    }

    func notRelated() {
        let folder = folder
        vaultWork { try SeriesActions.reject(meetingFolder: folder); return [] }
    }

    /// Runs `work` off the main actor, then reads the note back from disk (wherever it now is), so the editors
    /// see exactly what the file holds.
    private func vaultWork(_ work: @escaping @Sendable () throws -> [String]) {
        Task {
            let result = await Task.detached { Result { try work() } }.value
            switch result {
            case .success(let problems): if !problems.isEmpty { notice = problems.joined(separator: "\n") }
            case .failure(let error): notice = error.localizedDescription
            }
            noteChangedOnDisk()
            loadSeriesNames()
        }
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

    // MARK: Names from the conversation

    /// The quotes behind a speaker's name or suggestion, for its pill.
    func heardEntry(for speaker: SpeakerSummary) -> HeardName? {
        HeardNames.entry(for: speaker.label, source: speaker.source, in: heardNames)
    }

    /// Suggest names shows while some voice is still "Speaker N" and naming hasn't run (or last failed).
    var canSuggestNames: Bool {
        !naming && !renaming && !isWritingUp && meeting?.namesDone != true && !HeardNames.placeholders(in: lines).isEmpty
    }

    func suggestNames() {
        guard !naming, !renaming else { return }
        naming = true
        Task {
            do {
                if try await app.suggestNames(folder: folder) == .needsConfirmation { askToReplace = true }
            } catch {
                renameMessage = "Lyra couldn't suggest names: \(error.localizedDescription)"
            }
            naming = false
            reload()
        }
    }

    /// "Yes, that's them": the heard name becomes Aidan's, and the voice is learned, through the normal rename.
    func confirmHeard(_ heard: HeardName, label: String) {
        rename(label, to: heard.name)
    }

    /// "Not them": the name goes, and stays gone if names are suggested again.
    func rejectHeard(_ heard: HeardName) {
        renaming = true
        let (folder, notes) = (folder, notes)
        Task {
            let result = await Task.detached { () -> Result<RenameOutcome, Error> in
                do { return .success(try TalkNamer.reject(heard, folder: folder, note: RenameService.noteURL(inMeetingFolder: folder, index: notes))) }
                catch { return .failure(error) }
            }.value
            renaming = false
            switch result {
            case .success(let outcome): if outcome == .needsConfirmation { askToReplace = true }
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
