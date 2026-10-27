import AppKit
import LyraCore
import SwiftUI

/// One meeting: its speakers (click one to rename it, which also teaches Lyra that voice) and its transcript.
@MainActor
final class MeetingModel: ObservableObject {
    let folder: URL
    let note: URL
    private let service: RenameService
    @Published private(set) var meeting: Meeting?
    @Published private(set) var lines: [TranscriptLine] = []
    @Published private(set) var loadError: String?
    @Published private(set) var renaming = false
    @Published private(set) var message: String?
    @Published var askToReplace = false
    /// Set when a rename error also needs the replace question: asked once the error is dismissed.
    private var confirmAfterMessage = false

    init(folder: URL, notesDir: URL, people: PeopleStore) {
        self.folder = folder
        note = notesDir.appendingPathComponent(folder.lastPathComponent + ".md")  // same naming as processing
        service = RenameService(people: people)
        reload()
    }

    var speakers: [SpeakerSummary] { MeetingOverview.speakers(in: lines) }

    func reload() {
        do {
            meeting = try Meeting.load(from: folder)
            lines = try JSONDecoder().decode([TranscriptLine].self, from: Data(contentsOf: folder.appendingPathComponent("transcript.json")))
            loadError = nil
        } catch { loadError = "Couldn't read this meeting: \(error.localizedDescription)" }
    }

    func rename(_ label: String, to name: String) {
        renaming = true
        let (service, folder, note) = (service, folder, note)
        Task {
            let result = await Task.detached { () -> Result<RenameOutcome, Error> in
                do { return .success(try service.rename(speakerLabel: label, to: name, inMeetingFolder: folder, note: note)) }
                catch { return .failure(error) }
            }.value
            renaming = false
            switch result {
            case .success(let outcome): handle(outcome)
            case .failure(RenameError.notLearned(let outcome, let underlying)):
                message = RenameError.notLearned(outcome: outcome, underlying: underlying).localizedDescription
                confirmAfterMessage = outcome == .needsConfirmation
            case .failure(let error): message = error.localizedDescription
            }
            reload()
        }
    }

    private func handle(_ outcome: RenameOutcome) {
        if outcome == .needsConfirmation { askToReplace = true }
    }

    func dismissMessage() {
        message = nil
        guard confirmAfterMessage else { return }
        confirmAfterMessage = false
        Task { askToReplace = true }  // next turn: the error alert has to finish closing first
    }

    /// "Replace" in the edited-note alert.
    func replaceNote() {
        let (service, folder, note) = (service, folder, note)
        Task {
            let error = await Task.detached { () -> Error? in
                do { try service.rewriteNote(inMeetingFolder: folder, note: note); return nil } catch { return error }
            }.value
            if let error { message = error.localizedDescription }
            reload()
        }
    }
}

struct MeetingWindow: View {
    @ObservedObject var app: AppModel

    var body: some View {
        if let folder = app.shownMeeting {
            MeetingContent(model: MeetingModel(folder: folder, notesDir: app.paths.notesDir, people: app.people), people: app.people)
                .id(folder)
        } else {
            Text("No meetings yet.").padding(40)
        }
    }
}

private struct MeetingContent: View {
    @StateObject var model: MeetingModel
    let people: PeopleStore
    @State private var editing: String?
    @State private var newName = ""

    init(model: @autoclosure @escaping () -> MeetingModel, people: PeopleStore) {
        _model = StateObject(wrappedValue: model())
        self.people = people
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let error = model.loadError { Text(error).foregroundStyle(.red) }
            HStack(alignment: .top, spacing: 16) {
                speakerList.frame(width: 240)
                transcript
            }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 480)
        .alert("Couldn't finish renaming", isPresented: Binding(get: { model.message != nil },
                                                                set: { if !$0 { model.dismissMessage() } })) {
            Button("OK") {}
        } message: { Text(model.message ?? "") }
        .alert("This note's transcript was edited in Obsidian. Replace it with the renamed transcript?",
               isPresented: $model.askToReplace) {
            Button("Replace") { model.replaceNote() }
            Button("Keep my edits", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(model.meeting?.title ?? model.folder.lastPathComponent).font(.title2.bold())
                if let date = model.meeting?.startedAt {
                    Text(date.formatted(date: .complete, time: .shortened)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Open note in Obsidian") { NSWorkspace.shared.open(model.note) }
                .disabled(!FileManager.default.fileExists(atPath: model.note.path))
        }
    }

    private var speakerList: some View {
        List(model.speakers, id: \.label) { s in
            VStack(alignment: .leading, spacing: 4) {
                Button { editing = s.label; newName = s.label.hasPrefix("Speaker ") ? "" : s.label } label: {
                    HStack {
                        Text(s.label).bold()
                        if let badge = Self.badge(s.source) { Text(badge).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Text(Self.duration(s.seconds)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.renaming)
                if editing == s.label { renameField(for: s.label) }
            }
        }
    }

    private func renameField(for label: String) -> some View {
        let typed = newName.trimmingCharacters(in: .whitespaces).lowercased()
        let suggestions = people.all().map(\.name)
            .filter { typed.isEmpty || $0.lowercased().hasPrefix(typed) }
            .filter { $0.lowercased() != typed }
            .sorted()
            .prefix(5)
        return VStack(alignment: .leading, spacing: 4) {
            TextField("Name", text: $newName).onSubmit { commit(label) }
            ForEach(Array(suggestions), id: \.self) { name in
                Button(name) { newName = name }.buttonStyle(.link)
            }
            HStack {
                Button("Cancel") { editing = nil }
                Button("Rename") { commit(label) }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func commit(_ label: String) {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        editing = nil
        model.rename(label, to: name)
    }

    private var transcript: some View {
        List(model.lines.indices, id: \.self) { i in
            let line = model.lines[i]
            HStack(alignment: .firstTextBaseline) {
                Text(Self.stamp(line.start)).monospacedDigit().foregroundStyle(.secondary)
                Text(line.speakerLabel).bold()
                Text(line.text).textSelection(.enabled)
            }
        }
    }

    static func badge(_ source: NameSource?) -> String? {
        switch source {
        case .knownVoice: "known voice"
        case .setByAidan: "named by you"
        case nil: nil
        }
    }

    static func duration(_ s: Double) -> String { "\(Int(s.rounded())) s" }

    static func stamp(_ t: Double) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
}
