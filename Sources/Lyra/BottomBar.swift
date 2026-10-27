import LyraCore
import SwiftUI

/// The floating bar: while recording, a small capsule (live transcript toggle with a level dot row, and stop);
/// always, a wide "Ask anything" capsule. Claude's replies and the inline Ask… field sit just above it.
struct BottomBar: View {
    @ObservedObject var model: MeetingModel
    @Binding var drawerOpen: Bool
    @State private var draft = ""
    @State private var question = ""
    @FocusState private var questionFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            if let ask = model.inlineAsk { inlineAsk(ask.selection) }
            if let answer = model.answer { answerCard(answer.question, answer.text) }
            if let error = model.claudeError {
                Banner(text: error) { Button("OK") { model.claudeError = nil } }.frame(maxWidth: 560)
            }
            HStack(spacing: 10) {
                if model.isLive { liveCapsule }
                askCapsule
            }
            .frame(maxWidth: 560)
        }
    }

    private var liveCapsule: some View {
        HStack(spacing: 0) {
            Button { drawerOpen.toggle() } label: {
                HStack(spacing: 6) {
                    LevelDots()
                    Image(systemName: drawerOpen ? "chevron.down" : "chevron.up").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 14).padding(.trailing, 10).frame(height: 38).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(drawerOpen ? "Hide the live transcript" : "Show the live transcript")
            Divider().frame(height: 18)
            Button { model.app.stopRecording() } label: {
                RoundedRectangle(cornerRadius: 2.5).fill(.secondary).frame(width: 10, height: 10)
                    .padding(.leading, 10).padding(.trailing, 14).frame(height: 38).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Stop recording")
        }
        .capsuleSurface()
        .fixedSize()
    }

    private var askCapsule: some View {
        HStack(spacing: 8) {
            TextField("Ask anything or add an idea…", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .onSubmit {
                    model.submitBar(draft)
                    draft = ""
                }
            if let working = model.working {
                ProgressView().controlSize(.small).help(working)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 38)
        .capsuleSurface()
    }

    private func inlineAsk(_ selection: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask about “\(selection.prefix(80))\(selection.count > 80 ? "…" : "")”")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                TextField("Your question", text: $question)
                    .textFieldStyle(.plain).font(.system(size: 14)).focused($questionFocused)
                    .onSubmit { model.askInline(question); question = "" }
                Button("Cancel") { model.inlineAsk = nil; question = "" }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: 560, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Chrome.capsule))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Chrome.capsuleStroke))
        .onAppear { questionFocused = true }
    }

    private func answerCard(_ question: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(question).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            ScrollView {
                Text(text).font(.system(size: 14)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Add to notes") { model.addAnswerToNotes() }
                Spacer()
                Button("Dismiss") { model.answer = nil }.foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).font(.system(size: 12.5, weight: .medium))
        }
        .padding(14)
        .frame(maxWidth: 560, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Chrome.capsule))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Chrome.capsuleStroke))
    }
}

/// Granola's little green "•••": three dots breathing in turn while Lyra records.
private struct LevelDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<3) { i in
                    Capsule().fill(Chrome.live)
                        .frame(width: 3.5, height: 5 + 6 * abs(sin(t * 3.2 + Double(i) * 0.9)))
                }
            }
            .frame(width: 18, height: 12)
        }
    }
}
