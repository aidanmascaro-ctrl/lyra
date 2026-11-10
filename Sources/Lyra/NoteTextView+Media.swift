import AppKit
import LyraCore
import UniformTypeIdentifiers

/// Dividers and pictures in the editor: each a whole line of its own, never typed into.
extension NoteTextView {
    /// A paragraph that is only one of these, ended with Return, becomes a divider.
    static let dividerShortcuts: Set<String> = ["---", "***", "___"]

    func image(for media: String?) -> NSImage? {
        guard let media else { return nil }
        return imageLoader?.image(for: media)
    }

    /// Pictures are measured again (found, or a new note folder): their size depends on the file.
    func relayoutMedia() {
        guard let layout = layoutManager, let storage = textStorage else { return }
        layout.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
        needsDisplay = true
    }

    // MARK: Typing around them

    /// Typing on a picture or divider (the cursor just before or after it, nothing selected) starts a new line above
    /// or below it holding the typing. Returns false when the cursor isn't on one.
    func insertBesideMedia(_ typed: Any) -> Bool {
        let caret = selectedRange()
        var blocks = self.blocks
        guard caret.length == 0, !blocks.isEmpty else { return false }
        let i = blockIndex(at: caret.location)
        guard blocks.indices.contains(i), blocks[i].kind.isMedia else { return false }
        let text = NoteTextView.plainLines((typed as? NSAttributedString)?.string ?? (typed as? String) ?? "")
        guard !text.isEmpty else { return true }
        let at = caret.location == blockStart(i, in: blocks) ? i : i + 1
        let lines = text.components(separatedBy: "\n").map { NoteBlock(kind: .paragraph, runs: $0.isEmpty ? [] : [.init(text: $0)]) }
        blocks.insert(contentsOf: lines, at: at)
        let last = at + lines.count - 1
        replace(with: blocks, caret: blockStart(last, in: blocks) + NoteText.length(of: blocks[last]))
        return true
    }

    /// What Backspace (`backward`) or Delete does to a picture or divider: with the cursor just after one (or at the
    /// start of the line below it), or with exactly one selected, it goes; Delete at the end of the line above one
    /// takes it too. Nil when the key isn't about one.
    func mediaRemoval(backward: Bool, selection: NSRange, in blocks: [NoteBlock]) -> (blocks: [NoteBlock], caret: Int)? {
        guard !blocks.isEmpty else { return nil }
        let i = blockIndex(at: selection.location)
        guard blocks.indices.contains(i) else { return nil }
        let start = blockStart(i, in: blocks)
        func removing(_ j: Int) -> (blocks: [NoteBlock], caret: Int) {
            var rest = blocks
            rest.remove(at: j)
            let caret = j < rest.count ? blockStart(j, in: rest) : max(blockStart(j, in: rest) - 1, 0)
            return (rest, caret)
        }
        if selection.length > 0 {
            guard blocks[i].kind.isMedia, selection.location == start, selection.length == 1 else { return nil }
            return removing(i)
        }
        let offset = selection.location - start
        if blocks[i].kind.isMedia {
            if backward && offset == 1 || !backward && offset == 0 { return removing(i) }
            // Backspace just before one: take an empty line above, otherwise do nothing (never join it to text).
            if backward, i > 0 {
                return blocks[i - 1].runs.isEmpty && !blocks[i - 1].kind.isMedia
                    ? removing(i - 1) : (blocks, selection.location)
            }
            return backward ? (blocks, selection.location) : nil
        }
        if backward, offset == 0, i > 0, blocks[i - 1].kind.isMedia, blocks[i].kind == .paragraph {
            var result = removing(i - 1)
            result.caret = blockStart(i - 1, in: result.blocks)
            return result
        }
        if !backward, offset == NoteText.length(of: blocks[i]), i + 1 < blocks.count, blocks[i + 1].kind.isMedia {
            var result = removing(i + 1)
            result.caret = selection.location
            return result
        }
        return nil
    }

    // MARK: Paste and drop

    /// Saves the pictures on `pasteboard` beside the note and puts each on its own line: after the line the cursor
    /// is in (or in place of it when it is empty), or at block boundary `boundary` for a drop. Text wins over a
    /// picture that comes with it, unless that text is only a web address. Returns false when there was no picture.
    func pasteImages(from pasteboard: NSPasteboard, at boundary: Int?) -> Bool {
        let files = imageFiles(on: pasteboard)
        let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let textIsAddress = text.map { $0.hasPrefix("http://") || $0.hasPrefix("https://") } ?? false
        let data = files.isEmpty && (text == nil || textIsAddress) ? pastedImageData(on: pasteboard) : nil
        guard !files.isEmpty || data != nil else { return false }
        guard let loader = imageLoader else {
            onNotice?("Lyra can't add a picture until this note has been saved.")
            return true
        }
        var names: [String] = []
        do {
            if let data { names.append(try NoteImages.save(data.bytes, ext: data.ext, besideNote: loader.note)) }
            for file in files {
                let saved = try savable(file)
                names.append(try NoteImages.save(saved.bytes, ext: saved.ext, besideNote: loader.note))
            }
        } catch {
            onNotice?("Lyra couldn't save that picture: \(error.localizedDescription)")
        }
        guard !names.isEmpty else { return true }
        insertImages(names, at: boundary)
        return true
    }

    private func insertImages(_ names: [String], at boundary: Int?) {
        var blocks = self.blocks
        let pictures = names.map(NoteBlock.image(fileName:))
        var at: Int
        if let boundary {
            at = min(max(boundary, 0), blocks.count)
        } else if blocks.isEmpty {
            at = 0
        } else {
            let i = blockIndex(at: selectedRange().location)
            if blocks[i].kind == .paragraph, blocks[i].runs.isEmpty {
                blocks.remove(at: i)
                at = i
            } else {
                at = i + 1
            }
        }
        blocks.insert(contentsOf: pictures, at: at)
        let last = at + pictures.count - 1
        replace(with: blocks, caret: blockStart(last, in: blocks) + 1)
    }

    private func imageFiles(on pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { url in
            guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
            return type.conforms(to: .image)
        }
    }

    private func pastedImageData(on pasteboard: NSPasteboard) -> (bytes: Data, ext: String)? {
        if let png = pasteboard.data(forType: .png) { return (png, "png") }
        if let jpeg = pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)) { return (jpeg, "jpg") }
        guard let image = NSImage(pasteboard: pasteboard), let png = Self.pngData(image) else { return nil }
        return (png, "png")
    }

    /// A picture file's bytes as Obsidian can show them: its own when it is PNG, JPEG, GIF or WebP, else PNG.
    private func savable(_ file: URL) throws -> (bytes: Data, ext: String) {
        let ext = file.pathExtension.lowercased()
        if NoteImages.keepsOwnBytes(ext: ext) { return (try Data(contentsOf: file), ext) }
        guard let image = NSImage(contentsOf: file), let png = Self.pngData(image) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: file])
        }
        return (png, "png")
    }

    static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private func carriesImages(_ sender: NSDraggingInfo) -> Bool {
        guard isEditable, sender.draggingSource as AnyObject? !== self else { return false }
        let pasteboard = sender.draggingPasteboard
        return !imageFiles(on: pasteboard).isEmpty
            || (pasteboard.string(forType: .string) == nil && pastedImageData(on: pasteboard) != nil)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        carriesImages(sender) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        carriesImages(sender) ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard carriesImages(sender) else { return super.performDragOperation(sender) }
        let point = convert(sender.draggingLocation, from: nil)
        return pasteImages(from: sender.draggingPasteboard, at: dropIndex(at: point, in: blocks))
    }
}
