import SwiftUI
import Combine
import UniformTypeIdentifiers

/// One plottable dot on the 2D top-down canvas (world X/Z plane. Y/height is ignored visually,
/// exactly like every real KMP editor's "top view").
private struct KMPPoint: Identifiable {
    let id: KMPSelection
    var x: Float
    var z: Float
    var color: Color
    var label: String
    var arrowAngle: Float? = nil
}

private struct KMPLink: Identifiable {
    let id = UUID()
    var from: SIMD2<Float>
    var to: SIMD2<Float>
    var color: Color
    /// The whole path/route this segment belongs to, when clicked line-selects that (a path group
    /// for enemy/item/checkpoint links, or the whole POTI route).
    /// Gate/rail links that don't belong to a group (a lone ungrouped enemy point) leave it nil.
    var owner: KMPSelection? = nil
}

/// One anchor of an in-progress pen-tool path (see `KMPEditorView.penToolBar`/`drawPenPath`),
/// Photoshop-style: `position` is where the user clicked, `handle` is the offset they dragged out
/// (zero for a plain click/"corner" anchor). The same `handle` is used mirrored in both directions
/// (added for the outgoing bezier control point, subtracted for the incoming one), the simple
/// "symmetric smooth point" a single click-drag produces in Photoshop, rather than modeling
/// independent in/out handles a second drag could produce.
private struct PenAnchor: Identifiable {
    let id = UUID()
    var position: SIMD2<Float>
    var handle: SIMD2<Float>
}

/// Installs a window-local scroll-wheel monitor over the canvas so trackpad two-finger scroll /
/// mouse wheel zooms it too (in addition to pinch), anchored at the cursor, like every real 2D
/// editor. A plain `.background` NSView can't reliably receive `scrollWheel` via hit-testing once
/// a sibling view already claims mouse/gesture hit-testing, so this uses an event monitor instead
/// and only acts on events whose location actually falls inside this view's own bounds.
/// Middle-drags started inside the view pan it (SwiftUI's `DragGesture` only sees the left button,
/// so this works in every mode, pen tool included). Delete/Backspace over the canvas deletes the selection.
private struct ScrollWheelZoomCatcher: NSViewRepresentable {
    var onScroll: (CGFloat, CGPoint) -> Void
    var onMiddleDrag: (CGSize) -> Void = { _ in }
    /// Delete, Copy and Paste over the canvas. Returns whether it handled the key (if not, the key
    /// goes on to whoever else wants it).
    var onKey: (ControlAction) -> Bool = { _ in false }
    /// The right-click menu for a point (empty: no menu).
    var menu: (CGPoint) -> [CanvasMenuItem] = { _ in [] }

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onScroll = onScroll
        v.onMiddleDrag = onMiddleDrag
        v.onKey = onKey
        v.menuItems = menu
        return v
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onScroll = onScroll
        nsView.onMiddleDrag = onMiddleDrag
        nsView.onKey = onKey
        nsView.menuItems = menu
    }

    final class CatcherView: NSView {
        var onScroll: ((CGFloat, CGPoint) -> Void)?
        var onMiddleDrag: ((CGSize) -> Void)?
        var onKey: ((ControlAction) -> Bool)?
        var menuItems: ((CGPoint) -> [CanvasMenuItem])?
        private var monitor: Any?
        private var middleDragging = false

        // Matches SwiftUI/Canvas's top-left-origin, y-down coordinate space.
        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .otherMouseDown, .otherMouseDragged, .otherMouseUp, .keyDown, .rightMouseDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                switch event.type {
                case .keyDown:
                    // Delete/Forward Delete with no modifiers, unless a text field or list (the
                    // project navigator's own Delete) has the keyboard.
                    // Only with the pointer over the canvas: a focused inspector control (picker,
                    // stepper) otherwise saw Delete remove a whole selected path.
                    let pointer = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                    guard let action = [ControlAction.deleteSelection, .copy, .paste].first(where: { Controls.shared.matches($0, event) }),
                          !(window.firstResponder is NSText), !(window.firstResponder is NSTableView), !self.isHiddenOrHasHiddenAncestor,
                          self.bounds.contains(pointer) else { return event }
                    return self.onKey?(action) == true ? nil : event
                case .rightMouseDown:
                    guard self.bounds.contains(point), !self.isHiddenOrHasHiddenAncestor,
                          let items = self.menuItems?(point), !items.isEmpty else { return event }
                    let menu = NSMenu()
                    menu.autoenablesItems = false
                    for item in items {
                        guard let title = item.title else { menu.addItem(.separator()); continue }
                        let m = ClosureMenuItem(title: title, run: item.action)
                        m.isEnabled = item.enabled
                        menu.addItem(m)
                    }
                    NSMenu.popUpContextMenu(menu, with: event, for: self)
                    return nil
                case .otherMouseDown:
                    if event.buttonNumber == 2, self.bounds.contains(point) { self.middleDragging = true }
                case .otherMouseDragged:
                    if self.middleDragging { self.onMiddleDrag?(CGSize(width: event.deltaX, height: event.deltaY)) }
                case .otherMouseUp:
                    self.middleDragging = false
                default:
                    if self.bounds.contains(point) { self.onScroll?(event.scrollingDeltaY, point) }
                }
                return event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

/// One row of the canvas's right-click menu; a nil title is a separator.
struct CanvasMenuItem {
    var title: String?
    var enabled = true
    var action: () -> Void = {}
    static let separator = CanvasMenuItem(title: nil)
}

private final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void
    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}

/// A candidate course-model BRRES the background layer could load: either a real file on disk
/// (folder project / Finder) or an in-memory entry inside a currently-open SZS archive.
private struct ModelCandidate: Identifiable {
    let id = UUID()
    let label: String
    let action: () -> Void
}

/// Same idea as `BRRESCandidate`, for the "Snap to Ground" collision-mesh picker.
private struct KCLCandidate: Identifiable {
    let id = UUID()
    let label: String
    let load: () -> Data?
}

struct KMPEditorView: View {
    @ObservedObject private var controls = Controls.shared
    @EnvironmentObject var workbench: WorkbenchState
    @ObservedObject var box: KMPDocumentBox
    let source: EditorTab.Source
    @AppStorage("kmpInspectorPropertiesExpanded") private var isPropertiesExpanded = true
    @AppStorage("kmpInspectorSectionsExpanded") private var isSectionsExpanded = true
    @AppStorage("kmpInspectorPathsExpanded") private var isPathsExpanded = true
    @AppStorage("kmpInspectorRoutesExpanded") private var isRoutesExpanded = true
    @AppStorage("kmpInspectorStageInfoExpanded") private var isStageInfoExpanded = false
    @AppStorage(SnapToGroundPrefs.startPointYPaddingKey) private var startPointYPadding = SnapToGroundPrefs.defaultStartPointYPadding
    /// Undo/redo + Photoshop-style history list (see `EditHistory`). Snapshots the whole document
    /// on discrete actions, drag-end moves, add/remove point, snap-to-ground, not on every
    /// inspector keystroke, so the list reads as meaningful steps rather than noise.
    @StateObject private var history: EditHistory

    init(box: KMPDocumentBox, source: EditorTab.Source) {
        self.box = box
        self.source = source
        _history = StateObject(wrappedValue: EditHistory(initial: box.doc.serialize()))
    }

    @State private var scale: CGFloat = 1.5
    @State private var gestureStartScale: CGFloat = 1.5
    @State private var panOffset: CGSize = .zero
    @State private var dragStartOffset: CGSize = .zero
    @State private var draggingPointID: KMPSelection?
    @State private var layers: Set<String> = ["KTPT", "ENPT/ENPH", "ITPT/ITPH", "CKPT/CKPH", "GOBJ", "JGPT", "CNPT", "MSPT", "AREA", "CAME", "POTI"]

    @State private var backgroundModel: BRRESDocumentBox?
    @State private var backgroundMDL0: MDL0Model?
    @State private var backgroundModelLabel: String?
    @State private var showBackgroundModel = true
    @State private var backgroundOpacity: Double = 0.2

    @State private var showInfo = false
    @AppStorage("kmpEditorShowSpreadsheet") private var showSpreadsheet = false
    @AppStorage("kmpEditorShowInspector") private var showInspector = true
    @State private var showIntroCameras = false
    @State private var showEnemyToItem = false
    @State private var lapReport: CheckpointVerifier.Report?
    /// Double Dash's Check Laps: what `BOL.problems` finds (empty: all clear).
    @State private var bolProblems: [String]?
    /// Checkpoints the last Check Laps flagged, drawn red until the next edit.
    @State private var flaggedCheckpoints: Set<Int> = []
    @AppStorage("showArchiveInfoButton") private var showArchiveInfoButton = true
    /// Result of the last "Make Testable" pass, `nil` means it hasn't been run yet this session;
    /// an empty array (shown in `showTestableResult`'s popover) means it ran and found nothing to fix.
    @State private var testableFixes: [String]?
    @State private var showTestableResult = false
    /// User-chosen overrides for `drawCourseModelSilhouette`'s per-material auto color, keyed the
    /// same way that function keys its own dictionary lookup (`materialKey`), lets someone make a
    /// specific surface (e.g. the road) visually pop out from the auto-assigned hash color, which
    /// is well-spread but not chosen with any particular material in mind.
    @State private var materialColorOverrides: [String: Color] = [:]
    @State private var showMaterialColors = false
    /// A material's real `Kd` diffuse color, read from an OBJ background model's companion .mtl
    /// file (see `loadBackgroundModel(fromOBJ:label:objURL:)`), used as the *default* color ahead
    /// of the arbitrary auto-hash one, since it's the actual color the model was authored with, not
    /// a manual `materialColorOverrides` choice (which still wins over this if someone sets one).
    @State private var materialMTLColors: [String: Color] = [:]

    /// Section types it makes sense to place with the pen tool (see `penToolBar`), every point
    /// kind `addPointMenu` already offers; excludes STGI (not a point at all) and POTI (routes are
    /// built one point at a time via "New Route" + the Routes list's Add Point, not sketched as a
    /// smooth path the way a driving line is).
    private static let penEligibleSections: [KMPSection] = [.ktpt, .enpt, .itpt, .ckpt, .gobj, .jgpt, .cnpt, .mspt, .area, .came]
    /// What Shift-drag can box-select: every pen-tool type plus Route Points (which the pen tool
    /// doesn't draw, since a route belongs to one object/camera rather than a path).
    private static let marqueeSections: [KMPSection] = penEligibleSections + [.poti]

    @State private var penToolActive = false
    @State private var penToolSection: KMPSection = .enpt
    @State private var penToolSpacing: Double = 5000
    @State private var penAnchors: [PenAnchor] = []
    /// Screen-space start/current of a handle currently being dragged out of the anchor about to be
    /// placed, purely for the live preview line in `drawPenPath`; the committed handle (in world
    /// units) is computed once in `commitPenAnchor` when the drag ends.
    @State private var pendingPenDrag: (startScreen: CGPoint, currentScreen: CGPoint)?

    /// The multiply factor the width slider uses to expand/shrink every selected point's width at
    /// once (see `scaleMultiSelectionWidth`).
    @State private var widthScaleFactor: Double = 1

    /// Points picked up by a Shift-drag marquee (see `commitMarqueeSelection`), all of one chosen
    /// type, separate from `box.selection` (the single point the inspector edits) since a
    /// marquee's whole purpose is picking several points at once for a bulk action (currently just
    /// deletion; see `deleteMultiSelection`).
    @State private var multiSelection: Set<KMPSelection> = []
    /// The canvas' size, so the inspector's New rows can add at the centre of the view.
    /// Outliner rows currently open (section magic, or "ENPH#2" for a path group); selecting something opens its way down.
    @State private var outlineOpen: Set<String> = []
    @State private var canvasSize = CGSize(width: 600, height: 400)
    /// What a box-select or Select All picks up: one chosen point type, whichever type is picked
    /// first (Auto), or everything on screen.
    enum SelectionScope: Hashable { case auto, allVisible, type(KMPSection) }
    @State private var selectionScope: SelectionScope = .auto
    @State private var clipboardNote: String?
    /// Whether the drag gesture in progress is a Shift-drag marquee rather than a pan/point-move --
    /// decided once when the drag starts (see `dragGesture`) so it can't flip mid-gesture if Shift
    /// happens to be released before the mouse button is.
    @State private var marqueeModeActive = false
    /// Live marquee rectangle in screen space, drawn by `draw(in:size:)` while dragging.
    @State private var marqueeRect: CGRect?

    /// The course's real collision mesh, used purely as ground-height reference for "Snap to
    /// Ground" (Auto Y), see that feature's doc comment below for the MagicY prior art.
    @State private var collisionMesh: KCLDocument?
    @State private var collisionLabel: String?

