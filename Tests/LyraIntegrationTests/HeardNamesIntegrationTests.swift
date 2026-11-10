import XCTest
import LyraCore

/// Real Claude, naming voices from the conversation. Reads only; never writes.
final class HeardNamesIntegrationTests: XCTestCase {
    /// A made-up meeting: one self-introduction, one person spoken to by name, one voice nobody names.
    func testRealClaudeNamesOnlyWhatTheTranscriptShows() async throws {
        try requireIntegration()
        func line(_ label: String, _ text: String, _ t: Double) -> TranscriptLine {
            TranscriptLine(speakerLabel: label, track: .meeting, start: t, end: t + 4, text: text)
        }
        let lines = [
            line("Speaker 1", "Morning all. Let's do quick intros. I'm Dana, I run the workshop.", 0),
            line("Speaker 2", "Hi, I'm Felix, I do kitchen renovations.", 6),
            line("Speaker 1", "Thanks, Felix. Ruth, do you want to go next?", 12),
            line("Speaker 3", "Sure. I run a dog grooming van, mostly in the hills.", 18),
            line("Speaker 4", "Sorry, my camera's not working today.", 24),
            line("Speaker 1", "No worries. Felix mentioned Marco sent him the template earlier.", 30),
        ]
        let names = try await HeardNamesService.run(lines: lines, screenText: [], people: [], claude: ClaudeCLI())
        for n in names { print("\(n.speaker) → \(n.name) (sure: \(n.sure)) \(n.evidence)") }
        let byLabel = Dictionary(uniqueKeysWithValues: names.map { ($0.speaker, $0.name) })
        XCTAssertEqual(byLabel["Speaker 1"], "Dana")
        XCTAssertEqual(byLabel["Speaker 2"], "Felix")
        XCTAssertNil(byLabel["Speaker 4"])
        XCTAssertFalse(names.contains { $0.name == "Marco" })  // only talked about
    }

    /// Set LYRA_HEARD_NAMES_FOLDER to a scratch copy of a recording folder (transcript.json + meeting.json) to see
    /// what Claude would name there. Prints only, unless LYRA_HEARD_NAMES_NOTE also names a scratch copy of its note:
    /// then the full step runs and writes into those copies. Never point either at real files.
    func testRealClaudeOnARecordingFolderCopy() async throws {
        try requireIntegration()
        let env = ProcessInfo.processInfo.environment
        guard let path = env["LYRA_HEARD_NAMES_FOLDER"] else {
            throw XCTSkip("set LYRA_HEARD_NAMES_FOLDER to a scratch copy of a recording folder")
        }
        let folder = URL(fileURLWithPath: path)
        if let note = env["LYRA_HEARD_NAMES_NOTE"] {
            let outcome = try await TalkNamer(claude: ClaudeCLI()).run(folder: folder, note: URL(fileURLWithPath: note))
            for n in outcome.names { print("WROTE \(n.speaker) → \(n.name) sure=\(n.sure)") }
            print("WROTE note: \(outcome.note)")
            return
        }
        let lines = try JSONDecoder().decode([TranscriptLine].self, from: Data(contentsOf: folder.appendingPathComponent("transcript.json")))
        let meeting = try Meeting.load(from: folder)
        let names = try await HeardNamesService.run(lines: lines, screenText: meeting.screenText ?? [], people: [], claude: ClaudeCLI())
        print("HEARD \(names.count) of \(HeardNames.placeholders(in: lines).count) unnamed voices")
        for n in names { print("HEARD \(n.speaker) → \(n.name) sure=\(n.sure) | " + n.evidence.joined(separator: " | ")) }
    }
}
