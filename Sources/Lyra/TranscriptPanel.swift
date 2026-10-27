import LyraCore
import SwiftUI

/// Granola's transcript panel, slid up above the bottom bar: the conversation as chat bubbles — Aidan's mic on
/// the right, everyone else on the left under their name. Its controls are the bottom bar's, just below. The written-up
/// transcript first (every earlier part), then, while recording, the rough live draft as it is spoken.
struct TranscriptPanel: View {
    @ObservedObject var model: MeetingModel
    @ObservedObject var app: AppModel
    let close: () -> Void

    private static let height: CGFloat = 340
    private static let bubbleWidth: CGFloat = 420
    /// Name colours, picked by label so a speaker keeps theirs.
    private static let names: [Color] = [Color(red: 0.95, green: 0.75, blue: 0.30), Color(red: 0.72, green: 0.65, blue: 0.98),
                                         Color(red: 0.45, green: 0.80, blue: 0.95), Color(red: 0.95, green: 0.55, blue: 0.60),
                                         Color(red: 0.55, green: 0.85, blue: 0.55)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(model.lines.enumerated()), id: \.offset) { i, line in
                            bubble(line.text, mine: isMine(line), name: showsName(i) ? line.speakerLabel : nil, draft: false)
                        }
                        if model.isLive {
                            ForEach(app.liveLines) { line in
                                bubble(line.text, mine: line.track == .mic, name: line.track == .mic ? nil : line.label,
                                       draft: !line.isFinal).id(line.id)
                            }
                        }
                        empty
                        Color.clear.frame(height: 1).id(Self.bottom)
                    }
                    .padding(14)
                }
                .onAppear { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                .onChange(of: app.liveLines.last?.text) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                .onChange(of: model.lines.count) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
            }
        }
        .frame(height: Self.height)
        .background(RoundedRectangle(cornerRadius: 18).fill(Chrome.capsule))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Chrome.capsuleStroke))
        .shadow(color: .black.opacity(0.22), radius: 14, y: 4)
        .padding(.top, 8)
    }

    private static let bottom = "bottom"

    private var header: some View {
        HStack {
            Text("Transcript").font(.system(size: 13, weight: .semibold))
            if model.isLive {
                Text("Rough draft while recording — names come after").font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }
            Spacer()
            Button(action: close) {
                Image(systemName: "minus").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide the transcript")
        }
        .padding(.horizontal, 16).frame(height: 40)
    }

    @ViewBuilder private var empty: some View {
        if model.lines.isEmpty && !(model.isLive && !app.liveLines.isEmpty) {
            Text(model.isLive ? (app.isPaused ? "Paused." : "Listening…")
                 : model.isWritingUp ? "Writing up the transcript…" : "Nothing recorded yet. Press Record to start.")
                .font(.system(size: 13)).foregroundStyle(.tertiary)
        }
        if model.isLive, let error = app.liveError {
            Text(error).font(.system(size: 12.5)).foregroundStyle(.orange)
        }
    }

    /// A name over the first of each run of lines from the same person; Aidan's own bubbles need none.
    private func showsName(_ i: Int) -> Bool {
        let line = model.lines[i]
        guard !isMine(line) else { return false }
        return i == 0 || model.lines[i - 1].speakerLabel != line.speakerLabel
    }

    /// Aidan: his enrolled voice, or the "Me" label a transcript gives his mic.
    private func isMine(_ line: TranscriptLine) -> Bool {
        if let person = line.personID, person == ownerID { return true }
        return MeetingOverview.shortName(line.speakerLabel) == "Me"
    }

    private var ownerID: UUID? { app.people.all().first { $0.isOwner }?.id }

    private func bubble(_ text: String, mine: Bool, name: String?, draft: Bool) -> some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
            if let name {
                Text(name).font(.system(size: 12, weight: .semibold)).foregroundStyle(colour(for: name)).padding(.top, 6)
            }
            Text(text)
                .font(.system(size: 13.5))
                .foregroundStyle(draft ? .secondary : .primary)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 10).fill(mine ? Chrome.bubbleMine : Chrome.pill))
                .frame(maxWidth: Self.bubbleWidth, alignment: mine ? .trailing : .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    private func colour(for name: String) -> Color {
        Self.names[abs(name.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) }) % Self.names.count]
    }
}

/// Record, Resume (after End or a pause), Pause, or why it can't yet: the bottom bar's record control.
struct RecordControl: View {
    @ObservedObject var model: MeetingModel
    @ObservedObject var app: AppModel

    var body: some View {
        Button(action: act) {
            HStack(spacing: 7) {
                if waiting {
                    ProgressView().controlSize(.small)
                } else if !model.isLive {
                    Circle().fill(model.canRecord ? Chrome.record : Color.secondary).frame(width: 9, height: 9)
                }
                Text(title)
            }
            .font(.system(size: 13.5, weight: .medium))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    private var waiting: Bool { !model.isLive && (model.isStartingRecording || model.isWritingUp) }
    private var enabled: Bool { model.isLive || model.canRecord }

    private var title: String {
        if model.isLive { return app.isPaused ? "Resume" : "Pause" }
        if model.isStartingRecording { return "Starting…" }
        if model.isWritingUp { return "Writing up…" }
        return model.wasRecorded ? "Resume" : "Record"
    }

    private var help: String {
        if model.isLive { return app.isPaused ? "Resume recording" : "Pause recording" }
        if model.canRecord { return model.wasRecorded ? "Record more into this note" : "Start recording this note" }
        if app.isRecording || app.starting { return "Another note is recording — end it first" }
        return "Resume is ready once Lyra has written up the last recording"
    }

    private func act() {
        if model.isLive { app.isPaused ? app.resumeRecording() : app.pauseRecording() } else { app.record(in: model.folder) }
    }
}
