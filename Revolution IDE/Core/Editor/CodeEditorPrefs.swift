import Combine
import SwiftUI
import AppKit

/// The syntax colour roles a theme sets.
nonisolated enum CodeRole: String, CaseIterable, Identifiable {
	case keyword, type, string, comment, number, tag, attribute, function, constant, preprocessor, escape, member, plain
	var id: String { rawValue }
	var title: String {
		switch self {
		case .preprocessor: return "Preprocessor"
		case .plain: return "Plain text"
		default: return rawValue.capitalized
		}
	}
}

/// Resolved editor colours: a preset, then the user's own overrides on top. The syntax highlighter reads these.
nonisolated enum CodeTheme {
	static let presetNames = ["System", "Midnight", "Daylight", "Solarized Dark", "Monokai"]

	/// Hex colours per preset ("System" has none and uses the macOS semantic colours).
	private static let presets: [String: [String: String]] = [
		"Midnight": ["background": "#14161F", "plain": "#D6DAE8", "keyword": "#FF7AB2", "type": "#5DD8FF", "string": "#FF8170", "comment": "#7F8C98", "number": "#D9C97C", "tag": "#4EB0CC", "attribute": "#FFA14F", "function": "#78C2B3", "constant": "#B281EB", "preprocessor": "#FFA14F", "escape": "#D9C97C", "member": "#A0A8B8"],
		"Daylight": ["background": "#FFFFFF", "plain": "#1F2328", "keyword": "#CF222E", "type": "#0550AE", "string": "#0A3069", "comment": "#6E7781", "number": "#0550AE", "tag": "#116329", "attribute": "#953800", "function": "#8250DF", "constant": "#0550AE", "preprocessor": "#953800", "escape": "#116329", "member": "#57606A"],
		"Solarized Dark": ["background": "#002B36", "plain": "#93A1A1", "keyword": "#859900", "type": "#B58900", "string": "#2AA198", "comment": "#586E75", "number": "#D33682", "tag": "#268BD2", "attribute": "#CB4B16", "function": "#268BD2", "constant": "#6C71C4", "preprocessor": "#CB4B16", "escape": "#DC322F", "member": "#839496"],
		"Monokai": ["background": "#272822", "plain": "#F8F8F2", "keyword": "#F92672", "type": "#66D9EF", "string": "#E6DB74", "comment": "#75715E", "number": "#AE81FF", "tag": "#F92672", "attribute": "#A6E22E", "function": "#A6E22E", "constant": "#AE81FF", "preprocessor": "#F92672", "escape": "#AE81FF", "member": "#C0C0B0"],
	]

	private static let systemColors: [CodeRole: NSColor] = [
		.keyword: .systemPink, .type: .systemTeal, .string: .systemRed, .comment: .systemGreen, .number: .systemPurple,
		.tag: .systemBlue, .attribute: .systemOrange, .plain: .labelColor, .function: .systemBlue, .constant: .systemMint,
		.preprocessor: .systemOrange, .escape: .systemYellow, .member: .secondaryLabelColor,
	]

	nonisolated(unsafe) private static var cache: [CodeRole: NSColor] = [:]
	nonisolated(unsafe) private static var cachedBackground: NSColor?
	nonisolated(unsafe) private static var loaded = false

	static let overridesKey = "codeEditor.colorOverrides"
	static let themeKey = "codeEditor.theme"

	static func reload() { loaded = false }

	private static func load() {
		let d = UserDefaults.standard
		let preset = presets[d.string(forKey: themeKey) ?? "System"] ?? [:]
		let overrides = d.dictionary(forKey: overridesKey) as? [String: String] ?? [:]
		func hex(_ key: String) -> NSColor? { (overrides[key] ?? preset[key]).flatMap(NSColor.init(hexString:)) }
		cache = Dictionary(uniqueKeysWithValues: CodeRole.allCases.map { ($0, hex($0.rawValue) ?? systemColors[$0]!) })
		cachedBackground = hex("background")
		loaded = true
	}

	static func color(_ role: CodeRole) -> NSColor { if !loaded { load() }; return cache[role] ?? .labelColor }
	/// nil = the system text background.
	static var background: NSColor? { if !loaded { load() }; return cachedBackground }
	static var backgroundOrSystem: NSColor { background ?? .textBackgroundColor }
	/// The gutter and minimap shade: the background nudged toward the text colour.
	static var gutter: NSColor { backgroundOrSystem.blended(withFraction: 0.06, of: color(.plain)) ?? .controlBackgroundColor }
}

