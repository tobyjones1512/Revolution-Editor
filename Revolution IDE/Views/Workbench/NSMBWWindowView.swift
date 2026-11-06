import SwiftUI
import Combine

/// Resolves an NSMBW level window's session from the id the `WindowGroup(for: UUID.self)` in
/// `RevolutionIDEApp` hands it. See `SZSWindowContainerView` for why this indirection exists.
struct NSMBWWindowContainerView: View {
    @EnvironmentObject var workbench: WorkbenchState
    let id: UUID?

    var body: some View {
        if let id, let session = workbench.nsmbwWindowSessions[id] {
            NSMBWWindowView(session: session)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "square.grid.3x3").font(.system(size: 32)).foregroundStyle(.tertiary)
                Text("This level is no longer available.").foregroundStyle(.secondary)
                Text("Close this window and reopen the file.").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// One New Super Mario Bros. Wii level shown in its own dedicated OS window, only when the user
/// explicitly asked for that via "Open in New Window" (an `.arc`/`.szs` file gets that option in
/// its context menu). Opening one normally puts it in a Workbench tab instead, alongside every
/// other file; this is just a thin window-chrome wrapper around the same `NSMBWLevelView` content
/// the tab case uses (mirrors `SZSWindowView`/`SZSArchiveView`).
struct NSMBWWindowView: View {
    @EnvironmentObject var workbench: WorkbenchState
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var session: NSMBWWindowSession
    /// See `SZSWindowView`'s identical `box` property for why this is necessary: `session.box`'s
    /// own `isDirty`/`selectedAreaIndex` changing doesn't cascade through `session`'s
    /// `objectWillChange`, so without observing `box` directly the Save button never proactively
    /// re-renders when an edit actually happens.
    @ObservedObject private var box: NSMBWDocumentBox

    init(session: NSMBWWindowSession) {
        self.session = session
        self.box = session.box
    }

    var body: some View {
        NSMBWLevelView(box: box)
            .navigationTitle(session.title)
            .toolbar {
                ToolbarItem {
                    Button { workbench.saveNSMBWWindow(session) } label: { Label("Save", systemImage: "square.and.arrow.down") }
                        .disabled(!box.isDirty)
                        .shortcut(.save)
                }
            }
            .onChange(of: workbench.pendingSZSWindowID) { _, id in
                guard let id else { return }
                openWindow(id: "szsWindow", value: id)
                workbench.pendingSZSWindowID = nil
            }
            .onChange(of: workbench.pendingNSMBWWindowID) { _, id in
                guard let id else { return }
                openWindow(id: "nsmbwWindow", value: id)
                workbench.pendingNSMBWWindowID = nil
            }
    }
}

/// The content shared by an NSMBW level's Workbench tab and its dedicated window: an area picker
/// (when the level has more than one area) over the same 2D canvas + inspector `NSMBWAreaEditorView`
/// provides.
struct NSMBWLevelView: View {
    @ObservedObject var box: NSMBWDocumentBox
    /// Lives here, not in `NSMBWAreaEditorView`, which is torn down and rebuilt via
    /// `.id(selectedAreaIndex)` every time the area picker changes, this view isn't, so undo/redo
    /// survive switching areas and stay shared whether this is shown in a dedicated
    /// `NSMBWWindowView`, a Workbench tab, or nested inside an `.szs`.
    @StateObject private var history: EditHistory

    init(box: NSMBWDocumentBox) {
        self.box = box
        _history = StateObject(wrappedValue: EditHistory(initial: box.doc.snapshotData()))
    }

    private func pushHistory(_ label: String) {
        history.push(box.doc.snapshotData(), label: label)
    }

    private func restoreFromHistory(_ snapshot: Data) {
        guard let restored = try? NSMBWLevelDocument.restoring(from: snapshot) else { return }
        box.doc = restored
        box.isDirty = true
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if box.doc.areas.count > 1 {
                    Picker("Area", selection: Binding(
                        get: { box.selectedAreaIndex },
                        set: { box.selectedAreaIndex = $0 }
                    )) {
                        ForEach(Array(box.doc.areas.enumerated()), id: \.offset) { i, area in
                            Text("Area \(area.areaNumber)").tag(i)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Spacer()
                HistoryControlsView(history: history, onRestore: restoreFromHistory)
            }
            .padding(8)
            Divider()
            if box.doc.areas.indices.contains(box.selectedAreaIndex) {
                NSMBWAreaEditorView(box: box, area: box.doc.areas[box.selectedAreaIndex], pushHistory: pushHistory)
                    .id(box.selectedAreaIndex)
            }
        }
    }
}

/// What's currently selected in the canvas, for the inspector.
private enum NSMBWSelection: Hashable {
    case zone(Int), entrance(Int), sprite(Int), location(Int), pathNode(path: Int, node: Int), object(Int)
}

private struct NSMBWWindowView_AreaEditor {} // (namespacing helper, unused, keeps file organized)

struct NSMBWAreaEditorView: View {
    @ObservedObject var box: NSMBWDocumentBox
    let area: NSMBWArea
    /// Records a new undo step, see `NSMBWLevelView.history`'s doc comment for why this lives up
    /// there instead of as `@State` here.
    let pushHistory: (String) -> Void

    @State private var scale: CGFloat = 1
    @State private var gestureStartScale: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @State private var dragStartOffset: CGSize = .zero
    @State private var selection: NSMBWSelection?
    /// Set once, at the start of a drag, to whichever of these the drag turns out to be, panning
    /// the canvas, or moving whatever's currently selected (when the drag starts on top of it).
    /// Deciding this once and sticking with it for the whole gesture (instead of re-checking every
    /// `onChanged`) avoids the drag flip-flopping between the two if the pointer happens to cross
    /// the selection's hit area mid-drag.
    private enum DragMode { case panning, moving(NSMBWSelection) }
    @State private var dragMode: DragMode?
    @State private var dragStartWorldPos: CGPoint?
    @State private var showZones = true
    @State private var showObjects = true
    @State private var showSprites = true
    @State private var showEntrances = true
    @State private var showLocations = true
    @State private var showPaths = true
    @State private var areaSettingsExpanded = true

    private let minScale: CGFloat = 0.05, maxScale: CGFloat = 8

    var body: some View {
        HSplitView {
            canvasArea.frame(minWidth: 420)
            inspector.frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
        }
    }

    // MARK: Canvas

    private var canvasArea: some View {
        VStack(spacing: 0) {
            layerToggleBar
            Divider()
            GeometryReader { geo in
                Canvas { context, size in
                    draw(in: &context, size: size)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .gesture(dragGesture(size: geo.size))
                .gesture(MagnificationGesture()
                    .onChanged { value in scale = clampedScale(gestureStartScale * value) }
                    .onEnded { value in scale = clampedScale(gestureStartScale * value); gestureStartScale = scale }
                )
                .gesture(SpatialTapGesture().onEnded { value in handleTap(at: value.location, size: geo.size) })
                .overlay(alignment: .bottomTrailing) { zoomControls(size: geo.size) }
            }
        }
        .onAppear { /* placeholder for a future "zoom to fit on open" */ }
    }

    private var layerToggleBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                Toggle("Zones", isOn: $showZones).toggleStyle(.button).tint(.orange)
                Toggle("Objects", isOn: $showObjects).toggleStyle(.button).tint(.blue)
                Toggle("Sprites", isOn: $showSprites).toggleStyle(.button).tint(.green)
                Toggle("Entrances", isOn: $showEntrances).toggleStyle(.button).tint(.purple)
                Toggle("Locations", isOn: $showLocations).toggleStyle(.button).tint(.pink)
                Toggle("Paths", isOn: $showPaths).toggleStyle(.button).tint(.red)
            }
            .font(.caption)
            .padding(6)
        }
    }

    private func worldToScreen(_ x: CGFloat, _ y: CGFloat, size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2 + panOffset.width + x * scale, y: size.height / 2 + panOffset.height + y * scale)
    }

