import AVFoundation
import LyraAudio
import XCTest

final class MicUsageTests: XCTestCase {
    func testSeesOwnEngine() async throws {
        try requireIntegration()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { _, _ in }
        try engine.start()
        defer { engine.stop(); input.removeTap(onBus: 0) }

        let me = ProcessInfo.processInfo.processIdentifier
        var seen: [Int32] = []
        for _ in 0..<20 {
            seen = CoreAudioMicUsage().currentMicUsers().map(\.pid)
            if seen.contains(me) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(seen.contains(me), "pid \(me) not in mic users \(seen)")
    }
}
