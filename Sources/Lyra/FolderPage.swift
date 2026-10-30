import AppKit
import LyraCore
import SwiftUI

/// A sidebar folder's page: its coloured glyph and name as the title, then its meetings newest first, like home's
/// Recent list.
struct FolderPage: View {
    let name: String
    @ObservedObject var app: AppModel
    @ObservedObject var sidebar: SidebarModel
    @State private var trashing: MeetingSummary?
    /// A meeting from elsewhere is over the page: dropping it anywhere here files it in this folder.
    @State private var dropLit = false

    private var colour: FolderColour { sidebar.folder(named: name)?.colour ?? .grey }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 12) {
                    FolderGlyph(colour: colour, open: dropLit, size: 22)
                    Text(name).font(Chrome.titleFont)
                }
                // The sidebar shows its own notices while it is open.
                if !sidebar.visible, let notice = sidebar.notice { Banner(text: notice) { Button("OK") { sidebar.notice = nil } } }
                content
            }
            .noteColumn()
            .padding(.top, Chrome.topInset)
            .padding(.bottom, 40)
        }
        .background { if dropLit { DropHighlight(colour: colour.color, cornerRadius: 12).padding(8).transition(.opacity) } }
        .meetingDropTarget(into: name, sidebar: sidebar, lit: $dropLit)
        .onAppear { sidebar.refresh() }
        // Its own hooks, as the sidebar's: it may be hidden.
        .onChange(of: app.revision) { sidebar.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in sidebar.refresh() }
        .alert("Move “\(trashing?.title ?? "")” to the Trash?", isPresented: Binding(get: { trashing != nil }, set: { if !$0 { trashing = nil } })) {
            Button("Move to Trash", role: .destructive) { if let s = trashing { trash(s) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The Obsidian note and its recordings go to the Mac's Trash. You can put them back from the Trash in Finder.") }
    }

    @ViewBuilder private var content: some View {
        let notes = sidebar.notes(in: name)
        if !notes.isEmpty {
            VStack(spacing: 0) {
                ForEach(notes) { note in
                    FolderNoteRow(summary: note, open: { open(note) },
                                  unfile: { sidebar.move(noteID: note.id, to: nil) }, trash: { trashing = note })
                        .meetingDraggable(note, sidebar: sidebar)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, -8)
        } else if sidebar.loaded {
            Text(sidebar.folder(named: name) == nil
                 ? "Lyra can't find this folder any more. It may have been renamed or moved in Obsidian."
                 : "Nothing in here yet. Drag meetings onto the folder in the sidebar to file them.")
                .font(.system(size: 14)).foregroundStyle(.tertiary)
        }
    }

    private func open(_ note: MeetingSummary) {
        if let folder = note.folder { app.route = .meeting(folder) } else { NSWorkspace.shared.open(note.note) }
    }

    /// As on home: refused while Lyra is still working on the meeting.
    private func trash(_ note: MeetingSummary) {
        guard !app.isBusy(folder: note.folder, id: note.id) else { sidebar.notice = HomeModel.stillWorking; return }
        sidebar.trash(note)
    }
}

/// A meeting in a folder: title, series and date. Right-click to take it out of the folder or trash it.
struct FolderNoteRow: View {
    let summary: MeetingSummary
    let open: () -> Void
    let unfile: () -> Void
    let trash: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Text(summary.title.isEmpty ? "Untitled" : summary.title).foregroundStyle(.primary).lineLimit(1)
                if let series = summary.series { Text("· \(series)").foregroundStyle(.secondary).lineLimit(1) }
                Spacer(minLength: 12)
                Text(MeetingHeader.when(summary.date)).foregroundStyle(.tertiary).monospacedDigit()
            }
            .font(.system(size: 14))
            .padding(.horizontal, 8).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .help(summary.folder == nil ? "Open in Obsidian" : "Open this meeting")
        .contextMenu {
            Button("Remove from folder", action: unfile)
            Button("Move to Trash", role: .destructive, action: trash)
        }
    }
}
