import XCTest
@testable import LyraCore

final class SeriesLibraryTests: XCTestCase {
    private var vault: URL!
    private var meetings: URL!
    private var index: NoteIndex!

    override func setUpWithError() throws {
        vault = FileManager.default.temporaryDirectory.appendingPathComponent("SeriesLibraryTests-\(UUID().uuidString)")
        meetings = vault.appendingPathComponent("Meetings")
        try FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
        index = NoteIndex(notesRoot: meetings, vaultRoot: vault)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: vault)
    }

    private func date(_ day: Int, month: Int = 10) -> Date {
        var c = DateComponents(); c.year = 2026; c.month = month; c.day = day; c.hour = 9
        return Calendar.current.date(from: c)!
    }

    private func loaded(title: String, day: Int, series: String? = nil, tags: [String] = [], summary: String? = nil,
                        in dir: URL? = nil, file: String? = nil, id: UUID = UUID()) -> LoadedNote {
        let front = NoteFrontmatter(lyraID: id, title: title, date: date(day), app: "Zoom", durationMin: 10,
                                    recordings: URL(fileURLWithPath: "/tmp/rec", isDirectory: true),
                                    series: series, tags: tags, summary: summary)
        let doc = NoteDocument(front: front, warnings: [], myNotes: "", expanded: "", transcript: "")
        let url = (dir ?? meetings).appendingPathComponent((file ?? title) + ".md")
        return LoadedNote(url: url, document: doc, fingerprint: "x")
    }

    private func summary(title: String, day: Int, series: String? = nil, suggestion: String? = nil,
                         tags: [String] = [], summary: String? = nil) -> MeetingSummary {
        MeetingSummary(id: UUID(), title: title, date: date(day), series: series, tags: tags, summary: summary,
                       suggestion: suggestion, folder: nil, note: meetings.appendingPathComponent(title + ".md"))
    }

    func testGroupsBySeriesNewestFirst() {
        let all = [
            summary(title: "A1", day: 1, series: "Alpha", tags: ["x", "y"]),
            summary(title: "B1", day: 5, series: "Beta"),
            summary(title: "A2", day: 3, series: "Alpha", tags: ["x", "z", "w"]),
            summary(title: "Solo", day: 20),
        ]
        let groups = SeriesLibrary.groups(all)
        XCTAssertEqual(groups.map(\.name), ["Beta", "Alpha"])
        XCTAssertEqual(groups[1].meetings.map(\.title), ["A2", "A1"])
        XCTAssertEqual(groups[1].tags, ["x", "w", "y"])   // most shared first, then alphabetical, top 3
    }

    func testPendingSuggestionHiddenOnceRejectedOrConfirmed() {
        let id = UUID()
        var meeting = Meeting(id: id, title: "Chat", appName: "Zoom", startedAt: date(2))
        meeting.seriesSuggestion = "Weekly"
        let note = loaded(title: "Chat", day: 2, id: id)
        let byID = [id: (meeting, meetings.appendingPathComponent("rec"))]

        let pending = SeriesLibrary.summaries(notes: [note], meetingsByID: byID, notesRoot: meetings)
        XCTAssertEqual(pending.first?.suggestion, "Weekly")
        XCTAssertEqual(pending.first?.folder, meetings.appendingPathComponent("rec"))
        XCTAssertEqual(SeriesLibrary.pendingSuggestions(pending).count, 1)

        meeting.seriesRejected = true
        let rejected = SeriesLibrary.summaries(notes: [note], meetingsByID: [id: (meeting, URL(fileURLWithPath: "/r"))], notesRoot: meetings)
        XCTAssertNil(rejected.first?.suggestion)
        XCTAssertTrue(SeriesLibrary.pendingSuggestions(rejected).isEmpty)

        meeting.seriesRejected = nil
        let confirmed = loaded(title: "Chat", day: 2, series: "Weekly", id: id)
        let joined = SeriesLibrary.summaries(notes: [confirmed], meetingsByID: [id: (meeting, URL(fileURLWithPath: "/r"))], notesRoot: meetings)
        XCTAssertNil(joined.first?.suggestion)
        XCTAssertTrue(SeriesLibrary.pendingSuggestions(joined).isEmpty)
    }

    func testSeriesPageListsOldestFirstWithOneLiners() {
        let newer = MeetingSummary(id: UUID(), title: "Second: catch-up", date: date(27), series: "Weekly", tags: [], summary: nil,
                                   suggestion: nil, folder: nil, note: meetings.appendingPathComponent("Weekly/2026-10-27 0900 — Second.md"))
        let older = MeetingSummary(id: UUID(), title: "Kick-off", date: date(20), series: "Weekly", tags: [], summary: "Agreed scope.",
                                   suggestion: nil, folder: nil, note: meetings.appendingPathComponent("Weekly/2026-10-20 0900 — Kick-off.md"))
        let page = SeriesLibrary.seriesPage(name: "Weekly", meetings: [newer, older], notesRoot: meetings)
        XCTAssertEqual(page, """
            ---
            lyra_series: true
            ---
            # Weekly

            - [[2026-10-20 0900 — Kick-off|Kick-off]] — 20 Oct 2026 — Agreed scope.
            - [[2026-10-27 0900 — Second|Second: catch-up]] — 27 Oct 2026

            """)
    }

    func testFolderOverridesFrontmatterSeries() {
        let moved = loaded(title: "Moved", day: 2, in: meetings.appendingPathComponent("X"))
        let conflicting = loaded(title: "Conflict", day: 3, series: "Old", in: meetings.appendingPathComponent("X"))
        let loose = loaded(title: "Loose", day: 4)
        let looseSeries = loaded(title: "Loose2", day: 5, series: "Fm")
        let same = loaded(title: "Same", day: 6, series: "Y", in: meetings.appendingPathComponent("Y"))
        let result = SeriesLibrary.summaries(notes: [moved, conflicting, loose, looseSeries, same], meetingsByID: [:], notesRoot: meetings)
        XCTAssertEqual(result.map(\.series), ["X", "X", nil, "Fm", "Y"])
    }

    func testWriteSeriesPageWritesOnceAndSkipsUnchanged() throws {
        let dir = meetings.appendingPathComponent("Weekly")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let note = loaded(title: "Kick-off", day: 20, series: "Weekly", summary: "Agreed scope.", in: dir)
        try note.document.render().write(to: note.url, atomically: true, encoding: .utf8)

        try SeriesLibrary.writeSeriesPage(name: "Weekly", index: index)
        let page = dir.appendingPathComponent("Weekly.md")
        let first = try String(contentsOf: page, encoding: .utf8)
        XCTAssertTrue(first.contains("- [[Kick-off|Kick-off]] — 20 Oct 2026 — Agreed scope."))

        let stamp = try FileManager.default.attributesOfItem(atPath: page.path)[.modificationDate] as! Date
        Thread.sleep(forTimeInterval: 0.05)
        try SeriesLibrary.writeSeriesPage(name: "Weekly", index: index)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: page.path)[.modificationDate] as? Date, stamp)
        // The page itself is not a meeting.
        XCTAssertEqual(index.allNotes().count, 1)
    }

    func testWriteSeriesPageCreatesMissingFolder() throws {
        try SeriesLibrary.writeSeriesPage(name: "Fresh", index: index)
        let page = meetings.appendingPathComponent("Fresh/Fresh.md")
        XCTAssertEqual(try String(contentsOf: page, encoding: .utf8), "---\nlyra_series: true\n---\n# Fresh\n\n")
    }
}
