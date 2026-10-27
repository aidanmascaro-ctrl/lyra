import Foundation

/// An audio input device, as far as choosing the mic goes.
public struct AudioInput: Equatable, Sendable {
    public enum Transport: Sendable { case builtIn, bluetooth, other }

    public let id: UInt32
    public let transport: Transport

    public init(id: UInt32, transport: Transport) {
        self.id = id
        self.transport = transport
    }
}

/// Which mic Lyra records. Opening a Bluetooth headset's mic switches it into call mode, which makes whatever is
/// playing in the ears sound tinny for as long as Lyra records, so a Bluetooth default is swapped for the Mac's own
/// mic. Any other default — a USB mic, an audio interface, the Mac's mic — is what Aidan chose and is used as is.
public enum MicChoice {
    /// The device to record instead of the default, or nil to record the default.
    public static func device(defaultInput: AudioInput?, inputs: [AudioInput]) -> UInt32? {
        guard defaultInput?.transport == .bluetooth else { return nil }
        return inputs.first { $0.transport == .builtIn }?.id
    }
}
