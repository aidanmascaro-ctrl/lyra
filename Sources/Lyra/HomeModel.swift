import Foundation
import LyraCore

/// What the home window lists: every Lyra note under Meetings/, grouped into series, with pending suggestions.
/// Read off the main actor; refreshed when the window shows, comes forward, or a meeting finishes.
@MainActor
final class HomeModel: ObservableObject {
    @Published private(set) var recent: [MeetingSummary] = []
    @Published private(set) var groups: [SeriesGroup] = []
    @Published private(set) var suggestions: [MeetingSummary] = []
    @Published private(set) var loading = true
    /// Plain-English problems from a series change.
    @Published var notice: String?
    private let app: AppModel

    init(app: AppModel) { self.app = app }

    func refresh() {
        let (notes, root) = (app.notes, app.paths.recordingsRoot)
        Task {
            let summaries = await Task.detached { Self.summaries(notes: notes, recordingsRoot: root) }.value
            recent = summaries.sorted { $0.date > $1.date }
            groups = SeriesLibrary.groups(summaries)
            suggestions = SeriesLibrary.pendingSuggestions(summaries)
            loading = false
        }
    }

    /// "Add to series" on a suggestion card: `series:` set, the note filed into the folder, the page rewritten.
    func accept(_ summary: MeetingSummary) {
        guard let series = summary.suggestion else { return }
        let index = app.notes
        act(on: summary) { note in try SeriesActions.move(note, to: series, index: index).problems }
    }

    func reject(_ summary: MeetingSummary) {
        guard let folder = summary.folder else { return }
        do { try SeriesActions.reject(meetingFolder: folder) } catch { notice = "Lyra couldn't save that: \(error.localizedDescription)" }
        refresh()
    }

    func rename(series: String, to name: String) {
        do {
            let problems = try SeriesActions.rename(series, to: name, index: app.notes)
            if !problems.isEmpty { notice = problems.joined(separator: "\n") }
        } catch { notice = error.localizedDescription }
        refresh()
    }

    private func act(on summary: MeetingSummary, _ change: (LoadedNote) throws -> [String]) {
        do {
            let problems = try change(try app.notes.load(summary.id, hint: summary.note))
            if !problems.isEmpty { notice = problems.joined(separator: "\n") }
        } catch { notice = error.localizedDescription }
        refresh()
    }

    private nonisolated static func summaries(notes: NoteIndex, recordingsRoot: URL) -> [MeetingSummary] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: recordingsRoot, includingPropertiesForKeys: nil)) ?? []
        var meetings: [UUID: (Meeting, URL)] = [:]
        for folder in folders {
            if let meeting = try? Meeting.load(from: folder) { meetings[meeting.id] = (meeting, folder) }
        }
        return SeriesLibrary.summaries(notes: notes.allNotes(), meetingsByID: meetings, notesRoot: notes.notesRoot)
    }
}