    private func screenToWorld(_ p: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: (p.x - size.width / 2 - panOffset.width) / scale, y: (p.y - size.height / 2 - panOffset.height) / scale)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        // Light grid for orientation, matching the KMP editor's canvas conventions.
        context.stroke(Path { p in
            let step: CGFloat = 64 * scale
            guard step > 2 else { return }
            var x = size.width / 2 + panOffset.width.truncatingRemainder(dividingBy: step)
            while x < size.width { p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)); x += step }
            var y = size.height / 2 + panOffset.height.truncatingRemainder(dividingBy: step)
            while y < size.height { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)); y += step }
        }, with: .color(.gray.opacity(0.15)))

        if showZones {
            for (i, z) in area.zones.enumerated() {
                let rect = worldRect(x: z.x, y: z.y, w: z.width, h: z.height, size: size)
                let selected = selection == .zone(i)
                context.stroke(Path(rect), with: .color(.orange.opacity(selected ? 1 : 0.6)), style: StrokeStyle(lineWidth: selected ? 2.5 : 1.5, dash: [6, 4]))
            }
        }
        if showLocations {
            for (i, l) in area.locations.enumerated() {
                let rect = worldRect(x: l.x, y: l.y, w: l.width, h: l.height, size: size)
                let selected = selection == .location(i)
                context.fill(Path(rect), with: .color(.pink.opacity(selected ? 0.35 : 0.15)))
                context.stroke(Path(rect), with: .color(.pink.opacity(0.8)), lineWidth: selected ? 2 : 1)
            }
        }
        if showObjects {
            for (i, o) in area.objects.enumerated() {
                let rect = worldRect(x: o.x * 16, y: o.y * 16, w: max(o.width, 1) * 16, h: max(o.height, 1) * 16, size: size)
                let selected = selection == .object(i)
                let color: Color = [.blue, .cyan, .teal, .indigo][o.tilesetIndex % 4]
                context.fill(Path(rect), with: .color(color.opacity(selected ? 0.85 : 0.5)))
                context.stroke(Path(rect), with: .color(.white.opacity(0.6)), lineWidth: 0.5)
            }
        }
        if showPaths {
            for path in area.paths {
                var p = Path()
                for (i, node) in path.nodes.enumerated() {
                    let pt = worldToScreen(CGFloat(node.x), CGFloat(node.y), size: size)
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                if path.loops, let first = path.nodes.first, let last = path.nodes.last, first.x != last.x || first.y != last.y {
                    p.addLine(to: worldToScreen(CGFloat(first.x), CGFloat(first.y), size: size))
                }
                context.stroke(p, with: .color(.red.opacity(0.7)), lineWidth: 1.5)
                for (ni, node) in path.nodes.enumerated() {
                    let pt = worldToScreen(CGFloat(node.x), CGFloat(node.y), size: size)
                    let selected = selection == .pathNode(path: Int(path.pathId), node: ni)
                    let r: CGFloat = selected ? 5 : 3
                    context.fill(Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)), with: .color(.red))
                }
            }
        }
        if showSprites {
            for (i, s) in area.sprites.enumerated() {
                let pt = worldToScreen(CGFloat(s.x), CGFloat(s.y), size: size)
                let selected = selection == .sprite(i)
                let r: CGFloat = selected ? 7 : 5
                context.fill(Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)), with: .color(.green))
                if selected { context.stroke(Path(ellipseIn: CGRect(x: pt.x - r - 2, y: pt.y - r - 2, width: (r + 2) * 2, height: (r + 2) * 2)), with: .color(.white), lineWidth: 1.5) }
            }
        }
        if showEntrances {
            for (i, e) in area.entrances.enumerated() {
                let pt = worldToScreen(CGFloat(e.x), CGFloat(e.y), size: size)
                let selected = selection == .entrance(i)
                let r: CGFloat = selected ? 8 : 6
                let rect = CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)
                context.fill(Path(rect), with: .color(.purple))
                context.stroke(Path(rect), with: .color(.white), lineWidth: selected ? 2 : 1)
            }
        }
    }

    private func worldRect(x: Int, y: Int, w: Int, h: Int, size: CGSize) -> CGRect {
        let a = worldToScreen(CGFloat(x), CGFloat(y), size: size)
        let b = worldToScreen(CGFloat(x + w), CGFloat(y + h), size: size)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// A drag that starts on top of the current selection moves it (in world space, so it tracks
    /// 1:1 with the pointer regardless of zoom); any other drag pans the canvas, exactly as before.
    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragMode == nil {
                    if let sel = selection, hitTestSelection(sel, at: value.startLocation, size: size) {
                        dragMode = .moving(sel)
                        dragStartWorldPos = worldPosition(of: sel)
                    } else {
                        dragMode = .panning
                    }
                }
                switch dragMode {
                case .moving(let sel):
                    guard let start = dragStartWorldPos else { return }
                    let worldDelta = CGPoint(x: value.translation.width / scale, y: value.translation.height / scale)
                    setWorldPosition(of: sel, to: CGPoint(x: start.x + worldDelta.x, y: start.y + worldDelta.y))
                case .panning, nil:
                    panOffset = CGSize(width: dragStartOffset.width + value.translation.width, height: dragStartOffset.height + value.translation.height)
                }
            }
            .onEnded { _ in
                switch dragMode {
                case .panning: dragStartOffset = panOffset
                // One history step for the whole drag, not one per frame (`setWorldPosition`,
                // called from `onChanged` every frame while dragging, deliberately does not push).
                case .moving: pushHistory("Move")
                case nil: break
                }
                dragMode = nil
                dragStartWorldPos = nil
            }
    }

    private func hitTestSelection(_ sel: NSMBWSelection, at location: CGPoint, size: CGSize) -> Bool {
        switch sel {
        case .zone(let i):
            guard area.zones.indices.contains(i) else { return false }
            let z = area.zones[i]
            return worldRect(x: z.x, y: z.y, w: z.width, h: z.height, size: size).insetBy(dx: -4, dy: -4).contains(location)
        case .location(let i):
            guard area.locations.indices.contains(i) else { return false }
            let l = area.locations[i]
            return worldRect(x: l.x, y: l.y, w: l.width, h: l.height, size: size).insetBy(dx: -4, dy: -4).contains(location)
        case .object(let i):
            guard area.objects.indices.contains(i) else { return false }
            let o = area.objects[i]
            return worldRect(x: o.x * 16, y: o.y * 16, w: max(o.width, 1) * 16, h: max(o.height, 1) * 16, size: size).contains(location)
        case .entrance(let i):
            guard area.entrances.indices.contains(i) else { return false }
            let e = area.entrances[i]
            return hypot(worldToScreen(CGFloat(e.x), CGFloat(e.y), size: size).x - location.x, worldToScreen(CGFloat(e.x), CGFloat(e.y), size: size).y - location.y) < 14
        case .sprite(let i):
            guard area.sprites.indices.contains(i) else { return false }
            let s = area.sprites[i]
            let pt = worldToScreen(CGFloat(s.x), CGFloat(s.y), size: size)
            return hypot(pt.x - location.x, pt.y - location.y) < 14
        case .pathNode(let p, let n):
            guard let pi = area.paths.firstIndex(where: { Int($0.pathId) == p }), area.paths[pi].nodes.indices.contains(n) else { return false }
            let node = area.paths[pi].nodes[n]
            let pt = worldToScreen(CGFloat(node.x), CGFloat(node.y), size: size)
            return hypot(pt.x - location.x, pt.y - location.y) < 14
        }
    }

    private func worldPosition(of sel: NSMBWSelection) -> CGPoint? {
        switch sel {
        case .zone(let i): guard area.zones.indices.contains(i) else { return nil }; let z = area.zones[i]; return CGPoint(x: z.x, y: z.y)
        case .location(let i): guard area.locations.indices.contains(i) else { return nil }; let l = area.locations[i]; return CGPoint(x: l.x, y: l.y)
        case .object(let i): guard area.objects.indices.contains(i) else { return nil }; let o = area.objects[i]; return CGPoint(x: o.x * 16, y: o.y * 16)
        case .entrance(let i): guard area.entrances.indices.contains(i) else { return nil }; let e = area.entrances[i]; return CGPoint(x: e.x, y: e.y)
        case .sprite(let i): guard area.sprites.indices.contains(i) else { return nil }; let s = area.sprites[i]; return CGPoint(x: s.x, y: s.y)
        case .pathNode(let p, let n):
            guard let pi = area.paths.firstIndex(where: { Int($0.pathId) == p }), area.paths[pi].nodes.indices.contains(n) else { return nil }
            let node = area.paths[pi].nodes[n]
            return CGPoint(x: node.x, y: node.y)
        }
    }

    private func setWorldPosition(of sel: NSMBWSelection, to pt: CGPoint) {
        switch sel {
        case .zone(let i):
            guard area.zones.indices.contains(i) else { return }
            area.zones[i].x = Int(pt.x); area.zones[i].y = Int(pt.y)
        case .location(let i):
            guard area.locations.indices.contains(i) else { return }
            area.locations[i].x = Int(pt.x); area.locations[i].y = Int(pt.y)
        case .object(let i):
            guard area.objects.indices.contains(i) else { return }
            area.objects[i].x = Int((pt.x / 16).rounded()); area.objects[i].y = Int((pt.y / 16).rounded())
        case .entrance(let i):
            guard area.entrances.indices.contains(i) else { return }
            area.entrances[i].x = Int(pt.x); area.entrances[i].y = Int(pt.y)
        case .sprite(let i):
            guard area.sprites.indices.contains(i) else { return }
            area.sprites[i].x = Int(pt.x); area.sprites[i].y = Int(pt.y)
        case .pathNode(let p, let n):
            guard let pi = area.paths.firstIndex(where: { Int($0.pathId) == p }), area.paths[pi].nodes.indices.contains(n) else { return }
            area.paths[pi].nodes[n].x = Int(pt.x); area.paths[pi].nodes[n].y = Int(pt.y)
        }
        markDirty()
    }

    private func handleTap(at location: CGPoint, size: CGSize) {
        var best: (NSMBWSelection, CGFloat)?
        func consider(_ sel: NSMBWSelection, _ screenPoint: CGPoint) {
            let d = hypot(screenPoint.x - location.x, screenPoint.y - location.y)
            if d < 12, best == nil || d < best!.1 { best = (sel, d) }
        }
        for (i, s) in area.sprites.enumerated() where showSprites { consider(.sprite(i), worldToScreen(CGFloat(s.x), CGFloat(s.y), size: size)) }
        for (i, e) in area.entrances.enumerated() where showEntrances { consider(.entrance(i), worldToScreen(CGFloat(e.x), CGFloat(e.y), size: size)) }
        for path in area.paths where showPaths {
            for (ni, node) in path.nodes.enumerated() { consider(.pathNode(path: Int(path.pathId), node: ni), worldToScreen(CGFloat(node.x), CGFloat(node.y), size: size)) }
        }
        if best == nil {
            let world = screenToWorld(location, size: size)
            if showObjects, let i = area.objects.firstIndex(where: { obj in
                CGFloat(obj.x * 16)...CGFloat((obj.x + max(obj.width, 1)) * 16) ~= world.x &&
                CGFloat(obj.y * 16)...CGFloat((obj.y + max(obj.height, 1)) * 16) ~= world.y
            }) { best = (.object(i), 0) }
        }
        if best == nil {
            let world = screenToWorld(location, size: size)
            if showLocations, let i = area.locations.firstIndex(where: { l in
                CGFloat(l.x)...CGFloat(l.x + l.width) ~= world.x && CGFloat(l.y)...CGFloat(l.y + l.height) ~= world.y
            }) { best = (.location(i), 0) }
        }
        selection = best?.0
    }

    // MARK: Zoom (mirrors KMPEditorView's approach)

    private func clampedScale(_ s: CGFloat) -> CGFloat { max(minScale, min(maxScale, s)) }

    private func zoom(by factor: CGFloat, size: CGSize) {
        let newScale = clampedScale(scale * factor)
        scale = newScale; gestureStartScale = newScale
    }

    private func zoomControls(size: CGSize) -> some View {
        HStack(spacing: 4) {
            addMenu(size: size)
            if selection != nil {
                Button(role: .destructive) { deleteSelection() } label: { Image(systemName: "trash") }
            }
            Divider().frame(height: 14)
            Button { zoom(by: 0.8, size: size) } label: { Image(systemName: "minus.magnifyingglass") }
            Text("\(Int(scale * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 46)
            Button { zoom(by: 1.25, size: size) } label: { Image(systemName: "plus.magnifyingglass") }
            Divider().frame(height: 14)
            Button { scale = 1; gestureStartScale = 1; panOffset = .zero; dragStartOffset = .zero } label: { Text("1:1") }
        }
        .buttonStyle(.borderless)
        .padding(6)
        .background(.bar, in: RoundedRectangle(cornerRadius: 8))
        .padding(10)
    }

    // MARK: Add / remove

    private func centerWorld(size: CGSize) -> CGPoint {
        screenToWorld(CGPoint(x: size.width / 2, y: size.height / 2), size: size)
    }

    private func addMenu(size: CGSize) -> some View {
        Menu {
            Button("Zone") { addZone(at: centerWorld(size: size)) }
            Button("Entrance") { addEntrance(at: centerWorld(size: size)) }
            Button("Sprite") { addSprite(at: centerWorld(size: size)) }
            Button("Location") { addLocation(at: centerWorld(size: size)) }
            Button("Object") { addObject(at: centerWorld(size: size)) }
            Button("Path") { addPath(at: centerWorld(size: size)) }
        } label: { Image(systemName: "plus") }
    }

    /// Smallest ID not already used by `items`, so a freshly-added entry doesn't collide with an
    /// existing zone/entrance/location/path, these IDs are how other entries (an entrance's
    /// `zoneId`, a path's `pathId`) reference each other, so reusing one would silently re-target
    /// whatever already pointed at it.
    private func nextId<T>(_ items: [T], _ keyPath: KeyPath<T, UInt8>) -> UInt8 {
        let used = Set(items.map { $0[keyPath: keyPath] })
        var candidate: UInt8 = 0
        while used.contains(candidate) && candidate < 255 { candidate += 1 }
        return candidate
    }

    private func markDirty() {
        box.isDirty = true
        box.objectWillChange.send()
    }

    /// `markDirty()` plus one undo step, for a discrete, complete action (add/delete/toggle/field
    /// commit). Deliberately separate from `markDirty()` itself: `setWorldPosition` calls
    /// `markDirty()` on every single frame of a drag, and pushing a history entry that often would
    /// flood the stack, `dragGesture`'s `onEnded` pushes one step for the whole drag instead.
    private func commit(_ label: String) {
        markDirty()
        pushHistory(label)
    }

    private func addZone(at pt: CGPoint) {
        let z = NSMBWZone(x: Int(pt.x), y: Int(pt.y), width: 400, height: 300, modelId: 0, cameraProfile: 0,
                           zoneId: nextId(area.zones, \.zoneId), boundingId: 0, cameraBoundingId: 0, bgId: 0,
                           visibility: 0, cameraModeId: 0, zoneType: 0, musicId: 0)
        area.zones.append(z)
        selection = .zone(area.zones.count - 1)
        commit("Add Zone")
    }

    private func addEntrance(at pt: CGPoint) {
        let e = NSMBWEntrance(x: Int(pt.x), y: Int(pt.y), entranceId: nextId(area.entrances, \.entranceId),
                               destArea: 0, destEntrance: 0, entranceType: 0, zoneId: 0, layerId: 0, pathId: 0,
                               settings: 0, leaveLevelValue: 0, coinPortalDirection: 0)
        area.entrances.append(e)
        selection = .entrance(area.entrances.count - 1)
        commit("Add Entrance")
    }

    private func addSprite(at pt: CGPoint) {
        let s = NSMBWSprite(spriteType: 0, x: Int(pt.x), y: Int(pt.y), settings: [UInt8](repeating: 0, count: 8))
        area.sprites.append(s)
        selection = .sprite(area.sprites.count - 1)
        commit("Add Sprite")
    }

    private func addLocation(at pt: CGPoint) {
        let l = NSMBWLocation(x: Int(pt.x), y: Int(pt.y), width: 128, height: 128, locationId: nextId(area.locations, \.locationId))
        area.locations.append(l)
        selection = .location(area.locations.count - 1)
        commit("Add Location")
    }

    private func addObject(at pt: CGPoint) {
        let o = NSMBWObject(tilesetIndex: 0, objectId: 0, layer: 1, x: Int(pt.x / 16), y: Int(pt.y / 16), width: 1, height: 1)
        area.objects.append(o)
        selection = .object(area.objects.count - 1)
        commit("Add Object")
    }

    private func addPath(at pt: CGPoint) {
        let node = NSMBWPathNode(x: Int(pt.x), y: Int(pt.y))
        let pathId = nextId(area.paths, \.pathId)
        area.paths.append(NSMBWPath(pathId: pathId, loops: false, nodes: [node]))
        selection = .pathNode(path: Int(pathId), node: 0)
        commit("Add Path")
    }

    private func deleteSelection() {
        guard let sel = selection else { return }
        switch sel {
        case .zone(let i): guard area.zones.indices.contains(i) else { return }; area.zones.remove(at: i)
        case .entrance(let i): guard area.entrances.indices.contains(i) else { return }; area.entrances.remove(at: i)
        case .sprite(let i): guard area.sprites.indices.contains(i) else { return }; area.sprites.remove(at: i)
        case .location(let i): guard area.locations.indices.contains(i) else { return }; area.locations.remove(at: i)
        case .object(let i): guard area.objects.indices.contains(i) else { return }; area.objects.remove(at: i)
        case .pathNode(let p, let n):
            guard let pi = area.paths.firstIndex(where: { Int($0.pathId) == p }), area.paths[pi].nodes.indices.contains(n) else { return }
            // A path with no nodes left has nothing to render/reference, so drop the whole path.
            if area.paths[pi].nodes.count <= 1 {
                area.paths.remove(at: pi)
            } else {
                area.paths[pi].nodes.remove(at: n)
            }
        }
        selection = nil
        commit("Delete")
    }

    // MARK: Inspector

    @ViewBuilder
    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Inspector").font(.headline).padding([.top, .horizontal]).padding(.bottom, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Group {
                        switch selection {
                        case .zone(let i) where area.zones.indices.contains(i):
                            zoneInspector(i)
                        case .entrance(let i) where area.entrances.indices.contains(i):
                            entranceInspector(i)
                        case .sprite(let i) where area.sprites.indices.contains(i):
                            spriteInspector(i)
                        case .location(let i) where area.locations.indices.contains(i):
                            locationInspector(i)
                        case .object(let i) where area.objects.indices.contains(i):
                            objectInspector(i)
                        case .pathNode(let p, let n):
                            pathNodeInspector(pathId: p, nodeIndex: n)
                        default:
                            Text("Select something on the canvas.").foregroundStyle(.secondary).padding(.horizontal)
                        }
                    }
                    Divider()
                    DisclosureGroup("Area \(area.areaNumber) settings", isExpanded: $areaSettingsExpanded) {
                        areaSettingsForm
                    }
                    .padding(.horizontal)
                    Divider()
                    Text("Area \(area.areaNumber) summary").font(.subheadline.bold()).padding(.horizontal)
                    VStack(alignment: .leading, spacing: 6) {
                        row("Zones", "\(area.zones.count)")
                        row("Objects", "\(area.objects.count)")
                        row("Sprites", "\(area.sprites.count)")
                        row("Entrances", "\(area.entrances.count)")
                        row("Locations", "\(area.locations.count)")
                        row("Paths", "\(area.paths.count)")
                    }
                    .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 12)
            }
        }
    }

    /// Every `NSMBWAreaOptions` field, plus the four tileset names, the "course time limit...
    /// everything" ask: previously only shown as a read-only "Time limit" row.
    private var areaSettingsForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            textField("Tileset 0", area.tilesetNames.slot0) { area.tilesetNames.slot0 = $0 }
            textField("Tileset 1", area.tilesetNames.slot1) { area.tilesetNames.slot1 = $0 }
            textField("Tileset 2", area.tilesetNames.slot2) { area.tilesetNames.slot2 = $0 }
            textField("Tileset 3", area.tilesetNames.slot3) { area.tilesetNames.slot3 = $0 }
            Divider()
            numberField("Time limit", Int(area.options.timeLimit)) { area.options.timeLimit = Int16(clamping: $0) }
            numberField("Start entr.", Int(area.options.startEntrance)) { area.options.startEntrance = UInt8(clamping: $0) }
            numberField("Toad house", Int(area.options.toadHouseType)) { area.options.toadHouseType = UInt8(clamping: $0) }
            numberField("Wrap set.", Int(area.options.wrapSettings)) { area.options.wrapSettings = UInt16(clamping: $0) }
            numberField("Unknown", Int(area.options.unknownByte)) { area.options.unknownByte = UInt8(clamping: $0) }
            Toggle("Credits flag", isOn: Binding(get: { area.options.creditsFlag }, set: { area.options.creditsFlag = $0; commit("Credits Flag") }))
            Toggle("Face left", isOn: Binding(get: { area.options.faceLeftFlag }, set: { area.options.faceLeftFlag = $0; commit("Face Left") }))
            numberField("Event bits lo", Int(area.options.eventBitsLow)) { area.options.eventBitsLow = UInt32(clamping: $0) }
            numberField("Event bits hi", Int(area.options.eventBitsHigh)) { area.options.eventBitsHigh = UInt32(clamping: $0) }
        }
        .padding(.top, 4)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label); Spacer(); Text(value).foregroundStyle(.secondary) }.font(.caption)
    }

    private func numberField(_ label: String, _ value: Int, set: @escaping (Int) -> Void) -> some View {
        HStack {
            Text(label).font(.caption).frame(width: 84, alignment: .leading)
            TextField(label, value: Binding(get: { value }, set: { set($0); commit(label) }), format: .number)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func textField(_ label: String, _ value: String, set: @escaping (String) -> Void) -> some View {
        HStack {
            Text(label).font(.caption).frame(width: 84, alignment: .leading)
            TextField(label, text: Binding(get: { value }, set: { set($0); commit(label) }))
                .textFieldStyle(.roundedBorder)
        }
    }

    private func zoneInspector(_ i: Int) -> some View {
        let z = area.zones[i]
        return VStack(alignment: .leading, spacing: 6) {
            Text("Zone \(z.zoneId)").font(.subheadline.bold())
            numberField("ID", Int(z.zoneId)) { area.zones[i].zoneId = UInt8(clamping: $0) }
            numberField("X", z.x) { area.zones[i].x = $0 }
            numberField("Y", z.y) { area.zones[i].y = $0 }
            numberField("Width", z.width) { area.zones[i].width = $0 }
            numberField("Height", z.height) { area.zones[i].height = $0 }
            numberField("Model ID", Int(z.modelId)) { area.zones[i].modelId = UInt16(clamping: $0) }
            numberField("Cam. prof.", Int(z.cameraProfile)) { area.zones[i].cameraProfile = UInt16(clamping: $0) }
            numberField("Bounding", Int(z.boundingId)) { area.zones[i].boundingId = UInt8(clamping: $0) }
            numberField("Cam. bound.", Int(z.cameraBoundingId)) { area.zones[i].cameraBoundingId = UInt8(clamping: $0) }
            numberField("Background", Int(z.bgId)) { area.zones[i].bgId = UInt8(clamping: $0) }
            numberField("Visibility", Int(z.visibility)) { area.zones[i].visibility = UInt8(clamping: $0) }
            numberField("Cam. mode", Int(z.cameraModeId)) { area.zones[i].cameraModeId = UInt8(clamping: $0) }
            numberField("Zone type", Int(z.zoneType)) { area.zones[i].zoneType = UInt8(clamping: $0) }
            numberField("Music", Int(z.musicId)) { area.zones[i].musicId = UInt8(clamping: $0) }
        }.padding(.horizontal)
    }

    private func entranceInspector(_ i: Int) -> some View {
        let e = area.entrances[i]
        return VStack(alignment: .leading, spacing: 6) {
            Text("Entrance \(e.entranceId)").font(.subheadline.bold())
            numberField("ID", Int(e.entranceId)) { area.entrances[i].entranceId = UInt8(clamping: $0) }
            numberField("X", e.x) { area.entrances[i].x = $0 }
            numberField("Y", e.y) { area.entrances[i].y = $0 }
            numberField("Type", Int(e.entranceType)) { area.entrances[i].entranceType = UInt8(clamping: $0) }
            numberField("Dest area", Int(e.destArea)) { area.entrances[i].destArea = UInt8(clamping: $0) }
            numberField("Dest entr.", Int(e.destEntrance)) { area.entrances[i].destEntrance = UInt8(clamping: $0) }
            numberField("Zone", Int(e.zoneId)) { area.entrances[i].zoneId = UInt8(clamping: $0) }
            numberField("Layer", Int(e.layerId)) { area.entrances[i].layerId = UInt8(clamping: $0) }
            numberField("Path", Int(e.pathId)) { area.entrances[i].pathId = UInt8(clamping: $0) }
            numberField("Settings", Int(e.settings)) { area.entrances[i].settings = UInt16(clamping: $0) }
            numberField("Leave val.", Int(e.leaveLevelValue)) { area.entrances[i].leaveLevelValue = UInt8(clamping: $0) }
            numberField("Coin dir.", Int(e.coinPortalDirection)) { area.entrances[i].coinPortalDirection = UInt8(clamping: $0) }
        }.padding(.horizontal)
    }

    private func spriteInspector(_ i: Int) -> some View {
        let s = area.sprites[i]
        return VStack(alignment: .leading, spacing: 6) {
            Text("Sprite type \(s.spriteType)").font(.subheadline.bold())
            numberField("Type", Int(s.spriteType)) { area.sprites[i].spriteType = UInt16(clamping: $0) }
            numberField("X", s.x) { area.sprites[i].x = $0 }
            numberField("Y", s.y) { area.sprites[i].y = $0 }
            Text("Settings (raw bytes)").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(0..<8, id: \.self) { b in
                    HexByteField(value: s.settings[b]) { newValue in
                        area.sprites[i].settings[b] = newValue
                        commit("Sprite Settings")
                    }
                }
            }
        }.padding(.horizontal)
    }

    private func locationInspector(_ i: Int) -> some View {
        let l = area.locations[i]
        return VStack(alignment: .leading, spacing: 6) {
            Text("Location \(l.locationId)").font(.subheadline.bold())
            numberField("ID", Int(l.locationId)) { area.locations[i].locationId = UInt8(clamping: $0) }
            numberField("X", l.x) { area.locations[i].x = $0 }
            numberField("Y", l.y) { area.locations[i].y = $0 }
            numberField("Width", l.width) { area.locations[i].width = $0 }
            numberField("Height", l.height) { area.locations[i].height = $0 }
        }.padding(.horizontal)
    }

    private func objectInspector(_ i: Int) -> some View {
        let o = area.objects[i]
        return VStack(alignment: .leading, spacing: 6) {
            Text("Object #\(o.objectId) (tileset \(o.tilesetIndex), layer \(o.layer))").font(.subheadline.bold())
            numberField("Tileset", o.tilesetIndex) { area.objects[i].tilesetIndex = max(0, min(3, $0)) }
            numberField("Object ID", o.objectId) { area.objects[i].objectId = max(0, min(0xFFF, $0)) }
            numberField("Layer", o.layer) { area.objects[i].layer = max(0, min(2, $0)) }
            numberField("X", o.x) { area.objects[i].x = $0 }
            numberField("Y", o.y) { area.objects[i].y = $0 }
            numberField("Width", o.width) { area.objects[i].width = $0 }
            numberField("Height", o.height) { area.objects[i].height = $0 }
        }.padding(.horizontal)
    }

    @ViewBuilder
    private func pathNodeInspector(pathId: Int, nodeIndex: Int) -> some View {
        if let pi = area.paths.firstIndex(where: { Int($0.pathId) == pathId }), area.paths[pi].nodes.indices.contains(nodeIndex) {
            let node = area.paths[pi].nodes[nodeIndex]
            VStack(alignment: .leading, spacing: 6) {
                Text("Path \(pathId), node \(nodeIndex + 1) of \(area.paths[pi].nodes.count)").font(.subheadline.bold())
                numberField("X", node.x) { area.paths[pi].nodes[nodeIndex].x = $0 }
                numberField("Y", node.y) { area.paths[pi].nodes[nodeIndex].y = $0 }
                HStack {
                    Text("Speed").font(.caption).frame(width: 84, alignment: .leading)
                    TextField("Speed", value: Binding(
                        get: { area.paths[pi].nodes[nodeIndex].speed },
                        set: { area.paths[pi].nodes[nodeIndex].speed = $0; commit("Speed") }), format: .number)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("Accel").font(.caption).frame(width: 84, alignment: .leading)
                    TextField("Accel", value: Binding(
                        get: { area.paths[pi].nodes[nodeIndex].accel },
                        set: { area.paths[pi].nodes[nodeIndex].accel = $0; commit("Accel") }), format: .number)
                        .textFieldStyle(.roundedBorder)
                }
                numberField("Delay", Int(node.delay)) { area.paths[pi].nodes[nodeIndex].delay = Int16(clamping: $0) }
                Toggle("Loops", isOn: Binding(get: { area.paths[pi].loops }, set: { area.paths[pi].loops = $0; commit("Loops") }))
                Divider()
                HStack {
                    Button("Add Node After") {
                        let newNode = NSMBWPathNode(x: node.x + 32, y: node.y)
                        area.paths[pi].nodes.insert(newNode, at: nodeIndex + 1)
                        selection = .pathNode(path: pathId, node: nodeIndex + 1)
                        commit("Add Path Node")
                    }
                    Button("Remove Path", role: .destructive) {
                        area.paths.remove(at: pi)
                        selection = nil
                        commit("Remove Path")
                    }
                }
            }.padding(.horizontal)
        } else {
            Text("Select something on the canvas.").foregroundStyle(.secondary).padding(.horizontal)
        }
    }
}

/// A single byte edited as two hex digits, committed on Enter/focus-loss rather than per keystroke
///, same discipline as `KCLEditorView`'s `HexFlagField`, so a half-typed hex value never briefly
/// parses as something wildly different and churns an edit into the document.
private struct HexByteField: View {
    let value: UInt8
    let onCommit: (UInt8) -> Void
    @State private var text: String
    @FocusState private var focused: Bool

    init(value: UInt8, onCommit: @escaping (UInt8) -> Void) {
        self.value = value
        self.onCommit = onCommit
        _text = State(initialValue: String(format: "%02X", value))
    }

    var body: some View {
        TextField("00", text: $text)
            .textFieldStyle(.roundedBorder)
            .frame(width: 32)
            .font(.system(.caption, design: .monospaced))
            .focused($focused)
            .onSubmit { commit() }
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
    }

    private func commit() {
        guard let v = UInt8(text.trimmingCharacters(in: .whitespaces), radix: 16), v != value else { return }
        onCommit(v)
    }
}
