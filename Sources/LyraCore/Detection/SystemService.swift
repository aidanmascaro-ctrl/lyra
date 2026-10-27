import Foundation

/// macOS's own background services (dictation, Siri, speech recognition) use the mic but are never meetings.
/// Real apps live in /Applications or /System/Applications; FaceTime's call daemon is in /usr/libexec.
public enum SystemService {
    public static func isBackground(executablePath: String?) -> Bool {
        executablePath?.hasPrefix("/System/Library/") ?? false
    }
}
