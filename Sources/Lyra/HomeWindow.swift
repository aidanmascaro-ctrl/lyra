import AppKit
import LyraCore
import SwiftUI

/// Lyra's home and front door, Granola-style: New note (the live meeting's notes, or a new in-person recording),
/// series suggestions to confirm, each series with its meetings, and every meeting newest first.
struct HomeWindow: View {
    @ObservedObject var app: AppModel
    @StateObject private var model: HomeModel
    @Environment(\.openWindow) private var openWindow
    @State private var renaming: String?
    @State private var newName = ""
    /// New note started a recording: its meeting window opens as soon as the meeting exists.
    @State private var openWhenStarted = false

    init(app: AppModel) {
        self.app = app
        _model = StateObject(wrappedValue: HomeModel(app: app))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Meetings").font(Chrome.titleFont)
                newNote
                if let notice = model.notice { Banner(text: notice) { Button("OK") { model.notice = nil } } }
                ForEach(model.suggestions) { suggestionCard($0) }
                if !model.groups.isEmpty { section("Series") { ForEach(model.groups, id: \.name) { seriesCard($0) } } }
                if !model.recent.isEmpty {
                    section("Recent") { VStack(spacing: 0) { ForEach(model.recent) { row($0, showSeries: true) } }.padding(.horizontal, -8) }
                } else if !model.loading {
                    Text("No meetings yet. Lyra asks to record when a call starts, or press New note to start one in person.")
                        .font(.system(size: 14)).foregroundStyle(.tertiary)
                }
            }
            .noteColumn()
            .padding(.top, Chrome.topInset)
            .padding(.bottom, 40)
        }
        .frame(minWidth: 520, minHeight: 420)
        .lyraWindow()
        .onAppear { model.refresh() }
        .onChange(of: app.revision) { model.refresh() }
        .onChange(of: app.liveMeeting) {
            model.refresh()
            if openWhenStarted, let live = app.liveMeeting {
                openWhenStarted = false
                open(live.folder)
            }
        }
        .onChange(of: app.starting) {
            // Couldn't start: say why here, where New note was pressed.
            guard openWhenStarted, !app.starting, app.liveMeeting == nil else { return }
            openWhenStarted = false
            model.notice = app.lastError
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in model.refresh() }
        .alert("Rename series", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Series name", text: $newName)
            Button("Rename") { if let old = renaming { model.rename(series: old, to: newName) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The series folder, its page and links to it are renamed in Obsidian too.") }
    }

    /// Always there: the live meeting's notes while one is recording, otherwise a new in-person recording, which
    /// is what every Lyra note is (a meeting with a transcript).
    private var newNote: some View {
        Button(action: newNoteTapped) {
            HStack(spacing: 8) {
                if let live = app.liveMeeting {
                    Circle().fill(Chrome.live).frame(width: 8, height: 8)
                    Text("New note — \(live.appName) (live)")
                } else if openWhenStarted || app.starting {
                    ProgressView().controlSize(.small)
                    Text("Starting…")
                } else {
                    Image(systemName: "square.and.pencil")
                    Text("New note")
                }
            }
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 16).frame(height: 36)
            .capsuleSurface()
        }
        .buttonStyle(.plain)
        .disabled(app.liveMeeting == nil && (openWhenStarted || app.starting))
        .help(app.liveMeeting == nil ? "Start recording in person and write notes" : "Write notes for the meeting being recorded")
    }

    private func newNoteTapped() {
        if let live = app.liveMeeting { return open(live.folder) }
        openWhenStarted = true
        app.startInPerson()
    }

    private func suggestionCard(_ s: MeetingSummary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.badge.plus").foregroundStyle(.secondary)
            (Text("“\(s.title)” looks like part of ") + Text(s.suggestion ?? "").fontWeight(.semibold))
                .font(.system(size: 13.5)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Add to series") { model.accept(s) }.fontWeight(.medium)
            Button("Not related") { model.reject(s) }.foregroundStyle(.secondary).disabled(s.folder == nil)
        }
        .buttonStyle(.plain).font(.system(size: 13))
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Chrome.pill))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(.tertiary)
            content()
        }
    }

    private func seriesCard(_ group: SeriesGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(group.name).font(.system(size: 15, weight: .semibold))
                Text("\(group.meetings.count) meeting\(group.meetings.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                if !group.tags.isEmpty { Text(group.tags.map { "#\($0)" }.joined(separator: " ")).foregroundStyle(.tertiary) }
                Spacer()
            }
            .font(.system(size: 13))
            .padding(.bottom, 4)
            ForEach(group.meetings) { row($0, showSeries: false) }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Chrome.pill))
        .contextMenu {
            Button("Rename series…") { newName = group.name; renaming = group.name }
        }
    }

    private func row(_ s: MeetingSummary, showSeries: Bool) -> some View {
        Button { if let folder = s.folder { open(folder) } else { NSWorkspace.shared.open(s.note) } } label: {
            HStack(spacing: 8) {
                Text(s.title.isEmpty ? "Untitled" : s.title).foregroundStyle(.primary).lineLimit(1)
                if showSeries, let series = s.series { Text("· \(series)").foregroundStyle(.secondary).lineLimit(1) }
                Spacer(minLength: 12)
                Text(MeetingHeader.when(s.date)).foregroundStyle(.tertiary).monospacedDigit()
            }
            .font(.system(size: 14))
            .padding(.horizontal, 8).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .help(s.folder == nil ? "Open in Obsidian" : "Open this meeting")
    }

    private func open(_ folder: URL) {
        app.shownMeeting = folder
        openWindow(id: "meeting")
        NSApp.activate()
    }
}

/// A list row that lights up softly under the pointer.
private struct RowButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering || configuration.isPressed ? Chrome.hover : .clear))
            .onHover { hovering = $0 }
    }
}
