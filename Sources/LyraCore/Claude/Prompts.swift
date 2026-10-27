import Foundation

/// Everything Claude is told about one meeting.
public struct MeetingContext: Sendable {
    public var title: String
    public var myNotes: [NoteBlock]
    public var transcript: [TranscriptLine]
    /// Earlier meetings in the same series: context only, never edited.
    public var earlier: [EarlierMeeting]

    public init(title: String, myNotes: [NoteBlock], transcript: [TranscriptLine], earlier: [EarlierMeeting] = []) {
        self.title = title; self.myNotes = myNotes; self.transcript = transcript; self.earlier = earlier
    }
}

public struct EarlierMeeting: Sendable {
    public var title: String
    public var date: Date
    public var expanded: String
    public var transcript: String

    public init(title: String, date: Date, expanded: String, transcript: String) {
        self.title = title; self.date = date; self.expanded = expanded; self.transcript = transcript
    }
}

/// How much context goes to Claude, in characters.
public enum ContextBudget {
    public static let transcriptChars = 120_000
    public static let earlierChars = 40_000
    public static let earlierMeetings = 5
    public static let earlierExpandedChars = 8_000
}

/// Every prompt Lyra sends to Claude. Nothing else builds prompt text.
public enum Prompts {
    static let trimmedMarker = "[… trimmed …]"

    // MARK: Expanding (expand all, expand this, add an idea)

    public static let expandSystem = """
    You turn Aidan's meeting notes into fuller notes, using only what the meeting transcript and \
    his earlier meetings actually say. Aidan runs a small video and social media business in Perth, \
    Western Australia. His own notes are his words: you never repeat, reword or correct them — you \
    add detail under them, and add short sections for important things he didn't note.

    Your reply is read by a program, line by line. Reply with only these lines:
    @<n>              the bullets that follow go under note #n (one of Aidan's, unless told otherwise)
    @new <heading>    a new section for something important he didn't note
    - <bullet>        one point; indent two spaces per level for a sub-point (two levels at most)

    No preamble, no closing remarks, no code fences, no other formatting. **bold** is allowed \
    inside a bullet for a key figure or decision; nothing else.

    Before you write, silently check yourself: list the ways your notes could go wrong — a detail \
    the transcript doesn't support, a misheard or misspelled name, a point under the wrong note, \
    repeating what Aidan already wrote, padding — and avoid each one. Never write that check down.
    """

    public static func expandUser(ctx: MeetingContext) -> String {
        let task = ctx.myNotes.contains(where: isNumbered)
            ? """
              Expand Aidan's notes from the transcript. Write at least one @<n> group for every one of \
              Aidan's numbered notes (not the lines marked as added by you earlier), and put the useful \
              detail under it: decisions, numbers, dates, who is doing what, and the reasons given. A \
              short note that reads like a heading or label (for example "discovery call / meeting") \
              still gets its group: give a one-line summary of what the meeting said about that topic. \
              If the meeting truly says nothing more about a note, write one bullet saying so. Then, for \
              important things the meeting covered that none of his notes touch, write @new sections \
              (for example decisions, action items, open questions). Go in the order of his notes.
              """
            : """
              Aidan took no notes in this meeting. Write the notes from the transcript as @new \
              sections, in the order the meeting covered them: what was discussed, decisions, action \
              items with who owns them, and open questions. Don't use @<n>.
              """
        return compose(ctx: ctx, notes: ctx.myNotes, task: task)
    }

    public static func expandThisUser(selection: String, block: Int, in blocks: [NoteBlock], ctx: MeetingContext) -> String {
        let task = """
        Aidan highlighted this in note #\(block) and asked for more detail:
        <selection>\(selection)</selection>
        Write @\(block) and then new detail from the transcript about it — specifics not already in \
        the notes. Use only @\(block); nothing else will be kept. If the transcript says nothing more about it, \
        write one bullet saying so.
        """
        return compose(ctx: ctx, notes: blocks, task: task)
    }

    public static func injectUser(idea: String, into blocks: [NoteBlock], ctx: MeetingContext) -> String {
        let task = """
        Aidan wants this worked into the notes:
        <idea>\(idea)</idea>
        Usually that means one @new section after everything else. If it plainly belongs under one of \
        Aidan's own notes, use @<n> instead (not a line marked as added by you). Ground it in what the meeting and earlier meetings \
        said; where they say nothing on it, keep to what Aidan asked and don't fill gaps with guesses.
        """
        return compose(ctx: ctx, notes: blocks, task: task)
    }

    // MARK: Asking

