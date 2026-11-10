import LyraCore
import SwiftUI

/// The floating bar: a small capsule that is always there (transcript panel toggle, Record / Resume / Pause, Slides
/// and End while recording a call) and a wide "Ask anything" capsule. Claude's replies and the inline Ask… field sit just above it.
struct BottomBar: View {
    @ObservedObject var model: MeetingModel
    /// Watched directly so Pause / Resume / Record redraw at once.
    @ObservedObject var app: AppModel
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
                transcriptCapsule
                askCapsule
            }
            .frame(maxWidth: 560)
        }
    }

    /// Always there: the transcript panel toggle (breathing dots while recording, "Paused", or a still waveform),
    /// then Record / Resume / Pause, and End while recording.
    private var transcriptCapsule: some View {
        HStack(spacing: 0) {
            Button { drawerOpen.toggle() } label: {
                HStack(spacing: 6) {
                    if model.isLive && app.isPaused {
                        Text("Paused").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
                    } else if model.isLive {
                        LevelDots { app.level }
                    } else {
                        Image(systemName: "waveform").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    // The running recorded time, now that the menu-bar icon no longer shows it.
                    if model.isLive {
                        Text(app.elapsed).font(.system(size: 12.5, weight: .medium)).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: drawerOpen ? "chevron.down" : "chevron.up").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 14).padding(.trailing, 10).frame(height: 38).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(drawerOpen ? "Hide the transcript" : "Show the transcript")
            Divider().frame(height: 18)
            RecordControl(model: model, app: app)
                .padding(.leading, 12).padding(.trailing, model.isLive ? 6 : 16).frame(height: 38)
            if model.isLive, app.slides != nil, !ScreenAccess.isGranted { screenAccessButton }
            if model.isLive, let slides = app.slides { slidesButton(slides) }
            if model.isLive {
                Button { app.stopRecording() } label: {
                    RoundedRectangle(cornerRadius: 2.5).fill(.secondary).frame(width: 10, height: 10)
                        .padding(.leading, 6).padding(.trailing, 14).frame(height: 38).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("End recording and write it up")
            }
        }
        .capsuleSurface()
        .fixedSize()
    }

    /// Shown while recording a call Lyra isn't allowed to see: opens the Screen Recording settings page.
    private var screenAccessButton: some View {
        Button { ScreenAccess.openSettings() } label: {
            HStack(spacing: 4) {
                Image(systemName: "eye.slash").font(.system(size: 12))
                Text("Let Lyra see the call").font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.orange)
            .padding(.horizontal, 6).frame(height: 38).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Lyra can't see the call window, so it can't read names off the call's tiles. Click to turn on Screen Recording for Lyra in System Settings; Lyra may need to be quit and reopened after.")
    }

    /// Slides on or off for the call being recorded, with how many it has saved. Off until clicked.
    private func slidesButton(_ slides: CallSlides) -> some View {
        Button { app.setSlides(!slides.on) } label: {
            HStack(spacing: 4) {
                Image(systemName: slides.on ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle")
                    .font(.system(size: 12.5))
                if slides.on && slides.count > 0 {
                    Text("\(slides.count)").font(.system(size: 12, weight: .medium)).monospacedDigit()
                }
            }
            .foregroundStyle(slides.on ? AnyShapeStyle(Chrome.live) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 6).frame(height: 38).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(slides.on ? "Saving the call's slides (\(slides.count) so far). Click to stop." : "Save the call's slides and shared screens")
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
struct LevelDots: View {
    /// The loudness of the sound being recorded now (peak, 0…1), read every frame.
    let level: () -> Float

    static let minHeight: CGFloat = 4
    static let maxHeight: CGFloat = 13
    /// Quieter than this many dB below full scale is silence; the bars use the range above it.
    private static let floorDB: Float = -50

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { context in
            let heights = Self.heights(peak: level(), time: context.date.timeIntervalSinceReferenceDate)
            HStack(spacing: 2.5) {
                ForEach(0..<3) { i in
                    Capsule().fill(Chrome.live).frame(width: 3.5, height: heights[i])
                }
            }
            .frame(width: 18, height: Self.maxHeight)
            .animation(.easeOut(duration: 0.08), value: heights)
        }
    }

    /// Three bar heights for a peak level: loudness on a dB scale (so speech fills the range), each bar swaying a
    /// little out of step so a steady sound still looks alive. Silence is three still, low bars.
    static func heights(peak: Float, time: Double) -> [CGFloat] {
        let db = 20 * log10(max(peak, 1e-6))
        let loudness = CGFloat(min(max((db - floorDB) / -floorDB, 0), 1))
        return (0..<3).map { i in
            let sway = 0.6 + 0.4 * abs(sin(time * 7 + Double(i) * 1.4))
            return minHeight + (maxHeight - minHeight) * loudness * sway
        }
    }
}
