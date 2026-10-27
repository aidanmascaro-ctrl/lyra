import AVFoundation
@testable import LyraAudio
import LyraCore
@testable import LyraSpeech
import XCTest

final class LiveTranscriptTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// The recorders' own writer, fed from another thread at real-time pace, never closed while read:
    /// each read sees the frames written since the last one, and they are the real samples, not zeros.
    func testReadsFramesWhileFileIsBeingWritten() async throws {
        try requireIntegration()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let writer = try CAFWriter(url: folder.appendingPathComponent("mic.caf"), format: format.streamDescription.pointee)
        let tone = try Self.toneBuffer(format: format, frames: 4096)
        let writing = Task.detached {
            while !Task.isCancelled {
                writer.write(tone.audioBufferList, hostTime: 0)
                try? await Task.sleep(for: .milliseconds(85))  // ~4096 frames at 48 kHz
            }
        }
        defer { writing.cancel() }

        let reader = GrowingCAFReader(url: folder.appendingPathComponent("mic.caf"))
        try await Task.sleep(for: .seconds(1))
        let first = try reader.readNew()
        try await Task.sleep(for: .seconds(1))
        let second = try XCTUnwrap(try reader.readNew(), "no new frames while the file is still being written")
        print("growing: first=\(first?.frameLength ?? 0) second=\(second.frameLength) written=\(writer.seconds * 48_000)")
        XCTAssertGreaterThan(second.frameLength, 0)
        XCTAssertGreaterThan(Self.peak(second), 0.3)

        writing.cancel()
        _ = await writing.value
        let result = writer.finish(kind: .mic)
        XCTAssertNil(result.error)
        // Reading alongside the writer cost the recording nothing: every frame written is in the closed file.
        let closed = try AVAudioFile(forReading: folder.appendingPathComponent("mic.caf"))
        XCTAssertEqual(Double(closed.length), result.seconds * 48_000)
    }

    /// The fixture streamed into a growing CAF a little faster than real time comes out as live text.
    func testLiveTranscribesFixtureSpeech() async throws {
        try requireIntegration()
        let wav = try XCTUnwrap(Bundle.module.url(
            forResource: "speaker-test-3-voices", withExtension: "wav", subdirectory: "Fixtures"))
        let source = try AVAudioFile(forReading: wav)
        let format = source.processingFormat
        let writer = try CAFWriter(url: folder.appendingPathComponent("meeting.caf"), format: format.streamDescription.pointee)
        let chunkFrames = AVAudioFrameCount(format.sampleRate / 2)
        var chunks: [AVAudioPCMBuffer] = []
        while source.framePosition < source.length {
            let chunk = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames))
            try source.read(into: chunk, frameCount: chunkFrames)
            chunks.append(chunk)
        }
        let feed = chunks

        let live = LiveTranscriber(folder: folder, tracks: [.meeting])
        try await live.start()
        let writing = Task.detached {
            for chunk in feed {
                guard !Task.isCancelled else { return }
                writer.write(chunk.audioBufferList, hostTime: 0)
                try? await Task.sleep(for: .milliseconds(100))  // 5x real time
            }
        }
        let collecting = Task {
            var lines = LiveLines()
            for await (track, text, isFinal) in live.updates {
                lines.apply(track: track, text: text, isFinal: isFinal)
                let all = lines.lines.map(\.text).joined(separator: " ").lowercased()
                print("live: [\(track.rawValue)\(isFinal ? " final" : "")] \(text)")
                if all.contains("friday") { return all }
            }
            return lines.lines.map(\.text).joined(separator: " ").lowercased()
        }
        let timeout = Task {
            try await Task.sleep(for: .seconds(90))
            collecting.cancel()
        }
        let text = await collecting.value
        timeout.cancel()
        await live.stop()
        _ = await writing.value
        XCTAssertNil(writer.finish(kind: .meeting).error)
        XCTAssertTrue(text.contains("friday"), text)
    }

    /// Mirrors FluidAudio's two tiers: unconfirmed windows extend the open line; a confirmed window
    /// closes the open line and starts a new one with its own text.
    func testWindowUpdatesBecomeOpenAndClosedLines() {
        var tail = LiveTail()
        XCTAssertEqual(tail.receive(text: "so the shoot", confirmed: false).map { $0.text }, ["so the shoot"])
        XCTAssertEqual(tail.receive(text: "is on friday", confirmed: false).map { $0.text }, ["so the shoot is on friday"])
        XCTAssertTrue(tail.receive(text: "", confirmed: false).isEmpty)
        let confirmed = tail.receive(text: "bring the gear list", confirmed: true)
        XCTAssertEqual(confirmed.map { $0.text }, ["so the shoot is on friday", "bring the gear list"])
        XCTAssertEqual(confirmed.map { $0.isFinal }, [true, false])
        XCTAssertEqual(tail.receive(text: "", confirmed: true).map { $0.isFinal }, [true])
        XCTAssertTrue(tail.receive(text: "", confirmed: true).isEmpty)
    }

    private static func toneBuffer(format: AVAudioFormat, frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try XCTUnwrap(buffer.floatChannelData)
        for c in 0..<Int(format.channelCount) {
            for i in 0..<Int(frames) { data[c][i] = 0.5 * sin(2 * .pi * 440 * Float(i) / Float(format.sampleRate)) }
        }
        return buffer
    }

    private static func peak(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        return (0..<Int(buffer.frameLength)).reduce(0) { max($0, abs(data[0][$1])) }
    }
}
