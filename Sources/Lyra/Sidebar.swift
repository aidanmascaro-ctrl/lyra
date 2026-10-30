import AppKit
import LyraCore
import SwiftUI

/// Down the left of the window, Granola-style: Home, then Aidan's coloured folders, each opening to its meetings.
/// The same flat page colour, a hairline on its right edge, reaching up under the title bar.
struct Sidebar: View {
    static let width: CGFloat = 240

    @ObservedObject var app: AppModel
    @ObservedObject var model: SidebarModel
    @State private var editing: String?
    @State private var removing: String?
    /// A filed meeting is over the Home row: dropping it there takes it out of its folder.
    @State private var homeLit = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                SidebarRow(selected: app.route == .home, highlight: homeLit ? FolderColour.grey.color : nil,
                           action: { app.route = .home }) {
                    Image(systemName: "house").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).frame(width: 19)
                    Text("Home")
                    Spacer(minLength: 0)
                }
                .meetingDropTarget(into: nil, sidebar: model, lit: $homeLit)
                .help("Home. Drop a meeting here to take it out of its folder.")
                header.padding(.top, 18).padding(.bottom, 4)
                if let notice = model.notice { Banner(text: notice) { Button("OK") { model.notice = nil } }.padding(.bottom, 6) }
                if model.loaded && model.folders.isEmpty {
                    Text("Make a folder, then drag meetings into it.")
                        .font(.system(size: 12.5)).foregroundStyle(.tertiary).padding(.horizontal, 8).padding(.top, 4)
                }
                ForEach(model.folders, id: \.name) { folder in
                    folderRow(folder)
                    if model.expanded.contains(folder.name) {
                        ForEach(model.notes(in: folder.name)) { note in
                            SidebarNoteRow(summary: note, selected: isOpen(note), sidebar: model) { open(note) }
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
            }
            .animation(SidebarModel.spring, value: model.expanded)
            .padding(.horizontal, 10)
            .padding(.top, Chrome.topInset)
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
        .frame(width: Self.width)
        .background(Chrome.page.ignoresSafeArea())
        .overlay(alignment: .trailing) { Rectangle().fill(Chrome.capsuleStroke).frame(width: 1).ignoresSafeArea() }
        .onAppear { model.refresh() }
        .onChange(of: app.revision) { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in model.refresh() }
        .alert("Remove the folder “\(removing ?? "")”?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove Folder", role: .destructive) { if let name = removing { remove(name) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its meetings stay in Lyra and in Obsidian: they move back out to their series, or to Meetings. "
                 + "The empty folder goes to the Mac's Trash.")
        }
    }

    private var header: some View {
        HStack {
            Text("FOLDERS").font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(.tertiary)
            Spacer()
            Button(action: create) {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New folder")
        }
        .padding(.leading, 8).padding(.trailing, 4)
    }

    private func folderRow(_ folder: SidebarFolder) -> some View {
        let name = folder.name
        return FolderRow(
            folder: folder, count: model.notes(in: name).count, selected: app.route == .folder(name),
            expanded: Binding(get: { model.expanded.contains(name) },
                              set: { open in if open { model.expanded.insert(name) } else { model.expanded.remove(name) } }),
            editing: editing == name,
            open: { app.route = .folder(name) },
            renamed: { rename(name, to: $0) },
            menu: FolderMenu(rename: { editing = name }, colour: { model.setColour($0, of: name) }, remove: { removing = name }),
            sidebar: model)
    }

    // MARK: Actions

    private func create() {
        Task {
            if let name = await model.create() { editing = name }
        }
    }

    private func rename(_ name: String, to newName: String?) {
        guard let newName else { editing = nil; return }
        Task {
            _ = await model.rename(name, to: newName) { app.route = app.route.renamingFolder(name, to: $0) }
            editing = nil
        }
    }

    private func remove(_ name: String) {
        if app.route == .folder(name) { app.route = .home }
        model.remove(name)
    }

    private func isOpen(_ note: MeetingSummary) -> Bool {
        guard let folder = note.folder else { return false }
        return app.route == .meeting(folder)
    }

    private func open(_ note: MeetingSummary) {
        if let folder = note.folder { app.route = .meeting(folder) } else { NSWorkspace.shared.open(note.note) }
    }
}