    public static let askSystem = """
    You answer Aidan's questions about one of his meetings, using only the transcript, his notes and \
    his earlier meetings. Aidan runs a small video and social media business in Perth, Western \
    Australia.

    Answer in 2 to 6 plain sentences: no headings, bullets, markdown or preamble. Use people's names \
    as the transcript gives them, and Australian spelling. If the meeting doesn't answer the \
    question, say so plainly and say what it did cover that's closest.

    Before you answer, silently check whether each claim is actually in the transcript or notes, \
    and drop any that isn't. Never write that check down.
    """

    public static func askUser(question: String, selection: String?, ctx: MeetingContext) -> String {
        var task = "Aidan asks: \(question)"
        if let selection, !selection.isEmpty {
            task += "\nHe's asking about this part of the notes:\n<selection>\(selection)</selection>"
        }
        return compose(ctx: ctx, notes: ctx.myNotes, task: task, constraints: askConstraints)
    }

    // MARK: Insights (title, tags, links, series, one-liner)

    static let insightsHeadChars = 15_000
    static let insightsTailChars = 5_000

    public static let insightsSystem = """
    You file one finished meeting for Aidan, who runs a small video and social media business in \
    Perth, Western Australia. From the meeting window's title, text read off the screen, the \
    transcript and his notes, you choose a clear title, topic tags, which of his clients it relates \
    to, whether it belongs to a series, and a one-line summary.

    Your reply is read by a program. Reply with only one JSON object, no code fence and no other \
    text, shaped exactly like this:
    {"title": "...", "tags": ["..."], "clients": ["..."], "series": "..." or null, "summary": "..."}

    Before you answer, silently check yourself: list the ways your answer could be wrong — a title \
    that is vague or only repeats a generic window name, a tag that is too broad or invented, a \
    client the meeting wasn't really about, a new series name when an existing one fits, a summary \
    that claims more than the transcript says — and fix each one. Never write that check down.
    """

