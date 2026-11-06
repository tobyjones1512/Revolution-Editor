import Foundation

/// A programming/markup language this app can syntax-highlight. Detection is by file extension
/// first (the common case), falling back to sniffing a `#!` shebang line for extensionless
/// scripts.
nonisolated enum CodeLanguage: String, CaseIterable {
    case swift, c, cpp, objc, python, javascript, typescript, json, html, css, markdown, shell, yaml, xml, rust, go, java, ruby, php, sql, plainText

    var displayName: String {
        switch self {
        case .swift: return "Swift"
        case .c: return "C"
        case .cpp: return "C++"
        case .objc: return "Objective-C"
        case .python: return "Python"
        case .javascript: return "JavaScript"
        case .typescript: return "TypeScript"
        case .json: return "JSON"
        case .html: return "HTML"
        case .css: return "CSS"
        case .markdown: return "Markdown"
        case .shell: return "Shell"
        case .yaml: return "YAML"
        case .xml: return "XML"
        case .rust: return "Rust"
        case .go: return "Go"
        case .java: return "Java"
        case .ruby: return "Ruby"
        case .php: return "PHP"
        case .sql: return "SQL"
        case .plainText: return "Plain Text"
        }
    }

    static func detect(fileName: String, contents: String) -> CodeLanguage {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if let byExt = byExtension[ext] { return byExt }
        // No/unknown extension: sniff a shebang line for scripts.
        if contents.hasPrefix("#!") {
            let firstLine = contents.prefix(while: { !$0.isNewline }).lowercased()
            if firstLine.contains("python") { return .python }
            if firstLine.contains("node") { return .javascript }
            if firstLine.contains("ruby") { return .ruby }
            if firstLine.contains("sh") { return .shell } // bash/zsh/sh
        }
        return .plainText
    }

    private static let byExtension: [String: CodeLanguage] = [
        "swift": .swift,
        "c": .c, "h": .c,
        "cpp": .cpp, "cc": .cpp, "cxx": .cpp, "hpp": .cpp, "hxx": .cpp,
        "m": .objc, "mm": .objc,
        "py": .python, "pyw": .python,
        "js": .javascript, "mjs": .javascript, "cjs": .javascript, "jsx": .javascript,
        "ts": .typescript, "tsx": .typescript,
        "json": .json,
        "html": .html, "htm": .html,
        "css": .css,
        "md": .markdown, "markdown": .markdown,
        "sh": .shell, "bash": .shell, "zsh": .shell,
        "yaml": .yaml, "yml": .yaml,
        "xml": .xml, "plist": .xml, "svg": .xml,
        "rs": .rust,
        "go": .go,
        "java": .java, "kt": .java, "kts": .java,
        "rb": .ruby,
        "php": .php,
        "sql": .sql,
        "txt": .plainText, "log": .plainText,
    ]

    /// Every extension this app treats as source/text (and therefore opens in the code editor
    /// rather than the raw hex-dump fallback), regardless of which specific language it maps to.
    static var allRecognizedExtensions: Set<String> { Set(byExtension.keys) }
}
