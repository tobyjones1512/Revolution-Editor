import SwiftUI
import AppKit

/// The node-based coding editor for `.wiinodes`. Drag from a port to another port of the same
/// colour to wire them: white wires are the order things run in (top to bottom), coloured wires
/// carry numbers (blue), text (green) and boolean values (orange) and vectors (purple). The graph is turned into C when
/// the project is built.
///
/// Left-drag the background to box-select nodes, drag a title to move the selected ones, middle-drag
/// to pan, scroll wheel to zoom (trackpad scroll pans), and use the scroll bars to navigate.
struct NodeEditorView: View {
    @ObservedObject var box: NodeGraphBox
    @State private var pan = CGSize(width: 20, height: 20)
    @State private var dragOrigins: [String: CGPoint]?
    @State private var marquee: CGRect?
    @State private var marqueeBase: Set<String>?
    @State private var boxDrag: (origin: CGPoint, nodes: [String: CGPoint])?
    @State private var boxResize: CGSize?
    @State private var showAnalyze = false
    @State private var showHistory = false
    @AppStorage("nodeEditorShowVariables") private var showVariables = true
    @State private var wire: Wire?
    @State private var zoom: CGFloat = 1
    @State private var zoomStart: CGFloat?
    @State private var canvasSize = CGSize(width: 800, height: 600)

    private struct Wire {
        var node: String, port: String, type: PortType, fromOutput: Bool
        var to: CGPoint
    }