    private let minScale: CGFloat = 0.1
    private let maxScale: CGFloat = 20

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showSpreadsheet {
                KMPSpreadsheetView(box: box, onCommit: pushHistory)
            } else {
                HSplitView {
                    canvasArea
                        .frame(minWidth: 400)
                    if showInspector {
                        inspector
                            .frame(minWidth: 300, idealWidth: 320, maxWidth: 420)
                    }
                }
            }
        }
        // On the whole editor (not just the canvas) so objects added in the spreadsheet import too.
        .overlay(alignment: .bottom) {
            if box.doc.isBOL {
                MissingDoubleDashObjectFilesBanner(objectIDs: Set(box.doc.gobj.map(\.objectID)),
                                                   present: presentDoubleDashObjectFiles, install: installObjectFiles)
                    .padding(.bottom, 56)
            } else {
                MissingObjectFilesBanner(objectIDs: Set(box.doc.gobj.map(\.objectID)),
                                         present: presentObjectFileNames, install: installObjectFiles)
                    .padding(.bottom, 56)
            }
        }
        .task { autoDetectCourseModel(); autoDetectCollision() }
    }

    private var header: some View {
        HStack {
            Button { runMakeTestable() } label: { Label("Make Testable", systemImage: "checkmark.seal") }
                .help("Fills in whatever this KMP is missing to actually load and be raced from the KMP side, a start point, respawn points, checkpoints, dead-end paths, and any camera/object/area pointing at a route, camera, or point that doesn't exist. For a battle arena: one start point per player 0-11, 4 battle respawns, respawn points and a CPU loop. Leaves anything already set up alone.")
                .popover(isPresented: $showTestableResult) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let testableFixes, !testableFixes.isEmpty {
                            Text("Fixed:").font(.headline)
                            ForEach(testableFixes, id: \.self) { Text("\u{2022} \($0)").font(.caption) }
                        } else {
                            Text("Already testable").font(.headline)
                            Text("Nothing missing from the KMP side.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                    .frame(width: 320, alignment: .leading)
                }
            Menu {
                Button { showIntroCameras = true } label: { Label("Intro Cameras...", systemImage: "video") }
                    .help("Create, reorder and preview this track's opening camera sequence in 3D.")
                if !box.doc.ckpt.isEmpty, !BattleArena.isBattle(box.doc) {
                    Button { runRespawnPerCheckpoint() } label: { Label("Respawn Point per Checkpoint", systemImage: "arrow.uturn.backward.circle") }
                        .help("Replaces the respawn points with one per checkpoint: in the middle of each checkpoint, facing the next one, snapped to the collision's ground (load a .kcl first), with every checkpoint set to respawn at its own. Undo restores the old ones.")
                }
                if !box.doc.enph.isEmpty, !box.doc.isBOL {
                    Button { showEnemyToItem = true } label: { Label("Enemy Paths to Item Paths...", systemImage: "arrow.triangle.branch") }
                        .help("Replaces the item paths with a copy of the enemy paths, leaving out any branches you pick that items shouldn't take.")
                }
            } label: {
                Label("Tools", systemImage: "wrench.and.screwdriver")
            }
            .fixedSize()
            .sheet(isPresented: $showEnemyToItem) {
                EnemyToItemPathsSheet(box: box) { pushHistory("Enemy Paths to Item Paths") }
            }
            .sheet(isPresented: $showIntroCameras) {
                CameraSequenceEditorView(box: box, courseModel: backgroundMDL0,
                                         textures: backgroundModel.map { MDL0SceneKit.textureImages(in: $0.doc) } ?? [:],
                                         onCommit: { pushHistory($0) })
            }
            if box.doc.isBOL, box.doc.ktpt.count == 8 {
                Label("Battle Arena", systemImage: "flag.2.crossed")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("This course data is a Double Dash battle arena (8 start points, one per player). Make Testable and the archive's Verify use the battle rules; save it over a battle slot such as Mini1.arc.")
            } else if box.doc.isBOL {
                Button { bolProblems = BOL.problems(box.doc) } label: {
                    Label("Check Laps", systemImage: bolProblems.map { $0.isEmpty ? "flag.checkered" : "exclamationmark.triangle" } ?? "flag.checkered")
                }
                .help("Checks the course data the way Double Dash needs it: one start, a looping enemy route, checkpoint groups whose quads are all convex (a bent one freezes the game while loading), respawn points that rejoin the route, and intro cameras that don't loop.")
                .popover(isPresented: Binding(get: { bolProblems != nil }, set: { if !$0 { bolProblems = nil } })) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let bolProblems, !bolProblems.isEmpty {
                            Label("\(bolProblems.count) problem\(bolProblems.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
                                .font(.headline).foregroundStyle(.orange)
                            ScrollView {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(bolProblems, id: \.self) { Text("\u{2022} \($0)").font(.caption).fixedSize(horizontal: false, vertical: true) }
                                }
                            }
                            .frame(maxHeight: 320)
                            Text("Make Testable fixes most of these.").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Label("Ready to race", systemImage: "flag.checkered").font(.headline).foregroundStyle(.green)
                            Text("Start, enemy route, checkpoints, respawns and intro cameras all check out.").font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Check Again") { bolProblems = BOL.problems(box.doc) }
                    }
                    .padding()
                    .frame(width: 380, alignment: .leading)
                }
            } else if BattleArena.isBattle(box.doc) {
                Label("Battle Arena", systemImage: "flag.2.crossed")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("This KMP is a battle arena (per-player start points, battle respawns, no checkpoints). Make Testable and the archive's Verify use the battle rules; save it over a battle slot such as block_battle.szs.")
            } else if !box.doc.isBOL {
                Button { runLapCheck() } label: {
                    Label("Check Laps", systemImage: lapReport.map { $0.passed ? "flag.checkered" : "exclamationmark.triangle" } ?? "flag.checkered")
                }
                .help("Checks the checkpoints the way the game uses them, groups, key checkpoints, quad shapes, then drives the CPU route round three laps and confirms every lap counts.")
                .popover(isPresented: Binding(get: { lapReport != nil }, set: { if !$0 { lapReport = nil } })) {
                    if let lapReport { lapReportView(lapReport) }
                }
            }
            Spacer()
            Picker("View", selection: $showSpreadsheet) {
                Label("Canvas", systemImage: "map").tag(false)
                Label("Advanced", systemImage: "tablecells").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Advanced shows every field of every entry as an editable spreadsheet, one section at a time.")
            if !showSpreadsheet {
                Button { showInspector.toggle() } label: { Label(showInspector ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.trailing") }
                    .labelStyle(.iconOnly)
                    .keyboardShortcut("i", modifiers: [.command, .option])
                    .help(showInspector ? "Hide the inspector to give the map the whole width (Option-Command-I)." : "Show the inspector (Option-Command-I).")
            }
            if showArchiveInfoButton {
                Button { showInfo.toggle() } label: { Label("Info", systemImage: "info.circle") }
                    .help("Learn about which games use the KMP format and what its sections mean")
                    .popover(isPresented: $showInfo) { FormatInfoPopoverView(title: "KMP Format Info", games: KMPFormatInfo.games) }
            }
        }
        .padding(8)
    }

    private func lapReportView(_ report: CheckpointVerifier.Report) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(report.passed ? "Laps will count" : "Laps may not count",
                  systemImage: report.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .font(.headline)
                .foregroundStyle(report.passed ? .green : .red)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(report.issues) { issue in
                        Button { if let i = issue.checkpoint { revealCheckpoint(i) } } label: {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : issue.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                                    .foregroundStyle(issue.severity == .error ? .red : issue.severity == .warning ? .orange : .secondary)
                                Text(issue.message).font(.caption).multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(issue.checkpoint == nil)
                        .help(issue.checkpoint.map { "Select checkpoint \($0 + 1)" } ?? "")
                    }
                }
            }
            .frame(maxHeight: 320)
            Button("Check Again") { runLapCheck() }
        }
        .padding()
        .frame(width: 380, alignment: .leading)
    }

    private func runLapCheck() {
        let report = CheckpointVerifier.verify(box.doc)
        flaggedCheckpoints = Set(report.issues.filter { $0.severity != .info }.compactMap(\.checkpoint))
        lapReport = report
    }

    /// Selects a checkpoint and centres the canvas on it.
    private func revealCheckpoint(_ i: Int) {
        guard box.doc.ckpt.indices.contains(i) else { return }
        layers.insert("CKPT/CKPH")
        box.selection = .ckpt(i)
        let c = box.doc.ckpt[i]
        let x = CGFloat(c.left.x + c.right.x) / 2, z = CGFloat(c.left.y + c.right.y) / 2
        panOffset = CGSize(width: -x * scale * 0.05, height: -z * scale * 0.05)
        dragStartOffset = panOffset
    }

    // MARK: Canvas

    private var canvasArea: some View {
        VStack(spacing: 0) {
            backdropBar
            Divider()
            GeometryReader { geo in
                ZStack {
                    Color.clear.onAppear { canvasSize = geo.size }.onChange(of: geo.size) { _, new in canvasSize = new }
                    modelBackgroundLayer
                    Canvas { context, size in
                        draw(in: &context, size: size)
                    }
                    .background(Color(nsColor: .textBackgroundColor).opacity(showBackgroundModel && backgroundModel != nil ? 0 : 1))
                    .background(ScrollWheelZoomCatcher(onScroll: { deltaY, location in
                        zoom(by: 1 + deltaY * 0.01, around: location, size: geo.size)
                    }, onMiddleDrag: { delta in
                        panOffset.width += delta.width
                        panOffset.height += delta.height
                        dragStartOffset = panOffset
                    }, onKey: handleCanvasKey, menu: { pointMenu(at: $0, size: geo.size) }))
                    .gesture(
                        dragGesture(size: geo.size)
                            .exclusively(before: SpatialTapGesture().onEnded { value in
                                handleTap(at: value.location, size: geo.size)
                            })
                    )
                    .gesture(MagnificationGesture()
                        .onChanged { value in
                            scale = clampedScale(gestureStartScale * value)
                        }
                        .onEnded { value in
                            scale = clampedScale(gestureStartScale * value)
                            gestureStartScale = scale
                        }
                    )
                }
                .overlay(alignment: .bottomTrailing) {
                    zoomControls(size: geo.size)
                }
                .overlay(alignment: .topLeading) { layerList }
                .overlay(alignment: .bottomLeading) {
                    HistoryControlsView(history: history, onRestore: restoreFromHistory)
                        .padding(6)
                        .background(.bar, in: RoundedRectangle(cornerRadius: 8))
                        .padding(10)
                }
                .overlay(alignment: .top) {
                    VStack(spacing: 8) {
                        if penToolActive {
                            penToolBar(size: geo.size)
                        } else {
                            multiSelectBar
                        }
                        // ⌘D: duplicate the selected object/start/respawn/area/camera. Hidden
                        // button, like Select All, so a text field's own shortcuts still win.
                        Button("Duplicate") { if let sel = box.selection { duplicateNearby(sel, size: geo.size) } }
                            .shortcut(.duplicate)
                            .disabled(box.selection.map(isDuplicable) != true)
                            .frame(width: 1, height: 1)
                            .opacity(0.01)
                    }
                }
            }
        }
    }

    // MARK: Object files from the base game

    /// What's already beside this course.kmp: its archive's contents, or its folder's.
    private func presentObjectFileNames() -> Set<String> {
        switch source {
        case .file(let url): return BaseGameLibrary.names(inFolder: url.deletingLastPathComponent())
        case .szsEntry(let archive, let node): return BaseGameLibrary.names(in: node.parent ?? archive.root)
        case .discEntry: return []
        }
    }

    /// The files in the Double Dash course's `objects/` folder, lowercased.
    private func presentDoubleDashObjectFiles() -> Set<String> {
        switch source {
        case .file(let url):
            let dir = url.deletingLastPathComponent().appendingPathComponent("objects")
            return Set(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).map { $0.lowercased() })
        case .szsEntry(let archive, let node):
            let root = node.parent ?? archive.root
            return Set((root.children.first { $0.isDirectory && $0.name.lowercased() == "objects" }?.children ?? []).map { $0.name.lowercased() })
        case .discEntry: return []
        }
    }

    /// Puts imported object files next to this course.kmp, into its archive (marked unsaved, like
    /// any other archive edit) or its folder.
    private func installObjectFiles(_ files: [(path: [String], data: Data)]) {
        switch source {
        case .file(let url):
            let dir = url.deletingLastPathComponent()
            for f in files {
                let dest = f.path.reduce(dir) { $0.appendingPathComponent($1) }
                do {
                    try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try f.data.write(to: dest, options: .atomic)
                } catch { workbench.report(error) }
            }
            workbench.refreshFolderTree()
        case .szsEntry(let archive, let node):
            let dir = node.parent ?? archive.root
            for f in files { dir.setFile(at: f.path, data: f.data) }
            archive.isDirty = true
            archive.objectWillChange.send()
        case .discEntry:
            workbench.log("Importing object files into a course on a disc image isn't supported, extract the course to a folder first.")
            return
        }
        workbench.log("Imported \(files.count) object file(s) from the base game: \(files.map { $0.path.joined(separator: "/") }.joined(separator: ", ")).")
    }

    // MARK: History

    private func pushHistory(_ label: String) {
        flaggedCheckpoints = []
        history.push(box.doc.serialize(), label: label)
    }

    private func restoreFromHistory(_ data: Data) {
        guard let doc = try? KMPDocument.parse(data) else { return }
        box.doc = doc
        box.selection = nil
        box.isDirty = true
    }

    /// Canvas layers, keyed by the section magic(s) `draw` checks, with the names shown to the user.
    private static let layerNames: [(key: String, label: String)] = [
        ("KTPT", "Start Points"), ("ENPT/ENPH", "CPU Paths"), ("ITPT/ITPH", "Item Paths"), ("CKPT/CKPH", "Checkpoints"),
        ("JGPT", "Respawn Points"), ("GOBJ", "Objects"), ("POTI", "Object & Camera Routes"), ("AREA", "Areas"),
        ("CAME", "Cameras"), ("CNPT", "Cannon Targets"), ("MSPT", "Battle Respawns"),
    ]
    @AppStorage("kmpEditorLayersExpanded") private var isLayersExpanded = true

    /// A collapsible checklist of what the canvas shows, floating over its top-left corner.
    private var layerList: some View {
        DisclosureGroup(isExpanded: $isLayersExpanded) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Self.layerNames, id: \.key) { layer in
                    Toggle(layer.label, isOn: Binding(
                        get: { layers.contains(layer.key) },
                        set: { on in if on { layers.insert(layer.key) } else { layers.remove(layer.key) } }
                    ))
                    .toggleStyle(.checkbox)
                    .help(Self.layerTooltip(layer.key))
                }
                HStack {
                    Button("All") { layers = Set(Self.layerNames.map(\.key)) }
                    Button("None") { layers = [] }
                }
                .buttonStyle(.link)
                .padding(.top, 2)
            }
            .padding(.top, 4)
        } label: {
            Text("Show").font(.caption.weight(.semibold))
        }
        .font(.caption)
        .padding(8)
        .frame(width: 180, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(10)
    }

    // MARK: Course model background

    /// Draws the real course model's ground-plane silhouette (every mesh's triangles, projected
    /// onto the same X/Z top-down plane the KMP points already use) directly behind the grid --
    /// drawn in-canvas rather than as a separate overlay so it pans/zooms in perfect lockstep
    /// with the points, letting them be placed directly against the actual track shape.
    /// Colored per *material* (each mesh's real, RenderTree-resolved `textureName`, see
    /// `MDL0Mesh`'s doc comment) rather than per mesh, so meshes that share one texture (e.g. a
    /// track's road split across several polygon objects) read as the same surface instead of a
    /// patchwork of unrelated colors, while different materials (road vs. grass vs.
    /// walls) still read apart at a glance while placing points. Falls back to the mesh's own name
    /// for the rare mesh with no resolved material (no draw call, or a pure vertex-color material).
    private func drawCourseModelSilhouette(_ model: MDL0Model, in context: inout GraphicsContext, size: CGSize) {
        for (index, mesh) in model.meshes.enumerated() {
            var path = Path()
            var i = 0
            while i + 2 < mesh.vertices.count {
                let a = worldToScreen(mesh.vertices[i].position.x, mesh.vertices[i].position.z, size: size)
                let b = worldToScreen(mesh.vertices[i + 1].position.x, mesh.vertices[i + 1].position.z, size: size)
                let c = worldToScreen(mesh.vertices[i + 2].position.x, mesh.vertices[i + 2].position.z, size: size)
                path.move(to: a); path.addLine(to: b); path.addLine(to: c); path.closeSubpath()
                i += 3
            }
            let key = Self.materialKey(mesh, index: index)
            context.fill(path, with: .color(effectiveMaterialColor(key, fallbackIndex: index).opacity(backgroundOpacity)))
        }
    }

    /// A material's color, in priority order: an explicit user override, then its real `Kd` from
    /// a companion .mtl (if this background came from an .obj with one), then the arbitrary but
    /// stable auto-hash color as a last resort.
    private func effectiveMaterialColor(_ key: String, fallbackIndex: Int) -> Color {
        materialColorOverrides[key] ?? materialMTLColors[key] ?? Self.materialColor(name: key, fallbackIndex: fallbackIndex)
    }

    /// The identity used both to look up a user color override and (when there isn't one) to hash
    /// an auto color, a mesh's resolved texture name, or its own name/index if that's empty. Kept
    /// as one function so `drawCourseModelSilhouette` and the "Material Colors" popover always
    /// agree on what counts as "the same material."
    private static func materialKey(_ mesh: MDL0Mesh, index: Int) -> String {
        let name = mesh.textureName ?? mesh.name
        return name.isEmpty ? "mesh\(index)" : name
    }

    /// A stable, well-spread color per material (keyed by its resolved texture name, see
    /// `drawCourseModelSilhouette`), so the same material always gets the same color across
    /// redraws/reopens rather than a color that shuffles with dictionary/array ordering. This is
    /// only the *default*, `materialColorOverrides` takes priority when the user has picked their
    /// own color for a material via the "Material Colors" popover.
    private static func materialColor(name: String, fallbackIndex: Int) -> Color {
        var hasher = Hasher()
        hasher.combine(name.isEmpty ? "mesh\(fallbackIndex)" : name)
        let hash = hasher.finalize()
        let hue = Double(UInt32(bitPattern: Int32(truncatingIfNeeded: hash)) % 360) / 360
        return Color(hue: hue, saturation: 0.7, brightness: 0.95)
    }

    /// Every distinct material in the current background model, paired with its current effective
    /// color (an override if one's set, else the auto hash color), backs the "Material Colors"
    /// popover's list. Empty (and so the popover shows nothing to pick) whenever there's no parsed
    /// MDL0 model, e.g. the texture-collage fallback background has no per-material silhouette to color.
    private var materialList: [(key: String, color: Color)] {
        guard let backgroundMDL0 else { return [] }
        var seen = Set<String>()
        var out: [(String, Color)] = []
        for (index, mesh) in backgroundMDL0.meshes.enumerated() {
            let key = Self.materialKey(mesh, index: index)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            out.append((key, effectiveMaterialColor(key, fallbackIndex: index)))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// Fallback for when this course BRRES's MDL0 couldn't be parsed for real geometry (see
    /// `MDL0Parser`'s doc comment for what it doesn't support yet): a dim, non-interactive collage
    /// of its textures instead, purely as ambient visual reference rather than a to-scale outline.
    @ViewBuilder
    private var modelBackgroundLayer: some View {
        if showBackgroundModel, backgroundMDL0 == nil, let backgroundModel {
            let images = backgroundTextureImages(backgroundModel)
            if !images.isEmpty {
                let cols = max(1, Int(ceil(sqrt(Double(images.count)))))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: cols), spacing: 1) {
                    ForEach(Array(images.enumerated()), id: \.offset) { _, img in
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    }
                }
                .opacity(backgroundOpacity)
                .allowsHitTesting(false)
                .clipped()
            }
        }
    }

    private func backgroundTextureImages(_ model: BRRESDocumentBox) -> [NSImage] {
        model.doc.resources.filter { $0.magic == "TEX0" }.compactMap { r in
            guard let v = TEX0View(r), let rgba = v.decodeRGBA(palette: model.palette(for: r)) else { return nil }
            return ImageUtil.nsImage(fromRGBA: rgba, width: v.width, height: v.height)
        }
    }

    /// One row for what the points are placed against: the course model backdrop and the
    /// collision used for Snap to Ground, with a single menu to choose either.
    private var backdropBar: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $showBackgroundModel) {
                Label(backgroundModelLabel ?? "Course Model", systemImage: "photo.on.rectangle")
            }
            .toggleStyle(.button)
            .disabled(backgroundModel == nil && backgroundMDL0 == nil)
            .help("Shows the track's real 3D model as a faint backdrop so you can place points against the actual course geometry instead of guessing blind. Purely a visual aid, it isn't saved into the .kmp.")
            if backgroundModel != nil || backgroundMDL0 != nil {
                Slider(value: $backgroundOpacity, in: 0.05...0.8).frame(width: 80)
                    .help("Backdrop opacity")
            }
            if backgroundMDL0 != nil {
                Button { showMaterialColors = true } label: { Image(systemName: "paintpalette") }
                    .buttonStyle(.borderless)
                    .help("Pick your own colour for each material in the course model, instead of the auto-assigned one, makes it easier to tell surfaces apart (e.g. the road from the grass) while placing points.")
                    .popover(isPresented: $showMaterialColors) { materialColorsPopover }
            }
            Divider().frame(height: 14)
            Label(collisionLabel ?? "No collision", systemImage: collisionMesh != nil ? "checkmark.seal.fill" : "xmark.seal")
                .foregroundStyle(collisionMesh != nil ? .primary : .secondary)
                .lineLimit(1)
                .help(collisionMesh != nil ? "Collision loaded: Snap to Ground uses it." : "Load the course's collision (.kcl) to snap points to the ground.")
            Spacer()
            Button("Snap All to Ground") { snapAllToGround() }
                .disabled(collisionMesh == nil)
                .help("Raycasts every visible point straight down onto the collision mesh below and sets its height (Y) to match, an easy way to fix points floating above or sunk below the track after moving them on this 2D top-down view.")
            Menu {
                Section("Course Model") {
                    Button("Auto-Detect") { backgroundModel = nil; backgroundMDL0 = nil; backgroundModelLabel = nil; autoDetectCourseModel() }
                    let candidates = projectModelCandidates
                    if !candidates.isEmpty {
                        Menu("From Project") { ForEach(candidates) { c in Button(c.label) { c.action() } } }
                    }
                    Button("From Finder... (.brres/.bmd/.szs/.arc/.obj)") { chooseFromFinder() }
                    if backgroundModel != nil || backgroundMDL0 != nil {
                        Button("Clear Model", role: .destructive) { backgroundModel = nil; backgroundMDL0 = nil; backgroundModelLabel = nil }
                    }
                }
                Section("Collision") {
                    Button("Auto-Detect") { collisionMesh = nil; collisionLabel = nil; autoDetectCollision() }
                    let kcls = projectKCLCandidates
                    if !kcls.isEmpty {
                        Menu("From Project") { ForEach(kcls) { c in Button(c.label) { loadCollision(from: c.load(), label: c.label) } } }
                    }
                    Button("From Finder...") { chooseCollisionFromFinder() }
                    if collisionMesh != nil {
                        Button("Clear Collision", role: .destructive) { collisionMesh = nil; collisionLabel = nil }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Choose the course model and collision")
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    /// Lets the user override the course model's per-material auto color (see `materialList`) --
    /// one `ColorPicker` per distinct material, defaulting to that material's current effective
    /// color so opening this doesn't visually change anything until a color is actually touched.
    private var materialColorsPopover: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Material Colours").font(.headline)
                Text("Override the auto-assigned colour for a material in the course model background, to make specific surfaces (e.g. the road) easier to tell apart while placing points. Purely visual, not saved into the .kmp.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
                ForEach(materialList, id: \.key) { entry in
                    HStack {
                        ColorPicker("", selection: Binding(
                            get: { materialColorOverrides[entry.key] ?? entry.color },
                            set: { materialColorOverrides[entry.key] = $0 }
                        ))
                        .labelsHidden()
                        Text(entry.key).font(.caption).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if materialColorOverrides[entry.key] != nil {
                            Button { materialColorOverrides[entry.key] = nil } label: { Image(systemName: "arrow.uturn.backward.circle") }
                                .buttonStyle(.plain)
                                .help("Reset to the auto-assigned colour")
                        }
                    }
                }
                if !materialColorOverrides.isEmpty {
                    Divider()
                    Button("Reset All", role: .destructive) { materialColorOverrides.removeAll() }
                }
            }
            .padding()
        }
        .frame(width: 300, height: min(CGFloat(materialList.count) * 32 + 140, 420))
    }

    /// Looks for a sibling `.brres` next to this KMP, same folder on disk, or same directory
    /// inside the SZS archive it came from, which is where every real course puts its model.
    /// Prefers the one real Nintendo naming actually uses (`<basename>_model.brres`, e.g.
    /// `course.kmp` -> `course_model.brres`, confirmed against a real MKWii disc) over just
    /// grabbing whichever `.brres` happens to be listed/enumerated first: a real course folder or
    /// archive typically holds a dozen *other* `.brres` siblings too (item boxes, cannons, Mii
    /// statues, decorations, the vrcorn skybox...), so a plain "first match" can easily background
    /// the wrong, much smaller model instead of the actual track geometry, which then looks like
    /// it isn't colored per-texture at all, because it's simply the wrong model. Falls back to the
    /// first `.brres` found if no name match exists, rather than showing nothing.
    private func autoDetectCourseModel() {
        guard backgroundModel == nil else { return }
        switch source {
        case .file(let url):
            let dir = url.deletingLastPathComponent()
            let baseName = url.deletingPathExtension().lastPathComponent
            guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
            let candidates = items.filter { Self.isCourseModelFile($0.lastPathComponent) }
            if let match = preferredCourseModel(candidates.map { ($0.lastPathComponent, $0) }, baseName: baseName) {
                loadBackgroundModel(from: try? Data(contentsOf: match), label: match.lastPathComponent)
            }
        case .szsEntry(_, let node):
            guard let siblings = node.parent?.children else { return }
            let baseName = (node.name as NSString).deletingPathExtension
            let candidates = siblings.filter { !$0.isDirectory && Self.isCourseModelFile($0.name) }
            if let match = preferredCourseModel(candidates.map { ($0.name, $0) }, baseName: baseName) {
                loadBackgroundModel(from: match.data, label: match.name)
            }
        case .discEntry:
            break
        }
    }

    /// Picks `<baseName>_model.brres` out of `candidates` if present, else just the first one --
    /// see `autoDetectCourseModel`'s doc comment for why the exact-name match matters.
    private func preferredCourseModel<T>(_ candidates: [(name: String, value: T)], baseName: String) -> T? {
        let wanted = "\(baseName)_model.brres".lowercased()
        return candidates.first(where: { $0.name.lowercased() == wanted })?.value
            ?? candidates.first(where: { $0.name.lowercased().hasSuffix("_course.bmd") })?.value // Double Dash
            ?? candidates.first?.value
    }

    /// A Mario Kart Wii `.brres` or a Double Dash course `.bmd` (not its sky or objects).
    private static func isCourseModelFile(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.hasSuffix(".brres") || n.hasSuffix("_course.bmd")
    }

    // MARK: Collision mesh + "Snap to Ground" (Auto Y)

    /// Reference bar for the course's real collision mesh, used only as ground-height data for
    /// "Snap to Ground" below, separate from the visual `courseModelBar` background, since a
    /// track's `.kcl` and its `.brres` are two different sibling files.
    /// Looks for a sibling `.kcl` next to this KMP, the same way `autoDetectCourseModel` finds the
    /// sibling `.brres`, every real course puts both in the same place.
    private func autoDetectCollision() {
        guard collisionMesh == nil else { return }
        switch source {
        case .file(let url):
            let dir = url.deletingLastPathComponent()
            if let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
               let match = items.first(where: { ["kcl", "bco"].contains($0.pathExtension.lowercased()) }) {
                loadCollision(from: try? Data(contentsOf: match), label: match.lastPathComponent)
            }
        case .szsEntry(_, let node):
            if let siblings = node.parent?.children,
               let match = siblings.first(where: { !$0.isDirectory && ["kcl", "bco"].contains(($0.name as NSString).pathExtension.lowercased()) }) {
                loadCollision(from: match.data, label: match.name)
            }
        case .discEntry:
            break
        }
    }

    private func loadCollision(from data: Data?, label: String) {
        guard let data, let doc = try? KCLDocument.parse(data) else {
            if data != nil { workbench.log("Couldn't load \(label) as a collision (.kcl) file.") }
            return
        }
        collisionMesh = doc
        collisionLabel = label
    }

    private var projectKCLCandidates: [KCLCandidate] {
        var out: [KCLCandidate] = []
        if let root = workbench.projectRoot {
            collectKCL(in: root, into: &out)
        }
        if case .szsEntry(let archive, _) = source {
            collectKCL(in: archive.root, into: &out)
        }
        return out
    }

    private func collectKCL(in node: ProjectNode, into out: inout [KCLCandidate]) {
        guard out.count < 40 else { return }
        if !node.isDirectory, ["kcl", "bco"].contains(node.url.pathExtension.lowercased()) {
            out.append(KCLCandidate(label: node.name) { try? Data(contentsOf: node.url) })
        }
        for c in node.children { collectKCL(in: c, into: &out) }
    }

    private func collectKCL(in node: U8Node, into out: inout [KCLCandidate]) {
        guard out.count < 40 else { return }
        if !node.isDirectory, ["kcl", "bco"].contains((node.name as NSString).pathExtension.lowercased()) {
            out.append(KCLCandidate(label: node.name) { node.data })
        }
        for c in node.children { collectKCL(in: c, into: &out) }
    }

    private func chooseCollisionFromFinder() {
        PanelPresenter.openFile(configure: {
            $0.allowedContentTypes = ["kcl", "bco"].compactMap { UTType(filenameExtension: $0) }
            $0.allowsOtherFileTypes = true
        }) { url in
            guard let url, let data = try? Data(contentsOf: url) else { return }
            loadCollision(from: data, label: url.lastPathComponent)
        }
    }

    /// Automated ground-height correction, in the spirit of the community tool MagicY (Jopojelly,
    /// MagicY): that tool raycast against an imported `.obj` while the user held
    /// Ctrl-Y in a separate KMP editor; this raycasts straight down against the course's real
    /// collision mesh (a more accurate ground source than a plain model, and no external process
    /// needed) at each point's current X/Z and sets Y to the topmost hit. Applies to the same
    /// point kinds MagicY documents support, start points, enemy/item route points, objects,
    /// respawn points, and cannons, and deliberately excludes AREA and cameras, exactly as
    /// MagicY's own docs say those don't work either (both are placed by orientation/volume, not
    /// simply "resting on the ground").
    private func supportsGroundSnap(_ selection: KMPSelection) -> Bool { KMPDocument.supportsGroundSnap(selection) }

    /// Snaps every point currently visible under the layer toggles (reusing `points()`, so it
    /// naturally respects the same filter the canvas itself shows). Pushes one history entry for
    /// the whole batch rather than one per point.
    private func snapAllToGround() {
        guard collisionMesh != nil else { return }
        for pt in points() where supportsGroundSnap(pt.id) { snapToGround(pt.id) }
        pushHistory("Snap All to Ground")
    }

    /// A tiny margin added on top of every snapped point's exact computed surface height, purely as
    /// float-quantization insurance, checked against a real retail track (`beginner_course.szs`'s
    /// own KTPT/JGPT sit within ~0.002 units of their collision mesh's surface, i.e. *zero*
    /// intentional clearance), so this is not itself what "spawns in the ground and dies" turned out
    /// to be about. The real, verified cause (see `makeTestable`'s Start Point check) is an
    /// *existing* point whose Y was simply never snapped at all, `Self.groundSnapTolerance` is the
    /// threshold that catches that.
    private static let groundClearance: Float = 10
    /// How far a point's stored Y can differ from the collision mesh's real surface at its X/Z
    /// before `makeTestable` treats it as "never snapped" and fixes it, large enough to not fire
    /// on the sub-unit noise a correctly-snapped point already has (see `groundClearance`'s doc
    /// comment), small enough to catch a point that's actually sitting off the ground.
    private static let groundSnapTolerance: Float = 20

    private func snapToGround(_ id: KMPSelection) {
        guard let mesh = collisionMesh else { return }
        switch id {
        case .ktpt(let i):
            guard box.doc.ktpt.indices.contains(i), let y = startHeight(x: box.doc.ktpt[i].position.x, z: box.doc.ktpt[i].position.z, mesh: mesh) else { return }
            box.doc.ktpt[i].position.y = y + Self.groundClearance + Float(startPointYPadding)
        case .enpt(let i):
            guard box.doc.enpt.indices.contains(i), let y = groundHeight(x: box.doc.enpt[i].position.x, z: box.doc.enpt[i].position.z, mesh: mesh) else { return }
            box.doc.enpt[i].position.y = y + Self.groundClearance
        case .itpt(let i):
            guard box.doc.itpt.indices.contains(i), let y = groundHeight(x: box.doc.itpt[i].position.x, z: box.doc.itpt[i].position.z, mesh: mesh) else { return }
            box.doc.itpt[i].position.y = y + Self.groundClearance
        case .gobj(let i):
            guard box.doc.gobj.indices.contains(i), let y = groundHeight(x: box.doc.gobj[i].position.x, z: box.doc.gobj[i].position.z, mesh: mesh) else { return }
            box.doc.gobj[i].position.y = y + Self.groundClearance
        case .jgpt(let i):
            guard box.doc.jgpt.indices.contains(i), let y = groundHeight(x: box.doc.jgpt[i].position.x, z: box.doc.jgpt[i].position.z, mesh: mesh) else { return }
            box.doc.jgpt[i].position.y = y + Self.groundClearance
        case .cnpt(let i):
            guard box.doc.cnpt.indices.contains(i), let y = groundHeight(x: box.doc.cnpt[i].position.x, z: box.doc.cnpt[i].position.z, mesh: mesh) else { return }
            box.doc.cnpt[i].position.y = y + Self.groundClearance
        case .mspt(let i):
            guard box.doc.mspt.indices.contains(i), let y = groundHeight(x: box.doc.mspt[i].position.x, z: box.doc.mspt[i].position.z, mesh: mesh) else { return }
            box.doc.mspt[i].position.y = y + Self.groundClearance
        case .poti(let r, let p?):
            guard box.doc.poti.indices.contains(r), box.doc.poti[r].points.indices.contains(p) else { return }
            let pos = box.doc.poti[r].points[p].position
            guard let y = groundHeight(x: pos.x, z: pos.z, mesh: mesh) else { return }
            box.doc.poti[r].points[p].position.y = y + Self.groundClearance
        default:
            return
        }
        box.isDirty = true
        box.objectWillChange.send()
    }

    /// Returns the Y of the topmost collision triangle directly below `(x, z)`, or nil if nothing
    /// is below. Brute-forces every triangle rather than walking the KCL's own octree, simple
    /// and correct, and fast enough for a one-off manual action even on a real track's
    /// several-thousand-triangle mesh.
    ///
    /// The height comes from intersecting the triangle's own plane, rather than from casting a ray
    /// down from far overhead and subtracting how far it travelled. That subtraction is what used
    /// to put points fractionally *under* the track: at a ray origin of 1,000,000 a 32-bit float
    /// can only resolve 1/16 of a unit, so every snapped point landed on a multiple of 0.0625
    /// instead of on the surface, ground level 0.0 became -0.0625, and a point sunk into the
    /// collision mesh is a point a kart can fall through.
    private func groundHeight(x: Float, z: Float, mesh: KCLDocument) -> Float? {
        // "Topmost" over every triangle that contains (x, z) is too naive for real course meshes:
        // a wall standing in the spawn grid, an overpass roof, or a tunnel ceiling all contain the
        // point in XZ, and several sit *above* the road the player actually stands on. Snapping a
        // start point to a ceiling/wall pick puts the kart inside the visible track, which is the
        // "players clip through the ground at the start" report. Prefer triangles whose normal
        // points up (floors and slopes the player can stand on); only fall back to a non-floor
        // triangle when the point is covered by walls/ceilings alone (so a real retail course --
        // where every pick is already an up-facing floor, is bit-identical).
        var best: Float?
        var bestFloor: Float?
        for t in mesh.triangles {
            guard let y = triangleHeight(x: x, z: z, v0: t.v0, v1: t.v1, v2: t.v2) else { continue }
            if best == nil || y > best! { best = y }
            let normalY = (t.v1.x - t.v0.x) * (t.v2.z - t.v0.z) - (t.v1.z - t.v0.z) * (t.v2.x - t.v0.x)
            if normalY > 0 {
                if bestFloor == nil || y > bestFloor! { bestFloor = y }
            }
        }
        return bestFloor ?? best
    }

    /// Height to rest a *start point* (KTPT) on: the higher of the collision mesh's floor or the
    /// visible course model's floor at `(x, z)`. A custom track's collision mesh is routinely a
    /// simplified surface sitting slightly *below* the visible road it was modeled from, and a
    /// start point snapped to the KCL alone then spawns the kart with its wheels inside the visible
    /// road, the "players clip through the ground on their start point" report. The visible model
    /// is consulted only for start points (the reported case), not for route/object/respawn
    /// points, whose heights stay physics-tied to the KCL by design.
    private func startHeight(x: Float, z: Float, mesh: KCLDocument) -> Float? {
        let kclY = groundHeight(x: x, z: z, mesh: mesh)
        let visibleY = modelGroundHeight(x: x, z: z)
        switch (kclY, visibleY) {
        case (nil, nil): return nil
        case (let a?, nil): return a
        case (nil, let b?): return b
        case (let a?, let b?): return max(a, b)
        }
    }

    /// Same topmost-floor pick as `groundHeight`, but over the visible course model's triangles
    /// (`backgroundMDL0`) instead of the KCL, see `startHeight`. The model's meshes are stored as
    /// consecutive triangles (three vertices each, no index buffer), so each vertex triple is
    /// tested directly.
    private func modelGroundHeight(x: Float, z: Float) -> Float? {
        guard let mdl = backgroundMDL0 else { return nil }
        var best: Float?
        var bestFloor: Float?
        for mesh in mdl.meshes {
            let vs = mesh.vertices
            var i = 0
            while i + 2 < vs.count {
                let v0 = vs[i].position, v1 = vs[i + 1].position, v2 = vs[i + 2].position
                if let y = triangleHeight(x: x, z: z, v0: v0, v1: v1, v2: v2) {
                    if best == nil || y > best! { best = y }
                    let normalY = (v1.x - v0.x) * (v2.z - v0.z) - (v1.z - v0.z) * (v2.x - v0.x)
                    if normalY > 0 {
                        if bestFloor == nil || y > bestFloor! { bestFloor = y }
                    }
                }
                i += 3
            }
        }
        return bestFloor ?? best
    }

    /// Y of the point on triangle `v0 v1 v2` directly above/below `(x, z)`, or nil if `(x, z)`
    /// falls outside the triangle (or it is edge-on, so there is no single height).
    private func triangleHeight(x: Float, z: Float, v0: Vec3, v1: Vec3, v2: Vec3) -> Float? {
        // Barycentric coordinates in the XZ plane, then interpolate Y with them.
        let denominator = (v1.z - v2.z) * (v0.x - v2.x) + (v2.x - v1.x) * (v0.z - v2.z)
        guard abs(denominator) > 1e-9 else { return nil }
        let a = ((v1.z - v2.z) * (x - v2.x) + (v2.x - v1.x) * (z - v2.z)) / denominator
        let b = ((v2.z - v0.z) * (x - v2.x) + (v0.x - v2.x) * (z - v2.z)) / denominator
        let c = 1 - a - b
        let tolerance: Float = -1e-5 // a hair outside still counts, so shared edges never fall through
        guard a >= tolerance, b >= tolerance, c >= tolerance else { return nil }
        return a * v0.y + b * v1.y + c * v2.y
    }

    private func loadBackgroundModel(from data: Data?, label: String) {
        // A Double Dash model goes through the same Wii conversion its own editor previews with.
        let data = data.map { d in d.count >= 4 && d.asciiString(at: 0, length: 4) == "J3D2"
            ? ((try? J3DModel.parse(d)).flatMap { try? J3DToWii.brres(from: $0, modelName: "course", scale: 1) } ?? d) : d }
        guard let data, let doc = try? BRRESDocument.parse(data) else {
            if data != nil { workbench.log("Couldn't load \(label) as a course model BRRES.") }
            return
        }
        backgroundModel = BRRESDocumentBox(doc: doc)
        backgroundModelLabel = label
        showBackgroundModel = true
        // Merge every MDL0 resource's meshes into one silhouette, real course BRRES files
        // often split the track into several MDL0s (e.g. a separate "vrcorn" skybox model), and
        // showing all of them is more useful than guessing which one is "the" course model.
        let parsed = doc.resources.filter { $0.magic == "MDL0" }.compactMap { MDL0Parser.parse($0, rawFile: doc.rawData) }
        backgroundMDL0 = parsed.isEmpty ? nil : MDL0Model(name: label, meshes: parsed.flatMap(\.meshes))
        if backgroundMDL0 == nil {
            workbench.log("\(label): couldn't extract real mesh geometry, falling back to a texture reference instead.")
        }
    }

    /// A standalone reference mesh (e.g. exported from Blender for track planning) doesn't have a
    /// BRRES wrapper or textures, this goes straight to `backgroundMDL0` (real-geometry render
    /// path) with `backgroundModel` left nil, since there's nothing to fall back to a texture-card
    /// collage for and no BRRES to hold one anyway.
    private func loadBackgroundModel(fromOBJ text: String, label: String, objURL: URL? = nil) {
        let triangles = OBJImporter.parse(text)
        guard !triangles.isEmpty else {
            workbench.log("\(label): no triangles found in that .obj file.")
            return
        }
        backgroundModel = nil
        backgroundModelLabel = label
        showBackgroundModel = true
        backgroundMDL0 = MDL0Model(name: label, meshes: Self.meshes(groupedByMaterial: triangles))
        materialMTLColors = [:]
        if let objURL {
            for (name, mtl) in OBJImporter.loadMTLMaterials(objText: text, objURL: objURL) {
                guard let c = mtl.diffuseColor else { continue }
                materialMTLColors[name] = Color(red: Double(c.r), green: Double(c.g), blue: Double(c.b))
            }
        }
    }

    /// One `MDL0Mesh` per distinct `usemtl` material in `triangles` (plus one more for any triangle
    /// with no material), in first-seen order. A single mesh for the whole file (the previous
    /// behavior) meant every triangle shared one name, the file's own label, so
    /// `materialList`/the "Material Colors" popover only ever showed one entry for an entire OBJ
    /// background model, silently hiding every real material in it from per-material coloring.
    private static func meshes(groupedByMaterial triangles: [OBJImporter.Triangle]) -> [MDL0Mesh] {
        var order: [String] = []
        var byMaterial: [String: [OBJImporter.Triangle]] = [:]
        for t in triangles {
            let key = t.materialName ?? "(no material)"
            if byMaterial[key] == nil { order.append(key) }
            byMaterial[key, default: []].append(t)
        }
        return order.map { key in
            let group = byMaterial[key] ?? []
            let vertices = group.flatMap { [MDL0Vertex(position: $0.v0), MDL0Vertex(position: $0.v1), MDL0Vertex(position: $0.v2)] }
            return MDL0Mesh(name: key, vertices: vertices)
        }
    }

    /// Every `.brres` reachable from the current project folder, plus every `.brres` inside the
    /// SZS archive this KMP was opened from (if any), for the manual "From Project" picker.
    private var projectModelCandidates: [ModelCandidate] {
        var out: [ModelCandidate] = []
        if let root = workbench.projectRoot {
            collectModels(in: root, into: &out)
        }
        if case .szsEntry(let archive, _) = source {
            collectModels(in: archive.root, into: &out)
        }
        return out
    }

    private func collectModels(in node: ProjectNode, into out: inout [ModelCandidate]) {
        guard out.count < 40 else { return }
        if !node.isDirectory {
            let ext = node.url.pathExtension.lowercased()
            if ext == "brres" {
                out.append(ModelCandidate(label: node.name) { loadBackgroundModel(from: try? Data(contentsOf: node.url), label: node.name) })
            } else if ModelFile.isModel(node.url) {
                out.append(ModelCandidate(label: node.name) {
                    guard let (text, url) = try? ModelFile.objSource(node.url) else { return }
                    loadBackgroundModel(fromOBJ: text, label: node.name, objURL: url)
                })
            }
        }
        for c in node.children { collectModels(in: c, into: &out) }
    }

    private func collectModels(in node: U8Node, into out: inout [ModelCandidate]) {
        guard out.count < 40 else { return }
        if !node.isDirectory {
            let ext = (node.name as NSString).pathExtension.lowercased()
            if ext == "brres" {
                out.append(ModelCandidate(label: node.name) { loadBackgroundModel(from: node.data, label: node.name) })
            } else if ext == "obj" {
                out.append(ModelCandidate(label: node.name) {
                    guard let data = node.data, let text = String(data: data, encoding: .utf8) else { return }
                    loadBackgroundModel(fromOBJ: text, label: node.name, objURL: nil)
                })
            }
        }
        for c in node.children { collectModels(in: c, into: &out) }
    }

    private func chooseFromFinder() {
        PanelPresenter.openFile(configure: {
            $0.allowedContentTypes = ["brres", "bmd", "szs", "arc"].compactMap { UTType(filenameExtension: $0) } + ModelFile.contentTypes
            $0.allowsOtherFileTypes = true
        }) { url in
            guard let url, let data = try? Data(contentsOf: url) else { return }
            let ext = url.pathExtension.lowercased()
            if ModelFile.isModel(url) {
                guard let (text, objURL) = try? ModelFile.objSource(url) else { return }
                loadBackgroundModel(fromOBJ: text, label: url.lastPathComponent, objURL: objURL)
            } else if ext == "szs" || ext == "arc" || Yaz0.isYaz0(data) {
                guard let (root, _) = try? SZS.open(data) else { return }
                func firstBRRES(_ node: U8Node) -> U8Node? {
                    if !node.isDirectory, Self.isCourseModelFile(node.name) { return node }
                    for c in node.children { if let f = firstBRRES(c) { return f } }
                    return nil
                }
                guard let match = firstBRRES(root) else {
                    workbench.log("No course model (.brres or _course.bmd) found inside \(url.lastPathComponent).")
                    return
                }
                loadBackgroundModel(from: match.data, label: "\(url.lastPathComponent) -> \(match.name)")
            } else {
                loadBackgroundModel(from: data, label: url.lastPathComponent)
            }
        }
    }

    // MARK: Zoom

    private func clampedScale(_ s: CGFloat) -> CGFloat { max(minScale, min(maxScale, s)) }

    /// Changes `scale` by `factor` while keeping the world point currently under `location`
    /// (canvas-local coordinates) visually fixed, if `location` is nil (e.g. a toolbar button,
    /// not a pointer position), zooms around the canvas center instead.
    private func zoom(by factor: CGFloat, around location: CGPoint?, size: CGSize) {
        let anchor = location ?? CGPoint(x: size.width / 2, y: size.height / 2)
        let newScale = clampedScale(scale * factor)
        guard newScale != scale else { return }
        let worldX = (anchor.x - size.width / 2 - panOffset.width) / (scale * 0.05)
        let worldZ = (anchor.y - size.height / 2 - panOffset.height) / (scale * 0.05)
        panOffset = CGSize(width: anchor.x - size.width / 2 - worldX * newScale * 0.05,
                            height: anchor.y - size.height / 2 - worldZ * newScale * 0.05)
        dragStartOffset = panOffset
        scale = newScale
        gestureStartScale = newScale
    }

    private func resetZoom(size: CGSize) {
        scale = 1.5
        gestureStartScale = 1.5
        panOffset = .zero
        dragStartOffset = .zero
    }

    /// Fits every currently-visible point on screen with a little breathing room.
    private func zoomToFit(size: CGSize) {
        let pts = points()
        guard !pts.isEmpty else { resetZoom(size: size); return }
        let xs = pts.map(\.x), zs = pts.map(\.z)
        let minX = xs.min()!, maxX = xs.max()!, minZ = zs.min()!, maxZ = zs.max()!
        let spanX = max(CGFloat(maxX - minX), 200), spanZ = max(CGFloat(maxZ - minZ), 200)
        let fitScaleX = size.width / (spanX * 0.05 * 1.2)
        let fitScaleZ = size.height / (spanZ * 0.05 * 1.2)
        let newScale = clampedScale(min(fitScaleX, fitScaleZ))
        let centerX = CGFloat((minX + maxX) / 2), centerZ = CGFloat((minZ + maxZ) / 2)
        scale = newScale
        gestureStartScale = newScale
        panOffset = CGSize(width: -centerX * newScale * 0.05, height: -centerZ * newScale * 0.05)
        dragStartOffset = panOffset
    }

    private func zoomControls(size: CGSize) -> some View {
        HStack(spacing: 4) {
            addPointMenu(size: size)
            Toggle(isOn: $penToolActive) { Image(systemName: "pencil.tip") }
                .toggleStyle(.button)
                .help("Pen tool: click to place points along a straight line, or click-and-drag to pull out a curve handle, just like Photoshop's pen tool. Draw a path, then Finish to fill it with evenly-spaced points.")
                .onChange(of: penToolActive) { _, active in if !active { cancelPen() } }
            Divider().frame(height: 14)
            Button { zoom(by: 0.8, around: nil, size: size) } label: { Image(systemName: "minus.magnifyingglass") }
                .shortcut(.zoomOut)
            Text("\(Int(scale / 1.5 * 100))%")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 46)
            Button { zoom(by: 1.25, around: nil, size: size) } label: { Image(systemName: "plus.magnifyingglass") }
                .shortcut(.zoomIn)
            Divider().frame(height: 14)
            Button { resetZoom(size: size) } label: { Text("1:1") }
                .shortcut(.zoomReset)
            Button { zoomToFit(size: size) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("Zoom to Fit")
                .shortcut(.zoomFit)
        }
        .buttonStyle(.borderless)
        .padding(6)
        .background(.bar, in: RoundedRectangle(cornerRadius: 8))
        .padding(10)
    }

    // MARK: Pen tool

    /// Floating control strip shown while the pen tool (toggled from `zoomControls`) is active:
    /// picks which point type the drawn path becomes, the spacing between the points it'll place,
    /// and Finish/Cancel. Kept separate from `zoomControls` since it only makes sense while drawing.
    @ViewBuilder
    private func penToolBar(size: CGSize) -> some View {
        if penToolActive {
            HStack(spacing: 10) {
                Image(systemName: "pencil.tip")
                Menu {
                    ForEach(Self.penEligibleSections, id: \.self) { section in
                        Button("\(section.displayName) (\(section.magic))") { penToolSection = section }
                    }
                } label: {
                    Text("\(penToolSection.displayName) (\(penToolSection.magic))")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("What kind of point the path becomes when you Finish.")

                HStack(spacing: 4) {
                    Text("Spacing").font(.caption)
                    TextField("", value: $penToolSpacing, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 50)
                }
                .help("Distance (in-game units) between the points placed along the finished path.")

                Divider().frame(height: 16)

                Text(penAnchors.isEmpty ? "Click to start a path" : "\(penAnchors.count) anchor\(penAnchors.count == 1 ? "" : "s"), drag while clicking for a curve")
                    .font(.caption2).foregroundStyle(.secondary)

                Divider().frame(height: 16)

                Button("Finish") { finishPenPath() }
                    .disabled(penAnchors.count < 2)
                    .shortcut(.penFinish)
                Button("Cancel") { cancelPen() }
                    .shortcut(.penCancel)
                
                // Intercept Cmd+Z to pop the last anchor instead of firing document undo
                Button("Undo Anchor") { if !penAnchors.isEmpty { penAnchors.removeLast() } }
                    .shortcut(.penUndoAnchor)
                    .disabled(penAnchors.isEmpty)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
            }
            .font(.caption)
            .padding(8)
            .background(.bar, in: RoundedRectangle(cornerRadius: 8))
            .padding(10)
        }
    }

    // MARK: Marquee multi-select

    /// Persistent (not just-while-dragging) strip picking which point type Shift-drag marquees
    /// pick up, plus bulk actions once a marquee has actually selected something, shown whenever
    /// the pen tool isn't active, since Shift-drag works all the time rather than needing its own
    /// toggle first.
    private var multiSelectBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "lasso")
            Menu {
                Button("Auto") { selectionScope = .auto }
                Button("All Visible") { selectionScope = .allVisible }
                Divider()
                ForEach(Self.marqueeSections, id: \.self) { section in
                    Button(section == .poti ? "Route Points (POTI)" : "\(section.displayName) (\(section.magic))") { selectionScope = .type(section) }
                }
            } label: {
                switch selectionScope {
                case .auto: Text("Auto")
                case .allVisible: Text("All Visible")
                case .type(let t): Text(t == .poti ? "Route Points (POTI)" : "\(t.displayName) (\(t.magic))")
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Drag a box on the canvas (\(controls.phrase(.kmpBoxSelect, "drag"))) to select points inside it. Auto picks the first type it finds and sticks to it; All Visible picks every type.")

            // Cmd+A: select every currently-visible point of the type picked above. Kept as a
            // hidden button (same trick as penToolBar's "Undo Anchor") rather than a raw key
            // handler, so a focused text field's own Cmd+A (select-all-text) still wins there.
            Button("Select All") { selectAllOfCurrentType() }
                .shortcut(.selectAll)
                .frame(width: 1, height: 1)
                .opacity(0.01)

            Button("Copy") { copySelection() }
                .disabled(multiSelection.isEmpty && box.selection == nil)
                .help("Copy the selection (\(Controls.shared.binding(.copy).display)) to paste into this or another KMP/BOL.")
            Button("Paste") { pasteClipboard() }
                .disabled(KMPClipboard.current == nil)
                .help("Paste copied course data (\(Controls.shared.binding(.paste).display)). Pasting between KMP and BOL scales positions to the other game.")
            if let clipboardNote { Text(clipboardNote).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
            if multiSelection.isEmpty {
                Text("\(controls.phrase(.kmpBoxSelect, "drag")) to box-select. Drag a selected point to move the whole selection. \(controls.phrase(.kmpRotate, "drag")) a point to rotate.").font(.caption2).foregroundStyle(.secondary)
            } else {
                Divider().frame(height: 16)
                Text("\(multiSelection.count) selected").font(.caption2).foregroundStyle(.secondary)
                Button("Snap to Ground") { snapSelectedToGround() }
                    .disabled(collisionMesh == nil)
                    .help(collisionMesh == nil ? "Load a collision (.kcl) file in the toolbar to enable Snap to Ground" : "Snap Y to the collision mesh below these points")
                Button("Separate to New Group") { separateMultiSelection() }
                    .disabled(!canSeparate)
                    .help("Moves the selected enemy points, item points or checkpoints (all one kind) into a new path group. A run cut off the end or start of a path stays linked to the rest of it.")
                Button("Delete") { deleteMultiSelection() }
                Button("Clear") { multiSelection = [] }
            }
        }
        .font(.caption)
        .padding(8)
        .background(.bar, in: RoundedRectangle(cornerRadius: 8))
        .padding(10)
    }

    /// Maps a plotted point's selection id to the section it belongs to, so a marquee can filter to
    /// just `selectionTypeFilter`'s points among everything currently visible.
    private func section(of id: KMPSelection) -> KMPSection? {
        switch id {
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
        case .enph: return .enph
        case .itph: return .itph
        case .ckph: return .ckph
        default: return nil
        }
    }

    /// Maps a `pathsList` row's section/index to the `KMPSelection` case that shows *that path
    /// group's own* settings (links, not points) in the inspector, as opposed to `.enpt`/etc.,
    /// which selects one point inside a group.
    private func pathGroupSelection(_ section: KMPSection, _ index: Int) -> KMPSelection? {
        switch section {
        case .enph: return .enph(index)
        case .itph: return .itph(index)
        case .ckph: return .ckph(index)
        default: return nil
        }
    }

    private var canSeparate: Bool {
        let kinds = Set(multiSelection.compactMap { sel -> KMPSection? in
            switch sel.asPoint { case .enpt: return .enpt; case .itpt: return .itpt; case .ckpt: return .ckpt; default: return nil }
        })
        return kinds.count == 1 && multiSelection.allSatisfy { kinds.contains(section(of: $0.asPoint) ?? .ktpt) }
    }

    private func separateMultiSelection() {
        guard box.separateToNewGroup(multiSelection) else { return }
        multiSelection = []
        pushHistory("Separate to New Group")
    }

    private func handleCanvasKey(_ action: ControlAction) -> Bool {
        switch action {
        case .deleteSelection: return deleteSelected()
        case .copy: return copySelection()
        case .paste: return pasteClipboard()
        default: return false
        }
    }

    /// Copies the multi-selection, else the selected item, for pasting into this or another file.
    @discardableResult
    private func copySelection() -> Bool {
        let chosen: Set<KMPSelection> = multiSelection.isEmpty ? Set(box.selection.map { [$0] } ?? []) : multiSelection
        guard let clip = KMPClipboard.copy(from: box.doc, selection: chosen) else { return false }
        KMPClipboard.current = clip
        clipboardNote = "Copied \(clip.count) item\(clip.count == 1 ? "" : "s")."
        return true
    }

    @discardableResult
    private func pasteClipboard() -> Bool {
        guard let clip = KMPClipboard.current else { return false }
        let result = clip.paste(into: box.doc)
        guard !result.added.isEmpty else { clipboardNote = result.note ?? "Nothing to paste."; return true }
        box.isDirty = true
        box.objectWillChange.send()
        let points = result.added.filter { section(of: $0) != nil }
        if points.count > 1 { multiSelection = Set(points); box.selection = nil } else { multiSelection = []; box.selection = points.first }
        clipboardNote = "Pasted \(result.added.count) item\(result.added.count == 1 ? "" : "s")." + (result.note.map { " " + $0 } ?? "")
        pushHistory("Paste")
        return true
    }

    /// Delete/Backspace on the canvas: the multi-selection, else the selected point.
    private func deleteSelected() -> Bool {
        if !multiSelection.isEmpty { deleteMultiSelection(); return true }
        guard let sel = box.selection, canRemove(sel) else { return false }
        removeSelectedPoint()
        return true
    }

    private func snapSelectedToGround() {
        guard !multiSelection.isEmpty else { return }
        var snappedCount = 0
        for sel in multiSelection where supportsGroundSnap(sel) {
            snapToGround(sel)
            snappedCount += 1
        }
        if snappedCount > 0 {
            pushHistory("Snap Selected to Ground")
        }
    }

    /// Whether `id` is picked up under the current scope. Auto locks to the type already in the
    /// multi-selection, else to `first`'s.
    private func scopeAccepts(_ id: KMPSelection, first: KMPSelection?) -> Bool {
        switch selectionScope {
        case .allVisible: return true
        case .type(let t): return section(of: id) == t
        case .auto:
            let locked = multiSelection.first.flatMap { section(of: $0.asPoint) } ?? first.flatMap { section(of: $0.asPoint) }
            return locked != nil && section(of: id) == locked
        }
    }

    /// Adds every currently-visible point of the scope's type whose screen position
    /// falls inside the just-finished marquee to `multiSelection`, additive (never clears an
    /// existing multi-selection) so several marquees in a row can build up one larger selection.
    private func commitMarqueeSelection(rect: CGRect?, size: CGSize, from start: CGPoint? = nil) {
        guard let rect else { return }
        let inside = points().filter { rect.contains(worldToScreen($0.x, $0.z, size: size)) }
        let anchor = start ?? CGPoint(x: rect.midX, y: rect.midY)
        // Auto: the type already selected, else the type of the point nearest where the drag began.
        let nearest = inside.min { a, b in
            let pa = worldToScreen(a.x, a.z, size: size), pb = worldToScreen(b.x, b.z, size: size)
            return hypot(pa.x - anchor.x, pa.y - anchor.y) < hypot(pb.x - anchor.x, pb.y - anchor.y)
        }
        let matches = inside.filter { scopeAccepts($0.id, first: nearest?.id) }
        guard !matches.isEmpty else { return }
        multiSelection.formUnion(matches.map(\.id))
        box.selection = nil
    }

    /// Cmd+A: every currently-visible point of `selectionTypeFilter`'s type, full stop, the same
    /// filter `commitMarqueeSelection` uses, just without a marquee rect to test against.
    private func selectAllOfCurrentType() {
        let all = points()
        let matches = all.filter { scopeAccepts($0.id, first: box.selection.map(\.asPoint)) }
        guard !matches.isEmpty else { return }
        multiSelection = Set(matches.map(\.id))
        box.selection = nil
    }

    /// Removes every point in `multiSelection`. Section types with no other section indexing into
    /// them (everything but ENPT/ITPT/CKPT) can just be removed by index, highest-first per array so
    /// an earlier removal never shifts an index still queued for removal. ENPT/ITPT/CKPT go through
    /// `box.remove`, which keeps their path groups (and areas' enemy points) consistent.
    private func deleteMultiSelection() {
        guard !multiSelection.isEmpty else { return }
        func removeIndices<T>(from array: inout [T], match: (KMPSelection) -> Int?) {
            for i in multiSelection.compactMap(match).sorted(by: >) where array.indices.contains(i) {
                array.remove(at: i)
            }
        }
        removeIndices(from: &box.doc.ktpt) { if case .ktpt(let i) = $0 { return i }; return nil }
        removeIndices(from: &box.doc.gobj) { if case .gobj(let i) = $0 { return i }; return nil }
        // Respawn points go through `box.remove` so checkpoints pointing at later ones are renumbered.
        for i in multiSelection.compactMap({ sel -> Int? in if case .jgpt(let i) = sel { return i }; return nil }).sorted(by: >) {
            box.remove(.jgpt(i))
        }
        removeIndices(from: &box.doc.cnpt) { if case .cnpt(let i) = $0 { return i }; return nil }
        removeIndices(from: &box.doc.mspt) { if case .mspt(let i) = $0 { return i }; return nil }
        removeIndices(from: &box.doc.area) { if case .area(let i) = $0 { return i }; return nil }
        // Route points: highest index first within each route, so earlier removals don't shift later ones.
        let routePoints = multiSelection.compactMap { sel -> (Int, Int)? in if case .poti(let r, let p?) = sel { return (r, p) }; return nil }
        for (r, p) in routePoints.sorted(by: { $0.0 == $1.0 ? $0.1 > $1.1 : $0.0 > $1.0 })
            where box.doc.poti.indices.contains(r) && box.doc.poti[r].points.indices.contains(p) {
            box.doc.poti[r].points.remove(at: p)
        }
        for i in multiSelection.compactMap({ sel -> Int? in if case .came(let i) = sel { return i }; return nil }).sorted(by: >) {
            removeCame(at: i)
        }
        // Path points highest-first, so each removal leaves the rest's indices intact.
        let pathPoints = multiSelection.map(\.asPoint).filter {
            switch $0 { case .enpt, .itpt, .ckpt: return true; default: return false }
        }
        func index(_ sel: KMPSelection) -> Int {
            switch sel { case .enpt(let i), .itpt(let i), .ckpt(let i): return i; default: return 0 }
        }
        for sel in Set(pathPoints).sorted(by: { index($0) > index($1) }) { box.remove(sel) }
        multiSelection = []
        box.selection = nil
        box.isDirty = true
        box.objectWillChange.send()
        pushHistory("Delete Selected Points")
    }

    /// Commits the anchor a pen-tool click (or click-drag) just placed. `value.translation` past a
    /// few points of screen movement means the user dragged out a curve handle rather than just
    /// clicking, see `PenAnchor`'s doc comment for how that handle is used.
    private func commitPenAnchor(_ value: DragGesture.Value, size: CGSize) {
        let anchorWorld = screenToWorld(value.startLocation, size: size)
        let endWorld = screenToWorld(value.location, size: size)
        let dragScreenDistance = hypot(value.translation.width, value.translation.height)
        let handle: SIMD2<Float> = dragScreenDistance > 4
            ? SIMD2<Float>(endWorld.x - anchorWorld.x, endWorld.y - anchorWorld.y)
            : SIMD2<Float>(0, 0)
        penAnchors.append(PenAnchor(position: anchorWorld, handle: handle))
    }

    private func cancelPen() {
        penAnchors = []
        pendingPenDrag = nil
    }

    /// Samples the drawn path at even `penToolSpacing` intervals and appends one real KMP point per
    /// sample (via the same `addPoint` a single "+" menu click uses), then records one history step
    /// for the whole path rather than one per point.
    private func finishPenPath() {
        guard penAnchors.count >= 2 else { return }
        let samples = sampleAlongPenPath(spacing: Float(max(penToolSpacing, 10)))
        guard !samples.isEmpty else { cancelPen(); return }
        for sample in samples {
            addPoint(penToolSection, at: sample.position, tangent: sample.tangent)
        }
        pushHistory("Pen Tool: \(samples.count) \(penToolSection.magic) Point\(samples.count == 1 ? "" : "s")")
        penAnchors = []
        pendingPenDrag = nil
        penToolActive = false
    }

    /// Flattens the anchors' piecewise-cubic path (see `PenAnchor`) into small segments, then walks
    /// its cumulative arc length placing one sample every `spacing` world units, starting at the
    /// first anchor. `subdivisions` per segment is fixed rather than adaptive, plenty smooth for
    /// the gentle curves a hand-drawn track path needs, and simple.
    private func sampleAlongPenPath(spacing: Float) -> [(position: SIMD2<Float>, tangent: SIMD2<Float>)] {
        guard penAnchors.count >= 2 else { return [] }
        let subdivisions = 24
        var flat: [(pos: SIMD2<Float>, tangent: SIMD2<Float>)] = []
        for i in 0..<(penAnchors.count - 1) {
            let a = penAnchors[i], b = penAnchors[i + 1]
            let p0 = a.position
            let p1 = SIMD2<Float>(a.position.x + a.handle.x, a.position.y + a.handle.y)
            let p2 = SIMD2<Float>(b.position.x - b.handle.x, b.position.y - b.handle.y)
            let p3 = b.position
            let startStep = (i == 0) ? 0 : 1 // skip the duplicate point shared with the previous segment's end
            for s in startStep...subdivisions {
                let t = Float(s) / Float(subdivisions)
                flat.append((cubicBezierPoint(p0, p1, p2, p3, t), cubicBezierTangent(p0, p1, p2, p3, t)))
            }
        }
        guard flat.count >= 2 else { return [] }

        var samples: [(position: SIMD2<Float>, tangent: SIMD2<Float>)] = [(flat[0].pos, flat[0].tangent)]
        var accumulated: Float = 0
        var nextTarget: Float = spacing
        for i in 1..<flat.count {
            let segStart = accumulated
            let segLen = vecDistance(flat[i - 1].pos, flat[i].pos)
            accumulated += segLen
            while nextTarget <= accumulated, segLen > 0.0001 {
                let t = (nextTarget - segStart) / segLen
                samples.append((vecMix(flat[i - 1].pos, flat[i].pos, t), vecMix(flat[i - 1].tangent, flat[i].tangent, t)))
                nextTarget += spacing
            }
        }
        return samples
    }

    /// Draws the in-progress pen path: the curve itself, each anchor as a small square, and (for a
    /// dragged/"smooth" anchor) its two mirrored bezier handles as thin lines, the same visual
    /// language Photoshop's pen tool uses, so it reads as "still being drawn" rather than finished data.
    private func drawPenPath(in context: inout GraphicsContext, size: CGSize) {
        guard !penAnchors.isEmpty else { return }

        if penAnchors.count > 1 {
            var path = Path()
            path.move(to: worldToScreen(penAnchors[0].position.x, penAnchors[0].position.y, size: size))
            for i in 0..<(penAnchors.count - 1) {
                let a = penAnchors[i], b = penAnchors[i + 1]
                let p1 = worldToScreen(a.position.x + a.handle.x, a.position.y + a.handle.y, size: size)
                let p2 = worldToScreen(b.position.x - b.handle.x, b.position.y - b.handle.y, size: size)
                let p3 = worldToScreen(b.position.x, b.position.y, size: size)
                path.addCurve(to: p3, control1: p1, control2: p2)
            }
            context.stroke(path, with: .color(.yellow), lineWidth: 2)
        }

        for anchor in penAnchors {
            let p = worldToScreen(anchor.position.x, anchor.position.y, size: size)
            if anchor.handle != SIMD2<Float>(0, 0) {
                let h1 = worldToScreen(anchor.position.x + anchor.handle.x, anchor.position.y + anchor.handle.y, size: size)
                let h2 = worldToScreen(anchor.position.x - anchor.handle.x, anchor.position.y - anchor.handle.y, size: size)
                var handleLine = Path()
                handleLine.move(to: h1); handleLine.addLine(to: p); handleLine.addLine(to: h2)
                context.stroke(handleLine, with: .color(.yellow.opacity(0.6)), lineWidth: 1)
                for h in [h1, h2] {
                    context.fill(Path(ellipseIn: CGRect(x: h.x - 3, y: h.y - 3, width: 6, height: 6)), with: .color(.yellow))
                }
            }
            let r: CGFloat = 5
            context.stroke(Path(CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(.yellow), lineWidth: 2)
        }

        if let pendingPenDrag {
            let anchorWorld = screenToWorld(pendingPenDrag.startScreen, size: size)
            let currentWorld = screenToWorld(pendingPenDrag.currentScreen, size: size)
            let dragScreenDistance = hypot(pendingPenDrag.currentScreen.x - pendingPenDrag.startScreen.x,
                                            pendingPenDrag.currentScreen.y - pendingPenDrag.startScreen.y)
            let handle: SIMD2<Float> = dragScreenDistance > 4
                ? SIMD2<Float>(currentWorld.x - anchorWorld.x, currentWorld.y - anchorWorld.y)
                : SIMD2<Float>(0, 0)

            // Live preview of the curve segment this drag would commit, from the last already-
            // placed anchor (using its already-fixed out-handle) to this in-progress one (mirroring
            // the handle currently being dragged), exactly the math `commitPenAnchor` + the
            // finished-path renderer above use, so the preview never lies about the real result.
            if let last = penAnchors.last {
                let p0 = last.position
                let p1 = SIMD2<Float>(p0.x + last.handle.x, p0.y + last.handle.y)
                let p2 = SIMD2<Float>(anchorWorld.x - handle.x, anchorWorld.y - handle.y)
                var live = Path()
                live.move(to: worldToScreen(p0.x, p0.y, size: size))
                live.addCurve(to: worldToScreen(anchorWorld.x, anchorWorld.y, size: size),
                              control1: worldToScreen(p1.x, p1.y, size: size),
                              control2: worldToScreen(p2.x, p2.y, size: size))
                context.stroke(live, with: .color(.yellow.opacity(0.9)), lineWidth: 2)
            }

            if dragScreenDistance > 4 {
                let anchorScreen = worldToScreen(anchorWorld.x, anchorWorld.y, size: size)
                let h1 = worldToScreen(anchorWorld.x + handle.x, anchorWorld.y + handle.y, size: size)
                let h2 = worldToScreen(anchorWorld.x - handle.x, anchorWorld.y - handle.y, size: size)
                var handleLine = Path()
                handleLine.move(to: h1); handleLine.addLine(to: anchorScreen); handleLine.addLine(to: h2)
                context.stroke(handleLine, with: .color(.yellow.opacity(0.6)), lineWidth: 1)
                for h in [h1, h2] {
                    context.fill(Path(ellipseIn: CGRect(x: h.x - 3, y: h.y - 3, width: 6, height: 6)), with: .color(.yellow))
                }
            }
        }
    }

    // MARK: Add / remove points

    /// Adds a point and records one history step for it, so a point placed from the "+" menu is
    /// just as undoable (Cmd-Z) as a drag-move or a pen-tool path, which weren't the only kind of
    /// edit that used to skip `pushHistory` here.
    private func addPointWithHistory(_ section: KMPSection, at world: SIMD2<Float>) {
        addPoint(section, at: world)
        pushHistory("Add \(section.displayName)")
    }

    private func addPointMenu(size: CGSize) -> some View {
        Menu {
            Button("Start Point (KTPT)") { addPointWithHistory(.ktpt, at: viewCenterWorld(size: size)) }
            Button("Enemy Point (ENPT)") { addPointWithHistory(.enpt, at: viewCenterWorld(size: size)) }
            Button("Item Point (ITPT)") { addPointWithHistory(.itpt, at: viewCenterWorld(size: size)) }
            Button("Checkpoint (CKPT)") { addPointWithHistory(.ckpt, at: viewCenterWorld(size: size)) }
            Button("Object (GOBJ)") { addPointWithHistory(.gobj, at: viewCenterWorld(size: size)) }
            Button("Respawn Point (JGPT)") { addPointWithHistory(.jgpt, at: viewCenterWorld(size: size)) }
            Button("Cannon Point (CNPT)") { addPointWithHistory(.cnpt, at: viewCenterWorld(size: size)) }
            Button("Battle Respawn Point (MSPT)") { addPointWithHistory(.mspt, at: viewCenterWorld(size: size)) }
            Button("Area (AREA)") { addPointWithHistory(.area, at: viewCenterWorld(size: size)) }
            Button("Camera (CAME)") { addPointWithHistory(.came, at: viewCenterWorld(size: size)) }
            Divider()
            Button("New Enemy Path") { newPath(&box.doc.enph, arrayCount: box.doc.enpt.count); pushHistory("New Enemy Path") }
            Button("New Item Path") { newPath(&box.doc.itph, arrayCount: box.doc.itpt.count); pushHistory("New Item Path") }
            Button("New Checkpoint Path") { newPath(&box.doc.ckph, arrayCount: box.doc.ckpt.count); pushHistory("New Checkpoint Path") }
            Button("New Route") { newRoute(at: viewCenterWorld(size: size)) }
        } label: {
            Image(systemName: "plus.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Add a new point at the centre of the view, or start a fresh Enemy/Item/Checkpoint path, new points of that kind always extend whichever path was created most recently.")
    }

    /// Starts a new, empty path group, since points are only ever appended to the *last* group
    /// (see `appendToLastGroup`), this is all it takes to redirect subsequent Enemy/Item/Checkpoint
    /// point adds onto a fresh path (e.g. for a fork or shortcut) instead of extending whichever
    /// path already existed. Real tracks routinely have several of these; the editor previously had
    /// no way to start a second one at all.
    private func newPath(_ groups: inout [PathLinkEntry], arrayCount: Int) {
        guard arrayCount <= 255 else { return } // startIndex is a UInt8
        groups.append(PathLinkEntry(startIndex: UInt8(arrayCount), pointCount: 0))
        box.isDirty = true
        box.objectWillChange.send()
    }

    private func viewCenterWorld(size: CGSize) -> SIMD2<Float> {
        screenToWorld(CGPoint(x: size.width / 2, y: size.height / 2), size: size)
    }

    /// Starts a new Route (POTI) with two points, routes aren't path-grouped like ENPT/ITPT/CKPT
    /// (each one owns its points directly), so unlike `newPath` there's no separate "start an empty
    /// group" step. Two points, not one: a route is something to move *along*, and a single-point
    /// route has nowhere to go, it would just sit there looking created but not actually usable
    /// until a second point is added anyway, so start with one already in place.
    private func newRoute(at world: SIMD2<Float>) {
        let a = RoutePoint(position: Vec3(x: world.x, y: 0, z: world.y))
        let b = RoutePoint(position: Vec3(x: world.x + 1000, y: 0, z: world.y))
        box.doc.poti.append(POTIRoute(points: [a, b]))
        box.selection = .poti(route: box.doc.poti.count - 1, point: 0)
        box.isDirty = true
        box.objectWillChange.send()
        pushHistory("New Route")
    }

    /// Appends a new entry (at world position `at`) to whichever section is selected, and selects
    /// it. ENPT/ITPT/CKPT additionally extend the *last* path group's range so the new point is
    /// immediately part of a path, always safe since appending never touches another group's
    /// `startIndex`/`pointCount`. `tangent` is the direction of travel at this point, used only by
    /// CKPT to orient its left/right gate perpendicular to the path instead of always along X --
    /// the pen tool (see `finishPenPath`) supplies the curve's real tangent there; the "+" menu
    /// (which has no path to derive a direction from) leaves it nil and gets the old fixed-X gate.
    private func addPoint(_ section: KMPSection, at world: SIMD2<Float>, tangent: SIMD2<Float>? = nil) {
        box.addPoint(section, at: Vec3(x: world.x, y: 0, z: world.y), tangent: tangent)
    }

    private func insertIndexForLastGroup(_ groups: [PathLinkEntry], arrayCount: Int) -> Int {
        KMPDocument.insertIndexForLastGroup(groups, arrayCount: arrayCount)
    }

    private func appendToLastGroup(_ groups: inout [PathLinkEntry], insertedAt: Int) {
        KMPDocument.appendToLastGroup(&groups, insertedAt: insertedAt)
    }

    /// Reorders `groups` per a `List`'s `.onMove(perform:)` semantics (or a single-step up/down
    /// button, via a one-element `source`, see `moveGroup`), then remaps every group's
    /// `previousGroups`/`nextGroups` (which store *other groups' indices in this same array*, for
    /// fork/merge links) so they still point at the right group afterward. Doesn't touch
    /// `startIndex`/`pointCount` or the underlying point array at all, reordering which group is
    /// "first" doesn't require moving any actual points, since each group already carries its own
    /// absolute range into that array.
    private func reorderGroups(_ groups: inout [PathLinkEntry], from source: IndexSet, to destination: Int) {
        var indexed = Array(groups.enumerated())
        indexed.move(fromOffsets: source, toOffset: destination)
        var oldToNew: [UInt8: UInt8] = [:]
        for (newPosition, pair) in indexed.enumerated() { oldToNew[UInt8(pair.offset)] = UInt8(newPosition) }
        groups = indexed.map { $0.element }
        for i in groups.indices {
            groups[i].previousGroups = groups[i].previousGroups.map { $0 == 0xFF ? 0xFF : (oldToNew[$0] ?? $0) }
            groups[i].nextGroups = groups[i].nextGroups.map { $0 == 0xFF ? 0xFF : (oldToNew[$0] ?? $0) }
        }
        box.isDirty = true
        box.objectWillChange.send()
    }

    /// Moves the group at `index` one step up (`direction: -1`) or down (`direction: 1`), using the
    /// same `toOffset` convention `List.onMove` itself uses (an adjacent downward move's destination
    /// is `index + 2`, not `index + 1`, the destination is where the element lands *after* it's
    /// removed from its old position).
    private func moveGroup(_ groups: inout [PathLinkEntry], from index: Int, direction: Int) {
        let destination = direction < 0 ? index - 1 : index + 2
        guard groups.indices.contains(index), (0...groups.count).contains(destination) else { return }
        reorderGroups(&groups, from: IndexSet(integer: index), to: destination)
    }

    private func deleteGroup<T>(groups: inout [PathLinkEntry], points: inout [T], index: Int) {
        guard groups.indices.contains(index) else { return }
        KMPDocument.deleteGroup(groups: &groups, points: &points, index: index)
        box.selection = nil
        box.isDirty = true
        box.objectWillChange.send()
    }

    private func duplicatePath(from sourceSection: KMPSection, groupIndex: Int, to destSection: KMPSection) {
        guard [KMPSection.enph, .itph, .ckph].contains(sourceSection),
              [KMPSection.enph, .itph, .ckph].contains(destSection) else { return }
        
        let sourceGroup: PathLinkEntry
        let sourcePoints: [Vec3]
        // Radius/setting1/setting2 alongside each point, when the source has them at all. ENPT
        // and ITPT are the same shape (position + radius + 2 settings), so these survive not just
        // a same-type duplicate but also enemy<->item, which previously silently reset every
        // point's width back to the default 500. Only CKPT has no such fields (its "width" is the
        // gate's own left/right span, rebuilt below), so this stays nil for a `.ckph` source.
        let sourceWidths: [(radius: Float, setting1: UInt16, setting2: UInt16)]?

        switch sourceSection {
        case .enph:
            guard box.doc.enph.indices.contains(groupIndex) else { return }
            sourceGroup = box.doc.enph[groupIndex]
            let s = Int(sourceGroup.startIndex)
            let c = Int(sourceGroup.pointCount)
            let entries = (s..<(s+c)).compactMap { box.doc.enpt.indices.contains($0) ? box.doc.enpt[$0] : nil }
            sourcePoints = entries.map { $0.position }
            sourceWidths = entries.map { ($0.radius, $0.setting1, $0.setting2) }
        case .itph:
            guard box.doc.itph.indices.contains(groupIndex) else { return }
            sourceGroup = box.doc.itph[groupIndex]
            let s = Int(sourceGroup.startIndex)
            let c = Int(sourceGroup.pointCount)
            let entries = (s..<(s+c)).compactMap { box.doc.itpt.indices.contains($0) ? box.doc.itpt[$0] : nil }
            sourcePoints = entries.map { $0.position }
            sourceWidths = entries.map { ($0.radius, $0.setting1, $0.setting2) }
        case .ckph:
            guard box.doc.ckph.indices.contains(groupIndex) else { return }
            sourceGroup = box.doc.ckph[groupIndex]
            let s = Int(sourceGroup.startIndex)
            let c = Int(sourceGroup.pointCount)
            sourcePoints = (s..<(s+c)).compactMap { i -> Vec3? in
                guard box.doc.ckpt.indices.contains(i) else { return nil }
                let pt = box.doc.ckpt[i]
                return Vec3(x: (pt.left.x + pt.right.x) / 2, y: 0, z: (pt.left.y + pt.right.y) / 2)
            }
            sourceWidths = nil
        default: return
        }

        guard !sourcePoints.isEmpty else { return }

        let destGroup = PathLinkEntry(startIndex: 0, pointCount: UInt8(sourcePoints.count), previousGroups: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF], nextGroups: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])

        switch destSection {
        case .enph:
            let start = box.doc.enpt.count
            box.doc.enpt.append(contentsOf: sourcePoints.enumerated().map { i, p in
                let w = sourceWidths?[i]
                return ENPTEntry(position: p, radius: w?.radius ?? 500, setting1: w?.setting1 ?? 0, setting2: w?.setting2 ?? 0)
            })
            var g = destGroup
            g.startIndex = UInt8(start)
            box.doc.enph.append(g)
        case .itph:
            let start = box.doc.itpt.count
            box.doc.itpt.append(contentsOf: sourcePoints.enumerated().map { i, p in
                let w = sourceWidths?[i]
                return ITPTEntry(position: p, radius: w?.radius ?? 500, setting1: w?.setting1 ?? 0, setting2: w?.setting2 ?? 0)
            })
            var g = destGroup
            g.startIndex = UInt8(start)
            box.doc.itph.append(g)
        case .ckph:
            let start = box.doc.ckpt.count
            let halfWidth: Float = 100
            box.doc.ckpt.append(contentsOf: sourcePoints.enumerated().map { i, p in
                let tangent: SIMD2<Float>
                if i + 1 < sourcePoints.count {
                    let next = sourcePoints[i + 1]
                    tangent = SIMD2<Float>(next.x - p.x, next.z - p.z)
                } else if i > 0 {
                    let prev = sourcePoints[i - 1]
                    tangent = SIMD2<Float>(p.x - prev.x, p.z - prev.z)
                } else {
                    tangent = SIMD2<Float>(0, 1)
                }
                let n = vecNormalized(tangent)
                let normal = SIMD2<Float>(-n.y * halfWidth, n.x * halfWidth)
                return CKPTEntry(left: Vec2(x: p.x - normal.x, y: p.z - normal.y),
                                 right: Vec2(x: p.x + normal.x, y: p.z + normal.y))
            })
            var g = destGroup
            g.startIndex = UInt8(start)
            box.doc.ckph.append(g)
        default: break
        }
        
        box.selection = nil
        box.isDirty = true
        box.objectWillChange.send()
        pushHistory("Duplicate \(sourceSection.displayName) to \(destSection.displayName)")
    }

    /// Whether `selection` can currently be removed. Most section types have no other section
    /// indexing into them, so any entry can go; ENPT/ITPT/CKPT are referenced by index-range from
    /// their path groups, so we allow removing the tail point of *any* group without orphans.
    private func canRemove(_ selection: KMPSelection) -> Bool { box.canRemove(selection) }

    private func removeSelectedPoint() {
        guard let sel = box.selection, canRemove(sel) else { return }
        box.remove(sel)
        pushHistory("Remove \(section(of: sel)?.displayName ?? "Point")")
    }

    private func shrinkGroupContaining(_ groups: inout [PathLinkEntry], index: Int) {
        KMPDocument.shrinkGroupContaining(&groups, index: index)
    }

    /// Removing a CAME entry can leave other CAME/AREA entries pointing at a now-shifted or
    /// now-gone index, since both reference cameras by plain index rather than a stable id, fix
    /// those up (clear a reference to the removed camera, shift references past it down by one).
    private func removeCame(at i: Int) {
        KMPCameraSequence.removeCamera(i, in: box.doc)
    }

    /// Same idea as `removeCame`, for a Route (POTI): GOBJ/AREA/CAME each reference one by plain
    /// index, so removing one needs the same "clear a reference to it, shift references past it"
    /// fixup or a deletion would silently repoint everything after it at the wrong route.
    private func removePotiRoute(at i: Int) {
        KMPCameraSequence.removeRoute(i, in: box.doc)
    }

    // MARK: Ordering & respawns

    private func isOrderable(_ sel: KMPSelection) -> Bool {
        switch sel.asPoint {
        case .enpt, .itpt, .ckpt, .jgpt: return true
        case .poti(_, let p): return p != nil
        default: return false
        }
    }

    private func movePoint(_ sel: KMPSelection, by delta: Int) {
        guard let moved = box.doc.movePoint(sel, by: delta) else { return }
        box.selection = moved
        box.isDirty = true
        box.objectWillChange.send()
        pushHistory(delta < 0 ? "Move Point Earlier" : "Move Point Later")
    }

    /// Right-click on a point: selects it and offers what can be done to it. On empty canvas:
    /// add any kind of point there.
    private func pointMenu(at location: CGPoint, size: CGSize) -> [CanvasMenuItem] {
        guard !penToolActive else { return [] }
        guard let hit = hitTest(at: location, size: size) else {
            // Empty canvas: add a point right where the click was.
            let world = screenToWorld(location, size: size)
            let sections: [KMPSection] = [.ktpt, .enpt, .itpt, .ckpt, .gobj, .jgpt, .cnpt, .mspt, .area, .came]
            return sections.map { section in
                CanvasMenuItem(title: "Add \(section.displayName) Here") { addPointWithHistory(section, at: world) }
            }
        }
        if multiSelection.count > 1, multiSelection.contains(hit) {
            return [CanvasMenuItem(title: "Delete \(multiSelection.count) Points") { deleteMultiSelection() }]
        }
        multiSelection = []
        box.selection = hit
        let sel = hit.asPoint
        var items: [CanvasMenuItem] = []
        if box.doc.canInsertPoint(after: sel) {
            items.append(CanvasMenuItem(title: "Add Point Before") { insertPoint(before: sel) })
            items.append(CanvasMenuItem(title: "Add Point After") { insertPoint(after: sel) })
        }
        switch sel {
        case _ where isDuplicable(sel):
            items.append(CanvasMenuItem(title: "Duplicate    \u{2318}D") { duplicateNearby(sel, size: size) })
        default: break
        }
        if isOrderable(sel) {
            items.append(.separator)
            items.append(CanvasMenuItem(title: "Move Earlier", enabled: box.doc.canMovePoint(sel, by: -1)) { movePoint(sel, by: -1) })
            items.append(CanvasMenuItem(title: "Move Later", enabled: box.doc.canMovePoint(sel, by: 1)) { movePoint(sel, by: 1) })
        }
        if supportsGroundSnap(sel) {
            items.append(.separator)
            items.append(CanvasMenuItem(title: "Snap to Ground", enabled: collisionMesh != nil) { snapToGround(sel); pushHistory("Snap to Ground") })
        }
        items.append(.separator)
        items.append(CanvasMenuItem(title: "Delete", enabled: canRemove(hit)) { box.selection = hit; removeSelectedPoint() })
        return items
    }

    /// Objects, starts, respawns, cannons, areas and cameras that ⌘D / Duplicate can copy (path
    /// points are added before/after instead, so their paths stay in order).
    private func isDuplicable(_ sel: KMPSelection) -> Bool {
        switch sel { case .ktpt, .gobj, .jgpt, .cnpt, .mspt, .area, .came: true; default: false }
    }

    /// A copy of `sel` a little down and to the right of it on screen, selected.
    private func duplicateNearby(_ sel: KMPSelection, size: CGSize) {
        guard isDuplicable(sel), let pt = points().first(where: { $0.id == sel }) else { return }
        let p = worldToScreen(pt.x, pt.z, size: size)
        duplicateSelection(sel, at: screenToWorld(CGPoint(x: p.x + 24, y: p.y + 24), size: size))
        pushHistory("Duplicate \(section(of: sel)?.displayName ?? "Point")")
    }

    private func insertPoint(before sel: KMPSelection) {
        guard let added = box.doc.insertPoint(before: sel) else { return }
        box.selection = added
        box.isDirty = true
        box.objectWillChange.send()
        pushHistory("Insert Point")
    }

    private func insertPoint(after sel: KMPSelection) {
        guard let added = box.doc.insertPoint(after: sel) else { return }
        box.selection = added
        box.isDirty = true
        box.objectWillChange.send()
        pushHistory("Insert Point")
    }

    private func moveRoute(_ i: Int, by delta: Int) {
        guard box.doc.moveRoute(i, by: delta) else { return }
        if case .poti(let r, let p) = box.selection, r == i || r == i + delta { box.selection = .poti(route: r == i ? i + delta : i, point: p) }
        box.isDirty = true
        box.objectWillChange.send()
        pushHistory("Reorder Routes")
    }

    private func runRespawnPerCheckpoint() {
        let count = box.doc.makeRespawnPerCheckpoint(collision: collisionMesh)
        guard count > 0 else { return }
        box.selection = nil
        box.isDirty = true
        box.objectWillChange.send()
        pushHistory("Respawn per Checkpoint")
        workbench.log("Made \(count) respawn points, one per checkpoint\(collisionMesh == nil ? " (no collision loaded, so heights come from the nearest enemy point, load the .kcl and run it again to snap them to the ground)" : ", snapped to the ground").")
    }

    private func runMakeTestable() {
        let fixes = box.doc.isBOL
            ? BOL.makeTestable(box.doc, ground: collisionMesh.map { mesh in { x, z in groundHeight(x: x, z: z, mesh: mesh) } })
            : makeTestable()
        testableFixes = fixes
        showTestableResult = true
        guard !fixes.isEmpty else { return }
        box.isDirty = true
        box.objectWillChange.send()
        pushHistory("Make Testable")
    }

    /// Fills in whatever this KMP is missing to load and be raced at all, not a full "is this a
    /// good track" pass (that's `ModVerifier`'s job on the whole archive, and things like an actual
    /// AI driving line can't be auto-generated from nothing), just the specific, well-documented
    /// crash/non-load causes a from-scratch or heavily-edited KMP can be missing: a start point,
    /// somewhere to respawn, a checkpoint to count a lap, no dead-end paths, no camera/route/point
    /// reference pointing at something that doesn't exist. Never touches anything already valid.
    private func makeTestable() -> [String] {
        var fixes: [String] = []
        let battle = BattleArena.isBattle(box.doc)

        if battle {
            fixes += BattleArena.makeTestable(box.doc, ground: collisionMesh.map { mesh in { x, z in groundHeight(x: x, z: z, mesh: mesh) } })
        } else {
        if box.doc.ktpt.isEmpty {
            box.doc.ktpt.append(KTPTEntry(position: Vec3()))
            fixes.append("No Start Point (KTPT), added one at the origin.")
        }
        // The single most common real-world "spawns inside the ground and falls through" cause:
        // an *existing* Start Point whose Y just doesn't match the collision mesh at its X/Z (author
        // moved the point, or the track, after last placing it), unlike every check above, this
        // silently leaves a structurally-valid KMP that still doesn't work in-game, and previously
        // nothing here ever touched an existing KTPT's height at all (only a missing one got added,
        // at the origin, also unsnapped). Requires a collision mesh to already be loaded in this
        // editor (see `autoDetectCollision`); silently skipped otherwise rather than guessing.
        if let mesh = collisionMesh, let y = startHeight(x: box.doc.ktpt[0].position.x, z: box.doc.ktpt[0].position.z, mesh: mesh) {
            let off = box.doc.ktpt[0].position.y - y
            if abs(off) > Self.groundSnapTolerance {
                box.doc.ktpt[0].position.y = y + Self.groundClearance + Float(startPointYPadding)
                fixes.append("Start Point's height was \(Int(off)) units off the collision mesh's surface at its X/Z, snapped it to the ground.")
            }
        }
        let start = box.doc.ktpt[0].position

        if box.doc.jgpt.isEmpty {
            box.doc.jgpt.append(JGPTEntry(position: start))
            fixes.append("No Respawn Point (JGPT), added one at the start. Falling off the track would otherwise have nowhere to send a player.")
        } else if let mesh = collisionMesh {
            for i in box.doc.jgpt.indices {
                guard let y = groundHeight(x: box.doc.jgpt[i].position.x, z: box.doc.jgpt[i].position.z, mesh: mesh) else { continue }
                let off = box.doc.jgpt[i].position.y - y
                guard abs(off) > Self.groundSnapTolerance else { continue }
                box.doc.jgpt[i].position.y = y + Self.groundClearance
                fixes.append("Respawn Point \(i + 1)'s height was \(Int(off)) units off the collision mesh's surface, snapped it to the ground.")
            }
        }

        if box.doc.ckpt.isEmpty {
            let halfWidth: Float = 3000
            box.doc.ckpt = [CKPTEntry(left: Vec2(x: start.x - halfWidth, y: start.z), right: Vec2(x: start.x + halfWidth, y: start.z),
                                       respawnIndex: 0, lapCounterType: 0)]
            box.doc.ckph = [PathLinkEntry(startIndex: 0, pointCount: 1, previousGroups: [0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF], nextGroups: [0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])]
            fixes.append("No Checkpoints (CKPT), added a single Finish Line gate at the start. A lap could never be counted otherwise.")
        } else {
            for i in box.doc.ckpt.indices where !box.doc.jgpt.indices.contains(Int(box.doc.ckpt[i].respawnIndex)) {
                box.doc.ckpt[i].respawnIndex = 0
                fixes.append("Checkpoint \(i + 1) pointed at a Respawn Point that doesn't exist, reset to Respawn Point 1.")
            }
            if !box.doc.ckpt.contains(where: { $0.lapCounterType == 0 }) {
                box.doc.ckpt[box.doc.ckpt.count - 1].lapCounterType = 0
                fixes.append("No checkpoint was marked as the Finish Line, set the last one.")
            }
        }
        }

        // A battle arena's CPU network isn't a race loop (retail arenas don't pair their links),
        // so it's left as authored.
        if !battle { fixPathLinks(&box.doc.enph, label: "Enemy", fixes: &fixes) }
        // Links first (back-links, an unlinked set chained into a loop), so only item paths that
        // really have nothing leading into them are removed; then links again for the rest.
        fixPathLinks(&box.doc.itph, label: "Item", fixes: &fixes)
        if !battle, box.doc.itph.count > 1, case let n = KMPDocument.removeUnreachableGroups(groups: &box.doc.itph, points: &box.doc.itpt), n > 0 {
            fixes.append("\(n) item path\(n == 1 ? " had" : "s had") nothing leading into it, removed, since the game crashes reading the missing link once items are picked up.")
            fixPathLinks(&box.doc.itph, label: "Item", fixes: &fixes)
        }
        fixPathLinks(&box.doc.ckph, label: "Checkpoint", fixes: &fixes)

        for i in box.doc.gobj.indices where box.doc.gobj[i].routeID != 0xFFFF && Int(box.doc.gobj[i].routeID) >= box.doc.poti.count {
            box.doc.gobj[i].routeID = 0xFFFF
            fixes.append("Object \(i + 1) pointed at a Route that doesn't exist, cleared its Route.")
        }
        for i in box.doc.area.indices where box.doc.area[i].routeID != 0xFF && Int(box.doc.area[i].routeID) >= box.doc.poti.count {
            box.doc.area[i].routeID = 0xFF
            fixes.append("Area \(i + 1) pointed at a Route that doesn't exist, cleared its Route.")
        }
        for i in box.doc.area.indices where box.doc.area[i].enptID != 0xFF && !box.doc.enpt.indices.contains(Int(box.doc.area[i].enptID)) {
            box.doc.area[i].enptID = 0xFF
            fixes.append("Area \(i + 1) pointed at an Enemy Point that doesn't exist, cleared it. (A known leftover from some original tracks' destination-point Areas.)")
        }
        for i in box.doc.area.indices where box.doc.area[i].cameraIndex != 0xFF && !box.doc.came.indices.contains(Int(box.doc.area[i].cameraIndex)) {
            box.doc.area[i].cameraIndex = 0xFF
            fixes.append("Area \(i + 1) pointed at a Camera that doesn't exist, cleared it.")
        }

        for i in box.doc.came.indices {
            if box.doc.came[i].routeID != 0xFF && Int(box.doc.came[i].routeID) >= box.doc.poti.count {
                box.doc.came[i].routeID = 0xFF
                fixes.append("Camera \(i + 1) pointed at a Route that doesn't exist, cleared its Route.")
            }
            if box.doc.came[i].next != 0xFF && !box.doc.came.indices.contains(Int(box.doc.came[i].next)) {
                box.doc.came[i].next = 0xFF
                fixes.append("Camera \(i + 1)'s Next Camera doesn't exist, cleared it.")
            }
            let needsRoute = cameraTypeInfo[box.doc.came[i].type]?.needsRoute ?? false
            if needsRoute, box.doc.came[i].routeID == 0xFF {
                let pos = box.doc.came[i].position
                box.doc.poti.append(POTIRoute(points: [RoutePoint(position: pos), RoutePoint(position: Vec3(x: pos.x + 1000, y: pos.y, z: pos.z))]))
                box.doc.came[i].routeID = UInt8(box.doc.poti.count - 1)
                fixes.append("Camera \(i + 1) is a type that needs a Route to move along but had none, created a small one at its position.")
            }
        }

        if !box.doc.came.isEmpty {
            if Int(box.doc.openingCameraIndex) >= box.doc.came.count {
                box.doc.openingCameraIndex = 0
                fixes.append("The opening-pan camera pointed past the end of the camera list, reset to Camera 0. (The intro reads off the end of the array otherwise.)")
            }
            if Int(box.doc.selectionCameraIndex) >= box.doc.came.count {
                box.doc.selectionCameraIndex = box.doc.openingCameraIndex
            }
        }

        let speed = Float(bitPattern: UInt32(box.doc.stgi.speedFactor) << 16)
        if box.doc.stgi.speedFactor != 0 && !(speed >= 0.1 && speed <= 10) {
            box.doc.stgi.speedFactor = 0
            fixes.append("Stage Info's Speed Factor decoded to \(speed)x, not a sensible multiplier, reset to normal speed.")
        }

        let invalidObjects = box.doc.gobj.indices.filter { !isRetailObjectID(box.doc.gobj[$0].objectID) }
        for i in invalidObjects.reversed() {
            fixes.append("Object \(i + 1) had ID 0x\(String(box.doc.gobj[i].objectID, radix: 16)), which isn't a real object (the game crashes when a kart gets near it), removed it.")
            box.doc.gobj.remove(at: i)
        }

        for i in box.doc.poti.indices where box.doc.poti[i].points.count <= 2 && box.doc.poti[i].isSmooth {
            box.doc.poti[i].isSmooth = false
            fixes.append("Route \(i + 1) had Smooth motion enabled with only \(box.doc.poti[i].points.count) point(s), disabled it. Smoothing needs at least 3 points.")
        }

        return fixes
    }

    /// Makes path groups form one complete, closed loop so every point of a route is actually
    /// driven, generalizing what used to only self-link individual dead-ends:
    ///
    /// - A single group (the common retail case for checkpoints) so far unlinked links *back to
    ///   itself*. Both `next` *and* `previous` have to self-reference, matching retail's own closed
    ///   loop groups (confirmed byte-for-byte against `beginner_course.szs`'s CKPH: a lone group
    ///   closing on itself has previousGroups[0] == nextGroups[0] == its own index, not just the
    ///   latter). Setting only `next` leaves the loop asymmetric: wrapping forward past the last
    ///   point works, but nothing declares where the *first* point's path continues from, and that's
    ///   exactly the wraparound a completed lap depends on. In-game that asymmetry reproducibly
    ///   desyncs (enemy AI routes, item routes, and checkpoints alike), but this app's own preview
    ///   never reads `previousGroups` back, so only the wiki's "Last and Next must match each
    ///   other" rule, and the real game, surface it.
    ///
    /// - Several groups that are *all* completely unlinked (whose `previous`/`next` are all 0xFF --
    ///   exactly what every group created through the UI starts as) are chained into a single loop
    ///   in array order, the same "sequence" the group list implies. This is unambiguous: there is
    ///   no fork information to preserve. Left as-is, each group would instead dead-end on itself
    ///   and the route would only ever drive its first section.
    ///
    /// - Finally `previous`/`next` are reconciled: if group A lists B as next, B gains A in its
    ///   first free `previous` slot if it doesn't already list A (and vice-versa). Never overwrites
    ///   an existing link, never duplicates one, never touches self-references, and never
    ///   second-guesses a fork the user already wired.
    ///
    /// Any group still left without a *"next"* after all that (e.g. the loose end of a partially
    /// linked chain) is closed into its own loop, both ends, the original fixer's behavior, kept
    /// so the route always has somewhere to go before a lap completes. `ModVerifier` flags
    /// unresolved cases for a human separately.
    private func fixPathLinks(_ groups: inout [PathLinkEntry], label: String, fixes: inout [String]) {
        fixes += KMPDocument.fixPathLinks(&groups, label: label)
    }

    /// Every grid-line position covering `0..<extent` that's `step`-periodic through `origin` --
    /// i.e. every `x` with `(x - origin)` an exact multiple of `step`. The previous version started
    /// straight from `origin`'s own remainder (which sits inside `0..<extent` whenever `origin`
    /// itself is on-screen, e.g. exactly `size/2` at the default pan) and only walked forward from
    /// there, so it silently skipped every line before that point, half the grid, typically the
    /// entire left/top half at the default pan offset. Normalizing to the smallest such position
    /// `<= 0` first, then walking forward, guarantees the whole visible range is covered.
    private func gridLineOffsets(origin: CGFloat, extent: CGFloat, step: CGFloat) -> [CGFloat] {
        guard step > 0 else { return [] }
        var x = origin.truncatingRemainder(dividingBy: step)
        if x >= 0 { x -= step }
        var out: [CGFloat] = []
        while x < extent { out.append(x); x += step }
        return out
    }

    /// Points (and links) of the path group or route picked in the inspector are drawn in this.
    private static let groupHighlight = Color.cyan

    private func isInSelectedGroup(_ id: KMPSelection) -> Bool {
        func within(_ groups: [PathLinkEntry], _ g: Int, _ i: Int) -> Bool {
            groups.indices.contains(g) && i >= Int(groups[g].startIndex) && i < Int(groups[g].startIndex) + Int(groups[g].pointCount)
        }
        switch (box.selection, id.asPoint) {
        case (.enph(let g)?, .enpt(let i)): return within(box.doc.enph, g, i)
        case (.itph(let g)?, .itpt(let i)): return within(box.doc.itph, g, i)
        case (.ckph(let g)?, .ckpt(let i)), (.ckph(let g)?, .ckptLeft(let i)), (.ckph(let g)?, .ckptRight(let i)): return within(box.doc.ckph, g, i)
        case (.poti(let r, nil)?, .poti(let r2, _)): return r == r2
        default: return false
        }
    }

    private func worldToScreen(_ x: Float, _ z: Float, size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2 + panOffset.width + CGFloat(x) * scale * 0.05,
                y: size.height / 2 + panOffset.height + CGFloat(z) * scale * 0.05)
    }

    private func screenToWorldDelta(_ delta: CGSize) -> SIMD2<Float> {
        SIMD2<Float>(Float(delta.width / (scale * 0.05)), Float(delta.height / (scale * 0.05)))
    }

    private func screenToWorld(_ point: CGPoint, size: CGSize) -> SIMD2<Float> {
        let wx = (point.x - size.width / 2 - panOffset.width) / (scale * 0.05)
        let wz = (point.y - size.height / 2 - panOffset.height) / (scale * 0.05)
        return SIMD2<Float>(Float(wx), Float(wz))
    }

    /// Each AREA's footprint seen from above: a box or cylinder, 10000 units across at scale 1
    /// (the game's own area test), turned by its yaw.
    private func drawAreaShapes(in context: inout GraphicsContext, size: CGSize) {
        for (i, a) in box.doc.area.enumerated() {
            let yaw = Double(a.rotation.y) * .pi / 180
            let (s, c) = (Float(sin(yaw)), Float(cos(yaw)))
            func world(_ lx: Float, _ lz: Float) -> CGPoint {
                worldToScreen(a.position.x + lx * c + lz * s, a.position.z - lx * s + lz * c, size: size)
            }
            let hx = a.scale.x * 5000, hz = a.scale.z * 5000
            var path = Path()
            if a.shape == 1 {
                let centre = worldToScreen(a.position.x, a.position.z, size: size)
                let r = CGFloat(hx) * scale * 0.05
                path.addEllipse(in: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2))
            } else {
                path.move(to: world(-hx, -hz)); path.addLine(to: world(hx, -hz)); path.addLine(to: world(hx, hz)); path.addLine(to: world(-hx, hz)); path.closeSubpath()
            }
            let selected = box.selection == .area(i)
            context.fill(path, with: .color(.red.opacity(selected ? 0.25 : 0.1)))
            context.stroke(path, with: .color(.red.opacity(selected ? 1 : 0.6)), style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: selected ? [] : [5, 3]))
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        if showBackgroundModel, let backgroundMDL0 {
            drawCourseModelSilhouette(backgroundMDL0, in: &context, size: size)
        }

        // Light grid for orientation.
        context.stroke(Path { p in
            let step: CGFloat = 50 * scale
            for x in gridLineOffsets(origin: size.width / 2 + panOffset.width, extent: size.width, step: step) {
                p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in gridLineOffsets(origin: size.height / 2 + panOffset.height, extent: size.height, step: step) {
                p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
            }
        }, with: .color(.gray.opacity(0.15)))

        for link in links() {
            var path = Path()
            path.move(to: worldToScreen(link.from.x, link.from.y, size: size))
            path.addLine(to: worldToScreen(link.to.x, link.to.y, size: size))
            let inGroup = box.selection != nil && link.owner == box.selection
            context.stroke(path, with: .color(inGroup ? Self.groupHighlight : link.color.opacity(0.6)), lineWidth: inGroup ? 2.5 : 1.5)
        }

        if layers.contains("AREA") { drawAreaShapes(in: &context, size: size) }

        for pt in points() {
            let p = worldToScreen(pt.x, pt.z, size: size)
            let selected = box.selection == pt.id
            let r: CGFloat = selected ? 6 : 4
            let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
            context.fill(Path(ellipseIn: rect), with: .color(isInSelectedGroup(pt.id) ? Self.groupHighlight : pt.color))
            if selected {
                context.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(.white), lineWidth: 2)
            }
            if multiSelection.contains(pt.id) {
                context.stroke(Path(ellipseIn: rect.insetBy(dx: -5, dy: -5)), with: .color(.orange), lineWidth: 2)
            }
            if let angle = pt.arrowAngle {
                let rad = CGFloat(angle) * .pi / 180.0
                // MKWii Z is down, so +Z forward points down in screen coords.
                let dirX = sin(rad)
                let dirY = cos(rad) // +Z is +Y on screen
                
                var arrow = Path()
                let length: CGFloat = 16
                let tip = CGPoint(x: p.x + dirX * length, y: p.y + dirY * length)
                arrow.move(to: p)
                arrow.addLine(to: tip)
                
                // Draw arrowhead
                let headAng1 = rad + .pi * 0.75
                let headAng2 = rad - .pi * 0.75
                let headLen: CGFloat = 6
                arrow.move(to: tip)
                arrow.addLine(to: CGPoint(x: tip.x + sin(headAng1) * headLen, y: tip.y + cos(headAng1) * headLen))
                arrow.move(to: tip)
                arrow.addLine(to: CGPoint(x: tip.x + sin(headAng2) * headLen, y: tip.y + cos(headAng2) * headLen))
                
                context.stroke(arrow, with: .color(pt.color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }

        if let marqueeRect {
            context.fill(Path(marqueeRect), with: .color(.orange.opacity(0.12)))
            context.stroke(Path(marqueeRect), with: .color(.orange), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }

        if penToolActive {
            drawPenPath(in: &context, size: size)
        }
    }

    /// Doubles as the pen tool's click/click-drag recognizer when `penToolActive` (see
    /// `commitPenAnchor`), needs `minimumDistance: 0` there so a plain click (no movement at all)
    /// still fires `onEnded` and places a corner anchor, which is why this one `DragGesture` handles
    /// both roles rather than attaching a second, separately-configured one. Also doubles as the
    /// Shift-drag marquee recognizer (see `commitMarqueeSelection`), `NSEvent.modifierFlags` is
    /// checked live, right when the drag actually starts, rather than baked into this function's
    /// `minimumDistance` at whatever moment SwiftUI last happened to rebuild it (which wouldn't
    /// reliably reflect Shift's state at the moment the mouse button goes down).
    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: penToolActive ? 0 : 3)
            .onChanged { value in
                if penToolActive {
                    pendingPenDrag = (value.startLocation, value.location)
                    return
                }
                if !dragSessionStarted {
                    dragSessionStarted = true
                    lastAppliedDelta = .zero
                    let isDuplicate = Controls.shared.held(.kmpDuplicateDrag)
                    let isBoxSelect = Controls.shared.held(.kmpBoxSelect)
                    
                    if let hit = hitTest(at: value.startLocation, size: size) {
                        if isDuplicate {
                            var startPos = screenToWorld(value.startLocation, size: size)
                            if let pt = points().first(where: { $0.id == hit }) {
                                startPos = SIMD2<Float>(pt.x, pt.z)
                            }
                            duplicateSelection(hit, at: startPos)
                            draggingPointID = box.selection
                            pushHistory("Duplicate Point")
                        } else {
                            draggingPointID = hit
                            box.selection = hit
                        }
                        // Dragging a point that is part of the selection moves the whole selection.
                        if isDuplicate || multiSelection.count < 2 || !multiSelection.contains(hit.asPoint) { multiSelection = [] }
                    } else {
                        draggingPointID = nil
                        marqueeModeActive = isBoxSelect
                        if !isBoxSelect { multiSelection = [] }
                    }
                }
                if marqueeModeActive {
                    marqueeRect = CGRect(x: min(value.startLocation.x, value.location.x),
                                          y: min(value.startLocation.y, value.location.y),
                                          width: abs(value.location.x - value.startLocation.x),
                                          height: abs(value.location.y - value.startLocation.y))
                    return
                }
                if let id = draggingPointID {
                    if Controls.shared.held(.kmpRotate) {
                        rotatePoint(id, toScreenLocation: value.location, size: size)
                    } else {
                        movePoint(id, byScreenDelta: value.translation, isOrthogonal: Controls.shared.held(.kmpConstrain))
                    }
                } else {
                    panOffset = CGSize(width: dragStartOffset.width + value.translation.width,
                                        height: dragStartOffset.height + value.translation.height)
                }
            }
            .onEnded { value in
                if penToolActive {
                    commitPenAnchor(value, size: size)
                    pendingPenDrag = nil
                    return
                }
                dragSessionStarted = false
                lastAppliedDelta = .zero
                if marqueeModeActive {
                    if let rect = marqueeRect, rect.width < 5, rect.height < 5 {
                        handleTap(at: value.startLocation, size: size)
                    } else {
                        commitMarqueeSelection(rect: marqueeRect, size: size, from: value.startLocation)
                    }
                    marqueeRect = nil
                    marqueeModeActive = false
                    return
                }
                if draggingPointID != nil {
                    draggingPointID = nil
                    box.isDirty = true
                    pushHistory("Move Point")
                } else {
                    dragStartOffset = panOffset
                }
            }
    }

    private func handleTap(at location: CGPoint, size: CGSize) {
        let dupMods = Controls.shared.binding(.kmpDuplicateDrag).mods, held = ControlBinding.mods(of: NSEvent.modifierFlags)
        let alsoOption = dupMods & ControlBinding.option == 0 && held == dupMods | ControlBinding.option
        if let currentSelection = box.selection, held == dupMods || alsoOption {
            var world = screenToWorld(location, size: size)
            if alsoOption {
                if let pt = points().first(where: { $0.id == currentSelection }) {
                    let dx = abs(world.x - pt.x)
                    let dz = abs(world.y - pt.z)
                    if dx > dz {
                        world.y = pt.z
                    } else {
                        world.x = pt.x
                    }
                }
            }
            duplicateSelection(currentSelection, at: world)
            pushHistory("Duplicate Point")
            return
        }
        
        multiSelection = []
        if let pt = hitTest(at: location, size: size) {
            box.selection = pt
        } else if let whole = hitTestLink(at: location, size: size) {
            // A line (not a point): select the whole path/route it belongs to.
            box.selection = whole
        } else {
            box.selection = nil
        }
    }

    private func duplicateSelection(_ id: KMPSelection, at world: SIMD2<Float>) {
        let pos = Vec3(x: world.x, y: 0, z: world.y)
        switch id {
        case .ktpt(let i):
            guard box.doc.ktpt.indices.contains(i) else { return }
            var clone = box.doc.ktpt[i]
            clone.position = pos
            box.doc.ktpt.append(clone)
            box.selection = .ktpt(box.doc.ktpt.count - 1)
        case .enpt(let i), .enptLeft(let i), .enptRight(let i):
            guard box.doc.enpt.indices.contains(i) else { return }
            var clone = box.doc.enpt[i]
            clone.position = pos
            let insertAt = insertIndexForLastGroup(box.doc.enph, arrayCount: box.doc.enpt.count)
            box.doc.enpt.insert(clone, at: insertAt)
            appendToLastGroup(&box.doc.enph, insertedAt: insertAt)
            box.selection = .enpt(insertAt)
        case .itpt(let i), .itptLeft(let i), .itptRight(let i):
            guard box.doc.itpt.indices.contains(i) else { return }
            var clone = box.doc.itpt[i]
            clone.position = pos
            let insertAt = insertIndexForLastGroup(box.doc.itph, arrayCount: box.doc.itpt.count)
            box.doc.itpt.insert(clone, at: insertAt)
            appendToLastGroup(&box.doc.itph, insertedAt: insertAt)
            box.selection = .itpt(insertAt)
        case .ckpt(let i), .ckptLeft(let i), .ckptRight(let i):
            guard box.doc.ckpt.indices.contains(i) else { return }
            let orig = box.doc.ckpt[i]
            let center = SIMD2<Float>((orig.left.x + orig.right.x) / 2, (orig.left.y + orig.right.y) / 2)
            let offsetLeft = SIMD2<Float>(orig.left.x - center.x, orig.left.y - center.y)
            let offsetRight = SIMD2<Float>(orig.right.x - center.x, orig.right.y - center.y)
            
            var clone = orig
            clone.left = Vec2(x: world.x + offsetLeft.x, y: world.y + offsetLeft.y)
            clone.right = Vec2(x: world.x + offsetRight.x, y: world.y + offsetRight.y)
            
            let insertAt = insertIndexForLastGroup(box.doc.ckph, arrayCount: box.doc.ckpt.count)
            box.doc.ckpt.insert(clone, at: insertAt)
            appendToLastGroup(&box.doc.ckph, insertedAt: insertAt)
            box.selection = .ckpt(insertAt)
        case .gobj(let i):
            guard box.doc.gobj.indices.contains(i) else { return }
            var clone = box.doc.gobj[i]
            clone.position = pos
            box.doc.gobj.append(clone)
            box.selection = .gobj(box.doc.gobj.count - 1)
        case .jgpt(let i):
            guard box.doc.jgpt.indices.contains(i) else { return }
            var clone = box.doc.jgpt[i]
            clone.position = pos
            box.doc.jgpt.append(clone)
            box.selection = .jgpt(box.doc.jgpt.count - 1)
        case .cnpt(let i):
            guard box.doc.cnpt.indices.contains(i) else { return }
            var clone = box.doc.cnpt[i]
            clone.position = pos
            box.doc.cnpt.append(clone)
            box.selection = .cnpt(box.doc.cnpt.count - 1)
        case .mspt(let i):
            guard box.doc.mspt.indices.contains(i) else { return }
            var clone = box.doc.mspt[i]
            clone.position = pos
            box.doc.mspt.append(clone)
            box.selection = .mspt(box.doc.mspt.count - 1)
        case .area(let i):
            guard box.doc.area.indices.contains(i) else { return }
            var clone = box.doc.area[i]
            clone.position = pos
            box.doc.area.append(clone)
            box.selection = .area(box.doc.area.count - 1)
        case .came(let i):
            guard box.doc.came.indices.contains(i) else { return }
            var clone = box.doc.came[i]
            clone.position = pos
            box.doc.came.append(clone)
            box.selection = .came(box.doc.came.count - 1)
        case .poti(let route, let point):
            guard let point, box.doc.poti.indices.contains(route), box.doc.poti[route].points.indices.contains(point) else { return }
            var clone = box.doc.poti[route].points[point]
            clone.position = pos
            box.doc.poti[route].points.insert(clone, at: point + 1)
            box.selection = .poti(route: route, point: point + 1)
        default:
            break
        }
        box.isDirty = true
    }

    private func hitTest(at location: CGPoint, size: CGSize) -> KMPSelection? {
        var best: (KMPSelection, CGFloat)?
        for pt in points() {
            let p = worldToScreen(pt.x, pt.z, size: size)
            let d = hypot(p.x - location.x, p.y - location.y)
            if d < 10, best == nil || d < best!.1 { best = (pt.id, d) }
        }
        return best?.0
    }

    /// Taps can also hit a *line* rather than a point: clicking anywhere along a path's rail or
    /// route edge selects the whole group/route (`links()` stamps each link with its `owner`).
    /// Points win, this only runs after `hitTest` came up empty, so a vertex tapped within
    /// 10px still selects that single point while the draw between two vertices selects the path.
    private func hitTestLink(at location: CGPoint, size: CGSize) -> KMPSelection? {
        var best: (KMPSelection, CGFloat)?
        for link in links() where link.owner != nil {
            let a = worldToScreen(link.from.x, link.from.y, size: size)
            let b = worldToScreen(link.to.x, link.to.y, size: size)
            let d = distanceToSegment(location, a, b)
            if d < 7, best == nil || d < best!.1 { best = (link.owner!, d) }
        }
        return best?.0
    }

    /// Shortest distance from point `p` to the (closed) segment `a`-`b`, in the same pixel space
    /// as the tap, the tap target for a path/route line.
    private func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abx = b.x - a.x, aby = b.y - a.y
        let lenSq = abx * abx + aby * aby
        let t = lenSq > 0 ? max(0, min(1, ((p.x - a.x) * abx + (p.y - a.y) * aby) / lenSq)) : 0
        let cx = a.x + abx * t, cy = a.y + aby * t
        return hypot(p.x - cx, p.y - cy)
    }

    @State private var dragSessionStarted = false
    @State private var lastAppliedDelta: SIMD2<Float> = .zero

    private func movePoint(_ id: KMPSelection, byScreenDelta delta: CGSize, isOrthogonal: Bool = false) {
        // `delta` accumulates from the start of the whole gesture; apply only the increment
        // since the last callback so repeated calls don't compound.
        var worldDelta = screenToWorldDelta(delta)
        if isOrthogonal {
            let absX = abs(worldDelta.x)
            let absY = abs(worldDelta.y)
            if absX > absY * 2 {
                worldDelta.y = 0
            } else if absY > absX * 2 {
                worldDelta.x = 0
            } else {
                let avg = (absX + absY) / 2
                worldDelta.x = avg * (worldDelta.x < 0 ? -1 : 1)
                worldDelta.y = avg * (worldDelta.y < 0 ? -1 : 1)
            }
        }
        let dx = worldDelta.x - lastAppliedDelta.x, dz = worldDelta.y - lastAppliedDelta.y
        if multiSelection.count > 1, multiSelection.contains(id.asPoint) {
            for member in multiSelection { applyDelta(member, dx: dx, dz: dz) }
        } else {
            applyDelta(id, dx: dx, dz: dz)
        }
        lastAppliedDelta = worldDelta
    }
    
    private func rotatePoint(_ id: KMPSelection, toScreenLocation loc: CGPoint, size: CGSize) {
        let pt = points().first(where: { $0.id == id })
        guard let pt = pt else { return }
        let centerScreen = worldToScreen(pt.x, pt.z, size: size)
        
        // MKWii Z is typically down in screen coordinates (forward in 3D is +Z)
        let dx = loc.x - centerScreen.x
        let dz = loc.y - centerScreen.y // +y on screen maps to +Z in world
        
        let angle = atan2(dx, dz) * 180 / .pi
        applyRotation(id, yaw: Float(angle))
    }

    private func applyRotation(_ id: KMPSelection, yaw: Float) {
        switch id {
        case .ktpt(let i): guard box.doc.ktpt.indices.contains(i) else { return }; box.doc.ktpt[i].rotation.y = yaw
        case .ckpt(let i), .ckptLeft(let i), .ckptRight(let i):
            guard box.doc.ckpt.indices.contains(i) else { return }
            let left = box.doc.ckpt[i].left
            let right = box.doc.ckpt[i].right
            let mx = (left.x + right.x) / 2
            let mz = (left.y + right.y) / 2
            let halfWidth = hypot(right.x - left.x, right.y - left.y) / 2
            
            let rad = Float(yaw) * .pi / 180.0
            let dx = cos(rad) * halfWidth
            let dz = -sin(rad) * halfWidth
            
            box.doc.ckpt[i].left = Vec2(x: mx + dx, y: mz + dz)
            box.doc.ckpt[i].right = Vec2(x: mx - dx, y: mz - dz)
        case .gobj(let i): guard box.doc.gobj.indices.contains(i) else { return }; box.doc.gobj[i].rotation.y = yaw
        case .jgpt(let i): guard box.doc.jgpt.indices.contains(i) else { return }; box.doc.jgpt[i].rotation.y = yaw
        case .cnpt(let i): guard box.doc.cnpt.indices.contains(i) else { return }; box.doc.cnpt[i].effectVector.y = yaw
        case .mspt(let i): guard box.doc.mspt.indices.contains(i) else { return }; box.doc.mspt[i].rotation.y = yaw
        case .area(let i): guard box.doc.area.indices.contains(i) else { return }; box.doc.area[i].rotation.y = yaw
        case .came(let i): guard box.doc.came.indices.contains(i) else { return }; box.doc.came[i].rotation.y = yaw
        default: break
        }
        box.objectWillChange.send()
    }

    private func position(for id: KMPSelection) -> SIMD2<Float>? {
        switch id {
        case .ktpt(let i): return box.doc.ktpt.indices.contains(i) ? SIMD2<Float>(box.doc.ktpt[i].position.x, box.doc.ktpt[i].position.z) : nil
        case .enpt(let i), .enptLeft(let i), .enptRight(let i): return box.doc.enpt.indices.contains(i) ? SIMD2<Float>(box.doc.enpt[i].position.x, box.doc.enpt[i].position.z) : nil
        case .itpt(let i), .itptLeft(let i), .itptRight(let i): return box.doc.itpt.indices.contains(i) ? SIMD2<Float>(box.doc.itpt[i].position.x, box.doc.itpt[i].position.z) : nil
        case .ckpt(let i), .ckptLeft(let i), .ckptRight(let i):
            guard box.doc.ckpt.indices.contains(i) else { return nil }
            let orig = box.doc.ckpt[i]
            return SIMD2<Float>((orig.left.x + orig.right.x) / 2, (orig.left.y + orig.right.y) / 2)
        case .gobj(let i): return box.doc.gobj.indices.contains(i) ? SIMD2<Float>(box.doc.gobj[i].position.x, box.doc.gobj[i].position.z) : nil
        case .jgpt(let i): return box.doc.jgpt.indices.contains(i) ? SIMD2<Float>(box.doc.jgpt[i].position.x, box.doc.jgpt[i].position.z) : nil
        case .cnpt(let i): return box.doc.cnpt.indices.contains(i) ? SIMD2<Float>(box.doc.cnpt[i].position.x, box.doc.cnpt[i].position.z) : nil
        case .mspt(let i): return box.doc.mspt.indices.contains(i) ? SIMD2<Float>(box.doc.mspt[i].position.x, box.doc.mspt[i].position.z) : nil
        case .area(let i): return box.doc.area.indices.contains(i) ? SIMD2<Float>(box.doc.area[i].position.x, box.doc.area[i].position.z) : nil
        case .came(let i): return box.doc.came.indices.contains(i) ? SIMD2<Float>(box.doc.came[i].position.x, box.doc.came[i].position.z) : nil
        case .poti(let route, let point):
            guard let point, box.doc.poti.indices.contains(route), box.doc.poti[route].points.indices.contains(point) else { return nil }
            let p = box.doc.poti[route].points[point].position
            return SIMD2<Float>(p.x, p.z)
        default: return nil
        }
    }

    private func straightenMultiSelection() {
        guard Set(multiSelection.map(\.asPoint)).count > 1 else { return }
        box.doc.straighten(multiSelection)
        box.isDirty = true
        box.objectWillChange.send()
        pushHistory("Straighten Selected Points")
    }

    private func equaliseMultiSelection() {
        guard Set(multiSelection.map(\.asPoint)).count > 2 else { return }
        box.doc.equaliseGaps(multiSelection)
        box.isDirty = true
        box.objectWillChange.send()
        pushHistory("Equalise Selected Gaps")
    }

    /// Whether the current multi-selection contains any point whose *width* is editable at all --
    /// the "Wider/Narrower" controls only make sense when they can change something. Enemy/Item
    /// points have a Radius; Checkpoints have a gate whose two endpoints span a width.
    /// What the width slider scales: the multi-selection, else every point of the path group
    /// selected in the inspector.
    private var widthTargets: Set<KMPSelection> {
        if !multiSelection.isEmpty { return Set(multiSelection.map(\.asPoint)) }
        func members(_ groups: [PathLinkEntry], _ g: Int, _ make: (Int) -> KMPSelection) -> Set<KMPSelection> {
            guard groups.indices.contains(g) else { return [] }
            let start = Int(groups[g].startIndex)
            return Set((start..<start + Int(groups[g].pointCount)).map(make))
        }
        switch box.selection {
        case .enph(let g)?: return members(box.doc.enph, g) { .enpt($0) }
        case .itph(let g)?: return members(box.doc.itph, g) { .itpt($0) }
        case .ckph(let g)?: return members(box.doc.ckph, g) { .ckpt($0) }
        default: return []
        }
    }

    private var multiSelectionContainsWidth: Bool {
        widthTargets.contains { id in
            switch id {
            case .enpt, .itpt, .ckpt: return true
            default: return false
            }
        }
    }

    /// Expands or shrinks every selected width-bearing point at once by `factor`. Enemy/Item
    /// Point radius, or a Checkpoint gate scaled about its own centre so it grows/shrinks across
    /// the road without moving. Works across a marquee of any mix of those sections (tunnel-edge
    /// handles collapse to their point via `asPoint`). Does not push undo history itself, the
    /// slider calls this on every drag tick and pushes one history entry when the drag ends,
    /// same pattern as a canvas point drag (see `dragGesture`'s `onEnded`).
    private func scaleMultiSelectionWidth(by factor: Float) {
        guard factor > 0 else { return }
        let ids = widthTargets
        var changed = 0
        for id in ids {
            switch id {
            case .enpt(let i):
                guard box.doc.enpt.indices.contains(i) else { continue }
                box.doc.enpt[i].radius = max(0, box.doc.enpt[i].radius * factor); changed += 1
            case .itpt(let i):
                guard box.doc.itpt.indices.contains(i) else { continue }
                box.doc.itpt[i].radius = max(0, box.doc.itpt[i].radius * factor); changed += 1
            case .ckpt(let i):
                guard box.doc.ckpt.indices.contains(i) else { continue }
                let c = box.doc.ckpt[i]
                let cx = (c.left.x + c.right.x) / 2, cy = (c.left.y + c.right.y) / 2
                box.doc.ckpt[i].left = Vec2(x: cx + (c.left.x - cx) * factor, y: cy + (c.left.y - cy) * factor)
                box.doc.ckpt[i].right = Vec2(x: cx + (c.right.x - cx) * factor, y: cy + (c.right.y - cy) * factor)
                changed += 1
            default: continue
            }
        }
        guard changed > 0 else { return }
        box.isDirty = true
        box.objectWillChange.send()
    }

    /// The width-scale slider, shown only in the inspector's multi-selection block (not the
    /// marquee strip in the main canvas view, a bulk numeric control like this belongs with the
    /// rest of the selection's properties, not floating over the canvas). Hidden when nothing
    /// selected has an adjustable width (Enemy/Item Point radius or a Checkpoint gate). Centred at
    /// 1x every time a drag starts so it can be dragged repeatedly, each tick scales by the
    /// ratio from the previous tick, and one undo step is pushed when the drag ends.
    @ViewBuilder
    private func widthScaleControls() -> some View {
        if multiSelectionContainsWidth {
            VStack(spacing: 2) {
                Text("Width ×\(widthScaleFactor, specifier: "%.2f")").font(.caption).bold()
                Slider(value: Binding(
                    get: { widthScaleFactor },
                    set: { newValue in
                        scaleMultiSelectionWidth(by: Float(newValue / max(widthScaleFactor, 0.01)))
                        widthScaleFactor = newValue
                    }
                ), in: 0.1...3, onEditingChanged: { editing in
                    if !editing {
                        pushHistory(multiSelection.isEmpty ? "Scale Path Width" : "Scale Selected Widths")
                        widthScaleFactor = 1
                    }
                })
                .frame(width: 140)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .help("Drag to scale every selected point's (or the selected path's points') width live: Enemy/Item point Radius, or Checkpoint gate length.")
        }
    }

    private func applyDelta(_ id: KMPSelection, dx: Float, dz: Float) {
        switch id {
        case .ktpt(let i): guard box.doc.ktpt.indices.contains(i) else { return }; box.doc.ktpt[i].position.x += dx; box.doc.ktpt[i].position.z += dz
        case .enpt(let i): guard box.doc.enpt.indices.contains(i) else { return }; box.doc.enpt[i].position.x += dx; box.doc.enpt[i].position.z += dz
        case .itpt(let i): guard box.doc.itpt.indices.contains(i) else { return }; box.doc.itpt[i].position.x += dx; box.doc.itpt[i].position.z += dz
        case .enptLeft(let i):
            guard box.doc.enpt.indices.contains(i) else { return }
            box.doc.enpt[i].radius = max(0, box.doc.enpt[i].radius + tunnelRadiusDelta(groups: box.doc.enph, positions: box.doc.enpt.map { SIMD2($0.position.x, $0.position.z) }, at: i, isLeft: true, dx: dx, dz: dz))
        case .enptRight(let i):
            guard box.doc.enpt.indices.contains(i) else { return }
            box.doc.enpt[i].radius = max(0, box.doc.enpt[i].radius + tunnelRadiusDelta(groups: box.doc.enph, positions: box.doc.enpt.map { SIMD2($0.position.x, $0.position.z) }, at: i, isLeft: false, dx: dx, dz: dz))
        case .itptLeft(let i):
            guard box.doc.itpt.indices.contains(i) else { return }
            box.doc.itpt[i].radius = max(0, box.doc.itpt[i].radius + tunnelRadiusDelta(groups: box.doc.itph, positions: box.doc.itpt.map { SIMD2($0.position.x, $0.position.z) }, at: i, isLeft: true, dx: dx, dz: dz))
        case .itptRight(let i):
            guard box.doc.itpt.indices.contains(i) else { return }
            box.doc.itpt[i].radius = max(0, box.doc.itpt[i].radius + tunnelRadiusDelta(groups: box.doc.itph, positions: box.doc.itpt.map { SIMD2($0.position.x, $0.position.z) }, at: i, isLeft: false, dx: dx, dz: dz))
        case .ckpt(let i):
            guard box.doc.ckpt.indices.contains(i) else { return }
            box.doc.ckpt[i].left.x += dx; box.doc.ckpt[i].left.y += dz
            box.doc.ckpt[i].right.x += dx; box.doc.ckpt[i].right.y += dz
        case .ckptLeft(let i):
            guard box.doc.ckpt.indices.contains(i) else { return }
            box.doc.ckpt[i].left.x += dx; box.doc.ckpt[i].left.y += dz
        case .ckptRight(let i):
            guard box.doc.ckpt.indices.contains(i) else { return }
            box.doc.ckpt[i].right.x += dx; box.doc.ckpt[i].right.y += dz
        case .gobj(let i): guard box.doc.gobj.indices.contains(i) else { return }; box.doc.gobj[i].position.x += dx; box.doc.gobj[i].position.z += dz
        case .jgpt(let i): guard box.doc.jgpt.indices.contains(i) else { return }; box.doc.jgpt[i].position.x += dx; box.doc.jgpt[i].position.z += dz
        case .cnpt(let i): guard box.doc.cnpt.indices.contains(i) else { return }; box.doc.cnpt[i].position.x += dx; box.doc.cnpt[i].position.z += dz
        case .mspt(let i): guard box.doc.mspt.indices.contains(i) else { return }; box.doc.mspt[i].position.x += dx; box.doc.mspt[i].position.z += dz
        case .area(let i): guard box.doc.area.indices.contains(i) else { return }; box.doc.area[i].position.x += dx; box.doc.area[i].position.z += dz
        case .came(let i): guard box.doc.came.indices.contains(i) else { return }; box.doc.came[i].position.x += dx; box.doc.came[i].position.z += dz
        case .poti(let route, let point):
            guard let point, box.doc.poti.indices.contains(route), box.doc.poti[route].points.indices.contains(point) else { return }
            box.doc.poti[route].points[point].position.x += dx
            box.doc.poti[route].points[point].position.z += dz
        default: break
        }
        box.objectWillChange.send()
    }

    // MARK: Data -> plottable points/links

    private func points() -> [KMPPoint] {
        var out: [KMPPoint] = []
        if layers.contains("KTPT") {
            for (i, e) in box.doc.ktpt.enumerated() { out.append(KMPPoint(id: .ktpt(i), x: e.position.x, z: e.position.z, color: .green, label: "\(KMPSection.ktpt.displayName) \(i + 1)", arrowAngle: e.rotation.y)) }
        }
        if layers.contains("ENPT/ENPH") {
            let pts = box.doc.enpt.map { SIMD2<Float>($0.position.x, $0.position.z) }
            for (i, e) in box.doc.enpt.enumerated() {
                out.append(KMPPoint(id: .enpt(i), x: e.position.x, z: e.position.z, color: .orange, label: "\(KMPSection.enpt.displayName) \(i + 1)"))
                let t = tunnelEdges(box.doc.enph, points: pts, radius: e.radius, at: i)
                out.append(KMPPoint(id: .enptLeft(i), x: t.left.x, z: t.left.y, color: .orange, label: "\(KMPSection.enpt.displayName) \(i + 1) L"))
                out.append(KMPPoint(id: .enptRight(i), x: t.right.x, z: t.right.y, color: .orange, label: "\(KMPSection.enpt.displayName) \(i + 1) R"))
            }
        }
        if layers.contains("ITPT/ITPH") {
            let pts = box.doc.itpt.map { SIMD2<Float>($0.position.x, $0.position.z) }
            for (i, e) in box.doc.itpt.enumerated() {
                out.append(KMPPoint(id: .itpt(i), x: e.position.x, z: e.position.z, color: .purple, label: "\(KMPSection.itpt.displayName) \(i + 1)"))
                let t = tunnelEdges(box.doc.itph, points: pts, radius: e.radius, at: i)
                out.append(KMPPoint(id: .itptLeft(i), x: t.left.x, z: t.left.y, color: .purple, label: "\(KMPSection.itpt.displayName) \(i + 1) L"))
                out.append(KMPPoint(id: .itptRight(i), x: t.right.x, z: t.right.y, color: .purple, label: "\(KMPSection.itpt.displayName) \(i + 1) R"))
            }
        }
        if layers.contains("CKPT/CKPH") {
            for (i, e) in box.doc.ckpt.enumerated() {
                let mx = (e.left.x + e.right.x) / 2, mz = (e.left.y + e.right.y) / 2
                // Calculate direction. The checkpoint vector points from left to right.
                // The forward direction (yaw) in MKWii coordinates (where 0 is +Z, 90 is +X):
                let dx = e.right.x - e.left.x
                let dz = e.right.y - e.left.y
                let angle = atan2(dz, -dx) * 180 / .pi
                let color = ckptColor(e, i)

                out.append(KMPPoint(id: .ckpt(i), x: mx, z: mz, color: color, label: "\(KMPSection.ckpt.displayName) \(i + 1)", arrowAngle: Float(angle)))
                out.append(KMPPoint(id: .ckptLeft(i), x: e.left.x, z: e.left.y, color: color, label: "\(KMPSection.ckpt.displayName) \(i + 1) L"))
                out.append(KMPPoint(id: .ckptRight(i), x: e.right.x, z: e.right.y, color: color, label: "\(KMPSection.ckpt.displayName) \(i + 1) R"))
            }
        }
        if layers.contains("GOBJ") {
            for (i, e) in box.doc.gobj.enumerated() { out.append(KMPPoint(id: .gobj(i), x: e.position.x, z: e.position.z, color: .yellow, label: "\(box.doc.objectName(e.objectID)) \(i + 1)", arrowAngle: e.rotation.y)) }
        }
        if layers.contains("JGPT") {
            for (i, e) in box.doc.jgpt.enumerated() { out.append(KMPPoint(id: .jgpt(i), x: e.position.x, z: e.position.z, color: .mint, label: "\(KMPSection.jgpt.displayName) \(i + 1)", arrowAngle: e.rotation.y)) }
        }
        if layers.contains("CNPT") {
            for (i, e) in box.doc.cnpt.enumerated() { out.append(KMPPoint(id: .cnpt(i), x: e.position.x, z: e.position.z, color: .pink, label: "\(KMPSection.cnpt.displayName) \(i + 1)", arrowAngle: e.effectVector.y)) }
        }
        if layers.contains("MSPT") {
            for (i, e) in box.doc.mspt.enumerated() { out.append(KMPPoint(id: .mspt(i), x: e.position.x, z: e.position.z, color: .indigo, label: "\(KMPSection.mspt.displayName) \(i + 1)", arrowAngle: e.rotation.y)) }
        }
        if layers.contains("AREA") {
            for (i, e) in box.doc.area.enumerated() { out.append(KMPPoint(id: .area(i), x: e.position.x, z: e.position.z, color: .red, label: "\(KMPSection.area.displayName) \(i + 1)", arrowAngle: e.rotation.y)) }
        }
        if layers.contains("CAME") {
            for (i, e) in box.doc.came.enumerated() { out.append(KMPPoint(id: .came(i), x: e.position.x, z: e.position.z, color: .blue, label: "\(KMPSection.came.displayName) \(i + 1)", arrowAngle: e.rotation.y)) }
        }
        if layers.contains("POTI") {
            for (r, route) in box.doc.poti.enumerated() {
                for (p, pt) in route.points.enumerated() {
                    out.append(KMPPoint(id: .poti(route: r, point: p), x: pt.position.x, z: pt.position.z, color: .teal, label: "\(KMPSection.poti.displayName) \(r + 1) Point \(p + 1)"))
                }
            }
        }
        return out
    }

    private func links() -> [KMPLink] {
        var out: [KMPLink] = []
        if layers.contains("ENPT/ENPH") {
            let pts = box.doc.enpt.map { SIMD2<Float>($0.position.x, $0.position.z) }
            out += pathLinks(box.doc.enph, points: pts, color: .orange) { .enph($0) }
            out += tunnelLinks(box.doc.enph, points: pts, radii: box.doc.enpt.map(\.radius), color: .orange) { .enph($0) }
        }
        if layers.contains("ITPT/ITPH") {
            let pts = box.doc.itpt.map { SIMD2<Float>($0.position.x, $0.position.z) }
            out += pathLinks(box.doc.itph, points: pts, color: .purple) { .itph($0) }
            out += tunnelLinks(box.doc.itph, points: pts, radii: box.doc.itpt.map(\.radius), color: .purple) { .itph($0) }
        }
        if layers.contains("CKPT/CKPH") {
            for (i, e) in box.doc.ckpt.enumerated() {
                out.append(KMPLink(from: SIMD2(e.left.x, e.left.y), to: SIMD2(e.right.x, e.right.y), color: ckptColor(e, i), owner: .ckpt(i)))
            }
            // Connects consecutive gates in CKPH order along their own two endpoints, a Left rail
            // and a Right rail, same as the quadrilateral each pair of gates already forms (see
            // `checkpointFields`'s doc comment), rather than a single line through the gates'
            // midpoints, which drew a path no gate edge actually follows.
            for (g, group) in box.doc.ckph.enumerated() {
                let start = Int(group.startIndex), count = Int(group.pointCount)
                guard count > 1 else { continue }
                for i in start..<(start + count - 1) {
                    guard box.doc.ckpt.indices.contains(i), box.doc.ckpt.indices.contains(i + 1) else { continue }
                    let a = box.doc.ckpt[i], b = box.doc.ckpt[i + 1]
                    let color = ckptColor(a, i)
                    out.append(KMPLink(from: SIMD2(a.left.x, a.left.y), to: SIMD2(b.left.x, b.left.y), color: color, owner: .ckph(g)))
                    out.append(KMPLink(from: SIMD2(a.right.x, a.right.y), to: SIMD2(b.right.x, b.right.y), color: color, owner: .ckph(g)))
                }
            }
            // A group's last gate also forms a quad with the first gate of each next group --
            // drawn faded, so the hand-over between groups (where branches split and rejoin) shows.
            for (g, group) in box.doc.ckph.enumerated() where group.pointCount > 0 {
                let last = Int(group.startIndex) + Int(group.pointCount) - 1
                guard box.doc.ckpt.indices.contains(last) else { continue }
                let a = box.doc.ckpt[last]
                for n in group.nextGroups where n != 0xFF && Int(n) < box.doc.ckph.count {
                    let first = Int(box.doc.ckph[Int(n)].startIndex)
                    guard box.doc.ckpt.indices.contains(first) else { continue }
                    let b = box.doc.ckpt[first], color = ckptColor(a, last).opacity(0.5)
                    out.append(KMPLink(from: SIMD2(a.left.x, a.left.y), to: SIMD2(b.left.x, b.left.y), color: color, owner: .ckph(g)))
                    out.append(KMPLink(from: SIMD2(a.right.x, a.right.y), to: SIMD2(b.right.x, b.right.y), color: color, owner: .ckph(g)))
                }
            }
        }
        if layers.contains("POTI") {
            for (r, route) in box.doc.poti.enumerated() {
                let pts = route.points.map { SIMD2<Float>($0.position.x, $0.position.z) }
                guard pts.count > 1 else { continue }
                for i in 0..<(pts.count - 1) { out.append(KMPLink(from: pts[i], to: pts[i + 1], color: .teal, owner: .poti(route: r, point: nil))) }
                if route.isCyclic { out.append(KMPLink(from: pts[pts.count - 1], to: pts[0], color: .teal, owner: .poti(route: r, point: nil))) }
            }
        }
        return out
    }

    private func pathLinks(_ groups: [PathLinkEntry], points: [SIMD2<Float>], color: Color, groupID: (Int) -> KMPSelection) -> [KMPLink] {
        var out: [KMPLink] = []
        for (g, group) in groups.enumerated() {
            let start = Int(group.startIndex), count = Int(group.pointCount)
            guard count > 1 else { continue }
            for i in start..<(start + count - 1) {
                guard points.indices.contains(i), points.indices.contains(i + 1) else { continue }
                out.append(KMPLink(from: points[i], to: points[i + 1], color: color, owner: groupID(g)))
            }
        }
        return out
    }

    /// One color per checkpoint type, so the Finish Line, key checkpoints (used for shortcut
    /// detection/minimap %), and ordinary gates read apart at a glance, previously every CKPT
    /// drew the same cyan regardless of what it actually did.
    private func ckptColor(_ e: CKPTEntry, _ index: Int) -> Color {
        if flaggedCheckpoints.contains(index) { return .red }
        if e.lapCounterType == 0 { return .green }
        if e.lapCounterType > 0 { return .cyan }
        return .gray
    }

    // MARK: Enemy/Item tunnel ("2 points per point")
    //
    // The KMP format stores each ENPT/ITPT point as a single position + radius. Editing-wise
    // they're shown as a tunnel instead: every point gets two derived edge handles (left/right)
    // sitting `radius` away from it along the local path normal, so the stored radius is exactly
    // half the distance between the two handles. Dragging either handle only changes the radius
    // (the centre and the path's orientation stay put, see `applyDelta`); the handles themselves
    // are recomputed from position+radius every frame, which keeps the radius, the two canvased
    // points, and the format on disk always in agreement.

    /// Unit normal across the path at point `i`, perpendicular to travel (toward the next point
    /// in its group, else back from the previous one), matching how `addPoint` orients a new
    /// CKPT's left/right gate. A point with no group (or a group of one) falls back to the same
    /// fixed-X default CKPT uses for a lone gate, so its tunnel runs along X.
    private func tunnelNormal(_ groups: [PathLinkEntry], points pts: [SIMD2<Float>], at i: Int) -> SIMD2<Float> {
        guard pts.indices.contains(i),
              let g = groups.first(where: { Int($0.startIndex) <= i && i < Int($0.startIndex) + Int($0.pointCount) })
        else { return SIMD2<Float>(-1, 0) }
        let start = Int(g.startIndex)
        let end = start + Int(g.pointCount)
        let tangent: SIMD2<Float>
        if i + 1 < end, pts.indices.contains(i + 1) {
            tangent = pts[i + 1] - pts[i]
        } else if i - 1 >= start, pts.indices.contains(i - 1) {
            tangent = pts[i] - pts[i - 1]
        } else {
            return SIMD2<Float>(-1, 0)
        }
        guard (tangent.x * tangent.x + tangent.y * tangent.y).squareRoot() > 0.0001 else { return SIMD2<Float>(-1, 0) }
        let t = vecNormalized(tangent)
        return SIMD2<Float>(t.y, -t.x)
    }

    /// The derived left/right handle positions for the point at index `i`, each `radius` away from
    /// its centre along `tunnelNormal`, so `radius == distance(left, centre) == distance(centre,
    /// right)` by construction, the "2 points per point" definition.
    private func tunnelEdges(_ groups: [PathLinkEntry], points pts: [SIMD2<Float>], radius: Float, at i: Int) -> (center: SIMD2<Float>, left: SIMD2<Float>, right: SIMD2<Float>) {
        guard pts.indices.contains(i) else { return (SIMD2<Float>(0, 0), SIMD2<Float>(0, 0), SIMD2<Float>(0, 0)) }
        let c = pts[i]
        let n = tunnelNormal(groups, points: pts, at: i)
        return (c, c + n * radius, c - n * radius)
    }

    /// The corridor drawn through an ENPT/ITPT path: a gate across each point's two handles (the
    /// same visual language CKPT uses for a checkpoint gate) plus rails joining consecutive
    /// points' left-to-left and right-to-right handles, so the path reads as the width of tunnel
    /// its radius fields describe.
    private func tunnelLinks(_ groups: [PathLinkEntry], points pts: [SIMD2<Float>], radii: [Float], color: Color, groupID: (Int) -> KMPSelection) -> [KMPLink] {
        var out: [KMPLink] = []
        for i in pts.indices where radii.indices.contains(i) {
            let e = tunnelEdges(groups, points: pts, radius: radii[i], at: i)
            // Gate links only belong to a path when their point is inside a group; a lone
            // ungrouped point's tunnel isn't part of any path, so its gate is unowned.
            let owner = groups.firstIndex { Int($0.startIndex) <= i && i < Int($0.startIndex) + Int($0.pointCount) }.map(groupID)
            out.append(KMPLink(from: e.left, to: e.right, color: color, owner: owner))
        }
        for (g, group) in groups.enumerated() {
            let start = Int(group.startIndex)
            let end = start + Int(group.pointCount)
            guard end > start + 1 else { continue }
            for i in start..<(end - 1) {
                guard pts.indices.contains(i), pts.indices.contains(i + 1),
                      radii.indices.contains(i), radii.indices.contains(i + 1) else { continue }
                let a = tunnelEdges(groups, points: pts, radius: radii[i], at: i)
                let b = tunnelEdges(groups, points: pts, radius: radii[i + 1], at: i + 1)
                out.append(KMPLink(from: a.left, to: b.left, color: color, owner: groupID(g)))
                out.append(KMPLink(from: a.right, to: b.right, color: color, owner: groupID(g)))
            }
        }
        return out
    }

    /// How much a tunnel-edge drag should change a point's radius. A left handle lives on the
    /// +normal side of the centre and a right handle on the -normal side, so their outward
    /// directions are opposite, the drag is projected onto the normal so an along-path
    /// (tunnel-parallel) drag barely changes the width, and whichever side is dragged grows the
    /// tunnel by the same amount.
    private func tunnelRadiusDelta(groups: [PathLinkEntry], positions pts: [SIMD2<Float>], at i: Int, isLeft: Bool, dx: Float, dz: Float) -> Float {
        let n = tunnelNormal(groups, points: pts, at: i)
        let alongNormal = n.x * dx + n.y * dz
        return isLeft ? alongNormal : -alongNormal
    }

    // MARK: Inspector

    @ViewBuilder
    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Inspector").font(.headline)
                Spacer()
                if let sel = box.selection, isOrderable(sel) {
                    // Swap with the previous/next point along its path (or route, or respawn list).
                    Button { movePoint(sel, by: -1) } label: { Image(systemName: "chevron.backward") }
                        .buttonStyle(.borderless)
                        .disabled(!box.doc.canMovePoint(sel, by: -1))
                        .help("Move earlier: swap with the previous point in its path, so it's driven before it. Anything that refers to these points keeps pointing at the same ones.")
                    Button { movePoint(sel, by: 1) } label: { Image(systemName: "chevron.forward") }
                        .buttonStyle(.borderless)
                        .disabled(!box.doc.canMovePoint(sel, by: 1))
                        .help("Move later: swap with the next point in its path.")
                }
                if let sel = box.selection, box.doc.canInsertPoint(after: sel) {
                    Button { insertPoint(after: sel) } label: { Image(systemName: "plus.circle") }
                        .buttonStyle(.borderless)
                        .help("Insert a point after this one, halfway to the next point in its path, with the same settings.")
                }
                if let sel = box.selection {
                    // A tunnel-edge handle snaps/removes as its point: `asPoint` so ground-snapping
                    // an edge still snaps the point itself, while `canRemove` uses the raw handle
                    // (deleting a derived handle makes no sense, so the trash stays disabled).
                    if supportsGroundSnap(sel.asPoint) {
                        Button { snapToGround(sel.asPoint); pushHistory("Snap to Ground") } label: {
                            Image(systemName: "arrow.down.to.line")
                        }
                        .buttonStyle(.borderless)
                        .disabled(collisionMesh == nil)
                        .help(collisionMesh == nil ? "Load a collision (.kcl) file below to enable Snap to Ground" : "Snap Y to the collision mesh below this point (Auto Y)")
                    }
                    Button(role: .destructive) { removeSelectedPoint() } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!canRemove(sel))
                    .help("Remove this point (Delete)")
                }
            }
            .padding([.top, .horizontal])
            .padding(.bottom, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    DisclosureGroup(isExpanded: $isPropertiesExpanded) {
                        if !multiSelection.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("\(multiSelection.count) points selected").font(.headline)
                                
                                Button("Straighten") {
                                    straightenMultiSelection()
                                }
                                .help("Aligns all selected points to a single horizontal or vertical line.")
                                
                                Button("Equalise Gaps") {
                                    equaliseMultiSelection()
                                }
                                .help("Spaces the selected points out evenly between the two furthest points.")

                                Button("Separate to New Group") { separateMultiSelection() }
                                    .disabled(!canSeparate)
                                    .help("Moves the selected enemy points, item points or checkpoints (all one kind) into a new path group.")
                                
                                widthScaleControls()
                            }
                        } else if let sel = box.selection {
                            KMPInspectorFields(box: box, selection: sel, onCommit: { pushHistory("Edit Point") }, installObjectFiles: installObjectFiles)
                            widthScaleControls() // a path group: scales its points
                        } else {
                            Text("Select a point on the canvas, or use the + menu on the canvas to add one.").foregroundStyle(.secondary)
                        }
                    } label: {
                        Text("Properties").font(.headline)
                    }
                    .padding(.horizontal)
                    
                    Divider()
                    
                    DisclosureGroup(isExpanded: $isStageInfoExpanded) {
                        KMPStageInfoFields(box: box, onCommit: { pushHistory("Edit Stage Info") })
                    } label: {
                        Text("Stage Info").font(.headline)
                            .help("Track-wide settings (STGI): lap count, start grid, lens flare and speed.")
                    }
                    .padding(.horizontal)

                    Divider()

                    DisclosureGroup(isExpanded: $isSectionsExpanded) {
                        VStack(alignment: .leading, spacing: 6) {
                            sectionSummary(.ktpt, box.doc.ktpt.count)
                            pathSummary(.enph, points: .enpt, groups: box.doc.enph)
                            pathSummary(.itph, points: .itpt, groups: box.doc.itph)
                            pathSummary(.ckph, points: .ckpt, groups: box.doc.ckph)
                            sectionSummary(.gobj, box.doc.gobj.count)
                            sectionSummary(.poti, box.doc.poti.count)
                            sectionSummary(.area, box.doc.area.count)
                            sectionSummary(.came, box.doc.came.count)
                            sectionSummary(.jgpt, box.doc.jgpt.count)
                            sectionSummary(.cnpt, box.doc.cnpt.count)
                            sectionSummary(.mspt, box.doc.mspt.count)
                        }
                    } label: {
                        Text("Sections").font(.headline)
                    }
                    .onChange(of: box.selection) { _, sel in if let sel { outlineOpen.formUnion(outlineKeys(for: sel)) } }
                    .padding(.horizontal)

                    if !box.doc.enph.isEmpty || !box.doc.itph.isEmpty || !box.doc.ckph.isEmpty {
                        Divider()
                        DisclosureGroup(isExpanded: $isPathsExpanded) {
                            VStack(alignment: .leading, spacing: 10) {
                            pathsList("Enemy Paths", section: .enph, groups: box.doc.enph) { index, direction in
                                moveGroup(&box.doc.enph, from: index, direction: direction)
                                pushHistory("Reorder Enemy Path")
                            } delete: { index in
                                deleteGroup(groups: &box.doc.enph, points: &box.doc.enpt, index: index)
                                pushHistory("Delete Enemy Path")
                            } duplicate: { index, to in
                                duplicatePath(from: .enph, groupIndex: index, to: to)
                            }
                            pathsList("Item Paths", section: .itph, groups: box.doc.itph) { index, direction in
                                moveGroup(&box.doc.itph, from: index, direction: direction)
                                pushHistory("Reorder Item Path")
                            } delete: { index in
                                deleteGroup(groups: &box.doc.itph, points: &box.doc.itpt, index: index)
                                pushHistory("Delete Item Path")
                            } duplicate: { index, to in
                                duplicatePath(from: .itph, groupIndex: index, to: to)
                            }
                            pathsList("Checkpoint Paths", section: .ckph, groups: box.doc.ckph) { index, direction in
                                moveGroup(&box.doc.ckph, from: index, direction: direction)
                                pushHistory("Reorder Checkpoint Path")
                            } delete: { index in
                                deleteGroup(groups: &box.doc.ckph, points: &box.doc.ckpt, index: index)
                                pushHistory("Delete Checkpoint Path")
                            } duplicate: { index, to in
                                duplicatePath(from: .ckph, groupIndex: index, to: to)
                            }
                        }
                        } label: {
                            Text("Paths").font(.headline)
                                .help("Every separate Enemy/Item/Checkpoint path on this track (a fork or shortcut needs more than one). Reorder with the arrows, their order doesn't change where any point is, only which path is \"first\"; use New Enemy/Item/Checkpoint Path (the canvas' + menu) to start another one.")
                        }
                        .padding(.horizontal)
                    }

                    if !box.doc.poti.isEmpty {
                        Divider()
                        DisclosureGroup(isExpanded: $isRoutesExpanded) {
                            routesList()
                        } label: {
                            Text("Routes").font(.headline)
                                .help("Every Route (POTI) on this track, a path some Objects/Cameras/Areas follow. Use New Route (the canvas' + menu) to add one, tap a route below to select it, then Add Point in its Properties to build it out.")
                        }
                        .padding(.horizontal)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 12)
            }
        }
    }

    /// The section's entries as selectable rows (the outliner), in file order.
    private func sectionItems(_ section: KMPSection) -> [(KMPSelection, String)] {
        let d = box.doc
        func rows(_ n: Int, _ make: (Int) -> KMPSelection, _ name: (Int) -> String = { "\(section.displayName) \($0 + 1)" }) -> [(KMPSelection, String)] {
            (0..<n).map { (make($0), name($0)) }
        }
        switch section {
        case .ktpt: return rows(d.ktpt.count) { .ktpt($0) }
        case .enpt: return rows(d.enpt.count) { .enpt($0) }
        case .enph: return rows(d.enph.count) { .enph($0) }
        case .itpt: return rows(d.itpt.count) { .itpt($0) }
        case .itph: return rows(d.itph.count) { .itph($0) }
        case .ckpt: return rows(d.ckpt.count) { .ckpt($0) }
        case .ckph: return rows(d.ckph.count) { .ckph($0) }
        case .gobj: return rows(d.gobj.count, { .gobj($0) }) { "\(d.objectName(d.gobj[$0].objectID)) \($0 + 1)" }
        case .poti: return rows(d.poti.count) { .poti(route: $0, point: nil) }
        case .area: return rows(d.area.count) { .area($0) }
        case .came: return rows(d.came.count) { .came($0) }
        case .jgpt: return rows(d.jgpt.count) { .jgpt($0) }
        case .cnpt: return rows(d.cnpt.count) { .cnpt($0) }
        case .mspt: return rows(d.mspt.count) { .mspt($0) }
        default: return []
        }
    }

    private func outlineBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { outlineOpen.contains(key) }, set: { if $0 { outlineOpen.insert(key) } else { outlineOpen.remove(key) } })
    }

    /// The outliner rows that must be open to show `sel`.
    private func outlineKeys(for sel: KMPSelection) -> [String] {
        func path(_ section: KMPSection, _ groups: [PathLinkEntry], _ i: Int) -> [String] {
            let g = groups.firstIndex { i >= Int($0.startIndex) && i < Int($0.startIndex) + Int($0.pointCount) }
            return [section.magic] + (g.map { ["\(section.magic)#\($0)"] } ?? [])
        }
        switch sel.asPoint {
        case .ktpt: return ["KTPT"]
        case .enpt(let i): return path(.enph, box.doc.enph, i)
        case .itpt(let i): return path(.itph, box.doc.itph, i)
        case .ckpt(let i), .ckptLeft(let i), .ckptRight(let i): return path(.ckph, box.doc.ckph, i)
        case .enph: return ["ENPH"]
        case .itph: return ["ITPH"]
        case .ckph: return ["CKPH"]
        case .gobj: return ["GOBJ"]
        case .poti: return ["POTI"]
        case .area: return ["AREA"]
        case .came: return ["CAME"]
        case .jgpt: return ["JGPT"]
        case .cnpt: return ["CNPT"]
        case .mspt: return ["MSPT"]
        default: return []
        }
    }

    private func outlineRow(_ sel: KMPSelection, _ name: String) -> some View {
        Button { box.selection = sel; multiSelection = [] } label: {
            Text(name).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2).padding(.horizontal, 6)
                .background(box.selection == sel ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(sel)
    }

    private func newRow(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Text("New").font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 6).padding(.vertical, 2) }
            .buttonStyle(.plain)
    }

    private func sectionLabel(_ section: KMPSection, _ count: Int) -> some View {
        HStack { Text(section.displayName); Spacer(); Text("\(count)").foregroundStyle(.secondary) }
            .font(.caption)
            .help("\(section.magic). \(section.tooltip)")
    }

    /// One Sections row: the count, expanding to every entry (the outliner) with a New row at the end.
    private func sectionSummary(_ section: KMPSection, _ count: Int) -> some View {
        DisclosureGroup(isExpanded: outlineBinding(section.magic)) {
            ScrollViewReader { proxy in ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sectionItems(section), id: \.0) { sel, name in outlineRow(sel, name) }
                    if section == .poti {
                        newRow { newRoute(at: viewCenterWorld(size: canvasSize)) }
                    } else {
                        newRow { addPointWithHistory(section, at: viewCenterWorld(size: canvasSize)) }
                    }
                }
            }
            .onChange(of: box.selection) { _, sel in if let sel { withAnimation { proxy.scrollTo(sel) } } }
            .onAppear { if let sel = box.selection { proxy.scrollTo(sel) } } }
            .frame(maxHeight: 200)
        } label: { sectionLabel(section, count) }
    }

    /// An Enemy/Item/Checkpoint path row: its groups, each expanding to its points.
    private func pathSummary(_ section: KMPSection, points: KMPSection, groups: [PathLinkEntry]) -> some View {
        DisclosureGroup(isExpanded: outlineBinding(section.magic)) {
            ScrollViewReader { proxy in ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { g, group in
                        DisclosureGroup(isExpanded: outlineBinding("\(section.magic)#\(g)")) {
                            ForEach(Int(group.startIndex)..<Int(group.startIndex) + Int(group.pointCount), id: \.self) { i in
                                outlineRow(pathPointSelection(points, i), "\(points.displayName) \(i - Int(group.startIndex))")
                            }
                            // New points always extend the last group.
                            if g == groups.count - 1 { newRow { addPointWithHistory(points, at: viewCenterWorld(size: canvasSize)) } }
                        } label: { outlineRow(pathGroupSelection(section, g) ?? .stgi, "Group \(g)") }
                    }
                    newRow { newPathOf(section) }
                }
            }
            .onChange(of: box.selection) { _, sel in if let sel { withAnimation { proxy.scrollTo(sel.asPoint) } } }
            .onAppear { if let sel = box.selection { proxy.scrollTo(sel.asPoint) } } }
            .frame(maxHeight: 240)
        } label: { sectionLabel(section, groups.count) }
    }

    private func pathPointSelection(_ points: KMPSection, _ i: Int) -> KMPSelection {
        switch points { case .enpt: .enpt(i); case .itpt: .itpt(i); default: .ckpt(i) }
    }

    private func newPathOf(_ section: KMPSection) {
        switch section {
        case .enph: newPath(&box.doc.enph, arrayCount: box.doc.enpt.count); pushHistory("New Enemy Path")
        case .itph: newPath(&box.doc.itph, arrayCount: box.doc.itpt.count); pushHistory("New Item Path")
        default: newPath(&box.doc.ckph, arrayCount: box.doc.ckpt.count); pushHistory("New Checkpoint Path")
        }
    }

    /// One reorderable list of path groups (see the "Paths" inspector section), `move` is handed
    /// the tapped row's index and `-1`/`1` for up/down, matching `moveGroup`'s own convention.
    @ViewBuilder
    private func pathsList(_ title: String, section: KMPSection, groups: [PathLinkEntry], move: @escaping (Int, Int) -> Void, delete: @escaping (Int) -> Void, duplicate: @escaping (Int, KMPSection) -> Void) -> some View {
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.bold())
                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                    HStack {
                        Button {
                            box.selection = pathGroupSelection(section, index)
                        } label: {
                            Text("\(section.displayName) \(index + 1)")
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Text("\(group.pointCount) pt\(group.pointCount == 1 ? "" : "s")").foregroundStyle(.secondary)
                        
                        Menu {
                            if section != .enph { Button("Duplicate to Enemy Path") { duplicate(index, .enph) } }
                            if section != .itph { Button("Duplicate to Item Path") { duplicate(index, .itph) } }
                            if section != .ckph { Button("Duplicate to Checkpoint Path") { duplicate(index, .ckph) } }
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .help("Duplicate this path to another type")
                        
                        Button { move(index, -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.plain).disabled(index == 0)
                            .help("Move this path earlier in the sequence")
                        Button { move(index, 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.plain).disabled(index == groups.count - 1)
                            .help("Move this path later in the sequence")
                        Button { delete(index) } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain).foregroundStyle(.red)
                            .help("Delete this path and all its points")
                    }
                    .font(.caption)
                }
            }
        }
    }

    /// One row per Route (POTI), tapping a row selects it (its Properties then let you rename its
    /// Cyclic/Setting 2 fields, add points, or jump to editing a specific point); unlike the
    /// Enemy/Item/Checkpoint `pathsList`, there's no reorder here since nothing links routes to each
    /// other by array position the way path groups' previous/next fields do.
    private func routesList() -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(box.doc.poti.enumerated()), id: \.offset) { index, route in
                HStack {
                    Button {
                        box.selection = .poti(route: index, point: route.points.isEmpty ? nil : 0)
                    } label: {
                        Text("Route \(index + 1) (\(route.points.count) pt\(route.points.count == 1 ? "" : "s")\(route.isCyclic ? ", cyclic" : ""))")
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button { moveRoute(index, by: -1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.plain).disabled(index == 0)
                        .help("Move this route up. Objects, areas and cameras keep following the same route.")
                    Button { moveRoute(index, by: 1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.plain).disabled(index == box.doc.poti.count - 1)
                        .help("Move this route down.")
                    Button {
                        removePotiRoute(at: index)
                        box.selection = nil
                        box.isDirty = true
                        box.objectWillChange.send()
                        pushHistory("Delete Route")
                    } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).foregroundStyle(.red)
                        .help("Delete this route. Any Object/Camera/Area using it is set back to \"None\" instead of being left pointing at the wrong route.")
                }
                .font(.caption)
            }
        }
    }

    /// Maps a `layerList` combined-name (e.g. "ENPT/ENPH") to its plain-English explanation,
    /// using the first section named, both halves of a combined toggle describe the same feature
    /// (points + the paths that link them), so one description covers it.
    fileprivate static func layerTooltip(_ name: String) -> String {
        let first = name.split(separator: "/").first.map(String.init) ?? name
        guard let section = KMPSection.allCases.first(where: { $0.magic == first }) else { return "" }
        return section.tooltip
    }
}

