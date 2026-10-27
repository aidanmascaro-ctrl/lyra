import Foundation

/// macOS's own background services (dictation, Siri, speech recognition, screen capture) use the mic but are never
/// meetings. Real apps live in /Applications or /System/Applications; FaceTime's call daemon is in /usr/libexec, so
/// only named services there are left out.
public enum SystemService {
    /// replayd runs screen capture: Lyra's own screen text, screenshots and screen recordings.
    private static let backgroundDaemons: Set<String> = ["/usr/libexec/replayd"]

    public static func isBackground(executablePath: String?) -> Bool {
        guard let executablePath else { return false }
        return executablePath.hasPrefix("/System/Library/") || backgroundDaemons.contains(executablePath)
    }
}
