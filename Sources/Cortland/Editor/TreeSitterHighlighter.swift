import AppKit
import SwiftTreeSitter
import TreeSitterSwift
import TreeSitterGo
import TreeSitterRust
import TreeSitterTypeScript
import TreeSitterTSX
import TreeSitterMarkdown
import TreeSitterPython

/// Grammar-accurate syntax highlighting via tree-sitter, replacing the regex
/// highlighter for the languages it supports: Swift, Go, Rust, Python,
/// JS/JSX/TS/TSX, and Markdown (the advertised set). tree-sitter is
/// authoritative for these — the document highlighter no longer keeps a regex
/// fallback for them. Extensions with no grammar here (C/C++, Java, HTML, CSS,
/// JSON, unknown text) are still handled by the regex `SyntaxHighlighter`.
///
/// Scoped to the document editor path. The compiled query is cached per language.
///
/// This enum holds what every document shares — the grammars, the compiled
/// queries, the capture→color mapping. The highlighting itself belongs to
/// `TreeSitterHighlighter.Document`, one per open file, which keeps the parse
/// tree between keystrokes so it can reuse it *and* ask tree-sitter which
/// regions the edit actually re-parsed.
enum TreeSitterHighlighter {
    /// Extensions handled by tree-sitter. Anything else → regex fallback.
    static func canHighlight(ext: String) -> Bool {
        languageAndQuery(for: ext.lowercased()) != nil
    }

    // MARK: - Capture → color mapping

    /// Maps a tree-sitter capture name (nvim-treesitter convention) onto the
    /// theme's syntax palette. Keys mostly on the leading component; Markdown's
    /// `@text.*` family needs the second component too. Unmapped captures
    /// (operators, punctuation, plain variables) stay the base text color.
    private static func color(forCapture name: [String], scheme: SyntaxHighlighter.SyntaxColorScheme) -> NSColor? {
        switch name.first {
        case "keyword", "attribute", "label":
            return scheme.keyword
        case "string", "character", "escape":
            return scheme.string
        case "comment":
            return scheme.comment
        case "number", "boolean", "float":
            return scheme.number
        case "type", "constructor":
            return scheme.type
        case "function":
            return scheme.function
        case "constant":
            // `nil` / builtins read as keywords in the regex highlighter; keep that.
            return scheme.keyword
        case "text":
            // Markdown block captures: headings, code spans, links.
            switch name.dropFirst().first {
            case "title":              return scheme.keyword    // # Heading
            case "literal":            return scheme.function   // `code` / fenced
            case "uri", "reference":   return scheme.string     // links
            default:                   return nil
            }
        default:
            return nil
        }
    }

    // MARK: - Language + query cache

    /// Maps a (lowercased) file extension to its grammar's `Language` and the
    /// raw highlight-query text. nil for unsupported extensions. TS/TSX use the
    /// combined JS-base + TS-additions query; JSX rides the JavaScript grammar.
    private static func languageAndQueryText(for ext: String) -> (Language, String)? {
        switch ext {
        case "swift":
            return (Language(language: tree_sitter_swift()), treeSitterSwiftHighlightsQuery)
        case "go":
            return (Language(language: tree_sitter_go()), tsQueryGo)
        case "py", "pyi":
            return (Language(language: tree_sitter_python()), tsQueryPython)
        case "rs":
            return (Language(language: tree_sitter_rust()), tsQueryRust)
        case "js", "jsx", "mjs", "cjs", "ts", "mts", "cts", "tsx":
            // All routed through the TSX grammar — a superset of JS/JSX/TS/TSX —
            // so the combined JS-base + TS-additions query compiles against it
            // and one path covers every flavor (no tree-sitter-javascript dep).
            return (Language(language: tree_sitter_tsx()), tsQueryTypeScript)
        case "md", "markdown", "mdx":
            // Block grammar only (headings, fenced code, lists, links). Inline
            // emphasis/links need the inline grammar via injections — see #21.
            return (Language(language: tree_sitter_markdown()), tsQueryMarkdown)
        default:
            return nil
        }
    }

    /// Memoized (Language, Query) per extension. Built lazily on first use and
    /// reused; main-actor isolated via the module default, so the cache is
    /// single-threaded. A query that won't compile against its grammar caches
    /// nothing and returns nil, so that language quietly falls back to regex.
    private static var cache: [String: (Language, Query)] = [:]