extension NSColor {
	nonisolated convenience init?(hexString: String) {
		var s = hexString.trimmingCharacters(in: .whitespaces)
		if s.hasPrefix("#") { s.removeFirst() }
		guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
		self.init(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
	}
	nonisolated var hexString: String {
		let c = usingColorSpace(.sRGB) ?? self
		return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
	}
}

/// Every code editor setting, saved to UserDefaults as it changes. Fonts, colours, spacing and features.
@MainActor final class CodeEditorPrefs: ObservableObject {
	static let shared = CodeEditorPrefs()
	private let d = UserDefaults.standard

	// Font and spacing
	@Published var fontName: String { didSet { d.set(fontName, forKey: "codeEditorFontName") } }
	@Published var fontSize: Double { didSet { d.set(fontSize, forKey: "codeEditorFontSize") } }
	@Published var lineSpacing: Double { didSet { d.set(lineSpacing, forKey: "codeEditorLineSpacing") } }
	@Published var tabWidth: Int { didSet { d.set(tabWidth, forKey: "codeEditorTabWidth") } }
	@Published var insertSpaces: Bool { didSet { d.set(insertSpaces, forKey: "codeEditorInsertSpaces") } }
	@Published var wordWrap: Bool { didSet { d.set(wordWrap, forKey: "codeEditorWordWrap") } }
	// Features
	@Published var showLineNumbers: Bool { didSet { d.set(showLineNumbers, forKey: "codeEditorShowLineNumbers") } }
	@Published var highlightCurrentLine: Bool { didSet { d.set(highlightCurrentLine, forKey: "codeEditorHighlightLine") } }
	@Published var matchBrackets: Bool { didSet { d.set(matchBrackets, forKey: "codeEditorMatchBrackets") } }
	@Published var autoIndent: Bool { didSet { d.set(autoIndent, forKey: "codeEditorAutoIndent") } }
	@Published var autoClosePairs: Bool { didSet { d.set(autoClosePairs, forKey: "codeEditorAutoClose") } }
	@Published var autoComplete: Bool { didSet { d.set(autoComplete, forKey: "codeEditorAutoComplete") } }
	@Published var codeFolding: Bool { didSet { d.set(codeFolding, forKey: "codeEditorFolding") } }
	@Published var showMinimap: Bool { didSet { d.set(showMinimap, forKey: "codeEditorMinimap") } }
	@Published var showStatusBar: Bool { didSet { d.set(showStatusBar, forKey: "codeEditorStatusBar") } }
	// Colours
	@Published var theme: String { didSet { d.set(theme, forKey: CodeTheme.themeKey); CodeTheme.reload() } }
	@Published private(set) var overrides: [String: String] { didSet { d.set(overrides, forKey: CodeTheme.overridesKey); CodeTheme.reload() } }

	private init() {
		func bool(_ k: String, _ def: Bool) -> Bool { UserDefaults.standard.object(forKey: k) as? Bool ?? def }
		func num(_ k: String, _ def: Double) -> Double { UserDefaults.standard.object(forKey: k) as? Double ?? def }
		fontName = d.string(forKey: "codeEditorFontName") ?? "Menlo-Regular"
		fontSize = num("codeEditorFontSize", 13)
		lineSpacing = num("codeEditorLineSpacing", 0)
		tabWidth = d.object(forKey: "codeEditorTabWidth") as? Int ?? 4
		insertSpaces = bool("codeEditorInsertSpaces", false)
		wordWrap = bool("codeEditorWordWrap", true)
		showLineNumbers = bool("codeEditorShowLineNumbers", true)
		highlightCurrentLine = bool("codeEditorHighlightLine", true)
		matchBrackets = bool("codeEditorMatchBrackets", true)
		autoIndent = bool("codeEditorAutoIndent", true)
		autoClosePairs = bool("codeEditorAutoClose", true)
		autoComplete = bool("codeEditorAutoComplete", true)
		codeFolding = bool("codeEditorFolding", true)
		showMinimap = bool("codeEditorMinimap", true)
		showStatusBar = bool("codeEditorStatusBar", true)
		theme = d.string(forKey: CodeTheme.themeKey) ?? "System"
		overrides = d.dictionary(forKey: CodeTheme.overridesKey) as? [String: String] ?? [:]
	}

	var font: NSFont {
		(fontName.isEmpty ? nil : NSFont(name: fontName, size: fontSize)) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
	}
	var indentUnit: String { insertSpaces ? String(repeating: " ", count: tabWidth) : "\t" }

	/// Installed fixed-width fonts, for the font picker.
	static let monospacedFonts: [String] = (NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []).sorted()

	func color(_ role: CodeRole) -> Color { Color(nsColor: CodeTheme.color(role)) }
	func setColor(_ role: CodeRole, _ color: Color) { overrides[role.rawValue] = NSColor(color).hexString }
	var backgroundColor: Color { Color(nsColor: CodeTheme.backgroundOrSystem) }
	func setBackground(_ color: Color) { overrides["background"] = NSColor(color).hexString }
	func resetColors() { overrides = [:] }
}
