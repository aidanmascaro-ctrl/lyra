import Foundation

public enum NoteDocumentError: Error, Equatable, LocalizedError {
    case missingFrontmatter
    case invalidFrontmatter(field: String)

    public var errorDescription: String? {
        switch self {
        case .missingFrontmatter: "Lyra couldn't read this note's header, so it didn't change the note."
        case .invalidFrontmatter(let field): "Lyra couldn't read “\(field)” in this note's header, so it didn't change the note."
        }
    }
}

public struct NoteFrontmatter: Equatable, Sendable {
    public var lyraID: UUID
    public var title: String
    public var date: Date
    public var app: String
    public var durationMin: Int
    public var recordings: URL
    public var series: String?
    /// Without the `meeting` tag, which is always written first.
    public var tags: [String]
    /// Note names, written as `[[Name]]`.
    public var links: [String]
    public var summary: String?

    public init(lyraID: UUID, title: String, date: Date, app: String, durationMin: Int, recordings: URL,
                series: String? = nil, tags: [String] = [], links: [String] = [], summary: String? = nil) {
        self.lyraID = lyraID; self.title = title; self.date = date; self.app = app
        self.durationMin = durationMin; self.recordings = recordings; self.series = series
        self.tags = tags; self.links = links; self.summary = summary
    }
}

/// A note file: frontmatter, title, warnings, then three Lyra-owned sections (My notes, Expanded, Transcript).
/// Whatever else is in the file (text Aidan added, frontmatter keys Lyra doesn't know) is kept and written back as it was.
public struct NoteDocument: Equatable, Sendable {
    public var front: NoteFrontmatter
    public var warnings: [String]
    public var myNotes: String
    public var expanded: String
    public var transcript: String

    /// Text under the title that is neither a warning nor a section, and frontmatter lines Lyra doesn't own.
    private var headExtra = ""
    private var extraFront: [String] = []
    private var pieces: [Piece] = NoteDocument.defaultPieces

    public init(front: NoteFrontmatter, warnings: [String], myNotes: String, expanded: String, transcript: String) {
        self.front = front; self.warnings = warnings
        self.myNotes = myNotes; self.expanded = expanded; self.transcript = transcript
    }

    // MARK: Layout

    private enum Section: CaseIterable {
        case myNotes, expanded, transcript

        var heading: String {
            switch self {
            case .myNotes: "## My notes"
            case .expanded: "## Expanded"
            case .transcript: "## Transcript"
            }
        }
        var tag: String {
            switch self {
            case .myNotes: "mynotes"
            case .expanded: "expanded"
            case .transcript: "transcript"
            }
        }
        var start: String { "<!-- lyra:\(tag):start -->" }
        var end: String { "<!-- lyra:\(tag):end -->" }
    }

    private enum Piece: Equatable, Sendable {
        case section(Section)
        case literal(String)
    }

    /// Links to the three sections, under the title, so Obsidian (on the phone too) jumps between them. Lyra's
    /// furniture, not Aidan's text: parsing drops it wherever it sits and rendering puts it back under the title.
    static let jumpLine = "[[#My notes|My notes]] · [[#Expanded|Expanded]] · [[#Transcript|Transcript]]"
    private static let gap = Piece.literal("\n\n")
    private static let defaultPieces: [Piece] = [.section(.myNotes), gap, .section(.expanded), gap, .section(.transcript), .literal("\n")]

    // MARK: Render

    public func render(timeZone: TimeZone = .current) -> String {
        var out = "---\n" + renderFront(timeZone: timeZone) + "---\n"
        out += "# \(oneLine(front.title))\n\n"
        out += Self.jumpLine + "\n\n"
        for warning in warnings { out += "> [!warning] \(oneLine(warning))\n\n" }
        if !headExtra.isEmpty { out += headExtra + "\n\n" }
        for piece in pieces {
            switch piece {
            case .literal(let text): out += text
            case .section(let s): out += renderSection(s)
            }
        }
        return out
    }

    private func renderSection(_ s: Section) -> String {
        let body: String
        switch s {
        case .myNotes: body = myNotes
        case .expanded: body = expanded
        case .transcript: body = NoteSections.fold(transcript)
        }
        // Section text can't hold a comment opener, or it could fake a marker.
        return "\(s.heading)\n\(s.start)\n\(body.replacingOccurrences(of: "<!--", with: "&lt;!--"))\n\(s.end)"
    }

