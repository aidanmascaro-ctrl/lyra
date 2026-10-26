import CoreAudio
import Foundation

struct AudioError: Error, CustomStringConvertible {
    let description: String
}

/// Throws `AudioError` naming the step and the OSStatus when `status` is not noErr.
func check(_ status: OSStatus, _ step: String) throws {
    guard status == noErr else { throw AudioError(description: "\(step) failed (OSStatus \(status))") }
}

/// Small typed readers over Core Audio object properties (global scope, main element).
enum CoreAudioObject {
    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    /// Every Core Audio process object (one per process that has touched audio).
    static func processObjects() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func value<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) -> T? {
        var addr = address(selector)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func scalar<T: FixedWidthInteger & BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        value(object, selector, initial: 0)
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ref) == noErr else { return nil }
        return ref?.takeRetainedValue() as String?
    }
}
