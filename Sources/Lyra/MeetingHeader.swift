import AppKit
import LyraCore
import SwiftUI

/// Serif title (edit it to rename the note), a row of pills (date · series · people · slides · tags), and the tabs.
struct MeetingHeader: View {
    @ObservedObject var model: MeetingModel
    @FocusState private var titleFocused: Bool
    @State private var newSeries: String?
    @State private var confirmTrash = false
    @State private var showTags = Self.tagsOpenAtLaunch
    @State private var showPeople = Self.peopleOpenAtLaunch

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

    /// Wraps to further lines rather than cutting anything off; every pill the same height, centred on its line.
    private var pills: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            if let date = model.loaded?.document.front.date ?? model.meeting?.startedAt {
                Pill { Label(Self.when(date), systemImage: "calendar") }.headerPill()
            }
            seriesChip.headerPill()
            if people.count > MeetingOverview.peopleShown {
                peopleToggle
                if showPeople { ForEach(people, id: \.self) { name in TagPill(text: MeetingOverview.shortName(name)) } }
            } else if !people.isEmpty {
                Pill { Label(MeetingOverview.peoplePill(people), systemImage: "person.2") }
                    .headerPill()
                    .help(people.joined(separator: ", "))
            }
            if let front = model.loaded?.document.front {
                if front.slides > 0 { slidesPill(front) }
                if !front.tags.isEmpty { tagsToggle(count: front.tags.count) }
                if showTags { ForEach(front.tags, id: \.self) { tag in TagPill(text: "#\(tag)") } }
                ForEach(front.links.filter { !people.contains($0) }, id: \.self) { link in
                    TagPill(text: link, systemImage: "link")
                }
            }
        }
        .labelStyle(PillLabelStyle())
    }

    /// The call's slides, saved in the recordings folder; the pill opens that folder in Finder.
    private func slidesPill(_ front: NoteFrontmatter) -> some View {
        Button {
            NSWorkspace.shared.open(front.recordings.appendingPathComponent(SlideLog.folderName, isDirectory: true))
        } label: {
            Pill { Label(front.slides == 1 ? "1 slide" : "\(front.slides) slides", systemImage: "rectangle.on.rectangle") }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .headerPill()
        .help("Show the slides in Finder")
    }

    /// Tags stay folded behind one quiet pill until it's clicked; clicking again folds them away.
    private func tagsToggle(count: Int) -> some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { showTags.toggle() } } label: {
            TagPill(text: showTags ? "Hide tags" : (count == 1 ? "1 tag" : "\(count) tags"), systemImage: "number")
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(showTags ? "Hide tags" : "Show tags")
    }

    /// More people than the pill can name: like the tags, clicking lays every name out as its own pill.
    private var peopleToggle: some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { showPeople.toggle() } } label: {
            Pill { Label(showPeople ? "Hide people" : MeetingOverview.peoplePill(people), systemImage: "person.2") }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .headerPill()
        .help(showPeople ? "Hide people" : "Show everyone")
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
            if model.showsTranscriptTab { tab("Transcript", .transcript) }
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

    #if DEBUG
    private static var tagsOpenAtLaunch: Bool { DebugLaunch.tagsOpen }
    private static var peopleOpenAtLaunch: Bool { DebugLaunch.peopleOpen }
    #else
    private static let tagsOpenAtLaunch = false
    private static let peopleOpenAtLaunch = false
    #endif

    static func when(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today " + date.formatted(date: .omitted, time: .shortened) }
        return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
}

/// One tag or link: a pill like the others, a step quieter.
private struct TagPill: View {
    let text: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)  // as `Pill`, so every pill on the row is the same height
        .background(Capsule().fill(Chrome.pill.opacity(0.55)))
    }
}

private extension View {
    /// One line: a pill moves to the next line of the row rather than wrapping its own text.
    func headerPill() -> some View { lineLimit(1) }
}

private struct PillLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}
