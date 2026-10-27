import XCTest
@testable import LyraCore

/// Opening a Bluetooth headset's mic drops it into call mode (low-quality audio in the ears), so Lyra records the
/// Mac's own mic instead whenever the default input is Bluetooth.
final class MicChoiceTests: XCTestCase {
    private let headphones = AudioInput(id: 81, transport: .bluetooth)
    private let macMic = AudioInput(id: 64, transport: .builtIn)
    private let interface = AudioInput(id: 90, transport: .other)

    func testBluetoothDefaultUsesTheMacsOwnMic() {
        XCTAssertEqual(MicChoice.device(defaultInput: headphones, inputs: [headphones, interface, macMic]), macMic.id)
    }

    func testAnyOtherDefaultIsLeftAlone() {
        XCTAssertNil(MicChoice.device(defaultInput: interface, inputs: [headphones, interface, macMic]))
        XCTAssertNil(MicChoice.device(defaultInput: macMic, inputs: [headphones, macMic]))
    }

    func testBluetoothWithNoBuiltInMicKeepsTheHeadset() {
        XCTAssertNil(MicChoice.device(defaultInput: headphones, inputs: [headphones, interface]))
    }

    func testNoDefaultIsLeftAlone() {
        XCTAssertNil(MicChoice.device(defaultInput: nil, inputs: [macMic]))
    }
}
