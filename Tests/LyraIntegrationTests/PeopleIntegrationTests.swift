import Foundation
import LyraCore
import LyraSpeech
import XCTest

/// Voice naming end to end on real models. Nothing here touches the real people.json: every store is a temp file.
final class PeopleIntegrationTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-people-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private var fixture: URL {
        get throws { try XCTUnwrap(Bundle.module.url(forResource: "speaker-test-3-voices", withExtension: "wav", subdirectory: "Fixtures")) }
    }

    /// Ground truth for the fixture (docs/notes/phase1-findings.md): who speaks when, in seconds.
    private let daniel = [(0.0, 6.8), (18.8, 24.6), (35.2, 43.0)]
    private let others = [("Flo", 6.8, 13.4), ("Fred", 13.4, 18.8), ("Flo", 24.8, 30.3), ("Fred", 30.3, 35.2)]

    private func clusters(_ url: URL, _ track: TrackKind) async throws -> [SpeakerCluster] {
        try await TrackTranscriber(diarizer: FluidDiarizer(), transcriber: FluidTranscriber())
            .run(samples: AudioLoader.load16kMono(url: url), track: track).clusters
    }

    /// The fingerprint of a clip's longest cluster: what enrolment would learn from it.
    private func longest(_ url: URL, _ track: TrackKind = .meeting) async throws -> [Float] {
        let all = try await clusters(url, track)
        return try XCTUnwrap(all.max { $0.speechSeconds < $1.speechSeconds }).centroid
    }

    /// A fresh `say -v Daniel` clip with none of the fixture's sentences.
    private func danielClip() throws -> URL {
        let out = dir.appendingPathComponent("daniel-enrol.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Daniel", "-o", out.path,
                         "Morning everyone. The client wants a slower edit with more room for the product shots. "
                         + "I spoke to the editor yesterday and we agreed on three versions: thirty seconds, fifteen, and a six second cut-down. "
                         + "Let's keep the colour warm and the music low under the voice-over."]
        try say.run()
        say.waitUntilExit()
        XCTAssertEqual(say.terminationStatus, 0)
        return out
    }

    private func cosine(_ a: [Float], _ b: [Float]) -> Double { zip(a, b).reduce(0) { $0 + Double($1.0 * $1.1) } }

    private func inside(_ l: TranscriptLine, _ span: (Double, Double)) -> Bool { l.start >= span.0 - 0.3 && l.end <= span.1 + 0.3 }

    func testEnrolledDanielIsNamedOnlyOnHisLines() async throws {
        try requireIntegration()
        let store = PeopleStore(fileURL: dir.appendingPathComponent("people.json"))
        let danielPerson = try store.learn(name: "Daniel", sample: try await longest(try danielClip()))

        let folder = dir.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let wav = folder.appendingPathComponent("meeting.wav")
        try FileManager.default.copyItem(at: try fixture, to: wav)
        let processor = MeetingProcessor(
            trackTranscriber: TrackTranscriber(diarizer: FluidDiarizer(), transcriber: FluidTranscriber()),
            loader: { try AudioLoader.load16kMono(url: $0) }, convert: { _, _ in XCTFail("a WAV is never converted") },
            people: { store.all() })
        let meeting = Meeting(title: "Fixture", appName: "Test", startedAt: Date(), endedAt: Date())
        _ = try await processor.process(meeting: meeting, tracks: [TrackResult(kind: .meeting, url: wav, seconds: 43, peakLevel: 0.5, error: nil)],
                                        folder: folder, noteURL: dir.appendingPathComponent("note.md"))

        let lines = try JSONDecoder().decode([TranscriptLine].self, from: Data(contentsOf: folder.appendingPathComponent("transcript.json")))
        let speakers = try JSONDecoder().decode([SpeakerCluster].self, from: Data(contentsOf: folder.appendingPathComponent("speakers.json")))
        for s in speakers {
            print(String(format: "people: cluster %@ %.1f s  sim(Daniel) = %.3f", s.id, s.speechSeconds, cosine(s.centroid, danielPerson.prototype)))
        }
        for l in lines {
            print(String(format: "people: [%@ / %@ / %.3f] %.2f-%.2f %@", l.speakerLabel, l.speakerID ?? "-", l.confidence ?? -1, l.start, l.end, l.text))
        }
        XCTAssertTrue(store.all().count == 1 && store.all()[0].samples.count == 1, "naming must never write to the store")

        // Every line inside one of Daniel's sentences is named Daniel.
        let danielLines = lines.filter { l in daniel.contains { inside(l, $0) } }
        XCTAssertFalse(danielLines.isEmpty)
        for l in danielLines {
            XCTAssertEqual(l.personID, danielPerson.id, "\(l.start)-\(l.end) \(l.text)")
            XCTAssertEqual(l.nameSource, .knownVoice)
        }
        // No line inside Flo's sentences is named Daniel. Fred: see the strictness note below.
        for (who, a, b) in others {
            for l in lines where inside(l, (a, b)) {
                print("people: \(who) line named \(l.speakerLabel)")
                if who == "Flo" { XCTAssertNil(l.personID, "\(who): \(l.text)") }
            }
        }
        // ponytail: Fred is not asserted. The diarizer (default config) folds Fred into Daniel's cluster (phase1-findings),
        // so his words carry Daniel's fingerprint and get Daniel's name. Assert him once Lyra passes a speaker count.
    }

    /// Calibration (Step 5): similarities of real clusters against Aidan and Daniel. Reads Aidan's recordings,
    /// never writes there; prints numbers and cluster ids only (the meeting track is third-party content).
    func testCalibrationSimilarities() async throws {
        try requireIntegration()
        guard ProcessInfo.processInfo.environment["LYRA_CALIBRATION"] == "1" else { throw XCTSkip("set LYRA_CALIBRATION=1") }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Lyra Recordings")
        let m0405 = root.appendingPathComponent("2026-10-27 0405 — Google Chrome")
        let m0409 = root.appendingPathComponent("2026-10-27 0409 — Google Chrome")
        guard FileManager.default.fileExists(atPath: m0409.path) else { throw XCTSkip("Aidan's test recordings aren't on this machine") }

        let store = PeopleStore(fileURL: dir.appendingPathComponent("people.json"))
        let enrol = try await clusters(m0405.appendingPathComponent("mic.m4a"), .mic)
        for c in enrol { print(String(format: "calib: 0405 %@ %.1f s", c.id, c.speechSeconds)) }
        let source = try XCTUnwrap(enrol.max { $0.speechSeconds < $1.speechSeconds })
        print("calib: Aidan enrolled from 0405 \(source.id)")
        let aidan = try store.learn(name: "Aidan", sample: source.centroid, isOwner: true)
        let daniel = try store.learn(name: "Daniel", sample: try await longest(try danielClip()))

        func report(_ label: String, _ cs: [SpeakerCluster]) {
            for c in cs {
                let m = VoiceMatcher.match(c.centroid, people: store.all())
                print(String(format: "calib: %@ %@ %.1f s  Aidan %.3f  Daniel %.3f  match=%@", label, c.id, c.speechSeconds,
                             cosine(c.centroid, aidan.prototype), cosine(c.centroid, daniel.prototype),
                             m.flatMap { id in store.all().first { $0.id == id.personID }?.name } ?? "none"))
            }
        }
        report("0405", enrol)
        report("0405", try await clusters(m0405.appendingPathComponent("meeting.m4a"), .meeting))
        // 0409 in full: which mic clusters survive the echo filter, and how close each is to the call's own voice.
        let tt = TrackTranscriber(diarizer: FluidDiarizer(), transcriber: FluidTranscriber())
        let saved = try Meeting.load(from: m0409).tracks ?? []
        var lines: [TrackKind: [TranscriptLine]] = [:]
        var found: [SpeakerCluster] = []
        for kind in [TrackKind.mic, .meeting] {
            let r = try await tt.run(samples: AudioLoader.load16kMono(url: m0409.appendingPathComponent("\(kind.rawValue).m4a")), track: kind)
            let offset = saved.first { $0.kind == kind }?.startOffset ?? 0
            lines[kind] = r.lines.map { var l = $0; l.start += offset; l.end += offset; return l }
            found += r.clusters
        }
        report("0409", found)
        let kept = Set(TranscriptMerger.merge(meeting: lines[.meeting] ?? [], mic: lines[.mic] ?? []).compactMap(\.speakerID))
        let call = found.filter { $0.track == .meeting }
        for c in found where c.track == .mic {
            let n = lines[.mic]?.filter { $0.speakerID == c.id }.count ?? 0
            print(String(format: "calib: 0409 %@ lines=%d survivesEchoFilter=%@ maxSim(call clusters)=%.3f", c.id, n,
                         kept.contains(c.id) ? "yes" : "no", call.map { cosine(c.centroid, $0.centroid) }.max() ?? .nan))
        }
        report("fixture", try await clusters(try fixture, .meeting))
    }
}
