import CoreGraphics
import Foundation

/// Reads the words on a meeting's call window (slide titles, workshop names) so Claude can name the meeting.
/// The screenshot lives in memory only and is never written anywhere.
public enum ScreenText {
    /// Lines of text in reading order, or [] without Screen Recording permission, without a call window, or on any failure.
    public static func read(pid: pid_t, startTitle: String) async -> [String] {
        guard let image = await CallWindow.frame(pid: pid, startTitle: startTitle) else { return [] }
        return CallWindow.lines(in: image).map(\.text)
    }
}
