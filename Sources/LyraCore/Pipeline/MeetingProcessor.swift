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
            meeting.warnings.append(Self.silentWarning)
        }
        var lines: [TrackKind: [TranscriptLine]] = [:]
        for track in tracks {
            let samples: [Float]
            do { samples = try loader(track.url) } catch {
                // An unreadable file won't get better on retry; say so and keep going.
                meeting.warnings.append("Couldn't read \(track.url.lastPathComponent): \(error.localizedDescription)")
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
                meeting.warnings.append("Couldn't compress \(track.url.lastPathComponent); the original was kept. (\(error.localizedDescription))")
            }
        }

        let note = NoteRenderer.render(meeting: meeting, lines: merged, recordingsFolder: folder, timeZone: timeZone)
        try Self.createExclusively(Data(note.utf8), at: noteURL)
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
