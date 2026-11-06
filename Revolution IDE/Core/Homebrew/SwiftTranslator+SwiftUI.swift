import Foundation

/// Value types the SwiftUI layer needs (`Color`, `Font`), written in Swift and translated with the
/// app like any other code.
nonisolated enum SwiftPrelude {
    static let swiftUI = """
    enum Weight { case ultraLight, thin, light, regular, medium, semibold, bold, heavy, black }

    struct Color {
        var r: Int
        var g: Int
        var b: Int
        var a: Int
        init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
            r = Int(red * 255)
            g = Int(green * 255)
            b = Int(blue * 255)
            a = Int(opacity * 255)
        }
        func opacity(_ o: Double) -> Color { Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: o) }
        static let red = Color(red: 1.0, green: 0.23, blue: 0.19)
        static let orange = Color(red: 1.0, green: 0.58, blue: 0.0)
        static let yellow = Color(red: 1.0, green: 0.8, blue: 0.0)
        static let green = Color(red: 0.2, green: 0.78, blue: 0.35)
        static let mint = Color(red: 0.0, green: 0.78, blue: 0.75)
        static let teal = Color(red: 0.19, green: 0.69, blue: 0.78)
        static let cyan = Color(red: 0.2, green: 0.68, blue: 0.9)
        static let blue = Color(red: 0.0, green: 0.48, blue: 1.0)
        static let indigo = Color(red: 0.35, green: 0.34, blue: 0.84)
        static let purple = Color(red: 0.69, green: 0.32, blue: 0.87)
        static let pink = Color(red: 1.0, green: 0.18, blue: 0.33)
        static let brown = Color(red: 0.64, green: 0.52, blue: 0.37)
        static let gray = Color(red: 0.56, green: 0.56, blue: 0.58)
        static let black = Color(red: 0.0, green: 0.0, blue: 0.0)
        static let white = Color(red: 1.0, green: 1.0, blue: 1.0)
        static let clear = Color(red: 0.0, green: 0.0, blue: 0.0, opacity: 0.0)
        static let primary = Color(red: 1.0, green: 1.0, blue: 1.0)
        static let secondary = Color(red: 0.7, green: 0.7, blue: 0.75)
        static let accentColor = Color(red: 0.0, green: 0.48, blue: 1.0)
    }

    struct Font {
        var size: Int
        var bold: Bool
        func bold() -> Font { Font(size: size, bold: true) }
        static let largeTitle = Font(size: 48, bold: false)
        static let title = Font(size: 40, bold: false)
        static let title2 = Font(size: 32, bold: false)
        static let title3 = Font(size: 28, bold: false)
        static let headline = Font(size: 24, bold: true)
        static let body = Font(size: 24, bold: false)
        static let callout = Font(size: 20, bold: false)
        static let subheadline = Font(size: 20, bold: false)
        static let footnote = Font(size: 16, bold: false)
        static let caption = Font(size: 16, bold: false)
        static let caption2 = Font(size: 16, bold: false)
        static func system(size: Int, weight: Weight = .regular) -> Font { Font(size: size, bold: weight == .bold || weight == .heavy || weight == .black || weight == .semibold) }
    }
    """
}