    public static func insightsUser(input: InsightsInput) -> String {
        let screen = input.screenText.isEmpty ? "(Nothing read.)" : input.screenText.joined(separator: "\n")
        let series = input.existingSeries.keys.sorted().map { name -> String in
            let recent = (input.existingSeries[name] ?? []).map { "  - \($0)" }.joined(separator: "\n")
            return recent.isEmpty ? "- \(name)" : "- \(name)\n\(recent)"
        }.joined(separator: "\n")
        let notes = input.myNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        <meeting>\(input.windowTitle)</meeting>

        <screen_text>
        \(screen)
        </screen_text>

        <my_notes>
        \(notes.isEmpty ? "(Aidan took no notes.)" : notes)
        </my_notes>

        <transcript>
        \(insightsTranscript(input.transcript))
        </transcript>

        <existing_series>
        \(series.isEmpty ? "(None.)" : series)
        </existing_series>

        <known_tags>\(input.knownTags.joined(separator: ", "))</known_tags>
        <clients>\(input.clients.joined(separator: ", "))</clients>
        <people>\(input.people.joined(separator: ", "))</people>

        <task>
        Work out the details of this meeting:
        - title: a specific title of 3 to 80 characters. If the window title already names the meeting \
        well (for example a workshop name), keep it; if it is generic ("Google Meet", "Zoom Meeting"), \
        write a better one from the content.
        - tags: up to 6 lowercase, hyphenated topic tags (for example content-strategy). Reuse a known \
        tag whenever one fits.
        - clients: names from <clients> that this meeting is about, spelt exactly as listed. Empty if none.
        - series: if the meeting is one of a recurring set, the series name. Use an existing series \
        name exactly when the meeting plainly belongs to it (a title like "<series> | Workshop 2" belongs \
        to the series "<series>"); otherwise a short new name, or null when it is a one-off.
        - summary: one plain sentence of 140 characters or fewer saying what the meeting was about, \
        for a series page.
        </task>

        <constraints>
        - Only what the title, screen text, transcript and notes support; no invented clients or topics.
        - Australian spelling.
        - Output only the JSON object.
        </constraints>
        """
    }

    /// The opening and the end of the meeting: titles and series need the start, so the middle goes first.
    static func insightsTranscript(_ lines: [TranscriptLine]) -> String {
        guard !lines.isEmpty else { return "(No transcript.)" }
        let formatted = lines.map { "[\(timestamp($0.start))] \($0.speakerLabel): \($0.text)" }
        let total = formatted.reduce(0) { $0 + $1.count + 1 }
        guard total > insightsHeadChars + insightsTailChars else { return formatted.joined(separator: "\n") }
        let head = fitting(formatted, within: insightsHeadChars)
        let tail = Array(fitting(formatted[head.count...].reversed(), within: insightsTailChars).reversed())
        return (head + [trimmedMarker] + tail).joined(separator: "\n")
    }

    // MARK: Building blocks

    private static let expandConstraints = """
    - Never repeat, reword or correct Aidan's lines; only add beneath them.
    - Use people's names exactly as the transcript gives them; "Speaker 2" stays "Speaker 2".
    - Australian spelling (organise, colour, programme for a TV programme, licence as a noun).
    - No invented facts: every point must be supported by the transcript or the earlier meetings. \
    Earlier meetings are background only; don't attribute what was said there to this meeting.
    - Each bullet 25 words or fewer, one idea per bullet, plain and specific.
    - Output only the line protocol: @<n>, @new <heading>, and - bullets.
    """

    private static let askConstraints = """
    - Use people's names exactly as the transcript gives them.
    - Australian spelling.
    - No invented facts: only what the transcript, the notes or the earlier meetings support.
    - 2 to 6 plain sentences.
    """

    private static func compose(ctx: MeetingContext, notes: [NoteBlock], task: String,
                                constraints: String = expandConstraints) -> String {
        """
        <meeting>\(ctx.title)</meeting>

        <my_notes>
        \(numberedNotes(notes))
        </my_notes>

        <transcript>
        \(transcript(ctx.transcript))
        </transcript>

        <earlier_meetings>
        \(earlierMeetings(ctx.earlier))
        </earlier_meetings>

        <task>
        \(task)
        </task>

        <constraints>
        \(constraints)
        </constraints>
        """
    }

    private static func isNumbered(_ block: NoteBlock) -> Bool {
        !block.byClaude && !block.plainText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Every line as `#n <markdown>`, Claude's earlier additions marked as such.
    static func numberedNotes(_ blocks: [NoteBlock]) -> String {
        let lines = blocks.enumerated().compactMap { index, block -> String? in
            guard !block.plainText.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            var plain = block
            plain.byClaude = false
            let text = NoteMarkdown.render([plain])
            return block.byClaude ? "#\(index) (added by you earlier) \(text)" : "#\(index) \(text)"
        }
        return lines.isEmpty ? "(Aidan took no notes.)" : lines.joined(separator: "\n")
    }

    static func transcript(_ lines: [TranscriptLine]) -> String {
        guard !lines.isEmpty else { return "(No transcript.)" }
        let formatted = lines.map { "[\(timestamp($0.start))] \($0.speakerLabel): \($0.text)" }
        return trimMiddle(formatted, to: ContextBudget.transcriptChars).joined(separator: "\n")
    }

    /// Newest first. Expanded notes take the budget before any transcript does.
    static func earlierMeetings(_ meetings: [EarlierMeeting]) -> String {
        let recent = meetings.sorted { $0.date > $1.date }.prefix(ContextBudget.earlierMeetings)
        guard !recent.isEmpty else { return "(None.)" }
        var left = ContextBudget.earlierChars
        let notes = recent.map { meeting -> String in
            let cut = String(meeting.expanded.prefix(min(ContextBudget.earlierExpandedChars, max(left, 0))))
            left -= cut.count
            return cut.count < meeting.expanded.count ? cut + "\n" + trimmedMarker : cut
        }
        let transcripts = recent.map { meeting -> String in
            guard left > 0 else { return "" }
            let lines = trimMiddle(meeting.transcript.components(separatedBy: "\n"), to: left)
            let text = lines.joined(separator: "\n")
            left -= text.count
            return text
        }
        return zip(recent, zip(notes, transcripts)).map { meeting, parts in
            """
            <earlier_meeting title="\(meeting.title)" date="\(day(meeting.date))">
            <expanded_notes>
            \(parts.0)
            </expanded_notes>
            <transcript>
            \(parts.1)
            </transcript>
            </earlier_meeting>
            """
        }.joined(separator: "\n")
    }

    /// Keeps the start and end of the meeting and cuts the middle. A single over-long line is cut too.
    static func trimMiddle(_ lines: [String], to budget: Int) -> [String] {
        let total = lines.reduce(0) { $0 + $1.count + 1 }
        guard total > budget else { return lines }
        let half = max((budget - trimmedMarker.count) / 2, 0)
        let head = fitting(lines, within: half)
        let tail = Array(fitting(lines[head.count...].reversed(), within: half).reversed())
        if head.isEmpty && tail.isEmpty, let first = lines.first { return [String(first.prefix(half)), trimmedMarker] }
        return head + [trimmedMarker] + tail
    }

    /// The leading lines that fit in `budget`, stopping at the first that doesn't.
    private static func fitting<S: Sequence<String>>(_ lines: S, within budget: Int) -> [String] {
        var kept: [String] = []
        var used = 0
        for line in lines {
            guard used + line.count + 1 <= budget else { break }
            kept.append(line)
            used += line.count + 1
        }
        return kept
    }

    private static func timestamp(_ seconds: Double) -> String {
        let total = max(Int(seconds), 0)
        return String(format: "%02d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
