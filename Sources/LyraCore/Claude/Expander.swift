import Foundation

/// One thing Claude added, as soon as its line is complete.
public enum ExpansionEvent: Equatable, Sendable {
    /// A grey block under the target block at `index`.
    case under(index: Int, NoteBlock)
    /// A grey `##` heading for something Aidan didn't note.
    case section(NoteBlock)
    /// A grey block under the latest section.
    case bullet(NoteBlock)
}

/// Reads Claude's line protocol (`@n`, `@new Heading`, `- bullet`) as it streams in.
/// Anything else is ignored; a group whose `@` line is not allowed is dropped up to the next `@`.
public struct ExpansionParser: Sendable {
    private enum Group: Sendable { case none, under(Int), section, dropped }

    private let targets: [NoteBlock]
    private let only: Int?
    private let allowsNew: Bool
    private var buffer = ""
    private var group = Group.none

    /// `targets` are the blocks `@n` refers to; only Aidan's (white) ones can take additions,
    /// unless `only` names the single block that may (Expand this).
    public init(targets: [NoteBlock], only: Int? = nil, allowsNew: Bool = true) {
        self.targets = targets; self.only = only; self.allowsNew = allowsNew
    }

    public mutating func feed(_ chunk: String) -> [ExpansionEvent] {
        buffer += chunk
        var events: [ExpansionEvent] = []
        while let end = buffer.firstIndex(where: \.isNewline) {
            let line = String(buffer[..<end])
            buffer = String(buffer[buffer.index(after: end)...])
            events += parse(line)
        }
        return events
    }

    public mutating func finish() -> [ExpansionEvent] {
        let rest = buffer
        buffer = ""
        return parse(rest)
    }

    private mutating func parse(_ line: String) -> [ExpansionEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("@") { return header(String(trimmed.dropFirst())) }
        guard let (level, item) = bullet(line) else { return [] }
        switch group {
        case .under(let index):
            return [.under(index: index, grey(item, indent: targets[index].indent + 1 + level))]
        case .section:
            return [.bullet(grey(item, indent: level))]
        case .none, .dropped:
            return []
        }
    }

    /// Tolerates small wobbles: `@ 3`, `@#3`, `@3:`, `@3.`, `@NEW Heading`, `@new: Heading`.
    private mutating func header(_ text: String) -> [ExpansionEvent] {
        var token = Substring(text).drop(while: \.isWhitespace)
        if token.hasPrefix("#") { token = token.dropFirst() }
        let digits = token.prefix(while: { $0.isASCII && $0.isNumber })
        if !digits.isEmpty {
            let rest = token.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
            let valid = (rest.isEmpty || rest == ":" || rest == ".") && Int(digits).map(canTake) == true
            group = valid ? .under(Int(digits)!) : .dropped
            return []
        }
        guard allowsNew, token.prefix(3).lowercased() == "new" else { group = .dropped; return [] }
        var rest = token.dropFirst(3)
        if rest.first == ":" {
            rest = rest.dropFirst()
        } else if let next = rest.first, !next.isWhitespace {
            group = .dropped  // a word like "newsletter"
            return []
        }
        let heading = rest.drop(while: { $0 == "#" || $0.isWhitespace }).trimmingCharacters(in: .whitespaces)
        guard !heading.isEmpty else { group = .dropped; return [] }
        group = .section
        let runs = NoteMarkdown.parse("## " + heading).first?.runs ?? [InlineRun(text: heading)]
        return [.section(NoteBlock(kind: .heading2, runs: runs, byClaude: true))]
    }

    private func canTake(_ index: Int) -> Bool {
        guard targets.indices.contains(index) else { return false }
        if let only { return index == only }
        return !targets[index].byClaude
    }

    /// A `- ` or `1. ` line: its depth (two spaces per level) and the parsed block.
    private func bullet(_ line: String) -> (Int, NoteBlock)? {
        let spaces = line.prefix(while: { $0 == " " }).count
        guard let block = NoteMarkdown.parse(String(line.dropFirst(spaces))).first,
              block.kind == .bullet || block.kind == .numbered,
              !block.plainText.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return (spaces / 2, block)
    }

    private func grey(_ block: NoteBlock, indent: Int) -> NoteBlock {
        NoteBlock(kind: block.kind, indent: indent, runs: block.runs, byClaude: true)
    }
}

/// The document as it grows: `base` untouched, additions after each target (and the grey already
/// under it) in arrival order, new sections at the end.
struct ExpansionAssembly {
    let base: [NoteBlock]
    private var under: [Int: [NoteBlock]] = [:]
    private var sections: [NoteBlock] = []

