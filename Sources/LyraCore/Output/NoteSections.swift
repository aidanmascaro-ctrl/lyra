import CryptoKit
import Foundation

public enum NoteSectionsError: Error, Equatable, LocalizedError {
    case missingTranscriptMarkers

    public var errorDescription: String? {
        "Lyra couldn't find where the transcript starts and ends in this note (the lyra:transcript markers were removed), so it didn't change the note."
    }
}

/// The note's Lyra-owned transcript section: everything between the two marker lines. Text outside it is Aidan's.
public enum NoteSections {
    static let start = "<!-- lyra:transcript:start -->\n"
    static let end = "\n<!-- lyra:transcript:end -->"

    /// The section body, or nil when the markers are gone. The first end marker after the first start marker
    /// closes it; transcript text can't hold a marker because NoteRenderer escapes `<!--`.
    public static func transcriptBody(of note: String) -> String? {
        range(in: note).map { String(note[$0]) }
    }

    /// `note` with only the section body swapped; every byte outside it is kept.
    public static func replaceTranscript(in note: String, with body: String) throws -> String {
        guard let r = range(in: note) else { throw NoteSectionsError.missingTranscriptMarkers }
        return note.replacingCharacters(in: r, with: body)
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
