import CoreTransferable
import LyraCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A meeting dragged inside Lyra. Declared in Info.plist (`UTExportedTypeDeclarations`).
    static let lyraMeeting = UTType(exportedAs: "au.aidos.lyra.meeting")
}

/// What a dragged meeting row carries: the note's `lyra_id`, and its title for the lifted capsule.
struct MeetingDrag: Codable, Equatable, Transferable {
    let id: UUID
    let title: String

    init(id: UUID, title: String) {
        self.id = id
        self.title = title
    }

    init(_ summary: MeetingSummary) {
        self.init(id: summary.id, title: summary.title)
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .lyraMeeting)
    }
}

/// The meeting as it lifts under the pointer: a small capsule with its title.
struct MeetingDragPreview: View {
    let title: String

    var body: some View {
        Text(title.isEmpty ? "Untitled" : title)
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .frame(maxWidth: 260)
            .padding(.horizontal, 14).frame(height: 30)
            .capsuleSurface()
            .padding(12)  // Room for the capsule's shadow.
    }
}

extension View {
    /// Lets this meeting row be dragged onto a sidebar folder, the Home row or a folder page.
    func meetingDraggable(_ summary: MeetingSummary, sidebar: SidebarModel) -> some View {
        draggable(sidebar.dragPayload(for: summary)) { MeetingDragPreview(title: summary.title) }
    }

    /// Makes this view a place to drop meetings. `lit` is true while a meeting that can land here is over it
    /// (never for one already there), animated with the sidebar's spring.
    func meetingDropTarget(into folder: String?, sidebar: SidebarModel, lit: Binding<Bool>) -> some View {
        dropDestination(for: MeetingDrag.self) { items, _ in
            lit.wrappedValue = false
            return sidebar.drop(items, into: folder)
        } isTargeted: { targeted in
            withAnimation(SidebarModel.spring) { lit.wrappedValue = targeted && sidebar.accepts(into: folder) }
        }
    }
}
