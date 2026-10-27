import LyraCore
import SwiftUI

/// The rough live transcript, slid up above the bottom bar while recording. Lines are labelled by track only
/// (Me / Them); names come with the full transcript after the meeting, and this draft is thrown away.
struct LiveDrawer: View {
    @ObservedObject var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Live transcript").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text("Rough draft — names come after the meeting").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if app.liveLines.isEmpty && app.liveError == nil {
                            Text("Listening…").foregroundStyle(.tertiary)
                        }
                        ForEach(app.liveLines) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(line.label).fontWeight(.semibold).frame(width: 40, alignment: .leading)
                                    .foregroundStyle(line.track == .mic ? Chrome.live : .secondary)
                                Text(line.text).foregroundStyle(line.isFinal ? .primary : .secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .id(line.id)
                        }
                        if let error = app.liveError {
                            Text(error).foregroundStyle(.orange)
                        }
                    }
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: app.liveLines.last?.text) {
                    if let last = app.liveLines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .padding(14)
        .frame(height: 220)
        .background(RoundedRectangle(cornerRadius: 14).fill(Chrome.capsule))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Chrome.capsuleStroke))
        .padding(.top, 8)
    }
}
