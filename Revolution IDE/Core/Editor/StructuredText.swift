import Foundation

/// JSON and XML helpers for the code editor: validate, reformat and outline. JSON is scanned by
/// hand rather than through `JSONSerialization` so formatting and the outline keep key order.
nonisolated enum StructuredText {
    struct Node: Identifiable {
        let id = UUID()
        let label: String
        let value: String
        var children: [Node]?
    }

    static func supports(_ language: CodeLanguage) -> Bool { language == .json || language == .xml }

    /// Nil when the text parses; otherwise the parser's message (with its line, where it gives one).
    static func validate(_ text: String, _ language: CodeLanguage) -> String? {
        switch language {
        case .json:
            do { _ = try JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed); return nil }
            catch { return (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription }
        case .xml:
            do { _ = try XMLDocument(xmlString: text, options: []); return nil }
            catch { return (error as NSError).localizedDescription }
        default: return nil
        }
    }

    /// Re-indented text (`indent` per level), or nil if it doesn't parse.
    static func pretty(_ text: String, _ language: CodeLanguage, indent: String = "  ") -> String? {
        guard validate(text, language) == nil else { return nil }
        switch language {
        case .json: return reflowJSON(text, indent: indent)
        case .xml: return (try? XMLDocument(xmlString: text, options: [.nodePreserveCDATA]))?.xmlString(options: [.nodePrettyPrint, .nodePreserveCDATA])
        default: return nil
        }
    }

    static func minify(_ text: String, _ language: CodeLanguage) -> String? {
        guard validate(text, language) == nil else { return nil }
        switch language {
        case .json: return reflowJSON(text, indent: nil)
        case .xml: return (try? XMLDocument(xmlString: text, options: [.nodePreserveCDATA]))?.xmlString(options: [.nodeCompactEmptyElement, .nodePreserveCDATA])
        default: return nil
        }
    }

    /// Whitespace outside strings dropped, then (unless `indent` is nil) one value per line.
    private static func reflowJSON(_ text: String, indent: String?) -> String {
        var out = "", depth = 0, inString = false, escaped = false
        let chars = Array(text)
        func newline() { if let indent { out += "\n" + String(repeating: indent, count: depth) } }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            defer { i += 1 }
            if inString {
                out.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"": inString = true; out.append(c)
            case "{", "[":
                out.append(c)
                // Keep empty containers on one line.
                var j = i + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == (c == "{" ? "}" : "]") { out.append(chars[j]); i = j; break }
                depth += 1; newline()
            case "}", "]": depth -= 1; newline(); out.append(c)
            case ",": out.append(c); newline()
            case ":": out.append(indent == nil ? ":" : ": ")
            default: if !c.isWhitespace { out.append(c) }
            }
        }
        return out
    }

    // MARK: Outline

    static func outline(_ text: String, _ language: CodeLanguage) -> [Node] {
        switch language {
        case .json:
            var p = JSONOutline(chars: Array(text.utf8))
            p.skip()
            guard let root = p.value(label: "root") else { return [] }
            return root.children ?? [root]
        case .xml:
            guard let root = (try? XMLDocument(xmlString: text, options: []))?.rootElement() else { return [] }
            return [xmlNode(root)]
        default: return []
        }
    }

    private static func xmlNode(_ e: XMLElement) -> Node {
        let attributes = (e.attributes ?? []).map { "\($0.name ?? "")=\"\($0.stringValue ?? "")\"" }.joined(separator: " ")
        let elements = (e.children ?? []).compactMap { $0 as? XMLElement }
        let text = elements.isEmpty ? (e.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return Node(label: e.name ?? "?", value: [attributes, text].filter { !$0.isEmpty }.joined(separator: "  "),
                    children: elements.isEmpty ? nil : elements.map(xmlNode))
    }

    /// Just enough of a JSON reader to build the outline in source order.
    private struct JSONOutline {
        let chars: [UInt8]
        var i = 0

        mutating func skip() { while i < chars.count, [0x20, 0x09, 0x0A, 0x0D].contains(chars[i]) { i += 1 } }

        mutating func string() -> String? {
            guard i < chars.count, chars[i] == UInt8(ascii: "\"") else { return nil }
            let start = i
            i += 1
            while i < chars.count, chars[i] != UInt8(ascii: "\"") { if chars[i] == UInt8(ascii: "\\") { i += 1 }; i += 1 }
            i += 1
            let raw = String(decoding: chars[start..<min(i, chars.count)], as: UTF8.self)
            return (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed)) as? String ?? raw
        }

        mutating func value(label: String) -> Node? {
            skip()
            guard i < chars.count else { return nil }
            switch chars[i] {
            case UInt8(ascii: "{"):
                i += 1
                var kids: [Node] = []
                while true {
                    skip()
                    if i >= chars.count { return nil }
                    if chars[i] == UInt8(ascii: "}") { i += 1; break }
                    guard let key = string() else { return nil }
                    skip()
                    guard i < chars.count, chars[i] == UInt8(ascii: ":") else { return nil }
                    i += 1
                    guard let v = value(label: key) else { return nil }
                    kids.append(v)
                    skip()
                    if i < chars.count, chars[i] == UInt8(ascii: ",") { i += 1 }
                }
                return Node(label: label, value: "{\(kids.count)}", children: kids)
            case UInt8(ascii: "["):
                i += 1
                var kids: [Node] = []
                while true {
                    skip()
                    if i >= chars.count { return nil }
                    if chars[i] == UInt8(ascii: "]") { i += 1; break }
                    guard let v = value(label: "[\(kids.count)]") else { return nil }
                    kids.append(v)
                    skip()
                    if i < chars.count, chars[i] == UInt8(ascii: ",") { i += 1 }
                }
                return Node(label: label, value: "[\(kids.count)]", children: kids)
            case UInt8(ascii: "\""):
                return string().map { Node(label: label, value: "\"\($0)\"", children: nil) }
            default:
                let start = i
                while i < chars.count, ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x09, 0x0A, 0x0D].contains(chars[i]) { i += 1 }
                return Node(label: label, value: String(decoding: chars[start..<i], as: UTF8.self), children: nil)
            }
        }
    }
}
