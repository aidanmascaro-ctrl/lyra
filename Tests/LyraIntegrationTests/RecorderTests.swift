import AVFoundation
@testable import LyraAudio
import LyraCore
import XCTest

final class RecorderTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        try requireIntegration()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-rec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func testAppAudioCapturesAfplay() async throws {
        let result = try await recordAfplay(seconds: 5)
        print("normal: peak=\(result.peakLevel) seconds=\(result.seconds)")
        XCTAssertNil(result.error)
        XCTAssertEqual(result.kind, .meeting)
        XCTAssertGreaterThanOrEqual(result.seconds, 4)
        XCTAssertGreaterThan(result.peakLevel, 0.01)
    }

    func testAppAudioCapturesWhileMuted() async throws {
        let wasMuted = try osascript("output muted of (get volume settings)") == "true"
        defer { _ = try? osascript("set volume output muted \(wasMuted)") }
        _ = try osascript("set volume output muted true")
        XCTAssertEqual(try osascript("output muted of (get volume settings)"), "true")

        let result = try await recordAfplay(seconds: 5)
        print("muted: peak=\(result.peakLevel) seconds=\(result.seconds)")
        XCTAssertNil(result.error)
        XCTAssertGreaterThanOrEqual(result.seconds, 4)
        XCTAssertGreaterThan(result.peakLevel, 0.01)
    }

    func testCrashLeavesPlayableFile() async throws {
        let url = folder.appendingPathComponent("mic.caf")
        let recorder = MicRecorder()
        try recorder.start(writingTo: url)
        try await Task.sleep(for: .seconds(2))
        // Abandoned: never stopped. Read the file exactly as a crash would leave it on disk.
        let file = try AVAudioFile(forReading: url)
        XCTAssertGreaterThan(file.length, 0)
        withExtendedLifetime(recorder) {}
    }

    func testMicResumesAfterConfigurationChange() async throws {
        if AudioInputs.chosenCaptureDevice() != nil { throw XCTSkip("a Bluetooth default is recorded through the Mac's own mic, not the engine") }
        let recorder = MicRecorder()
        try recorder.start(writingTo: folder.appendingPathComponent("mic.caf"))
        let started = Date()  // once capture runs; engine setup before it isn't recording time
        try await Task.sleep(for: .seconds(1))
        // Simulate a device change: the engine stops itself, stays down for a while, then posts the notification.
        let engine = try XCTUnwrap(recorder.session?.engine)
        engine.stop()
        try await Task.sleep(for: .seconds(1))
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        try await Task.sleep(for: .seconds(2))
        let result = await recorder.stop()
        let elapsed = Date().timeIntervalSince(started)
        print("config change: seconds=\(result.seconds) elapsed=\(elapsed) error=\(result.error ?? "nil")")
        XCTAssertNil(result.error)
        // The stopped second is kept as silence, so the mic track stays aligned with the meeting track.
        XCTAssertEqual(result.seconds, elapsed, accuracy: 0.2)
    }

    func testSecondStartThrows() throws {
        let mic = MicRecorder()
        try mic.start(writingTo: folder.appendingPathComponent("a.caf"))
        XCTAssertThrowsError(try mic.start(writingTo: folder.appendingPathComponent("b.caf")))
        let app = AppAudioRecorder(target: MicUser(pid: ProcessInfo.processInfo.processIdentifier, bundleID: "", appName: "self"))
        // Our own process has a Core Audio object because the mic engine is running.
        try app.start(writingTo: folder.appendingPathComponent("c.caf"))
        XCTAssertThrowsError(try app.start(writingTo: folder.appendingPathComponent("d.caf")))
    }

    func testInPersonRecordsMicOnly() async throws {
        let recorder = TwoTrackRecorder(target: nil)
        let warning = try await recorder.start(in: folder)
        XCTAssertNil(warning)
        try await Task.sleep(for: .seconds(1))
        let results = await recorder.stop()
        XCTAssertEqual(results.map(\.kind), [.mic])
        XCTAssertNil(results.first?.error)
        XCTAssertGreaterThan(results.first?.seconds ?? 0, 0.5)
    }

    // MARK: helpers

    private func recordAfplay(seconds: Double) async throws -> TrackResult {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "speaker-test-3-voices", withExtension: "wav", subdirectory: "Fixtures"))
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [fixture.path]
        try player.run()
        defer { player.terminate() }
        try await Task.sleep(for: .milliseconds(500))

        let recorder = AppAudioRecorder(target: MicUser(pid: player.processIdentifier, bundleID: "", appName: "afplay"))
        try recorder.start(writingTo: folder.appendingPathComponent("meeting.caf"))
        try await Task.sleep(for: .seconds(seconds))
        return await recorder.stop()
    }

    private func osascript(_ script: String) throws -> String {
        let p = Process()
        let out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// No hardware: converting a changed input format back into the file's original format.
final class FormatBridgeTests: XCTestCase {
    func testConvertsNewInputFormatIntoFileFormat() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-bridge-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let fileFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let inputFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let writer = try CAFWriter(url: url, format: fileFormat.streamDescription.pointee)
        let bridge = try FormatBridge(from: inputFormat, to: fileFormat, writer: writer)
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 4410))
        input.frameLength = 4410
        for i in 0..<4410 { input.floatChannelData![0][i] = 0.5 * sin(Float(i) * 0.06) }
        let start = AudioConvertNanosToHostTime(5_000_000_000)
        for i in 0..<10 { bridge.write(input, hostTime: start + UInt64(i)) } // 1 s of 44.1 kHz mono
        bridge.flush()
        let result = writer.finish(kind: .mic)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.seconds, 1, accuracy: 0.005)
        XCTAssertEqual(result.peakLevel, 0.5, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(result.firstFrameTime), 5, accuracy: 0.001)  // the first buffer's time is kept
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 48_000)
        XCTAssertEqual(file.fileFormat.channelCount, 2)
    }
}

