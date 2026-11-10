import XCTest
@testable import LyraCore

private final class FakeClaude: ClaudeRunning, @unchecked Sendable {
    let reply: String
    var calls: [(system: String, prompt: String)] = []
    init(_ reply: String) { self.reply = reply }
    func stream(system: String, prompt: String, model: String) -> AsyncThrowingStream<String, Error> {
        calls.append((system, prompt))
        let reply = reply
        return AsyncThrowingStream { $0.yield(reply); $0.finish() }
    }
}

final class HeardNamesTests: XCTestCase {
    // Made-up meeting: Aidan (known voice), Speaker 1 introduces herself, Speaker 2 is spoken to by name.
    private func line(_ label: String, _ text: String, at start: Double, source: NameSource? = nil) -> TranscriptLine {
        var l = TranscriptLine(speakerLabel: label, speakerID: "meeting:\(label)", track: .meeting,
                               start: start, end: start + 4, text: text)
        l.nameSource = source
        if source != nil { l.personID = UUID() }
        return l
    }

    private var lines: [TranscriptLine] {
        [
            line("Aidan", "Welcome everyone, let's go round the room.", at: 0, source: .knownVoice),
            line("Speaker 1", "Hi all, I'm Priya, I run a bakery in Northbridge.", at: 5),
            line("Aidan", "Thanks, Priya. Tomas, what about you?", at: 10, source: .knownVoice),
            line("Speaker 2", "Yeah, I do landscaping, mostly residential.", at: 15),
            line("Speaker 3", "Can everyone hear me okay, Aidan?", at: 20),
        ]
    }

