import Foundation

/// A recording Quit stopped, offered on the next launch: Resume carries on in the same note, Not now writes it up.
/// While offered it isn't written up — for `lifetime`, then it is written up as if Aidan had said Not now.
public struct ResumeOffer: Equatable, Sendable {
    public static let lifetime: TimeInterval = 15 * 60

    public let folder: URL
    public let title: String
    /// The meeting app recorded, for recording its sound again on Resume; nil for an in-person note.
    public let bundleID: String?
    public let appName: String
    /// When Quit stopped it.
    public let stoppedAt: Date?

    /// Unprocessed folders (`MeetingProcessor.pendingFolders`) split into offers and crashes to recover. A folder
    /// whose meeting.json can't be read goes to recovery, which says why.
    public static func split(pending: [URL]) -> (offers: [ResumeOffer], recover: [URL]) {
        var offers: [ResumeOffer] = []
        var recover: [URL] = []
        for folder in pending {
            guard let meeting = try? Meeting.load(from: folder), meeting.stoppedByQuit == true else {
                recover.append(folder)
                continue
            }
            offers.append(ResumeOffer(folder: folder, title: meeting.title, bundleID: meeting.bundleID,
                                      appName: meeting.appName, stoppedAt: meeting.endedAt))
        }
        return (offers, recover)
    }

    /// Quit stopped this recording: set after its files are closed.
    public static func markStoppedByQuit(folder: URL) throws {
        var meeting = try Meeting.load(from: folder)
        meeting.stoppedByQuit = true
        try meeting.save(in: folder)
    }

    /// Not now (or the offer ran out): written up like any recording from here on.
    public static func decline(folder: URL) throws {
        var meeting = try Meeting.load(from: folder)
        meeting.stoppedByQuit = nil
        try meeting.save(in: folder)
    }

    public static func isOffered(folder: URL) -> Bool {
        (try? Meeting.load(from: folder))?.stoppedByQuit == true
    }

    public static func expired(offeredAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(offeredAt) >= lifetime
    }
}
