import Foundation

/// Turns a finished recording folder into a transcript, a note and compressed audio.
/// The note itself is made when recording starts (`createSkeletonNote`); processing fills in its transcript.
/// Order matters for crash safety: convert → note → speakers.json → transcript.json (the "done" marker) → delete CAFs.
public struct MeetingProcessor: Sendable {
    public static let silentPeak: Float = 0.005

    /// Neutral on purpose: a solo call is silent too, so this must not claim a permission problem.
    public static func noSoundWarning(appName: String) -> String {
        "No sound came from \(appName) during this meeting, so the transcript is from your microphone only. If other people spoke, check System Settings → Privacy & Security → Screen & System Audio Recording for Lyra."
    }

    private let trackTranscriber: TrackTranscriber
    private let loader: @Sendable (URL) throws -> [Float]
    private let convert: @Sendable (URL, URL) async throws -> Void
    private let timeZone: TimeZone
    private let people: @Sendable () -> [Person]
    private let policy: MatchPolicy

    /// `convert(caf, m4a)` must throw unless `m4a` ends up playable with a non-zero duration.
    /// `people` is read once per meeting; naming only reads it, it never writes to the people store.
    public init(trackTranscriber: TrackTranscriber, loader: @escaping @Sendable (URL) throws -> [Float],
                convert: @escaping @Sendable (URL, URL) async throws -> Void, timeZone: TimeZone = .current,
                people: @escaping @Sendable () -> [Person] = { [] }, policy: MatchPolicy = .init()) {
        self.trackTranscriber = trackTranscriber
        self.loader = loader
        self.convert = convert
        self.timeZone = timeZone
        self.people = people
        self.policy = policy
    }

    public func process(meeting: Meeting, tracks: [TrackResult], folder: URL, noteURL: URL) async throws -> URL {
        var meeting = meeting
        if let m = tracks.first(where: { $0.kind == .meeting }), m.peakLevel < Self.silentPeak || m.error != nil {
            meeting.warn(Self.noSoundWarning(appName: meeting.appName))
        }
        var lines: [TrackKind: [TranscriptLine]] = [:]
        var clusters: [TrackKind: [SpeakerCluster]] = [:]
        for track in tracks {
            let samples: [Float]
            do { samples = try loader(track.url) } catch {
                // An unreadable file won't get better on retry; say so and keep going.
                meeting.warn("Couldn't read \(track.url.lastPathComponent): \(error.localizedDescription)")
                continue
            }
            // Engine failures (e.g. models not downloaded) throw, so the folder is retried next launch.
            // Shift onto the shared timeline: the tracks start recording at different moments.
            let offset = track.startOffset ?? 0
            let result = try await trackTranscriber.run(samples: samples, track: track.kind)
            lines[track.kind] = result.lines.map { var l = $0; l.start += offset; l.end += offset; return l }
            clusters[track.kind] = result.clusters
        }
        let known = people()
        let (echoFree, allClusters) = TranscriptMerger.dropVoiceEcho(
            lines: TranscriptMerger.merge(meeting: lines[.meeting] ?? [], mic: lines[.mic] ?? []),
            clusters: (clusters[.meeting] ?? []) + (clusters[.mic] ?? []), people: known, policy: policy)
        let merged = SpeakerNamer.name(lines: echoFree, clusters: allClusters, people: known, policy: policy)

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

        let noteAt = try writeTranscript(merged, meeting: &meeting, folder: folder, reserved: noteURL)
        meeting.notePath = noteAt.path
        try meeting.save(in: folder)
        // Before transcript.json: a crash between the two leaves no done marker, so the folder is reprocessed.
        // Only clusters with a line left after the echo filter: an echo-only mic cluster is the remote voice leaking in.
        // Taken before naming: a join keeps only its first line's raw id, but both clusters still spoke.
        let kept = Set(echoFree.compactMap(\.speakerID))
        let speakers = allClusters.filter { kept.contains($0.id) }
        try PeopleStore.writeOwnerOnly(Self.encoder.encode(speakers), to: folder.appendingPathComponent("speakers.json"))
        try Self.encoder.encode(merged).write(to: folder.appendingPathComponent("transcript.json"), options: .atomic)
        // Only now is the meeting safe without its CAFs; a crash before this point reprocesses the folder.
        for caf in converted { try? FileManager.default.removeItem(at: caf) }
        return noteAt
    }

    /// The note made when recording starts, so Aidan can type in it during the meeting: header, empty sections.
    /// Never replaces a file already at `noteURL`.
    public static func createSkeletonNote(for meeting: Meeting, recordingsFolder: URL, at noteURL: URL) throws {
        let note = NoteRenderer.render(meeting: meeting, lines: [], recordingsFolder: recordingsFolder)
        try createExclusively(Data(note.utf8), at: noteURL)
    }

    /// Puts the transcript into the meeting's note, wherever Aidan has moved it under the notes root (the folder
    /// `reserved` is in), keeping My notes and Expanded exactly as on disk. Creates the note at `reserved` when
    /// there is none (Lyra died before the skeleton was written). Records the section hash rename relies on.
    private func writeTranscript(_ lines: [TranscriptLine], meeting: inout Meeting, folder: URL, reserved: URL) throws -> URL {
        let index = NoteIndex(notesRoot: reserved.deletingLastPathComponent(), vaultRoot: reserved.deletingLastPathComponent())
        let body = NoteRenderer.transcriptBody(lines: lines)
        guard let found = index.find(meeting.id, hint: meeting.notePath.map { URL(fileURLWithPath: $0) } ?? reserved) else {
            let note = NoteRenderer.render(meeting: meeting, lines: lines, recordingsFolder: folder, timeZone: timeZone)
            try Self.createExclusively(Data(note.utf8), at: reserved)
            meeting.transcriptSectionHash = NoteSections.hash(body)
            return reserved
        }
        let loaded: LoadedNote
        do { loaded = try index.load(meeting.id, hint: found) } catch is NoteDocumentError {
            // Our note, but its header was broken by hand: finish the job and leave the note untouched.
            let existing = try String(contentsOf: found, encoding: .utf8)
            meeting.transcriptSectionHash = NoteSections.transcriptBody(of: existing).map(NoteSections.hash)
            return found
        }
        guard loaded.document.transcript.isEmpty else {
            // Written by a run a crash cut short (and maybe edited since): leave it as it is.
            meeting.transcriptSectionHash = NoteSections.hash(loaded.document.transcript)
            return loaded.url
        }
        let (minutes, warnings) = (NoteRenderer.durationMinutes(of: meeting), meeting.warnings)
        let saved = try index.update(loaded) { doc in
            doc.transcript = body
            doc.front.durationMin = minutes
            doc.warnings += warnings.filter { !doc.warnings.contains($0) }
        }
        meeting.transcriptSectionHash = NoteSections.hash(body)
        return saved.url
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
            var track = TrackResult(kind: kind, url: url, seconds: saved?.seconds ?? 0, peakLevel: saved?.peakLevel ?? 1, error: saved?.error)
            track.startOffset = saved?.startOffset
            return track
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
    public mutating func warn(_ text: String) {
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
