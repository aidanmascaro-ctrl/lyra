import AVFoundation
import CoreAudio
import LyraCore

/// The Mac's audio input devices, read from Core Audio for `MicChoice`.
enum AudioInputs {
    /// The mic to record instead of the default input, as a capture device, or nil to record the default.
    static func chosenCaptureDevice() -> AVCaptureDevice? {
        guard let device = chosenDevice(), let uid = CoreAudioObject.string(device, kAudioDevicePropertyDeviceUID) else { return nil }
        return AVCaptureDevice(uniqueID: uid)
    }

    /// The device Lyra should record instead of the default input, or nil to record the default.
    static func chosenDevice() -> AudioDeviceID? {
        let inputs = all()
        let defaultID: AudioDeviceID? = CoreAudioObject.scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)
        return MicChoice.device(defaultInput: inputs.first { $0.id == defaultID }, inputs: inputs)
    }

    private static func all() -> [AudioInput] {
        var addr = CoreAudioObject.address(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter(hasInput).map { AudioInput(id: $0, transport: transport(of: $0)) }
    }

    private static func hasInput(_ device: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func transport(of device: AudioDeviceID) -> AudioInput.Transport {
        let type: UInt32? = CoreAudioObject.scalar(device, kAudioDevicePropertyTransportType)
        switch type {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        default: return .other
        }
    }
}
