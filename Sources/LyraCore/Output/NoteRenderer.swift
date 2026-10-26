import Foundation

public enum NoteRenderer {
    public static func render(meeting: Meeting, lines: [TranscriptLine], recordingsFolder: URL,
                              timeZone: TimeZone = .current) -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = timeZone
        iso.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        let minutes = meeting.endedAt.map { max(0, Int((($0.timeIntervalSince(meeting.startedAt)) / 60).rounded())) } ?? 0
        let warnings = meeting.warnings.map { "> [!warning] \($0)\n" }.joined(separator: "\n")
        let transcript = lines.map { "**\($0.speakerLabel)** [\(stamp($0.start))] \($0.text.replacingOccurrences(of: "<!--", with: "&lt;!--"))" }.joined(separator: "\n\n")
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

    private static func stamp(_ t: Double) -> String {
        let s = t.isFinite ? Int(max(0, t)) : 0
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
}
