import Foundation

public enum TrackKind: String, Codable, Sendable { case meeting, mic }

public struct Meeting: Codable, Sendable {
    public let id: UUID
    public var title: String
    public let appName: String
    public let bundleID: String?
    public let startedAt: Date
    public var endedAt: Date?
    public var warnings: [String]

    public init(id: UUID = UUID(), title: String, appName: String, bundleID: String? = nil,
                startedAt: Date, endedAt: Date? = nil, warnings: [String] = []) {
        self.id = id; self.title = title; self.appName = appName; self.bundleID = bundleID
        self.startedAt = startedAt; self.endedAt = endedAt; self.warnings = warnings
    }
}
