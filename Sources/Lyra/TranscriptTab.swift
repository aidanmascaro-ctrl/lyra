import LyraCore
import SwiftUI

/// The named transcript. Click a speaker to rename them (which also teaches Lyra that voice); lines found by
/// Find in transcript are highlighted and scrolled to.
struct TranscriptTab: View {
    @ObservedObject var model: MeetingModel
    let people: PeopleStore
    @State private var editing: String?
    @State private var newName = ""

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.lines.isEmpty {
                        Text(model.isLive ? "The full transcript, with names, is made after the meeting. Open the live transcript from the bar below."
                                          : "No transcript yet.")
                            .font(.system(size: 14)).foregroundStyle(.tertiary)
                    } else {
                        speakers
                        lines
                    }
                }
                .noteColumn()
                .padding(.vertical, 24)
            }
            .onAppear { scroll(proxy) }
            .onChange(of: model.highlighted) { scroll(proxy) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let first = model.highlighted.min() else { return }
        withAnimation { proxy.scrollTo(first, anchor: .center) }
    }

    private var speakers: some View {
        HStack(spacing: 6) {
            ForEach(model.speakers, id: \.label) { s in
                Button { editing = s.label; newName = s.label.hasPrefix("Speaker ") ? "" : s.label } label: {
                    Pill {
                        HStack(spacing: 5) {
                            Text(s.label).foregroundStyle(.primary)
                            if let badge = Self.badge(s.source) { Text(badge) }
                            Text(Self.duration(s.seconds)).monospacedDigit()
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(model.renaming)
                .help("Rename this speaker")
                .popover(isPresented: Binding(get: { editing == s.label }, set: { if !$0 { editing = nil } })) {
                    renameField(for: s.label).padding(14).frame(width: 240)
                }
            }
            if model.renaming { ProgressView().controlSize(.small) }
        }
    }

    private func renameField(for label: String) -> some View {
        let typed = newName.trimmingCharacters(in: .whitespaces).lowercased()
        let suggestions = people.all().map(\.name)
            .filter { typed.isEmpty || $0.lowercased().hasPrefix(typed) }
            .filter { $0.lowercased() != typed }
            .sorted()
            .prefix(5)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Who is \(label)?").font(.headline)
            TextField("Name", text: $newName).onSubmit { commit(label) }
            ForEach(Array(suggestions), id: \.self) { name in
                Button(name) { newName = name }.buttonStyle(.link)
            }
            HStack {
                Spacer()
                Button("Cancel") { editing = nil }
                Button("Rename") { commit(label) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func commit(_ label: String) {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        editing = nil
        model.rename(label, to: name)
    }

    private var lines: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(model.lines.indices, id: \.self) { i in
                let line = model.lines[i]
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(Self.stamp(line.start)).monospacedDigit().foregroundStyle(.tertiary).frame(width: 48, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.speakerLabel).fontWeight(.semibold)
                        Text(line.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.system(size: 14))
                .padding(.horizontal, 8).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(model.highlighted.contains(i) ? Color.yellow.opacity(0.16) : .clear))
                .id(i)
            }
        }
        .padding(.horizontal, -8)
    }

    static func badge(_ source: NameSource?) -> String? {
        switch source {
        case .knownVoice: "known voice"
        case .onScreen: "on screen"
        case .setByAidan: "named by you"
        case nil: nil
        }
    }

    static func duration(_ s: Double) -> String {
        let total = Int(s.rounded())
        return total < 60 ? "\(total) s" : "\(total / 60) min"
    }

    static func stamp(_ t: Double) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
}
