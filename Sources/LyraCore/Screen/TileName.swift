import Foundation

/// Turns the text on a call tile into a person's name, or nil. A wrong name is worse than none, so anything that
/// could be a device, a room, a button or a label is refused rather than guessed at.
public enum TileName {
    private static let maxWords = 4
    private static let minLetters = 3
    /// Lower-case words a name may contain ("Mary van Dyk", "Ali bin Said").
    private static let particles: Set<String> = ["van", "von", "de", "da", "del", "der", "di", "du", "le", "la", "bin", "binti", "al", "el", "ter", "den"]
    /// Words that mean the tile is a device, a room, a button or a status, not a person.
    private static let refused: Set<String> = [
        "iphone", "ipad", "macbook", "mac", "imac", "pro", "air", "galaxy", "pixel", "android", "samsung", "phone",
        "laptop", "desktop", "pc", "windows", "computer", "device", "camera", "display", "tv",
        "room", "boardroom", "conference", "meeting", "office", "studio", "hall", "zoom", "teams", "meet", "webex",
        "presentation", "presenting", "presenter", "screen", "sharing", "share", "shared", "whiteboard",
        "guest", "user", "admin", "host", "unknown", "anonymous", "you", "me", "participant", "participants", "everyone",
        "mute", "muted", "unmute", "chat", "record", "recording", "leave", "end", "more", "view", "gallery", "speaker",
        "reactions", "apps", "captions", "waiting", "joining", "connecting", "calling", "ringing", "audio", "video",
    ]

    /// The name in a tile label: "(Host)", "(she/her)" and "| Company" taken off. Nil unless it reads like a person.
    public static func clean(_ text: String) -> String? {
        var s = text.replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
        for separator in ["|", " - ", " – ", " — ", "•", ","] {
            if let r = s.range(of: separator) { s = String(s[..<r.lowerBound]) }
        }
        let words = s.split(whereSeparator: \.isWhitespace).map {
            $0.trimmingCharacters(in: CharacterSet.letters.inverted.subtracting(CharacterSet(charactersIn: "'’-.")))
        }.filter { !$0.isEmpty }
        guard (1...maxWords).contains(words.count) else { return nil }
        for word in words {
            let lower = word.lowercased()
            // "Aidan's" (from "Aidan's iPhone") is caught by its device word; the possessive alone isn't a name either.
            guard !refused.contains(lower), !lower.hasSuffix("'s"), !lower.hasSuffix("’s") else { return nil }
            guard word.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) || "'’-.".unicodeScalars.contains($0) }),
                  word.first?.isLetter == true else { return nil }
            guard word.first?.isUppercase == true || particles.contains(lower) else { return nil }
        }
        guard words.joined().filter(\.isLetter).count >= minLetters else { return nil }
        return words.joined(separator: " ")
    }

    /// The name label among a tile's text lines (`bottom`: 0 at the tile's top, 1 at its bottom). Apps put the
    /// label at the bottom, so the lowest line that reads like a name wins.
    public static func pick(_ lines: [(text: String, bottom: Double)]) -> String? {
        lines.sorted { $0.bottom > $1.bottom }.lazy.compactMap { clean($0.text) }.first
    }
}