/// No hardware: fake recorders behind TwoTrackRecorder's seam.
final class TwoTrackRecorderTests: XCTestCase {
    private final class FakeRecorder: TrackRecorder {
        let kind: TrackKind
        let fails: Bool
        var url: URL?
        init(_ kind: TrackKind, fails: Bool) { self.kind = kind; self.fails = fails }
        func start(writingTo url: URL) throws {
            if fails {
                FileManager.default.createFile(atPath: url.path, contents: nil)  // like a half-opened CAF
                throw AudioError(description: "no Core Audio process for zoom.us")
            }
            self.url = url
        }
        func stop() async -> TrackResult { TrackResult(kind: kind, url: url!, seconds: 1, peakLevel: 0.5, error: nil) }
    }

    private let zoom = MicUser(pid: 100, bundleID: "us.zoom.xos", appName: "zoom.us")
    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-2t-\(UUID().uuidString)")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    func testMeetingTrackFailureRecordsMicOnlyWithWarning() async throws {
        var meetingAttempts = 0
        let recorder = TwoTrackRecorder(target: zoom, meeting: { _ in meetingAttempts += 1; return FakeRecorder(.meeting, fails: true) },
                                        mic: { FakeRecorder(.mic, fails: false) }, retryDelay: .zero)
        let warning = try await recorder.start(in: folder)
        XCTAssertEqual(warning, "Couldn't capture zoom.us audio: no Core Audio process for zoom.us. Transcript is from your microphone only.")
        XCTAssertEqual(meetingAttempts, 12)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("meeting.caf").path))
        let results = await recorder.stop()
        XCTAssertEqual(results.map(\.kind), [.mic])
    }

    func testMeetingTrackRetriesThenRecordsBoth() async throws {
        var meetingAttempts = 0
        let recorder = TwoTrackRecorder(target: zoom, meeting: { _ in meetingAttempts += 1; return FakeRecorder(.meeting, fails: meetingAttempts < 3) },
                                        mic: { FakeRecorder(.mic, fails: false) }, retryDelay: .zero)
        let warning = try await recorder.start(in: folder)
        XCTAssertNil(warning)
        let results = await recorder.stop()
        XCTAssertEqual(results.map(\.kind), [.meeting, .mic])
    }

    func testMicFailureThrows() async throws {
        let recorder = TwoTrackRecorder(target: zoom, meeting: { _ in FakeRecorder(.meeting, fails: false) },
                                        mic: { FakeRecorder(.mic, fails: true) }, retryDelay: .zero)
        do { _ = try await recorder.start(in: folder); XCTFail("expected a throw") } catch {}
        let results = await recorder.stop()
        XCTAssertEqual(results.count, 0)
    }
}