    private static func languageAndQuery(for ext: String) -> (Language, Query)? {
        if let hit = cache[ext] { return hit }
        guard let (language, text) = languageAndQueryText(for: ext),
              let query = try? Query(language: language, data: Data(text.utf8)) else {
            return nil
        }
        cache[ext] = (language, query)
        return (language, query)
    }

    // MARK: - Test hook

    /// Parses `source` for `ext` and returns the set of leading capture-name
    /// components produced (e.g. ["keyword", "string", "number"]), or nil if the
    /// language is unsupported / the query failed to compile. Lets a unit test
    /// confirm the embedded query compiles against the grammar (ABI match) and
    /// actually classifies tokens — without needing the running app.
    static func _captureKinds(in source: String, ext: String) -> Set<String>? {
        guard let (language, query) = languageAndQuery(for: ext.lowercased()) else { return nil }
        let parser = Parser()
        guard (try? parser.setLanguage(language)) != nil,
              let tree = parser.parse(source), let root = tree.rootNode else { return nil }
        var kinds = Set<String>()
        for match in query.execute(node: root, in: tree) {
            for capture in match.captures {
                if let first = capture.nameComponents.first { kinds.insert(first) }
            }
        }
        return kinds
    }
}

// MARK: - Incremental, per-document highlighting

extension TreeSitterHighlighter {
    /// UTF-16 offsets of every line start in a source. tree-sitter wants a point
    /// (row, column) next to every byte offset in an `InputEdit`, and the points
    /// on the *old* side of an edit can only be read off the text the stored tree
    /// was parsed from — which the text storage has already overwritten by the
    /// time the edit is reported.
    struct LineIndex {
        private let lineStarts: [Int]
        let length: Int

        init(_ source: String) {
            var starts = [0]
            var offset = 0
            for unit in source.utf16 {
                offset += 1
                if unit == 0x000A { starts.append(offset) }
            }
            lineStarts = starts
            length = offset
        }