    private enum L {
        static let width: CGFloat = 220, header: CGFloat = 26, paramRow: CGFloat = 30, portRow: CGFloat = 28, pad: CGFloat = 8
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HStack(spacing: 0) {
                graphCanvas.frame(minWidth: 400)
                    .overlay(alignment: .bottomLeading) { zoomControls }
                if showVariables {
                    Divider()
                    variablesPanel.frame(width: 270)
                }
            }
        }
        .onAppear { box.reloadWidgetNames() }
        .sheet(isPresented: $showAnalyze) { AnalyzeSheet(box: box) }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(NodeKind.Category.allCases, id: \.self) { cat in
                    Menu(cat.rawValue) {
                        ForEach(NodeKind.allCases.filter { $0.category == cat }) { kind in
                            Button(kind.title) { box.addNode(kind, x: (60 - Double(pan.width)) / Double(zoom) + Double.random(in: 0...60), y: (60 - Double(pan.height)) / Double(zoom) + Double.random(in: 0...60)) }
                        }
                    }
                }
            } label: { Label("Add Node", systemImage: "plus") }
                .fixedSize()
            Group {
                Button { box.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!box.canUndo).help("Undo")
                    .shortcut(.undo)
                Button { box.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!box.canRedo).help("Redo")
                    .shortcut(.redo)
                Button("Redo") { box.redo() }.disabled(!box.canRedo).shortcut(.redoAlternate)
                    .frame(width: 1, height: 1).opacity(0.01)
                Button { showHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }.help("History")
                    .popover(isPresented: $showHistory) { historyList }
            }
            Divider().frame(height: 16)
            Group {
                Button { box.cleanUp(); fitAll() } label: { Label("Cleanup", systemImage: "wand.and.stars") }
                    .help("Cleanup: tidy the nodes into neat columns, one block per event").disabled(box.graph.nodes.isEmpty)
                Button {
                    let cx = (canvasSize.width / 2 - pan.width) / zoom, cy = (canvasSize.height / 2 - pan.height) / zoom
                    box.addBox(x: Double(cx) - 210, y: Double(cy) - 130)
                } label: { Label("Add Box", systemImage: "rectangle.dashed") }
                    .help("Add Box: a labelled box to group nodes. Dragging its title bar moves the nodes inside it too.")
                Button { showAnalyze = true } label: { Label("Analyze", systemImage: "checkmark.seal") }
                    .help("Analyse: look for ways to tidy and speed up this graph")
            }
            .labelStyle(.iconOnly)
            Menu {
                Picker("Origin", selection: Binding(get: { box.graph.yUp }, set: { v in box.edit(key: "yup") { $0.yUp = v } })) {
                    Text("0, 0 at bottom left").tag(true)
                    Text("0, 0 at top left").tag(false)
                }
                Picker("Type", selection: Binding(get: { box.isActor }, set: { v in box.edit(key: "actor") { $0.actorSprite = v ? ($0.actorSprite ?? "") : nil } })) {
                    Text("Program logic").tag(false)
                    Text("Sprite actor").tag(true)
                }
                if !box.isActor {
                    Picker("Frame rate", selection: Binding(get: { box.graph.fps ?? 60 }, set: { v in box.edit(key: "fps") { $0.fps = v == 60 ? nil : v } })) {
                        ForEach([60, 30, 20, 15, 10], id: \.self) { Text("\($0) frames per second").tag($0) }
                    }
                }
                if box.isActor {
                    Picker("Sprite", selection: Binding(get: { box.graph.actorSprite ?? "" }, set: { v in box.edit(key: "actorsprite") { $0.actorSprite = v } })) {
                        Text("None (invisible)").tag("")
                        ForEach(box.spriteNames, id: \.self) { Text($0).tag($0) }
                    }
                }
            } label: { Label("Graph", systemImage: "slider.horizontal.3") }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Graph settings: frame rate, where 0, 0 is on the screen, and whether this file is the program's logic or a sprite actor")
            if box.isActor {
                Text("Sprite: " + ((box.graph.actorSprite ?? "").isEmpty ? "none" : box.graph.actorSprite!))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !box.selection.isEmpty {
                Button(role: .destructive) { box.deleteSelected() } label: { Label(box.selection.count > 1 ? "Delete \(box.selection.count)" : "Delete", systemImage: "trash") }
            }
            Button { showVariables.toggle() } label: { Image(systemName: "sidebar.right") }
                .help(showVariables ? "Hide the variables panel" : "Show the variables panel")
        }
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    /// Every recorded state, oldest first; click one to jump straight to it.
    private var historyList: some View {
        let past = box.undoCount, future = box.redoCount
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0...(past + future), id: \.self) { i in
                    let isNow = i == past
                    HStack {
                        Image(systemName: isNow ? "arrow.right.circle.fill" : "circle").foregroundStyle(isNow ? Color.accentColor : Color.secondary)
                        Text(i == 0 ? "Opened" : "Edit \(i)")
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(isNow ? Color.accentColor.opacity(0.15) : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { box.step(past - i); showHistory = false }
                }
            }
        }
        .frame(width: 200, height: min(320, CGFloat(past + future + 1) * 26 + 8))
    }

    /// Zoom controls floating over the canvas corner.
    private var zoomControls: some View {
        HStack(spacing: 2) {
            Button { zoomBy(1 / 1.25) } label: { Image(systemName: "minus") }.help("Zoom out").shortcut(.zoomOut)
            Text("\(Int((zoom * 100).rounded()))%").font(.caption.monospacedDigit()).frame(width: 38)
            Button { zoomBy(1.25) } label: { Image(systemName: "plus") }.help("Zoom in").shortcut(.zoomIn)
            Divider().frame(height: 12)
            Button { fitAll() } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                .help("Fit all nodes on screen").disabled(box.graph.nodes.isEmpty)
        }
        .buttonStyle(.borderless).controlSize(.small)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .padding(.leading, 12).padding(.bottom, 24)
    }

    // MARK: Geometry (fixed, so wires and ports line up without measuring views)

    private func rows(_ k: NodeKind) -> Int { max(k.inputs.count, k.outputs.count) }
    private func height(_ n: GraphNode) -> CGFloat { L.header + CGFloat(n.kind.params.count) * L.paramRow + CGFloat(rows(n.kind)) * L.portRow + L.pad }
    private func rowY(_ n: GraphNode, _ row: Int) -> CGFloat {
        CGFloat(n.y) + L.header + CGFloat(n.kind.params.count) * L.paramRow + CGFloat(row) * L.portRow + L.portRow / 2
    }
    private func inputPoint(_ n: GraphNode, _ i: Int) -> CGPoint { CGPoint(x: CGFloat(n.x), y: rowY(n, i)) }
    private func outputPoint(_ n: GraphNode, _ i: Int) -> CGPoint { CGPoint(x: CGFloat(n.x) + L.width, y: rowY(n, i)) }

    private func screenRect(_ n: GraphNode) -> CGRect {
        let o = at(CGPoint(x: n.x, y: n.y))
        return CGRect(x: o.x, y: o.y, width: L.width * zoom, height: height(n) * zoom)
    }

    private func tint(_ t: PortType) -> Color {
        switch t {
        case .exec: return .primary
        case .number: return .blue
        case .text: return .green
        case .bool: return .orange
        case .vector: return .purple
        case .colour: return .pink
        case .bounds: return .indigo
        }
    }

    private func at(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * zoom + pan.width, y: p.y * zoom + pan.height) }

    // MARK: Zoom

    /// Zooms about the middle of the canvas.
    private func setZoom(_ new: CGFloat, about c: CGPoint? = nil) {
        let z = min(2.5, max(0.1, new))
        let c = c ?? CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let k = z / zoom
        pan = CGSize(width: c.x - (c.x - pan.width) * k, height: c.y - (c.y - pan.height) * k)
        zoom = z
    }

    private func zoomBy(_ factor: CGFloat) { setZoom(zoom * factor) }

    private func fitAll() {
        let nodes = box.graph.nodes
        guard !nodes.isEmpty else { return }
        let minX = nodes.map { CGFloat($0.x) }.min()!, minY = nodes.map { CGFloat($0.y) }.min()!
        let maxX = nodes.map { CGFloat($0.x) + L.width }.max()!, maxY = nodes.map { CGFloat($0.y) + height($0) }.max()!
        let margin: CGFloat = 40
        let z = min(1.5, max(0.1, min((canvasSize.width - 2 * margin) / (maxX - minX), (canvasSize.height - 2 * margin) / (maxY - minY))))
        zoom = z
        pan = CGSize(width: (canvasSize.width - (maxX - minX) * z) / 2 - minX * z, height: (canvasSize.height - (maxY - minY) * z) / 2 - minY * z)
    }

    // MARK: Canvas

    private var graphCanvas: some View {
        let g = box.graph
        return GeometryReader { geo in ZStack(alignment: .topLeading) {
            Rectangle().fill(Color(nsColor: .underPageBackgroundColor))
                .contentShape(Rectangle())
                .onTapGesture { box.selection = [] }
                .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("graph")).onChanged { v in
                    if marqueeBase == nil { marqueeBase = Controls.shared.held(.nodeExtendSelection) ? box.selection : [] }
                    let r = CGRect(x: min(v.startLocation.x, v.location.x), y: min(v.startLocation.y, v.location.y),
                                   width: abs(v.location.x - v.startLocation.x), height: abs(v.location.y - v.startLocation.y))
                    marquee = r
                    box.selection = (marqueeBase ?? []).union(box.graph.nodes.filter { screenRect($0).intersects(r) }.map(\.id))
                }.onEnded { _ in marquee = nil; marqueeBase = nil })
                .gesture(MagnifyGesture().onChanged { v in
                    if zoomStart == nil { zoomStart = zoom }
                    if let z = zoomStart { setZoom(z * v.magnification, about: v.startLocation) }
                }.onEnded { _ in zoomStart = nil })

            ForEach(g.boxes) { b in boxView(b) }

            Canvas { ctx, _ in
                for e in g.edges {
                    guard let a = g.node(e.fromNode), let b = g.node(e.toNode),
                          let oi = a.kind.outputs.firstIndex(where: { $0.name == e.fromPort }),
                          let ii = b.kind.inputs.firstIndex(where: { $0.name == e.toPort }) else { continue }
                    stroke(&ctx, at(outputPoint(a, oi)), at(inputPoint(b, ii)), tint(a.kind.outputs[oi].type))
                }
                if let w = wire, let n = g.node(w.node) {
                    let specs = w.fromOutput ? n.kind.outputs : n.kind.inputs
                    if let i = specs.firstIndex(where: { $0.name == w.port }) {
                        let p = at(w.fromOutput ? outputPoint(n, i) : inputPoint(n, i))
                        if w.fromOutput { stroke(&ctx, p, w.to, tint(w.type)) } else { stroke(&ctx, w.to, p, tint(w.type)) }
                    }
                }
            }
            .allowsHitTesting(false)

            ForEach(g.nodes) { n in
                card(n)
                    .frame(width: L.width, height: height(n), alignment: .topLeading)
                    .scaleEffect(zoom, anchor: .topLeading)
                    .offset(x: CGFloat(n.x) * zoom + pan.width, y: CGFloat(n.y) * zoom + pan.height)
            }
            ForEach(g.nodes) { n in
                ForEach(Array(n.kind.inputs.enumerated()), id: \.offset) { i, spec in portDot(n, spec, index: i, output: false) }
                ForEach(Array(n.kind.outputs.enumerated()), id: \.offset) { i, spec in portDot(n, spec, index: i, output: true) }
            }
            if let m = marquee {
                Rectangle().fill(Color.accentColor.opacity(0.12))
                    .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1))
                    .frame(width: m.width, height: m.height)
                    .offset(x: m.minX, y: m.minY)
                    .allowsHitTesting(false)
            }
            MouseCatcher(
                onPan: { d in pan = CGSize(width: pan.width + d.width, height: pan.height + d.height) },
                onWheel: { dy, p in setZoom(zoom * pow(1.1, dy), about: p) },
                onTrackpad: { d in pan = CGSize(width: pan.width + d.width, height: pan.height + d.height) })
            scrollBars
        }
        .coordinateSpace(name: "graph")
        .clipped()
        .focusable()
        .onDeleteCommand { box.deleteSelected() }
        .onAppear { canvasSize = geo.size }
        .onChange(of: geo.size) { _, new in canvasSize = new }
        }
    }

    // MARK: Boxes

    private func boxColour(_ name: String) -> Color {
        switch name {
        case "green": return .green
        case "orange": return .orange
        case "purple": return .purple
        case "red": return .red
        case "gray": return .gray
        default: return .blue
        }
    }

    private func boxView(_ b: GraphBox) -> some View {
        let c = boxColour(b.colour)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(c.opacity(0.10)).overlay(Rectangle().stroke(c.opacity(0.7), lineWidth: 1.5)).allowsHitTesting(false)
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                TextField("Group", text: Binding(get: { b.title }, set: { v in box.updateBox(b.id, key: "title") { $0.title = v } }))
                    .textFieldStyle(.plain).font(.system(size: 13, weight: .semibold)).frame(maxWidth: 220)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).frame(height: 28).frame(maxWidth: .infinity, alignment: .leading)
            .background(c.opacity(0.28))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("graph")).onChanged { v in
                let newDrag = boxDrag == nil
                if newDrag {
                    let inside = box.graph.nodes.filter { n in
                        let cx = n.x + Self.nodeW / 2, cy = n.y + Double(height(n)) / 2
                        return cx >= b.x && cx <= b.x + b.width && cy >= b.y && cy <= b.y + b.height
                    }
                    boxDrag = (CGPoint(x: b.x, y: b.y), Dictionary(uniqueKeysWithValues: inside.map { ($0.id, CGPoint(x: $0.x, y: $0.y)) }))
                }
                if let d = boxDrag {
                    box.moveBox(b.id, nodes: d.nodes, origin: d.origin, by: CGSize(width: v.translation.width / zoom, height: v.translation.height / zoom), newDrag: newDrag)
                }
            }.onEnded { _ in boxDrag = nil })
            Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10)).foregroundStyle(c)
                .frame(width: 18, height: 18).background(c.opacity(0.2))
                .contentShape(Rectangle())
                .offset(x: b.width - 18, y: b.height - 18)
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("graph")).onChanged { v in
                    if boxResize == nil { boxResize = CGSize(width: b.width, height: b.height) }
                    guard let o = boxResize else { return }
                    box.updateBox(b.id, key: "resize") {
                        $0.width = max(140, Double(o.width + v.translation.width / zoom))
                        $0.height = max(90, Double(o.height + v.translation.height / zoom))
                    }
                }.onEnded { _ in boxResize = nil })
        }
        .frame(width: CGFloat(b.width), height: CGFloat(b.height), alignment: .topLeading)
        .scaleEffect(zoom, anchor: .topLeading)
        .offset(x: CGFloat(b.x) * zoom + pan.width, y: CGFloat(b.y) * zoom + pan.height)
        .contextMenu {
            Menu("Colour") { ForEach(GraphBox.palette, id: \.self) { name in Button(name.capitalized) { box.updateBox(b.id) { $0.colour = name } } } }
            Button("Delete Box", role: .destructive) { box.deleteBox(b.id) }
        }
    }

    private static let nodeW = 220.0

    private func stroke(_ ctx: inout GraphicsContext, _ a: CGPoint, _ b: CGPoint, _ color: Color) {
        var path = Path()
        let dx = max(50, abs(b.x - a.x) / 2)
        path.move(to: a)
        path.addCurve(to: b, control1: CGPoint(x: a.x + dx, y: a.y), control2: CGPoint(x: b.x - dx, y: b.y))
        ctx.stroke(path, with: .color(color.opacity(0.9)), lineWidth: 2.5)
    }

    // MARK: Ports

    private func portDot(_ n: GraphNode, _ spec: PortSpec, index: Int, output: Bool) -> some View {
        let p = at(output ? outputPoint(n, index) : inputPoint(n, index))
        return Circle()
            .fill(spec.type == .exec ? Color(nsColor: .controlBackgroundColor) : tint(spec.type))
            .overlay(Circle().stroke(tint(spec.type), lineWidth: 2))
            .frame(width: 13, height: 13)
            .contentShape(Circle().inset(by: -6))
            .position(p)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("graph"))
                .onChanged { v in wire = Wire(node: n.id, port: spec.name, type: spec.type, fromOutput: output, to: v.location) }
                .onEnded { v in finishWire(at: v.location) })
            .contextMenu {
                if !output, box.graph.edges.contains(where: { $0.toNode == n.id && $0.toPort == spec.name }) {
                    Button("Disconnect") { box.disconnect(toNode: n.id, port: spec.name) }
                }
            }
            .help("\(spec.name) (\(spec.type.rawValue))")
    }

    private func finishWire(at point: CGPoint) {
        defer { wire = nil }
        guard let w = wire else { return }
        for n in box.graph.nodes where n.id != w.node {
            let specs = w.fromOutput ? n.kind.inputs : n.kind.outputs
            for (i, spec) in specs.enumerated() where spec.type == w.type {
                let p = at(w.fromOutput ? inputPoint(n, i) : outputPoint(n, i))
                guard hypot(p.x - point.x, p.y - point.y) < 18 else { continue }
                box.connect(w.fromOutput
                    ? GraphEdge(fromNode: w.node, fromPort: w.port, toNode: n.id, toPort: spec.name)
                    : GraphEdge(fromNode: n.id, fromPort: spec.name, toNode: w.node, toPort: w.port))
                return
            }
        }
    }

    // MARK: Node card

    private func card(_ n: GraphNode) -> some View {
        let selected = box.selection.contains(n.id)
        return VStack(spacing: 0) {
            Text(n.kind.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
                .frame(height: L.header)
                .background(headerColor(n.kind))
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("graph"))
                    .onChanged { v in
                        let newDrag = dragOrigins == nil
                        if newDrag {
                            if !box.selection.contains(n.id) {
                                box.selection = Controls.shared.held(.nodeExtendSelection) ? box.selection.union([n.id]) : [n.id]
                            }
                            dragOrigins = Dictionary(uniqueKeysWithValues: box.graph.nodes.filter { box.selection.contains($0.id) }.map { ($0.id, CGPoint(x: $0.x, y: $0.y)) })
                        }
                        if let o = dragOrigins, abs(v.translation.width) + abs(v.translation.height) > 1 || !newDrag {
                            box.moveNodes(o, by: CGSize(width: v.translation.width / zoom, height: v.translation.height / zoom), newDrag: newDrag)
                        }
                    }
                    .onEnded { _ in dragOrigins = nil })
            ForEach(n.kind.params, id: \.key) { spec in
                paramEditor(n, spec).frame(height: L.paramRow).padding(.horizontal, 12)
            }
            ForEach(0..<rows(n.kind), id: \.self) { row in
                HStack(spacing: 4) {
                    if row < n.kind.inputs.count { inputLabel(n, n.kind.inputs[row]) }
                    Spacer(minLength: 0)
                    if row < n.kind.outputs.count {
                        Text(n.kind.outputs[row].type == .exec ? "\(n.kind.outputs[row].name) ▸" : n.kind.outputs[row].name)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: L.portRow)
            }
            Spacer(minLength: 0)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: selected ? 2.5 : 1))
        .shadow(radius: selected ? 4 : 1)
        .onTapGesture {
            if Controls.shared.held(.nodeExtendSelection) {
                if box.selection.contains(n.id) { box.selection.remove(n.id) } else { box.selection.insert(n.id) }
            } else { box.selection = [n.id] }
        }
        .contextMenu {
            let ids = box.selection.contains(n.id) ? box.selection : [n.id]
            Button(ids.count > 1 ? "Duplicate \(ids.count) Nodes" : "Duplicate") { box.duplicate(ids) }
            Button("Disconnect All Wires") { box.disconnectAll(ids) }
                .disabled(!box.graph.edges.contains { ids.contains($0.fromNode) || ids.contains($0.toNode) })
            Divider()
            Button(ids.count > 1 ? "Delete \(ids.count) Nodes" : "Delete", role: .destructive) { box.delete(ids) }
        }
    }

    private func headerColor(_ k: NodeKind) -> Color {
        switch k.category {
        case .events: return .red.opacity(0.45)
        case .flow: return .purple.opacity(0.4)
        case .functions: return .pink.opacity(0.45)
        case .sprites: return .brown.opacity(0.5)
        case .widgets: return .blue.opacity(0.4)
        case .variables: return .cyan.opacity(0.4)
        case .draw: return .teal.opacity(0.45)
        case .input: return .indigo.opacity(0.4)
        case .values: return .gray.opacity(0.35)
        case .math: return .orange.opacity(0.4)
        case .text: return .green.opacity(0.4)
        }
    }

    /// An input's label; when nothing is wired in, a field for the value to use instead.
    @ViewBuilder private func inputLabel(_ n: GraphNode, _ spec: PortSpec) -> some View {
        let wired = box.graph.edges.contains { $0.toNode == n.id && $0.toPort == spec.name }
        if spec.type == .exec {
            Text("▸").font(.caption).foregroundStyle(.secondary)
        } else {
            Text(spec.name).font(.caption).foregroundStyle(.secondary)
            if !wired && !(n.kind == .branch && spec.name == "condition") {
                if spec.type == .colour {
                    ColorPicker("", selection: Binding(get: { rgbColour(n.params[spec.name] ?? "255, 255, 255") },
                                                       set: { box.setParam(n.id, spec.name, rgbString($0)) }))
                        .labelsHidden().controlSize(.small).frame(width: 78)
                } else if spec.type == .bool {
                    Picker("", selection: Binding(get: { n.params[spec.name] ?? "No" }, set: { box.setParam(n.id, spec.name, $0) })) {
                        Text("Yes").tag("Yes"); Text("No").tag("No")
                    }.labelsHidden().controlSize(.small).frame(width: 64)
                } else {
                    TextField(spec.type == .number ? "0" : (spec.type == .vector ? "x, y" : (spec.type == .bounds ? "x, y, w, h" : "text")), text: Binding(get: { n.params[spec.name] ?? "" }, set: { box.setParam(n.id, spec.name, $0) }))
                        .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 78)
                }
            }
        }
    }

    @ViewBuilder private func paramEditor(_ n: GraphNode, _ spec: ParamSpec) -> some View {
        let value = Binding(get: { n.params[spec.key] ?? spec.defaultValue }, set: { box.setParam(n.id, spec.key, $0) })
        HStack {
            Text(spec.label).font(.caption).foregroundStyle(.secondary)
            switch spec.kind {
            case .text, .number:
                TextField(spec.label, text: value).textFieldStyle(.roundedBorder).controlSize(.small)
            case .toggle:
                Spacer(minLength: 0)
                Toggle("", isOn: Binding(get: { value.wrappedValue == "Yes" }, set: { value.wrappedValue = $0 ? "Yes" : "No" })).labelsHidden().toggleStyle(.checkbox)
            case .choice(let options):
                Picker("", selection: value) { ForEach(options, id: \.self) { Text($0).tag($0) } }.labelsHidden().controlSize(.small)
            case .widget:
                picker(value, options: box.widgetNames, empty: "Choose widget")
            case .sprite:
                picker(value, options: box.spriteNames, empty: "Choose sprite")
            case .sound:
                picker(value, options: box.soundNames, empty: "Choose sound")
            case .actor:
                picker(value, options: box.actorNames, empty: "Choose sprite")
            case .screen:
                picker(value, options: box.screenNames, empty: "Choose screen")
            case .music:
                picker(value, options: box.musicNames, empty: "Choose music")
            case .function:
                picker(value, options: box.functionNames, empty: "Choose function")
            case .colour:
                // Picks the colour by writing the node's own r, g and b inputs.
                ColorPicker("", selection: Binding(
                    get: { rgbColour("\(n.params["r"] ?? "255"), \(n.params["g"] ?? "255"), \(n.params["b"] ?? "255")") },
                    set: { c in
                        let p = rgbString(c).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        box.setParams(n.id, ["r": p[0], "g": p[1], "b": p[2]], key: "pick")
                    })).labelsHidden().controlSize(.small)
            case .variable(let type):
                picker(value, options: (box.graph.variables.filter { $0.type == type }.map(\.name)
                                        + box.otherGlobals.filter { $0.variable.type == type }.map(\.variable.name)).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } },
                       empty: "Choose variable")
            }
        }
    }

    /// "r, g, b" (0...255) <-> a SwiftUI colour.
    private func rgbColour(_ s: String) -> Color {
        let p = s.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Double($0) }
        let v = (0..<3).map { $0 < p.count ? max(0, min(255, p[$0])) / 255 : 1 }
        return Color(.sRGB, red: v[0], green: v[1], blue: v[2])
    }

    private func rgbString(_ c: Color) -> String {
        guard let n = NSColor(c).usingColorSpace(.sRGB) else { return "255, 255, 255" }
        return [n.redComponent, n.greenComponent, n.blueComponent].map { String(Int(($0 * 255).rounded())) }.joined(separator: ", ")
    }

    private func picker(_ value: Binding<String>, options: [String], empty: String) -> some View {
        let all = value.wrappedValue.isEmpty || options.contains(value.wrappedValue) ? options : options + [value.wrappedValue]
        return Picker("", selection: value) {
            Text(empty).tag("")
            ForEach(all, id: \.self) { Text($0).tag($0) }
        }.labelsHidden().controlSize(.small)
    }

    // MARK: Variables

    private var variablesPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Variables").font(.headline)
                Spacer()
                Menu {
                    Button("Number") { box.addVariable(type: .number) }
                    Button("Text") { box.addVariable(type: .text) }
                    Button("Boolean") { box.addVariable(type: .bool) }
                    Button("Vector") { box.addVariable(type: .vector) }
                    Button("Bounds") { box.addVariable(type: .bounds) }
                } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if box.graph.variables.isEmpty {
                        Text("No variables yet. Press + to add one, then use Get and Set nodes to read and change it.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                    }
                    ForEach(Array(box.graph.variables.enumerated()), id: \.offset) { i, v in variableCard(i, v) }
                }
                .padding(12)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// One variable: its name and Global switch on top, its starting value below.
    private func variableCard(_ i: Int, _ v: GraphVariable) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(tint(v.type)).frame(width: 9, height: 9)
                TextField("Name", text: Binding(get: { v.name }, set: { rename(i, to: $0) }))
                    .textFieldStyle(.plain).font(.callout.weight(.medium))
                Button { box.edit(key: "varglobal\(i)") { if i < $0.variables.count { $0.variables[i].global.toggle() } } } label: {
                    Label("Global", systemImage: v.global ? "globe.americas.fill" : "globe")
                        .font(.caption).foregroundStyle(v.global ? Color.white : Color.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(v.global ? Color.accentColor : Color.secondary.opacity(0.15), in: Capsule())
                }
                .buttonStyle(.plain)
                .help(v.global ? "Global: every node file and sprite actor reads and changes this one value. Click to make it local." : "Make this variable global so every node file and sprite actor can use it.")
                Button { box.edit { if i < $0.variables.count { $0.variables.remove(at: i) } } } label: { Image(systemName: "trash").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless).help("Delete variable")
            }
            HStack(spacing: 6) {
                Text("Starts as").font(.caption).foregroundStyle(.secondary)
                if v.type == .bool {
                    Picker("", selection: Binding(get: { v.initial == "Yes" ? "Yes" : "No" }, set: { setInitial(i, $0) })) {
                        Text("Yes").tag("Yes"); Text("No").tag("No")
                    }.labelsHidden().controlSize(.small).fixedSize()
                    Spacer(minLength: 0)
                } else {
                    TextField("", text: Binding(get: { v.initial }, set: { setInitial(i, $0) }))
                        .textFieldStyle(.roundedBorder).controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
    }

    /// Renaming also re-points every node that used the old name.
    private func rename(_ i: Int, to raw: String) {
        let new = UIDocument.identifier(raw)
        guard box.graph.variables.indices.contains(i) else { return }
        let old = box.graph.variables[i].name
        guard new != old, !box.graph.variables.contains(where: { $0.name == new }) else { return }
        box.edit(key: "varname\(i)") { g in
            g.variables[i].name = new
            for k in g.nodes.indices where g.nodes[k].params["variable"] == old { g.nodes[k].params["variable"] = new }
        }
    }

    private func setInitial(_ i: Int, _ value: String) {
        guard box.graph.variables.indices.contains(i) else { return }
        box.edit(key: "varinit\(i)") { $0.variables[i].initial = value }
    }
}

// MARK: Navigation

extension NodeEditorView {
    /// World-space rectangle currently on screen.
    private var visibleWorld: CGRect {
        CGRect(x: -pan.width / zoom, y: -pan.height / zoom, width: canvasSize.width / zoom, height: canvasSize.height / zoom)
    }

    /// Everything reachable by scrolling: all nodes, a margin around them, and the current view.
    private var totalWorld: CGRect {
        let v = visibleWorld
        guard !box.graph.nodes.isEmpty else { return v.insetBy(dx: -200, dy: -200) }
        let xs = box.graph.nodes.map { CGFloat($0.x) }, ys = box.graph.nodes.map { CGFloat($0.y) }
        let maxY = box.graph.nodes.map { CGFloat($0.y) + 200 }.max()!
        let nodes = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! + 220 - xs.min()!, height: maxY - ys.min()!)
        return nodes.insetBy(dx: -200, dy: -200).union(v)
    }

    @ViewBuilder var scrollBars: some View {
        let t = totalWorld, v = visibleWorld
        ZStack(alignment: .topLeading) {
            ScrollThumb(vertical: false, total: t.minX...t.maxX, visible: v.minX...v.maxX) { pan.width = -$0 * zoom }
                .frame(width: max(0, canvasSize.width - 12), height: 10)
                .position(x: (canvasSize.width - 12) / 2, y: canvasSize.height - 6)
            ScrollThumb(vertical: true, total: t.minY...t.maxY, visible: v.minY...v.maxY) { pan.height = -$0 * zoom }
                .frame(width: 10, height: max(0, canvasSize.height - 12))
                .position(x: canvasSize.width - 6, y: (canvasSize.height - 12) / 2)
        }
    }
}

