import Foundation
import LyraCore
import XCTest
@testable import Lyra

/// The sidebar remembers whether it was open, and a dragged note shows in its new folder at once, coming back (with
/// a notice) if the file move fails.
@MainActor
final class SidebarModelTests: XCTestCase {
    /// A throwaway defaults suite per test, wiped afterwards.
    private lazy var defaults: UserDefaults = {
        let suite = "lyra-sidebar-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }()

    // MARK: Visibility

    func testHiddenTheFirstTime() {
        XCTAssertFalse(SidebarModel(store: .empty, defaults: defaults).visible)
    }

    func testRemembersItWasOpen() {
        let model = SidebarModel(store: .empty, defaults: defaults)
        model.toggle()
        XCTAssertTrue(model.visible)
        XCTAssertTrue(SidebarModel(store: .empty, defaults: defaults).visible)
        model.toggle()
        XCTAssertFalse(SidebarModel(store: .empty, defaults: defaults).visible)
    }

    // MARK: Moving

    func testMoveShowsAtOnceThenRollsBackWhenItFails() async {
        let note = Self.summary("Kickoff", filedIn: "Clients")
        let store = SidebarStore.stub(snapshot: Self.snapshot([note])) { _, _ in throw StubError.failed }
        let model = SidebarModel(store: store, defaults: defaults)
        await model.refresh().value

        let task = model.move(noteID: note.id, to: "Content")
        XCTAssertEqual(model.notes(in: "Content").map(\.id), [note.id])
        XCTAssertTrue(model.notes(in: "Clients").isEmpty)

        await task.value
        XCTAssertEqual(model.notes(in: "Clients").map(\.id), [note.id])
        XCTAssertTrue(model.notes(in: "Content").isEmpty)
        XCTAssertEqual(model.notice, StubError.failed.localizedDescription)
    }

    func testMoveThatWorksStaysAndTellsOthers() async {
        let note = Self.summary("Kickoff", filedIn: nil)
        let disk = Box(Self.snapshot([note]))
        let store = SidebarStore.stub(load: { disk.value }) { summary, folder in
            var moved = summary
            moved.filedIn = folder
            disk.value = Self.snapshot([moved])
            return []
        }
        let model = SidebarModel(store: store, defaults: defaults)
        await model.refresh().value
        let changes = model.changes

        await model.move(noteID: note.id, to: "Clients").value
        XCTAssertEqual(model.notes(in: "Clients").map(\.id), [note.id])
        XCTAssertNil(model.notice)
        XCTAssertGreaterThan(model.changes, changes)
    }

    func testMoveToTheFolderItIsAlreadyInDoesNothing() async {
        let note = Self.summary("Kickoff", filedIn: "Clients")
        let store = SidebarStore.stub(snapshot: Self.snapshot([note])) { _, _ in XCTFail("moved"); return [] }
        let model = SidebarModel(store: store, defaults: defaults)
        await model.refresh().value
        await model.move(noteID: note.id, to: "Clients").value
        XCTAssertEqual(model.notes(in: "Clients").map(\.id), [note.id])
    }

    func testFolderNotesAreNewestFirst() async {
        let old = Self.summary("Old", filedIn: "Clients", date: Date(timeIntervalSince1970: 0))
        let new = Self.summary("New", filedIn: "Clients", date: Date(timeIntervalSince1970: 100))
        let model = SidebarModel(store: .stub(snapshot: Self.snapshot([old, new])) { _, _ in [] }, defaults: defaults)
        await model.refresh().value
        XCTAssertEqual(model.notes(in: "Clients").map(\.title), ["New", "Old"])
    }

    // MARK: Routes

    func testRenamingTheOpenFolderFollowsIt() {
        XCTAssertEqual(Route.folder("Clients").renamingFolder("Clients", to: "Customers"), .folder("Customers"))
        XCTAssertEqual(Route.folder("Content").renamingFolder("Clients", to: "Customers"), .folder("Content"))
        XCTAssertEqual(Route.home.renamingFolder("Clients", to: "Customers"), .home)
    }

    // MARK: Helpers

    private enum StubError: LocalizedError {
        case failed
        var errorDescription: String? { "The disk said no." }
    }

    private nonisolated static func summary(_ title: String, filedIn: String?, date: Date = Date()) -> MeetingSummary {
        MeetingSummary(id: UUID(), title: title, date: date, series: nil, tags: [], summary: nil, suggestion: nil,
                       folder: nil, note: URL(fileURLWithPath: "/tmp/\(title).md"), filedIn: filedIn)
    }

    private nonisolated static func snapshot(_ notes: [MeetingSummary]) -> SidebarSnapshot {
        SidebarSnapshot(folders: [SidebarFolder(name: "Clients", colour: .blue), SidebarFolder(name: "Content", colour: .green)],
                        notes: notes)
    }
}

/// A value the stub store's closures share across actors.
private final class Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

extension SidebarStore {
    static func stub(snapshot: SidebarSnapshot,
                     move: @escaping @Sendable (MeetingSummary, String?) throws -> [String]) -> SidebarStore {
        stub(load: { snapshot }, move: move)
    }

    static func stub(load: @escaping @Sendable () -> SidebarSnapshot,
                     move: @escaping @Sendable (MeetingSummary, String?) throws -> [String]) -> SidebarStore {
        var store = SidebarStore.empty
        store.load = load
        store.move = move
        return store
    }
}
