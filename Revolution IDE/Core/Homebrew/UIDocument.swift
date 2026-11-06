import Foundation

/// The WYSIWYG designer's file (`.wiiui`): one 640x480 screen of widgets, stored as JSON. Turned
/// into C by `UICodegen` whenever a homebrew project is built.
nonisolated struct RGB: Codable, Equatable {
    var r: Double, g: Double, b: Double   // 0...1

    static let white = RGB(r: 1, g: 1, b: 1)
    static let black = RGB(r: 0, g: 0, b: 0)

    var bytes: [UInt8] { [r, g, b].map { UInt8(max(0, min(255, ($0 * 255).rounded()))) } }
}

nonisolated struct UIWidget: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case rectangle, label, button, image
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var icon: String {
            switch self {
            case .rectangle: return "rectangle"
            case .label: return "textformat"
            case .button: return "capsule"
            case .image: return "photo"
            }
        }
    }

    /// Also the C identifier: the widget is `UI_<NAME>` in generated code.
    var name: String
    var kind: Kind
    var x: Double, y: Double, width: Double, height: Double
    var text: String
    var fontSize: Int
    /// Fill for rectangles and buttons (and the backdrop of an image's transparent parts).
    var fill: RGB
    var textColor: RGB
    /// Relative to the project folder.
    var imagePath: String
    var visible: Bool

    var id: String { name }

    static func make(_ kind: Kind, name: String, x: Double = 40, y: Double = 40) -> UIWidget {
        switch kind {
        case .rectangle:
            return UIWidget(name: name, kind: kind, x: x, y: y, width: 160, height: 100, text: "", fontSize: 24,
                            fill: RGB(r: 0.2, g: 0.45, b: 0.8), textColor: .white, imagePath: "", visible: true)
        case .label:
            return UIWidget(name: name, kind: kind, x: x, y: y, width: 240, height: 36, text: "Label", fontSize: 28,
                            fill: .black, textColor: .white, imagePath: "", visible: true)
        case .button:
            return UIWidget(name: name, kind: kind, x: x, y: y, width: 200, height: 56, text: "Button", fontSize: 28,
                            fill: RGB(r: 0.15, g: 0.55, b: 0.35), textColor: .white, imagePath: "", visible: true)
        case .image:
            return UIWidget(name: name, kind: kind, x: x, y: y, width: 128, height: 128, text: "", fontSize: 24,
                            fill: RGB(r: 0.3, g: 0.3, b: 0.3), textColor: .white, imagePath: "", visible: true)
        }
    }
}

nonisolated struct UIDocument: Codable, Equatable {
    static let width = 640
    static let height = 480

    var background: RGB
    var widgets: [UIWidget]
    /// 16:9 (854x480) instead of 4:3 (640x480). Missing in older files, which are 4:3.
    var widescreen = false

    var screenWidth: Int { widescreen ? 854 : Self.width }

    static func sample() -> UIDocument {
        var title = UIWidget.make(.label, name: "title", x: 40, y: 40)
        title.text = "Hello, Wii!"; title.fontSize = 48; title.width = 400; title.height = 60
        var status = UIWidget.make(.label, name: "status", x: 40, y: 140)
        status.text = "Point and press A"; status.width = 400
        var button = UIWidget.make(.button, name: "go", x: 40, y: 220)
        button.text = "Press me"
        return UIDocument(background: RGB(r: 0.07, g: 0.08, b: 0.12), widgets: [title, status, button])
    }

    /// A C identifier from anything typed into the name field.
    static func identifier(_ s: String) -> String {
        var out = String(s.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") ? $0 : "_" })
        if out.isEmpty { out = "widget" }
        if out.first!.isNumber { out = "_" + out }
        return out
    }

    func uniqueName(_ base: String) -> String {
        let names = Set(widgets.map(\.name))
        let root = UIDocument.identifier(base)
        if !names.contains(root) { return root }
        var i = 2
        while names.contains("\(root)\(i)") { i += 1 }
        return "\(root)\(i)"
    }

    func problems() -> [String] {
        var seen = Set<String>(), out: [String] = []
        for w in widgets {
            if w.name != UIDocument.identifier(w.name) { out.append("Widget \"\(w.name)\" isn't a valid name (letters, digits and _ only).") }
            if !seen.insert(w.name).inserted { out.append("Two widgets are named \"\(w.name)\".") }
            if w.kind == .image, w.imagePath.isEmpty { out.append("Image \"\(w.name)\" has no image chosen.") }
        }
        return out
    }

    static func parse(_ data: Data) throws -> UIDocument {
        try JSONDecoder().decode(UIDocument.self, from: data)
    }

    func serialize() -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? enc.encode(self)) ?? Data()
    }
}

nonisolated extension UIDocument {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        background = try c.decode(RGB.self, forKey: .background)
        widgets = try c.decode([UIWidget].self, forKey: .widgets)
        widescreen = try c.decodeIfPresent(Bool.self, forKey: .widescreen) ?? false
    }
}
