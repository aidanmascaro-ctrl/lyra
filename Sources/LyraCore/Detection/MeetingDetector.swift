import Foundation

public enum DetectorEvent: Equatable {
    case meetingStarted(MicUser)
    case meetingEnded(MicUser)
}

/// Turns successive mic-usage snapshots into start/end events. Not thread-safe; drive from one actor/queue.
public final class MeetingDetector {
    private let ownPID: pid_t
    private let ignoredBundleIDs: Set<String>
    private let endGrace: TimeInterval
    private var active: MicUser?
    /// Users seen recently (value = last-seen time), kept until absent for `endGrace`; only users not in it count as newly started.
    private var known: [MicUser: Date] = [:]
    private var lastSeen = Date.distantPast

    /// Set by the owner while a recording is in progress; suppresses new starts.
    public var isRecording = false

    public init(ownPID: pid_t, ignoredBundleIDs: Set<String>, endGrace: TimeInterval = 10) {
        self.ownPID = ownPID
        self.ignoredBundleIDs = ignoredBundleIDs
        self.endGrace = endGrace
    }

    public func update(users: [MicUser], now: Date) -> [DetectorEvent] {
        let eligible = users.filter { $0.pid != ownPID && !ignoredBundleIDs.contains($0.bundleID) }

        known = known.filter { now.timeIntervalSince($0.value) < endGrace }
        let fresh = eligible.filter { known[$0] == nil }
        for user in eligible { known[user] = now }

        if let current = active {
            if eligible.contains(current) {
                lastSeen = now
                return []
            }
            guard now.timeIntervalSince(lastSeen) >= endGrace else { return [] }
            active = nil
            return [.meetingEnded(current)]
        }

        guard !isRecording, let first = fresh.first else { return [] }
        active = first
        lastSeen = now
        return [.meetingStarted(first)]
    }
}