/// Human-readable name for a GOBJ entry, combining its object type name (per the tockdom
/// "List of Objects" for Mario Kart Wii) with the raw ID as a fallback for anything not covered.
/// CAME `type` byte meanings, per the community-documented behavior of each, `needsRoute`
/// drives the inspector's route-required warning; `usage` is the plain-English explanation shown
/// under the type picker.
fileprivate let cameraTypeInfo: [UInt8: (name: String, needsRoute: Bool, usage: String)] = [
    0: ("Goal", false, "The default replay camera shown automatically when a player finishes the race. Every track needs at least one."),
    1: ("Fix / Search", false, "Stays in a fixed position and rotates to track the player, a simple, static replay angle."),
    2: ("Path / Search", true, "Moves along a Route while its view tracks the player. Needs a Route to move along."),
    3: ("Kart Follow", false, "Positioned relative to the player, similar to the normal in-race follow camera."),
    4: ("Kart / Path Follow", false, "Used for opening/replay shots with a shifting viewpoint as the player moves."),
    5: ("Opening: Rides Route", true, "Opening-sequence camera (OP_FixMoveAt): rides its Route while its view pans from Look-At Start to Look-At End. Nintendo's intros are three of these. Edit and preview them with Intro Cameras."),
    6: ("Opening: Player-Relative", true, "Opening-sequence camera (OP_PathMoveAt): rides a Route placed relative to the player, looking at the player."),
    7: ("Mini-Game", false, "Battle/mini-game camera."),
    8: ("Mission Success", false, "Mission-mode success camera (unused in the retail game's normal races)."),
    9: ("Menu", false, "Menu camera."),
]

