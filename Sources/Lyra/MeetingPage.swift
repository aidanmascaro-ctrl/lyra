import AppKit
import LyraCore
import SwiftUI

/// One meeting, Granola-style: serif title, a quiet row of pills, three tabs (My notes / Expanded / Transcript)
/// and a floating bar at the bottom for the live transcript and for asking Claude.
/// Shown inside Lyra's one window; leaving it (back to home, or the window closing) flushes the editors and stops
/// the note watcher, through the editors' teardown and `onDisappear`.
struct MeetingPage: View {
    let folder: URL
    @ObservedObject var app: AppModel

    var body: some View {
        MeetingContent(model: MeetingModel(folder: folder, app: app), app: app).id(folder)
    }
}

private struct MeetingContent: View {
    @StateObject var model: MeetingModel
    @ObservedObject var app: AppModel
    @State private var drawerOpen = false

    init(model: @autoclosure @escaping () -> MeetingModel, app: AppModel) {
        _model = StateObject(wrappedValue: model())
        self.app = app
    }

    var body: some View {
        VStack(spacing: 0) {
            MeetingHeader(model: model).noteColumn().padding(.top, Chrome.topInset)
            banners.noteColumn()
            page.frame(maxWidth: .infinity, maxHeight: .infinity)
            if drawerOpen && model.isLive {
                LiveDrawer(app: app).noteColumn().transition(.move(edge: .bottom).combined(with: .opacity))
            }
            BottomBar(model: model, app: app, drawerOpen: $drawerOpen).padding(.horizontal, 24).padding(.vertical, 14)
        }
        .animation(.easeOut(duration: 0.2), value: drawerOpen)
        .onChange(of: model.streaming == nil) { model.reload() }
        .onChange(of: app.revision) { model.reload() }
        .onChange(of: model.isLive) { if !model.isLive { drawerOpen = false } }
        .onDisappear { model.close() }
        .alert("Couldn't finish renaming", isPresented: Binding(get: { model.renameMessage != nil },
                                                                set: { if !$0 { model.dismissRenameMessage() } })) {
            Button("OK") {}
        } message: { Text(model.renameMessage ?? "") }
        .alert("This note's transcript was edited in Obsidian. Replace it with the renamed transcript?",
               isPresented: $model.askToReplace) {
            Button("Replace") { model.replaceNote() }
            Button("Keep my edits", role: .cancel) {}
        }
    }

    /// Both editors stay alive behind the tabs, so each always answers pushes and keeps its undo history; the one
    /// not shown can't be typed into. While Claude streams, a separate read-only view shows the stream.
    private var page: some View {
        ZStack {
            editor(.myNotes, blocks: model.myBlocks, placeholder: "Write notes…")
            editor(.expanded, blocks: model.expandedBlocks, placeholder: expandedPlaceholder, actions: true)
            if model.tab == .expanded, let stream = model.streaming {
                NoteEditor(blocks: stream, onChange: { _ in }, editable: false)
            }
            if model.tab == .transcript {
                TranscriptTab(model: model, people: app.people).background(Chrome.page)
            }
        }
    }

    private func editor(_ section: NoteSection, blocks: [NoteBlock], placeholder text: String, actions: Bool = false) -> some View {
        let tab: MeetingTab = section == .myNotes ? .myNotes : .expanded
        let active = model.tab == tab && (section == .myNotes || model.streaming == nil)
        // The object itself, not this view's `@StateObject`: the editor's last flush runs just after the page is
        // gone (back to home), when the view's property is no longer installed.
        let model = model
        return NoteEditor(blocks: blocks, onChange: { model.edited($0, in: section) },
                          selectionActions: actions,
                          onSelectionAction: { model.selectionAction($0, text: $1, block: $2) },
                          pushID: model.pushID[section] ?? 0,
                          onExternal: { model.acknowledged(section, id: $0, accepted: $1) },
                          forceLoad: model.forceLoad[section] ?? 0,
                          editable: active)
            .overlay(alignment: .topLeading) { if active { placeholder(blocks, text) } }
            .opacity(active ? 1 : 0)
            .allowsHitTesting(active)
    }

    private var expandedPlaceholder: String {
        if model.canRecord { return "Press Record and Claude expands your notes from the transcript afterwards." }
        return model.lines.isEmpty ? "Claude expands your notes from the transcript after the meeting." : "Nothing expanded yet."
    }

    @ViewBuilder private func placeholder(_ blocks: [NoteBlock], _ text: String) -> some View {
        if blocks.isEmpty || blocks == [NoteBlock(kind: .paragraph, runs: [])] {
            Text(text).font(.system(size: 15)).foregroundStyle(.tertiary)
                .noteColumn().padding(.top, 28).allowsHitTesting(false)
        }
    }

    @ViewBuilder private var banners: some View {
        VStack(spacing: 6) {
            if let error = model.loadError { Banner(text: error) }
            ForEach([NoteSection.myNotes, .expanded], id: \.self) { section in
                if model.conflicts[section] != nil {
                    Banner(text: "\(section == .myNotes ? "My notes" : "Expanded") changed in Obsidian while you were typing.") {
                        Button("Reload") { model.takeDisk(section) }
                        Button("Keep mine") { model.keepMine(section) }
                    }
                }
            }
            if let notice = model.notice {
                Banner(text: notice) { Button("OK") { model.notice = nil } }
            }
            if model.tab == .expanded {
                if model.streaming != nil {
                    Banner(text: "Claude is writing the expanded notes…", spinning: true)
                } else if let failure = model.expandFailure {
                    Banner(text: "Couldn't expand — \(failure)") { Button("Retry") { model.retryExpansion() } }
                } else if model.newNotesCount > 0 {
                    let n = model.newNotesCount
                    Banner(text: "\(n) new note\(n == 1 ? "" : "s") since") { Button("Re-expand") { model.reExpand() } }
                }
            }
        }
        .padding(.bottom, 4)
    }
}

/// A quiet one-line message under the tabs, with its actions on the right.
struct Banner<Actions: View>: View {
    let text: String
    var spinning = false
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 10) {
            if spinning { ProgressView().controlSize(.small) }
            Text(text).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            actions().buttonStyle(.plain).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.primary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Chrome.pill))
    }
}

extension Banner where Actions == EmptyView {
    init(text: String, spinning: Bool = false) { self.init(text: text, spinning: spinning) { EmptyView() } }
}
