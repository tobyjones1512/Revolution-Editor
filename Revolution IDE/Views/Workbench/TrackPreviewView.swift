import SwiftUI
import SceneKit
import AppKit
import Combine
import UniformTypeIdentifiers

/// What a `TrackPreviewWindowSession` shows, see `ProjectNavigatorView.beginPreviewTrack`. `id`
/// is the source's own path/name so re-invoking Preview Track on the same archive reuses/replaces
/// rather than stacks a second window (see `WorkbenchState.openTrackPreviewWindow`). `save` writes
/// the edited archive back to wherever it actually lives, a real file or a nested archive entry,
/// see `ProjectNavigatorView`'s two `beginPreviewTrack` overloads.
struct TrackPreviewRequest: Identifiable {
    let id: String
    let root: U8Node
    let sourceName: String
    let save: () -> Void
}

/// Resolves a Preview Track window's session from the id the `WindowGroup(for: UUID.self)` in
/// `RevolutionIDEApp` hands it, same indirection as `NSMBWWindowContainerView`/
/// `SZSWindowContainerView`, and for the same reason: `openWindow(id:value:)` can only pass a
/// `Hashable` value, not the session object itself.
struct TrackPreviewWindowContainerView: View {
    @EnvironmentObject var workbench: WorkbenchState
    let id: UUID?