    private func reply(_ entries: String) -> String { #"{"speakers": [\#(entries)]}"# }

    // MARK: Parsing and checks

    func testKeepsANameWithARealQuote() throws {
        let json = reply(#"{"speaker": "Speaker 1", "name": "Priya", "sure": true, "evidence": ["I'm Priya, I run a bakery"]}"#)
        let names = try HeardNames.parse(json, lines: lines)
        XCTAssertEqual(names, [HeardName(speaker: "Speaker 1", name: "Priya", sure: true, evidence: ["I'm Priya, I run a bakery"])])
    }

    func testQuoteMatchIgnoresCaseSpacingAndPunctuation() throws {
        let json = reply(#"{"speaker": "Speaker 2", "name": "Tomas", "sure": true, "evidence": ["thanks priya   tomas WHAT about you"]}"#)
        XCTAssertEqual(try HeardNames.parse(json, lines: lines).map(\.name), ["Tomas"])
    }

    func testDropsANameWhoseQuoteIsNotInTheTranscript() throws {
        let json = reply(#"{"speaker": "Speaker 3", "name": "Marco", "sure": true, "evidence": ["Marco, can you hear us?"]}"#)
        XCTAssertEqual(try HeardNames.parse(json, lines: lines), [])
    }

    func testDropsAQuoteThatDoesNotMentionTheName() throws {
        // A real line, but it says nothing about who Speaker 3 is.
        let json = reply(#"{"speaker": "Speaker 3", "name": "Marco", "sure": true, "evidence": ["Can everyone hear me okay?"]}"#)
        XCTAssertEqual(try HeardNames.parse(json, lines: lines), [])
    }

    func testDropsANameWithNoEvidence() throws {
        let json = reply(#"{"speaker": "Speaker 1", "name": "Priya", "sure": true, "evidence": []}"#)
        XCTAssertEqual(try HeardNames.parse(json, lines: lines), [])
    }

    func testOnlyPlaceholderSpeakersCanBeNamed() throws {
        let json = reply(#"{"speaker": "Aidan", "name": "Priya", "sure": true, "evidence": ["I'm Priya"]}"#)
        XCTAssertEqual(try HeardNames.parse(json, lines: lines), [])
    }

    func testNeverGivesANameAlreadyOnAnotherSpeaker() throws {
        // A real quote that does mention the name: only the "already taken" rule can drop it.
        let json = reply(#"{"speaker": "Speaker 3", "name": "aidan", "sure": true, "evidence": ["hear me okay, Aidan"]}"#)
        XCTAssertEqual(try HeardNames.parse(json, lines: lines), [])
    }

    func testRejectsPlaceholderBlankAndOverlongNames() throws {
        for name in ["Speaker 7", "  ", String(repeating: "x", count: HeardNames.maxNameChars + 1)] {
            let json = reply(#"{"speaker": "Speaker 1", "name": "\#(name)", "sure": true, "evidence": ["I'm Priya"]}"#)
            XCTAssertEqual(try HeardNames.parse(json, lines: lines), [], name)
        }
    }

    func testOneNameForTwoSpeakersNamesNeither() throws {
        let json = reply("""
        {"speaker": "Speaker 1", "name": "Priya", "sure": true, "evidence": ["I'm Priya"]},
        {"speaker": "Speaker 2", "name": "priya", "sure": true, "evidence": ["Thanks, Priya"]}
        """)
        XCTAssertEqual(try HeardNames.parse(json, lines: lines), [])
    }

    func testTwoNamesForOneSpeakerNamesItNeither() throws {
        let json = reply("""
        {"speaker": "Speaker 2", "name": "Tomas", "sure": true, "evidence": ["Tomas, what about you?"]},
        {"speaker": "Speaker 2", "name": "Priya", "sure": false, "evidence": ["Thanks, Priya"]}
        """)
        XCTAssertEqual(try HeardNames.parse(json, lines: lines), [])
    }

    // MARK: What makes a name sure (Lyra's own check, on top of Claude's)

    func testASelfIntroductionIsSure() throws {
        let json = reply(#"{"speaker": "Speaker 1", "name": "Priya", "sure": true, "evidence": ["I'm Priya"]}"#)
        XCTAssertEqual(try HeardNames.parse(json, lines: lines).map(\.sure), [true])
    }

    func testBeingSpokenToAndAnsweringNextIsSure() throws {
        let json = reply(#"{"speaker": "Speaker 2", "name": "Tomas", "sure": true, "evidence": ["Tomas, what about you?"]}"#)
        XCTAssertEqual(try HeardNames.parse(json, lines: lines).map(\.sure), [true])
    }

    func testANameAnsweredBySomeoneElseIsOnlyASuggestion() throws {
        // Aidan says "Priya", but Speaker 2 answers next: not proof that Speaker 2 is Priya.
        let json = reply(#"{"speaker": "Speaker 2", "name": "Priya", "sure": true, "evidence": ["Thanks, Priya."]}"#)
        XCTAssertEqual(try HeardNames.parse(json, lines: lines).map(\.sure), [false])
    }

    func testAVoiceSayingTheNameItselfIsOnlyASuggestion() throws {
        // Speaker 3 says "Marco" without introducing itself: that points away from it, not to it.
        let extra = lines + [line("Speaker 3", "Marco, can you share your screen?", at: 30)]
        let json = reply(#"{"speaker": "Speaker 3", "name": "Marco", "sure": true, "evidence": ["Marco, can you share your screen?"]}"#)
        XCTAssertEqual(try HeardNames.parse(json, lines: extra).map(\.sure), [false])
    }

    func testAnsweringSkipsTheSpeakersOwnFollowOnLines() throws {
        let extra = [
            line("Aidan", "Next one is Wren.", at: 0, source: .knownVoice),
            line("Aidan", "Take it away.", at: 4, source: .knownVoice),
            line("Speaker 1", "Thanks, nice to see you.", at: 8),
        ]
        let json = reply(#"{"speaker": "Speaker 1", "name": "Wren", "sure": true, "evidence": ["Next one is Wren"]}"#)
        XCTAssertEqual(try HeardNames.parse(json, lines: extra).map(\.sure), [true])
    }

    func testThanksIsForWhoeverJustSpokeSoItIsOnlyASuggestion() throws {
        let extra = [
            line("Speaker 1", "That's my update.", at: 0),
            line("Aidan", "Thanks, Sam.", at: 4, source: .knownVoice),
            line("Speaker 2", "Okay, my turn then.", at: 8),
        ]
        // Claude says Speaker 2 is Sam; but "Thanks, Sam" was for Speaker 1, who had just finished.
        let json = reply(#"{"speaker": "Speaker 2", "name": "Sam", "sure": true, "evidence": ["Thanks, Sam."]}"#)
        XCTAssertEqual(try HeardNames.parse(json, lines: extra).map(\.sure), [false])
    }

    func testANameAddressedToThePreviousVoiceIsOnlyASuggestion() throws {
        let extra = [
            line("Speaker 1", "So that's the plan.", at: 0),
            line("Aidan", "Great work, Sam.", at: 4, source: .knownVoice),
            line("Speaker 1", "Cheers.", at: 8),
        ]
        // Speaker 1 is probably Sam, but it spoke just before as well as just after: a remark to whoever finished
        // can't be told from a question to whoever's next, so it stays a suggestion for Aidan.
        let json = reply(#"{"speaker": "Speaker 1", "name": "Sam", "sure": true, "evidence": ["Great work, Sam."]}"#)
        XCTAssertEqual(try HeardNames.parse(json, lines: extra).map(\.sure), [false])
    }

    func testThisIsAndPossessivesAreNotSelfIntroductions() throws {
        let extra = [
            line("Speaker 1", "This is Sam, she runs our socials.", at: 0),
            line("Speaker 2", "I'm Jo's partner in the business.", at: 4),
        ]
        let json = reply("""
        {"speaker": "Speaker 1", "name": "Sam", "sure": true, "evidence": ["This is Sam, she runs our socials."]},
        {"speaker": "Speaker 2", "name": "Jo", "sure": true, "evidence": ["I'm Jo's partner in the business."]}
        """)
        XCTAssertEqual(try HeardNames.parse(json, lines: extra).map(\.sure), [false, false])
    }

    func testKeepsUnsureNamesAsSuggestions() throws {
        let json = reply(#"{"speaker": "Speaker 2", "name": "Tomas", "sure": false, "evidence": ["Tomas, what about you?"]}"#)
        XCTAssertEqual(try HeardNames.parse(json, lines: lines).map(\.sure), [false])
    }

    func testThrowsWhenTheReplyHasNoJSON() {
        XCTAssertThrowsError(try HeardNames.parse("I couldn't tell, sorry.", lines: lines))
    }

    func testAcceptsAFencedReplyAndAnEmptyList() throws {
        XCTAssertEqual(try HeardNames.parse("```json\n{\"speakers\": []}\n```", lines: lines), [])
    }

    // MARK: Applying

    func testAppliesOnlySureNamesThatAreNotRejected() {
        var rejected = HeardName(speaker: "Speaker 3", name: "Marco", sure: true, evidence: ["x"])
        rejected.rejected = true
        let names = [
            HeardName(speaker: "Speaker 1", name: "Priya", sure: true, evidence: ["I'm Priya"]),
            HeardName(speaker: "Speaker 2", name: "Tomas", sure: false, evidence: ["Tomas, what about you?"]),
            rejected,
        ]
        let out = HeardNames.apply(names, to: lines)
        XCTAssertEqual(out.map(\.speakerLabel), ["Aidan", "Priya", "Aidan", "Speaker 2", "Speaker 3"])
        XCTAssertEqual(out[1].nameSource, .heard)
        XCTAssertNil(out[1].personID)  // never a person until Aidan says yes
        XCTAssertEqual(out[0].nameSource, .knownVoice)
    }

    func testApplyLeavesAlreadyNamedLinesAlone() {
        let names = [HeardName(speaker: "Aidan", name: "Priya", sure: true, evidence: ["I'm Priya"])]
        let before = lines  // read once: each read makes fresh person ids
        XCTAssertEqual(HeardNames.apply(names, to: before), before)
    }

    func testARerunKeepsWhatAidanRejected() {
        var old = HeardName(speaker: "Speaker 1", name: "Priya", sure: true, evidence: ["I'm Priya"])
        old.rejected = true
        let fresh = [HeardName(speaker: "Speaker 1", name: "priya", sure: true, evidence: ["I'm Priya"]),
                     HeardName(speaker: "Speaker 2", name: "Tomas", sure: true, evidence: ["Tomas, what about you?"])]
        let merged = HeardNames.merge(fresh, keepingRejectionsFrom: [old])
        XCTAssertEqual(merged.map(\.rejected), [true, nil])
    }

    func testNotThemIsNeverForgottenWhateverLaterAnswersSay() {
        var sam = HeardName(speaker: "Speaker 3", name: "Sam", sure: true, evidence: ["x"])
        sam.rejected = true
        let second = HeardNames.merge([HeardName(speaker: "Speaker 3", name: "Alex", sure: true, evidence: ["y"])],
                                      keepingRejectionsFrom: [sam])
        let third = HeardNames.merge([HeardName(speaker: "Speaker 3", name: "Sam", sure: true, evidence: ["x"])],
                                     keepingRejectionsFrom: second)
        XCTAssertEqual(third.first { $0.name == "Sam" }?.rejected, true)
    }

    func testAFirstNameAlreadyOnSomeoneIsTaken() throws {
        // "Aidan" is a named speaker: "Aidan Smith" for another voice would split one person in two.
        let json = reply(#"{"speaker": "Speaker 3", "name": "Aidan Smith", "sure": true, "evidence": ["hear me okay, Aidan"]}"#)
        XCTAssertEqual(try HeardNames.parse(json, lines: lines), [])
    }

    func testQuotesMatchWholeWordsOnly() throws {
        // "I'm" normalises to "i m", so "m Priya, I run" is whole words of the line; "riya, I run" is half a word.
        let json = reply(#"{"speaker": "Speaker 1", "name": "Priya", "sure": true, "evidence": ["m Priya, I run"]}"#)
        XCTAssertEqual(try HeardNames.parse(json, lines: lines).map(\.name), ["Priya"])  // "m" is a whole word here
        let partial = reply(#"{"speaker": "Speaker 1", "name": "Priya", "sure": true, "evidence": ["riya, I run"]}"#)
        XCTAssertEqual(try HeardNames.parse(partial, lines: lines), [])
    }

    // MARK: File

    func testSavesAndLoads() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-heard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(HeardNames.load(from: folder), [])
        let names = [HeardName(speaker: "Speaker 1", name: "Priya", sure: true, evidence: ["I'm Priya"])]
        try HeardNames.save(names, in: folder)
        XCTAssertEqual(HeardNames.load(from: folder), names)
    }

    // MARK: Service and prompt

    func testServiceSendsTheTranscriptAndPeopleAndParsesTheReply() async throws {
        let claude = FakeClaude(reply(#"{"speaker": "Speaker 1", "name": "Priya", "sure": true, "evidence": ["I'm Priya"]}"#))
        let names = try await HeardNamesService.run(lines: lines, screenText: ["Priya Shah"], people: ["Aidan", "Tomas"], claude: claude)
        XCTAssertEqual(names.map(\.name), ["Priya"])
        XCTAssertEqual(claude.calls.first?.system, Prompts.heardNamesSystem)
        let prompt = try XCTUnwrap(claude.calls.first?.prompt)
        XCTAssertTrue(prompt.contains("Speaker 1: Hi all, I'm Priya"))
        XCTAssertTrue(prompt.contains("Priya Shah"))
        XCTAssertTrue(prompt.contains("Tomas"))
        XCTAssertTrue(prompt.contains("<to_name>Speaker 1, Speaker 2, Speaker 3</to_name>"))
    }

    func testServiceSkipsClaudeWhenNobodyIsUnnamed() async throws {
        let claude = FakeClaude(reply(""))
        let named = lines.filter { $0.nameSource != nil }
        let names = try await HeardNamesService.run(lines: named, screenText: [], people: [], claude: claude)
        XCTAssertEqual(names, [])
        XCTAssertTrue(claude.calls.isEmpty)
    }

    func testPlaceholdersInOrderOfFirstAppearance() {
        XCTAssertEqual(HeardNames.placeholders(in: lines), ["Speaker 1", "Speaker 2", "Speaker 3"])
    }
}
