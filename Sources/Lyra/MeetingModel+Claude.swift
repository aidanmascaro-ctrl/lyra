import Foundation
import LyraCore

/// Claude's actions in the meeting window. Each runs off the main actor; what it adds to Expanded is grey, is laid
/// onto whatever Aidan typed meanwhile, is saved, and is recorded as Lyra's own writing. My notes is never touched.
extension MeetingModel {
    func selectionAction(_ action: SelectionAction, text: String, block: Int) {
        switch action {
        case .find:
            highlighted = TranscriptSearch.lines(matching: text, in: lines)
            tab = .transcript
            if highlighted.isEmpty { notice = "Lyra couldn't find that in the transcript." }
        case .ask:
            inlineAsk = (text, block)
        case .expand:
            let base = expandedBlocks
            run("Expanding…") { [expander = app.expander] ctx in
                try await expander.expandThis(text, block: block, in: base, ctx: ctx)
            } apply: { result, current in ExpandedEdits.rebase(result, base: base, onto: current) }
        }
    }

    /// The question typed in the inline field of Ask…: the answer goes under the highlighted point.
    func askInline(_ question: String) {
        guard let ask = inlineAsk, !question.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        inlineAsk = nil
        let base = expandedBlocks
        run("Asking…") { [expander = app.expander] ctx in
            let answer = try await expander.ask(question, about: ask.selection, ctx: ctx)
            return ExpandedEdits.insert(ExpandedEdits.greyBlocks(from: answer), under: ask.block, in: base)
        } apply: { result, current in ExpandedEdits.rebase(result, base: base, onto: current) }
    }

    /// The bottom bar: a question gets an answer above the bar; "add / include / weave …" is written into Expanded.
    func submitBar(_ text: String) {
        switch BarRequest.parse(text) {
        case .ask(let question):
            answer = nil
            run("Thinking…") { [expander = app.expander] ctx in
                let reply = try await expander.ask(question, about: nil, ctx: ctx)
                await MainActor.run { self.answer = (question, reply) }
                return nil
            }
        case .inject(let idea):
            tab = .expanded
            let base = expandedBlocks
            run("Adding your idea…") { [expander = app.expander] ctx in
                try await expander.inject(idea, into: base, ctx: ctx)
            } apply: { result, current in ExpandedEdits.rebase(result, base: base, onto: current) }
        case nil:
            break
        }
    }

    /// "Add to notes" on a bottom-bar answer: a grey paragraph at the end of Expanded.
    func addAnswerToNotes() {
        guard let answer else { return }
        self.answer = nil
        tab = .expanded
        addClaude(ExpandedEdits.append(ExpandedEdits.greyBlocks(from: answer.text), to: expandedBlocks))
    }

    func retryExpansion() {
        meeting?.expandError = nil
        meeting?.insightsError = nil
        app.runAfterMeeting(folder: folder)
    }

    func reExpand() {
        guard working == nil, let id = meeting?.id else { return }
        // Expanded is not saved here: the editor saves its own typing, and Re-expand refuses if Expanded changes
        // while Claude writes.
        working = "Re-expanding…"
        claudeError = nil
        Task {
            do { try await app.reExpand(folder: folder, id: id) } catch NoteIndexError.changedOnDisk {
                claudeError = "Expanded changed while Claude was writing, so Lyra kept your version. Try Re-expand again."
            } catch { claudeError = Self.plain(error) }
            working = nil
            reload()
        }
    }

    // MARK: Running

    /// Builds the meeting's context off the main actor, runs `work`, and lays its blocks (if any) onto the current
    /// Expanded with `apply`.
    private func run(_ label: String, _ work: @escaping @Sendable (MeetingContext) async throws -> [NoteBlock]?,
                     apply: @escaping ([NoteBlock], [NoteBlock]) -> [NoteBlock] = { result, _ in result }) {
        guard working == nil, let loaded else { return }
        guard !lines.isEmpty else {
            claudeError = "The transcript isn't ready yet, so Claude has nothing to go on. Try again once the meeting has been processed."
            return
        }
        working = label
        claudeError = nil
        let (folder, notes) = (folder, notes)
        Task {
            do {
                let ctx = try await Task.detached { try AfterMeeting.context(for: loaded, meetingFolder: folder, index: notes) }.value
                if let result = try await work(ctx) { addClaude(apply(result, expandedBlocks)) }
            } catch { claudeError = Self.plain(error) }
            working = nil
        }
    }

    /// Saves Claude's version of Expanded, pushes it to the editor, and records its new grey as Lyra's.
    private func addClaude(_ blocks: [NoteBlock]) {
        let before = Set(expandedBlocks.map { NoteMarkdown.render([$0]) })
        guard lyraWrite(blocks, to: .expanded) else {
            claudeError = "Expanded was being changed (in Obsidian or by your typing) while Claude worked, so Lyra didn't add its answer. Try again."
            return
        }
        let added = blocks.filter { $0.byClaude && !before.contains(NoteMarkdown.render([$0])) }
        do { try NoteEdits.rememberGrey(added, meetingFolder: folder) } catch {
            notice = "Lyra couldn't update this meeting's records: \(error.localizedDescription)"
        }
    }

    static func plain(_ error: Error) -> String {
        if error is ClaudeError { return error.localizedDescription }
        return "Something went wrong: \(error.localizedDescription)"
    }
}