    private func renderFront(timeZone: TimeZone) -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = timeZone
        iso.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        let tags = (["meeting"] + front.tags.filter { $0 != "meeting" }).joined(separator: ", ")
        var lines = [
            "lyra_id: \(front.lyraID.uuidString)",
            "date: \(iso.string(from: front.date))",
            "app: \(quote(front.app))",
            "duration_min: \(front.durationMin)",
            "recordings: \(quote(front.recordings.absoluteString))",
        ]
        if let series = front.series { lines.append("series: \(quote(series))") }
        lines.append("tags: [\(tags)]")
        lines.append("links: [\(front.links.map { quote("[[\($0)]]") }.joined(separator: ", "))]")
        if let summary = front.summary { lines.append("summary: \(quote(summary))") }
        return (lines + extraFront).joined(separator: "\n") + "\n"
    }

    private func oneLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    private func quote(_ s: String) -> String {
        let escaped = oneLine(s).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: Parse

    public static func parse(_ text: String) throws -> NoteDocument {
        guard text.hasPrefix("---\n"), let close = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex)
        else { throw NoteDocumentError.missingFrontmatter }
        let frontLines = text[text.index(text.startIndex, offsetBy: 4)..<close.lowerBound]
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let body = String(text[close.upperBound...])

        var fields: [String: String] = [:]
        var extra: [String] = []
        var blockKey: String?   // a known list key whose `  - item` lines follow
        var blockItems: [String: [String]] = [:]
        for line in frontLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let key = blockKey, line.hasPrefix(" "), trimmed.hasPrefix("- ") {
                blockItems[key, default: []].append(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                continue
            }
            blockKey = nil
            if let colon = line.firstIndex(of: ":"), knownKeys.contains(String(line[..<colon])), !line.hasPrefix(" ") {
                let key = String(line[..<colon])
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                fields[key] = value
                if value.isEmpty, key == "tags" || key == "links" { blockKey = key }
            } else if !line.isEmpty {
                extra.append(line)
            }
        }
        // Obsidian's Properties editor writes lists as `key:` plus `  - item` lines.
        for (key, items) in blockItems { fields[key] = "[" + items.joined(separator: ", ") + "]" }

        let located = locateSections(in: body)
        let headText = located.first.map { String(body[..<$0.outer.lowerBound]) } ?? body
        let head = parseHead(headText)

        let front = try makeFront(fields, title: head.title)
        var doc = NoteDocument(front: front, warnings: head.warnings, myNotes: "", expanded: "", transcript: "")
        doc.headExtra = head.extra
        doc.extraFront = extra

        var pieces: [Piece] = []
        var cursor = located.first?.outer.lowerBound ?? body.endIndex
        for hit in located {
            if hit.outer.lowerBound > cursor { pieces.append(.literal(String(body[cursor..<hit.outer.lowerBound]))) }
            pieces.append(.section(hit.section))
            let sectionBody = trimOne(String(body[hit.body]))
            let typed = sectionBody.replacingOccurrences(of: "&lt;!--", with: "<!--")
            switch hit.section {
            case .myNotes: doc.myNotes = typed
            case .expanded: doc.expanded = typed
            case .transcript: doc.transcript = NoteSections.unfold(sectionBody)
            }
            cursor = hit.outer.upperBound
        }
        if !located.isEmpty, cursor < body.endIndex { pieces.append(.literal(String(body[cursor...]))) }
        doc.pieces = ensureAllSections(pieces)
        return doc
    }

    private static let knownKeys: Set<String> = ["lyra_id", "date", "app", "duration_min", "recordings", "series", "tags", "links", "summary"]

    private static func makeFront(_ f: [String: String], title: String) throws -> NoteFrontmatter {
        guard let id = f["lyra_id"].flatMap({ UUID(uuidString: $0) }) else { throw NoteDocumentError.invalidFrontmatter(field: "lyra_id") }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        guard let date = f["date"].flatMap({ iso.date(from: $0) }) else { throw NoteDocumentError.invalidFrontmatter(field: "date") }
        let tags = list(f["tags"]).filter { $0 != "meeting" }
        let links = list(f["links"]).compactMap { item -> String? in
            let name = unquote(item)
            guard name.hasPrefix("[["), name.hasSuffix("]]"), name.count > 4 else { return nil }
            return String(name.dropFirst(2).dropLast(2))
        }
        return NoteFrontmatter(lyraID: id, title: title, date: date, app: f["app"].map(unquote) ?? "",
                               durationMin: f["duration_min"].flatMap { Int($0) } ?? 0,
                               recordings: f["recordings"].flatMap { URL(string: unquote($0)) } ?? URL(fileURLWithPath: "/"),
                               series: f["series"].map(unquote), tags: tags, links: links, summary: f["summary"].map(unquote))
    }

    private static func parseHead(_ head: String) -> (title: String, warnings: [String], extra: String) {
        var title = ""
        var titleSeen = false
        var warnings: [String] = []
        var rest: [String] = []
        for line in head.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if !titleSeen, line.hasPrefix("# ") { title = String(line.dropFirst(2)); titleSeen = true }
            else if line.hasPrefix("> [!warning] ") { warnings.append(String(line.dropFirst(13))) }
            else if line == jumpLine { continue }
            else { rest.append(line) }
        }
        let extra = rest.joined(separator: "\n").trimmingCharacters(in: .newlines)
        return (title, warnings, extra)
    }

    private struct Hit {
        var section: Section
        var outer: Range<String.Index>   // heading through end marker
        var body: Range<String.Index>    // between the markers
    }

    /// The first start marker of each section and the first end marker after it, plus its heading line when directly above.
    /// A Phase 2 note's `lyra:notes` markers and `## Notes` heading count as My notes.
    private static func locateSections(in body: String) -> [Hit] {
        var hits: [Hit] = []
        for section in Section.allCases {
            var variants = [(section.start, section.end, section.heading)]
            if section == .myNotes { variants.append(("<!-- lyra:notes:start -->", "<!-- lyra:notes:end -->", "## Notes")) }
            for (start, end, heading) in variants {
                guard let s = body.range(of: start), let e = body.range(of: end, range: s.upperBound..<body.endIndex) else { continue }
                var lower = s.lowerBound
                if let h = body.range(of: heading + "\n", options: .backwards, range: body.startIndex..<s.lowerBound),
                   h.upperBound == s.lowerBound {
                    lower = h.lowerBound
                }
                hits.append(Hit(section: section, outer: lower..<e.upperBound, body: s.upperBound..<e.lowerBound))
                break
            }
        }
        hits.sort { $0.outer.lowerBound < $1.outer.lowerBound }
        var kept: [Hit] = []
        for hit in hits where kept.last.map({ $0.outer.upperBound <= hit.outer.lowerBound }) ?? true { kept.append(hit) }
        return kept
    }

    /// Adds any section the file lacks: Transcript last, Expanded just before it, My notes first.
    private static func ensureAllSections(_ pieces: [Piece]) -> [Piece] {
        guard !pieces.isEmpty else { return defaultPieces }
        var out = pieces
        func has(_ s: Section) -> Bool { out.contains(.section(s)) }
        if !has(.transcript) { out += [gap, .section(.transcript), .literal("\n")] }
        if !has(.expanded), let i = out.firstIndex(of: .section(.transcript)) { out.insert(contentsOf: [.section(.expanded), gap], at: i) }
        if !has(.myNotes) { out.insert(contentsOf: [.section(.myNotes), gap], at: 0) }
        // Adjacent literals are one piece, so a parsed document equals the one that was rendered.
        return out.reduce(into: [Piece]()) { merged, piece in
            if case .literal(let b) = piece, case .literal(let a)? = merged.last { merged[merged.count - 1] = .literal(a + b) }
            else { merged.append(piece) }
        }
    }

    /// Render writes `marker\nbody\nmarker`, so one newline each side is not part of the body.
    private static func trimOne(_ s: String) -> String {
        var t = Substring(s)
        if t.hasPrefix("\n") { t = t.dropFirst() }
        if t.hasSuffix("\n") { t = t.dropLast() }
        return String(t)
    }

    // MARK: Frontmatter values

    private static func unquote(_ raw: String) -> String {
        guard raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else { return raw }
        var out = ""
        var escaped = false
        for ch in raw.dropFirst().dropLast() {
            if escaped { out.append(ch); escaped = false }
            else if ch == "\\" { escaped = true }
            else { out.append(ch) }
        }
        return out
    }

    /// `[a, "b, c"]` style lists: split on commas outside quotes.
    private static func list(_ raw: String?) -> [String] {
        guard var s = raw?.trimmingCharacters(in: .whitespaces), s.hasPrefix("["), s.hasSuffix("]") else { return [] }
        s = String(s.dropFirst().dropLast())
        var items: [String] = []
        var current = ""
        var inQuotes = false, escaped = false
        for ch in s {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" && inQuotes { current.append(ch); escaped = true; continue }
            if ch == "\"" { inQuotes.toggle(); current.append(ch); continue }
            if ch == "," && !inQuotes { items.append(current); current = ""; continue }
            current.append(ch)
        }
        items.append(current)
        return items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
