import AVFoundation
import LyraAudio
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

    func testInPersonRecordsMicOnly() async throws {
        let recorder = TwoTrackRecorder(target: nil)
        try recorder.start(in: folder)
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