/// A slim scroll bar over a world-space range; dragging the thumb reports the new lower bound of the view.
private struct ScrollThumb: View {
    let vertical: Bool
    let total: ClosedRange<CGFloat>
    let visible: ClosedRange<CGFloat>
    let move: (CGFloat) -> Void
    @State private var frozen: ClosedRange<CGFloat>?
    @State private var startLo: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let track = vertical ? geo.size.height : geo.size.width
            let t = frozen ?? total
            let span = max(t.upperBound - t.lowerBound, 1)
            let visLen = visible.upperBound - visible.lowerBound
            let len = min(track, max(28, track * visLen / span))
            let room = max(span - visLen, 0.001)
            let off = max(0, min(track - len, (visible.lowerBound - t.lowerBound) / room * (track - len)))
            Capsule().fill(Color.secondary.opacity(frozen == nil ? 0.35 : 0.6))
                .frame(width: vertical ? 6 : len, height: vertical ? len : 6)
                .offset(x: vertical ? 2 : off, y: vertical ? off : 2)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local).onChanged { v in
                    if frozen == nil { frozen = total; startLo = visible.lowerBound }
                    guard let lo = startLo, track > len else { return }
                    let d = vertical ? v.translation.height : v.translation.width
                    move(lo + d / (track - len) * room)
                }.onEnded { _ in frozen = nil; startLo = nil })
        }
    }
}