private func cameraTypeName(_ type: UInt8) -> String {
    cameraTypeInfo[type]?.name ?? "Unknown"
}

// MARK: Pen tool math (world-space X/Z 2D vectors, plain component math, no `simd` import needed)

/// Point at parameter `t` (0...1) along the cubic bezier `p0`-`p1`-`p2`-`p3`.
private func cubicBezierPoint(_ p0: SIMD2<Float>, _ p1: SIMD2<Float>, _ p2: SIMD2<Float>, _ p3: SIMD2<Float>, _ t: Float) -> SIMD2<Float> {
    let u = 1 - t
    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
    return SIMD2<Float>(a * p0.x + b * p1.x + c * p2.x + d * p3.x, a * p0.y + b * p1.y + c * p2.y + d * p3.y)
}

/// Derivative (unnormalized tangent/direction of travel) at parameter `t` along the same curve.
private func cubicBezierTangent(_ p0: SIMD2<Float>, _ p1: SIMD2<Float>, _ p2: SIMD2<Float>, _ p3: SIMD2<Float>, _ t: Float) -> SIMD2<Float> {
    let u = 1 - t
    let a = 3 * u * u, b = 6 * u * t, c = 3 * t * t
    return SIMD2<Float>(a * (p1.x - p0.x) + b * (p2.x - p1.x) + c * (p3.x - p2.x),
                         a * (p1.y - p0.y) + b * (p2.y - p1.y) + c * (p3.y - p2.y))
}

