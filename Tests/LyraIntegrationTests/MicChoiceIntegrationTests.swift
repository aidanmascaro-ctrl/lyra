import AVFoundation
import XCTest
@testable import LyraAudio

/// On this Mac as set up now: with a Bluetooth headset as the default input, the mic track is recorded from the
/// Mac's own mic, and it still records sound.
final class MicChoiceIntegrationTests: XCTestCase {
    func testBluetoothDefaultRecordsTheMacsOwnMic() async throws {
        try requireIntegration()
        guard AudioInputs.chosenCaptureDevice() != nil else { throw XCTSkip("default input isn't Bluetooth here") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mic-choice-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = MicRecorder()
        try recorder.start(writingTo: url)
        XCTAssertNotNil(recorder.deviceSession)
        XCTAssertNil(recorder.session)
        try await Task.sleep(for: .seconds(2))
        let result = await recorder.stop()
        XCTAssertNil(result.error)
        XCTAssertEqual(result.seconds, 2, accuracy: 0.5)
        XCTAssertGreaterThan(result.peakLevel, 0)
    }
}
