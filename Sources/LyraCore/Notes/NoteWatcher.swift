import Foundation

/// Calls `onChange` (on `queue`) soon after a file changes, however it was written: in place, or replaced by a
/// rename as Lyra and many editors do. After a replace it watches the new file at the same path; when the path is
/// gone (the note was moved), `onChange` still fires so the owner can find the note and `watch` its new place.
/// Watching starts before `init` and `watch` return, so no write after them is missed.
public final class NoteWatcher: @unchecked Sendable {
    private static let settle: DispatchTimeInterval = .milliseconds(100)
    private static let rearmTries = 20

    private let queue: DispatchQueue
    private let onChange: @Sendable () -> Void
    private let lock = NSLock()
    // Guarded by `lock`.
    private var url: URL
    private var source: DispatchSourceFileSystemObject?
    private var pending = false
    private var stopped = false

    public init(url: URL, queue: DispatchQueue = .main, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.queue = queue
        self.onChange = onChange
        arm(tries: 0)
    }

    /// Watches `url` instead (the note was renamed or moved).
    public func watch(_ url: URL) {
        lock.withLock {
            guard url.standardizedFileURL != self.url.standardizedFileURL else { return }
            self.url = url
            source?.cancel()
            source = nil
        }
        arm(tries: 0)
    }

    public func stop() {
        lock.withLock {
            stopped = true
            source?.cancel()
            source = nil
        }
    }

    private func arm(tries: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, source == nil else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            // Mid-replace the path can be empty for a moment.
            if tries < Self.rearmTries { queue.asyncAfter(deadline: .now() + .milliseconds(50)) { self.arm(tries: tries + 1) } }
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib], queue: queue)
        source.setEventHandler { [weak self, unowned source] in
            guard let self else { return }
            if !source.data.isDisjoint(with: [.delete, .rename]) {
                self.lock.withLock {
                    source.cancel()
                    if self.source === source { self.source = nil }
                }
                self.arm(tries: 0)
            }
            self.changed()
        }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    /// Several events from one save become one call.
    private func changed() {
        let first = lock.withLock { () -> Bool in
            guard !pending else { return false }
            pending = true
            return true
        }
        guard first else { return }
        queue.asyncAfter(deadline: .now() + Self.settle) {
            let live = self.lock.withLock { () -> Bool in
                self.pending = false
                return !self.stopped
            }
            if live { self.onChange() }
        }
    }
}
