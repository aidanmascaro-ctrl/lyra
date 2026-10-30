import LyraCore
import SwiftUI

/// One sidebar row: lights up softly under the pointer, and sits in a pill when it is the page being shown.
struct SidebarRow<Content: View>: View {
    var selected = false
    var indent: CGFloat = 0
    let action: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    static var height: CGFloat { 28 }

    var body: some View {
        HStack(spacing: 7) { content() }
            .font(.system(size: 13.5))
            .lineLimit(1)
            .padding(.leading, 6 + indent).padding(.trailing, 8)
            .frame(height: Self.height)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Chrome.pill : hovering ? Chrome.hover : .clear))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .onHover { hovering = $0 }
            .accessibilityAddTraits(.isButton)
    }
}

/// A sidebar folder: chevron, coloured glyph, name (or the inline rename field), and its note count.
struct FolderRow: View {
    let folder: SidebarFolder
    let count: Int
    let selected: Bool
    @Binding var expanded: Bool
    let editing: Bool
    let open: () -> Void
    /// The new name, or nil when renaming was called off.
    let renamed: (String?) -> Void
    let menu: FolderMenu

    var body: some View {
        SidebarRow(selected: selected, action: { if !editing { open() } }) {
            Button { expanded.toggle() } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 12, height: SidebarRow<EmptyView>.height).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide its meetings" : "Show its meetings")
            FolderGlyph(colour: folder.colour)
            if editing {
                FolderNameField(name: folder.name, done: renamed)
            } else {
                Text(folder.name).foregroundStyle(.primary)
                Spacer(minLength: 6)
                if count > 0 { Text("\(count)").font(.system(size: 12)).foregroundStyle(.tertiary).monospacedDigit() }
            }
        }
        .animation(SidebarModel.spring, value: expanded)
        .contextMenu {
            Button("Rename…", action: menu.rename)
            FolderColourMenu(current: folder.colour, choose: menu.colour)
            Divider()
            Button("Remove folder…", action: menu.remove)
        }
    }
}

/// What a folder row's right-click offers.
struct FolderMenu {
    let rename: () -> Void
    let colour: (FolderColour) -> Void
    let remove: () -> Void
}

/// The folder's name, editable in place: Return saves, Esc (or an empty name) calls it off.
private struct FolderNameField: View {
    let name: String
    let done: (String?) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Folder name", text: $draft)
            .textFieldStyle(.plain)
            .focused($focused)
            .onSubmit { finish(draft) }
            .onExitCommand { finish(nil) }
            .onAppear {
                draft = name
                DispatchQueue.main.async { focused = true }
            }
    }

    private func finish(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        done(trimmed.isEmpty || trimmed == name ? nil : trimmed)
    }
}

/// A meeting listed under its expanded folder: its title on one line.
struct SidebarNoteRow: View {
    let summary: MeetingSummary
    let selected: Bool
    let open: () -> Void

    var body: some View {
        SidebarRow(selected: selected, indent: 33, action: open) {
            Text(summary.title.isEmpty ? "Untitled" : summary.title)
                .font(.system(size: 13)).foregroundStyle(selected ? .primary : .secondary)
            Spacer(minLength: 0)
        }
        .help(summary.title)
    }
}
