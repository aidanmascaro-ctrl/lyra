import AppKit
import LyraCore
import SwiftUI

/// Serif title (edit it to rename the note), a row of pills (date · series · people · tags), and the tabs.
struct MeetingHeader: View {
    @ObservedObject var model: MeetingModel
    @FocusState private var titleFocused: Bool
    @State private var newSeries: String?
    @State private var confirmTrash = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("New note", text: $model.titleDraft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Chrome.titleFont)
                .focused($titleFocused)
                // Return just ends editing; losing focus is the one place the title is committed.
                .onSubmit { titleFocused = false }
                .onChange(of: titleFocused) {
                    if titleFocused { model.editingTitle = true } else { model.commitTitle() }
                }
            pills
            tabs.padding(.top, 6)
        }
        .padding(.bottom, 6)
        .alert("Move “\(model.titleDraft.isEmpty ? "Untitled" : model.titleDraft)” to the Trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) { model.trash() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The Obsidian note and its recordings go to the Mac's Trash. You can put them back from the Trash in Finder.") }
        .alert("New series", isPresented: Binding(get: { newSeries != nil }, set: { if !$0 { newSeries = nil } })) {
            TextField("Series name", text: Binding(get: { newSeries ?? "" }, set: { newSeries = $0 }))
            Button("Add") { if let name = newSeries?.trimmingCharacters(in: .whitespaces), !name.isEmpty { model.move(to: name) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This meeting moves into a folder of that name in Meetings.") }
    }

    private var pills: some View {
        HStack(spacing: 6) {
            if let date = model.loaded?.document.front.date ?? model.meeting?.startedAt {
                Pill { Label(Self.when(date), systemImage: "calendar") }
            }
            seriesChip
            if !people.isEmpty { Pill { Label(people.joined(separator: ", "), systemImage: "person.2") }.lineLimit(1) }
            if let front = model.loaded?.document.front, !(front.tags.isEmpty && front.links.isEmpty) {
                Text((front.tags.map { "#\($0)" } + front.links.filter { !people.contains($0) }.map { "[[\($0)]]" }).joined(separator: " "))
                    .font(.system(size: 12)).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .labelStyle(PillLabelStyle())
    }

    @ViewBuilder private var seriesChip: some View {
        if let suggestion = model.suggestion {
            Pill {
                HStack(spacing: 8) {
                    Label("Part of \(suggestion)?", systemImage: "folder")
                    Button("Add") { model.move(to: suggestion) }.buttonStyle(.plain).foregroundStyle(.primary)
                    Button("Not related") { model.notRelated() }.buttonStyle(.plain).foregroundStyle(.primary)
                }
            }
        } else {
            Menu {
                ForEach(model.knownSeries.filter { $0 != model.series }, id: \.self) { name in
                    Button(name) { model.move(to: name) }
                }
                Button("New series…") { newSeries = "" }
                if model.series != nil {
                    Divider()
                    Button("Remove from series") { model.move(to: nil) }
                }
            } label: {
                Pill { Label(model.series ?? "Add to series", systemImage: "folder") }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var people: [String] {
        MeetingOverview.speakers(in: model.lines).map(\.label).filter { $0.range(of: #"^Speaker \d+$"#, options: .regularExpression) == nil }
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            tab("My notes", .myNotes)
            tab("Expanded", .expanded)
            tab("Transcript", .transcript)
            Spacer()
            Menu {
                Button("Re-expand") { model.reExpand() }.disabled(model.working != nil || model.lines.isEmpty)
                Button("Open in Obsidian") { if let url = model.loaded?.url { NSWorkspace.shared.open(url) } }
                Divider()
                Button("Move to Trash", role: .destructive) { confirmTrash = true }
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(.secondary).frame(width: 24, height: 20)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        }
    }

    private func tab(_ title: String, _ tab: MeetingTab) -> some View {
        let selected = model.tab == tab
        return Button { model.tab = tab } label: {
            Text(title)
                .font(.system(size: 13, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(selected ? Chrome.pill : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    static func when(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today " + date.formatted(date: .omitted, time: .shortened) }
        return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
}

private struct PillLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}
