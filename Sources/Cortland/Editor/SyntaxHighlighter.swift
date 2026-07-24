import Cocoa

class SyntaxHighlighter {
    private let textView: NSTextView
    private let colorScheme: SyntaxColorScheme
    var fileExtension: String = ""

    /// Files larger than this (UTF-16 units) are not highlighted at all.
    static let maxHighlightLength = 1_000_000

    /// Compiled regexes are cached per pattern; patterns are static per language.
    private var regexCache: [String: NSRegularExpression] = [:]

    /// Tree-sitter state for the document this highlighter is attached to: the
    /// last parse tree plus the edits made since, so a reparse knows what the
    /// edit restructured. Unused for the regex languages.
    private let treeSitter = TreeSitterHighlighter.Document()

    struct SyntaxColorScheme {
        let text: NSColor
        let background: NSColor
        let comment: NSColor
        let keyword: NSColor
        let string: NSColor
        let number: NSColor
        let function: NSColor
        let type: NSColor

        /// Built from the active theme's palette, so syntax colors follow
        /// whichever theme is selected.
        static var current: SyntaxColorScheme {
            let p = Theme.shared.palette
            return SyntaxColorScheme(
                text: p.text,
                background: p.base,
                comment: p.overlay0,
                keyword: p.mauve,
                string: p.green,
                number: p.peach,
                function: p.blue,
                type: p.yellow
            )
        }
    }

    init(textView: NSTextView, colorScheme: SyntaxColorScheme = .current) {
        self.textView = textView
        self.colorScheme = colorScheme
    }

    /// Highlights the whole document.
    func highlightSyntax() {
        highlightSyntax(in: nil)
    }

    /// Records a character edit to the document. The editor must report every
    /// one: the tree-sitter path folds them into the delta it hands the parser,
    /// and an edit it never hears about would leave it reusing a tree that no
    /// longer matches the text.
    func noteEdit(editedRange: NSRange, changeInLength delta: Int) {
        treeSitter.noteEdit(editedRange: editedRange, changeInLength: delta)
    }

    /// Highlights only the paragraphs overlapping `dirtyRange` (the whole
    /// document when nil), so edits don't re-scan the entire file.
    func highlightSyntax(in dirtyRange: NSRange?) {
        guard let textStorage = textView.textStorage else { return }
        guard textStorage.length <= Self.maxHighlightLength else { return }

        let nsText = textStorage.string as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        let range: NSRange
        if let dirtyRange = dirtyRange {
            let clamped = NSIntersectionRange(dirtyRange, fullRange)
            range = nsText.paragraphRange(for: clamped)
        } else {
            range = fullRange
        }
        guard range.length > 0 else { return }

        textStorage.beginEditing()
        defer { textStorage.endEditing() }

        // tree-sitter is authoritative for every language it has a grammar for
        // (Swift, Go, Rust, Python, JS/TS/JSX/TSX, Markdown — the advertised
        // set). Its grammar-accurate output fully replaces the old regex passes,
        // so there is no regex fallback for these: on the rare parse failure the
        // text simply stays the base color.
        //
        // It resets the base color itself rather than being handed a reset
        // range: a structural edit changes the parse below the dirty paragraph,
        // so which ranges need recoloring is only known once it has reparsed.
        if TreeSitterHighlighter.canHighlight(ext: fileExtension) {
            let handled = treeSitter.highlight(
                textStorage: textStorage,
                fullText: nsText,
                dirtyRange: dirtyRange == nil ? nil : range,
                ext: fileExtension,
                scheme: colorScheme
            )
            if !handled {
                resetToBaseColor(textStorage, range: range)
            }
            return
        }

        resetToBaseColor(textStorage, range: range)

        // Regex highlighting survives only for languages tree-sitter has no
        // grammar for: C/C++ and Java (keyword rules), HTML/CSS/JSON, and a
        // generic pass for unknown text.
        if let rules = Self.rules(for: fileExtension) {
            highlightKeywordLanguage(rules, text: nsText, textStorage: textStorage, range: range)
        } else {
            switch fileExtension {
            case "html", "htm":
                highlightHTML(text: nsText, textStorage: textStorage, range: range)
            case "css":
                highlightCSS(text: nsText, textStorage: textStorage, range: range)
            case "json":
                highlightJSON(text: nsText, textStorage: textStorage, range: range)
            default:
                highlightGeneric(text: nsText, textStorage: textStorage, range: range)
            }
        }
    }

    private func resetToBaseColor(_ textStorage: NSTextStorage, range: NSRange) {
        textStorage.removeAttribute(.foregroundColor, range: range)
        textStorage.addAttribute(.foregroundColor, value: colorScheme.text, range: range)
    }