/// Catches what SwiftUI can't: the middle mouse button (pans) and the scroll wheel (zooms; a
/// trackpad's two-finger scroll pans). Every other event, including left-clicks, falls through.
private struct MouseCatcher: NSViewRepresentable {
    var onPan: (CGSize) -> Void
    var onWheel: (CGFloat, CGPoint) -> Void
    var onTrackpad: (CGSize) -> Void

    func makeNSView(context: Context) -> CatcherView { let v = CatcherView(); v.owner = self; return v }
    func updateNSView(_ v: CatcherView, context: Context) { v.owner = self }

    final class CatcherView: NSView {
        var owner: MouseCatcher?
        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .otherMouseDown, .otherMouseDragged, .otherMouseUp, .scrollWheel: return super.hitTest(point)
            default: return nil
            }
        }
        override func otherMouseDown(with e: NSEvent) {}
        override func otherMouseUp(with e: NSEvent) {}
        override func otherMouseDragged(with e: NSEvent) {
            if e.buttonNumber == 2 { owner?.onPan(CGSize(width: e.deltaX, height: e.deltaY)) }
        }
        override func scrollWheel(with e: NSEvent) {
            if e.hasPreciseScrollingDeltas {
                owner?.onTrackpad(CGSize(width: e.scrollingDeltaX, height: e.scrollingDeltaY))
            } else {
                owner?.onWheel(e.scrollingDeltaY, convert(e.locationInWindow, from: nil))
            }
        }
    }
}

