import LyraCore
import SwiftUI

/// Home's card for a recording Quit stopped: Resume records on into the same note, Not now writes it up.
/// The card itself opens the note.
struct ResumeOfferCard: View {
    @ObservedObject var app: AppModel
    let offer: ResumeOffer

    var body: some View {
        HStack(spacing: 12) {
            Button { app.route = .meeting(offer.folder) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "pause.circle").font(.system(size: 18)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(offer.title.isEmpty ? offer.appName : offer.title)
                            .font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        Text(subtitle).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 12)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open the note")
            Button("Not now") { app.declineResume(offer) }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).frame(height: 30)
                .help("Write up what was recorded. You can still Resume from the note later.")
            Button { app.record(in: offer.folder) } label: {
                HStack(spacing: 6) {
                    Circle().fill(canResume ? Chrome.record : Color.secondary).frame(width: 8, height: 8)
                    Text("Resume")
                }
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 14).frame(height: 30)
                .background(Capsule().fill(Chrome.pill))
            }
            .buttonStyle(.plain)
            .disabled(!canResume)
            .help(canResume ? "Record on into this note" : "Something else is recording")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Chrome.pill))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Chrome.capsuleStroke))
    }

    private var canResume: Bool { app.canRecord(in: offer.folder) }

    private var subtitle: String {
        let time = offer.stoppedAt.map { " at " + $0.formatted(date: .omitted, time: .shortened) } ?? ""
        return "Recording stopped when Lyra quit\(time)"
    }
}
