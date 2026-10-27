import CryptoKit
import Foundation

public enum NoteSectionsError: Error, Equatable, LocalizedError {
    case missingTranscriptMarkers

    public var errorDescription: String? {
        "Lyra couldn't find where the transcript starts and ends in this note (the lyra:transcript markers were removed), so it didn't change the note."
    }
}

/// The note's Lyra-owned transcript section: everything between the two marker lines. Text outside it is Aidan's.
///
/// In the file the lines sit in a folded Obsidian callout, so a two-hour transcript opens as one closed box under
/// the notes instead of a wall; to Lyra the body is always the plain lines (`fold`/`unfold`), so hashes recorded
/// before the fold still match, and a note written before it reads the same.
public enum NoteSections {
    static let start = "<!-- lyra:transcript:start -->\n"
    static let end = "\n<!-- lyra:transcript:end -->"
    static let foldHeader = "> [!quote]- Full transcript"

    /// The section body as plain lines, or nil when the markers are gone. The first end marker after the first
    /// start marker closes it; transcript text can't hold a marker because NoteRenderer escapes `<!--`.
    public static func transcriptBody(of note: String) -> String? {
        range(in: note).map { unfold(String(note[$0])) }
    }

    /// `note` with only the section body swapped (folded); every byte outside it is kept.
    public static func replaceTranscript(in note: String, with body: String) throws -> String {
        guard let r = range(in: note) else { throw NoteSectionsError.missingTranscriptMarkers }
        return note.replacingCharacters(in: r, with: fold(body))
    }

    /// Plain lines as the folded callout the file holds; nothing to fold stays empty.
    public static func fold(_ body: String) -> String {
        guard !body.isEmpty else { return "" }
        let quoted = body.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> " + $0 }
        return ([foldHeader] + quoted).joined(separator: "\n")
    }

    /// The callout's plain lines. A body without the callout (written before the fold) is already plain; a line
    /// Aidan added without the `>` (Obsidian lets that happen) is taken as it is.
    public static func unfold(_ body: String) -> String {
        var lines = body.components(separatedBy: "\n")
        guard lines.first?.hasPrefix("> [!") == true else { return body }
        lines.removeFirst()
        return lines.map { line in
            if line.hasPrefix("> ") { return String(line.dropFirst(2)) }
            if line.hasPrefix(">") { return String(line.dropFirst(1)) }
            return line
        }.joined(separator: "\n")
    }

    /// SHA-256 hex of the UTF-8 bytes.
    public static func hash(_ body: String) -> String {
        SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func range(in note: String) -> Range<String.Index>? {
        guard let s = note.range(of: start) else { return nil }
        guard let e = note.range(of: end, range: s.upperBound..<note.endIndex) else { return nil }
        return s.upperBound..<e.lowerBound
    }
}