        /// A column is a byte offset into its row, and the parser reads the source
        /// as UTF-16LE, so a column is 2× the UTF-16 offset into the line.
        func point(atUTF16 offset: Int) -> Point {
            let clamped = min(max(offset, 0), length)
            var low = 0
            var high = lineStarts.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if lineStarts[mid] <= clamped {
                    low = mid
                } else {
                    high = mid - 1
                }
            }
            return Point(row: low, column: (clamped - lineStarts[low]) * 2)
        }
    }

    /// The single edit that turns the text the stored tree was parsed from into
    /// the text now in the storage. `start` and `oldEnd` are UTF-16 offsets into
    /// the old text, `newEnd` into the new one.
    ///
    /// Keystrokes arrive one at a time but the reparse is debounced, so several
    /// edits have to fold into one before tree-sitter sees them. The fold holds
    /// `newEnd - oldEnd == newLength - oldLength`; that invariant is also how a
    /// delta that no longer describes the text in hand (an edit the delegate
    /// never reported, say) is caught and the tree dropped instead of corrupted.
    struct EditDelta: Equatable {
        let start: Int
        let oldEnd: Int
        let newEnd: Int

        init(start: Int, oldEnd: Int, newEnd: Int) {
            self.start = start
            self.oldEnd = oldEnd
            self.newEnd = newEnd
        }

        /// `editedRange` is the edit's range in the *post*-edit text, as reported
        /// by `NSTextStorageDelegate`; `delta` is its length change.
        init(editedRange: NSRange, changeInLength delta: Int) {
            start = editedRange.location
            oldEnd = NSMaxRange(editedRange) - delta
            newEnd = NSMaxRange(editedRange)
        }

        /// Folds another storage edit in. Widening the window is always safe —
        /// tree-sitter just reuses less of the tree — so an edit landing outside
        /// it extends the window over both edits and the untouched text between.
        func merging(editedRange: NSRange, changeInLength delta: Int) -> EditDelta {
            // Where the text this edit replaced ended, in coordinates of the text
            // as it was *before* this edit (i.e. the window's `newEnd` space).
            let replacedEnd = NSMaxRange(editedRange) - delta
            let shift = newEnd - oldEnd

            // Offsets at or past the window's end map back to the old text by
            // undoing the shift; anything inside it is already covered by oldEnd.
            let mappedOldEnd = replacedEnd >= newEnd ? replacedEnd - shift : oldEnd
            let mergedOldEnd = max(oldEnd, mappedOldEnd)

            return EditDelta(
                start: min(start, editedRange.location),
                oldEnd: mergedOldEnd,
                // Keeps the invariant: the window's two ends differ by the total
                // length change accumulated so far.
                newEnd: mergedOldEnd + shift + delta
            )
        }

        /// Whether this delta still describes the two texts in hand. A false here
        /// means edits went unreported and the tree must be thrown away.
        func describes(oldLength: Int, newLength: Int) -> Bool {
            start >= 0
                && start <= oldEnd && oldEnd <= oldLength
                && start <= newEnd && newEnd <= newLength
                && newEnd - oldEnd == newLength - oldLength
        }

        func inputEdit(old: LineIndex, new: LineIndex) -> InputEdit {
            InputEdit(
                startByte: start * 2,
                oldEndByte: oldEnd * 2,
                newEndByte: newEnd * 2,
                startPoint: old.point(atUTF16: start),
                oldEndPoint: old.point(atUTF16: oldEnd),
                newEndPoint: new.point(atUTF16: newEnd)
            )
        }
    }

    /// Per-document tree-sitter state, owned by one `SyntaxHighlighter`.
    ///
    /// Holding the previous tree buys two things. The reparse becomes genuinely
    /// incremental (tree-sitter reuses the subtrees the edit didn't touch), and —
    /// the reason this exists — `changedRanges` can say which regions of the
    /// *parse* the edit changed. A structural edit (opening a quote, deleting a
    /// brace) re-parses everything below it, so recoloring only the paragraph the
    /// user typed in leaves the rest of the file wearing the colors of the old
    /// parse until they happen to edit it.
    ///
    /// Main-actor bound (the module default), so the tree never crosses an
    /// isolation boundary.
    final class Document {
        private let parser = Parser()
        private var tree: MutableTree?
        /// Extension the stored tree was parsed as; a change invalidates it.
        private var parsedExt = ""
        /// Line index of the source the stored tree was parsed from.
        private var parsedLines = LineIndex("")
        private var pendingEdit: EditDelta?

        /// Records a character edit to the storage. Must be called for every one
        /// (from the editor's `NSTextStorageDelegate`): the pre-edit shape of the
        /// change is knowable nowhere else, and a missed edit invalidates the tree.
        func noteEdit(editedRange: NSRange, changeInLength delta: Int) {
            pendingEdit = pendingEdit?.merging(editedRange: editedRange, changeInLength: delta)
                ?? EditDelta(editedRange: editedRange, changeInLength: delta)
        }

        /// Throws the tree away, so the next pass parses from scratch.
        func invalidate() {
            tree = nil
            pendingEdit = nil
        }

        /// Reparses and recolors. A nil `dirtyRange` means the whole document was
        /// replaced (file opened, theme changed): everything is reparsed and
        /// recolored. Otherwise the recolored region is `dirtyRange` plus every
        /// range whose parse the edit changed. Returns false — leaving the storage
        /// untouched — when the language is unsupported or the parse failed, so
        /// the caller can fall back.
        func highlight(
            textStorage: NSTextStorage,
            fullText: NSString,
            dirtyRange: NSRange?,
            ext: String,
            scheme: SyntaxHighlighter.SyntaxColorScheme
        ) -> Bool {
            let ext = ext.lowercased()
            guard let (language, query) = languageAndQuery(for: ext) else { return false }
            if ext != parsedExt || dirtyRange == nil {
                invalidate()
                parsedExt = ext
            }
            guard (try? parser.setLanguage(language)) != nil else { return false }

            let source = fullText as String
            let lines = LineIndex(source)
            let edit = pendingEdit.flatMap {
                $0.describes(oldLength: parsedLines.length, newLength: lines.length) ? $0 : nil
            }

            var changed: [NSRange] = []
            let newTree: MutableTree
            if let oldTree = tree, let edit {
                oldTree.edit(edit.inputEdit(old: parsedLines, new: lines))
                guard let reparsed = parse(source, reusing: oldTree) else {
                    invalidate()
                    return false
                }
                // The C call this wraps takes the edited *old* tree first and the
                // new one second, and reports the ranges of the new tree whose
                // syntax differs — that is the region the edit restructured.
                changed = oldTree.changedRanges(from: reparsed).map { $0.bytes.range }
                newTree = reparsed
            } else {
                guard let parsed = parse(source, reusing: nil) else {
                    invalidate()
                    return false
                }
                newTree = parsed
            }

            tree = newTree
            parsedLines = lines
            pendingEdit = nil

            let ranges = Self.recolorRanges(
                // A nil dirty range is the whole document (see above).
                dirty: dirtyRange ?? NSRange(location: 0, length: fullText.length),
                edited: edit.map { NSRange(location: $0.start, length: $0.newEnd - $0.start) },
                changed: changed,
                documentLength: fullText.length
            )
            for range in ranges {
                textStorage.removeAttribute(.foregroundColor, range: range)
                textStorage.addAttribute(.foregroundColor, value: scheme.text, range: range)
            }
            return applyCaptures(textStorage: textStorage, tree: newTree, query: query, ranges: ranges, scheme: scheme)
        }

        /// Colors each of `ranges` from `tree`'s captures. Returns false if the
        /// tree has no root, so the caller can fall back.
        private func applyCaptures(
            textStorage: NSTextStorage,
            tree: MutableTree,
            query: Query,
            ranges: [NSRange],
            scheme: SyntaxHighlighter.SyntaxColorScheme
        ) -> Bool {
            guard let root = tree.rootNode else { return false }

            for range in ranges {
                let cursor = query.execute(node: root, in: tree)
                // Restrict the query to the range's byte span. SwiftTreeSitter
                // parses the source as UTF-16LE, so the tree's byte offsets are
                // 2× the NSRange units — setRange does that conversion (a UTF-8
                // conversion here under-shoots by half and silently drops
                // highlights in the back half of the file). Captures are only
                // ever applied within `range` below, so this yields identical
                // output to scanning the whole tree — but on a per-keystroke edit
                // it walks the touched region instead of every capture in the
                // file. A wider construct (e.g. a multi-line string) still
                // matches because set_byte_range returns patterns intersecting it.
                cursor.setRange(range)

                // First-capture-wins per character, matching tree-sitter's convention
                // that earlier (more specific) query patterns take precedence — so a
                // keyword inside a string keeps the string color, etc.
                var colored = IndexSet()
                for match in cursor {
                    for capture in match.captures {
                        guard let color = color(forCapture: capture.nameComponents, scheme: scheme) else { continue }
                        let nodeRange = NSIntersectionRange(capture.node.range, range)
                        guard nodeRange.length > 0 else { continue }
                        let positions = IndexSet(integersIn: nodeRange.location..<(nodeRange.location + nodeRange.length))
                        let fresh = positions.subtracting(colored)
                        guard !fresh.isEmpty else { continue }
                        for run in fresh.rangeView {
                            textStorage.addAttribute(.foregroundColor, value: color, range: NSRange(run))
                        }
                        colored.formUnion(positions)
                    }
                }
            }
            return true
        }

        /// The regions to recolor: the dirty range, the edit itself (tree-sitter
        /// reports no changed range when a keystroke only grows a leaf node, so
        /// the typed text has to be covered explicitly), and every range whose
        /// parse changed. Merged and clamped, so the query runs once per
        /// contiguous region.
        static func recolorRanges(dirty: NSRange?, edited: NSRange?, changed: [NSRange], documentLength: Int) -> [NSRange] {
            let document = NSRange(location: 0, length: documentLength)
            let candidates = ([dirty, edited].compactMap { $0 } + changed)
                .map { NSIntersectionRange($0, document) }
                .filter { $0.length > 0 }
                .sorted { $0.location < $1.location }

            var merged: [NSRange] = []
            for range in candidates {
                if let last = merged.last, range.location <= NSMaxRange(last) {
                    merged[merged.count - 1] = NSUnionRange(last, range)
                } else {
                    merged.append(range)
                }
            }
            return merged
        }

        /// Feeds the parser one UTF-16LE encoding of the whole source. The library's
        /// own string reader chunks the source and cuts each chunk with
        /// `Range(_:in:)`, which returns nil — silently ending the parse early —
        /// when a chunk boundary lands inside a surrogate pair.
        private func parse(_ source: String, reusing oldTree: MutableTree?) -> MutableTree? {
            guard let data = source.data(using: .utf16LittleEndian) else { return nil }
            return parser.parse(tree: oldTree) { byteOffset, _ in
                guard byteOffset < data.count else { return nil }
                return data.subdata(in: byteOffset..<data.count)
            }
        }
    }
}
