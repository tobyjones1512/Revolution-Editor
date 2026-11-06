import Foundation

nonisolated enum StrPart { case text(String), interp([Token]) }

nonisolated enum Tok {
    case ident(String), keyword(String), int(Int), double(Double), string([StrPart]), op(String), punct(String), eof
}

nonisolated struct Token {
    var tok: Tok
    var line: Int
    var col: Int
    var newlineBefore: Bool
    var spaceBefore: Bool
}

nonisolated enum SwiftLexer {
    static let keywords: Set<String> = ["func", "let", "var", "if", "else", "while", "repeat", "for", "in", "return", "struct", "enum",
                                        "case", "switch", "default", "break", "continue", "true", "false", "mutating", "self", "import",
                                        "class", "protocol", "extension", "guard", "defer", "do", "try", "catch", "throw", "static",
                                        "init", "nil", "where", "is", "as", "inout", "typealias", "deinit", "subscript", "operator",
                                        "associatedtype", "throws", "rethrows", "async", "await", "fallthrough", "Any", "Self"]
    private static let ops3 = ["...", "..<", "<<=", ">>=", "===", "!=="]
    private static let ops2 = ["==", "!=", "<=", ">=", "&&", "||", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "->", "<<", ">>", "??"]

    static func lex(_ src: String, file: String, lineOffset: Int = 0) throws -> [Token] {
        let c = Array(src.unicodeScalars)
        var i = 0, line = 1 + lineOffset, lineStart = 0
        var out: [Token] = []
        var nl = false, sp = false
        func err(_ m: String) -> SwiftError { SwiftError(file: file, line: line, col: i - lineStart + 1, message: m) }
        func isIdentStart(_ u: Unicode.Scalar) -> Bool { u == "_" || (u.isASCII && CharacterSet.letters.contains(u)) }
        func isDigit(_ u: Unicode.Scalar) -> Bool { u.isASCII && u.value >= 48 && u.value <= 57 }
        func add(_ t: Tok, _ start: Int) { out.append(Token(tok: t, line: line, col: start - lineStart + 1, newlineBefore: nl, spaceBefore: sp || nl || out.isEmpty)); nl = false; sp = false }

        while i < c.count {
            let u = c[i]
            if u == "\n" { line += 1; i += 1; lineStart = i; nl = true; continue }
            if u == " " || u == "\t" || u == "\r" { i += 1; sp = true; continue }
            if u == "/", i + 1 < c.count, c[i + 1] == "/" { while i < c.count, c[i] != "\n" { i += 1 }; continue }
            if u == "/", i + 1 < c.count, c[i + 1] == "*" {
                i += 2
                while i + 1 < c.count, !(c[i] == "*" && c[i + 1] == "/") { if c[i] == "\n" { line += 1; lineStart = i + 1; nl = true }; i += 1 }
                i += 2; sp = true; continue
            }
            let start = i
            if isIdentStart(u) || u == "$" {
                var s = ""
                s.unicodeScalars.append(u); i += 1
                while i < c.count, isIdentStart(c[i]) || isDigit(c[i]) { s.unicodeScalars.append(c[i]); i += 1 }
                add(keywords.contains(s) ? .keyword(s) : .ident(s), start); continue
            }
            if isDigit(u) {
                var s = ""
                if u == "0", i + 1 < c.count, c[i + 1] == "x" || c[i + 1] == "b" {
                    let radix = c[i + 1] == "x" ? 16 : 2
                    i += 2
                    while i < c.count, c[i].properties.isASCIIHexDigit || c[i] == "_" { if c[i] != "_" { s.unicodeScalars.append(c[i]) }; i += 1 }
                    guard let v = Int(s, radix: radix) else { throw err("invalid number") }
                    add(.int(v), start); continue
                }
                var isDouble = false
                while i < c.count {
                    if isDigit(c[i]) { s.unicodeScalars.append(c[i]) }
                    else if c[i] == "_" {}
                    else if c[i] == ".", i + 1 < c.count, isDigit(c[i + 1]), !isDouble { isDouble = true; s += "." }
                    else if (c[i] == "e" || c[i] == "E"), i + 1 < c.count, isDigit(c[i + 1]) || c[i + 1] == "-" || c[i + 1] == "+" {
                        isDouble = true; s += "e"; i += 1; s.unicodeScalars.append(c[i])
                    } else { break }
                    i += 1
                }
                if isDouble { guard let d = Double(s) else { throw err("invalid number") }; add(.double(d), start) }
                else { guard let v = Int(s) else { throw err("invalid number") }; add(.int(v), start) }
                continue
            }
            if u == "\"" {
                i += 1
                var parts: [StrPart] = [], cur = ""
                while true {
                    guard i < c.count, c[i] != "\n" else { throw err("unterminated string") }
                    let ch = c[i]
                    if ch == "\"" { i += 1; break }
                    if ch == "\\" {
                        i += 1
                        guard i < c.count else { throw err("unterminated string") }
                        switch c[i] {
                        case "n": cur += "\n"
                        case "t": cur += "\t"
                        case "\\": cur += "\\"
                        case "\"": cur += "\""
                        case "0": cur += "\0"
                        case "(":
                            var depth = 1, j = i + 1
                            while j < c.count, depth > 0 { if c[j] == "(" { depth += 1 } else if c[j] == ")" { depth -= 1 }; j += 1 }
                            guard depth == 0 else { throw err("unterminated interpolation") }
                            var inner = ""; for k in (i + 1)..<(j - 1) { inner.unicodeScalars.append(c[k]) }
                            if !cur.isEmpty { parts.append(.text(cur)); cur = "" }
                            parts.append(.interp(try lex(inner, file: file, lineOffset: line - 1)))
                            i = j - 1
                        default: throw err("unknown escape \\\(c[i])")
                        }
                        i += 1; continue
                    }
                    cur.unicodeScalars.append(ch); i += 1
                }
                if !cur.isEmpty || parts.isEmpty { parts.append(.text(cur)) }
                add(.string(parts), start); continue
            }
            func take(_ list: [String], _ n: Int) -> String? {
                guard i + n <= c.count else { return nil }
                let s = String(String.UnicodeScalarView(c[i..<(i + n)]))
                return list.contains(s) ? s : nil
            }
            if let o = take(ops3, 3) ?? take(ops2, 2) { i += o.count; add(.op(o), start); continue }
            if "(){}[],.;:@\\".unicodeScalars.contains(u) { i += 1; add(.punct(String(u)), start); continue }
            if "+-*/%=<>!&|^~?".unicodeScalars.contains(u) { i += 1; add(.op(String(u)), start); continue }
            throw err("unexpected character '\(u)'")
        }
        out.append(Token(tok: .eof, line: line, col: i - lineStart + 1, newlineBefore: true, spaceBefore: true))
        return out
    }
}