nonisolated extension SwiftTranslator {
    static let viewConstructors: Set<String> = ["Text", "Image", "Button", "VStack", "HStack", "ZStack", "Spacer", "Divider", "Rectangle", "RoundedRectangle",
                                                "Circle", "Capsule", "Toggle", "Slider", "ProgressView", "Group", "ForEach", "EmptyView"]
    static let unsupportedViews: [String: String] = [
        "List": "List isn't supported yet; use a VStack with ForEach", "ScrollView": "ScrollView isn't supported yet; use a VStack",
        "NavigationStack": "navigation isn't supported; switch screens with an @State value", "NavigationView": "navigation isn't supported; switch screens with an @State value",
        "NavigationLink": "navigation isn't supported; switch screens with an @State value", "TabView": "TabView isn't supported; switch screens with an @State value",
        "TextField": "text entry isn't supported (the Wii has no keyboard)", "Picker": "Picker isn't supported; use buttons", "Form": "Form isn't supported; use a VStack",
        "Section": "Section isn't supported; use a VStack", "LazyVStack": "use VStack", "LazyHStack": "use HStack", "Label": "Label isn't supported; use an HStack with Image and Text",
        "GeometryReader": "GeometryReader isn't supported (the screen is always 640 x 480)", "Stepper": "Stepper isn't supported; use buttons", "Menu": "Menu isn't supported; use buttons",
        "Canvas": "Canvas isn't supported", "Path": "Path isn't supported", "AsyncImage": "AsyncImage isn't supported",
    ]
    static let ignoredModifiers: Set<String> = [
        // Layout and look that this renderer doesn't have
        "ignoresSafeArea", "safeAreaInset", "safeAreaPadding", "clipped", "contentShape", "allowsHitTesting", "fixedSize", "layoutPriority", "zIndex",
        "mask", "blendMode", "blur", "brightness", "contrast", "saturation", "grayscale", "hueRotation", "colorMultiply", "colorInvert", "luminanceToAlpha",
        "rotationEffect", "rotation3DEffect", "scaleEffect", "projectionEffect", "transformEffect", "compositingGroup", "drawingGroup", "redacted", "unredacted",
        "tint", "accentColor", "preferredColorScheme", "colorScheme", "symbolRenderingMode", "symbolVariant", "imageScale", "interpolation", "antialiased",
        // Text styling beyond size
        "bold", "italic", "strikethrough", "kerning", "tracking", "lineSpacing", "textCase", "monospacedDigit", "monospaced", "minimumScaleFactor",
        "truncationMode", "multilineTextAlignment", "allowsTightening", "baselineOffset", "fontWeight", "fontDesign", "fontWidth", "textSelection", "dynamicTypeSize",
        // Animation
        "animation", "transition", "matchedGeometryEffect", "transaction", "phaseAnimator", "keyframeAnimator", "contentTransition", "symbolEffect",
        // Accessibility
        "accessibilityLabel", "accessibilityHint", "accessibilityValue", "accessibilityIdentifier", "accessibilityHidden", "accessibilityElement", "accessibilityAddTraits",
        "accessibilityRemoveTraits", "accessibilityAction", "accessibilityInputLabels", "accessibilityFocused", "accessibilitySortPriority",
        // Controls, input and focus (no keyboard, mouse or touch on a Wii)
        "keyboardType", "textContentType", "textInputAutocapitalization", "autocorrectionDisabled", "submitLabel", "onSubmit", "focused", "focusable", "focusedValue",
        "hoverEffect", "onHover", "help", "buttonBorderShape", "controlSize", "labelsHidden", "labelStyle", "toggleStyle", "textFieldStyle", "pickerStyle", "menuStyle",
        "datePickerStyle", "gaugeStyle", "progressViewStyle", "tabViewStyle", "indexViewStyle", "menuIndicator", "keyboardShortcut", "onKeyPress", "onCommand",
        "onExitCommand", "onPlayPauseCommand", "onMoveCommand", "onDrag", "onDrop", "draggable", "dropDestination", "onCopyCommand", "onPasteCommand", "onDeleteCommand",
        // Lists, scrolling and refreshing
        "listStyle", "listRowSeparator", "listRowBackground", "listRowInsets", "listSectionSeparator", "listItemTint", "scrollContentBackground", "scrollIndicators",
        "scrollDisabled", "scrollBounceBehavior", "scrollTargetBehavior", "scrollPosition", "defaultScrollAnchor", "refreshable", "searchable", "headerProminence",
        // Navigation, bars and presentation (nothing to present on a TV)
        "navigationTitle", "navigationBarTitleDisplayMode", "navigationBarHidden", "navigationBarBackButtonHidden", "navigationSubtitle", "navigationDestination",
        "toolbar", "toolbarBackground", "toolbarColorScheme", "toolbarRole", "toolbarVisibility", "statusBar", "statusBarHidden", "tabItem", "badge",
        "sheet", "alert", "popover", "fullScreenCover", "contextMenu", "swipeActions", "confirmationDialog", "presentationDetents", "presentationDragIndicator",
        "interactiveDismissDisabled", "gesture", "highPriorityGesture", "simultaneousGesture", "onOpenURL", "onContinueUserActivity", "sensoryFeedback",
        // Data and lifecycle hooks with nothing to observe here
        "environment", "environmentObject", "preference", "onPreferenceChange", "tag", "id", "equatable", "foregroundStyleDefault", "padding(.all)",
        "onDisappear", "onReceive", "onSubmit", "defersSystemGestures", "persistentSystemOverlays",
        // Platform exclusive
        "digitalCrownRotation", "containerBackground", "menuBarExtraStyle", "formStyle", "windowResizability", "windowStyle", "defaultSize", "frame(minWidth:)",
    ]

    // MARK: Roots and view-returning code

    /// The root view of the app: `@main struct X: App { WindowGroup { RootView() } }`, else `ContentView`.
    func findRootView() throws -> (type: TypeInfo, initExpr: Expr)? {
        guard usesView else { return nil }
        if let app = types.values.first(where: { $0.isApp }) {
            curFile = app.decl.file; curLine = app.decl.line; curCol = 1
            guard let body = app.decl.props.first(where: { $0.name == "body" })?.getter, body.count == 1, case .expr(let e) = body[0].kind,
                  case .call(let callee, let args) = e.kind, case .ident("WindowGroup") = callee.kind, let content = args.last, case .closure(let c) = content.value.kind,
                  c.body.count == 1, case .expr(let root) = c.body[0].kind else {
                throw fail("an App's body should be `WindowGroup { YourView() }`")
            }
            guard case .call(let rc, _) = root.kind, case .ident(let tn) = rc.kind, let ti = types[tn], ti.isView else { throw fail("WindowGroup should show one of your views, like ContentView()") }
            return (ti, root)
        }
        if let ti = types["ContentView"], ti.isView {
            let e = Expr(kind: .call(Expr(kind: .ident("ContentView"), line: ti.decl.line, col: 1), []), line: ti.decl.line, col: 1)
            return (ti, e)
        }
        throw fail("no root view found: add `@main struct MyApp: App { var body: some Scene { WindowGroup { ContentView() } } }`")
    }

    // MARK: View expressions

    func viewBlock(_ stmts: [Stmt], indent n: Int) throws -> String {
        let saved = ctx.viewMode
        ctx.viewMode = true
        defer { ctx.viewMode = saved }
        return try block(stmts, indent: n)
    }

    /// The statements that add the view `e` to the tree.
    func viewExpr(_ e: Expr, indent n: Int) throws -> String {
        at(e)
        let p = ind(n)
        switch e.kind {
        case .call(let callee, let args):
            if case .ident(let name) = callee.kind {
                if let why = Self.unsupportedViews[name] { throw fail(why) }
                if Self.viewConstructors.contains(name), lookupLocal(name) == nil, types[name] == nil { return try viewConstructor(name, args, e, indent: n) }
                if let ti = types[name], ti.isView { return try childView(ti, args, e, indent: n) }
            }
            if case .member(let base, let mod, _) = callee.kind, !isStaticTypeExpr(base) {
                return try viewModifier(base, mod, args, e, indent: n)
            }
        default: break
        }
        // Anything else: a Color, a helper that returns a view, ...
        let (c, t) = try expr(e, nil)
        switch t {
        case .view: return "\(p)\(c);\n"
        case .named("Color"):
            let k = newTmp("k")
            return "\(p){ T_Color \(k) = \(c); wui_color(\(k).r, \(k).g, \(k).b, \(k).a); }\n"
        default: throw fail("this is a \(t.name), not a view")
        }
    }

    func isStaticTypeExpr(_ b: Expr) -> Bool {
        if let tn = staticTypeName(b) { return types[tn] != nil || tn == "UI" || tn == "Sprite" || tn == "Sound" || tn == "Music" }
        return false
    }

    func trailingClosure(_ args: [Arg]) -> (Closure, [Arg])? {
        guard let last = args.last, last.label == nil, case .closure(let c) = last.value.kind else { return nil }
        return (c, Array(args.dropLast()))
    }

    func viewContent(_ c: Closure, indent n: Int) throws -> String {
        guard c.params.isEmpty || c.hasSignature == false else { throw fail("this closure shouldn't take parameters") }
        ctx.scopes.append([:])
        defer { ctx.scopes.removeLast() }
        return try viewBlock(c.body, indent: n)
    }

    /// Alignment names → a 3x3 code (v * 3 + h) for the runtime.
    func alignmentCode(_ e: Expr?, default def: Int = 4) throws -> Int {
        guard let e else { return def }
        var name = ""
        switch e.kind {
        case .implicitMember(let n): name = n
        case .member(_, let n, _): name = n
        default: throw fail("use an alignment like .leading or .center")
        }
        var h = 1, v = 1
        switch name {
        case "leading": h = 0
        case "trailing": h = 2
        case "center": break
        case "top": v = 0
        case "bottom": v = 2
        case "topLeading": v = 0; h = 0
        case "topTrailing": v = 0; h = 2
        case "bottomLeading": v = 2; h = 0
        case "bottomTrailing": v = 2; h = 2
        case "firstTextBaseline": v = 0
        case "lastTextBaseline": v = 2
        default: throw fail("unknown alignment '.\(name)'")
        }
        return v * 3 + h
    }

    func number(_ e: Expr) throws -> String { "(float)(\(try coerce(e, to: .double)))" }

    func viewConstructor(_ name: String, _ args: [Arg], _ whole: Expr, indent n: Int) throws -> String {
        let p = ind(n)
        switch name {
        case "Text":
            guard let a = args.first, a.label == nil || a.label == "verbatim" else { throw fail("Text needs a string, like Text(\"Hello\")") }
            let (c, t) = try expr(a.value, .string)
            return "\(p)wui_text((\(try stringify(c, t))).s);\n"
        case "Image":
            guard let a = args.first else { throw fail("Image needs a picture from your assets folder, like Image(\"ball\")") }
            if a.label == "systemName" { throw fail("system symbols aren't available; use a picture from your assets folder") }
            if case .string(let parts) = a.value.kind, parts.count == 1, let name = parts[0].text {
                guard sprites.contains(name) else { throw fail("the project has no picture named '\(name)' in its assets folder" + (sprites.isEmpty ? "" : "; available: " + sprites.sorted().joined(separator: ", "))) }
                return "\(p)wui_image(SPRITE_\(name.uppercased()));\n"
            }
            return "\(p)wui_image(\(try coerce(a.value, to: .int)));\n"
        case "Spacer": return "\(p)wui_spacer();\n"
        case "Divider": return "\(p)wui_divider();\n"
        case "EmptyView": return ""
        case "Rectangle": return "\(p)wui_shape(0, 0);\n"
        case "RoundedRectangle":
            guard let a = args.first(where: { $0.label == "cornerRadius" }) else { throw fail("use RoundedRectangle(cornerRadius: 12)") }
            return "\(p)wui_shape(1, \(try number(a.value)));\n"
        case "Circle": return "\(p)wui_shape(2, 0);\n"
        case "Capsule": return "\(p)wui_shape(3, 0);\n"
        case "VStack", "HStack", "ZStack":
            guard let (content, rest) = trailingClosure(args) else { throw fail("\(name) needs content: \(name) { ... }") }
            var align = name == "ZStack" ? 4 : 4, spacing = "8.0f"
            for a in rest {
                switch a.label {
                case "alignment": align = try alignmentCode(a.value)
                case "spacing": spacing = try number(a.value)
                default: throw fail("\(name) takes alignment: and spacing:")
                }
            }
            let axis = name == "VStack" ? 0 : (name == "HStack" ? 1 : 2)
            if name == "ZStack" { spacing = "0.0f" }
            return "\(p)wui_begin_stack(\(axis), \(align), \(spacing));\n\(try viewContent(content, indent: n))\(p)wui_end();\n"
        case "Group":
            guard let (content, _) = trailingClosure(args) else { throw fail("Group needs content") }
            return try viewContent(content, indent: n)
        case "ForEach": return try forEachView(args, indent: n)
        case "Button": return try buttonView(args, indent: n)
        case "Toggle":
            guard let label = args.first, label.label == nil, let on = args.first(where: { $0.label == "isOn" }) else { throw fail("use Toggle(\"Label\", isOn: $flag)") }
            let (bc, bt) = try expr(on.value, .binding(.bool))
            guard bt == .binding(.bool) else { throw fail("isOn needs a Bool binding like $flag") }
            return "\(p)wui_toggle((\(try coerce(label.value, to: .string))).s, \(bc));\n"
        case "Slider":
            guard let v = args.first(where: { $0.label == "value" }) else { throw fail("use Slider(value: $v, in: 0...1)") }
            let (bc, bt) = try expr(v.value, .binding(.double))
            guard bt == .binding(.double) else { throw fail("value needs a Double binding like $volume") }
            var lo = "0.0", hi = "1.0"
            if let r = args.first(where: { $0.label == "in" }), case .range(let l, let h, _) = r.value.kind { lo = try coerce(l, to: .double); hi = try coerce(h, to: .double) }
            return "\(p)wui_slider(\(bc), \(lo), \(hi));\n"
        case "ProgressView":
            guard let v = args.first(where: { $0.label == "value" }) else { throw fail("use ProgressView(value: 0.5)") }
            return "\(p)wui_progress(\(try coerce(v.value, to: .double)));\n"
        default: throw fail("'\(name)' isn't supported")
        }
    }

    func buttonView(_ args: [Arg], indent n: Int) throws -> String {
        let p = ind(n)
        var rest = args
        var label: Closure?
        var action: Expr?
        var title: Expr?
        if let (c, r) = trailingClosure(rest) { rest = r; if rest.contains(where: { $0.label == "action" }) { label = c } else { action = Expr(kind: .closure(c), line: curLine, col: curCol) } }
        for a in rest {
            if a.label == "action" { action = a.value }
            else if a.label == nil, title == nil, !(isClosure(a.value)) { title = a.value }
            else if a.label == "label", case .closure(let c) = a.value.kind { label = c }
            else if a.label == nil, case .closure = a.value.kind { action = a.value }
            else if a.label == "role" { continue }
            else { throw fail("Button takes a title, an action and optional content") }
        }
        guard let action else { throw fail("a Button needs an action: Button(\"Go\") { ... }") }
        let f = newTmp("act")
        var out = "\(p){\n\(p)    \(try ctype(.fn([], .void))) \(f) = \(try functionValue(action, [], .void));\n\(p)    wui_begin_button(\(f).f, \(f).ctx);\n"
        if let l = label { out += try viewContent(l, indent: n + 1) }
        else if let t = title { let (c, ty) = try expr(t, .string); out += "\(p)    wui_text((\(try stringify(c, ty))).s);\n" }
        else { throw fail("a Button needs a title or content") }
        return out + "\(p)    wui_end();\n\(p)}\n"
    }

    func isClosure(_ e: Expr) -> Bool { if case .closure = e.kind { return true }; return false }

    func forEachView(_ args: [Arg], indent n: Int) throws -> String {
        guard let (content, rest) = trailingClosure(args), let data = rest.first(where: { $0.label == nil }) else { throw fail("use ForEach(items) { item in ... }") }
        var seq = data.value
        if case .call(let c, let a) = seq.kind, case .ident("Array") = c.kind, a.count == 1 { seq = a[0].value }
        let names: [String] = content.hasSignature ? content.params.map(\.name) : (0..<max(1, content.maxShorthand)).map { "$\($0)" }
        let pat: Pattern = names.count == 1 ? (names[0] == "_" ? .wildcard : .name(names[0])) : .tuple(names.map { $0 == "_" ? .wildcard : .name($0) })
        let saved = ctx.viewMode
        ctx.viewMode = true
        defer { ctx.viewMode = saved }
        return try forStmt(pat, seq, content.body, indent: n)
    }

    // MARK: Child views

    func childView(_ ti: TypeInfo, _ args: [Arg], _ whole: Expr, indent n: Int) throws -> String {
        let p = ind(n)
        let (initC, _) = try typeInit(ti, args, whole)
        let t = newTmp("v")
        let hasState = ti.storedProps.contains { $0.isState }
        if !hasState { return "\(p){ T_\(ti.name) \(t) = \(initC); T_\(ti.name)_get_body(&\(t)); }\n" }
        // A view with @State keeps one instance per place it appears, so its state survives frames.
        let inst = "\(t)_inst", flag = "\(t)_ready"
        var out = "\(p){\n\(p)    static T_\(ti.name) \(inst); static int \(flag);\n\(p)    T_\(ti.name) \(t) = \(initC);\n"
        out += "\(p)    if (!\(flag)) { \(inst) = \(t); \(flag) = 1; }\n"
        for prop in ti.storedProps where !prop.isState { out += "\(p)    \(inst).\(cname(prop.name)) = \(t).\(cname(prop.name));\n" }
        return out + "\(p)    T_\(ti.name)_get_body(&\(inst));\n\(p)}\n"
    }

    // MARK: Modifiers

    func colorCode(_ e: Expr) throws -> (decl: String, r: String) {
        let k = newTmp("k")
        return ("T_Color \(k) = \(try coerce(e, to: .named("Color")));", "\(k).r, \(k).g, \(k).b, \(k).a")
    }

    func viewModifier(_ base: Expr, _ name: String, _ args: [Arg], _ whole: Expr, indent n: Int) throws -> String {
        let p = ind(n)
        var out = try viewExpr(base, indent: n)
        at(whole)
        func arg(_ i: Int = 0) throws -> Expr { guard i < args.count else { throw fail("'\(name)' needs an argument") }; return args[i].value }
        switch name {
        case "padding":
            var edges = "all"
            var amount: String?
            for a in args {
                if case .implicitMember(let e) = a.value.kind { edges = e }
                else if case .member(_, let e, _) = a.value.kind, a.label == nil, ["all", "horizontal", "vertical", "top", "bottom", "leading", "trailing"].contains(e) { edges = e }
                else if a.label == nil || a.label == "length" { amount = try number(a.value) }
            }
            let v = amount ?? "16.0f"
            let top = ["all", "vertical", "top"].contains(edges) ? v : "0.0f", bottom = ["all", "vertical", "bottom"].contains(edges) ? v : "0.0f"
            let left = ["all", "horizontal", "leading"].contains(edges) ? v : "0.0f", right = ["all", "horizontal", "trailing"].contains(edges) ? v : "0.0f"
            guard ["all", "horizontal", "vertical", "top", "bottom", "leading", "trailing"].contains(edges) else { throw fail("unknown edge '.\(edges)'") }
            out += "\(p)wui_padding(\(top), \(right), \(bottom), \(left));\n"
        case "frame":
            var w = "-1.0f", h = "-1.0f", minw = "-1.0f", maxw = "-1.0f", minh = "-1.0f", maxh = "-1.0f", align = 4
            for a in args {
                switch a.label {
                case "width": w = try number(a.value)
                case "height": h = try number(a.value)
                case "minWidth": minw = try number(a.value)
                case "maxWidth": maxw = try number(a.value)
                case "minHeight": minh = try number(a.value)
                case "maxHeight": maxh = try number(a.value)
                case "idealWidth", "idealHeight": continue
                case "alignment": align = try alignmentCode(a.value)
                default: throw fail("frame takes width, height, minWidth, maxWidth, minHeight, maxHeight and alignment")
                }
            }
            out += "\(p)wui_frame(\(w), \(h), \(minw), \(maxw), \(minh), \(maxh), \(align));\n"
        case "background":
            let (d, r) = try colorCode(try arg())
            out += "\(p){ \(d) wui_background(\(r)); }\n"
        case "foregroundColor", "foregroundStyle", "fill":
            let (d, r) = try colorCode(try arg())
            out += "\(p){ \(d) wui_foreground(\(r)); }\n"
        case "font":
            let k = newTmp("f")
            out += "\(p){ T_Font \(k) = \(try coerce(try arg(), to: .named("Font"))); wui_font(\(k).size, \(k).bold); }\n"
        case "opacity": out += "\(p)wui_opacity(\(try number(try arg())));\n"
        case "offset":
            var x = "0.0f", y = "0.0f"
            for a in args { if a.label == "x" { x = try number(a.value) } else if a.label == "y" { y = try number(a.value) } }
            out += "\(p)wui_offset(\(x), \(y));\n"
        case "cornerRadius": out += "\(p)wui_corner(\(try number(try arg())));\n"
        case "border":
            let (d, r) = try colorCode(try arg())
            var width = "1.0f"
            if let w = args.first(where: { $0.label == "width" }) { width = try number(w.value) }
            out += "\(p){ \(d) wui_border(\(r), \(width)); }\n"
        case "onTapGesture":
            guard let (c, _) = trailingClosure(args) else { throw fail("onTapGesture needs a closure: .onTapGesture { ... }") }
            let f = newTmp("tap")
            out += "\(p){ \(try ctype(.fn([], .void))) \(f) = \(try functionValue(Expr(kind: .closure(c), line: whole.line, col: whole.col), [], .void)); wui_on_tap(\(f).f, \(f).ctx); }\n"
        case "onAppear":
            guard let (c, _) = trailingClosure(args) else { throw fail("onAppear needs a closure: .onAppear { ... }") }
            let once = newTmp("once")
            ctx.scopes.append([:])
            let saved = ctx.viewMode; ctx.viewMode = false
            let savedMutating = ctx.isMutating; ctx.isMutating = true      // these blocks run on the live view, so they may change its state
            let body = try block(c.body, indent: n + 1)
            ctx.viewMode = saved
            ctx.isMutating = savedMutating
            ctx.scopes.removeLast()
            out += "\(p){ static int \(once); if (!\(once)) { \(once) = 1;\n\(body)\(p)} }\n"
        case "disabled": out += "\(p)wui_disabled(\(try coerce(try arg(), to: .bool)));\n"
        case "resizable": out += "\(p)wui_resizable(0);\n"
        case "scaledToFit": out += "\(p)wui_resizable(1);\n"
        case "scaledToFill": out += "\(p)wui_resizable(0);\n"
        case "aspectRatio":
            var fit = 1
            if let m = args.first(where: { $0.label == "contentMode" }), case .implicitMember(let n) = m.value.kind { fit = n == "fit" ? 1 : 0 }
            out += "\(p)wui_resizable(\(fit));\n"
        case "lineLimit": out += "\(p)wui_line_limit(\(try coerce(try arg(), to: .int)));\n"
        case "buttonStyle":
            if case .implicitMember(let s) = try arg().kind, s == "plain" { out += "\(p)wui_button_plain();\n" }
        case "underline": out += "\(p)wui_underline();\n"
        case "overlay":
            // Only a colour can be drawn over a view here; other overlays are skipped.
            if let a = args.first(where: { $0.label == nil || $0.label == "content" }), let (d, r) = try? colorCode(a.value) {
                out += "\(p){ \(d) wui_overlay(\(r)); }\n"
            }
        case "position":
            var x = "0.0f", y = "0.0f"
            for a in args { if a.label == "x" { x = try number(a.value) } else if a.label == "y" { y = try number(a.value) } }
            out += "\(p)wui_position(\(x), \(y));\n"
        case "shadow":
            var color = "0, 0, 0, 90", dx = "0.0f", dy = "2.0f"
            var radius = "4.0f"
            for a in args {
                switch a.label {
                case "color": let (d, r) = try colorCode(a.value); out += "\(p){ \(d) wui_shadow(\(r), %DX%, %DY%); }\n"; color = ""
                case "radius": radius = try number(a.value)
                case "x": dx = try number(a.value)
                case "y": dy = try number(a.value)
                default: if a.label == nil { radius = try number(a.value) }
                }
            }
            _ = radius
            if color.isEmpty { out = out.replacingOccurrences(of: "%DX%", with: dx).replacingOccurrences(of: "%DY%", with: dy) }
            else { out += "\(p)wui_shadow(0, 0, 0, 90, \(dx), \(dy));\n" }
        case "clipShape":
            // Rounded shapes become rounded corners; other clips are skipped.
            if case .call(let shape, let sargs) = try arg().kind, case .ident(let sn) = shape.kind {
                if sn == "Circle" || sn == "Capsule" { out += "\(p)wui_corner(100000.0f);\n" }
                else if sn == "RoundedRectangle", let r = sargs.first(where: { $0.label == "cornerRadius" }) { out += "\(p)wui_corner(\(try number(r.value)));\n" }
            }
        case "onLongPressGesture":
            guard let closure = (trailingClosure(args)?.0) ?? args.compactMap({ a -> Closure? in if a.label == "perform", case .closure(let c) = a.value.kind { return c }; return nil }).first
            else { throw fail("onLongPressGesture needs a closure: .onLongPressGesture { ... }") }
            var seconds = "0.5f"
            if let d = args.first(where: { $0.label == "minimumDuration" }) { seconds = try number(d.value) }
            let f = newTmp("hold")
            out += "\(p){ \(try ctype(.fn([], .void))) \(f) = \(try functionValue(Expr(kind: .closure(closure), line: whole.line, col: whole.col), [], .void)); wui_long_press(\(f).f, \(f).ctx, (int)(\(seconds) * 60.0f)); }\n"
        case "task":
            guard let (c, _) = trailingClosure(args) else { throw fail("task needs a closure: .task { ... }") }
            let once = newTmp("once")
            ctx.scopes.append([:])
            let saved = ctx.viewMode; ctx.viewMode = false
            let savedMutating = ctx.isMutating; ctx.isMutating = true      // these blocks run on the live view, so they may change its state
            let body = try block(c.body, indent: n + 1)
            ctx.viewMode = saved
            ctx.isMutating = savedMutating
            ctx.scopes.removeLast()
            out += "\(p){ static int \(once); if (!\(once)) { \(once) = 1;\n\(body)\(p)} }\n"
        case "onChange":
            guard let (c, rest) = trailingClosure(args), let watched = rest.first(where: { $0.label == "of" }) ?? rest.first else {
                throw fail("onChange needs a value and a closure: .onChange(of: value) { ... }")
            }
            let (vc, vt) = try expr(watched.value, nil)
            let key = newTmp("chg"), cur = newTmp("cur")
            let ct = try ctype(vt)
            ctx.scopes.append([:])
            let saved = ctx.viewMode; ctx.viewMode = false
            let savedMutating = ctx.isMutating; ctx.isMutating = true      // these blocks run on the live view, so they may change its state
            let names = c.params.map(\.name)
            if names.count == 1 { ctx.scopes[ctx.scopes.count - 1][names[0]] = Local(type: vt, c: cur, isLet: true) }
            else if names.count >= 2 {
                ctx.scopes[ctx.scopes.count - 1][names[0]] = Local(type: vt, c: "\(key)_prev", isLet: true)
                ctx.scopes[ctx.scopes.count - 1][names[1]] = Local(type: vt, c: cur, isLet: true)
            }
            let body = try block(c.body, indent: n + 2)
            ctx.viewMode = saved
            ctx.isMutating = savedMutating
            ctx.scopes.removeLast()
            let same = try equalityCode("\(key)_prev", cur, vt)
            out += "\(p){ static int \(key)_seen; static \(ct) \(key)_prev; \(ct) \(cur) = \(vc);\n"
            out += "\(p)  if (\(key)_seen && !(\(same))) {\n\(body)\(p)  }\n\(p)  \(key)_prev = \(cur); \(key)_seen = 1; }\n"
        default:
            if Self.ignoredModifiers.contains(name) { break }
            throw fail("the modifier '.\(name)' isn't supported")
        }
        return out
    }
}
