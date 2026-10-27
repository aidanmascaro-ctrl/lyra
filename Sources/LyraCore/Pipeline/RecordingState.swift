import Foundation

/// Start/stop bookkeeping for the one recording Lyra runs at a time. Starting takes up to ~3 s
/// (process objects appear late), so a stop or the call ending during that window is remembered
/// and applied the moment recording is running. A running recording can be paused and resumed; ending it or the
/// call ending works the same paused or not.
public struct RecordingState: Sendable {
    public enum Phase: Equatable, Sendable { case idle, starting(MicUser?), recording(MicUser?), paused(MicUser?) }

    public private(set) var phase: Phase = .idle
    private var stopPending = false

    public init() {}

    /// False if a recording is already starting or running.
    public mutating func begin(target: MicUser?) -> Bool {
        guard phase == .idle else { return false }
        phase = .starting(target)
        stopPending = false
        return true
    }

    /// Call once recording is running. True means a stop arrived while starting: stop it now.
    public mutating func started() -> Bool {
        guard case .starting(let target) = phase else { return false }
        if stopPending { phase = .idle; stopPending = false; return true }
        phase = .recording(target)
        return false
    }

    public mutating func failed() { phase = .idle; stopPending = false }

    /// True when the caller should pause the running recording now.
    public mutating func pause() -> Bool {
        guard case .recording(let target) = phase else { return false }
        phase = .paused(target)
        return true
    }

    /// True when the caller should resume the paused recording now.
    public mutating func resume() -> Bool {
        guard case .paused(let target) = phase else { return false }
        phase = .recording(target)
        return true
    }

    /// True when the caller should stop the running (or paused) recording now.
    public mutating func requestStop() -> Bool {
        switch phase {
        case .idle: return false
        case .starting: stopPending = true; return false
        case .recording, .paused: phase = .idle; return true
        }
    }

    /// Only the app being recorded can end it; an in-person recording never ends this way.
    public mutating func meetingEnded(_ user: MicUser) -> Bool {
        switch phase {
        case .starting(let t?) where t == user, .recording(let t?) where t == user, .paused(let t?) where t == user:
            return requestStop()
        default: return false
        }
    }
}
