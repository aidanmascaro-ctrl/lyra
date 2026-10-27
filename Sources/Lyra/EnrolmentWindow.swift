import LyraAudio
import LyraCore
import LyraSpeech
import SwiftUI

/// Records 20 s of mic (only after Start), finds Aidan's voice in it and saves it as the owner. The recording is a
/// temp file, deleted whatever happens; meeting folders are never touched.
@MainActor
final class EnrolmentModel: ObservableObject {
    enum Phase: Equatable { case ready, recording(secondsLeft: Int), working, saved, tooLittle, failed(String) }
    static let seconds = 20

    @Published private(set) var phase = Phase.ready
    private var recorder: MicRecorder?
    private var file: URL?
    private var countdown: Task<Void, Never>?

    func start(people: PeopleStore) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-enrol-\(UUID().uuidString).caf")
        let recorder = MicRecorder()
        do { try recorder.start(writingTo: url) } catch {
            try? FileManager.default.removeItem(at: url)
            phase = .failed("Couldn't start the microphone: \(error.localizedDescription)")
            return
        }
        self.recorder = recorder
        file = url
        phase = .recording(secondsLeft: Self.seconds)
        countdown = Task { [weak self] in
            for left in stride(from: Self.seconds - 1, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                phase = .recording(secondsLeft: left)
            }
            await self?.finish(people: people)
        }
    }

    /// Stops and throws the recording away. Also runs when the window closes.
    func cancel() {
        countdown?.cancel()
        countdown = nil
        guard let recorder, let file else { return }
        self.recorder = nil
        self.file = nil
        phase = .ready
        Task {
            _ = await recorder.stop()
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func finish(people: PeopleStore) async {
        guard let recorder, let file else { return }
        self.recorder = nil
        self.file = nil
        countdown = nil
        phase = .working
        _ = await recorder.stop()
        let result = await Task.detached { () -> Result<Bool, Error> in
            defer { try? FileManager.default.removeItem(at: file) }
            do {
                let samples = try AudioLoader.load16kMono(url: file)
                return .success(try await Enrolment.enrol(samples: samples, diarizer: FluidDiarizer(), people: people))
            } catch { return .failure(error) }
        }.value
        switch result {
        case .success(true): phase = .saved
        case .success(false): phase = .tooLittle
        case .failure(let error): phase = .failed(error.localizedDescription)
        }
    }
}

struct EnrolmentWindow: View {
    @ObservedObject var app: AppModel
    @StateObject private var model = EnrolmentModel()

    static let paragraph = """
        This morning I made a cup of coffee and stood by the window for a while. The sky was grey, but the rain \
        held off, so I went out for a short walk around the block. A neighbour was watering her garden and a dog \
        barked at me from behind a gate. When I got home the kettle was still warm, so I made a second cup, sat \
        down at the table and wrote a list of the things I wanted to get done before lunch.
        """

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Press Start, then read this aloud in your normal voice. Lyra records your microphone for \(EnrolmentModel.seconds) seconds, only to learn your voice.")
                .foregroundStyle(.secondary)
            Text(Self.paragraph).font(.title3).textSelection(.enabled)
            HStack {
                status
                Spacer()
                controls
            }
        }
        .padding(24)
        .frame(width: 520)
        .onDisappear { model.cancel() }
    }

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .ready: EmptyView()
        case .recording(let left): Text("Recording… \(left) s").monospacedDigit()
        case .working: HStack { ProgressView().controlSize(.small); Text("Learning your voice…") }
        case .saved: Text("Saved. Lyra now knows your voice.")
        case .tooLittle: Text("Lyra heard less than \(Int(Enrolment.minSpeechSeconds)) seconds of speech. Try again, a little closer to the mic.")
        case .failed(let message): Text(message).foregroundStyle(.red)
        }
    }

    @ViewBuilder private var controls: some View {
        switch model.phase {
        case .recording: Button("Cancel") { model.cancel() }
        case .working: EmptyView()
        default:
            Button(model.phase == .ready ? "Start" : "Record again") { model.start(people: app.people) }
                .keyboardShortcut(.defaultAction)
                .disabled(app.isRecording || app.starting)
                .help(app.isRecording ? "Stop the meeting recording first." : "")
        }
    }
}