private func vecDistance(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
    let dx = a.x - b.x, dy = a.y - b.y
    return (dx * dx + dy * dy).squareRoot()
}

private func vecMix(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ t: Float) -> SIMD2<Float> {
    SIMD2<Float>(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
}

/// Unit vector in the direction of `v`, or `(1, 0)` for a (near-)zero vector rather than dividing by
/// (near) zero, happens when a pen-tool sample lands exactly on a corner anchor with no handle.
private func vecNormalized(_ v: SIMD2<Float>) -> SIMD2<Float> {
    let length = (v.x * v.x + v.y * v.y).squareRoot()
    guard length > 0.0001 else { return SIMD2<Float>(1, 0) }
    return SIMD2<Float>(v.x / length, v.y / length)
}

/// Editable numeric fields for whichever KMP entry is currently selected, used by both the KMP
/// editor and the 3D track viewer, so every field is edited the same way in each.
struct KMPInspectorFields: View {
    @ObservedObject var box: KMPDocumentBox
    let selection: KMPSelection
    /// Called after every field edit commits, so the owning `KMPEditorView` can record one
    /// history step, per-keystroke granularity is an accepted tradeoff here rather than
    /// threading focus-loss tracking through every field.
    let onCommit: () -> Void
    /// Puts object files into the track (custom objects' models), when the owner can.
    var installObjectFiles: (([(path: [String], data: Data)]) -> Void)? = nil

    /// The enemy path group's first point says "only enter with an off-road item" (setting 1 = 1).
    private func requiresOffroad(_ group: Int) -> Bool {
        guard box.doc.enph.indices.contains(group) else { return false }
        let first = Int(box.doc.enph[group].startIndex)
        return box.doc.enpt.indices.contains(first) && box.doc.enpt[first].setting1 == 1
    }

    /// On: the first point gets setting 1 = 1, and the second "use it here" (2) unless some point
    /// already is. Off: clears both markers from the whole group.
    private func setRequiresOffroad(_ group: Int, _ on: Bool) {
        guard box.doc.enph.indices.contains(group) else { return }
        let g = box.doc.enph[group], first = Int(g.startIndex)
        let members = (first..<first + Int(g.pointCount)).filter(box.doc.enpt.indices.contains)
        guard let head = members.first else { return }
        if on {
            box.doc.enpt[head].setting1 = 1
            if members.count > 1, !members.dropFirst().contains(where: { box.doc.enpt[$0].setting1 == 2 }) { box.doc.enpt[members[1]].setting1 = 2 }
        } else {
            for k in members where [1, 2].contains(box.doc.enpt[k].setting1) { box.doc.enpt[k].setting1 = 0 }
        }
        box.isDirty = true
        box.objectWillChange.send()
        onCommit()
    }

    var body: some View {
        // A tunnel-edge handle (.enptLeft/.enptRight/...) selects the point it belongs to, its
        // L/R handles are derived, so the only thing editing them does is change the radius.
        switch selection.asPoint {
        case .ktpt(let i):
            if box.doc.ktpt.indices.contains(i) {
                VStack(alignment: .leading, spacing: 4) {
                    header(.ktpt, i)
                    vec3Fields("Position", get: { box.doc.ktpt.indices.contains(i) ? box.doc.ktpt[i].position : .init() }, set: { if box.doc.ktpt.indices.contains(i) { box.doc.ktpt[i].position = $0; box.isDirty = true } })
                    vec3Fields("Rotation", get: { box.doc.ktpt.indices.contains(i) ? box.doc.ktpt[i].rotation : .init() }, set: { if box.doc.ktpt.indices.contains(i) { box.doc.ktpt[i].rotation = $0; box.isDirty = true } })
                    intField("Player Index", box.doc.ktpt[i].playerIndex, -1...11) { v in if box.doc.ktpt.indices.contains(i) { box.doc.ktpt[i].playerIndex = Int16(v) } }
                    hint("-1 (every retail race track) = the whole starting grid is laid out from this one point. 0-11 = one start per player, used by battle arenas.")
                }
            }
        case .enpt(let i):
            if box.doc.enpt.indices.contains(i) {
                VStack(alignment: .leading, spacing: 4) {
                    header(.enpt, i)
                    vec3Fields("Position", get: { box.doc.enpt.indices.contains(i) ? box.doc.enpt[i].position : .init() }, set: { if box.doc.enpt.indices.contains(i) { box.doc.enpt[i].position = $0; box.isDirty = true } })
                    floatField("Radius", get: { box.doc.enpt.indices.contains(i) ? box.doc.enpt[i].radius : 0 }, set: { if box.doc.enpt.indices.contains(i) { box.doc.enpt[i].radius = $0; box.isDirty = true } })
                    intField("Setting 1", box.doc.enpt[i].setting1, 0...0xFFFF) { v in if box.doc.enpt.indices.contains(i) { box.doc.enpt[i].setting1 = UInt16(v) } }
                    intField("Setting 2", box.doc.enpt[i].setting2, 0...0xFFFF) { v in if box.doc.enpt.indices.contains(i) { box.doc.enpt[i].setting2 = UInt16(v) } }
                    hint("Half the distance between this point's two tunnel-edge handles (L/R) on the canvas, drag either handle to change it; CPU karts can cut this point that close.")
                    if !box.doc.isBOL, let group = box.doc.enph.firstIndex(where: { i >= Int($0.startIndex) && i < Int($0.startIndex) + Int($0.pointCount) }),
                       requiresOffroad(group), i != Int(box.doc.enph[group].startIndex) {
                        Toggle("Use Mushroom", isOn: Binding(get: { box.doc.enpt.indices.contains(i) && box.doc.enpt[i].setting1 == 2 }, set: { on in
                            guard box.doc.enpt.indices.contains(i) else { return }
                            box.doc.enpt[i].setting1 = on ? 2 : 0
                            box.isDirty = true
                            box.objectWillChange.send()
                            onCommit()
                        }))
                        .font(.caption)
                        hint("CPUs use their mushroom (or other off-road item) at this point (Setting 1 = 2). The path needs Requires Off-Roading on, set on the path itself.")
                    }
                }
            }
        case .itpt(let i):
            if box.doc.itpt.indices.contains(i) {
                VStack(alignment: .leading, spacing: 4) {
                    header(.itpt, i)
                    vec3Fields("Position", get: { box.doc.itpt.indices.contains(i) ? box.doc.itpt[i].position : .init() }, set: { if box.doc.itpt.indices.contains(i) { box.doc.itpt[i].position = $0; box.isDirty = true } })
                    floatField("Radius", get: { box.doc.itpt.indices.contains(i) ? box.doc.itpt[i].radius : 0 }, set: { if box.doc.itpt.indices.contains(i) { box.doc.itpt[i].radius = $0; box.isDirty = true } })
                    intField("Setting 1", box.doc.itpt[i].setting1, 0...0xFFFF) { v in if box.doc.itpt.indices.contains(i) { box.doc.itpt[i].setting1 = UInt16(v) } }
                    intField("Setting 2", box.doc.itpt[i].setting2, 0...0xFFFF) { v in if box.doc.itpt.indices.contains(i) { box.doc.itpt[i].setting2 = UInt16(v) } }
                    hint("Half the distance between this point's two tunnel-edge handles (L/R) on the canvas, drag either handle to change it; where CPUs aim/throw held items.")
                    if !box.doc.isBOL {
                        Toggle("Prevent Bullet Bill Stopping", isOn: Binding(
                            get: { box.doc.itpt.indices.contains(i) && box.doc.itpt[i].setting2 % 10 == 1 },
                            set: { on in
                                guard box.doc.itpt.indices.contains(i) else { return }
                                let s2 = box.doc.itpt[i].setting2
                                box.doc.itpt[i].setting2 = s2 - s2 % 10 + (on ? 1 : 0)
                                box.isDirty = true; box.objectWillChange.send(); onCommit()
                            })).font(.caption)
                        hint("Setting 2's ones digit = 1: a Bullet Bill doesn't drop you here, for item points over an abyss. Other digits (10, 100) are kept.")
                        Toggle("Make Bullet Bill Ignore Height", isOn: Binding(
                            get: { box.doc.itpt.indices.contains(i) && box.doc.itpt[i].setting1 == 1 },
                            set: { on in
                                guard box.doc.itpt.indices.contains(i) else { return }
                                box.doc.itpt[i].setting1 = on ? 1 : 0
                                box.isDirty = true; box.objectWillChange.send(); onCommit()
                            })).font(.caption)
                        hint("Setting 1 = 1: the Bullet Bill follows this route along the ground, ignoring the points' height like a red shell (0 is the default, 2 follows the height too).")
                    }
                }
            }
        case .ckpt(let i):
            if box.doc.ckpt.indices.contains(i) {
                checkpointFields(i)
            }
        case .gobj(let i):
            if box.doc.gobj.indices.contains(i) {
                VStack(alignment: .leading, spacing: 4) {
                    header(.gobj, i)
                    HStack {
                        ObjectTypeMenu(selection: box.doc.gobj[i].objectID, doubleDash: box.doc.isBOL, install: installObjectFiles) { id in
                            guard box.doc.gobj.indices.contains(i) else { return }
                            box.doc.gobj[i].objectID = id
                            box.isDirty = true
                            box.objectWillChange.send()
                            onCommit()
                        }
                        
                        Text("0x")
                        TextField("ID", text: Binding(
                            get: { box.doc.gobj.indices.contains(i) ? String(format: "%04X", box.doc.gobj[i].objectID) : "" },
                            set: { if box.doc.gobj.indices.contains(i), let val = UInt16($0, radix: 16) { box.doc.gobj[i].objectID = val; box.isDirty = true } }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 50)
                    }
                    let oid = box.doc.gobj[i].objectID
                    if box.doc.isBOL {
                        if BOL.objectNames[oid] == nil {
                            warning("\(oid) isn't a known Double Dash object, the game may freeze or crash building it. Pick one from the list.", color: .red)
                        }
                    } else if !isRetailObjectID(oid) {
                        warning("0x\(String(format: "%04X", oid)) isn't a Mario Kart Wii object, the game crashes when a kart gets near it.", color: .red)
                    } else if !retailUsedObjectIDs.contains(oid) {
                        warning("No retail course uses \(gobjDisplayName(oid)), it may not work in-game.")
                    }
                    if !box.doc.isBOL, routeRequiredObjectIDs.contains(oid), box.doc.gobj[i].routeID == 0xFFFF || !box.doc.poti.indices.contains(Int(box.doc.gobj[i].routeID)) {
                        warning("\(gobjDisplayName(oid)) moves along a route and has none, set its Route below, or the game can crash.", color: .red)
                    }
                    vec3Fields("Position", get: { box.doc.gobj.indices.contains(i) ? box.doc.gobj[i].position : .init() }, set: { if box.doc.gobj.indices.contains(i) { box.doc.gobj[i].position = $0; box.isDirty = true } })
                    vec3Fields("Rotation", get: { box.doc.gobj.indices.contains(i) ? box.doc.gobj[i].rotation : .init() }, set: { if box.doc.gobj.indices.contains(i) { box.doc.gobj[i].rotation = $0; box.isDirty = true } })
                    vec3Fields("Scale", get: { box.doc.gobj.indices.contains(i) ? box.doc.gobj[i].scale : .init(x: 1, y: 1, z: 1) }, set: { if box.doc.gobj.indices.contains(i) { box.doc.gobj[i].scale = $0; box.isDirty = true } })
                    
                    routePicker("Route", selection: box.doc.gobj[i].routeID == 0xFFFF ? -1 : Int(box.doc.gobj[i].routeID)) { v in
                        if box.doc.gobj.indices.contains(i) { box.doc.gobj[i].routeID = v < 0 ? 0xFFFF : UInt16(v) }
                    }
                    Divider()
                    let objID = box.doc.gobj[i].objectID
                    Text(objID == 0x0065 || objID == 0x00CE ? "Item Box Settings" : "Object Settings").font(.headline)
                    ForEach(0..<8, id: \.self) { k in
                        intField(Self.gobjSettingLabel(objID, k), box.doc.gobj[i].settings[k], 0...0xFFFF) { v in
                            if box.doc.gobj.indices.contains(i) { box.doc.gobj[i].settings[k] = UInt16(v) }
                        }
                    }
                    hint("What each setting does depends on the object, see its entry in the Mario Kart Wii object list.")
                    Divider()
                    Text("Appears In").font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(["1 player", "2 players", "3-4 players", "Online"].enumerated()), id: \.offset) { bit, name in
                        Toggle(name, isOn: Binding(
                            get: { box.doc.gobj.indices.contains(i) && box.doc.gobj[i].presenceFlags & (1 << bit) != 0 },
                            set: { on in if box.doc.gobj.indices.contains(i) { box.doc.gobj[i].presenceFlags ^= (box.doc.gobj[i].presenceFlags & (1 << bit) != 0) == on ? 0 : UInt16(1 << bit); box.isDirty = true; onCommit() } }
                        )).font(.caption)
                    }
                }
            }
        case .jgpt(let i):
            if box.doc.jgpt.indices.contains(i) {
                VStack(alignment: .leading, spacing: 4) {
                    header(.jgpt, i)
                    vec3Fields("Position", get: { box.doc.jgpt.indices.contains(i) ? box.doc.jgpt[i].position : .init() }, set: { if box.doc.jgpt.indices.contains(i) { box.doc.jgpt[i].position = $0; box.isDirty = true } })
                    vec3Fields("Rotation", get: { box.doc.jgpt.indices.contains(i) ? box.doc.jgpt[i].rotation : .init() }, set: { if box.doc.jgpt.indices.contains(i) { box.doc.jgpt[i].rotation = $0; box.isDirty = true } })
                    intField("Range", box.doc.jgpt[i].extra == 0xFFFF ? -1 : Int(box.doc.jgpt[i].extra), -1...0xFFFE) { v in if box.doc.jgpt.indices.contains(i) { box.doc.jgpt[i].extra = v < 0 ? 0xFFFF : UInt16(v) } }
                    hint("-1 on almost every retail respawn point. Its ID is always its position in the list counting from 0 (\(i)), written automatically, since checkpoints find respawn points by that number.")
                }
            }
        case .cnpt(let i):
            if box.doc.cnpt.indices.contains(i) {
                VStack(alignment: .leading, spacing: 4) {
                    header(.cnpt, i)
                    vec3Fields("Position", get: { box.doc.cnpt.indices.contains(i) ? box.doc.cnpt[i].position : .init() }, set: { if box.doc.cnpt.indices.contains(i) { box.doc.cnpt[i].position = $0; box.isDirty = true } })
                    vec3Fields("Effect Vector", get: { box.doc.cnpt.indices.contains(i) ? box.doc.cnpt[i].effectVector : .init() }, set: { if box.doc.cnpt.indices.contains(i) { box.doc.cnpt[i].effectVector = $0; box.isDirty = true } })
                    hint("Cannon ID \(i), always its position in the list, written automatically. The Cannon Trigger collision that fires it needs variant \(i).")
                    intField("Shoot Effect", Int(Int16(bitPattern: box.doc.cnpt[i].shootEffect)), -1...2) { v in if box.doc.cnpt.indices.contains(i) { box.doc.cnpt[i].shootEffect = UInt16(bitPattern: Int16(v)) } }
                    hint("-1/0 = straight line, 1 = high arc, 2 = low arc.")
                }
            }
        case .mspt(let i):
            if box.doc.mspt.indices.contains(i) {
                VStack(alignment: .leading, spacing: 4) {
                    header(.mspt, i)
                    vec3Fields("Position", get: { box.doc.mspt.indices.contains(i) ? box.doc.mspt[i].position : .init() }, set: { if box.doc.mspt.indices.contains(i) { box.doc.mspt[i].position = $0; box.isDirty = true } })
                    vec3Fields("Rotation", get: { box.doc.mspt.indices.contains(i) ? box.doc.mspt[i].rotation : .init() }, set: { if box.doc.mspt.indices.contains(i) { box.doc.mspt[i].rotation = $0; box.isDirty = true } })
                    hint("Entry ID \(i), always its position in the list, written automatically.")
                    intField("Setting", box.doc.mspt[i].extra, 0...0xFFFF) { v in if box.doc.mspt.indices.contains(i) { box.doc.mspt[i].extra = UInt16(v) } }
                }
            }
        case .area(let i):
            if box.doc.area.indices.contains(i) {
                VStack(alignment: .leading, spacing: 4) {
                    header(.area, i)
                    vec3Fields("Position", get: { box.doc.area.indices.contains(i) ? box.doc.area[i].position : .init() }, set: { if box.doc.area.indices.contains(i) { box.doc.area[i].position = $0; box.isDirty = true } })
                    vec3Fields("Rotation", get: { box.doc.area.indices.contains(i) ? box.doc.area[i].rotation : .init() }, set: { if box.doc.area.indices.contains(i) { box.doc.area[i].rotation = $0; box.isDirty = true } })
                    vec3Fields("Scale", get: { box.doc.area.indices.contains(i) ? box.doc.area[i].scale : .init(x: 1, y: 1, z: 1) }, set: { if box.doc.area.indices.contains(i) { box.doc.area[i].scale = $0; box.isDirty = true } })
                    Picker("Shape", selection: Binding(get: { box.doc.area.indices.contains(i) ? box.doc.area[i].shape : 0 },
                                                       set: { if box.doc.area.indices.contains(i) { box.doc.area[i].shape = $0; box.isDirty = true; onCommit() } })) {
                        Text("Box").tag(UInt8(0)); Text("Cylinder").tag(UInt8(1))
                    }.font(.caption)
                    intField("Type", box.doc.area[i].type, 0...10) { v in if box.doc.area.indices.contains(i) { box.doc.area[i].type = UInt8(v) } }
                    hint(Self.areaTypeNames[box.doc.area[i].type].map { "\($0)." } ?? "Area type \(box.doc.area[i].type).")
                    intField("Camera", box.doc.area[i].cameraIndex == 0xFF ? 0 : Int(box.doc.area[i].cameraIndex) + 1, 0...255) { v in if box.doc.area.indices.contains(i) { box.doc.area[i].cameraIndex = v == 0 ? 0xFF : UInt8(v - 1) } }
                    intField("Priority", box.doc.area[i].priority, 0...255) { v in if box.doc.area.indices.contains(i) { box.doc.area[i].priority = UInt8(v) } }
                    intField("Setting 1", box.doc.area[i].setting1, 0...0xFFFF) { v in if box.doc.area.indices.contains(i) { box.doc.area[i].setting1 = UInt16(v) } }
                    intField("Setting 2", box.doc.area[i].setting2, 0...0xFFFF) { v in if box.doc.area.indices.contains(i) { box.doc.area[i].setting2 = UInt16(v) } }
                    routePicker("Route", selection: box.doc.area[i].routeID == 0xFF ? -1 : Int(box.doc.area[i].routeID)) { v in
                        if box.doc.area.indices.contains(i) { box.doc.area[i].routeID = v < 0 ? 0xFF : UInt8(v) }
                    }
                    intField("Enemy Point", box.doc.area[i].enptID == 0xFF ? 0 : Int(box.doc.area[i].enptID) + 1, 0...255) { v in if box.doc.area.indices.contains(i) { box.doc.area[i].enptID = v == 0 ? 0xFF : UInt8(v - 1) } }
                    hint("0 = none, for Camera and Enemy Point.")
                }
            }
        case .came(let i):
            if box.doc.came.indices.contains(i) {
                cameraFields(i)
            }
        case .poti(let route, let point):
            if box.doc.poti.indices.contains(route) {
                potiFields(route, point)
            }
        case .enph(let i):
            VStack(alignment: .leading, spacing: 4) {
                pathGroupFields(section: .enph, index: i, groups: Binding(get: { box.doc.enph }, set: { box.doc.enph = $0 }))
                if !box.doc.isBOL {
                    Toggle("Requires Off-Roading", isOn: Binding(get: { requiresOffroad(i) }, set: { setRequiresOffroad(i, $0) }))
                        .font(.caption)
                    hint("CPUs only take this path while holding a mushroom or other off-road item (Setting 1 = 1 on its first point). Tick Use Mushroom on the points where they should use it.")
                }
            }
        case .itph(let i):
            pathGroupFields(section: .itph, index: i, groups: Binding(get: { box.doc.itph }, set: { box.doc.itph = $0 }))
        case .ckph(let i):
            pathGroupFields(section: .ckph, index: i, groups: Binding(get: { box.doc.ckph }, set: { box.doc.ckph = $0 }))
        default:
            EmptyView()
        }
    }

    /// The section's full name alongside its raw four-letter KMP tag (e.g. "Enemy Point (ENPT) 3")
    ///, every inspector section shows both, since the abbreviation is what real KMP tools/docs
    /// use but isn't obviously meaningful on its own.
    private func header(_ section: KMPSection, _ index: Int) -> some View {
        Text("\(section.displayName) (\(section.magic)) \(index + 1)").font(.subheadline.bold())
            .help(section.tooltip)
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.caption2).foregroundStyle(.secondary)
    }

    private func warning(_ text: String, color: Color = .orange) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(color)
    }

    /// A full plain-English editor for a Checkpoint gate (CKPT): the two gate points, which
    /// respawn point catches a player who falls off nearby, and its role in lap counting, see
    /// `previous`/`next` aren't shown here at all: they're
    /// derived automatically from this point's position in its Checkpoint Path (see
    /// `KMPDocument.computeCkptLinks`), not something to hand-edit.
    @ViewBuilder
    private func checkpointFields(_ i: Int) -> some View {
        let e = box.doc.ckpt[i]
        VStack(alignment: .leading, spacing: 10) {
            header(.ckpt, i)

            vec2Fields("Left Point", get: { box.doc.ckpt.indices.contains(i) ? box.doc.ckpt[i].left : .init() }, set: { if box.doc.ckpt.indices.contains(i) { box.doc.ckpt[i].left = $0; box.isDirty = true } })
            vec2Fields("Right Point", get: { box.doc.ckpt.indices.contains(i) ? box.doc.ckpt[i].right : .init() }, set: { if box.doc.ckpt.indices.contains(i) { box.doc.ckpt[i].right = $0; box.isDirty = true } })
            hint("These two points form the gate line racers cross. Together with the next checkpoint's gate they make a quadrilateral, keep it convex (don't let the gates cross over each other) or the game can glitch the player's position.")

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Respawn Point").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { Int(box.doc.ckpt.indices.contains(i) ? box.doc.ckpt[i].respawnIndex : 0) },
                    set: { newVal in if box.doc.ckpt.indices.contains(i) { box.doc.ckpt[i].respawnIndex = UInt8(clamping: newVal); box.isDirty = true; onCommit() } }
                )) {
                    ForEach(Array(box.doc.jgpt.indices), id: \.self) { j in
                        Text("Respawn Point \(j + 1)").tag(j)
                    }
                    if !box.doc.jgpt.indices.contains(Int(e.respawnIndex)) {
                        Text("Respawn Point \(Int(e.respawnIndex) + 1) (missing)").tag(Int(e.respawnIndex))
                    }
                }
                .labelsHidden()
                if box.doc.jgpt.isEmpty {
                    warning("No respawn points (JGPT) exist yet, add one, or the game will crash if a player falls off near here.", color: .red)
                } else if !box.doc.jgpt.indices.contains(Int(e.respawnIndex)) {
                    warning("Points at Respawn Point \(Int(e.respawnIndex) + 1), which doesn't exist, pick a valid one or the game will crash.", color: .red)
                }
                hint("Where a player is sent after falling off the track near this checkpoint.")
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Role").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { e.lapCounterType < 0 ? 0 : (e.lapCounterType == 0 ? 2 : 1) },
                    set: { newRole in
                        guard box.doc.ckpt.indices.contains(i) else { return }
                        switch newRole {
                        case 0: box.doc.ckpt[i].lapCounterType = -1
                        case 2: box.doc.ckpt[i].lapCounterType = 0
                        default: box.doc.ckpt[i].lapCounterType = max(1, box.doc.ckpt[i].lapCounterType)
                        }
                        box.isDirty = true; onCommit()
                    }
                )) {
                    Text("Regular").tag(0)
                    Text("Key Checkpoint").tag(1)
                    Text("Finish Line").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch e.lapCounterType {
                case ..<0:
                    hint("A plain gate: only used for shortcut/wrong-way detection and the minimap %. Doesn't affect lap counting.")
                case 0:
                    let finishLineCount = box.doc.ckpt.filter { $0.lapCounterType == 0 }.count
                    hint("Crossing this gate increments the player's lap count. Exactly one checkpoint on the whole track should be the Finish Line.")
                    if finishLineCount > 1 {
                        warning("\(finishLineCount) checkpoints are set as Finish Line, there should only be one, or online play can suffer the \"Everyone In First\" bug.")
                    }
                default:
                    HStack {
                        Text("Key Number").font(.caption)
                        Spacer()
                        numberField("Key #", Float(e.lapCounterType)) { if box.doc.ckpt.indices.contains(i) { box.doc.ckpt[i].lapCounterType = Int8(clamping: max(1, Int($0))); box.isDirty = true } }
                            .frame(width: 70)
                    }
                    hint("Players must cross all Key Checkpoints in ascending number order before the Finish Line will count a lap, this stops shortcuts that skip most of the track. Put the highest-numbered one past 95% of the lap distance so an ultra shortcut can't skip it.")
                }
            }
        }
    }

    /// A full plain-English editor for a Camera (CAME): type, route/next linking, field of view,
    /// look-at points, and timing.
    @ViewBuilder
    private func cameraFields(_ i: Int) -> some View {
        let e = box.doc.came[i]
        let info = cameraTypeInfo[e.type]
        let needsRoute = info?.needsRoute ?? false
        VStack(alignment: .leading, spacing: 10) {
            header(.came, i)

            VStack(alignment: .leading, spacing: 4) {
                Text("Camera Type").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { box.doc.came.indices.contains(i) ? box.doc.came[i].type : 0 },
                    set: { if box.doc.came.indices.contains(i) { box.doc.came[i].type = $0; box.isDirty = true; onCommit() } }
                )) {
                    ForEach(cameraTypeInfo.keys.sorted(), id: \.self) { key in
                        Text("\(key): \(cameraTypeInfo[key]!.name)").tag(key)
                    }
                    if info == nil { Text("Unknown (\(e.type))").tag(e.type) }
                }
                .labelsHidden()
                if let info { hint(info.usage) }
            }

            Divider()

            vec3Fields("Position", get: { box.doc.came.indices.contains(i) ? box.doc.came[i].position : .init() }, set: { if box.doc.came.indices.contains(i) { box.doc.came[i].position = $0; box.isDirty = true } })
            if needsRoute { hint("Ignored, this camera type moves along its Route instead.") }
            vec3Fields("Rotation", get: { box.doc.came.indices.contains(i) ? box.doc.came[i].rotation : .init() }, set: { if box.doc.came.indices.contains(i) { box.doc.came[i].rotation = $0; box.isDirty = true } })

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Route").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { box.doc.came.indices.contains(i) && box.doc.came[i].routeID != 0xFF ? Int(box.doc.came[i].routeID) : -1 },
                    set: { newVal in if box.doc.came.indices.contains(i) { box.doc.came[i].routeID = newVal < 0 ? 0xFF : UInt8(newVal); box.isDirty = true; onCommit() } }
                )) {
                    Text("None").tag(-1)
                    ForEach(Array(box.doc.poti.indices), id: \.self) { r in
                        Text("Route \(r + 1) (\(box.doc.poti[r].points.count) pts)").tag(r)
                    }
                }
                .labelsHidden()
                if needsRoute, e.routeID == 0xFF {
                    warning("This camera type needs a Route to move along, add one (canvas' + menu) and pick it here.")
                } else if !needsRoute, e.routeID != 0xFF {
                    hint("Set, but this camera type doesn't use a Route, it'll be ignored.")
                } else if needsRoute {
                    let sharedWith = box.doc.came.indices.filter { $0 != i && box.doc.came[$0].routeID == e.routeID }.count
                    if sharedWith > 0 {
                        warning("Also used by \(sharedWith) other camera\(sharedWith == 1 ? "" : "s"), each camera should have its own Route.")
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Next Camera").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { box.doc.came.indices.contains(i) && box.doc.came[i].next != 0xFF ? Int(box.doc.came[i].next) : -1 },
                    set: { newVal in if box.doc.came.indices.contains(i) { box.doc.came[i].next = newVal < 0 ? 0xFF : UInt8(newVal); box.isDirty = true; onCommit() } }
                )) {
                    Text("None (end of sequence)").tag(-1)
                    ForEach(Array(box.doc.came.indices), id: \.self) { c in
                        if c != i { Text("Camera \(c + 1) (\(cameraTypeName(box.doc.came[c].type)))").tag(c) }
                    }
                }
                .labelsHidden()
                hint("Chains into another camera once this one finishes, used to build multi-part opening pans.")
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Field of View").font(.caption).foregroundStyle(.secondary)
                HStack {
                    numberField("Start", e.zoomStart) { if box.doc.came.indices.contains(i) { box.doc.came[i].zoomStart = $0; box.isDirty = true } }
                    Text("\u{2192}").foregroundStyle(.secondary)
                    numberField("End", e.zoomEnd) { if box.doc.came.indices.contains(i) { box.doc.came[i].zoomEnd = $0; box.isDirty = true } }
                }
                hint("Viewing angle in degrees, easing from Start to End over the Duration below.")
            }

            Divider()

            vec3Fields("Look-At Start", get: { box.doc.came.indices.contains(i) ? box.doc.came[i].viewPositionStart : .init() }, set: { if box.doc.came.indices.contains(i) { box.doc.came[i].viewPositionStart = $0; box.isDirty = true } })
            vec3Fields("Look-At End", get: { box.doc.came.indices.contains(i) ? box.doc.came[i].viewPositionEnd : .init() }, set: { if box.doc.came.indices.contains(i) { box.doc.came[i].viewPositionEnd = $0; box.isDirty = true } })
            hint("Where the camera points at the start/end of its motion (or a player-relative offset, for follow-style cameras).")

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Timing").font(.caption).foregroundStyle(.secondary)
                HStack { Text("Duration (frames)"); Spacer(); numberField("Time", e.time) { if box.doc.came.indices.contains(i) { box.doc.came[i].time = $0; box.isDirty = true } }.frame(width: 70) }
                HStack { Text("Move Speed"); Spacer(); numberField("Move", Float(e.pointVelocity)) { if box.doc.came.indices.contains(i) { box.doc.came[i].pointVelocity = UInt16(clamping: Int($0)); box.isDirty = true } }.frame(width: 70) }
                HStack { Text("Zoom Speed"); Spacer(); numberField("Zoom", Float(e.zoomVelocity)) { if box.doc.came.indices.contains(i) { box.doc.came[i].zoomVelocity = UInt16(clamping: Int($0)); box.isDirty = true } }.frame(width: 70) }
                HStack { Text("Look Speed"); Spacer(); numberField("Look", Float(e.viewVelocity)) { if box.doc.came.indices.contains(i) { box.doc.came[i].viewVelocity = UInt16(clamping: Int($0)); box.isDirty = true } }.frame(width: 70) }
                hint("Speeds are in units per 100 frames (~1.67s at 60fps), not per-frame, unlike Route points.")
            }

            Divider()

            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text("Shake"); Spacer(); numberField("Shake", Float(e.shake)) { if box.doc.came.indices.contains(i) { box.doc.came[i].shake = UInt8(clamping: Int($0)); box.isDirty = true } }.frame(width: 70) }
                        .help("Camera shake amount, rarely used in real tracks; exact effect isn't well documented.")
                    HStack { Text("Start Flag"); Spacer(); numberField("Start Flag", Float(e.startFlag)) { if box.doc.came.indices.contains(i) { box.doc.came[i].startFlag = UInt8(clamping: Int($0)); box.isDirty = true } }.frame(width: 70) }
                    HStack { Text("Movie Flag"); Spacer(); numberField("Movie Flag", Float(e.movieFlag)) { if box.doc.came.indices.contains(i) { box.doc.came[i].movieFlag = UInt8(clamping: Int($0)); box.isDirty = true } }.frame(width: 70) }
                }
                .font(.caption)
            }
        }
    }

    /// A Route (POTI)'s own settings (Cyclic, Smooth) plus, once a specific point is picked below,
    /// that point's position/settings, shown for both "whole route selected" (from the inspector's
    /// Routes list, `point == nil`) and "one point selected" (from the canvas or the picker here),
    /// since both share the route-level fields.
    @ViewBuilder
    private func potiFields(_ route: Int, _ point: Int?) -> some View {
        let r = box.doc.poti[route]
        VStack(alignment: .leading, spacing: 10) {
            Text("\(KMPSection.poti.displayName) (POTI) \(route + 1)").font(.subheadline.bold())
                .help(KMPSection.poti.tooltip)

            Toggle("Cyclic (loops back to the first point; off = back and forth)", isOn: Binding(
                get: { box.doc.poti.indices.contains(route) ? box.doc.poti[route].isCyclic : true },
                set: { if box.doc.poti.indices.contains(route) { box.doc.poti[route].isCyclic = $0; box.isDirty = true; onCommit() } }
            ))
            Toggle("Smooth motion (curves between points)", isOn: Binding(
                get: { box.doc.poti.indices.contains(route) ? box.doc.poti[route].isSmooth : false },
                set: { if box.doc.poti.indices.contains(route) { box.doc.poti[route].isSmooth = $0; box.isDirty = true; onCommit() } }
            ))
            if r.isSmooth, r.points.count <= 2 {
                warning("Smooth motion on a route of \(r.points.count) point(s) freezes the game, add a point or turn it off.")
            }

            Divider()

            HStack {
                Text("Points").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    guard box.doc.poti.indices.contains(route) else { return }
                    let last = box.doc.poti[route].points.last?.position ?? Vec3()
                    box.doc.poti[route].points.append(RoutePoint(position: Vec3(x: last.x + 500, y: last.y, z: last.z)))
                    box.isDirty = true
                    box.selection = .poti(route: route, point: box.doc.poti[route].points.count - 1)
                    onCommit()
                } label: { Image(systemName: "plus.circle") }
                .buttonStyle(.borderless)
                .help("Add a point at the end of this route.")
            }

            if !r.points.isEmpty {
                Picker("", selection: Binding(
                    get: { point ?? 0 },
                    set: { box.selection = .poti(route: route, point: $0) }
                )) {
                    ForEach(Array(r.points.indices), id: \.self) { p in
                        Text("Point \(p + 1)").tag(p)
                    }
                }
                .labelsHidden()

                if let point, box.doc.poti[route].points.indices.contains(point) {
                    vec3Fields("Position", get: { box.doc.poti[route].points[point].position },
                               set: { if box.doc.poti.indices.contains(route), box.doc.poti[route].points.indices.contains(point) { box.doc.poti[route].points[point].position = $0; box.isDirty = true } })
                    HStack {
                        numberField("Setting 1", Float(box.doc.poti[route].points[point].setting1)) { if box.doc.poti.indices.contains(route), box.doc.poti[route].points.indices.contains(point) { box.doc.poti[route].points[point].setting1 = UInt16(clamping: Int($0)); box.isDirty = true } }
                        numberField("Setting 2", Float(box.doc.poti[route].points[point].setting2)) { if box.doc.poti.indices.contains(route), box.doc.poti[route].points.indices.contains(point) { box.doc.poti[route].points[point].setting2 = UInt16(clamping: Int($0)); box.isDirty = true } }
                    }
                    hint("A point's Setting 1/2 meaning depends on whatever follows this route (e.g. an object's speed), not fixed by the format itself.")
                }
            } else {
                hint("No points yet, a route with no points does nothing. Add one above.")
            }

            Divider()

            let usedBy = describeRouteUsage(route)
            if usedBy.isEmpty {
                warning("Nothing references this route yet, it has no effect in-game until an Object, Camera, or Area is set to use it.")
            } else {
                hint("Used by: \(usedBy.joined(separator: ", ")).")
            }
        }
    }

    private func describeRouteUsage(_ route: Int) -> [String] {
        var out: [String] = []
        let gobjUsers = box.doc.gobj.indices.filter { Int(box.doc.gobj[$0].routeID) == route }
        if !gobjUsers.isEmpty { out.append("\(gobjUsers.count) object\(gobjUsers.count == 1 ? "" : "s")") }
        let cameUsers = box.doc.came.indices.filter { Int(box.doc.came[$0].routeID) == route }
        if !cameUsers.isEmpty { out.append("\(cameUsers.count) camera\(cameUsers.count == 1 ? "" : "s")") }
        let areaUsers = box.doc.area.indices.filter { Int(box.doc.area[$0].routeID) == route }
        if !areaUsers.isEmpty { out.append("\(areaUsers.count) area\(areaUsers.count == 1 ? "" : "s")") }
        return out
    }

    /// A path group's own settings (Enemy/Item/Checkpoint Path), as opposed to one point inside
    /// it. The point range is shown but not editable here: it's derived purely from where this
    /// group's points sit in the shared array (see `KMPEditorView.appendToLastGroup`/`deleteGroup`),
    /// so hand-editing it here could desync it from the actual points. What *is* this group's own
    /// data are its Previous/Next links, the fork/merge points a track with shortcuts needs, and
    /// previously only reachable by starting a brand new path, never by linking two existing ones.
    @ViewBuilder
    private func pathGroupFields(section: KMPSection, index: Int, groups: Binding<[PathLinkEntry]>) -> some View {
        if groups.wrappedValue.indices.contains(index) {
            let group = groups.wrappedValue[index]
            let lastPoint = Int(group.startIndex) + max(0, Int(group.pointCount) - 1)
            VStack(alignment: .leading, spacing: 10) {
                header(section, index)
                Text("Points \(Int(group.startIndex) + 1)-\(lastPoint + 1) (\(group.pointCount) point\(group.pointCount == 1 ? "" : "s"))")
                    .font(.caption).foregroundStyle(.secondary)
                hint("The point range fills in automatically as points are added/removed on the canvas, not hand-edited here.")

                Divider()

                linkFields("Previous", section: section, index: index, groups: groups, isNext: false)
                linkFields("Next", section: section, index: index, groups: groups, isNext: true)
            }
        }
    }

    /// One direction (Previous or Next) of a path group's links: up to 6 slots per the format, but
    /// only the ones actually in use are shown (plus an Add button) rather than 6 pickers most
    /// tracks would leave on "None", most paths use 0 or 1 link, a fork/merge uses 2+.
    @ViewBuilder
    private func linkFields(_ label: String, section: KMPSection, index: Int, groups: Binding<[PathLinkEntry]>, isNext: Bool) -> some View {
        let arr = isNext ? groups.wrappedValue[index].nextGroups : groups.wrappedValue[index].previousGroups
        let used = arr.enumerated().filter { $0.element != 0xFF }
        VStack(alignment: .leading, spacing: 4) {
            Text("\(label) Group(s)").font(.caption).foregroundStyle(.secondary)
            ForEach(used, id: \.offset) { slot, value in
                HStack {
                    Picker("", selection: Binding(
                        get: { Int(value) },
                        set: { newVal in setLink(groups: groups, index: index, slot: slot, isNext: isNext, value: UInt8(newVal)) }
                    )) {
                        ForEach(Array(groups.wrappedValue.indices), id: \.self) { g in
                            Text("\(section.displayName) \(g + 1)").tag(g)
                        }
                    }
                    .labelsHidden()
                    Button { setLink(groups: groups, index: index, slot: slot, isNext: isNext, value: 0xFF) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            if used.isEmpty {
                hint("None.")
            }
            if used.count < 6 {
                Button {
                    guard let freeSlot = (0..<6).first(where: { $0 >= arr.count || arr[$0] == 0xFF }) else { return }
                    let target = groups.wrappedValue.indices.first(where: { $0 != index }) ?? index
                    setLink(groups: groups, index: index, slot: freeSlot, isNext: isNext, value: UInt8(target))
                } label: { Label("Add \(label) Link", systemImage: "plus.circle") }
                .buttonStyle(.borderless)
            }
            if isNext, used.isEmpty {
                warning("No \"next\" group, reaching the end of this path has nowhere to continue. A single looping path should link to itself.")
            }
        }
    }

    private func setLink(groups: Binding<[PathLinkEntry]>, index: Int, slot: Int, isNext: Bool, value: UInt8) {
        guard groups.wrappedValue.indices.contains(index) else { return }
        var g = groups.wrappedValue
        if isNext {
            while g[index].nextGroups.count <= slot { g[index].nextGroups.append(0xFF) }
            g[index].nextGroups[slot] = value
        } else {
            while g[index].previousGroups.count <= slot { g[index].previousGroups.append(0xFF) }
            g[index].previousGroups[slot] = value
        }
        groups.wrappedValue = g
        onCommit()
    }

    /// A labeled axis field: a fixed-width letter (X/Y/Z/L/R/...) ahead of the number, since
    /// `TextField`'s own `label` argument is only a placeholder, invisible the moment the field
    /// actually holds a value, which otherwise leaves a row of unlabeled boxes with no way to
    /// tell which axis is which without clicking in.
    private func axisField(_ axis: String, _ value: Float, _ set: @escaping (Float) -> Void) -> some View {
        HStack(spacing: 3) {
            Text(axis).font(.caption2.monospaced()).foregroundStyle(.secondary).frame(width: 8, alignment: .leading)
            numberField(axis, value, set).frame(width: 58)
        }
    }

    @ViewBuilder
    private func vec3Fields(_ label: String, get: () -> Vec3, set: @escaping (Vec3) -> Void) -> some View {
        let v = get()
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                axisField("X", v.x) { set(Vec3(x: $0, y: v.y, z: v.z)) }
                axisField("Y", v.y) { set(Vec3(x: v.x, y: $0, z: v.z)) }
                axisField("Z", v.z) { set(Vec3(x: v.x, y: v.y, z: $0)) }
            }
        }
    }

    @ViewBuilder
    private func vec2Fields(_ label: String, get: () -> Vec2, set: @escaping (Vec2) -> Void) -> some View {
        let v = get()
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                axisField("X", v.x) { set(Vec2(x: $0, y: v.y)) }
                axisField("Y", v.y) { set(Vec2(x: v.x, y: $0)) }
            }
        }
    }

    static let areaTypeNames: [UInt8: String] = [
        0: "Camera, switches to its Camera while a player is inside (replays)",
        1: "Effect, environment effect such as rain or sand",
        2: "Fog",
        3: "Pull, moving road/water that pushes karts along its Route",
        4: "Enemy Fall, sends CPUs that fall here to its Enemy Point",
        5: "Minimap, 2D map area",
        6: "Bloom",
    ]

    static func gobjSettingLabel(_ objectID: UInt16, _ k: Int) -> String {
        if objectID == 0x0065 || objectID == 0x00CE {
            if let name = [1: "Player Type", 2: "Enemy Type", 3: "No Shadow", 5: "Lottery Timing"][k] { return "S\(k + 1) \(name)" }
        }
        return "Setting \(k + 1)"
    }

    /// An integer field for any KMP field; `range` also enforces the field's real width, so a
    /// typed value can't wrap around when it's narrowed back to UInt8/UInt16.
    private func intField<T: BinaryInteger>(_ label: String, _ value: T, _ range: ClosedRange<Int>, set: @escaping (Int) -> Void) -> some View {
        HStack {
            Text(label).font(.caption)
            Spacer()
            TextField(label, value: Binding(get: { Int(value) }, set: { set(min(max($0, range.lowerBound), range.upperBound)); box.isDirty = true; onCommit() }),
                      format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
        }
    }

    /// "None" plus every route, for the fields that reference a POTI route by index.
    private func routePicker(_ label: String, selection: Int, set: @escaping (Int) -> Void) -> some View {
        Picker(label, selection: Binding(get: { selection }, set: { set($0); box.isDirty = true; onCommit() })) {
            Text("None").tag(-1)
            ForEach(box.doc.poti.indices, id: \.self) { Text("Route \($0 + 1)").tag($0) }
            if selection >= box.doc.poti.count { Text("Route \(selection + 1) (missing)").tag(selection) }
        }
        .font(.caption)
    }

    private func floatField(_ label: String, get: () -> Float, set: @escaping (Float) -> Void) -> some View {
        HStack { Text(label).font(.caption); Spacer(); numberField(label, get(), set) }
    }

    private func numberField(_ label: String, _ value: Float, _ set: @escaping (Float) -> Void) -> some View {
        TextField(label, value: Binding(get: { value }, set: { set($0); onCommit() }), format: .number)
            .textFieldStyle(.roundedBorder)
            .frame(width: 70)
    }
}

