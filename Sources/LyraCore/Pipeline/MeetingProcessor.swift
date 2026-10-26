import Foundation

/// Turns a finished recording folder into a transcript, a note and compressed audio.
/// Order matters for crash safety: convert → note → transcript.json (the "done" marker) → delete CAFs.
public struct MeetingProcessor: Sendable {
    public static let silentPeak: Float = 0.005
    public static let silentWarning = "Meeting audio was silent — transcript is from your microphone only. If this keeps happening, check System Settings → Privacy & Security → Screen & System Audio Recording for Lyra."

    private let trackTranscriber: TrackTranscriber
    private let loader: @Sendable (URL) throws -> [Float]
    private let convert: @Sendable (URL, URL) async throws -> Void
    private let timeZone: TimeZone

    /// `convert(caf, m4a)` must throw unless `m4a` ends up playable with a non-zero duration.
    public init(trackTranscriber: TrackTranscriber, loader: @escaping @Sendable (URL) throws -> [Float],
                convert: @escaping @Sendable (URL, URL) async throws -> Void, timeZone: TimeZone = .current) {
        self.trackTranscriber = trackTranscriber
        self.loader = loader
        self.convert = convert
        self.timeZone = timeZone
    }

    public func process(meeting: Meeting, tracks: [TrackResult], folder: URL, noteURL: URL) async throws -> URL {
        var meeting = meeting
        if let m = tracks.first(where: { $0.kind == .meeting }), m.peakLevel < Self.silentPeak || m.error != nil {
            meeting.warn(Self.silentWarning)
        }
        var lines: [TrackKind: [TranscriptLine]] = [:]
        for track in tracks {
            let samples: [Float]
            do { samples = try loader(track.url) } catch {
                // An unreadable file won't get better on retry; say so and keep going.
                meeting.warn("Couldn't read \(track.url.lastPathComponent): \(error.localizedDescription)")
                continue
            }
            // Engine failures (e.g. models not downloaded) throw, so the folder is retried next launch.
            lines[track.kind] = try await trackTranscriber.run(samples: samples, track: track.kind)
        }
        let merged = TranscriptMerger.merge(meeting: lines[.meeting] ?? [], mic: lines[.mic] ?? [])

        // Convert first (keeping the CAFs) so a failure can be warned about in the note itself.
        var converted: [URL] = []
        for track in tracks where track.url.pathExtension == "caf" {
            let m4a = track.url.deletingPathExtension().appendingPathExtension("m4a")
            do {
                try? FileManager.default.removeItem(at: m4a)  // leftover from a run a crash cut short
                try await convert(track.url, m4a)
                let size = (try? FileManager.default.attributesOfItem(atPath: m4a.path)[.size] as? Int) ?? 0
                guard size > 0 else { throw CocoaError(.fileReadCorruptFile) }
                converted.append(track.url)
            } catch {
                meeting.warn("Couldn't compress \(track.url.lastPathComponent); the original was kept. (\(error.localizedDescription))")
            }
        }

        let note = NoteRenderer.render(meeting: meeting, lines: merged, recordingsFolder: folder, timeZone: timeZone)
        if let existing = try? String(contentsOf: noteURL, encoding: .utf8) {
            // Our own note from a run cut short after writing it: finish the job, leave the note untouched.
            guard existing.contains("lyra_id: \(meeting.id.uuidString)") else {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: noteURL.path])
            }
        } else {
            try Self.createExclusively(Data(note.utf8), at: noteURL)
        }
        try meeting.save(in: folder)
        try Self.encoder.encode(merged).write(to: folder.appendingPathComponent("transcript.json"), options: .atomic)
        // Only now is the meeting safe without its CAFs; a crash before this point reprocesses the folder.
        for caf in converted { try? FileManager.default.removeItem(at: caf) }
        return noteURL
    }

    /// Folders under `root` holding a `.caf` but no `transcript.json`: recordings a crash left unprocessed.
    public static func pendingFolders(in root: URL) -> [URL] {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.filter { folder in
            let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
            return names.contains { $0.hasSuffix(".caf") } && !names.contains("transcript.json")
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// What crash recovery needs to reprocess `folder`: its saved meeting, its CAFs (with the levels saved
    /// at stop, if any), and its note path. Throws when the folder can't be recovered, so it is never skipped silently.
    public static func recoveryJob(folder: URL, notesDir: URL) throws -> (meeting: Meeting, tracks: [TrackResult], note: URL) {
        var meeting = try Meeting.load(from: folder)
        let cafs = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "caf" }
        let tracks = cafs.compactMap { url -> TrackResult? in
            guard let kind = TrackKind(rawValue: url.deletingPathExtension().lastPathComponent) else { return nil }
            let saved = meeting.tracks?.first { $0.kind == kind }
            // No saved level means Lyra died mid-recording; don't claim silence we never measured.
            return TrackResult(kind: kind, url: url, seconds: saved?.seconds ?? 0, peakLevel: saved?.peakLevel ?? 1, error: saved?.error)
        }.sorted { $0.kind.rawValue < $1.kind.rawValue }
        guard !tracks.isEmpty else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "no meeting.caf or mic.caf in \(folder.lastPathComponent)"])
        }
        if meeting.endedAt == nil {
            meeting.endedAt = cafs.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
            meeting.warn("Recovered after Lyra stopped unexpectedly — the end of the meeting may be missing.")
        }
        return (meeting, tracks, notesDir.appendingPathComponent(folder.lastPathComponent + ".md"))
    }

    /// Writes to a temp file beside `url`, then renames with RENAME_EXCL: never replaces an existing file.
    static func createExclusively(_ data: Data, at url: URL) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard renamex_np(tmp.path, url.path, UInt32(RENAME_EXCL)) == 0 else {
            throw CocoaError(errno == EEXIST ? .fileWriteFileExists : .fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

extension Meeting {
    /// Adds a warning once; a reprocessed meeting must not repeat its warnings.
    mutating func warn(_ text: String) {
        if !warnings.contains(text) { warnings.append(text) }
    }

    /// `meeting.json` is written when recording starts (so crash recovery knows the meeting) and again at the end.
    public func save(in folder: URL) throws {
        try MeetingProcessor.encoder.encode(self).write(to: folder.appendingPathComponent("meeting.json"), options: .atomic)
    }

    public static func load(from folder: URL) throws -> Meeting {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(Meeting.self, from: Data(contentsOf: folder.appendingPathComponent("meeting.json")))
    }
}
