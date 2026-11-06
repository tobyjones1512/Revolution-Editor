import Foundation
import AppKit

/// A lightweight, regex/scanner-based syntax highlighter, not a real parser for any of these
/// languages, just enough tokenization (comments, strings, numbers, keywords) to make source
/// files readable at a glance. Colors are chosen to read reasonably in both light and dark mode
/// via `NSColor` dynamic (semantic) colors where possible.
nonisolated enum SyntaxHighlighter {
    /// The colours come from the editor theme (Settings > Code Editor).
    struct Palette {
        static var keyword: NSColor { CodeTheme.color(.keyword) }
        static var type: NSColor { CodeTheme.color(.type) }
        static var string: NSColor { CodeTheme.color(.string) }
        static var comment: NSColor { CodeTheme.color(.comment) }
        static var number: NSColor { CodeTheme.color(.number) }
        static var tag: NSColor { CodeTheme.color(.tag) }
        static var attribute: NSColor { CodeTheme.color(.attribute) }
        static var plain: NSColor { CodeTheme.color(.plain) }
        static var function: NSColor { CodeTheme.color(.function) }
        static var constant: NSColor { CodeTheme.color(.constant) }
        static var preprocessor: NSColor { CodeTheme.color(.preprocessor) }
        static var escape: NSColor { CodeTheme.color(.escape) }
        static var member: NSColor { CodeTheme.color(.member) }
    }

    private struct LanguageRules {
        var lineComment: String?
        var blockCommentStart: String?
        var blockCommentEnd: String?
        var stringDelimiters: Set<Character> = ["\"", "'"]
        var keywords: Set<String> = []
        var caseInsensitiveKeywords = false
    }

    private static let rules: [CodeLanguage: LanguageRules] = [
        .swift: LanguageRules(lineComment: "//", blockCommentStart: "/*", blockCommentEnd: "*/", keywords: [
            "func", "var", "let", "class", "struct", "enum", "protocol", "extension", "if", "else", "guard",
            "switch", "case", "default", "for", "while", "repeat", "return", "import", "private", "public",
            "internal", "fileprivate", "open", "static", "final", "override", "init", "deinit", "self", "super",
            "nil", "true", "false", "throws", "throw", "try", "catch", "async", "await", "in", "as", "is", "some",
            "any", "where", "defer", "break", "continue", "fallthrough", "do", "associatedtype", "typealias",
            "mutating", "inout", "lazy", "weak", "unowned", "convenience", "required", "subscript", "operator",
            "indirect", "rethrows", "willSet", "didSet", "get", "set", "nonisolated", "actor",
        ]),
        .c: cFamily, .cpp: cFamilyPlusPlus, .objc: objcRules,
        .python: LanguageRules(lineComment: "#", blockCommentStart: nil, blockCommentEnd: nil, keywords: [
            "def", "class", "import", "from", "as", "if", "elif", "else", "for", "while", "in", "is", "not", "and",
            "or", "return", "yield", "pass", "break", "continue", "try", "except", "finally", "raise", "with",
            "lambda", "global", "nonlocal", "assert", "del", "None", "True", "False", "self", "async", "await",
        ]),
        .javascript: jsFamily, .typescript: tsFamily,
        .json: LanguageRules(lineComment: nil, blockCommentStart: nil, blockCommentEnd: nil, keywords: ["true", "false", "null"]),
        .css: LanguageRules(lineComment: nil, blockCommentStart: "/*", blockCommentEnd: "*/", keywords: []),
        .rust: LanguageRules(lineComment: "//", blockCommentStart: "/*", blockCommentEnd: "*/", keywords: [
            "fn", "let", "mut", "const", "static", "if", "else", "match", "for", "while", "loop", "break",
            "continue", "return", "struct", "enum", "trait", "impl", "pub", "mod", "use", "crate", "self",
            "super", "as", "where", "dyn", "move", "ref", "unsafe", "async", "await", "true", "false", "None",
            "Some", "Ok", "Err",
        ]),
        .go: LanguageRules(lineComment: "//", blockCommentStart: "/*", blockCommentEnd: "*/", keywords: [
            "func", "var", "const", "type", "struct", "interface", "map", "chan", "go", "defer", "if", "else",
            "for", "range", "switch", "case", "default", "break", "continue", "return", "package", "import",
            "nil", "true", "false", "select",
        ]),
        .java: LanguageRules(lineComment: "//", blockCommentStart: "/*", blockCommentEnd: "*/", keywords: [
            "class", "interface", "extends", "implements", "public", "private", "protected", "static", "final",
            "void", "int", "long", "double", "float", "boolean", "char", "byte", "short", "new", "this", "super",
            "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "try",
            "catch", "finally", "throw", "throws", "import", "package", "null", "true", "false", "enum",
            "abstract", "synchronized", "volatile", "instanceof", "fun", "val", "var", "when", "object",
            "companion",
        ]),
        .ruby: LanguageRules(lineComment: "#", blockCommentStart: nil, blockCommentEnd: nil, keywords: [
            "def", "end", "class", "module", "if", "elsif", "else", "unless", "case", "when", "while", "until",
            "for", "in", "do", "begin", "rescue", "ensure", "raise", "return", "yield", "require",
            "require_relative", "attr_accessor", "attr_reader", "attr_writer", "nil", "true", "false", "self",
        ]),
        .php: LanguageRules(lineComment: "//", blockCommentStart: "/*", blockCommentEnd: "*/", keywords: [
            "function", "class", "public", "private", "protected", "static", "if", "else", "elseif", "for",
            "foreach", "while", "do", "switch", "case", "default", "break", "continue", "return", "echo", "print",
            "new", "try", "catch", "finally", "throw", "namespace", "use", "require", "require_once", "include",
            "include_once", "null", "true", "false", "array", "self", "parent",
        ]),
        .sql: LanguageRules(lineComment: "--", blockCommentStart: "/*", blockCommentEnd: "*/", keywords: [
            "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "TABLE",
            "ALTER", "DROP", "JOIN", "INNER", "LEFT", "RIGHT", "OUTER", "ON", "GROUP", "BY", "ORDER", "HAVING",
            "AS", "AND", "OR", "NOT", "NULL", "IS", "IN", "LIKE", "LIMIT", "DISTINCT", "UNION", "PRIMARY", "KEY",
            "FOREIGN", "REFERENCES", "DEFAULT", "INDEX", "VIEW", "BEGIN", "END", "IF", "CASE", "WHEN", "THEN",
            "ELSE",
        ], caseInsensitiveKeywords: true),
        .shell: LanguageRules(lineComment: "#", blockCommentStart: nil, blockCommentEnd: nil, keywords: [
            "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until", "case", "esac",
            "function", "return", "exit", "export", "local", "readonly", "shift", "break", "continue", "echo",
            "set", "unset", "source", "alias", "true", "false",
        ]),
        .yaml: LanguageRules(lineComment: "#", blockCommentStart: nil, blockCommentEnd: nil, keywords: ["true", "false", "null"]),
    ]

    private static var cFamily: LanguageRules {
        LanguageRules(lineComment: "//", blockCommentStart: "/*", blockCommentEnd: "*/", keywords: [
            "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return",
            "void", "int", "char", "float", "double", "long", "short", "unsigned", "signed", "struct", "union",
            "enum", "typedef", "static", "extern", "const", "volatile", "sizeof", "goto", "auto", "register",
            "NULL", "true", "false",
        ])
    }
    private static var cFamilyPlusPlus: LanguageRules {
        var r = cFamily
        r.keywords.formUnion([
            "class", "public", "private", "protected", "virtual", "new", "delete", "namespace", "using",
            "template", "typename", "this", "friend", "operator", "try", "catch", "throw", "nullptr", "bool",
            "constexpr", "override", "final", "inline", "mutable", "explicit", "noexcept", "static_cast",
            "dynamic_cast", "const_cast", "reinterpret_cast",
        ])
        return r
    }
    private static var objcRules: LanguageRules {
        var r = cFamilyPlusPlus
        r.keywords.formUnion([
            "@interface", "@implementation", "@protocol", "@property", "@synthesize", "@end", "@selector",
            "@class", "id", "self", "super", "IBOutlet", "IBAction", "nonatomic", "strong", "weak", "readonly",
            "readwrite", "YES", "NO",
        ])
        return r
    }
    private static var jsFamily: LanguageRules {
        LanguageRules(lineComment: "//", blockCommentStart: "/*", blockCommentEnd: "*/", keywords: [
            "function", "var", "let", "const", "if", "else", "for", "while", "do", "switch", "case", "default",
            "break", "continue", "return", "new", "delete", "typeof", "instanceof", "in", "of", "this", "class",
            "extends", "super", "import", "export", "from", "as", "async", "await", "try", "catch", "finally",
            "throw", "yield", "null", "undefined", "true", "false", "void",
        ])
    }
    private static var tsFamily: LanguageRules {
        var r = jsFamily
        r.keywords.formUnion(["interface", "type", "enum", "implements", "private", "public", "protected", "readonly", "static", "namespace", "declare"])
        return r
    }

    /// The keywords of `language` (for code completion).
    static func keywords(for language: CodeLanguage) -> [String] { rules[language].map { Array($0.keywords) } ?? [] }

    /// Highlights `text` for `language`, returning a fully-styled `NSAttributedString` (base font
    /// applied throughout, colors layered on top). Markdown/HTML/XML get their own lightweight
    /// passes since angle-bracket tags and heading/emphasis markers aren't well captured by the
    /// generic keyword/string/comment/number tokenizer the other languages share.
    static func highlight(_ text: String, language: CodeLanguage, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: Palette.plain])
        guard !text.isEmpty else { return result }

        switch language {
        case .html, .xml:
            highlightMarkup(text, into: result)
        case .markdown:
            highlightMarkdown(text, into: result)
        case .plainText:
            break
        default:
            if let r = rules[language] {
                highlightGeneric(text, rules: r, language: language, into: result)
            }
        }
        return result
    }

    // MARK: Generic tokenizer (comments / strings / numbers / keywords)

    private static let funcWords: Set<String> = ["func", "function", "def", "fn", "fun", "sub"]
    private static let typeWords: Set<String> = ["class", "struct", "enum", "protocol", "extension", "interface", "trait", "impl", "actor", "union", "namespace", "typealias", "typedef", "type"]

    /// The shared tokenizer: comments, strings (with escapes, format specifiers and interpolation), numbers,
    /// preprocessor lines, attributes, and identifiers classified as keyword / type / function / constant / member.
    private static func highlightGeneric(_ text: String, rules: LanguageRules, language: CodeLanguage, into result: NSMutableAttributedString) {
        let u = Array(text.utf16)
        let n = u.count
        let isC = language == .c || language == .cpp || language == .objc
        let hasAttributes = language == .swift || language == .java || language == .typescript || language == .python || language == .objc
        func ch(_ i: Int) -> UInt16 { i >= 0 && i < n ? u[i] : 0 }
        func isLetter(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 || c > 127 }
        func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
        func isHex(_ c: UInt16) -> Bool { isDigit(c) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102) }
        func isIdent(_ c: UInt16) -> Bool { isLetter(c) || isDigit(c) }
        func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 13 }
        func set(_ color: NSColor, _ a: Int, _ b: Int) {
            guard b > a else { return }
            result.addAttribute(.foregroundColor, value: color, range: NSRange(location: a, length: min(b, n) - a))
        }
        func matches(_ s: [UInt16], at i: Int) -> Bool {
            guard !s.isEmpty, i + s.count <= n else { return false }
            for k in 0..<s.count where u[i + k] != s[k] { return false }
            return true
        }
        let lineC = rules.lineComment.map { Array($0.utf16) }
        let blockS = rules.blockCommentStart.map { Array($0.utf16) }
        let blockE = rules.blockCommentEnd.map { Array($0.utf16) }
        let delimiters = Set(rules.stringDelimiters.compactMap { $0.utf16.first })
        let multilineDelimiters: Set<UInt16> = language == .javascript || language == .typescript ? [96] : []
        let tripleQuoted = language == .python || language == .swift

        var i = 0
        var atLineStart = true
        var prevWord = ""
        var prevChar: UInt16 = 0           // last non-space character before the current token

        while i < n {
            let c = u[i]
            if c == 10 { atLineStart = true; prevChar = 0; i += 1; continue }
            if isSpace(c) { i += 1; continue }

            // Comments
            if let lc = lineC, matches(lc, at: i) {
                let start = i
                while i < n, u[i] != 10 { i += 1 }
                set(Palette.comment, start, i); atLineStart = false; continue
            }
            if let bs = blockS, let be = blockE, matches(bs, at: i) {
                let start = i
                i += bs.count
                while i < n, !matches(be, at: i) { i += 1 }
                i = min(n, i + be.count)
                set(Palette.comment, start, i); atLineStart = false; continue
            }

            // C preprocessor lines: #include <x.h>, #define NAME, #if ...
            if isC, c == 35, atLineStart {
                let start = i
                i += 1
                while i < n, isSpace(u[i]) { i += 1 }
                let wordStart = i
                while i < n, isLetter(u[i]) { i += 1 }
                set(Palette.preprocessor, start, i)
                let directive = String(decoding: u[wordStart..<i], as: UTF16.self)
                while i < n, isSpace(u[i]) { i += 1 }
                if directive == "include", ch(i) == 60 {            // <...>
                    let a = i
                    while i < n, u[i] != 62, u[i] != 10 { i += 1 }
                    if ch(i) == 62 { i += 1 }
                    set(Palette.string, a, i)
                } else if directive == "define" || directive == "undef" || directive == "ifdef" || directive == "ifndef" {
                    let a = i
                    while i < n, isIdent(u[i]) { i += 1 }
                    set(Palette.constant, a, i)
                }
                atLineStart = false; prevWord = ""; continue
            }
            if language == .swift, c == 35, isLetter(ch(i + 1)) {      // #if, #available, #selector
                let start = i
                i += 1
                while i < n, isIdent(u[i]) { i += 1 }
                set(Palette.preprocessor, start, i); atLineStart = false; continue
            }

            // Strings
            let triple: Bool = tripleQuoted && (c == 34 || c == 39) && ch(i + 1) == c && ch(i + 2) == c
            if triple || delimiters.contains(c) || multilineDelimiters.contains(c) {
                let quote = c
                let multiline = triple || multilineDelimiters.contains(c)
                let start = i
                let isKey = language == .json
                i += triple ? 3 : 1
                var segment = start
                let swiftInterp = language == .swift
                while i < n {
                    let d = u[i]
                    if d == quote && (!triple || (ch(i + 1) == quote && ch(i + 2) == quote)) { i += triple ? 3 : 1; break }
                    if d == 10 && !multiline { break }
                    if d == 92, i + 1 < n {                                      // escape
                        set(Palette.string, segment, i)
                        let a = i
                        i += 2
                        let e = ch(a + 1)
                        if swiftInterp, e == 40 {                                  // \( ... ) interpolation stays plain
                            var depth = 1
                            while i < n, depth > 0 { if u[i] == 40 { depth += 1 } else if u[i] == 41 { depth -= 1 }; i += 1 }
                            set(Palette.plain, a, i)
                        } else {
                            if e == 120 { while i < n, isHex(u[i]), i - a < 4 { i += 1 } }
                            else if e == 117, ch(i) == 123 { while i < n, u[i] != 125 { i += 1 }; i = min(n, i + 1) }
                            else if isDigit(e) { while i < n, isDigit(u[i]), i - a < 4 { i += 1 } }
                            set(Palette.escape, a, i)
                        }
                        segment = i
                        continue
                    }
                    if isC, d == 37 {   // printf-style specifiers
                        var k = i + 1
                        if ch(k) == 37 { i += 2; continue }
                        while k < n, "-+ #0123456789.*hlLzjt".utf16.contains(u[k]) { k += 1 }
                        if k < n, "diouxXeEfgGcspn".utf16.contains(u[k]) {
                            set(Palette.string, segment, i)
                            set(Palette.escape, i, k + 1)
                            i = k + 1; segment = i
                            continue
                        }
                    }
                    i += 1
                }
                set(Palette.string, segment, i)
                if isKey {
                    var k = i
                    while k < n, isSpace(u[k]) { k += 1 }
                    if ch(k) == 58 { set(Palette.tag, start, i) }                 // "key":
                }
                atLineStart = false; prevChar = c; prevWord = ""; continue
            }

            // Numbers
            if isDigit(c) || (c == 46 && isDigit(ch(i + 1)) && !isIdent(prevChar)) {
                let start = i
                if c == 48, ch(i + 1) == 120 || ch(i + 1) == 88 {
                    i += 2; while i < n, isHex(u[i]) || u[i] == 95 { i += 1 }
                } else if c == 48, ch(i + 1) == 98 || ch(i + 1) == 66 {
                    i += 2; while i < n, u[i] == 48 || u[i] == 49 || u[i] == 95 { i += 1 }
                } else {
                    while i < n, isDigit(u[i]) || u[i] == 95 { i += 1 }
                    if ch(i) == 46, isDigit(ch(i + 1)) || !isLetter(ch(i + 1)) { i += 1; while i < n, isDigit(u[i]) || u[i] == 95 { i += 1 } }
                    if (ch(i) == 101 || ch(i) == 69), isDigit(ch(i + 1)) || ((ch(i + 1) == 43 || ch(i + 1) == 45) && isDigit(ch(i + 2))) {
                        i += 2; while i < n, isDigit(u[i]) { i += 1 }
                    }
                }
                while i < n, "uUlLfFdD".utf16.contains(u[i]) { i += 1 }          // 10u, 1.0f, 5UL
                set(Palette.number, start, i); atLineStart = false; prevChar = 48; prevWord = ""; continue
            }

            // Attributes: @State, @MainActor, @objc
            if c == 64, hasAttributes, isLetter(ch(i + 1)) {
                let start = i
                i += 1
                while i < n, isIdent(u[i]) { i += 1 }
                let word = String(decoding: u[start..<i], as: UTF16.self)
                set(rules.keywords.contains(word) ? Palette.keyword : Palette.attribute, start, i)
                atLineStart = false; prevWord = ""; continue
            }

            // Identifiers and keywords
            if isLetter(c) || c == 64 {
                let start = i
                i += 1
                while i < n, isIdent(u[i]) { i += 1 }
                let word = String(decoding: u[start..<i], as: UTF16.self)
                let isMember = prevChar == 46
                var k = i
                while k < n, isSpace(u[k]) { k += 1 }
                let isCall = ch(k) == 40
                let isKeyword = rules.caseInsensitiveKeywords
                    ? rules.keywords.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame })
                    : rules.keywords.contains(word)
                let first = u[start]
                let capitalised = first >= 65 && first <= 90
                let allCaps = word.count >= 2 && word.unicodeScalars.allSatisfy { ($0.value >= 65 && $0.value <= 90) || ($0.value >= 48 && $0.value <= 57) || $0.value == 95 } && word.unicodeScalars.contains { $0.value >= 65 && $0.value <= 90 }
                let hasLower = word.unicodeScalars.contains { $0.value >= 97 && $0.value <= 122 }
                if isKeyword && !(isMember && !isCall) {
                    set(Palette.keyword, start, i)
                } else if funcWords.contains(prevWord) {
                    set(Palette.function, start, i)
                } else if typeWords.contains(prevWord) {
                    set(Palette.type, start, i)
                } else if isCall {
                    set(capitalised && hasLower && language != .c && !isC ? Palette.type : Palette.function, start, i)
                } else if allCaps && !isMember {
                    set(Palette.constant, start, i)
                } else if capitalised && hasLower && !isMember {
                    set(Palette.type, start, i)
                } else if isMember {
                    set(Palette.member, start, i)
                } else if (word.hasSuffix("_t") || word.hasPrefix("GX") || word == "u8" || word == "u16" || word == "u32" || word == "u64" || word == "s8" || word == "s16" || word == "s32" || word == "s64" || word == "f32" || word == "f64") && isC {
                    set(Palette.type, start, i)
                }
                atLineStart = false; prevWord = word; prevChar = 97; continue
            }

            // Anything else (punctuation, operators).
            atLineStart = false
            prevChar = c
            if c != 46 { prevWord = "" }
            i += 1
        }
    }

    // MARK: HTML/XML

    private static func highlightMarkup(_ text: String, into result: NSMutableAttributedString) {
        let chars = Array(text)
        let n = chars.count
        var i = 0
        func setColor(_ color: NSColor, _ range: Range<Int>) {
            result.addAttribute(.foregroundColor, value: color, range: NSRange(location: range.lowerBound, length: range.upperBound - range.lowerBound))
        }
        while i < n {
            if chars[i] == "<" {
                if i + 3 < n, chars[i + 1] == "!", chars[i + 2] == "-", chars[i + 3] == "-" {
                    let start = i
                    i += 4
                    while i + 2 < n, !(chars[i] == "-" && chars[i + 1] == "-" && chars[i + 2] == ">") { i += 1 }
                    i = min(n, i + 3)
                    setColor(Palette.comment, start..<i)
                    continue
                }
                let start = i
                i += 1
                while i < n, chars[i] != ">" {
                    if chars[i] == "\"" || chars[i] == "'" {
                        let quote = chars[i]; let sStart = i; i += 1
                        while i < n, chars[i] != quote { i += 1 }
                        i = min(n, i + 1)
                        setColor(Palette.string, sStart..<i)
                        continue
                    }
                    i += 1
                }
                i = min(n, i + 1)
                setColor(Palette.tag, start..<i)
                continue
            }
            i += 1
        }
    }

    // MARK: Markdown

    private static func highlightMarkdown(_ text: String, into result: NSMutableAttributedString) {
        let lines = text.components(separatedBy: "\n")
        var offset = 0
        for line in lines {
            let range = offset..<(offset + line.count)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                result.addAttribute(.foregroundColor, value: Palette.keyword, range: NSRange(location: range.lowerBound, length: range.upperBound - range.lowerBound))
            } else if trimmed.hasPrefix("```") {
                result.addAttribute(.foregroundColor, value: Palette.comment, range: NSRange(location: range.lowerBound, length: range.upperBound - range.lowerBound))
            } else if trimmed.hasPrefix(">") {
                result.addAttribute(.foregroundColor, value: Palette.number, range: NSRange(location: range.lowerBound, length: range.upperBound - range.lowerBound))
            }
            offset += line.count + 1
        }
    }
}