    init(base: [NoteBlock]) { self.base = base }

    mutating func apply(_ event: ExpansionEvent) {
        switch event {
        case .under(let index, let block): under[index, default: []].append(block)
        case .section(let block), .bullet(let block): sections.append(block)
        }
    }

    var blocks: [NoteBlock] {
        let byPosition = Dictionary(grouping: under.keys, by: insertionPoint)
        var result: [NoteBlock] = []
        for position in 0...base.count {
            for target in (byPosition[position] ?? []).sorted() { result += under[target] ?? [] }
            if position < base.count { result.append(base[position]) }
        }
        return result + sections
    }

    private func insertionPoint(after index: Int) -> Int {
        var end = index + 1
        while end < base.count, base[end].byClaude, base[end].indent > base[index].indent { end += 1 }
        return end
    }
}

/// Claude's note operations after a meeting. Aidan's blocks are passed through untouched; every
/// block Claude adds is grey.
public struct Expander: Sendable {
    private let claude: any ClaudeRunning

    public init(claude: any ClaudeRunning) { self.claude = claude }

    /// Yields the whole Expanded list after each addition.
    public func expandAll(_ ctx: MeetingContext) -> AsyncThrowingStream<[NoteBlock], Error> {
        expansion(prompt: Prompts.expandUser(ctx: ctx), parser: ExpansionParser(targets: ctx.myNotes), base: ctx.myNotes)
    }

    /// Settles edited grey, folds in new My-notes points, drops the old grey and expands what's left.
    public func reExpand(myNotes: [NoteBlock], expanded: [NoteBlock], lyraWrote: [String],
                         ctx: MeetingContext) -> AsyncThrowingStream<[NoteBlock], Error> {
        let settled = ExpandedMerge.settle(expanded, lyraWrote: lyraWrote)
        let added = ExpandedMerge.newNotes(myNotes: myNotes, expanded: settled)
        let merged = ExpandedMerge.insertNewNotes(added, myNotes: myNotes, into: settled)
        var white = ctx
        white.myNotes = ExpandedMerge.stripGrey(merged)
        return expandAll(white)
    }

    /// More detail under `block` only. The block may be grey: Aidan can ask about Claude's points too.
    public func expandThis(_ selection: String, block: Int, in blocks: [NoteBlock], ctx: MeetingContext) async throws -> [NoteBlock] {
        guard blocks.indices.contains(block) else { throw ClaudeError.failed("that point isn't in the notes any more.") }
        let prompt = Prompts.expandThisUser(selection: selection, block: block, in: blocks, ctx: ctx)
        let parser = ExpansionParser(targets: blocks, only: block, allowsNew: false)
        return try await final(expansion(prompt: prompt, parser: parser, base: blocks))
    }

    public func inject(_ idea: String, into blocks: [NoteBlock], ctx: MeetingContext) async throws -> [NoteBlock] {
        let prompt = Prompts.injectUser(idea: idea, into: blocks, ctx: ctx)
        return try await final(expansion(prompt: prompt, parser: ExpansionParser(targets: blocks), base: blocks))
    }

    public func ask(_ question: String, about selection: String?, ctx: MeetingContext) async throws -> String {
        let prompt = Prompts.askUser(question: question, selection: selection, ctx: ctx)
        let answer = try await claude.complete(system: Prompts.askSystem, prompt: prompt)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw ClaudeError.failed("the answer came back empty.") }
        return answer
    }

    // MARK: Streaming

    /// Throws if Claude's whole reply held nothing usable, so the UI offers Retry rather than
    /// silently showing no expansion.
    private func expansion(prompt: String, parser: ExpansionParser, base: [NoteBlock]) -> AsyncThrowingStream<[NoteBlock], Error> {
        let claude = self.claude
        return AsyncThrowingStream { continuation in
            let task = Task {
                var parser = parser
                var assembly = ExpansionAssembly(base: base)
                var added = false
                func emit(_ events: [ExpansionEvent]) {
                    for event in events {
                        assembly.apply(event)
                        added = true
                        continuation.yield(assembly.blocks)
                    }
                }
                do {
                    for try await chunk in claude.stream(system: Prompts.expandSystem, prompt: prompt, model: ClaudeCLI.defaultModel) {
                        emit(parser.feed(chunk))
                    }
                    emit(parser.finish())
                    guard added else { throw ClaudeError.failed("its reply wasn't in a form Lyra can use.") }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func final(_ stream: AsyncThrowingStream<[NoteBlock], Error>) async throws -> [NoteBlock] {
        var latest: [NoteBlock] = []
        for try await blocks in stream { latest = blocks }
        return latest
    }
}
