import Foundation
import Combine
import AppKit

/// Snapshot undo shared by the designer and node editor: `edit(key:)` records the state before a
/// change, and consecutive edits with the same key within a second (typing in one field, one
/// drag) collapse into a single undo step.
@MainActor class SnapshotHistory<Doc: Equatable> {
    private(set) var undoStack: [Doc] = []
    private(set) var redoStack: [Doc] = []
    private var lastKey: String?
    private var lastTime = Date.distantPast
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func record(_ current: Doc, key: String?) {
        if let key, key == lastKey, Date().timeIntervalSince(lastTime) < 1 { lastTime = Date(); return }
        lastKey = key; lastTime = Date()
        undoStack.append(current)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }
    func undo(_ current: Doc) -> Doc? {
        guard let prev = undoStack.popLast() else { return nil }
        redoStack.append(current); lastKey = nil
        return prev
    }
    func redo(_ current: Doc) -> Doc? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current); lastKey = nil
        return next
    }
}

/// The folder a `.wiiui`/`.wiinodes` belongs to: the nearest parent holding the project's Makefile.
nonisolated func homebrewProjectRoot(for file: URL?) -> URL? {
    guard let file else { return nil }
    var dir = file.deletingLastPathComponent()
    while dir.path != "/" {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Makefile").path) { return dir }
        dir = dir.deletingLastPathComponent()
    }
    return file.deletingLastPathComponent()
}

@MainActor final class UIDesignBox: ObservableObject {
    @Published private(set) var doc: UIDocument
    @Published var isDirty = false
    @Published var selection: String?
    let url: URL?
    let projectRoot: URL?
    private let history = SnapshotHistory<UIDocument>()

    init(doc: UIDocument, url: URL?) {
        self.doc = doc
        self.url = url
        self.projectRoot = homebrewProjectRoot(for: url)
    }

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    func edit(key: String? = nil, _ change: (inout UIDocument) -> Void) {
        history.record(doc, key: key)
        change(&doc)
        isDirty = true
    }

    func undo() { if let d = history.undo(doc) { doc = d; isDirty = true; fixSelection() } }
    func redo() { if let d = history.redo(doc) { doc = d; isDirty = true; fixSelection() } }
    private func fixSelection() { if let s = selection, !doc.widgets.contains(where: { $0.name == s }) { selection = nil } }

    func index(of name: String) -> Int? { doc.widgets.firstIndex { $0.name == name } }

    func update(_ name: String, key: String? = nil, _ change: (inout UIWidget) -> Void) {
        guard let i = index(of: name) else { return }
        edit(key: key.map { "\(name).\($0)" }) { change(&$0.widgets[i]) }
    }

    func add(_ kind: UIWidget.Kind, imagePath: String = "") {
        let n = doc.widgets.count % 8
        var w = UIWidget.make(kind, name: doc.uniqueName(kind.rawValue), x: Double(40 + n * 20), y: Double(40 + n * 20))
        w.imagePath = imagePath
        edit { $0.widgets.append(w) }
        selection = w.name
    }

    func rename(_ old: String, to new: String) {
        let name = UIDocument.identifier(new)
        guard name != old, !doc.widgets.contains(where: { $0.name == name }) else { return }
        update(old) { $0.name = name }
        if selection == old { selection = name }
    }

    func deleteSelected() {
        guard let s = selection else { return }
        edit { $0.widgets.removeAll { $0.name == s } }
        selection = nil
    }

    func move(_ name: String, by delta: Int) {   // draw order: later is on top
        guard let i = index(of: name), (0..<doc.widgets.count).contains(i + delta) else { return }
        edit { $0.widgets.swapAt(i, i + delta) }
    }

    func moveToEdge(_ name: String, front: Bool) {
        guard let i = index(of: name) else { return }
        edit { let w = $0.widgets.remove(at: i); front ? $0.widgets.append(w) : $0.widgets.insert(w, at: 0) }
    }

    func delete(_ name: String) {
        edit { $0.widgets.removeAll { $0.name == name } }
        if selection == name { selection = nil }
    }

    func duplicate(_ name: String) {
        guard let i = index(of: name) else { return }
        var w = doc.widgets[i]
        w.name = doc.uniqueName(w.kind.rawValue)
        w.x += 16; w.y += 16
        edit { $0.widgets.insert(w, at: i + 1) }
        selection = w.name
    }
}