    /// Regex fallback for keyword-based languages tree-sitter doesn't cover
    /// (C/C++, Java in the document path). The per-language data lives in
    /// `rulesByExt`, still shared with the diff tokenizer's `tokens(for:)`,
    /// which regex-highlights every language line-by-line.
    private func highlightKeywordLanguage(_ rules: LanguageRules, text: NSString, textStorage: NSTextStorage, range: NSRange) {
        // Apply order is lowest-to-highest priority (later passes override
        // earlier ones). Numbers are weakest, so a `42` inside a string or a
        // trailing `// 42` is reclaimed by the string/comment pass that follows.
        // Strings stay last so a URL inside a string (`"http://x"`) wins over
        // the `//` comment pattern.
        highlightNumbers(in: text, textStorage: textStorage, range: range)
        highlightKeywords(rules.keywords, in: text, textStorage: textStorage, range: range, color: colorScheme.keyword)
        highlightKeywords(rules.types, in: text, textStorage: textStorage, range: range, color: colorScheme.type)
        highlightComments(in: text, textStorage: textStorage, range: range, commentStyle: rules.comment)
        highlightStrings(in: text, textStorage: textStorage, range: range)
    }

    private func highlightHTML(text: NSString, textStorage: NSTextStorage, range: NSRange) {
        // HTML tags
        highlightPattern("<[^>]+>", in: text, textStorage: textStorage, range: range, color: colorScheme.keyword)

        // HTML comments
        highlightPattern("<!--[\\s\\S]*?-->", in: text, textStorage: textStorage, range: range, color: colorScheme.comment)

        // Attribute values
        highlightPattern("\"[^\"]*\"", in: text, textStorage: textStorage, range: range, color: colorScheme.string)
    }

    private func highlightCSS(text: NSString, textStorage: NSTextStorage, range: NSRange) {
        // CSS properties
        highlightPattern("\\b[a-z-]+(?=\\s*:)", in: text, textStorage: textStorage, range: range, color: colorScheme.keyword)

        // CSS values
        highlightPattern("(?<=:)\\s*[^;]+", in: text, textStorage: textStorage, range: range, color: colorScheme.string)

        // CSS comments
        highlightPattern("/\\*[\\s\\S]*?\\*/", in: text, textStorage: textStorage, range: range, color: colorScheme.comment)
    }

    private func highlightJSON(text: NSString, textStorage: NSTextStorage, range: NSRange) {
        // JSON strings
        highlightPattern("\"([^\"\\\\]|\\\\.)*\"", in: text, textStorage: textStorage, range: range, color: colorScheme.string)

        // JSON numbers
        highlightNumbers(in: text, textStorage: textStorage, range: range)

        // JSON booleans and null
        highlightKeywords(["true", "false", "null"], in: text, textStorage: textStorage, range: range, color: colorScheme.keyword)
    }

    private func highlightGeneric(text: NSString, textStorage: NSTextStorage, range: NSRange) {
        // Generic highlighting for unknown file types
        highlightComments(in: text, textStorage: textStorage, range: range, commentStyle: .slashSlash)
        highlightStrings(in: text, textStorage: textStorage, range: range)
        highlightNumbers(in: text, textStorage: textStorage, range: range)
    }

    // MARK: - Language data

    fileprivate enum CommentStyle {
        case slashSlash
        case hash
        case slashStar
    }

    struct LanguageRules {
        let keywords: [String]
        let types: [String]
        fileprivate let comment: CommentStyle
    }