/// Tools > "Enemy Paths to Item Paths...": pick which enemy path branches items may follow, then
/// replace the item paths with a copy of the rest (see `KMPDocument.copyEnemyPathsToItemPaths`).
private struct EnemyToItemPathsSheet: View {
    @ObservedObject var box: KMPDocumentBox
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var excluded: Set<Int> = []

    var body: some View {
        let doc = box.doc
        let cutOff = doc.itemPathsCutOff(excluding: excluded).sorted()
        VStack(alignment: .leading, spacing: 12) {
            Text("Enemy Paths to Item Paths").font(.headline)
            Text("Untick the branches items shouldn't be able to take. Paths that require off-roading start unticked.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(doc.enph.indices, id: \.self) { g in
                    let e = doc.enph[g]
                    let next = e.nextGroups.filter { $0 != 0xFF }.map { "\(Int($0) + 1)" }.joined(separator: ", ")
                    Toggle(isOn: Binding(get: { !excluded.contains(g) }, set: { if $0 { excluded.remove(g) } else { excluded.insert(g) } })) {
                        HStack {
                            Text("Enemy Path \(g + 1)")
                            Text("\(e.pointCount) pts\(next.isEmpty ? "" : ", then \(next)")").foregroundStyle(.secondary)
                            if isOffroad(g) { Text("off-road").font(.caption2).foregroundStyle(.orange) }
                        }
                    }
                }
            }
            .frame(height: 260)
            .border(Color.gray.opacity(0.3))
            if excluded.count + cutOff.count == doc.enph.count {
                Label("Every path is unticked or cut off by the unticked ones, so there would be no item paths.", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
            } else if !cutOff.isEmpty {
                Label("Also left out: Enemy Path \(cutOff.map { "\($0 + 1)" }.joined(separator: ", ")). With the unticked paths gone, nothing leads into \(cutOff.count == 1 ? "it" : "them") or \(cutOff.count == 1 ? "it leads" : "they lead") nowhere, and an item path like that crashes the game when items come into play.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !doc.itph.isEmpty {
                Text("Replaces the current \(doc.itph.count) item path\(doc.itph.count == 1 ? "" : "s") (\(doc.itpt.count) points). Undo restores them.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Convert") {
                    box.doc.copyEnemyPathsToItemPaths(excluding: excluded)
                    box.selection = nil
                    box.isDirty = true
                    box.objectWillChange.send()
                    onDone()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(excluded.count + cutOff.count == doc.enph.count)
            }
        }
        .padding()
        .frame(width: 440)
        .onAppear { excluded = Set(doc.enph.indices.filter { isOffroad($0) && isBranch($0) }) }
    }

    /// Every path leading into `g` also leads somewhere else, so leaving `g` out still leaves a
    /// way on. (old_garden_ds marks a path every route runs through as off-road.)
    private func isBranch(_ g: Int) -> Bool {
        let groups = box.doc.enph
        let into = groups.indices.filter { groups[$0].nextGroups.contains(UInt8(g)) }
        return !into.isEmpty && into.allSatisfy { p in groups[p].nextGroups.contains { $0 != 0xFF && $0 != UInt8(g) } }
    }

    /// The path's first point says "only enter with an off-road item" (setting 1 = 1).
    private func isOffroad(_ g: Int) -> Bool {
        let first = Int(box.doc.enph[g].startIndex)
        return box.doc.enpt.indices.contains(first) && box.doc.enpt[first].setting1 == 1
    }
}