// MARK: Analyze

/// Lists what the analyser found and applies the ticked suggestions in one undoable edit.
struct AnalyzeSheet: View {
    @ObservedObject var box: NodeGraphBox
    @Environment(\.dismiss) private var dismiss
    @State private var found: [GraphSuggestion] = []
    @State private var chosen: Set<String> = []
    @State private var performed: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Analyze").font(.headline)
            if let performed {
                Label(performed == 0 ? "Nothing needed changing." : "Done: \(performed) change\(performed == 1 ? "" : "s") made. Undo brings them back.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if found.isEmpty {
                Text(performed == nil ? "No clean-ups found. This graph is already tight." : "No further suggestions.").foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(found) { s in
                        Toggle(isOn: Binding(get: { chosen.contains(s.id) }, set: { on in if on { chosen.insert(s.id) } else { chosen.remove(s.id) } })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.title).font(.body.weight(.medium))
                                Text(s.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .onHover { inside in if inside { box.selection = Set(s.nodes) } }
                    }
                }
                .frame(minHeight: 160)
            }
            Text("When the app is built, maths on fixed numbers and decisions that never change are also worked out ahead of time automatically.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Perform Suggestions") {
                    performed = (performed ?? 0) + countChanges()
                    refresh()
                }
                .keyboardShortcut(.defaultAction).disabled(chosen.isEmpty)
            }
        }
        .padding(20).frame(width: 520)
        .onAppear { refresh() }
    }

    private func countChanges() -> Int {
        var copy = box.graph
        let n = copy.perform(chosen)
        box.perform(chosen)
        return n
    }

    private func refresh() {
        found = box.graph.suggestions()
        chosen = Set(found.map(\.id))
    }
}