    /// Single source of truth for every keyword-based language, shared by the
    /// document highlighter and the line-isolated diff tokenizer.
    private static let rulesByExt: [String: LanguageRules] = {
        let swift = LanguageRules(
            keywords: ["class", "struct", "enum", "protocol", "extension", "func", "var", "let", "if", "else", "for", "while", "switch", "case", "default", "break", "continue", "return", "import", "private", "public", "internal", "fileprivate", "static", "final", "override", "mutating", "nonmutating", "convenience", "required", "optional", "weak", "strong", "unowned", "lazy", "dynamic", "inout", "throws", "rethrows", "try", "catch", "defer", "guard", "where", "associatedtype", "typealias", "self", "Self", "super", "nil", "true", "false", "init", "deinit", "subscript", "operator", "precedencegroup", "infix", "prefix", "postfix", "left", "right", "none", "assignment", "higherThan", "lowerThan", "as", "is", "in", "some", "any"],
            types: ["Int", "Float", "Double", "String", "Bool", "Array", "Dictionary", "Set", "Optional", "Result", "NSString", "NSArray", "NSDictionary", "NSSet", "NSNumber", "NSData", "NSDate", "NSURL", "NSError", "NSObject", "UIView", "UIViewController", "NSView", "NSViewController"],
            comment: .slashSlash
        )
        let javascript = LanguageRules(
            keywords: ["var", "let", "const", "function", "class", "extends", "import", "export", "from", "default", "if", "else", "for", "while", "do", "switch", "case", "break", "continue", "return", "try", "catch", "finally", "throw", "new", "delete", "typeof", "instanceof", "in", "of", "this", "super", "static", "async", "await", "yield", "true", "false", "null", "undefined"],
            types: ["Array", "Object", "String", "Number", "Boolean", "Function", "Date", "RegExp", "Error", "Promise", "Map", "Set", "WeakMap", "WeakSet"],
            comment: .slashSlash
        )
        let python = LanguageRules(
            keywords: ["def", "class", "if", "elif", "else", "for", "while", "break", "continue", "return", "import", "from", "as", "try", "except", "finally", "raise", "with", "lambda", "yield", "global", "nonlocal", "and", "or", "not", "is", "in", "True", "False", "None", "pass", "del", "assert"],
            types: ["int", "float", "str", "bool", "list", "dict", "tuple", "set", "frozenset", "bytes", "bytearray"],
            comment: .hash
        )
        let rust = LanguageRules(
            keywords: ["fn", "let", "mut", "const", "static", "struct", "enum", "impl", "trait", "mod", "pub", "use", "if", "else", "match", "for", "while", "loop", "break", "continue", "return", "where", "move", "ref", "self", "Self", "super", "crate", "true", "false", "unsafe", "async", "await"],
            types: ["i8", "i16", "i32", "i64", "i128", "u8", "u16", "u32", "u64", "u128", "f32", "f64", "bool", "char", "str", "String", "Vec", "HashMap", "Result", "Option", "Box", "Rc", "Arc"],
            comment: .slashSlash
        )
        let go = LanguageRules(
            keywords: ["package", "import", "func", "var", "const", "type", "struct", "interface", "if", "else", "for", "range", "switch", "case", "default", "break", "continue", "return", "go", "defer", "select", "chan", "map", "make", "new", "append", "len", "cap", "copy", "delete", "close", "true", "false", "nil"],
            types: ["int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64", "float32", "float64", "complex64", "complex128", "bool", "byte", "rune", "string", "error"],
            comment: .slashSlash
        )
        let c = LanguageRules(
            keywords: ["auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long", "register", "restrict", "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "_Bool", "_Complex", "_Imaginary", "true", "false"],
            types: ["int", "char", "float", "double", "void", "long", "short", "unsigned", "signed", "bool", "size_t", "ssize_t", "ptrdiff_t", "wchar_t"],
            comment: .slashSlash
        )
        let java = LanguageRules(
            keywords: ["abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const", "continue", "default", "do", "double", "else", "enum", "extends", "final", "finally", "float", "for", "goto", "if", "implements", "import", "instanceof", "int", "interface", "long", "native", "new", "package", "private", "protected", "public", "return", "short", "static", "strictfp", "super", "switch", "synchronized", "this", "throw", "throws", "transient", "try", "void", "volatile", "while", "true", "false", "null"],
            types: ["String", "Integer", "Double", "Float", "Boolean", "Character", "Byte", "Short", "Long", "Object", "Class", "Array", "List", "Map", "Set", "Collection"],
            comment: .slashSlash
        )
        return [
            "swift": swift,
            "js": javascript, "ts": javascript, "jsx": javascript, "tsx": javascript,
            "py": python,
            "rs": rust,
            "go": go,
            "c": c, "cpp": c, "cc": c, "cxx": c, "h": c, "hpp": c,
            "java": java
        ]
    }()

    static func rules(for ext: String) -> LanguageRules? {
        rulesByExt[ext]
    }

    // MARK: - Diff tokenization (line-isolated, range-returning)

    /// Tokenizes a single isolated line of source and returns the foreground
    /// colors to apply, without touching any text storage. Used by
    /// `InlineDiffRenderer` to syntax-highlight diff content while leaving the
    /// add/remove background bars intact. Ranges are in UTF-16 units relative
    /// to `line`; later entries override earlier ones, matching the document
    /// highlighter's apply order (keywords, types, comments, strings, numbers).
    static func tokens(for line: String, ext: String, scheme: SyntaxColorScheme = .current) -> [(range: NSRange, color: NSColor)] {
        guard !line.isEmpty else { return [] }
        let ns = line as NSString
        var out: [(range: NSRange, color: NSColor)] = []

        func add(_ pattern: String, _ color: NSColor) {
            for r in staticRanges(pattern, in: ns) {
                out.append((r, color))
            }
        }

        let keywordColor = scheme.keyword
        let typeColor = scheme.type
        let commentPattern: String

        // Numbers first (weakest): a `42` inside a string or a trailing `// 42`
        // is reclaimed by the string/comment pass below.
        add("\\b\\d+(\\.\\d+)?([eE][+-]?\\d+)?\\b", scheme.number)

        if let rules = rulesByExt[ext] {
            add(keywordAlternation(rules.keywords), keywordColor)
            add(keywordAlternation(rules.types), typeColor)
            commentPattern = Self.commentPattern(for: rules.comment)
        } else {
            switch ext {
            case "json":
                add("\\b(?:true|false|null)\\b", keywordColor)
            case "md", "markdown", "mdx":
                add("^#{1,6}\\s+.*$", keywordColor)
                add("`[^`]+`", scheme.function)
                add("\\[([^\\]]+)\\]\\([^)]+\\)", scheme.string)
            default:
                break
            }
            commentPattern = Self.commentPattern(for: .slashSlash)
        }

        // Strings last so a URL inside a string (`"http://x"`) wins over the
        // `//` comment pattern; comments win over keywords/numbers.
        add(commentPattern, scheme.comment)
        add("\"([^\"\\\\]|\\\\.)*\"", scheme.string)
        add("'([^'\\\\]|\\\\.)*'", scheme.string)

        return out
    }

    private static func keywordAlternation(_ keywords: [String]) -> String {
        let escaped = keywords.map { NSRegularExpression.escapedPattern(for: $0) }
        return "\\b(?:\(escaped.joined(separator: "|")))\\b"
    }

    private static func commentPattern(for style: CommentStyle) -> String {
        switch style {
        case .slashSlash: return "//.*$"
        case .hash: return "#.*$"
        case .slashStar: return "/\\*[\\s\\S]*?\\*/"
        }
    }

    private static var staticRegexCache: [String: NSRegularExpression] = [:]

    private static func staticRanges(_ pattern: String, in ns: NSString) -> [NSRange] {
        let regex: NSRegularExpression
        if let cached = staticRegexCache[pattern] {
            regex = cached
        } else if let compiled = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) {
            staticRegexCache[pattern] = compiled
            regex = compiled
        } else {
            return []
        }
        var out: [NSRange] = []
        regex.enumerateMatches(in: ns as String, options: [], range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            if let match = match { out.append(match.range) }
        }
        return out
    }