    var body: some View {
        if let id, let session = workbench.trackPreviewWindowSessions[id] {
            TrackPreviewView(request: session.request)
                .navigationTitle("Edit Track in 3D. \(session.request.sourceName)")
        } else {
            VStack(spacing: 8) {
                Image(systemName: "video.3d").font(.system(size: 32)).foregroundStyle(.tertiary)
                Text("This preview is no longer available.").foregroundStyle(.secondary)
                Text("Close this window and reopen it from the project navigator.").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// "Preview Track": a textured 3D view of a course archive built from its own real files, and a
/// full KMP editor in 3D, every KMP entry is a clickable marker, edited with the *same*
/// inspector the 2D KMP editor uses (`KMPInspectorFields`, `KMPStageInfoFields`) and added/removed
/// through the same shared logic (`KMPDocumentBox.addPoint`/`remove`), so the two can't disagree.
/// Every edit is written straight back into the archive's `course.kmp` and saved.
///
/// Navigation is SketchUp/Blender-style (see `NavigationSCNView`): orbit around the point under the
/// cursor, pan, zoom toward the cursor, frame selection/track, preset views, WASD fly.
struct TrackPreviewView: View {
    @ObservedObject private var controls = Controls.shared
    let request: TrackPreviewRequest
    private var root: U8Node { request.root }
    private var sourceName: String { request.sourceName }

    @State private var built: BuiltPreview?
    @State private var loadError: String?
    @State private var kmpBox: KMPDocumentBox?
    @State private var moveSpeed: Float = 500
    @State private var moveSpeedRange: ClosedRange<Float> = 50...5000
    @State private var command: NavigationCommand?
    @State private var layerVisibility: [Layer: Bool] = Dictionary(uniqueKeysWithValues: Layer.allCases.map { ($0, $0.visibleByDefault) })
    @State private var isPlacing = false
    @State private var placeSection: KMPSection = .gobj
    @State private var placeObjectID: UInt16 = 0x0065 // Item Box, the most common custom-track addition
    /// Which KMP entry each clickable node stands for, rebuilt with the KMP layers.
    @State private var selectionByNode: [ObjectIdentifier: KMPSelection] = [:]
    /// Loaded object models by object ID, cloned per placement; `nil` means "no bundled model".
    @State private var objectTemplates: [UInt16: SCNNode?] = [:]
    @State private var selectionIndicator = TrackPreviewView.makeSelectionIndicator()
    @State private var showControls = false
    /// Driver's View: the camera rides the CPU route at eye height. Nil when off.
    @State private var driverPath: DriverPath?
    @State private var drivePaused = false
    @State private var driveSpeed: Float = 4500
    @State private var driveLap = 1
    @State private var driveRestart = 0
    /// The branch taken at each fork so far (by the enemy-path group that ends there).
    @State private var driveChoices: [Int: Int] = [:]
    /// The fork the driver is stopped at, waiting for a choice.
    @State private var driveFork: DriverPath.Fork?
    @State private var layersBeforeDrive: [Layer: Bool]?
    /// Edit mode selects, moves, adds and deletes KMP entries; View mode only looks.
    @AppStorage("trackPreviewEditing") private var isEditing = false
    private var canEdit: Bool { isEditing && !renderMode && driverPath == nil }
    /// Cmd-click selection, for Straighten / Equalise Gaps / Snap to Ground on several points.
    @State private var multiSelection: Set<KMPSelection> = []
    @State private var multiIndicators = SCNNode()
    /// Undo/redo + history list, the same `EditHistory` the KMP editor uses. Snapshots course.kmp
    /// each time an edit is committed (drag end, add, delete, snap, inspector change).
    @State private var history: EditHistory?
    @State private var historyLabel = "Edit Properties"
    @State private var isRestoring = false
    /// Edits live in the archive in memory until Save (or closing the window, which saves too).
    @State private var hasUnsavedChanges = false
    /// Create Render: KMP markers hidden, render lighting/look applied, export panel in the inspector.
    @State private var renderMode = false
    @State private var renderSettings = RenderSettings()
    @State private var layersBeforeRender: [Layer: Bool]?
    @State private var viewportSize: CGSize = .zero
    @State private var renderError: String?

    enum Layer: String, CaseIterable, Identifiable {
        case course = "Course Model", background = "Background", objects = "Objects", startPoints = "Start Points"
        case minimap = "Minimap", enemyPaths = "Enemy Paths", itemPaths = "Item Paths", checkpoints = "Checkpoints"
        case respawns = "Respawn Points", routes = "Routes", cameras = "Cameras", areas = "Areas", cannons = "Cannon Points", battleStarts = "Battle Starts"
        var id: String { rawValue }
        var visibleByDefault: Bool { ![.routes, .cameras, .areas].contains(self) }
        static let kmpLayers: [Layer] = [.objects, .startPoints, .enemyPaths, .itemPaths, .checkpoints, .respawns, .routes, .cameras, .areas, .cannons, .battleStarts]
    }

    enum NavigationCommand: Equatable {
        case returnToStart, frameTrack, frameSelection, top, front, side, toggleOrtho
    }

    struct BuiltPreview {
        let scene: SCNScene
        let moveSpeed: Float
        let startPosition: SCNVector3
        let startLookAt: SCNVector3
        let boundsMin: SIMD3<Float>
        let boundsMax: SIMD3<Float>
        let layerNodes: [Layer: SCNNode]
        let minimapModel: MDL0Model?
        let minimapBounds: (minX: Float, maxX: Float, minZ: Float, maxZ: Float)?
        let kmp: (doc: KMPDocument, node: U8Node)?
        let objectTemplates: [UInt16: SCNNode?]
        /// `course.kcl`, for Snap to Ground.
        let collision: KCLDocument?
    }

    /// Sections that can be placed by clicking the track, in the same order as the KMP editor's + menu.
    private static let placeableSections: [KMPSection] = [.gobj, .ktpt, .enpt, .itpt, .ckpt, .jgpt, .cnpt, .mspt, .area, .came]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    content
                        .background(GeometryReader { g in
                            Color.clear.onAppear { viewportSize = g.size }.onChange(of: g.size) { _, s in viewportSize = s }
                        })
                    if renderMode {
                        RenderFrameGuide(aspect: CGFloat(max(renderSettings.width, 1)) / CGFloat(max(renderSettings.height, 1)))
                    }
                    if !renderMode, let built, let minimapModel = built.minimapModel, let bounds = built.minimapBounds, layerVisibility[.minimap] == true {
                        MinimapOverlay(model: minimapModel, bounds: bounds)
                            .frame(width: 150, height: 150)
                            .padding(14)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    }
                    if isPlacing {
                        Text("Click the track to add \(placeSection == .gobj ? "\"\(kmpBox?.doc.isBOL == true ? BOL.objectName(placeObjectID) : gobjFriendlyName(placeObjectID))\"" : "a \(placeSection.displayName)")")
                            .font(.caption).bold()
                            .padding(8)
                            .background(.bar, in: RoundedRectangle(cornerRadius: 8))
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .top)
                    }
                    if showControls { controlsCard.padding(14) }
                    if driverPath != nil {
                        VStack(spacing: 8) {
                            if let driveFork { forkChooser(driveFork) }
                            driveBar
                        }
                        .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    }
                    if canEdit, let history {
                        HistoryControlsView(history: history, onRestore: restoreFromHistory)
                            .padding(6)
                            .background(.bar, in: RoundedRectangle(cornerRadius: 8))
                            .padding(14)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: showControls ? .topLeading : .bottomLeading)
                    }
                    if !renderMode, let kmpBox, !kmpBox.doc.isBOL {
                        MissingObjectFilesBanner(objectIDs: Set(kmpBox.doc.gobj.map(\.objectID)),
                                                 present: { BaseGameLibrary.names(in: root) },
                                                 install: installObjectFiles)
                            .padding(.top, 14)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    } else if !renderMode, let kmpBox {
                        MissingDoubleDashObjectFilesBanner(objectIDs: Set(kmpBox.doc.gobj.map(\.objectID)),
                                                           present: { Set((root.children.first { $0.isDirectory && $0.name.lowercased() == "objects" }?.children ?? []).map { $0.name.lowercased() }) },
                                                           install: installObjectFiles)
                            .padding(.top, 14)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                }
                .layoutPriority(1)
                if renderMode || isEditing {
                    Divider()
                    Group {
                        if renderMode {
                            TrackRenderPanel(settings: $renderSettings, hasSkybox: !(built?.layerNodes[.background]?.childNodes.isEmpty ?? true),
                                             onExport: exportRender, onCopy: copyRender, onDone: { setRenderMode(false) })
                        } else {
                            inspector
                        }
                    }
                    .frame(width: 300)
                }
            }
        }
        .task { build() }
        .onChange(of: renderSettings) { _, _ in if renderMode { applyRenderSettings() } }
        .alert("Couldn't create the render", isPresented: Binding(get: { renderError != nil }, set: { if !$0 { renderError = nil } })) {
            Button("OK") { renderError = nil }
        } message: { Text(renderError ?? "") }
        // Closing the window never throws edits away.
        .onDisappear { if hasUnsavedChanges { request.save() } }
    }

    private func save() {
        request.save()
        hasUnsavedChanges = false
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack {
            Text(sourceName).font(.headline)
            if built != nil, !renderMode, kmpBox != nil {
                Picker("Mode", selection: Binding(get: { isEditing }, set: { setEditing($0) })) {
                    Label("View", systemImage: "eye").tag(false)
                    Label("Edit", systemImage: "pencil").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("View: look around and drive the course. KMP points can't be selected or moved. Edit: select, move, add and delete KMP points.")
            }
            Spacer()
            if built != nil, renderMode {
                Text("Frame your shot, then Export PNG in the panel on the right.").font(.caption).foregroundStyle(.secondary)
            } else if built != nil {
                Button { setRenderMode(true) } label: { Label("Create Render", systemImage: "camera.aperture") }
                    .help("Make a high-quality picture of the track: hides every KMP marker, shows the textured course with adjustable sun, sky light, shadows, fog and camera effects, and exports a PNG at up to 8K.")
                Divider().frame(height: 16)
                if kmpBox != nil, isEditing {
                    Picker("Tool", selection: $isPlacing) {
                        Label("Select", systemImage: "cursorarrow").tag(false)
                        Label("Add", systemImage: "plus.circle").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .help("Select: click placed objects/points to select them, drag a box for several. Add: click the track to add the chosen kind of KMP point there.")
                    if isPlacing {
                        Picker("", selection: $placeSection) {
                            ForEach(Self.placeableSections, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden().frame(width: 150)
                        if placeSection == .gobj {
                            ObjectTypeMenu(selection: placeObjectID, doubleDash: kmpBox?.doc.isBOL == true, install: installObjectFiles) { placeObjectID = $0 }
                                .frame(width: 220)
                        }
                    }
                    Divider().frame(height: 16)
                }
                if isEditing || hasUnsavedChanges {
                    Button("Save") { save() }
                        .shortcut(.save)
                        .disabled(!hasUnsavedChanges)
                        .help("Write the edited archive to disk (\(Controls.shared.keys(.save))). Closing the window also saves.")
                    if hasUnsavedChanges { Text("Edited").font(.caption).foregroundStyle(.orange) }
                    Divider().frame(height: 16)
                }
                Button { toggleDriversView() } label: {
                    Label("Driver's View", systemImage: driverPath == nil ? "steeringwheel" : "xmark.circle")
                }
                .help(driverPath == nil
                      ? "Ride round the course from a racer's seat, following the CPU route (enemy path), to see the track the way a driver does. KMP markers are hidden while driving, and where the route splits you choose which way to go."
                      : "Leave Driver's View and return to free navigation (Esc).")
                .disabled(kmpBox.map { $0.doc.enpt.count < 2 && $0.doc.ckpt.count < 2 } ?? true)
                Button { command = .returnToStart } label: { Label("Reset View", systemImage: "arrow.counterclockwise") }
                    .help("Put the camera back where it started (0).")
                Menu("Camera") {
                    Button("Frame Selection (F)") { command = .frameSelection }
                    Button("Frame Whole Track (H)") { command = .frameTrack }
                    Button("Return to Start (0)") { command = .returnToStart }
                    Divider()
                    Button("Top (7)") { command = .top }
                    Button("Front (1)") { command = .front }
                    Button("Side (3)") { command = .side }
                    Button("Toggle Orthographic (5)") { command = .toggleOrtho }
                }
                .menuStyle(.borderlessButton).fixedSize()
                Menu("Layers") {
                    ForEach(Layer.allCases) { layer in
                        Toggle(layer.rawValue, isOn: Binding(get: { layerVisibility[layer] ?? true }, set: { setLayer(layer, visible: $0) }))
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
                Divider().frame(height: 16)
                Text("Fly").font(.caption).foregroundStyle(.secondary)
                Slider(value: $moveSpeed, in: moveSpeedRange).frame(width: 90)
                    .help("Fly speed (\(Controls.shared.keys(.flyForward))\(Controls.shared.keys(.flyLeft))\(Controls.shared.keys(.flyBack))\(Controls.shared.keys(.flyRight))/\(Controls.shared.keys(.flyDown))\(Controls.shared.keys(.flyUp)); hold \(Controls.shared.modifierName(.view3DFlyFast)) for 4x).")
                Button { showControls.toggle() } label: { Image(systemName: "questionmark.circle") }
                    .buttonStyle(.borderless)
                    .help("Navigation controls")
            }
        }
        .padding(10)
    }

    // MARK: Create Render

    private var trackExtent: Float {
        guard let built else { return 10_000 }
        let d = built.boundsMax - built.boundsMin
        return max(d.x, d.y, d.z, 1000)
    }

    private func setRenderMode(_ on: Bool) {
        guard let built, on != renderMode else { return }
        renderMode = on
        if on {
            driverPath = nil
            isPlacing = false
            kmpBox?.selection = nil
            multiSelection = []
            layersBeforeRender = layerVisibility
            selectionIndicator.isHidden = true
            multiIndicators.isHidden = true
            applyRenderSettings()
        } else {
            TrackRender.apply(nil, to: built.scene, extent: trackExtent, sky: built.layerNodes[.background])
            multiIndicators.isHidden = false
            for (layer, visible) in layersBeforeRender ?? layerVisibility { setLayer(layer, visible: visible) }
            layersBeforeRender = nil
        }
    }

    private func applyRenderSettings() {
        guard let built else { return }
        TrackRender.apply(renderSettings, to: built.scene, extent: trackExtent, sky: built.layerNodes[.background])
        for layer in Layer.allCases {
            let visible: Bool = switch layer {
            case .course: true
            case .background: renderSettings.background == .skybox
            case .objects: renderSettings.showObjects
            default: false
            }
            built.layerNodes[layer]?.isHidden = !visible
        }
    }

    private func renderImage() -> NSImage? {
        guard let built else { return nil }
        let aspect = CGFloat(renderSettings.width) / CGFloat(renderSettings.height)
        let frame = RenderFrameGuide.frame(in: viewportSize, aspect: aspect)
        let fraction = viewportSize.height > 0 ? frame.height / viewportSize.height : 1
        return TrackRender.render(scene: built.scene, width: renderSettings.width, height: renderSettings.height,
                                  supersample: renderSettings.supersample, guideFraction: fraction)
    }

    private func exportRender() {
        PanelPresenter.saveFile(configure: {
            $0.allowedContentTypes = [.png]
            $0.nameFieldStringValue = (sourceName as NSString).deletingPathExtension + " render.png"
        }) { url in
            guard let url else { return }
            guard let image = renderImage(), let png = TrackRender.pngData(image) else {
                renderError = "The renderer didn't produce an image, try a smaller size or turn off Supersample."
                return
            }
            do { try png.write(to: url, options: .atomic) } catch { renderError = error.localizedDescription }
        }
    }

    private func copyRender() {
        guard let image = renderImage() else { renderError = "The renderer didn't produce an image."; return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    private func toggleDriversView() {
        if driverPath != nil {
            driverPath = nil
            driveFork = nil
            for (layer, visible) in layersBeforeDrive ?? layerVisibility { setLayer(layer, visible: visible) }
            layersBeforeDrive = nil
            return
        }
        guard let kmpBox else { return }
        driveChoices = [:]
        guard let path = DriverPath(kmp: kmpBox.doc, collision: built?.collision) else { return }
        // A driver sees the course and its objects, not the KMP markers.
        layersBeforeDrive = layerVisibility
        for layer in Layer.kmpLayers where layer != .objects { built?.layerNodes[layer]?.isHidden = true }
        isPlacing = false
        kmpBox.selection = nil
        multiSelection = []
        selectionIndicator.isHidden = true
        drivePaused = false
        driveFork = nil
        driveLap = 1
        driveRestart += 1
        driverPath = path
    }

    /// Takes a branch at the fork the driver is stopped at and drives on.
    private func chooseBranch(_ group: Int, at fork: DriverPath.Fork) {
        driveChoices[fork.group] = group
        if let kmpBox, let path = DriverPath(kmp: kmpBox.doc, collision: built?.collision, choices: driveChoices) { driverPath = path }
        driveFork = nil
    }

    private func forkChooser(_ fork: DriverPath.Fork) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
            Text("Which way?").font(.callout.bold())
            ForEach(fork.options, id: \.group) { option in
                Button(option.label) { chooseBranch(option.group, at: fork) }
                    .help("Take this branch (enemy path group \(option.group + 1)).")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar, in: Capsule())
    }

    private var driveBar: some View {
        HStack(spacing: 10) {
            Button { drivePaused.toggle() } label: { Image(systemName: drivePaused ? "play.fill" : "pause.fill") }
                .help("Pause or resume (Space)")
            Button { driveRestart += 1; driveLap = 1; driveFork = nil } label: { Image(systemName: "backward.end.fill") }
                .help("Back to the start line")
            Text("Lap \(driveLap)").font(.caption.monospacedDigit().bold())
            Divider().frame(height: 14)
            Text("Speed").font(.caption).foregroundStyle(.secondary)
            Slider(value: $driveSpeed, in: 1000...12000).frame(width: 120)
                .help("Driving speed. A 150cc kart's top speed is roughly 4500 units a second. Boost panels, boost ramps and jump pads in the collision (course.kcl) speed you up and launch you as they would in-game.")
            Button("Exit") { toggleDriversView() }
                .help("Back to free navigation (Esc)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar, in: Capsule())
    }

    private var controlsCard: some View {
        let c = Controls.shared
        return VStack(alignment: .leading, spacing: 3) {
            Text("Navigation").font(.caption.bold())
            Group {
                Text("Drag, orbit around the point under the cursor (View mode)")
                Text("Middle-drag or \(c.phrase(.view3DOrbitRight, "right-drag")), orbit (\(c.phrase(.view3DPan, "middle-drag")): pan)")
                Text("\(c.phrase(.view3DPan, "drag")) / right-drag, pan")
                Text("Scroll wheel / pinch, zoom toward the cursor")
                Text("Trackpad two-finger swipe, orbit (\(c.modifierName(.view3DPan).isEmpty ? "plain" : c.modifierName(.view3DPan)): pan)")
                Text("Double-click, centre on that point")
                Text("\(c.keys(.frameSelection)) frame selection, \(c.keys(.frameTrack)) whole track, \(c.keys(.returnToStart)) start")
                Text("\(c.keys(.viewTop)) top, \(c.keys(.viewFront)) front, \(c.keys(.viewSide)) side, \(c.keys(.toggleOrtho)) orthographic")
                Text("\(c.keys(.flyForward))\(c.keys(.flyLeft))\(c.keys(.flyBack))\(c.keys(.flyRight)) fly, \(c.keys(.flyDown))/\(c.keys(.flyUp)) down/up, hold \(c.modifierName(.view3DFlyFast).isEmpty ? "nothing" : c.modifierName(.view3DFlyFast)) for faster")
                Text("Edit mode: click a marker to select, \(c.phrase(.view3DBoxSelect, "drag").lowercased()) a box or \(c.phrase(.view3DBoxSelect, "click").lowercased()) for several, \(c.keys(.deleteSelection)) to remove")
                Text("Driver's View: Space pause, Esc exit")
                Text("\(c.keys(.undo)) undo, \(c.keys(.redo)) redo")
                Text("Arrows move, rings rotate; drag a selected marker to slide it")
                Text("  \(c.modifierName(.view3DStraight).isEmpty ? "Plain" : c.modifierName(.view3DStraight)): straight line, \(c.modifierName(.view3DFaceCursor).isEmpty ? "plain" : c.modifierName(.view3DFaceCursor)): face the cursor")
            }
            .font(.caption2)
        }
        .padding(10)
        .background(.bar, in: RoundedRectangle(cornerRadius: 8))
    }

    private func setLayer(_ layer: Layer, visible: Bool) {
        layerVisibility[layer] = visible
        built?.layerNodes[layer]?.isHidden = !visible
    }

    // MARK: Scene

    @ViewBuilder
    private var content: some View {
        if let built {
            SceneKitPreview(scene: built.scene, moveSpeed: $moveSpeed, command: $command,
                            startPosition: built.startPosition, startLookAt: built.startLookAt,
                            boundsMin: built.boundsMin, boundsMax: built.boundsMax,
                            selectionFocus: selectionFocus,
                            onClick: handleClick,
                            onDelete: deleteSelection,
                            gizmoTarget: gizmoTarget,
                            isSelectedNode: isSelectedNode,
                            onTranslate: translateSelection,
                            onRotate: rotateSelection,
                            onYawToward: yawSelection,
                            onManipulationEnd: { historyLabel = "Move/Rotate"; kmpBox?.isDirty = true; kmpBox?.objectWillChange.send() },
                            onMarquee: marqueeSelect,
                            contextDelete: contextDelete,
                            onDeleteHit: deleteHit,
                            editable: canEdit,
                            driverPath: driverPath, drivePaused: drivePaused, driveSpeed: driveSpeed, driveRestart: driveRestart,
                            driveForkPending: driveFork != nil,
                            onDriveFork: { driveFork = $0 },
                            onDriveLap: { driveLap = $0 },
                            onDriveKey: { key in
                                switch key {
                                case .togglePause: drivePaused.toggle()
                                case .exit: toggleDriversView()
                                }
                            })
                .background(Color.black)
                .onReceive(kmpBox?.objectWillChange.eraseToAnyPublisher().debounce(for: .milliseconds(120), scheduler: RunLoop.main).eraseToAnyPublisher()
                           ?? Empty().eraseToAnyPublisher()) { _ in kmpChanged() }
        } else if let loadError {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
                Text(loadError).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.85))
        } else {
            ProgressView("Building preview...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.85))
        }
    }

    private func setEditing(_ on: Bool) {
        isEditing = on
        guard !on else { return }
        isPlacing = false
        kmpBox?.selection = nil
        multiSelection = []
        updateSelectionIndicator()
    }

    private func handleClick(_ hit: SCNHitTestResult?, _ command: Bool) {
        guard !renderMode, let kmpBox else { return }
        if isPlacing, let existing = hit.flatMap({ selection(for: $0.node) }) {
            // Clicking an existing marker selects it rather than stacking a new point on it.
            multiSelection = []
            kmpBox.selection = existing
            updateSelectionIndicator()
            return
        }
        if isPlacing {
            guard let hit else { return }
            let p = hit.worldCoordinates
            historyLabel = "Add \(placeSection.displayName)"
            if kmpBox.addPoint(placeSection, at: Vec3(x: Float(p.x), y: Float(p.y), z: Float(p.z))),
               placeSection == .gobj, case .gobj(let i) = kmpBox.selection {
                kmpBox.doc.gobj[i].objectID = placeObjectID
            }
            return
        }
        var node = hit?.node
        var clicked: KMPSelection?
        while let n = node, clicked == nil {
            clicked = selectionByNode[ObjectIdentifier(n)]
            node = n.parent
        }
        if command {
            // Cmd-click adds/removes points from a multi-selection, as marquee/Cmd does in 2D.
            if multiSelection.isEmpty, let current = kmpBox.selection { multiSelection.insert(current) }
            if let clicked { if multiSelection.contains(clicked) { multiSelection.remove(clicked) } else { multiSelection.insert(clicked) } }
            kmpBox.selection = multiSelection.count == 1 ? multiSelection.first : nil
            if multiSelection.count <= 1 { multiSelection = [] }
        } else {
            multiSelection = []
            kmpBox.selection = clicked
        }
        updateSelectionIndicator()
    }

    /// The KMP entry a scene node (or any of its ancestors) stands for.
    private func selection(for node: SCNNode) -> KMPSelection? {
        var n: SCNNode? = node
        while let cur = n {
            if let sel = selectionByNode[ObjectIdentifier(cur)] { return sel }
            n = cur.parent
        }
        return nil
    }

    /// Right-click menu: what deleting the clicked marker would do, if it can be deleted.
    private func contextDelete(_ hit: SCNHitTestResult) -> (title: String, enabled: Bool)? {
        guard let kmpBox, let sel = selection(for: hit.node) else { return nil }
        let name: String
        if case .gobj(let i) = sel.asPoint, kmpBox.doc.gobj.indices.contains(i) { name = kmpBox.doc.objectName(kmpBox.doc.gobj[i].objectID) }
        else { name = Self.section(of: sel)?.displayName ?? "Point" }
        return kmpBox.canRemove(sel) ? ("Delete \(name)", true) : ("Can't delete, only the last point of a path can be removed", false)
    }

    private static func section(of sel: KMPSelection) -> KMPSection? {
        switch sel.asPoint {
        case .ktpt: return .ktpt
        case .enpt: return .enpt
        case .itpt: return .itpt
        case .ckpt: return .ckpt
        case .gobj: return .gobj
        case .jgpt: return .jgpt
        case .cnpt: return .cnpt
        case .mspt: return .mspt
        case .area: return .area
        case .came: return .came
        case .poti: return .poti
        default: return nil
        }
    }

    private func deleteHit(_ hit: SCNHitTestResult) {
        guard let kmpBox, let sel = selection(for: hit.node) else { return }
        multiSelection = []
        kmpBox.selection = sel
        deleteSelection()
    }

    // MARK: History

    private func restoreFromHistory(_ data: Data) {
        guard let kmpBox, let doc = try? KMPDocument.parse(data) else { return }
        kmpBox.doc = doc
        kmpBox.selection = nil
        multiSelection = []
        isRestoring = true
        kmpBox.isDirty = true
        kmpBox.objectWillChange.send()
    }

    // MARK: Base game objects

    /// Copies imported object files into this course archive, saves it, and shows their models.
    private func installObjectFiles(_ files: [(path: [String], data: Data)]) {
        for f in files { root.setFile(at: f.path, data: f.data) }
        hasUnsavedChanges = true
        objectTemplates = [:] // reload models so newly imported ones replace placeholders
        rebuildKMPLayers()
    }

    // MARK: Marquee

    /// Cmd-drag box: selects every visible KMP marker whose centre lands inside it.
    private func marqueeSelect(_ rect: CGRect, _ project: (SIMD3<Float>) -> CGPoint?) {
        guard let built, let kmpBox else { return }
        var picked = Set<KMPSelection>()
        for layer in Layer.kmpLayers where layerVisibility[layer] ?? true {
            for node in built.layerNodes[layer]?.childNodes ?? [] {
                guard let sel = selectionByNode[ObjectIdentifier(node)], let pt = project(node.simdWorldPosition), rect.contains(pt) else { continue }
                picked.insert(sel.asPoint)
            }
        }
        multiSelection = picked.count > 1 ? picked : []
        kmpBox.selection = picked.count == 1 ? picked.first : nil
        updateSelectionIndicator()
    }

    // MARK: Gizmo

    private func gizmoTarget() -> GizmoTarget? {
        guard let kmpBox, let sel = kmpBox.selection, let p = kmpBox.doc.position3D(of: sel) else { return nil }
        let isGate: Bool = { if case .ckpt = sel.asPoint { return true }; return false }()
        let rot = kmpBox.doc.rotation(of: sel) ?? Vec3()
        return GizmoTarget(position: SIMD3(p.x, p.y, p.z), rotation: SIMD3(rot.x, rot.y, rot.z),
                           translate: [true, !isGate, true], rotate: kmpBox.doc.rotationAxes(of: sel))
    }

    private func isSelectedNode(_ node: SCNNode) -> Bool {
        guard let sel = kmpBox?.selection else { return false }
        var n: SCNNode? = node
        while let cur = n {
            if selectionByNode[ObjectIdentifier(cur)] == sel { return true }
            n = cur.parent
        }
        return false
    }

    private func selectedNodes() -> [SCNNode] {
        guard let built, let sel = kmpBox?.selection else { return [] }
        return Layer.kmpLayers.flatMap { built.layerNodes[$0]?.childNodes ?? [] }.filter { selectionByNode[ObjectIdentifier($0)] == sel }
    }

    private func translateSelection(_ d: SIMD3<Float>) {
        guard let kmpBox, let sel = kmpBox.selection else { return }
        let isGate: Bool = { if case .ckpt = sel.asPoint { return true }; return false }()
        let delta = SIMD3(d.x, isGate ? 0 : d.y, d.z)
        kmpBox.doc.translate(sel, dx: delta.x, dy: delta.y, dz: delta.z)
        for n in selectedNodes() { n.simdPosition += delta }
        kmpBox.objectWillChange.send()
    }

    private func rotateSelection(axis: Int, degrees: Float) {
        guard let kmpBox, let sel = kmpBox.selection, var r = kmpBox.doc.rotation(of: sel) else { return }
        switch axis { case 0: r.x += degrees; case 1: r.y += degrees; default: r.z += degrees }
        kmpBox.doc.setRotation(sel, r)
        showRotation(sel)
    }

    /// Alt-drag: turn to face the cursor, exactly like the 2D editor (0 = +Z, 90 = +X).
    private func yawSelection(toward h: SIMD3<Float>) {
        guard let kmpBox, let sel = kmpBox.selection, let p = kmpBox.doc.position3D(of: sel),
              var r = kmpBox.doc.rotation(of: sel), kmpBox.doc.rotationAxes(of: sel)[1] else { return }
        r.y = atan2(h.x - p.x, h.z - p.z) * 180 / .pi
        kmpBox.doc.setRotation(sel, r)
        showRotation(sel)
    }

    /// Live feedback while rotating; the full redraw happens when the drag ends.
    private func showRotation(_ sel: KMPSelection) {
        guard let kmpBox, let r = kmpBox.doc.rotation(of: sel) else { return }
        if case .ckpt = sel.asPoint { rebuildKMPLayers() }
        for n in selectedNodes() {
            n.eulerAngles = SCNVector3(CGFloat(r.x * .pi / 180), CGFloat(r.y * .pi / 180), CGFloat(r.z * .pi / 180))
        }
        kmpBox.objectWillChange.send()
    }

    private func snapToGround(_ selections: Set<KMPSelection>) {
        guard let kmpBox, let collision = built?.collision else { return }
        var moved = false
        for sel in selections { moved = kmpBox.doc.snapToGround(sel, collision: collision) || moved }
        guard moved else { return }
        historyLabel = "Snap to Ground"
        kmpBox.isDirty = true
        kmpBox.objectWillChange.send()
    }

    private func alignMulti(_ label: String, _ op: (KMPDocument, Set<KMPSelection>) -> Void) {
        guard let kmpBox else { return }
        historyLabel = label
        op(kmpBox.doc, multiSelection)
        kmpBox.isDirty = true
        kmpBox.objectWillChange.send()
    }

    private func deleteSelection() {
        guard let kmpBox, let sel = kmpBox.selection, kmpBox.canRemove(sel) else { return }
        historyLabel = "Remove Point"
        kmpBox.remove(sel)
    }

    /// Where the current selection is, and roughly how big, for Frame Selection.
    private func selectionFocus() -> (SIMD3<Float>, Float)? {
        guard let kmpBox, let sel = kmpBox.selection, let p = kmpBox.doc.position3D(of: sel) else { return nil }
        return (SIMD3(p.x, p.y, p.z), 2500)
    }

    /// Any edit (inspector, add, remove) lands here: write course.kmp back into the archive, save,
    /// and redraw the KMP markers. Selection-only changes just move the highlight.
    private func kmpChanged() {
        guard let kmpBox, let built, let kmp = built.kmp else { return }
        if kmpBox.isDirty {
            let data = kmpBox.doc.serialize()
            kmp.node.data = data
            kmpBox.isDirty = false
            if !isRestoring { history?.push(data, label: historyLabel) }
            isRestoring = false
            historyLabel = "Edit Properties"
            hasUnsavedChanges = true
            rebuildKMPLayers()
        }
        updateSelectionIndicator()
    }

    private func rebuildKMPLayers() {
        guard let built, let kmpBox else { return }
        for layer in Layer.kmpLayers { built.layerNodes[layer]?.childNodes.forEach { $0.removeFromParentNode() } }
        var templates = objectTemplates
        selectionByNode = Self.addKMPNodes(kmpBox.doc, root: root, layerNodes: built.layerNodes, templates: &templates)
        objectTemplates = templates
    }

    private func updateSelectionIndicator() {
        guard let built else { return }
        if selectionIndicator.parent == nil { built.scene.rootNode.addChildNode(selectionIndicator) }
        if multiIndicators.parent == nil { built.scene.rootNode.addChildNode(multiIndicators) }
        multiIndicators.childNodes.forEach { $0.removeFromParentNode() }
        if let kmpBox {
            for sel in multiSelection {
                guard let p = kmpBox.doc.position3D(of: sel) else { continue }
                let ring = selectionIndicator.clone()
                ring.isHidden = false
                ring.simdPosition = SIMD3(p.x, p.y, p.z)
                multiIndicators.addChildNode(ring)
            }
        }
        guard let kmpBox, let sel = kmpBox.selection, let p = kmpBox.doc.position3D(of: sel) else {
            selectionIndicator.isHidden = true
            return
        }
        selectionIndicator.isHidden = false
        selectionIndicator.simdPosition = SIMD3(p.x, p.y, p.z)
    }

    private static func makeSelectionIndicator() -> SCNNode {
        let ring = SCNTorus(ringRadius: 650, pipeRadius: 60)
        let m = SCNMaterial()
        m.diffuse.contents = NSColor.white
        m.emission.contents = NSColor.white
        m.lightingModel = .constant
        m.readsFromDepthBuffer = false // always visible, even inside geometry
        ring.materials = [m]
        let node = SCNNode(geometry: ring)
        node.renderingOrder = 100
        node.categoryBitMask = 4 // never picked by clicks or orbit pivots
        node.isHidden = true
        return node
    }

    // MARK: Inspector

    @ViewBuilder
    private var inspector: some View {
        if let kmpBox {
            TrackPreviewInspector(box: kmpBox, layerVisibility: $layerVisibility, setLayer: setLayer,
                                  multiSelection: multiSelection, canSnap: built?.collision != nil,
                                  snap: snapToGround,
                                  straighten: { alignMulti("Straighten Selected Points") { $0.straighten($1) } },
                                  equalise: { alignMulti("Equalise Selected Gaps") { $0.equaliseGaps($1) } },
                                  installObjectFiles: installObjectFiles)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Inspector").font(.headline)
                Text(built == nil ? "Loading..." : "This archive has no readable course.kmp, so there's nothing to edit.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Building

    private enum BuildOutcome {
        case success(BuiltPreview)
        case failure(String)
    }

    private func build() {
        guard let courseData = Self.file(root, "course_model.brres", orSuffix: "_course.bmd")?.data else {
            loadError = "This archive has no course_model.brres (or Double Dash *_course.bmd) at its top level, there's no course model to preview."
            return
        }
        let root = self.root
        Task.detached(priority: .userInitiated) {
            let result = Self.buildScene(root: root, courseModelData: courseData)
            await MainActor.run {
                switch result {
                case .success(let preview):
                    built = preview
                    moveSpeed = preview.moveSpeed
                    moveSpeedRange = (preview.moveSpeed / 10)...(preview.moveSpeed * 10)
                    objectTemplates = preview.objectTemplates
                    for (layer, node) in preview.layerNodes { node.isHidden = !(layerVisibility[layer] ?? true) }
                    if let kmp = preview.kmp {
                        kmpBox = KMPDocumentBox(doc: kmp.doc)
                        if kmp.doc.isBOL { placeObjectID = 1 } // Double Dash item box
                        history = EditHistory(initial: kmp.doc.serialize())
                        rebuildKMPLayers()
                        loadMissingObjectsFromDisc()
                    }
                case .failure(let message): loadError = message
                }
            }
        }
    }

    /// Objects whose models the archive doesn't bundle (most live in the game's `Common.szs`) come
    /// from the linked Mario Kart Wii disc, if there is one, loaded after the preview is up,
    /// since the first look through the disc takes a while.
    private func loadMissingObjectsFromDisc() {
        let missing = objectTemplates.filter { $0.value == nil }.map(\.key)
        guard !missing.isEmpty, BaseGameLibrary.linkedISO != nil, kmpBox?.doc.isBOL == false else { return }
        let keys = (KeyManager.shared.commonKey, KeyManager.shared.koreanKey)
        let root = self.root
        Task.detached(priority: .utility) {
            guard let index = try? BaseGameLibrary.shared.index(commonKey: keys.0, koreanKey: keys.1) else { return }
            var found: [UInt16: SCNNode] = [:]
            for id in missing { if let node = Self.objectTemplate(for: id, root: root, library: index) { found[id] = node } }
            guard !found.isEmpty else { return }
            await MainActor.run { [found] in
                for (id, node) in found { objectTemplates[id] = node }
                rebuildKMPLayers()
            }
        }
    }

    /// Off the main thread: parsing several BRRES/MDL0/KMP files and decoding every texture is real
    /// work on a track-sized archive, and none of it touches `@MainActor` state until the finished
    /// `SCNScene` is handed back.
    nonisolated private static func buildScene(root: U8Node, courseModelData: Data) -> BuildOutcome {
        guard let courseModelData = wiiModel(courseModelData, name: "course"),
              let courseDoc = try? BRRESDocument.parse(courseModelData) else {
            return .failure("course_model.brres is present but couldn't be parsed.")
        }
        guard let courseResource = courseDoc.resources.first(where: { $0.magic == "MDL0" && $0.name == "course" }),
              let courseModel = MDL0Parser.parse(courseResource, rawFile: courseDoc.rawData) else {
            return .failure("course_model.brres has no MDL0 named \"course\" this app can read geometry out of.")
        }

        let scene = SCNScene()
        var layerNodes: [Layer: SCNNode] = [:]
        for layer in Layer.allCases {
            let node = SCNNode()
            node.name = layer.rawValue
            scene.rootNode.addChildNode(node)
            layerNodes[layer] = node
        }

        layerNodes[.course]!.addChildNode(MDL0SceneKit.node(for: courseModel, textures: MDL0SceneKit.textureImages(in: courseDoc), animations: courseDoc))

        if let vrData = file(root, "vrcorn_model.brres", orSuffix: "_sky.bmd")?.data.flatMap({ wiiModel($0, name: "vrcorn") }),
           let vrDoc = try? BRRESDocument.parse(vrData),
           let vrResource = vrDoc.resources.first(where: { $0.magic == "MDL0" && $0.name == "vrcorn" }),
           let vrModel = MDL0Parser.parse(vrResource, rawFile: vrDoc.rawData) {
            layerNodes[.background]!.addChildNode(MDL0SceneKit.node(for: vrModel, textures: MDL0SceneKit.textureImages(in: vrDoc)))
        }

        var minimapModel: MDL0Model?
        var minimapBounds: (Float, Float, Float, Float)?
        if let mapData = root.children.first(where: { !$0.isDirectory && $0.name == "map_model.brres" })?.data,
           let mapDoc = try? BRRESDocument.parse(mapData),
           let mapResource = mapDoc.resources.first(where: { $0.magic == "MDL0" }),
           let mapModel = MDL0Parser.parse(mapResource, rawFile: mapDoc.rawData) {
            minimapModel = mapModel
            let b0 = mapModel.boundsMin, b1 = mapModel.boundsMax
            if b0.x.isFinite, b1.x.isFinite, b1.x > b0.x, b1.z > b0.z { minimapBounds = (b0.x, b1.x, b0.z, b1.z) }
        }

        var kmpResult: (doc: KMPDocument, node: U8Node)?
        var templates: [UInt16: SCNNode?] = [:]
        if let kmpNode = file(root, "course.kmp", orSuffix: "_course.bol"),
           let kmpData = kmpNode.data, let kmp = try? KMPDocument.parse(kmpData) {
            kmpResult = (kmp, kmpNode)
            // Load each object model once here, off the main thread; markers are built on the main
            // thread from these (and rebuilt after every edit).
            for id in Set(kmp.gobj.map(\.objectID)) { templates[id] = objectTemplate(for: id, root: root) }
        }

        let (startPosition, startLookAt) = cameraStartPose(boundsOf: courseModel, startPoint: kmpResult?.doc.ktpt.first)
        let moveSpeed = frameCamera(scene: scene, position: startPosition, lookAt: startLookAt, extentOf: courseModel)
        let bmin = courseModel.boundsMin, bmax = courseModel.boundsMax

        return .success(BuiltPreview(scene: scene, moveSpeed: moveSpeed, startPosition: startPosition, startLookAt: startLookAt,
                                     boundsMin: SIMD3(bmin.x, bmin.y, bmin.z), boundsMax: SIMD3(bmax.x, bmax.y, bmax.z),
                                     layerNodes: layerNodes, minimapModel: minimapModel,
                                     minimapBounds: minimapBounds.map { (minX: $0.0, maxX: $0.1, minZ: $0.2, maxZ: $0.3) },
                                     kmp: kmpResult, objectTemplates: templates,
                                     collision: file(root, "course.kcl", orSuffix: "_course.bco")?.data.flatMap { try? KCLDocument.parse($0) }))
    }

    /// A top-level file: the Mario Kart Wii name, or for a Double Dash archive the file ending in `suffix`.
    nonisolated static func file(_ root: U8Node, _ name: String, orSuffix suffix: String) -> U8Node? {
        root.children.first { !$0.isDirectory && $0.name == name }
            ?? root.children.first { !$0.isDirectory && $0.name.lowercased().hasSuffix(suffix) }
    }

    /// A model as BRRES: Double Dash J3D models are converted (at their own scale) for display.
    nonisolated private static func wiiModel(_ data: Data, name: String) -> Data? {
        guard data.asciiString(at: 0, length: 4) == "J3D2" else { return data }
        return (try? J3DModel.parse(data)).flatMap { try? J3DToWii.brres(from: $0, modelName: name, scale: 1) }
    }

    // MARK: KMP markers

    /// Adds a clickable node for every KMP entry to its layer and returns which entry each node is.
    nonisolated private static func addKMPNodes(_ doc: KMPDocument, root: U8Node, layerNodes: [Layer: SCNNode],
                                    templates: inout [UInt16: SCNNode?]) -> [ObjectIdentifier: KMPSelection] {
        var map: [ObjectIdentifier: KMPSelection] = [:]
        func add(_ node: SCNNode, _ sel: KMPSelection, to layer: Layer) {
            layerNodes[layer]?.addChildNode(node)
            map[ObjectIdentifier(node)] = sel
        }
        for (i, e) in doc.ktpt.enumerated() { add(markerNode(at: e.position, color: .systemGreen, radius: 300, rotation: e.rotation), .ktpt(i), to: .startPoints) }
        let enemyDirs = pathDirections(doc.enpt.map(\.position), groups: doc.enph)
        for (i, e) in doc.enpt.enumerated() { add(markerNode(at: e.position, color: .systemOrange, radius: 220, rotation: enemyDirs[i]), .enpt(i), to: .enemyPaths) }
        let itemDirs = pathDirections(doc.itpt.map(\.position), groups: doc.itph)
        for (i, e) in doc.itpt.enumerated() { add(markerNode(at: e.position, color: .systemPurple, radius: 220, rotation: itemDirs[i]), .itpt(i), to: .itemPaths) }
        addPathLines(doc.enpt.map(\.position), groups: doc.enph, color: .systemOrange, into: layerNodes[.enemyPaths]!)
        addPathLines(doc.itpt.map(\.position), groups: doc.itph, color: .systemPurple, into: layerNodes[.itemPaths]!)

        let gateY: (CKPTEntry) -> Float = { e in
            if let b = e.bol, b.count >= 0x14 { return (b.beFloat32(4) + b.beFloat32(0x10)) / 2 } // Double Dash gates carry their own height
            return doc.jgpt.indices.contains(Int(e.respawnIndex)) ? doc.jgpt[Int(e.respawnIndex)].position.y : 0
        }
        for (i, e) in doc.ckpt.enumerated() {
            let y = gateY(e)
            let color: NSColor = e.lapCounterType == 0 ? .systemGreen : e.lapCounterType > 0 ? .systemCyan : .lightGray
            let mid = Vec3(x: (e.left.x + e.right.x) / 2, y: y, z: (e.left.y + e.right.y) / 2)
            // Facing the direction of travel: across the gate, left to right turned a quarter.
            let facing = rotationFacing(SIMD3(-(e.left.y - e.right.y), 0, e.left.x - e.right.x))
            add(markerNode(at: mid, color: color, radius: 200, rotation: facing), .ckpt(i), to: .checkpoints)
            add(markerNode(at: Vec3(x: e.left.x, y: y, z: e.left.y), color: color, radius: 150, rotation: facing), .ckpt(i), to: .checkpoints)
            add(markerNode(at: Vec3(x: e.right.x, y: y, z: e.right.y), color: color, radius: 150, rotation: facing), .ckpt(i), to: .checkpoints)
        }
        addCheckpointLines(doc.ckpt, groups: doc.ckph, y: gateY, into: layerNodes[.checkpoints]!)

        for (i, obj) in doc.gobj.enumerated() {
            if templates[obj.objectID] == nil { templates[obj.objectID] = objectTemplate(for: obj.objectID, root: root) }
            let node: SCNNode
            if let template = templates[obj.objectID] ?? nil {
                node = template.clone()
                node.position = SCNVector3(obj.position.x, obj.position.y, obj.position.z)
                node.eulerAngles = SCNVector3(degreesToRadians(obj.rotation.x), degreesToRadians(obj.rotation.y), degreesToRadians(obj.rotation.z))
                node.scale = SCNVector3(obj.scale.x, obj.scale.y, obj.scale.z)
                if obj.objectID == 0x0065 { // the item box: the game spins it in code
                    node.childNodes.first?.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 2)))
                }
                if doc.poti.indices.contains(Int(obj.routeID)) { followRoute(node, doc.poti[Int(obj.routeID)]) }
            } else {
                node = markerNode(at: obj.position, color: isRetailObjectID(obj.objectID) ? placeholderColor(for: obj.objectID) : .systemRed, radius: 300, rotation: obj.rotation)
            }
            add(node, .gobj(i), to: .objects)
        }
        for (i, e) in doc.jgpt.enumerated() { add(markerNode(at: e.position, color: .systemYellow, radius: 300, rotation: e.rotation), .jgpt(i), to: .respawns) }
        for (i, e) in doc.cnpt.enumerated() { add(markerNode(at: e.position, color: .systemRed, radius: 300, rotation: Vec3(x: 0, y: e.effectVector.y, z: 0)), .cnpt(i), to: .cannons) }
        for (i, e) in doc.mspt.enumerated() { add(markerNode(at: e.position, color: .systemTeal, radius: 300, rotation: e.rotation), .mspt(i), to: .battleStarts) }
        for (i, e) in doc.area.enumerated() { add(markerNode(at: e.position, color: .systemIndigo, radius: 350, rotation: e.rotation), .area(i), to: .areas) }
        for (i, e) in doc.came.enumerated() { add(markerNode(at: e.position, color: .systemPink, radius: 300, rotation: e.rotation), .came(i), to: .cameras) }
        for (r, route) in doc.poti.enumerated() {
            let groups = [PathLinkEntry(startIndex: 0, pointCount: UInt8(clamping: route.points.count))]
            let dirs = pathDirections(route.points.map(\.position), groups: groups)
            for (p, point) in route.points.enumerated() { add(markerNode(at: point.position, color: .systemBrown, radius: 180, rotation: dirs[p]), .poti(route: r, point: p), to: .routes) }
            let v = route.points.map { SCNVector3($0.position.x, $0.position.y, $0.position.z) }
            if v.count > 1 {
                var segs: [SCNVector3] = []
                for k in 0..<(v.count - 1) { segs += [v[k], v[k + 1]] }
                if route.isCyclic { segs += [v[v.count - 1], v[0]] }
                layerNodes[.routes]?.addChildNode(lineNode(segs, color: .systemBrown))
            }
        }
        return map
    }

    nonisolated private static func degreesToRadians(_ d: Float) -> Float { d * .pi / 180 }

    /// An object on a route travels it as the game moves it: point to point, facing the way it
    /// goes, round and round (cyclic) or back and forth.
    /// ponytail: speed is each point's setting 1 as units a frame (else 20), not every object's own rule.
    nonisolated private static func followRoute(_ node: SCNNode, _ route: POTIRoute) {
        guard route.points.count > 1 else { return }
        var order = Array(route.points.indices)
        order += route.isCyclic ? [order[0]] : order.reversed().dropFirst()
        var steps: [SCNAction] = []
        for (a, b) in zip(order, order.dropFirst()) {
            let p = route.points[a].position, q = route.points[b].position
            let d = SIMD3(q.x - p.x, q.y - p.y, q.z - p.z)
            let speed = Float(route.points[a].setting1 >= 5 ? route.points[a].setting1 : 20) * 60
            steps.append(.group([.move(to: SCNVector3(q.x, q.y, q.z), duration: Double(simd_length(d) / speed)),
                                 .rotateTo(x: 0, y: CGFloat(atan2(d.x, d.z)), z: 0, duration: 0.2, usesShortestUnitArc: true)]))
        }
        let start = route.points[0].position
        node.position = SCNVector3(start.x, start.y, start.z)
        node.runAction(.repeatForever(.sequence(steps)))
    }

    nonisolated private static func addPathLines(_ points: [Vec3], groups: [PathLinkEntry], color: NSColor, into node: SCNNode) {
        var vertices: [SCNVector3] = []
        for group in groups {
            let start = Int(group.startIndex), count = Int(group.pointCount)
            guard count > 1 else { continue }
            for i in start..<(start + count - 1) where points.indices.contains(i) && points.indices.contains(i + 1) {
                vertices.append(SCNVector3(points[i].x, points[i].y, points[i].z))
                vertices.append(SCNVector3(points[i + 1].x, points[i + 1].y, points[i + 1].z))
            }
        }
        guard !vertices.isEmpty else { return }
        node.addChildNode(lineNode(vertices, color: color))
    }

    /// Each checkpoint's gate plus the left/right rails between consecutive gates of a group, at
    /// the height of the respawn point each gate uses (CKPT itself is 2D).
    nonisolated private static func addCheckpointLines(_ ckpt: [CKPTEntry], groups: [PathLinkEntry], y: (CKPTEntry) -> Float, into node: SCNNode) {
        func v(_ p: Vec2, _ e: CKPTEntry) -> SCNVector3 { SCNVector3(CGFloat(p.x), CGFloat(y(e)), CGFloat(p.y)) }
        var byColor: [NSColor: [SCNVector3]] = [:]
        for e in ckpt {
            let c: NSColor = e.lapCounterType == 0 ? .systemGreen : e.lapCounterType > 0 ? .systemCyan : .lightGray
            byColor[c, default: []].append(contentsOf: [v(e.left, e), v(e.right, e)])
        }
        for (c, verts) in byColor where !verts.isEmpty { node.addChildNode(lineNode(verts, color: c)) }
        var rails: [SCNVector3] = []
        for group in groups {
            let start = Int(group.startIndex), count = Int(group.pointCount)
            guard count > 1 else { continue }
            for i in start..<(start + count - 1) where ckpt.indices.contains(i) && ckpt.indices.contains(i + 1) {
                let a = ckpt[i], b = ckpt[i + 1]
                rails += [v(a.left, a), v(b.left, b), v(a.right, a), v(b.right, b)]
            }
        }
        if !rails.isEmpty { node.addChildNode(lineNode(rails, color: .cyan)) }
    }

    nonisolated private static func lineNode(_ vertices: [SCNVector3], color: NSColor) -> SCNNode {
        let source = SCNGeometrySource(vertices: vertices)
        let element = SCNGeometryElement(indices: Array(0..<Int32(vertices.count)), primitiveType: .line)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.emission.contents = color
        material.lightingModel = .constant
        geometry.materials = [material]
        return SCNNode(geometry: geometry)
    }

    /// Candidate filenames (without extension) an object's model might be bundled under. MKWii's
    /// object model files are typically one bare lowercase word (e.g. both Item Box variants use
    /// `itembox`). Best-effort: a miss falls back to a placeholder marker rather than guessing.
    nonisolated private static func objectModelSearchNames(for objectID: UInt16) -> [String] {
        if let resources = gobjResources[objectID] { return resources.map { $0.lowercased() } }
        let display = gobjDisplayName(objectID)
        guard !display.hasPrefix("Object 0x") else { return [] }
        let base = display.split(separator: "(").first.map(String.init) ?? display
        let squashed = base.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "")
        return squashed.isEmpty ? [] : [squashed]
    }

    /// The object's real model, animated, when one is bundled in this archive, or, with
    /// `library`, found on the linked Mario Kart Wii disc (its course archives and `Common.szs`).
    nonisolated private static func objectTemplate(for objectID: UInt16, root: U8Node,
                                                   library: BaseGameLibrary.Index? = nil) -> SCNNode? {
        for name in objectModelSearchNames(for: objectID) {
            guard let data = findBRRES(named: name, in: root) ?? library.flatMap({ BaseGameLibrary.shared.brres(named: name, in: $0) }),
                  let node = objectNode(brres: data, name: name) else { continue }
            return node
        }
        return nil
    }

    /// The object's main model (named after its file, never its `-shadow`/`-low` stand-ins),
    /// playing its animations, under a plain node that placement transforms.
    nonisolated private static func objectNode(brres data: Data, name: String) -> SCNNode? {
        guard let doc = try? BRRESDocument.parse(data) else { return nil }
        let models = doc.resources.filter { $0.magic == "MDL0" }
        guard let resource = models.first(where: { $0.name.lowercased() == name })
                ?? models.first(where: { !$0.name.hasSuffix("-shadow") && !$0.name.hasSuffix("-low") }) ?? models.first,
              let model = MDL0Parser.parse(resource, rawFile: doc.rawData) else { return nil }
        let node = SCNNode()
        node.addChildNode(MDL0SceneKit.node(for: model, textures: MDL0SceneKit.textureImages(in: doc), animations: doc))
        return node
    }

    nonisolated private static func findBRRES(named name: String, in node: U8Node) -> Data? {
        for child in node.children {
            if child.isDirectory {
                if let found = findBRRES(named: name, in: child) { return found }
            } else if child.name.lowercased() == "\(name).brres", let data = child.data {
                return data
            }
        }
        return nil
    }

    /// A marker for any KMP entry: a sphere with a cone out front showing which way it faces.
    /// `rotation` is in degrees, the same convention as the KMP (yaw 0 = +Z, 90 = +X), applied as
    /// SceneKit Euler angles exactly like an object's real model, so the cone and the model agree.
    nonisolated private static func markerNode(at position: Vec3, color: NSColor, radius: CGFloat, rotation: Vec3 = Vec3()) -> SCNNode {
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.emission.contents = color
        let sphere = SCNNode(geometry: SCNSphere(radius: radius))
        sphere.geometry?.materials = [material]
        let cone = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: radius * 0.55, height: radius * 1.6))
        cone.geometry?.materials = [material]
        cone.position = SCNVector3(0, 0, radius * 1.5)
        cone.eulerAngles = SCNVector3(CGFloat.pi / 2, 0, 0) // cone's +Y tip turned to face +Z
        let node = SCNNode()
        node.addChildNode(sphere)
        node.addChildNode(cone)
        node.position = SCNVector3(position.x, position.y, position.z)
        node.eulerAngles = SCNVector3(degreesToRadians(rotation.x), degreesToRadians(rotation.y), degreesToRadians(rotation.z))
        return node
    }

    /// The rotation (degrees) that points a marker's cone along `direction`.
    nonisolated private static func rotationFacing(_ direction: SIMD3<Float>) -> Vec3 {
        let flat = (direction.x * direction.x + direction.z * direction.z).squareRoot()
        guard flat > 1e-4 || abs(direction.y) > 1e-4 else { return Vec3() }
        return Vec3(x: -atan2(direction.y, flat) * 180 / .pi, y: atan2(direction.x, direction.z) * 180 / .pi, z: 0)
    }

    /// Each path point faces the next point in its group (the last one keeps the previous
    /// segment's direction); a point in no group faces +Z.
    nonisolated private static func pathDirections(_ points: [Vec3], groups: [PathLinkEntry]) -> [Vec3] {
        var out = Array(repeating: Vec3(), count: points.count)
        func d(_ a: Vec3, _ b: Vec3) -> SIMD3<Float> { SIMD3(b.x - a.x, b.y - a.y, b.z - a.z) }
        for g in groups {
            let start = Int(g.startIndex), end = min(points.count, start + Int(g.pointCount))
            guard end - start > 1 else { continue }
            for i in start..<end {
                out[i] = rotationFacing(i + 1 < end ? d(points[i], points[i + 1]) : d(points[i - 1], points[i]))
            }
        }
        return out
    }

    nonisolated private static func placeholderColor(for objectID: UInt16) -> NSColor {
        var hasher = Hasher()
        hasher.combine(objectID)
        let hash = UInt32(bitPattern: Int32(truncatingIfNeeded: hasher.finalize()))
        return NSColor(hue: Double(hash % 360) / 360.0, saturation: 0.75, brightness: 0.95, alpha: 1)
    }

    nonisolated private static func cameraStartPose(boundsOf model: MDL0Model, startPoint: KTPTEntry?) -> (position: SCNVector3, lookAt: SCNVector3) {
        let bmin = model.boundsMin, bmax = model.boundsMax
        guard bmin.x.isFinite, bmax.x.isFinite else { return (SCNVector3(0, 500, 500), SCNVector3Zero) }
        let center = SCNVector3((bmin.x + bmax.x) / 2, (bmin.y + bmax.y) / 2, (bmin.z + bmax.z) / 2)
        let extent = CGFloat(max(bmax.x - bmin.x, max(bmax.y - bmin.y, bmax.z - bmin.z), 1000))
        if let startPoint {
            let yaw = degreesToRadians(startPoint.rotation.y)
            let forward = SCNVector3(CGFloat(sin(yaw)), 0, CGFloat(cos(yaw)))
            // Behind and above the start, looking over it down the track.
            let eye = SCNVector3(CGFloat(startPoint.position.x) - forward.x * 1500, CGFloat(startPoint.position.y) + 900,
                                 CGFloat(startPoint.position.z) - forward.z * 1500)
            return (eye, SCNVector3(CGFloat(startPoint.position.x) + forward.x * 1500, CGFloat(startPoint.position.y), CGFloat(startPoint.position.z) + forward.z * 1500))
        }
        return (SCNVector3(center.x, center.y + extent * 0.6, center.z + extent * 0.9), center)
    }

    /// Places the camera, adds a light, and returns a fly speed scaled to the model's size.
    nonisolated private static func frameCamera(scene: SCNScene, position: SCNVector3, lookAt: SCNVector3, extentOf model: MDL0Model) -> Float {
        let bmin = model.boundsMin, bmax = model.boundsMax
        let extent = max(bmax.x - bmin.x, max(bmax.y - bmin.y, bmax.z - bmin.z), 1000)
        let camera = SCNCamera()
        camera.zFar = Double(extent) * 6
        camera.zNear = Double(extent) / 20000
        camera.fieldOfView = 60
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = position
        cameraNode.look(at: lookAt)
        scene.rootNode.addChildNode(cameraNode)

        let light = SCNLight()
        light.type = .directional
        light.intensity = 900
        let lightNode = SCNNode()
        lightNode.name = "sun" // Create Render restyles these by name (see `TrackRender.apply`)
        lightNode.light = light
        lightNode.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 4, 0)
        scene.rootNode.addChildNode(lightNode)
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 300
        let ambientNode = SCNNode()
        ambientNode.name = "ambient"
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)
        return extent / 8
    }
}

/// Which gizmo handles the selected entry gets: arrows for the axes it can move along, rings for
/// the axes it can rotate about.
struct GizmoTarget {
    var position: SIMD3<Float>
    /// The entry's own rotation in degrees, the move arrows follow it, so "forward" is the
    /// object's forward.
    var rotation: SIMD3<Float>
    var translate: [Bool]
    var rotate: [Bool]
}

/// The 3D viewer's right-hand panel: the same Properties inspector and Stage Info as the KMP
/// editor, the same delete rules, Snap to Ground, and, for a Cmd-click multi-selection, the
/// 2D editor's Straighten / Equalise Gaps.
private struct TrackPreviewInspector: View {
    @ObservedObject private var controls = Controls.shared
    @ObservedObject var box: KMPDocumentBox
    @Binding var layerVisibility: [TrackPreviewView.Layer: Bool]
    let setLayer: (TrackPreviewView.Layer, Bool) -> Void
    let multiSelection: Set<KMPSelection>
    let canSnap: Bool
    let snap: (Set<KMPSelection>) -> Void
    let straighten: () -> Void
    let equalise: () -> Void
    let installObjectFiles: ([(path: [String], data: Data)]) -> Void
    @AppStorage("trackPreviewStageInfoExpanded") private var isStageInfoExpanded = false
    @AppStorage("trackPreviewLayersExpanded") private var isLayersExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Inspector").font(.headline)
                Spacer()
                if let sel = box.selection, box.doc.canInsertPoint(after: sel) {
                    Button {
                        box.selection = box.doc.insertPoint(after: sel)
                        box.isDirty = true
                        box.objectWillChange.send()
                    } label: { Image(systemName: "plus.circle") }
                    .buttonStyle(.borderless)
                    .help("Insert a point after this one, halfway to the next point in its path, with the same settings.")
                }
                if let sel = box.selection {
                    if KMPDocument.supportsGroundSnap(sel) {
                        Button { snap([sel]) } label: { Image(systemName: "arrow.down.to.line") }
                            .buttonStyle(.borderless)
                            .disabled(!canSnap)
                            .help(canSnap ? "Snap Y to the collision (course.kcl) below this point" : "This archive has no readable course.kcl to snap to")
                    }
                    Button(role: .destructive) { box.remove(sel) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .disabled(!box.canRemove(sel))
                        .help(box.canRemove(sel) ? "Remove this point" : "Only the last point of a path can be removed.")
                }
            }
            .padding([.top, .horizontal]).padding(.bottom, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if multiSelection.count > 1 {
                        Text("\(multiSelection.count) points selected").font(.headline)
                        Button("Straighten", action: straighten)
                            .help("Aligns all selected points to a single horizontal or vertical line.")
                        Button("Equalise Gaps", action: equalise)
                            .help("Spaces the selected points out evenly between the two furthest points.")
                            .disabled(multiSelection.count < 3)
                        Button("Snap to Ground") { snap(multiSelection) }
                            .disabled(!canSnap)
                        Text("\(Controls.shared.phrase(.view3DBoxSelect, "click")) points to add or remove them.").font(.caption2).foregroundStyle(.secondary)
                    } else if let sel = box.selection {
                        KMPInspectorFields(box: box, selection: sel, onCommit: {}, installObjectFiles: installObjectFiles)
                        Text("Drag the arrows to move along an axis and the rings to rotate. Drag the point itself to slide it along the ground, hold \(Controls.shared.modifierName(.view3DStraight)) to keep to a straight line, \(Controls.shared.modifierName(.view3DFaceCursor)) to turn it to face the cursor.")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("Click a marker in the scene to inspect it (\(Controls.shared.phrase(.view3DBoxSelect, "click").lowercased()) for several), or use Add to place a new point.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    DisclosureGroup(isExpanded: $isStageInfoExpanded) {
                        KMPStageInfoFields(box: box, onCommit: {})
                    } label: { Text("Stage Info").font(.headline) }
                    Divider()
                    DisclosureGroup(isExpanded: $isLayersExpanded) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(TrackPreviewView.Layer.allCases) { layer in
                                Toggle(layer.rawValue, isOn: Binding(get: { layerVisibility[layer] ?? true }, set: { setLayer(layer, $0) })).font(.caption)
                            }
                        }
                    } label: { Text("Layers").font(.headline) }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Scene view and navigation

private struct SceneKitPreview: NSViewRepresentable {
    let scene: SCNScene
    @Binding var moveSpeed: Float
    @Binding var command: TrackPreviewView.NavigationCommand?
    let startPosition: SCNVector3
    let startLookAt: SCNVector3
    let boundsMin: SIMD3<Float>
    let boundsMax: SIMD3<Float>
    let selectionFocus: () -> (SIMD3<Float>, Float)?
    let onClick: (SCNHitTestResult?, Bool) -> Void
    let onDelete: () -> Void
    let gizmoTarget: () -> GizmoTarget?
    let isSelectedNode: (SCNNode) -> Bool
    let onTranslate: (SIMD3<Float>) -> Void
    let onRotate: (Int, Float) -> Void
    let onYawToward: (SIMD3<Float>) -> Void
    let onManipulationEnd: () -> Void
    let onMarquee: (CGRect, (SIMD3<Float>) -> CGPoint?) -> Void
    let contextDelete: (SCNHitTestResult) -> (title: String, enabled: Bool)?
    let onDeleteHit: (SCNHitTestResult) -> Void
    /// Edit mode (and not rendering or driving): markers can be picked, moved and deleted.
    let editable: Bool
    let driverPath: DriverPath?
    let drivePaused: Bool
    let driveSpeed: Float
    /// Bumped to send the driver back to the start line.
    let driveRestart: Int
    let driveForkPending: Bool
    let onDriveFork: (DriverPath.Fork) -> Void
    let onDriveLap: (Int) -> Void
    let onDriveKey: (NavigationSCNView.DriveKey) -> Void

    func makeNSView(context: Context) -> NavigationSCNView {
        let view = NavigationSCNView()
        view.scene = scene
        view.autoenablesDefaultLighting = false
        view.backgroundColor = .black
        view.antialiasingMode = .multisampling4X
        view.isPlaying = true // objects' animations
        view.startPose = (startPosition, startLookAt)
        view.bounds3D = (boundsMin, boundsMax)
        view.pivot = SIMD3(Float(startLookAt.x), Float(startLookAt.y), Float(startLookAt.z))
        scene.rootNode.addChildNode(view.gizmo)
        update(view)
        context.coordinator.startTimer(for: view)
        return view
    }

    func updateNSView(_ nsView: NavigationSCNView, context: Context) {
        update(nsView)
        if let command {
            nsView.perform(command)
            DispatchQueue.main.async { self.command = nil }
        }
        DispatchQueue.main.async { if nsView.window?.firstResponder is NSTextView == false { nsView.window?.makeFirstResponder(nsView) } }
    }

    private func update(_ view: NavigationSCNView) {
        view.moveSpeed = moveSpeed
        view.onClick = onClick
        view.onDelete = onDelete
        view.selectionFocus = selectionFocus
        view.gizmoTarget = gizmoTarget
        view.isSelectedNode = isSelectedNode
        view.onTranslate = onTranslate
        view.onRotate = onRotate
        view.onYawToward = onYawToward
        view.onManipulationEnd = onManipulationEnd
        view.onMarquee = onMarquee
        view.contextDelete = contextDelete
        view.onDeleteHit = onDeleteHit
        view.editable = editable
        view.setDrive(driverPath, restart: driveRestart)
        view.drivePaused = drivePaused
        view.driveSpeed = driveSpeed
        view.onDriveLap = onDriveLap
        view.forkPending = driveForkPending
        view.onDriveFork = onDriveFork
        view.onDriveKey = onDriveKey
    }

    static func dismantleNSView(_ nsView: NavigationSCNView, coordinator: Coordinator) {
        coordinator.stopTimer()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var timer: Timer?
        func startTimer(for view: NavigationSCNView) {
            let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak view] _ in view?.tick(dt: 1.0 / 60.0) }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        func stopTimer() { timer?.invalidate(); timer = nil }
    }
}

/// SketchUp/Blender-style navigation on a plain `SCNView`, driving the camera node directly, plus
/// a move/rotate gizmo on the selected KMP entry:
/// - Orbit (turntable) around `pivot`, which a drag first moves to the point under the cursor.
///   Middle-drag, Alt+right-drag, trackpad swipe, or (View mode only) left-drag, in Edit mode a
///   left-drag on empty space draws a selection box instead, leaving the left button for picking.
///   Pan: Shift-drag, right-drag, Shift+middle/swipe.
/// - Zoom toward the cursor with the scroll wheel or pinch. Double-click centres on a point.
/// - F/H/0 frame selection/track/start; 7/1/3 top/front/side; 5 orthographic; WASD/QE fly.
/// - Gizmo: red/green/blue arrows move along X/Y/Z, matching rings rotate about them. Dragging the
///   selected marker itself slides it along the ground; Shift keeps it to a straight line and Alt
///   turns it to face the cursor, the 2D KMP editor's modifiers.
final class NavigationSCNView: SCNView {
    var moveSpeed: Float = 500
    /// Reports plain clicks in View mode too (the KCL editor picks triangles without an Edit mode).
    var clicksWhenNotEditable = false
    enum DriveKey { case togglePause, exit }
    var drivePaused = false
    var driveSpeed: Float = 4500
    var onDriveLap: ((Int) -> Void)?
    /// Stopped at a fork until the user picks a branch (set here on arrival, cleared by the choice).
    var forkPending = false
    var onDriveFork: ((DriverPath.Fork) -> Void)?
    /// The sample of the fork last stopped at, so driving on from it doesn't stop there again.
    private var forkStop: Int?
    var onDriveKey: ((DriveKey) -> Void)?
    private var driverPath: DriverPath?
    private var driveDistance: Float = 0
    private var driveRestart = 0
    private var driveLap = 1
    /// Seconds of boost left (boost panel / boost ramp).
    private var driveBoost: Float = 0
    /// In the air off a ramp or jump pad: launch height, upward speed, seconds airborne, and a
    /// jump pad's own forward speed (units/second).
    private var driveAir: (launchY: Float, vy: Float, t: Float, speed: Float?)?
    /// The free-navigation camera to go back to after Driver's View.
    private var preDrivePose: (simd_float3, simd_quatf, CGFloat)?
    var onClick: ((SCNHitTestResult?, Bool) -> Void)?
    /// Collision editing: clicks hit the back of a double-sided face too (the underside of a ramp
    /// is drawn, so it should be clickable), and clicking the same spot again picks the next
    /// surface behind the last one, so a face hidden under another can still be reached.
    var clicksThroughStacks = false
    private var lastClick: (point: CGPoint, depth: Int)?
    var onDelete: (() -> Void)?
    var selectionFocus: (() -> (SIMD3<Float>, Float)?)?
    var gizmoTarget: (() -> GizmoTarget?)?
    var isSelectedNode: ((SCNNode) -> Bool)?
    var onTranslate: ((SIMD3<Float>) -> Void)?
    var onRotate: ((Int, Float) -> Void)?
    var onYawToward: ((SIMD3<Float>) -> Void)?
    var onManipulationEnd: (() -> Void)?
    var onMarquee: ((CGRect, (SIMD3<Float>) -> CGPoint?) -> Void)?
    var contextDelete: ((SCNHitTestResult) -> (title: String, enabled: Bool)?)?
    var onDeleteHit: ((SCNHitTestResult) -> Void)?
    var editable = false
    private var rightDragged = false
    private let marqueeLayer: CAShapeLayer = {
        let l = CAShapeLayer()
        l.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        l.strokeColor = NSColor.controlAccentColor.cgColor
        l.lineWidth = 1
        l.lineDashPattern = [4, 3]
        return l
    }()
    var startPose: (SCNVector3, SCNVector3) = (SCNVector3Zero, SCNVector3Zero)
    var bounds3D: (SIMD3<Float>, SIMD3<Float>) = (.zero, .zero)
    var pivot = SIMD3<Float>(0, 0, 0)
    let gizmo = NavigationSCNView.makeGizmo()

    private enum Drag {
        case orbit, pan
        case axis(Int, last: Float)
        case ring(Int, last: Float)
        case marker(planeY: Float, start: SIMD3<Float>, applied: SIMD3<Float>)
        case marquee(start: CGPoint)
    }
    private var drag: Drag = .orbit
    private var keys: Set<UInt16> = []
    private var dragged = false
    private var panDepth: Float = 1000
    private let orbitSensitivity: Float = 0.006 // radians per point
    private static let axes: [SIMD3<Float>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]
    private static let gizmoCategory = 2

    override var acceptsFirstResponder: Bool { true }
    private var cam: SCNNode? { pointOfView }

    // MARK: Gizmo

    private static func makeGizmo() -> SCNNode {
        let root = SCNNode()
        root.name = "gizmo"
        let colors: [NSColor] = [.systemRed, .systemGreen, .systemBlue]
        func material(_ c: NSColor) -> SCNMaterial {
            let m = SCNMaterial()
            m.diffuse.contents = c
            m.emission.contents = c
            m.lightingModel = .constant
            m.readsFromDepthBuffer = false // drawn on top of the track, like any 3D editor's gizmo
            m.writesToDepthBuffer = false
            return m
        }
        for k in 0..<3 {
            // Arrow: built along +Y, then turned onto its axis.
            let arrow = SCNNode()
            arrow.name = "t\(k)"
            let shaft = SCNNode(geometry: SCNCylinder(radius: 0.03, height: 0.8))
            shaft.position = SCNVector3(0, 0.4, 0)
            let tip = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.08, height: 0.22))
            tip.position = SCNVector3(0, 0.9, 0)
            for n in [shaft, tip] { n.geometry?.materials = [material(colors[k])]; arrow.addChildNode(n) }
            if k == 0 { arrow.eulerAngles = SCNVector3(0, 0, -CGFloat.pi / 2) }
            if k == 2 { arrow.eulerAngles = SCNVector3(CGFloat.pi / 2, 0, 0) }
            root.addChildNode(arrow)
            // Ring: a torus lies around +Y; turned so it lies around its axis.
            let ring = SCNNode(geometry: SCNTorus(ringRadius: 0.62, pipeRadius: 0.035))
            ring.name = "r\(k)"
            ring.geometry?.materials = [material(colors[k].withAlphaComponent(0.85))]
            if k == 0 { ring.eulerAngles = SCNVector3(0, 0, CGFloat.pi / 2) }
            if k == 2 { ring.eulerAngles = SCNVector3(CGFloat.pi / 2, 0, 0) }
            root.addChildNode(ring)
        }
        func tag(_ n: SCNNode) { n.categoryBitMask = gizmoCategory; n.renderingOrder = 1000; n.childNodes.forEach(tag) }
        tag(root)
        root.isHidden = true
        return root
    }

    /// Keeps the gizmo on the selection and the same size on screen however far away it is.
    private func updateGizmo() {
        guard editable, let cam, let target = gizmoTarget?() else { gizmo.isHidden = true; return }
        gizmo.isHidden = false
        gizmo.simdWorldPosition = target.position
        let distance = simd_length(target.position - cam.simdWorldPosition)
        let s = (cam.camera?.usesOrthographicProjection ?? false) ? Float(cam.camera!.orthographicScale) * 0.25 : distance * 0.14
        gizmo.simdScale = SIMD3(repeating: max(s, 1))
        // Alt swaps the move arrows for the rotate rings. Arrows follow the entry's rotation;
        // rings stay on the world axes, which is what each rotation field turns about.
        let rotating: Bool
        switch drag {
        case .ring: rotating = true
        case .axis: rotating = false
        default: rotating = Controls.shared.held(.view3DRotateRings)
        }
        let r = rotating ? SIMD3<Float>(0, 0, 0) : target.rotation * (.pi / 180)
        gizmo.simdEulerAngles = r
        for k in 0..<3 {
            gizmo.childNode(withName: "t\(k)", recursively: false)?.isHidden = rotating || !target.translate[k]
            gizmo.childNode(withName: "r\(k)", recursively: false)?.isHidden = !rotating || !target.rotate[k]
        }
    }

    /// Which gizmo handle (if any) is under `p`.
    private func gizmoHandle(at p: CGPoint) -> Drag? {
        guard !gizmo.isHidden else { return nil }
        for hit in hitTest(p, options: [.categoryBitMask: Self.gizmoCategory, .searchMode: SCNHitTestSearchMode.all.rawValue]) {
            var n: SCNNode? = hit.node
            while let cur = n, cur !== gizmo {
                if let name = cur.name, name.count == 2, let k = Int(name.dropFirst()), !cur.isHidden {
                    if name.hasPrefix("t"), let s = axisParam(k, p) { return .axis(k, last: s) }
                    if name.hasPrefix("r"), let a = ringAngle(k, p) { return .ring(k, last: a) }
                }
                n = cur.parent
            }
        }
        return nil
    }

    private func ray(_ p: CGPoint) -> (SIMD3<Float>, SIMD3<Float>) {
        let near = unprojectPoint(SCNVector3(p.x, p.y, 0)), far = unprojectPoint(SCNVector3(p.x, p.y, 1))
        let o = SIMD3(Float(near.x), Float(near.y), Float(near.z))
        return (o, simd_normalize(SIMD3(Float(far.x), Float(far.y), Float(far.z)) - o))
    }

    /// Gizmo axis `k` in world space, the entry's own (rotated) axis while moving.
    private func axisVector(_ k: Int) -> SIMD3<Float> {
        let c = gizmo.simdWorldTransform[k]
        let v = SIMD3(c.x, c.y, c.z)
        return simd_length(v) > 0 ? simd_normalize(v) : Self.axes[k]
    }

    /// How far along gizmo axis `k` the cursor's ray passes closest.
    private func axisParam(_ k: Int, _ p: CGPoint) -> Float? {
        let (o, d) = ray(p), a = axisVector(k), w = gizmo.simdWorldPosition - o
        let b = simd_dot(a, d)
        guard abs(1 - b * b) > 1e-4 else { return nil } // looking straight down the axis
        return (b * simd_dot(d, w) - simd_dot(a, w)) / (1 - b * b)
    }

    /// The cursor's angle around gizmo axis `k`, in the plane of that ring.
    private func ringAngle(_ k: Int, _ p: CGPoint) -> Float? {
        let (o, d) = ray(p), n = axisVector(k), g = gizmo.simdWorldPosition
        let den = simd_dot(d, n)
        guard abs(den) > 1e-4 else { return nil }
        let v = o + d * (simd_dot(g - o, n) / den) - g
        let u = axisVector((k + 1) % 3)
        return atan2(simd_dot(simd_cross(u, v), n), simd_dot(u, v))
    }

    private func groundPoint(_ p: CGPoint, y: Float) -> SIMD3<Float>? {
        let (o, d) = ray(p)
        guard abs(d.y) > 1e-4 else { return nil }
        let t = (y - o.y) / d.y
        return t > 0 ? o + d * t : nil
    }

    // MARK: Camera math

    private func hitPoint(_ p: CGPoint) -> SIMD3<Float>? {
        guard let hit = hitTest(p, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue, .categoryBitMask: 1]).first else { return nil }
        let w = hit.worldCoordinates
        return SIMD3(Float(w.x), Float(w.y), Float(w.z))
    }

    private func orbit(dx: Float, dy: Float) {
        guard let cam else { return }
        let yaw = simd_quatf(angle: -dx * orbitSensitivity, axis: SIMD3(0, 1, 0))
        var q = yaw
        let pitch = simd_quatf(angle: -dy * orbitSensitivity, axis: cam.simdWorldRight)
        if abs((pitch * yaw).act(cam.simdWorldFront).y) < 0.995 { q = pitch * yaw } // stop short of straight up/down
        cam.simdWorldPosition = pivot + q.act(cam.simdWorldPosition - pivot)
        cam.simdWorldOrientation = q * cam.simdWorldOrientation
    }

    private func pan(dx: Float, dy: Float) {
        guard let cam, let camera = cam.camera else { return }
        let perPoint: Float = camera.usesOrthographicProjection
            ? Float(camera.orthographicScale) * 2 / Float(max(bounds.height, 1))
            : panDepth * 2 * tan(Float(camera.fieldOfView) * .pi / 360) / Float(max(bounds.height, 1))
        let delta = (-dx * cam.simdWorldRight + dy * cam.simdWorldUp) * perPoint
        cam.simdWorldPosition += delta
        pivot += delta
    }

    /// Zoom toward the middle of the view: positive is in. For +/- buttons.
    func zoomStep(_ amount: Float) { zoom(toward: CGPoint(x: bounds.midX, y: bounds.midY), amount: amount) }

    private func zoom(toward p: CGPoint, amount: Float) {
        guard let cam, let camera = cam.camera else { return }
        let f = max(-0.5, min(0.5, amount))
        if camera.usesOrthographicProjection {
            camera.orthographicScale *= Double(1 - f)
            return
        }
        let (o, d) = ray(p)
        let target = hitPoint(p) ?? (o + d * simd_length(pivot - cam.simdWorldPosition))
        cam.simdWorldPosition += (target - cam.simdWorldPosition) * f
    }

    /// Looks at `center` from the current direction (or `direction`), far enough back to fit `radius`.
    private func frame(center: SIMD3<Float>, radius: Float, from direction: SIMD3<Float>? = nil) {
        guard let cam, let camera = cam.camera else { return }
        let dir = simd_normalize(direction ?? cam.simdWorldFront)
        let distance = radius / sin(Float(camera.fieldOfView) * .pi / 360) * 1.1
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.35
        cam.simdWorldPosition = center - dir * distance
        cam.simdLook(at: center, up: abs(dir.y) > 0.99 ? SIMD3(0, 0, -1) : SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
        camera.orthographicScale = Double(radius * 1.1)
        SCNTransaction.commit()
        pivot = center
    }

    private var trackCenter: SIMD3<Float> { (bounds3D.0 + bounds3D.1) / 2 }
    private var trackRadius: Float { max(simd_length(bounds3D.1 - bounds3D.0) / 2, 1000) }

    func perform(_ command: TrackPreviewView.NavigationCommand) {
        switch command {
        case .returnToStart:
            guard let cam else { return }
            cam.camera?.usesOrthographicProjection = false
            cam.position = startPose.0
            // `look(at:)` alone keeps the node's current (possibly orbit-tilted) up vector, which
            // left the camera rolled after a reset. Always use world up.
            cam.simdLook(at: SIMD3(Float(startPose.1.x), Float(startPose.1.y), Float(startPose.1.z)),
                         up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
            pivot = SIMD3(Float(startPose.1.x), Float(startPose.1.y), Float(startPose.1.z))
        case .frameTrack: frame(center: trackCenter, radius: trackRadius)
        case .frameSelection:
            if let (c, r) = selectionFocus?() { frame(center: c, radius: r) } else { frame(center: trackCenter, radius: trackRadius) }
        case .top: frame(center: trackCenter, radius: trackRadius, from: SIMD3(0, -1, 0))
        case .front: frame(center: trackCenter, radius: trackRadius, from: SIMD3(0, 0, -1))
        case .side: frame(center: trackCenter, radius: trackRadius, from: SIMD3(-1, 0, 0))
        case .toggleOrtho:
            guard let camera = cam?.camera else { return }
            camera.orthographicScale = Double(simd_length(pivot - (cam?.simdWorldPosition ?? pivot)) * tan(Float(camera.fieldOfView) * .pi / 360))
            camera.usesOrthographicProjection.toggle()
        }
    }

    /// Starts, restarts or stops Driver's View.
    func setDrive(_ path: DriverPath?, restart: Int) {
        guard let cam else { return }
        if path != nil, driverPath == nil {
            preDrivePose = (cam.simdWorldPosition, cam.simdWorldOrientation, cam.camera?.fieldOfView ?? 60)
            cam.camera?.usesOrthographicProjection = false
            cam.camera?.fieldOfView = 75 // a driver's wider view
        } else if path == nil, driverPath != nil, let (p, q, fov) = preDrivePose {
            cam.simdWorldPosition = p
            cam.simdWorldOrientation = q
            cam.camera?.fieldOfView = fov
            preDrivePose = nil
        }
        if path != nil, restart != driveRestart || driverPath == nil { driveDistance = 0; driveLap = 1; driveBoost = 0; driveAir = nil; forkStop = nil }
        driveRestart = restart
        driverPath = path
    }

    /// Moves along the line, applying any boost panel, boost ramp or jump pad crossed.
    private func advanceDrive(_ path: DriverPath, dt: Float) {
        // ponytail: boost = flat x1.3 for 1 s (a panel's 60 frames); real karts ramp to it.
        var speed = driveSpeed * (driveBoost > 0 ? 1.3 : 1)
        if let jumpSpeed = driveAir?.speed { speed = jumpSpeed * driveSpeed / 4500 } // pad speed, scaled like the slider
        let before = driveDistance
        driveDistance += speed * dt
        driveBoost = max(0, driveBoost - dt)
        if driveAir != nil { driveAir!.t += dt; return } // no pads mid-air
        let n = path.points.count
        let i0 = Int(before / path.spacing), i1 = Int(driveDistance / path.spacing)
        guard i1 > i0 else { return }
        for i in (i0 + 1)...i1 {
            // A real fork in the route: stop on it and ask which way.
            if let fork = path.forks[i % n], forkStop.map({ abs($0 - i) > 3 }) ?? true {
                driveDistance = Float(i) * path.spacing
                forkStop = i
                forkPending = true
                onDriveFork?(fork)
                return
            }
            // Only on entering a pad, not every sample across it.
            guard let pad = path.pads[i % n], path.pads[(i - 1) % n] != pad else { continue }
            let y = path.point(at: Float(i) * path.spacing).y
            switch pad {
            case .boost: driveBoost = 1
            case .ramp(let airTime): driveBoost = 1; driveAir = (y, DriverPath.gravity * airTime / 2, 0, nil)
            case .jump(let speed, let height): driveAir = (y, height, 0, speed)
            }
            if driveAir != nil { return }
        }
    }

    func tick(dt: Float) {
        updateGizmo()
        if let driverPath, let cam {
            if !drivePaused, !forkPending { advanceDrive(driverPath, dt: dt) }
            // Each branch makes a path of its own length, so laps count on wrapping, not distance.
            if driveDistance >= driverPath.length {
                driveDistance -= driverPath.length
                forkStop = nil
                driveLap += 1
                onDriveLap?(driveLap)
            }
            var (eye, target) = driverPath.pose(at: driveDistance)
            let ground = driverPath.point(at: driveDistance).y
            if let a = driveAir {
                let y = a.launchY + a.vy * a.t - 0.5 * DriverPath.gravity * a.t * a.t
                // Landed: back down to the road while falling.
                if y <= ground, a.vy - DriverPath.gravity * a.t < 0 { driveAir = nil }
                let lift = max(0, y - ground)
                eye.y += lift
                target.y += lift * 0.7
            }
            cam.simdWorldPosition = eye
            cam.simdLook(at: target, up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
            pivot = target
            return
        }
        guard let cam, !keys.isEmpty else { return }
        var move = SIMD3<Float>(0, 0, 0)
        if keys.contains(13) { move += cam.simdWorldFront }  // W
        if keys.contains(1) { move -= cam.simdWorldFront }   // S
        if keys.contains(0) { move -= cam.simdWorldRight }   // A
        if keys.contains(2) { move += cam.simdWorldRight }   // D
        if keys.contains(14) { move.y += 1 }                 // E
        if keys.contains(12) { move.y -= 1 }                 // Q
        guard simd_length(move) > 0 else { return }
        let speed = moveSpeed * (Controls.shared.held(.view3DFlyFast) ? 4 : 1)
        let delta = simd_normalize(move) * speed * dt
        cam.simdWorldPosition += delta
        pivot += delta
    }

    // MARK: Mouse

    private func beginNavigation(at p: CGPoint) {
        guard let cam else { return }
        if let hit = hitPoint(p) { pivot = hit; panDepth = max(simd_length(hit - cam.simdWorldPosition), 10) }
        else { panDepth = max(simd_length(pivot - cam.simdWorldPosition), 10) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        dragged = false
        if editable, let handle = gizmoHandle(at: p) {
            drag = handle
        } else if editable, Controls.shared.held(.view3DBoxSelect, event.modifierFlags) {
            drag = .marquee(start: p) // Cmd-drag box select; a plain Cmd-click still toggles
        } else if editable, !Controls.shared.held(.view3DBoxSelect, event.modifierFlags),
                  let hit = hitTest(p, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue, .categoryBitMask: 1]).first,
                  isSelectedNode?(hit.node) == true, let target = gizmoTarget?(),
                  let start = groundPoint(p, y: target.position.y) {
            drag = .marker(planeY: target.position.y, start: start, applied: .zero)
        } else if editable, !Controls.shared.held(.view3DPan, event.modifierFlags), event.clickCount < 2 {
            drag = .marquee(start: p) // Edit mode: the left button picks/box-selects; middle or Alt+right orbits
        } else {
            beginNavigation(at: p)
            drag = Controls.shared.held(.view3DPan, event.modifierFlags) ? .pan : .orbit
            if event.clickCount == 2, let hit = hitPoint(p), let cam {
                frame(center: hit, radius: max(simd_length(hit - cam.simdWorldPosition) * 0.4, 500))
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        dragged = true
        let p = convert(event.locationInWindow, from: nil)
        switch drag {
        case .orbit: orbit(dx: Float(event.deltaX), dy: Float(event.deltaY))
        case .pan: pan(dx: Float(event.deltaX), dy: Float(event.deltaY))
        case .axis(let k, let last):
            guard let s = axisParam(k, p) else { return }
            onTranslate?(axisVector(k) * (s - last))
            drag = .axis(k, last: s)
        case .ring(let k, let last):
            guard let a = ringAngle(k, p) else { return }
            var delta = a - last
            if delta > .pi { delta -= 2 * .pi } else if delta < -.pi { delta += 2 * .pi }
            onRotate?(k, delta * 180 / .pi)
            drag = .ring(k, last: a)
        case .marquee(let start):
            let rect = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
            if marqueeLayer.superlayer == nil { wantsLayer = true; layer?.addSublayer(marqueeLayer) }
            marqueeLayer.frame = bounds
            marqueeLayer.path = CGPath(rect: rect, transform: nil)
        case .marker(let y, let start, let applied):
            guard let h = groundPoint(p, y: y) else { return }
            let flags = event.modifierFlags
            if Controls.shared.held(.view3DFaceCursor, flags) {
                onYawToward?(h) // Alt: turn to face the cursor
                return
            }
            var total = h - start
            total.y = 0
            if Controls.shared.held(.view3DStraight, flags) {
                // Keep to a straight line, the 2D editor's axis/diagonal lock.
                let ax = abs(total.x), az = abs(total.z)
                if ax > az * 2 { total.z = 0 }
                else if az > ax * 2 { total.x = 0 }
                else { let m = (ax + az) / 2; total.x = m * (total.x < 0 ? -1 : 1); total.z = m * (total.z < 0 ? -1 : 1) }
            }
            onTranslate?(total - applied)
            drag = .marker(planeY: y, start: start, applied: total)
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch drag {
        case .axis, .ring, .marker: if dragged { onManipulationEnd?() }
        case .marquee(let start):
            marqueeLayer.removeFromSuperlayer()
            if dragged {
                let p = convert(event.locationInWindow, from: nil)
                let rect = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
                onMarquee?(rect) { [weak self] w in
                    guard let self else { return nil }
                    let v = self.projectPoint(SCNVector3(w.x, w.y, w.z))
                    return v.z > 0 && v.z < 1 ? CGPoint(x: v.x, y: v.y) : nil
                }
                drag = .orbit
                return
            }
        default: break
        }
        if editable || clicksWhenNotEditable, !dragged, event.clickCount < 2 {
            let p = convert(event.locationInWindow, from: nil)
            onClick?(clickHit(p), Controls.shared.held(.view3DBoxSelect, event.modifierFlags))
        }
        drag = .orbit
    }

    private func clickHit(_ p: CGPoint) -> SCNHitTestResult? {
        guard clicksThroughStacks else {
            return hitTest(p, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue, .categoryBitMask: 1]).first
        }
        let hits = hitTest(p, options: [.searchMode: SCNHitTestSearchMode.all.rawValue, .categoryBitMask: 1, .backFaceCulling: false])
            .sorted { simd_distance_squared($0.simdWorldCoordinates, pointOfView?.simdWorldPosition ?? .zero) < simd_distance_squared($1.simdWorldCoordinates, pointOfView?.simdWorldPosition ?? .zero) }
        guard !hits.isEmpty else { lastClick = nil; return nil }
        let again = lastClick.map { hypot($0.point.x - p.x, $0.point.y - p.y) < 4 } ?? false
        let depth = again ? (lastClick!.depth + 1) % hits.count : 0
        lastClick = (p, depth)
        return hits[depth]
    }

    override func rightMouseDown(with event: NSEvent) {
        rightDragged = false
        beginNavigation(at: convert(event.locationInWindow, from: nil))
    }
    /// Right-drag pans; Alt+right-drag orbits (for mice without a middle button).
    override func rightMouseDragged(with event: NSEvent) {
        rightDragged = true
        if Controls.shared.held(.view3DOrbitRight, event.modifierFlags) { orbit(dx: Float(event.deltaX), dy: Float(event.deltaY)) }
        else { pan(dx: Float(event.deltaX), dy: Float(event.deltaY)) }
    }

    /// A right-click (not a right-drag pan) on a marker offers to delete it.
    override func rightMouseUp(with event: NSEvent) {
        guard !rightDragged else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard let hit = hitTest(p, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue, .categoryBitMask: 1]).first,
              editable, let item = contextDelete?(hit) else { return }
        let menu = NSMenu()
        let action = ClosureMenuItem(title: item.title) { [weak self] in self?.onDeleteHit?(hit) }
        action.isEnabled = item.enabled
        menu.autoenablesItems = false
        menu.addItem(action)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    override func otherMouseDown(with event: NSEvent) { beginNavigation(at: convert(event.locationInWindow, from: nil)) }
    override func otherMouseDragged(with event: NSEvent) {
        if Controls.shared.held(.view3DPan, event.modifierFlags) { pan(dx: Float(event.deltaX), dy: Float(event.deltaY)) }
        else { orbit(dx: Float(event.deltaX), dy: Float(event.deltaY)) }
    }

    override func scrollWheel(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if event.hasPreciseScrollingDeltas && !event.modifierFlags.contains(.command) {
            // Trackpad: swipe orbits (Blender on a Mac), Shift pans.
            if event.phase == .began { beginNavigation(at: p) }
            if Controls.shared.held(.view3DPan, event.modifierFlags) { pan(dx: -Float(event.scrollingDeltaX), dy: -Float(event.scrollingDeltaY)) }
            else { orbit(dx: -Float(event.scrollingDeltaX), dy: -Float(event.scrollingDeltaY)) }
        } else {
            let lines = event.hasPreciseScrollingDeltas ? Float(event.scrollingDeltaY) / 10 : Float(event.scrollingDeltaY)
            zoom(toward: p, amount: lines * 0.12)
        }
    }

    override func magnify(with event: NSEvent) {
        zoom(toward: convert(event.locationInWindow, from: nil), amount: Float(event.magnification) * 1.5)
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        if driverPath != nil {
            switch event.keyCode {
            case 49: onDriveKey?(.togglePause); return // Space
            case 53: onDriveKey?(.exit); return        // Esc
            default: break
            }
        }
        let c = Controls.shared
        if let fly = Self.flyKeys.first(where: { c.keyOnly($0.action, event) }) { keys.insert(fly.code); return }
        let views: [(ControlAction, () -> Void)] = [(.frameSelection, { self.perform(.frameSelection) }), (.frameTrack, { self.perform(.frameTrack) }),
                                                    (.returnToStart, { self.perform(.returnToStart) }), (.viewTop, { self.perform(.top) }),
                                                    (.viewFront, { self.perform(.front) }), (.viewSide, { self.perform(.side) }),
                                                    (.toggleOrtho, { self.perform(.toggleOrtho) })]
        if let hit = views.first(where: { c.keyOnly($0.0, event) }) { hit.1(); return }
        if c.matches(.deleteSelection, event) || (event.keyCode == 117 && c.binding(.deleteSelection).mods == 0) {
            if editable { onDelete?() }
        } else if event.keyCode == 115 { perform(.frameTrack) } // Home
        else { super.keyDown(with: event) }
    }

    /// The fly controls and the key code each one holds in `keys` while down.
    private static let flyKeys: [(action: ControlAction, code: UInt16)] = [(.flyForward, 13), (.flyBack, 1), (.flyLeft, 0), (.flyRight, 2), (.flyUp, 14), (.flyDown, 12)]

    override func keyUp(with event: NSEvent) {
        if let fly = Self.flyKeys.first(where: { Controls.shared.keyOnly($0.action, event) }), keys.remove(fly.code) != nil { return }
        super.keyUp(with: event)
    }

    override func resignFirstResponder() -> Bool {
        keys.removeAll()
        return super.resignFirstResponder()
    }
}

/// The minimap overlay: `map_model.brres`'s own triangles, flattened top-down and filled white,
/// drawn straight from its real geometry like the in-game HUD minimap.
private struct MinimapOverlay: View {
    let model: MDL0Model
    let bounds: (minX: Float, maxX: Float, minZ: Float, maxZ: Float)

    var body: some View {
        Canvas { context, size in
            let w = bounds.maxX - bounds.minX, h = bounds.maxZ - bounds.minZ
            guard w > 0, h > 0 else { return }
            let scale = min(size.width / CGFloat(w), size.height / CGFloat(h)) * 0.9
            let offsetX = (size.width - CGFloat(w) * scale) / 2
            let offsetY = (size.height - CGFloat(h) * scale) / 2
            func point(_ v: Vec3) -> CGPoint {
                CGPoint(x: offsetX + CGFloat(v.x - bounds.minX) * scale, y: offsetY + CGFloat(v.z - bounds.minZ) * scale)
            }
            for mesh in model.meshes {
                var path = Path()
                var i = 0
                while i + 2 < mesh.vertices.count {
                    path.move(to: point(mesh.vertices[i].position))
                    path.addLine(to: point(mesh.vertices[i + 1].position))
                    path.addLine(to: point(mesh.vertices[i + 2].position))
                    path.closeSubpath()
                    i += 3
                }
                context.fill(path, with: .color(.white))
                context.stroke(path, with: .color(.black.opacity(0.5)), lineWidth: 0.5)
            }
        }
    }
}

/// An `NSMenuItem` that runs a closure.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}
