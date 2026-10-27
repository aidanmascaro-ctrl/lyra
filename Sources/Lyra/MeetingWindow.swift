import AppKit
import LyraCore
import SwiftUI

/// One meeting, Granola-style: serif title, a quiet row of pills, three tabs (My notes / Expanded / Transcript)
/// and a floating bar at the bottom for the live transcript and for asking Claude.
struct MeetingWindow: View {
    @ObservedObject var app: AppModel

    var body: some View {
        Group {
            if let folder = app.shownMeeting {
                MeetingContent(model: MeetingModel(folder: folder, app: app), app: app).id(folder)
            } else {
                Text("No meeting open.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .lyraWindow()
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
            BottomBar(model: model, drawerOpen: $drawerOpen).padding(.horizontal, 24).padding(.vertical, 14)
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

    @ViewBuilder private var page: some View {
        switch model.tab {
        case .myNotes:
            NoteEditor(blocks: model.myBlocks, onChange: { model.edited($0, in: .myNotes) })
                .overlay(alignment: .topLeading) { placeholder(model.myBlocks, "Write notes…") }
        case .expanded:
            NoteEditor(blocks: model.streaming ?? model.expandedBlocks, onChange: { model.edited($0, in: .expanded) },
                       selectionActions: true,
                       onSelectionAction: { model.selectionAction($0, text: $1, block: $2) })
                // Claude is writing it: nothing to type into until it's done.
                .allowsHitTesting(model.streaming == nil)
                .overlay(alignment: .topLeading) { placeholder(model.streaming ?? model.expandedBlocks, expandedPlaceholder) }
        case .transcript:
            TranscriptTab(model: model, people: app.people)
        }
    }

    private var expandedPlaceholder: String {
        model.lines.isEmpty ? "Claude expands your notes from the transcript after the meeting." : "Nothing expanded yet."
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
            if model.conflict != nil {
                Banner(text: "This note changed in Obsidian.") {
                    Button("Reload") { model.takeDisk() }
                    Button("Keep mine") { model.keepMine() }
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
