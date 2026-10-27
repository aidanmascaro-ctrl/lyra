import Foundation

public enum NoteRenderer {
    public static func render(meeting: Meeting, lines: [TranscriptLine], recordingsFolder: URL,
                              timeZone: TimeZone = .current) -> String {
        let front = NoteFrontmatter(lyraID: meeting.id, title: meeting.title, date: meeting.startedAt, app: meeting.appName,
                                    durationMin: durationMinutes(of: meeting), recordings: recordingsFolder)
        return NoteDocument(front: front, warnings: meeting.warnings, myNotes: "", expanded: "",
                            transcript: transcriptBody(lines: lines)).render(timeZone: timeZone)
    }

    /// Whole minutes recorded: the longest track, so paused time (and time in a New note before Record) is left
    /// out. Start to end when no track lengths were saved (or a crash lost them); 0 while the meeting is still being recorded.
    public static func durationMinutes(of meeting: Meeting) -> Int {
        guard let end = meeting.endedAt else { return 0 }
        // A recording recovered after a crash has no saved lengths (0): fall back to the clock.
        let seconds = meeting.tracks?.map(\.seconds).filter { $0 > 0 }.max()
            ?? end.timeIntervalSince(meeting.recordingStartedAt ?? meeting.startedAt)
        return max(0, Int((seconds / 60).rounded()))
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
