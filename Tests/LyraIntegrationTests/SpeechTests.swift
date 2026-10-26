import AVFoundation
import LyraAudio
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

    /// An all-zeros track (what a missing Audio Capture permission records) is no speakers, not an error.
    func testDiarizerOnSilenceIsEmpty() async throws {
        try requireIntegration()
        let turns = try await FluidDiarizer().diarize(samples: [Float](repeating: 0, count: 160_000))
        XCTAssertTrue(turns.isEmpty)
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

    /// Compressed formats overestimate `length`; the read past the real end must count as end-of-file.
    /// Encoded with Lyra's own converter, as every processed meeting is.
    func testLoadsAACThroughEnd() async throws {
        try requireIntegration()
        let wav = try XCTUnwrap(Bundle.module.url(
            forResource: "speaker-test-3-voices", withExtension: "wav", subdirectory: "Fixtures"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-aac-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let m4a = dir.appendingPathComponent("meeting.m4a")
        try await M4AConverter.convert(wav, to: m4a)

        let samples = try AudioLoader.load16kMono(url: m4a)
        XCTAssertEqual(Double(samples.count) / 16_000, 43, accuracy: 1)
    }

    /// A CAF cut off halfway (a crash-damaged master) must throw, not load as a shorter meeting.
    func testTruncatedCAFThrows() throws {
        try requireIntegration()
        let wav = try XCTUnwrap(Bundle.module.url(
            forResource: "speaker-test-3-voices", withExtension: "wav", subdirectory: "Fixtures"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-cut-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let caf = dir.appendingPathComponent("meeting.caf")
        let convert = Process()
        convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        convert.arguments = ["-f", "caff", "-d", "LEF32@48000", "-c", "2", wav.path, caf.path]
        try convert.run()
        convert.waitUntilExit()
        let data = try Data(contentsOf: caf)
        try data.prefix(data.count / 2).write(to: caf)

        XCTAssertThrowsError(try AudioLoader.load16kMono(url: caf))
    }

    /// A call where only the right channel carries sound must not load as silence.
    func testStereoRightChannelOnlyIsHeard() throws {
        try requireIntegration()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        let data = try XCTUnwrap(buffer.floatChannelData)
        for i in 0..<48_000 {
            data[0][i] = 0
            data[1][i] = 0.5 * sin(2 * .pi * 440 * Float(i) / 48_000)
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }

        let samples = try AudioLoader.load16kMono(url: url)
        XCTAssertEqual(samples.count, 16_000, accuracy: 50)
        let peak = samples.map(abs).max() ?? 0
        XCTAssertEqual(peak, 0.25, accuracy: 0.05)  // true average of 0 and 0.5
    }
}
