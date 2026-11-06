import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The WYSIWYG designer for `.wiiui`: a 640x480 Wii screen. Drag widgets to move, drag the corner
/// handle to resize, arrow keys nudge, Delete removes. Layers (draw order) and properties are on
/// the sides; the screen is turned into C when the project is built.
struct UIDesignerView: View {
    @ObservedObject var box: UIDesignBox
    @State private var dragOrigin: CGPoint?
    @State private var resizeOrigin: CGSize?

    private var W: CGFloat { CGFloat(box.doc.screenWidth) }
    private let H = CGFloat(UIDocument.height)

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HSplitView {
                sidebar.frame(minWidth: 170, idealWidth: 190, maxWidth: 260)
                canvas.frame(minWidth: 360)
                inspector.frame(minWidth: 230, idealWidth: 260, maxWidth: 340)
            }
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(UIWidget.Kind.allCases) { kind in
                    Button { add(kind) } label: { Label(kind.title, systemImage: kind.icon) }
                }
            } label: { Label("Add Widget", systemImage: "plus") }
                .fixedSize()
            Button { box.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!box.canUndo).help("Undo")
            Button { box.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!box.canRedo).help("Redo")
            Divider().frame(height: 16)
            ColorPicker("Background", selection: colorBinding(get: { box.doc.background }, set: { c in box.edit(key: "bg") { $0.background = c } }))
                .fixedSize()
            Toggle("16:9", isOn: Binding(get: { box.doc.widescreen }, set: { v in box.edit(key: "wide") { $0.widescreen = v } }))
                .toggleStyle(.checkbox).help("Design for a widescreen 854 × 480 screen instead of 4:3 (640 × 480). On a 4:3 TV it is letterboxed.")
            Spacer()
            let problems = box.doc.problems()
            if !problems.isEmpty {
                Label(problems[0], systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            } else {
                Text("\(box.doc.screenWidth) × 480 · built into C on Build").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
    }

    // MARK: Layers

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Layers").font(.headline).padding([.top, .horizontal], 10).padding(.bottom, 6)
            List(selection: $box.selection) {
                // Top of the list = drawn last = on top.
                ForEach(Array(box.doc.widgets.reversed())) { w in
                    Label(w.name, systemImage: w.kind.icon)
                        .opacity(w.visible ? 1 : 0.5)
                        .tag(w.name)
                        .contextMenu { widgetMenu(w) }
                }
            }
            .listStyle(.sidebar)
            if let s = box.selection {
                HStack {
                    Button { box.move(s, by: 1) } label: { Image(systemName: "arrow.up") }.help("Bring forward")
                    Button { box.move(s, by: -1) } label: { Image(systemName: "arrow.down") }.help("Send backward")
                    Spacer()
                    Button(role: .destructive) { box.deleteSelected() } label: { Image(systemName: "trash") }.help("Delete")
                }
                .padding(8)
            }
        }
    }

    // MARK: Canvas

    private var canvas: some View {
        GeometryReader { geo in
            let scale = max(0.2, min((geo.size.width - 32) / W, (geo.size.height - 32) / H))
            ZStack(alignment: .topLeading) {
                Rectangle().fill(color(box.doc.background))
                    .frame(width: W, height: H)
                    .contentShape(Rectangle())
                    .onTapGesture { box.selection = nil }
                ForEach(box.doc.widgets) { w in
                    widgetView(w)
                        .frame(width: w.width, height: w.height, alignment: .topLeading)
                        .offset(x: w.x, y: w.y)
                        .opacity(w.visible ? 1 : 0.35)
                        .gesture(moveGesture(w))
                        .contextMenu { widgetMenu(w) }
                }
                if let s = box.selection, let w = box.doc.widgets.first(where: { $0.name == s }) {
                    Rectangle().stroke(Color.accentColor, lineWidth: 2 / scale)
                        .frame(width: w.width, height: w.height)
                        .offset(x: w.x, y: w.y)
                        .allowsHitTesting(false)
                    Rectangle().fill(Color.accentColor)
                        .frame(width: 14 / scale, height: 14 / scale)
                        .offset(x: w.x + w.width - 7 / scale, y: w.y + w.height - 7 / scale)
                        .gesture(resizeGesture(w))
                }
            }
            .frame(width: W, height: H, alignment: .topLeading)
            .coordinateSpace(name: "design")
            .clipped()
            .overlay(Rectangle().stroke(Color.secondary.opacity(0.6), lineWidth: 1 / scale))
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: W * scale, height: H * scale, alignment: .topLeading)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            .focusable()
            .onDeleteCommand { box.deleteSelected() }
            .onMoveCommand { dir in nudge(dir) }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    @ViewBuilder private func widgetMenu(_ w: UIWidget) -> some View {
        let i = box.index(of: w.name) ?? 0, last = box.doc.widgets.count - 1
        Button("Duplicate") { box.duplicate(w.name) }
        Button(w.visible ? "Hide at Start" : "Show at Start") { box.update(w.name) { $0.visible.toggle() } }
        Menu("Arrange") {
            Button("Bring to Front") { box.moveToEdge(w.name, front: true) }.disabled(i == last)
            Button("Bring Forward") { box.move(w.name, by: 1) }.disabled(i == last)
            Button("Send Backward") { box.move(w.name, by: -1) }.disabled(i == 0)
            Button("Send to Back") { box.moveToEdge(w.name, front: false) }.disabled(i == 0)
        }
        if w.kind == .image { Button("Choose Image...") { chooseImage(for: w.name) } }
        Divider()
        Button("Delete", role: .destructive) { box.delete(w.name) }
    }

    private func moveGesture(_ w: UIWidget) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("design"))
            .onChanged { v in
                if box.selection != w.name { box.selection = w.name }
                if dragOrigin == nil { dragOrigin = CGPoint(x: w.x, y: w.y) }
                guard let o = dragOrigin, abs(v.translation.width) + abs(v.translation.height) > 1 else { return }
                box.update(w.name, key: "move") { $0.x = (o.x + v.translation.width).rounded(); $0.y = (o.y + v.translation.height).rounded() }
            }
            .onEnded { _ in dragOrigin = nil }
    }

    private func resizeGesture(_ w: UIWidget) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("design"))
            .onChanged { v in
                if resizeOrigin == nil { resizeOrigin = CGSize(width: w.width, height: w.height) }
                guard let o = resizeOrigin else { return }
                var nw = o.width + v.translation.width, nh = o.height + v.translation.height
                if Controls.shared.held(.designerKeepAspect), o.width > 0, o.height > 0 {   // keep the aspect ratio
                    let k = max(nw / o.width, nh / o.height, 8 / min(o.width, o.height))
                    nw = o.width * k; nh = o.height * k
                }
                box.update(w.name, key: "resize") {
                    $0.width = max(8, nw.rounded())
                    $0.height = max(8, nh.rounded())
                }
            }
            .onEnded { _ in resizeOrigin = nil }
    }

    private func nudge(_ dir: MoveCommandDirection) {
        guard let s = box.selection else { return }
        let d: (Double, Double)
        switch dir {
        case .left: d = (-1, 0)
        case .right: d = (1, 0)
        case .up: d = (0, -1)
        case .down: d = (0, 1)
        @unknown default: return
        }
        box.update(s, key: "nudge") { $0.x += d.0; $0.y += d.1 }
    }

    /// Mirrors what `wiiui.c` draws: flat rects, left-aligned labels, buttons with a lighter edge.
    @ViewBuilder private func widgetView(_ w: UIWidget) -> some View {
        switch w.kind {
        case .rectangle:
            Rectangle().fill(color(w.fill))
        case .label:
            Text(w.text).font(.custom("Helvetica", size: CGFloat(w.fontSize)))
                .foregroundStyle(color(w.textColor)).lineLimit(1).fixedSize()
                .frame(width: w.width, height: w.height, alignment: .leading)
        case .button:
            ZStack {
                Rectangle().fill(color(lighter(w.fill, 0.24)))
                Rectangle().fill(color(w.fill)).padding(2)
                Text(w.text).font(.custom("Helvetica", size: CGFloat(w.fontSize)))
                    .foregroundStyle(color(w.textColor)).lineLimit(1).fixedSize()
            }
        case .image:
            if let root = box.projectRoot, !w.imagePath.isEmpty,
               let img = NSImage(contentsOf: root.appendingPathComponent(w.imagePath)) {
                Image(nsImage: img).resizable().frame(width: w.width, height: w.height)
            } else {
                ZStack { Rectangle().fill(color(w.fill)); Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary) }
            }
        }
    }

    // MARK: Inspector

    @ViewBuilder private var inspector: some View {
        if let name = box.selection, let w = box.doc.widgets.first(where: { $0.name == name }) {
            Form {
                Section("Widget") {
                    TextField("Name", text: Binding(get: { w.name }, set: { box.rename(name, to: $0) }))
                    LabeledContent("Type", value: w.kind.title)
                    Toggle("Visible at start", isOn: field(w, \.visible))
                }
                Section("Position & size (Y counts up from the bottom)") {
                    HStack { number("X", field(w, \.x)); number("Y", fromBottom(w)) }
                    HStack { number("W", field(w, \.width)); number("H", field(w, \.height)) }
                }
                if w.kind == .label || w.kind == .button {
                    Section("Text") {
                        TextField("Text", text: field(w, \.text))
                        Stepper("Size \(w.fontSize)", value: field(w, \.fontSize), in: 8...96)
                        ColorPicker("Text colour", selection: colorField(w, \.textColor))
                    }
                }
                if w.kind != .label {
                    Section("Fill") { ColorPicker(w.kind == .image ? "Behind transparency" : "Colour", selection: colorField(w, \.fill)) }
                }
                if w.kind == .image {
                    Section("Image") {
                        Text(w.imagePath.isEmpty ? "None chosen" : w.imagePath).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Button("Choose Image...") { chooseImage(for: name) }
                        Text("Scaled to the widget's size when you build. Big images make big C files; keep them small.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("In your code") {
                    Text("UI_\(w.name.uppercased())").font(.system(.caption, design: .monospaced))
                    if w.kind == .button { Text("Handle it with the On Button Pressed node, or app_on_button(UI_\(w.name.uppercased())).").font(.caption).foregroundStyle(.secondary) }
                }
            }
            .formStyle(.grouped)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "cursorarrow.click").font(.largeTitle).foregroundStyle(.tertiary)
                Text("Select a widget to edit it, or add one from Add Widget.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Y as the node editor sees it: the widget's bottom edge, counted up from the bottom of the screen.
    private func fromBottom(_ w: UIWidget) -> Binding<Double> {
        let name = w.name
        return Binding(get: { box.doc.widgets.first { $0.name == name }.map { H - $0.y - $0.height } ?? 0 },
                       set: { v in box.update(name, key: "y") { $0.y = H - v - $0.height } })
    }

    private func number(_ label: String, _ b: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary).frame(width: 14)
            TextField("", value: b, format: .number.precision(.fractionLength(0))).labelsHidden().textFieldStyle(.roundedBorder)
        }
    }

    // MARK: Helpers

    private func add(_ kind: UIWidget.Kind) {
        if kind == .image {
            box.add(.image)
            if let s = box.selection { chooseImage(for: s) }
        } else {
            box.add(kind)
        }
    }

    /// Images live in the project; one from elsewhere is copied into `assets/` first.
    private func chooseImage(for name: String) {
        PanelPresenter.openFile(configure: { $0.allowedContentTypes = [.image] }) { url in
            guard let url, let root = box.projectRoot else { return }
            var rel = url.path
            if rel.hasPrefix(root.path + "/") {
                rel = String(rel.dropFirst(root.path.count + 1))
            } else {
                let assets = root.appendingPathComponent("assets", isDirectory: true)
                try? FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
                let dest = assets.appendingPathComponent(url.lastPathComponent)
                if !FileManager.default.fileExists(atPath: dest.path) { try? FileManager.default.copyItem(at: url, to: dest) }
                rel = "assets/" + url.lastPathComponent
            }
            box.update(name) { $0.imagePath = rel }
        }
    }

    private func field<T>(_ w: UIWidget, _ kp: WritableKeyPath<UIWidget, T>) -> Binding<T> {
        let name = w.name
        return Binding(get: { box.doc.widgets.first { $0.name == name }?[keyPath: kp] ?? w[keyPath: kp] },
                       set: { v in box.update(name, key: "\(kp)") { $0[keyPath: kp] = v } })
    }

    private func colorField(_ w: UIWidget, _ kp: WritableKeyPath<UIWidget, RGB>) -> Binding<Color> {
        let b = field(w, kp)
        return colorBinding(get: { b.wrappedValue }, set: { b.wrappedValue = $0 })
    }

    private func colorBinding(get: @escaping () -> RGB, set: @escaping (RGB) -> Void) -> Binding<Color> {
        Binding(get: { color(get()) }, set: { c in
            if let n = NSColor(c).usingColorSpace(.sRGB) { set(RGB(r: Double(n.redComponent), g: Double(n.greenComponent), b: Double(n.blueComponent))) }
        })
    }

    private func color(_ c: RGB) -> Color { Color(.sRGB, red: c.r, green: c.g, blue: c.b) }
    private func lighter(_ c: RGB, _ d: Double) -> RGB { RGB(r: min(1, c.r + d), g: min(1, c.g + d), b: min(1, c.b + d)) }
}
