import Foundation

/// Problem messages in the shape each place needs: one plain sentence for the full text, one short line for the menu.
public enum ErrorBrief {
    public static let menuLimit = 60
    public static let signedOutShort = "Claude needs you to sign in again"
    private static let nestedMarker = "Claude couldn't"

    /// One sentence for a failure while doing something. Errors that already say what Claude couldn't do
    /// (`ClaudeError`) stand alone, so there is never "Claude couldn't…: Claude couldn't answer: …".
    public static func sentence(_ prefix: String, _ error: Error) -> String {
        let text = error.localizedDescription
        return error is ClaudeError || text.hasPrefix(nestedMarker) ? text : "\(prefix): \(text)"
    }

    /// At most `menuLimit` characters on one line: the latest problem only, sign-in problems in short form.
    public static func menuLine(_ message: String) -> String {
        let latest = message.split(whereSeparator: \.isNewline).last.map(String.init) ?? message
        let lower = latest.lowercased()
        if lower.contains("sign in again") || ClaudeError.classify(latest) == .signedOut { return signedOutShort }
        var line = latest
        if let last = line.range(of: nestedMarker, options: .backwards) { line = String(line[last.lowerBound...]) }
        line = line.trimmingCharacters(in: .whitespaces)
        return line.count <= menuLimit ? line : String(line.prefix(menuLimit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
