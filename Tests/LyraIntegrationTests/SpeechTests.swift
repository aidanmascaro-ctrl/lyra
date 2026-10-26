import LyraCore
import LyraSpeech
import XCTest

final class SpeechTests: XCTestCase {
    func testThreeVoiceFixture() async throws {
        try requireIntegration()
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "speaker-test-3-voices", withExtension: "wav", subdirectory: "Fixtures"))
        let samples = try AudioLoader.load16kMono(url: url)
        XCTAssertEqual(Double(samples.count) / 16_000, 43, accuracy: 1)

        let started = Date()
        let lines = try await TrackTranscriber(diarizer: FluidDiarizer(), transcriber: FluidTranscriber())
            .run(samples: samples, track: .meeting)
        print("speech: \(Date().timeIntervalSince(started)) s")
        for line in lines {
            print(String(format: "speech: [%@] %.2f-%.2f %@", line.speakerLabel, line.start, line.end, line.text))
        }

        let speakers = Set(lines.map(\.speakerLabel))
        print("speech: distinct speakers = \(speakers.count) \(speakers.sorted())")
        XCTAssertGreaterThanOrEqual(speakers.count, 2)
        let text = lines.map(\.text).joined(separator: " ").lowercased()
        XCTAssertTrue(text.contains("friday"), text)
        XCTAssertTrue(text.contains("gear list"), text)
    }

    func testLoadsStereo48kCAF() throws {
        try requireIntegration()
        let wav = try XCTUnwrap(Bundle.module.url(
            forResource: "speaker-test-3-voices", withExtension: "wav", subdirectory: "Fixtures"))
        let caf = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: caf) }
        let convert = Process()
        convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        convert.arguments = ["-f", "caff", "-d", "LEF32@48000", "-c", "2", wav.path, caf.path]
        try convert.run()
        convert.waitUntilExit()
        XCTAssertEqual(convert.terminationStatus, 0)

        let samples = try AudioLoader.load16kMono(url: caf)
        XCTAssertEqual(Double(samples.count) / 16_000, 43, accuracy: 1)
        XCTAssertGreaterThan(samples.map(abs).max() ?? 0, 0.1)
    }
}
