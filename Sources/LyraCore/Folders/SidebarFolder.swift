import Foundation

/// The eight muted colours a sidebar folder can have, in the order new folders take them.
public enum FolderColour: String, Codable, CaseIterable, Sendable {
    case blue, green, orange, purple, teal, red, yellow, grey
}

/// One of Aidan's sidebar folders: a directory under `Meetings/` that holds Lyra's marker file.
public struct SidebarFolder: Equatable, Hashable, Sendable {
    public let name: String
    public let colour: FolderColour

    public init(name: String, colour: FolderColour) {
        self.name = name
        self.colour = colour
    }
}

public enum MeetingFoldersError: Error, Equatable, LocalizedError {
    case emptyName
    case invalidName(String)
    case nameTaken(String)
    case missingFolder(String)

    public var errorDescription: String? {
        switch self {
        case .emptyName: "A folder needs a name."
        case .invalidName(let name): "“\(name)” can't be a folder name: names can't start with a dot or use any of / : \\ ? * \" < > # [ ] ^ |"
        case .nameTaken(let name): "There is already a folder or series called “\(name)”."
        case .missingFolder(let name): "Lyra couldn't find a folder called “\(name)”."
        }
    }
}