@MainActor final class NodeGraphBox: ObservableObject {
    @Published private(set) var graph: NodeGraph
    @Published var isDirty = false
    @Published var selection: Set<String> = []
    /// Widget names from the project's `.wiiui`, for the widget pickers.
    @Published var widgetNames: [String] = []
    /// Images and sounds in the project's `assets/` folder, for the sprite and sound pickers.
    @Published var spriteNames: [String] = []
    @Published var soundNames: [String] = []
    @Published var musicNames: [String] = []
    @Published var screenNames: [String] = []
    @Published var actorNames: [String] = []
    /// Variables marked Global in the project's other node files.
    @Published var otherGlobals: [(file: String, variable: GraphVariable)] = []
    /// True when this file is a sprite actor (see `NodeGraph.actorSprite`).
    var isActor: Bool { graph.actorSprite != nil }
    let url: URL?
    let projectRoot: URL?
    private let history = SnapshotHistory<NodeGraph>()

    /// Every open graph, so shared (Global) variables show up in other files straight away, before anything is saved.
    private static let live = NSHashTable<NodeGraphBox>.weakObjects()
    private static let globalsChanged = Notification.Name("NodeGraphBox.globalsChanged")
    private var observer: NSObjectProtocol?

    init(graph: NodeGraph, url: URL?) {
        self.graph = graph
        self.url = url
        self.projectRoot = homebrewProjectRoot(for: url)
        Self.live.add(self)
        observer = NotificationCenter.default.addObserver(forName: Self.globalsChanged, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as AnyObject?) !== self else { return }
                self.reloadWidgetNames()
            }
        }
        reloadWidgetNames()
    }

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    func reloadWidgetNames() {
        if let root = projectRoot {
            spriteNames = AssetCatalog.images(in: root).map(\.name)
            soundNames = AssetCatalog.sounds(in: root).map(\.name)
            musicNames = AssetCatalog.music(in: root).map(\.name)
        }
        // Other node files: what is on disk, replaced by the in-memory version of any that are open.
        var files: [String: (name: String, graph: NodeGraph)] = [:]
        for entry in (projectRoot.flatMap { try? HomebrewGenerator.nodeGraphs(in: $0) } ?? []) { files[entry.url.standardizedFileURL.path] = (entry.name, entry.graph) }
        for other in Self.live.allObjects where other !== self {
            guard let u = other.url, other.projectRoot?.standardizedFileURL == projectRoot?.standardizedFileURL else { continue }
            files[u.standardizedFileURL.path] = (UIDocument.identifier(u.deletingPathExtension().lastPathComponent), other.graph)
        }
        let mine = url?.standardizedFileURL.path
        let others = files.filter { $0.key != mine }.values.sorted { $0.name < $1.name }
        otherGlobals = others.flatMap { entry in entry.graph.variables.filter(\.global).map { (entry.name, $0) } }
        actorNames = files.values.filter { $0.graph.actorSprite != nil }.map(\.name).sorted()
        guard let root = projectRoot, let screens = try? HomebrewGenerator.uiScreens(in: root) else { widgetNames = []; screenNames = []; return }
        widgetNames = screens.flatMap { $0.doc.widgets.map(\.name) }
        screenNames = screens.map(\.name)
    }

    func edit(key: String? = nil, _ change: (inout NodeGraph) -> Void) {
        history.record(graph, key: key)
        let before = globalSignature
        change(&graph)
        isDirty = true
        if globalSignature != before { NotificationCenter.default.post(name: Self.globalsChanged, object: self) }
    }

    private var globalSignature: [String] { graph.variables.filter(\.global).map { "\($0.name):\($0.type.rawValue)" } + [graph.actorSprite == nil ? "p" : "a"] }

    func undo() { if let g = history.undo(graph) { graph = g; isDirty = true; selection = [] } }
    func redo() { if let g = history.redo(graph) { graph = g; isDirty = true; selection = [] } }
    var undoCount: Int { history.undoStack.count }
    var redoCount: Int { history.redoStack.count }
    /// History menu: step `n` states back (negative = forward).
    func step(_ n: Int) { for _ in 0..<abs(n) { n > 0 ? undo() : redo() } }

    /// Names of the graph's Define Function nodes, for the Call Function picker.
    var functionNames: [String] {
        graph.nodes.filter { $0.kind == .defineFunction }.map { UIDocument.identifier($0.params["name"] ?? "") }
    }

    func addNode(_ kind: NodeKind, x: Double, y: Double) {
        let n = GraphNode.make(kind, x: x, y: y)
        edit { $0.nodes.append(n) }
        selection = [n.id]
    }

    /// Several parameters in one undo step (a colour picker sets r, g and b together).
    func setParams(_ node: String, _ values: [String: String], key: String) {
        guard let i = graph.nodes.firstIndex(where: { $0.id == node }) else { return }
        edit(key: "\(node).\(key)") { for (k, v) in values { $0.nodes[i].params[k] = v } }
    }

    func setParam(_ node: String, _ key: String, _ value: String) {
        guard let i = graph.nodes.firstIndex(where: { $0.id == node }) else { return }
        edit(key: "\(node).\(key)") { $0.nodes[i].params[key] = value }
    }

    /// Moves every node in `origins` (id -> where it was when the drag began) by `d`.
    func moveNodes(_ origins: [String: CGPoint], by d: CGSize, newDrag: Bool) {
        edit(key: newDrag ? nil : "drag") { g in
            for (id, o) in origins {
                guard let i = g.nodes.firstIndex(where: { $0.id == id }) else { continue }
                g.nodes[i].x = Double(o.x + d.width); g.nodes[i].y = Double(o.y + d.height)
            }
        }
    }

    func connect(_ e: GraphEdge) {
        var probe = graph
        guard probe.connect(e) else { return }
        edit { _ = $0.connect(e) }
    }

    func disconnect(toNode: String, port: String) {
        edit { $0.edges.removeAll { $0.toNode == toNode && $0.toPort == port } }
    }

    func deleteSelected() { delete(selection) }

    func delete(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        edit { g in for id in ids { g.remove(node: id) } }
        selection.subtract(ids)
    }

    /// Copies beside the originals; wires between copied nodes are kept, wires to others are not.
    func duplicate(_ ids: Set<String>) {
        var map: [String: String] = [:], copies: [GraphNode] = []
        for n in graph.nodes where ids.contains(n.id) {
            var c = GraphNode.make(n.kind, x: n.x + 30, y: n.y + 30)
            c.params = n.params
            map[n.id] = c.id
            copies.append(c)
        }
        guard !copies.isEmpty else { return }
        let wires = graph.edges.compactMap { e -> GraphEdge? in
            guard let a = map[e.fromNode], let b = map[e.toNode] else { return nil }
            return GraphEdge(fromNode: a, fromPort: e.fromPort, toNode: b, toPort: e.toPort)
        }
        edit { $0.nodes += copies; $0.edges += wires }
        selection = Set(copies.map(\.id))
    }

    /// Tidies every node into neat columns (one undo step).
    func cleanUp() { edit { $0.cleanUp() } }

    func addBox(x: Double, y: Double) { edit { $0.boxes.append(GraphBox.make(x: x, y: y)) } }

    func updateBox(_ id: String, key: String? = nil, _ change: (inout GraphBox) -> Void) {
        guard let i = graph.boxes.firstIndex(where: { $0.id == id }) else { return }
        edit(key: key.map { "box.\(id).\($0)" }) { change(&$0.boxes[i]) }
    }

    func deleteBox(_ id: String) { edit { $0.boxes.removeAll { $0.id == id } } }

    /// Moves a box together with the nodes sitting inside it.
    func moveBox(_ id: String, nodes ids: [String: CGPoint], origin: CGPoint, by d: CGSize, newDrag: Bool) {
        edit(key: newDrag ? nil : "boxdrag.\(id)") { g in
            if let i = g.boxes.firstIndex(where: { $0.id == id }) { g.boxes[i].x = Double(origin.x + d.width); g.boxes[i].y = Double(origin.y + d.height) }
            for (nid, o) in ids { if let i = g.nodes.firstIndex(where: { $0.id == nid }) { g.nodes[i].x = Double(o.x + d.width); g.nodes[i].y = Double(o.y + d.height) } }
        }
    }

    /// Runs the chosen analyser passes as one undoable edit.
    func perform(_ ids: Set<String>) { edit { $0.perform(ids) } }

    func disconnectAll(_ ids: Set<String>) {
        edit { $0.edges.removeAll { ids.contains($0.fromNode) || ids.contains($0.toNode) } }
    }

    func addVariable(type: PortType) {
        var n = 1
        while graph.variables.contains(where: { $0.name == "var\(n)" }) { n += 1 }
        let v = GraphVariable(name: "var\(n)", type: type, initial: type == .text ? "" : (type == .bool ? "No" : (type == .vector ? "0, 0" : (type == .bounds ? "0, 0, 32, 32" : "0"))))
        edit { $0.variables.append(v) }
    }
}
