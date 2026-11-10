import Foundation

/// Recording again in a note that has already been ended and written up. The finished part — its transcript (all
/// parts so far, as Aidan may have renamed them), speakers and audio — is filed under `parts/N`; the folder then
/// looks like any recording in progress, so crash recovery and processing work unchanged. Processing joins the new
/// part's transcript on after the filed one (`join`).
public enum RecordingParts {
    static let folderName = "parts"
    /// `onscreen.json` goes with its part: its times are that part's. Slides stay at the top, where the note links them.
    private static let filed: Set<String> = ["transcript.json", "speakers.json", OnScreenLog.fileName]

    /// Files the finished part away and readies `meeting.json` for the next one. Returns the meeting as it was,
    /// for `restore` if recording then can't start.
    public static func archive(folder: URL) throws -> Meeting {
        let fm = FileManager.default
        let previous = try Meeting.load(from: folder)
        let part = (previous.earlierParts ?? 0) + 1
        let target = partFolder(folder, part)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let names = try fm.contentsOfDirectory(atPath: folder.path).filter { filed.contains($0) || $0.hasSuffix(".m4a") }
        var moved: [String] = []
        do {
            for name in names {
                try fm.moveItem(at: folder.appendingPathComponent(name), to: target.appendingPathComponent(name))
                moved.append(name)
            }
        } catch {
            // Half filed away would leave the note looking empty: put back what moved, then say why.
            for name in moved { try? fm.moveItem(at: target.appendingPathComponent(name), to: folder.appendingPathComponent(name)) }
            throw error
        }
        var meeting = previous
        meeting.earlierParts = part
        meeting.recordedBefore = (previous.recordedBefore ?? 0) + recordedSeconds(of: previous, folder: target)
        meeting.tracks = nil
        meeting.endedAt = nil
        meeting.afterMeetingDone = nil
        meeting.expandError = nil
        meeting.namesDone = nil  // the new part's voices get named too
        meeting.namesError = nil
        try meeting.save(in: folder)
        return previous
    }

    /// Undoes `archive`: the filed part goes back and `meeting.json` is as it was.
    public static func restore(folder: URL, previous: Meeting) throws {
        let fm = FileManager.default
        let source = partFolder(folder, (previous.earlierParts ?? 0) + 1)
        for name in try fm.contentsOfDirectory(atPath: source.path) {
            try fm.moveItem(at: source.appendingPathComponent(name), to: folder.appendingPathComponent(name))
        }
        try fm.removeItem(at: source)
        if (try? fm.contentsOfDirectory(atPath: folder.appendingPathComponent(folderName).path))?.isEmpty == true {
            try? fm.removeItem(at: folder.appendingPathComponent(folderName))
        }
        try previous.save(in: folder)
    }

    /// The transcript and speakers of every part before the one being processed.
    public static func earlier(in folder: URL, part: Int) throws -> (lines: [TranscriptLine], clusters: [SpeakerCluster]) {
        let dir = partFolder(folder, part)
        let lines = try JSONDecoder().decode([TranscriptLine].self, from: Data(contentsOf: dir.appendingPathComponent("transcript.json")))
        let clusters = (try? JSONDecoder().decode([SpeakerCluster].self, from: Data(contentsOf: dir.appendingPathComponent("speakers.json")))) ?? []
        return (lines, clusters)
    }

    /// The new part after the earlier ones: its times moved on by `offset` (seconds recorded before it), its
    /// speaker ids marked with the part so they can't clash, and people Lyra doesn't know numbered on from the
    /// earlier parts' — the same voice can't be told apart across parts, so it is never claimed to be.
    public static func join(earlier: [TranscriptLine], earlierClusters: [SpeakerCluster], new: [TranscriptLine],
                            newClusters: [SpeakerCluster], offset: Double, part: Int) -> (lines: [TranscriptLine], clusters: [SpeakerCluster]) {
        let highest = earlier.compactMap { speakerNumber($0.speakerLabel) }.max() ?? 0
        let tag = "part\(part)/"
        let shifted = new.map { line -> TranscriptLine in
            var l = line
            l.start += offset
            l.end += offset
            l.speakerID = line.speakerID.map { tag + $0 }
            if line.personID == nil, line.nameSource == nil, let n = speakerNumber(line.speakerLabel) {
                l.speakerLabel = "Speaker \(n + highest)"
            }
            return l
        }
        let clusters = newClusters.map {
            SpeakerCluster(id: tag + $0.id, track: $0.track, centroid: $0.centroid, speechSeconds: $0.speechSeconds)
        }
        return (earlier + shifted, earlierClusters + clusters)
    }

    static func partFolder(_ folder: URL, _ part: Int) -> URL {
        folder.appendingPathComponent(folderName).appendingPathComponent("\(part)")
    }

    /// The finished part's length: its longest track, else how far its transcript runs past the earlier parts.
    private static func recordedSeconds(of meeting: Meeting, folder: URL) -> Double {
        if let longest = meeting.tracks?.map(\.seconds).filter({ $0 > 0 }).max() { return longest }
        let lines = (try? JSONDecoder().decode([TranscriptLine].self, from: Data(contentsOf: folder.appendingPathComponent("transcript.json")))) ?? []
        return max(0, (lines.map(\.end).max() ?? 0) - (meeting.recordedBefore ?? 0))
    }

    private static func speakerNumber(_ label: String) -> Int? {
        guard label.hasPrefix("Speaker ") else { return nil }
        return Int(label.dropFirst("Speaker ".count))
    }
}
