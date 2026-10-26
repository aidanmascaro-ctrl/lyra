import Foundation

public enum NoteRenderer {
    public static func render(meeting: Meeting, lines: [TranscriptLine], recordingsFolder: URL,
                              timeZone: TimeZone = .current) -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = timeZone
        iso.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        let minutes = meeting.endedAt.map { max(0, Int((($0.timeIntervalSince(meeting.startedAt)) / 60).rounded())) } ?? 0
        let warnings = meeting.warnings.map { "> [!warning] \($0)\n" }.joined(separator: "\n")
        let transcript = transcriptBody(lines: lines)
        return """
        ---
        lyra_id: \(meeting.id.uuidString)
        date: \(iso.string(from: meeting.startedAt))
        app: "\(meeting.appName.replacingOccurrences(of: "\"", with: "\\\""))"
        duration_min: \(minutes)
        recordings: "\(recordingsFolder.absoluteString)"
        tags: [meeting]
        ---
        # \(meeting.title)

        \(warnings.isEmpty ? "" : warnings + "\n")## Notes
        <!-- lyra:notes:start -->
        <!-- lyra:notes:end -->

        ## Transcript
        <!-- lyra:transcript:start -->
        \(transcript)
        <!-- lyra:transcript:end -->

        """
    }

    /// What goes between the lyra transcript markers. Rename re-renders the section with this, so both paths share one format.
    public static func transcriptBody(lines: [TranscriptLine]) -> String {
        lines.map { line in
            let badge = line.nameSource == .knownVoice ? " _(known voice)_" : ""
            return "**\(escapeName(line.speakerLabel))**\(badge) [\(stamp(line.start))] \(line.text.replacingOccurrences(of: "<!--", with: "&lt;!--"))"
        }.joined(separator: "\n\n")
    }

    /// Backslash-escapes what would break the bold or start a link/tag; a newline would end the line, so it becomes a space.
    private static func escapeName(_ name: String) -> String {
        var out = ""
        // `<!--` first, as in transcript text, so a name can't spoof the lyra markers.
        for ch in name.replacingOccurrences(of: "<!--", with: "&lt;!--") {
            if ch.isNewline { out.append(" "); continue }
            if "\\*_`[]<".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    private static func stamp(_ t: Double) -> String {
        let s = t.isFinite ? Int(max(0, t)) : 0
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
}
