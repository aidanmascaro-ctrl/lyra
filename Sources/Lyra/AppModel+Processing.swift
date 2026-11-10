import AppKit
import CoreGraphics
import LyraAudio
import LyraCore
import LyraSpeech

/// Processing: the background queue that transcribes, writes up and expands each meeting, one at a time.
extension AppModel {
    typealias Job = (meeting: Meeting, tracks: [TrackResult], folder: URL, note: URL)

    /// Processes jobs one at a time, off the main actor, then files and expands each one; results hop back here.
    func run(_ jobs: [Job]) {
        guard !jobs.isEmpty else { return }
        processingCount += jobs.count
        let processor = processor
        for job in jobs {
            enqueue(folder: job.folder) {
                let result = await Result { try await processor.process(meeting: job.meeting, tracks: job.tracks, folder: job.folder, noteURL: job.note) }
                await self.finished(result, folder: job.folder)
                if case .success = result { await self.expand(folder: job.folder, id: job.meeting.id) }
            }
        }
    }

    /// Runs the after-meeting step again for an already processed meeting (the meeting window's Retry).
    func runAfterMeeting(folder: URL) {
        enqueue(folder: folder) {
            do { await self.expand(folder: folder, id: try Meeting.load(from: folder).id) } catch {
                await self.report("Couldn't read \(folder.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    /// Re-expand from the meeting window: streams into `liveExpansion` like the first expansion. Throws in plain
    /// English; the note is left as it was on failure.
    func reExpand(folder: URL, id: UUID) async throws {
        let after = afterMeeting
        busyFolders[folder.standardizedFileURL.path, default: 0] += 1
        defer { showExpansion(nil, for: id); endBusy(folder); revision += 1 }
        try await after.reExpand(folder: folder) { blocks in await self.showExpansion(blocks, for: id) }
    }

    /// Suggest names from the Transcript tab. The meeting counts as busy meanwhile, so it can't be written up, trashed
    /// or named twice at once. Returns how the note fared (`.needsConfirmation`: its transcript was edited by hand).
    func suggestNames(folder: URL) async throws -> RenameOutcome {
        let (namer, notes) = (talkNamer, notes)
        busyFolders[folder.standardizedFileURL.path, default: 0] += 1
        defer { endBusy(folder); revision += 1 }
        return try await Task.detached {
            try await namer.run(folder: folder, note: RenameService.noteURL(inMeetingFolder: folder, index: notes)).note
        }.value
    }

    private func enqueue(folder: URL, _ work: @escaping @Sendable () async -> Void) {
        busyFolders[folder.standardizedFileURL.path, default: 0] += 1
        let previous = pipeline
        pipeline = Task.detached {
            await previous?.value
            await work()
            await self.release(folder)
        }
    }

    private func release(_ folder: URL) { endBusy(folder) }

    private func endBusy(_ folder: URL) {
        let key = folder.standardizedFileURL.path
        busyFolders[key] = (busyFolders[key] ?? 1) > 1 ? (busyFolders[key] ?? 1) - 1 : nil
    }

    /// True while this meeting is being recorded, processed, queued or expanded: it can't be moved to the Trash then.
    func isBusy(folder: URL?, id: UUID?) -> Bool {
        if let id, liveExpansion[id] != nil { return true }
        guard let folder else { return false }
        let key = folder.standardizedFileURL.path
        return busyFolders[key] != nil || session?.folder.standardizedFileURL.path == key
            || liveMeeting?.folder.standardizedFileURL.path == key || startingFolder?.standardizedFileURL.path == key
    }

    /// Title, tags, rename and Claude's expansion. A failure is saved in meeting.json for the meeting window.
    private nonisolated func expand(folder: URL, id: UUID) async {
        let after = await afterMeeting
        do {
            try await after.run(folder: folder) { blocks in await self.showExpansion(blocks, for: id) }
        } catch {
            await report(ErrorBrief.sentence("Couldn't finish the notes for \(folder.lastPathComponent)", error))
        }
        await showExpansion(nil, for: id)
        await bumpRevision()
    }

    private func bumpRevision() { revision += 1 }

    private func showExpansion(_ blocks: [NoteBlock]?, for id: UUID) {
        liveExpansion[id] = blocks
    }

    private func finished(_ result: Result<URL, Error>, folder: URL) {
        processingCount -= 1
        revision += 1
        if case .failure(let error) = result {
            report("Processing \(folder.lastPathComponent) failed (will retry next launch): \(error.localizedDescription)")
        }
    }

    private func report(_ message: String) {
        lastError = message  // the latest problem only
    }

    /// Any folder with `.caf` files but no `transcript.json` was cut short by a crash or quit.
    /// A folder that can't be recovered is reported, never skipped silently.
    func recoverUnprocessed() {
        var jobs: [Job] = []
        for folder in MeetingProcessor.pendingFolders(in: paths.recordingsRoot) {
            do {
                let job = try MeetingProcessor.recoveryJob(folder: folder, notesDir: paths.notesDir)
                jobs.append((job.meeting, job.tracks, folder, job.note))
            } catch {
                report("Couldn't recover \(folder.lastPathComponent): \(error.localizedDescription)")
            }
        }
        run(jobs)
    }
}

private extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
