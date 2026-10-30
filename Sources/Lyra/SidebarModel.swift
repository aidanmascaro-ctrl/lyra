import Foundation
import LyraCore
import SwiftUI

/// The sidebar: whether it shows (remembered), Aidan's folders and the meetings filed in each. Vault work runs off
/// the main actor; a moved note shows in its new folder at once and comes back, with a notice, if the move fails.
@MainActor
final class SidebarModel: ObservableObject {
    static let visibleKey = "sidebarVisible"
    static let spring = Animation.spring(response: 0.3, dampingFraction: 0.86)

    @Published private(set) var visible: Bool { didSet { defaults.set(visible, forKey: Self.visibleKey) } }
    @Published private(set) var folders: [SidebarFolder] = []
    @Published private(set) var loaded = false
    @Published var expanded: Set<String> = []
    /// Plain-English problems from a folder change.
    @Published var notice: String?
    /// Goes up when notes moved or folders changed, so other pages re-read the vault.
    @Published private(set) var changes = 0
    /// Every meeting as last read, with moves still running applied on top.
    @Published private(set) var notes: [MeetingSummary] = []

    private let store: SidebarStore
    private let defaults: UserDefaults
    private var onDisk: [MeetingSummary] = []
    /// Moves not finished yet, by note: kept over any refresh that lands meanwhile. Each carries its own token, so
    /// an older move of the same note finishing (or failing) never clears or undoes a newer one.
    private var pending: [UUID: PendingMove] = [:]
    private var moveTokens = 0
    /// Goes up with every refresh started: an older one landing late is dropped.
    private var refreshGeneration = 0
    /// The meeting being dragged, so a folder it is already in doesn't light up under it. Not published: it is set
    /// as the drag starts, outside any view update.
    private(set) var dragging: UUID?

    init(store: SidebarStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        visible = defaults.bool(forKey: Self.visibleKey)
    }

    func toggle() { visible.toggle() }
    func hide() { visible = false }

    func notes(in folder: String) -> [MeetingSummary] {
        notes.filter { $0.filedIn == folder }.sorted { $0.date > $1.date }
    }

    func folder(named name: String) -> SidebarFolder? { folders.first { $0.name == name } }

    @discardableResult
    func refresh() -> Task<Void, Never> {
        let store = store
        refreshGeneration += 1
        let generation = refreshGeneration
        return Task {
            let snapshot = await Task.detached { store.load() }.value
            guard generation == refreshGeneration else { return }
            folders = snapshot.folders
            onDisk = snapshot.notes
            applyPending()
            loaded = true
        }
    }

    /// Files the note in `folder` (nil: out of folders) at once, then moves its file in the background.
    @discardableResult
    func move(noteID: UUID, to folder: String?) -> Task<Void, Never> {
        guard let summary = notes.first(where: { $0.id == noteID }), summary.filedIn != folder else { return Task {} }
        // What is on disk, not the optimistic view: a failure falls back to it.
        let onDiskSummary = onDisk.first { $0.id == noteID } ?? summary
        moveTokens += 1
        let token = moveTokens
        pending[noteID] = PendingMove(token: token, folder: folder)
        withAnimation(Self.spring) { applyPending() }
        let store = store
        return Task {
            let result = await Task.detached { Result { try store.move(onDiskSummary, folder) } }.value
            if pending[noteID]?.token == token {
                pending[noteID] = nil
                if case .failure = result { withAnimation(Self.spring) { applyPending() } }
            }
            report(result)
            await refresh().value
        }
    }

    // MARK: Drag and drop

    /// What a meeting row hands to a drag, noting which meeting is on the move.
    func dragPayload(for summary: MeetingSummary) -> MeetingDrag {
        dragging = summary.id
        return MeetingDrag(summary)
    }

    /// Whether the meeting being dragged can land in `folder` (nil: out of folders): not when it is already there.
    func accepts(into folder: String?) -> Bool {
        guard let dragging, let note = notes.first(where: { $0.id == dragging }) else { return true }
        return note.filedIn != folder
    }

    /// Files the dropped meetings in `folder` (nil: out of folders). False when none of them moved.
    @discardableResult
    func drop(_ items: [MeetingDrag], into folder: String?) -> Bool {
        dragging = nil
        let moving = items.filter { item in notes.contains { $0.id == item.id && $0.filedIn != folder } }
        for item in moving { move(noteID: item.id, to: folder) }
        return !moving.isEmpty
    }

    // MARK: Folder actions

    /// A new folder, returned so the sidebar can start naming it.
    func create() async -> String? {
        let store = store
        let result = await Task.detached { Result { try store.create() } }.value
        report(result.map { _ in [] })
        await refresh().value
        return try? result.get().name
    }

    /// Renames the folder; once it has worked, it shows under its new name at once and `followed` runs (so the
    /// open page can follow it) before the vault is re-read.
    func rename(_ name: String, to newName: String, followed: (String) -> Void = { _ in }) async -> Bool {
        let store = store
        let result = await Task.detached { Result { try store.rename(name, newName) } }.value
        if case .success = result { showRenamed(name, to: newName); followed(newName) }
        report(result.map { [] })
        await refresh().value
        return (try? result.get()) != nil
    }

    func setColour(_ colour: FolderColour, of name: String) {
        folders = folders.map { $0.name == name ? SidebarFolder(name: name, colour: colour) : $0 }
        let store = store
        vaultWork { try store.setColour(colour, name); return [] }
    }

    func remove(_ name: String) {
        let store = store
        expanded.remove(name)
        vaultWork { try store.remove(name) }
    }

    func trash(_ summary: MeetingSummary) {
        let store = store
        vaultWork { store.trash(summary) }
    }

    // MARK: Helpers

    private func vaultWork(_ work: @escaping @Sendable () throws -> [String]) {
        Task {
            report(await Task.detached { Result { try work() } }.value)
            refresh()
        }
    }

    private func report(_ result: Result<[String], Error>) {
        switch result {
        case .success(let problems):
            changes += 1
            if !problems.isEmpty { notice = problems.joined(separator: "\n") }
        case .failure(let error): notice = error.localizedDescription
        }
    }

    private func applyPending() {
        notes = onDisk.map { note in
            guard let move = pending[note.id] else { return note }
            var moved = note
            moved.filedIn = move.folder
            return moved
        }
    }

    private func showRenamed(_ name: String, to newName: String) {
        if expanded.remove(name) != nil { expanded.insert(newName) }
        folders = folders.map { $0.name == name ? SidebarFolder(name: newName, colour: $0.colour) : $0 }
        onDisk = onDisk.map { note in
            guard note.filedIn == name else { return note }
            var renamed = note
            renamed.filedIn = newName
            return renamed
        }
        pending = pending.mapValues { $0.folder == name ? PendingMove(token: $0.token, folder: newName) : $0 }
        applyPending()
    }
}

/// A move shown before its file has moved.
private struct PendingMove {
    let token: Int
    let folder: String?
}

extension Route {
    /// The same page after a sidebar folder is renamed: its own page follows the new name.
    func renamingFolder(_ name: String, to newName: String) -> Route {
        self == .folder(name) ? .folder(newName) : self
    }
}