    // MARK: - Helper Methods

    private func highlightKeywords(_ keywords: [String], in text: NSString, textStorage: NSTextStorage, range: NSRange, color: NSColor) {
        // One alternation regex for the whole keyword set instead of one
        // regex pass per keyword.
        let escaped = keywords.map { NSRegularExpression.escapedPattern(for: $0) }
        let pattern = "\\b(?:\(escaped.joined(separator: "|")))\\b"
        highlightPattern(pattern, in: text, textStorage: textStorage, range: range, color: color)
    }

    private func highlightComments(in text: NSString, textStorage: NSTextStorage, range: NSRange, commentStyle: CommentStyle) {
        highlightPattern(Self.commentPattern(for: commentStyle), in: text, textStorage: textStorage, range: range, color: colorScheme.comment)
    }

    private func highlightStrings(in text: NSString, textStorage: NSTextStorage, range: NSRange) {
        // Double quoted strings
        highlightPattern("\"([^\"\\\\]|\\\\.)*\"", in: text, textStorage: textStorage, range: range, color: colorScheme.string)

        // Single quoted strings
        highlightPattern("'([^'\\\\]|\\\\.)*'", in: text, textStorage: textStorage, range: range, color: colorScheme.string)
    }

    private func highlightNumbers(in text: NSString, textStorage: NSTextStorage, range: NSRange) {
        // Integer and floating point numbers
        highlightPattern("\\b\\d+(\\.\\d+)?([eE][+-]?\\d+)?\\b", in: text, textStorage: textStorage, range: range, color: colorScheme.number)
    }

    private func highlightPattern(_ pattern: String, in text: NSString, textStorage: NSTextStorage, range: NSRange, color: NSColor) {
        guard let regex = cachedRegex(for: pattern) else { return }

        regex.enumerateMatches(in: text as String, options: [], range: range) { match, _, _ in
            if let match = match {
                textStorage.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }
    }

    private func cachedRegex(for pattern: String) -> NSRegularExpression? {
        if let cached = regexCache[pattern] {
            return cached
        }
        let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        regexCache[pattern] = regex
        return regex
    }
}
