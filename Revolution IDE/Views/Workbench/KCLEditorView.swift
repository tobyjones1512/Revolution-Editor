import SwiftUI
import SceneKit
import UniformTypeIdentifiers
import Combine

/// Viewer + editor for Mario Kart Wii collision (.kcl) files. There's no vertex-level mesh editing
///, like every real KCL tool, the practical workflow for *shape* changes is "model collision
/// externally, import the whole mesh", but every triangle's collision flag (surface type) is
/// directly editable here, individually or in bulk per surface type, and a triangle can be deleted
/// outright. This shows the decoded mesh (colored by collision surface type, with the selected
/// triangle highlighted) and lets the user replace it wholesale from a .obj file.
/// Which of `KCLDocumentBox`'s two texture dictionaries a texture-link action targets: the
/// whole-surface-type default (`.base`, keyed by `attribute & 0x1F`) or one exact attribute
/// value's override (`.override`, keyed by the full 16-bit flag), see `KCLDocumentBox
/// .flagTextureOverrides`'s doc comment for why these are kept separate rather than one dictionary
/// keyed by full attribute.
private enum FlagTextureTarget: Hashable {
    case base(UInt16)
    case override(UInt16)
    /// Every triangle imported from one material of the source model.
    case material(String)
}

/// One row of the "Surface Types" list, either a base surface type's default bucket, or one
/// exact-attribute override split out of it. See `KCLEditorView.surfaceRows`'s doc comment.
private struct SurfaceRow: Identifiable {
    var id: FlagTextureTarget { target }
    let target: FlagTextureTarget
    let baseType: UInt16
    let count: Int
    /// The flag's name, for an override row, of its exact attribute rather than just the base type.
    let label: String
}

/// One row of `KCLEditorView.objImportSheet`'s per-material review table, lets the user pick a
/// real collision flag for each `usemtl` material an imported .obj uses (or for its materialless
/// triangles, if any) before the import actually happens, instead of every material silently
/// getting an arbitrary sequential flag.
private struct OBJMaterialAssignment: Identifiable {
    let id = UUID()
    let materialName: String
    var hexText: String
    /// Resolved from the .obj's companion .mtl file, if it has one (see `KCLEditorView.importOBJ`)
    ///, either the material's actual `map_Kd` texture, or a flat swatch of its `Kd` diffuse color
    /// if it only gives a color. Nil for a material the .mtl doesn't cover, or when there's no
    /// .mtl at all, not an error, plenty of real .obj exports have neither.
    var image: NSImage?
    /// Unticked: the material's triangles are left out of the collision entirely.
    var include = true
}

/// Which winding direction of triangle the 3D preview hides, purely as a way to spot a collision
/// triangle that's wound backwards (and so has an inverted normal), see `KCLEditorView
/// .displayControls`'s doc comment.
private enum KCLCullMode: String, CaseIterable, Identifiable {
    case none = "None", clockwise = "Clockwise", counterClockwise = "Counter Clockwise"
    var id: String { rawValue }
}

struct KCLEditorView: View {
    @ObservedObject private var controls = Controls.shared
    @ObservedObject var box: KCLDocumentBox
    @State private var importErrorMessage: String?
    @State private var textureErrorMessage: String?
    @State private var selectedTriangleIndex: Int?
    @State private var bulkFromAttribute: UInt16?
    /// The row "Reassign All" came from, when it was a row: only its triangles change (a material
    /// row shares its surface type with other materials).
    @State private var bulkRow: SurfaceRow?
    @State private var bulkToHexText: String = "0"
    @State private var texturePickerTarget: FlagTextureTarget?
    @State private var texturePickerCandidates: [TextureCandidate] = []
    /// The just-parsed triangles from an in-progress "Import OBJ", waiting on the user to assign a
    /// surface type to each of its materials in `objImportSheet`, see `importOBJ`.
    @State private var pendingOBJTriangles: [OBJImporter.Triangle]?
    @State private var objMaterialAssignments: [OBJMaterialAssignment] = []
    @State private var wireframeMode = false
    @State private var cullMode: KCLCullMode = .none
    /// Whether the preview's per-surface-type materials render as flat, unlit color (the default --
    /// easiest to tell surface types apart) or take real scene lighting, which shades a triangle
    /// darker the more its normal points away from the light, paired with `cullMode`, a way to
    /// spot a collision triangle whose winding (and so normal) is backwards without leaving this view.
    @State private var flatShading = true
    /// A connected patch of same-material triangles picked by clicking the 3D preview (see
    /// `selectConnected`), separate from `selectedTriangleIndex` (one triangle, via the stepper)
    /// since this is meant for retagging a whole contiguous surface (e.g. one lane of road) at once
    /// without touching every other triangle that happens to share its flag elsewhere on the track.
    @State private var connectedSelection: Set<Int> = []
    @State private var connectedReassignHexText: String = "0"
    @StateObject private var previewController = KCLPreviewController()
    /// Undo/redo + history list, same `EditHistory` pattern `KMPEditorView` uses. Snapshots on
    /// each discrete action (attribute commit, bulk reassign, delete, OBJ import), not per keystroke.
    @StateObject private var history: EditHistory
    /// Bumped on every attribute/delete edit so `KCLScenePreviewView` knows to rebuild even when
    /// the triangle count and first vertex (its own cheap change-check) didn't change, see that
    /// view's `signature`.
    @State private var editRevision = 0
    @State private var showInfo = false
    @AppStorage("showArchiveInfoButton") private var showArchiveInfoButton = true
    @AppStorage(KCLFlagColors.defaultsKey) private var customColors = ""
    @State private var convertZUpToYUp = false
    /// The .obj `exportOBJForEditing` just wrote, while its "open it?" prompt is up.
    @State private var exportedOBJ: URL?

    init(box: KCLDocumentBox) {
        self.box = box
        _history = StateObject(wrappedValue: EditHistory(initial: Self.snapshot(box.doc)))
    }

    /// Snapshots the triangles themselves rather than serialized KCL bytes: keeps each triangle's
    /// editor-only `material`, and skips rebuilding the octree on every edit.
    private static func snapshot(_ doc: KCLDocument) -> Data {
        (try? JSONEncoder().encode(doc.triangles)) ?? Data()
    }

    private func pushHistory(_ label: String) {
        history.push(Self.snapshot(box.doc), label: label)
    }

    private func restoreFromHistory(_ data: Data) {
        guard let triangles = try? JSONDecoder().decode([KCLTriangle].self, from: data) else { return }
        let doc = KCLDocument()
        doc.bcoSource = box.doc.bcoSource
        doc.prismThickness = box.doc.prismThickness
        doc.sphereRadius = box.doc.sphereRadius
        doc.triangles = triangles
        box.doc = doc
        selectedTriangleIndex = nil
        bulkFromAttribute = nil
        connectedSelection = []
        box.isDirty = true
        editRevision += 1
    }

    var body: some View {
        HSplitView {
            KCLScenePreviewView(document: box.doc, selectedTriangleIndex: selectedTriangleIndex,
                                 flagTextures: box.flagTextures, flagTextureOverrides: box.flagTextureOverrides, materialTextures: box.materialTextures,
                                 controller: previewController, editRevision: editRevision,
                                 wireframeMode: wireframeMode, cullMode: cullMode, flatShading: flatShading, customColors: customColors,
                                 connectedSelection: connectedSelection, onTriangleClick: { selectConnected(from: $0) })
                .frame(minWidth: 300, minHeight: 300)
                .help("Same controls as the 3D track preview: drag to orbit, \(Controls.shared.phrase(.view3DPan, "drag").lowercased()) or right-drag to pan, scroll or pinch to zoom toward the cursor, double-click to centre, \(Controls.shared.keys(.flyForward))\(Controls.shared.keys(.flyLeft))\(Controls.shared.keys(.flyBack))\(Controls.shared.keys(.flyRight))/\(Controls.shared.keys(.flyDown))\(Controls.shared.keys(.flyUp)) to fly. \(Controls.shared.keys(.frameSelection))/\(Controls.shared.keys(.frameTrack)) frame, \(Controls.shared.keys(.returnToStart)) resets, \(Controls.shared.keys(.viewTop))/\(Controls.shared.keys(.viewFront))/\(Controls.shared.keys(.viewSide)) top/front/side, \(Controls.shared.keys(.toggleOrtho)) orthographic. Click a triangle to select its connected surface; click the same spot again to pick the surface behind it (e.g. under a ramp).")
                .overlay(alignment: .topLeading) { displayControls }
                .overlay(alignment: .bottomTrailing) { previewZoomControls }
                .overlay(alignment: .bottomLeading) {
                    HistoryControlsView(history: history, onRestore: restoreFromHistory)
                        .padding(6)
                        .background(.bar, in: RoundedRectangle(cornerRadius: 8))
                        .padding(10)
                }

            VSplitView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Collision Mesh").font(.headline)
                            .help("The invisible mesh that decides what a racer's wheels/kart actually touch, road, wall, off-road, lava, etc. It's usually a simplified version of the visible track model (the .brres), not the exact same geometry.")
                        Spacer()
                        if showArchiveInfoButton {
                            Button { showInfo.toggle() } label: { Label("Info", systemImage: "info.circle") }
                                .help("Learn about which games use the KCL format and what its data means")
                                .popover(isPresented: $showInfo) { FormatInfoPopoverView(title: "KCL Format Info", games: KCLFormatInfo.games) }
                        }
                    }
                    Text("\(box.doc.triangles.count) triangles").font(.caption).foregroundStyle(.secondary)
                    Text(boundsText).font(.caption2).foregroundStyle(.secondary)

                    Divider()
                    Text(box.materialTextures.isEmpty && !box.doc.triangles.contains { $0.material != nil } ? "Surface Types (tap to select)" : "Textures (tap to select)").font(.subheadline.bold())
                        .help("Each triangle carries a \"flag\" that picks its surface type (Road, Off-Road, Wall, Boost Panel, ...), this controls physics like grip, speed, and whether it counts as out-of-bounds. Tap a row to jump to one of its triangles.")
                    List(surfaceRows) { row in
                        HStack {
                            if let img = texture(for: row.target) {
                                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                                    .frame(width: 16, height: 16).clipShape(RoundedRectangle(cornerRadius: 3))
                            } else {
                                ColorPicker("Colour", selection: Binding(
                                    get: { _ = customColors; return Color(nsColor: kclFlagColor(row.baseType, bco: box.doc.isBCO)) },
                                    set: { KCLFlagColors.set(NSColor($0), for: row.baseType, bco: box.doc.isBCO) }), supportsOpacity: false)
                                    .labelsHidden()
                                    .fixedSize()
                                    .padding(.trailing, 4)
                                    .help("This surface's colour in the 3D view, for every collision file. Right-click the row to reset it.")
                            }
                            Text(row.label)
                            Spacer()
                            Text("\(row.count)").foregroundStyle(.secondary)
                            if !box.doc.isBCO {
                                Toggle("Trick", isOn: Binding(get: { isTrickable(row) }, set: { setTrickable($0, in: row) }))
                                    .toggleStyle(.checkbox)
                                    .help("Trickable: players can perform a trick off this surface (sets collision-effect bit 0x2000 on all \(row.count) of its triangles).")
                            }
                            textureMenu(for: row.target)
                        }
                        .font(.caption)
                        .contentShape(Rectangle())
                        .onTapGesture { selectFirst(row) }
                        .contextMenu {
                            if KCLFlagColors.custom(row.baseType, bco: box.doc.isBCO) != nil {
                                Button("Reset Colour") { KCLFlagColors.set(nil, for: row.baseType, bco: box.doc.isBCO) }
                            }
                            Button("Delete \(row.count) Triangle\(row.count == 1 ? "" : "s")", role: .destructive) { deleteTriangles(in: row) }
                                .help("Removes this surface type's triangles (and its linked texture) from the collision.")
                        }
                    }
                    .listStyle(.inset)
                }
                .padding([.top, .horizontal])
                .padding(.bottom, 6)
                .frame(minHeight: 120)

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let bulkFromAttribute {
                            GroupBox("Reassign All \"\(bulkRow?.label ?? box.doc.flagName(bulkFromAttribute))\"") {
                                HStack {
                                    Text("To flag (hex):").font(.caption)
                                    TextField("0", text: $bulkToHexText).textFieldStyle(.roundedBorder).frame(width: 70)
                                    kclFlagMenu(bco: box.doc.isBCO) { bulkToHexText = String($0, radix: 16) }
                                    Button("Apply") { applyBulkReassign() }
                                }
                                .padding(4)
                            }
                        }

                        if !connectedSelection.isEmpty {
                            GroupBox("Connected Selection (\(connectedSelection.count) triangles)") {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Click a triangle in the 3D view to select every triangle connected to it that shares its current surface type/texture, handy for retagging just one contiguous patch (e.g. one lane) instead of every triangle sharing that flag across the whole track.")
                                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    HStack {
                                        Text("To flag (hex):").font(.caption)
                                        TextField("0", text: $connectedReassignHexText).textFieldStyle(.roundedBorder).frame(width: 70)
                                        kclFlagMenu(bco: box.doc.isBCO) { connectedReassignHexText = String($0, radix: 16) }
                                        Button("Apply") { applyConnectedReassign() }
                                        Button("Clear") { connectedSelection = [] }
                                    }
                                }
                                .padding(4)
                            }
                        }

                        Divider()
                        GroupBox("Edit Triangle") {
                            VStack(alignment: .leading, spacing: 8) {
                                Stepper(value: Binding(
                                    get: { selectedTriangleIndex ?? 0 },
                                    set: { selectedTriangleIndex = box.doc.triangles.isEmpty ? nil : max(0, min($0, box.doc.triangles.count - 1)) }
                                ), in: 0...max(0, box.doc.triangles.count - 1)) {
                                    Text(box.doc.triangles.isEmpty ? "No triangles" : "Triangle #\(selectedTriangleIndex ?? 0) of \(box.doc.triangles.count)")
                                }
                                .disabled(box.doc.triangles.isEmpty)

                                if let idx = selectedTriangleIndex, box.doc.triangles.indices.contains(idx) {
                                    Text(box.doc.flagName(box.doc.triangles[idx].attribute)).font(.caption).foregroundStyle(.secondary)
                                    HStack {
                                        Text("Flag (hex):").font(.caption)
                                        HexFlagField(initialValue: box.doc.triangles[idx].attribute) { newValue in
                                            setTriangleAttribute(idx, newValue)
                                        }
                                        .id("\(idx)-\(box.doc.triangles[idx].attribute)")
                                        kclFlagMenu(bco: box.doc.isBCO) { setTriangleAttribute(idx, $0) }
                                    }
                                    HStack {
                                        Text("Texture for this exact flag:").font(.caption)
                                        textureMenu(for: .override(box.doc.triangles[idx].attribute))
                                            .help("Link a texture to this triangle's exact flag value (\(String(format: "0x%02X", box.doc.triangles[idx].attribute))) rather than its whole surface type, lets triangles sharing a base flag but differing in variant bits show separately, each with their own texture.")
                                    }
                                    Button("Delete Triangle", role: .destructive) { deleteTriangle(idx) }
                                        .help("Removes this triangle from the collision mesh only, the visible track model (.brres) is untouched, so this creates an invisible hole a racer can fall through, not a visual one.")
                                } else {
                                    Text("Tap a surface type above, or use the stepper, to select a triangle.")
                                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(4)
                        }

                        Divider()
                        GroupBox("Create From .obj/.dae") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Replaces this file's entire collision mesh with triangles imported from a Wavefront .obj model. The .obj's own normals and groups are ignored. KCL always computes its own face/edge normals from each triangle's winding. You'll assign a surface type to each of the model's materials next, if the .obj has a companion .mtl file, each material's texture/colour is pulled in automatically as a reference image.")
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                HStack {
                                    Button("Import OBJ...") { importOBJ() }
                                    Button("Edit as OBJ...") { exportOBJForEditing() }
                                        .help("Writes this collision as an .obj, then offers to open it in your model editor. Bring your changes back with Import OBJ.")
                                }
                            }
                            .padding(4)
                        }
                    }
                    .padding([.horizontal, .bottom])
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(minWidth: 280, idealWidth: 320)
        }
        .alert("Couldn't Import OBJ", isPresented: Binding(get: { importErrorMessage != nil }, set: { if !$0 { importErrorMessage = nil } })) {
            Button("OK", role: .cancel) { importErrorMessage = nil }
        } message: {
            Text(importErrorMessage ?? "")
        }
        .alert("Collision Exported as OBJ", isPresented: Binding(get: { exportedOBJ != nil }, set: { if !$0 { exportedOBJ = nil } })) {
            Button("Open in Editor") { if let url = exportedOBJ { openForEditing(url) } }
            Button("Show in Finder") { if let url = exportedOBJ { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("Edit \(exportedOBJ?.lastPathComponent ?? "the .obj"), keeping each surface's \"kcl_0x...\" material name, then bring it back with Import OBJ (leave Y/Z swap off).")
        }
        .alert("Couldn't Load Texture", isPresented: Binding(get: { textureErrorMessage != nil }, set: { if !$0 { textureErrorMessage = nil } })) {
            Button("OK", role: .cancel) { textureErrorMessage = nil }
        } message: {
            Text(textureErrorMessage ?? "")
        }
        .sheet(isPresented: Binding(get: { texturePickerTarget != nil }, set: { if !$0 { texturePickerTarget = nil } })) {
            TextureCandidatePickerView(candidates: texturePickerCandidates) { chosen in
                if let target = texturePickerTarget {
                    setTexture(chosen.image, label: chosen.name, for: target)
                }
                texturePickerTarget = nil
            }
        }
        .onAppear {
            if let url = box.pendingOBJURL { box.pendingOBJURL = nil; beginOBJImport(url) }
        }
        .sheet(isPresented: Binding(get: { pendingOBJTriangles != nil }, set: { if !$0 { cancelOBJImport() } })) {
            objImportSheet
        }
    }

    // MARK: Display controls (wireframe / culling / shading)

    /// Matches the checkbox/radio-button "Wireframe Mode" / "Disable lightmap" / "Culling" controls
    /// a classic KCL-editing tool (e.g. SZS Modifier's KCL viewer) puts next to its 3D view --
    /// diagnostic aids rather than editing tools: they don't change the .kcl at all, just how this
    /// preview renders it, to help spot mesh problems a flat colored view alone can hide.
    private var displayControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Wireframe Mode", isOn: $wireframeMode)
                .help("Shows only each triangle's edges instead of a solid coloured face, makes it easy to spot overlapping, missing, or oddly-shaped triangles in the collision mesh.")
            Toggle("Disable Lightmap", isOn: $flatShading)
                .help("On (default): every surface type renders as its own flat, evenly-lit colour, easiest for telling types apart. Off: the mesh is shaded by real scene lighting instead, so a triangle facing away from the light goes dark, useful together with Culling below for spotting a triangle whose winding (and so its collision normal) is backwards.")
            Divider()
            Text("Culling").font(.caption.bold())
            Picker("", selection: $cullMode) {
                ForEach(KCLCullMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)
            .help("None shows every triangle regardless of which way it's wound. Clockwise/Counter Clockwise hides whichever triangles are wound the other way, if part of the track disappears, those triangles' winding (and so their collision normal) is backwards.")
        }
        .font(.caption)
        .padding(8)
        .background(.bar, in: RoundedRectangle(cornerRadius: 8))
        .padding(10)
    }

    /// Bounding box of every triangle currently in the mesh, the same at-a-glance "how big/where
    /// is this thing" readout a KCL tool's viewer typically shows next to its 3D view.
    private var boundsText: String {
        let triangles = box.doc.triangles
        guard !triangles.isEmpty else { return "No triangles" }
        var bmin = Vec3(x: .greatestFiniteMagnitude, y: .greatestFiniteMagnitude, z: .greatestFiniteMagnitude)
        var bmax = Vec3(x: -.greatestFiniteMagnitude, y: -.greatestFiniteMagnitude, z: -.greatestFiniteMagnitude)
        for t in triangles {
            for v in [t.v0, t.v1, t.v2] {
                bmin = Vec3(x: min(bmin.x, v.x), y: min(bmin.y, v.y), z: min(bmin.z, v.z))
                bmax = Vec3(x: max(bmax.x, v.x), y: max(bmax.y, v.y), z: max(bmax.z, v.z))
            }
        }
        return "Bounds: X: \(Int(bmin.x))...\(Int(bmax.x))  Y: \(Int(bmin.y))...\(Int(bmax.y))  Z: \(Int(bmin.z))...\(Int(bmax.z))"
    }

    // MARK: Preview zoom

    private var previewZoomControls: some View {
        HStack(spacing: 4) {
            Button { previewController.resetView() } label: { Label("Reset View", systemImage: "arrow.counterclockwise") }
                .help("Put the camera back where it started (0).")
            Button { previewController.zoom(inward: false) } label: { Image(systemName: "minus.magnifyingglass") }
                .shortcut(.zoomOut)
                .help("Zoom out")
            Button { previewController.zoom(inward: true) } label: { Image(systemName: "plus.magnifyingglass") }
                .shortcut(.zoomIn)
                .help("Zoom in")
        }
        .buttonStyle(.borderless)
        .padding(6)
        .background(.bar, in: RoundedRectangle(cornerRadius: 8))
        .padding(10)
    }

    // MARK: Texture linking

    private func texture(for target: FlagTextureTarget) -> NSImage? {
        switch target {
        case .base(let b): return box.flagTextures[b]
        case .override(let a): return box.flagTextureOverrides[a]
        case .material(let m): return box.materialTextures[m]
        }
    }

    private func setTexture(_ image: NSImage?, label: String?, for target: FlagTextureTarget) {
        switch target {
        case .base(let b): box.flagTextures[b] = image; box.flagTextureLabels[b] = label
        case .override(let a): box.flagTextureOverrides[a] = image; box.flagTextureOverrideLabels[a] = label
        case .material(let m): box.materialTextures[m] = image
        }
        editRevision += 1
    }

    @ViewBuilder
    private func textureMenu(for target: FlagTextureTarget) -> some View {
        Menu {
            Button("Choose Image File...") { chooseTextureFile(for: target) }
            Button("From .brres/.szs...") { chooseTextureFromArchive(for: target) }
            if texture(for: target) != nil {
                Divider()
                Button("Clear Texture", role: .destructive) { setTexture(nil, label: nil, for: target) }
            }
        } label: {
            Image(systemName: "photo")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Link a reference texture (editor-only visual aid, not written to the .kcl file)")
    }

    private func chooseTextureFile(for target: FlagTextureTarget) {
        PanelPresenter.openFile(configure: {
            $0.allowedContentTypes = [.png, .jpeg, .tiff, .bmp, .gif]
            $0.allowsOtherFileTypes = true
        }) { url in
            guard let url else { return }
            guard let img = NSImage(contentsOf: url) else {
                textureErrorMessage = "Couldn't load \(url.lastPathComponent) as an image."
                return
            }
            setTexture(img, label: url.lastPathComponent, for: target)
        }
    }

    /// Lets the user point at a `.brres` (or a `.szs`/`.arc` containing one) and pick one of its
    /// decoded textures by name, the practical way to match a flag to the real track texture
    /// used there, since MKWii course textures live inside BRRES/TPL, not as standalone images.
    private func chooseTextureFromArchive(for target: FlagTextureTarget) {
        PanelPresenter.openFile(configure: {
            $0.allowedContentTypes = ["brres", "szs", "arc"].compactMap { UTType(filenameExtension: $0) }
            $0.allowsOtherFileTypes = true
        }) { url in
            guard let url, let data = try? Data(contentsOf: url) else { return }
            var brresData = data
            let ext = url.pathExtension.lowercased()
            if ext == "szs" || ext == "arc" || Yaz0.isYaz0(data) {
                guard let (root, _) = try? SZS.open(data) else {
                    textureErrorMessage = "Couldn't open \(url.lastPathComponent) as an archive."
                    return
                }
                func firstBRRES(_ node: U8Node) -> U8Node? {
                    if !node.isDirectory, (node.name as NSString).pathExtension.lowercased() == "brres" { return node }
                    for c in node.children { if let f = firstBRRES(c) { return f } }
                    return nil
                }
                guard let match = firstBRRES(root), let d = match.data else {
                    textureErrorMessage = "No .brres model found inside \(url.lastPathComponent)."
                    return
                }
                brresData = d
            }
            guard let doc = try? BRRESDocument.parse(brresData) else {
                textureErrorMessage = "Couldn't parse \(url.lastPathComponent) as a BRRES."
                return
            }
            let paletteBox = BRRESDocumentBox(doc: doc)
            let textures: [TextureCandidate] = doc.resources.filter { $0.magic == "TEX0" }.compactMap { r in
                guard let v = TEX0View(r), let rgba = v.decodeRGBA(palette: paletteBox.palette(for: r)),
                      let img = ImageUtil.nsImage(fromRGBA: rgba, width: v.width, height: v.height) else { return nil }
                return TextureCandidate(name: r.name, image: img)
            }
            guard !textures.isEmpty else {
                textureErrorMessage = "No decodable textures found in \(url.lastPathComponent)."
                return
            }
            texturePickerCandidates = textures
            texturePickerTarget = target
        }
    }

    /// Grouped by base surface type *and* variant (`attribute & 0xFF`) by default, a real
    /// track's full attribute values, base/variant OR'd with BLIGHT-index/wheel-depth/effect bits
    /// too, routinely number in the hundreds, and grouping by the raw value once blew this list
    /// (and the matching per-group SceneKit node/material in the 3D preview) up to hundreds of
    /// rows/nodes for a real KCL, which is what was actually behind "the app crashed when I edited
    /// a kcl flag", not a crash so much as a UI/scene-graph explosion that made the app
    /// unresponsive. Variant is included (unlike the upper BLIGHT/wheel/effect bits) because it's
    /// independently pickable now (see `kclFlagMenu`'s per-base-type variant submenus), grouping
    /// it away with those bits meant picking a different variant for a triangle changed nothing
    /// anyone could see: same row, same 3D color, same count. A base+variant group is only split
    /// further into separate rows for the exact attribute values someone has explicitly linked a
    /// texture to (`box.flagTextureOverrides`, set from the "Edit Triangle" panel's per-exact-flag
    /// texture menu), so two textures sharing a base+variant but differing in BLIGHT-index bits
    /// show as two rows, without the row count ever growing on its own the way full-attribute
    /// grouping did.
    private var surfaceRows: [SurfaceRow] {
        var rows: [SurfaceRow] = []
        // Imported triangles are listed by the material (texture) they came from.
        let byMaterial = Dictionary(grouping: box.doc.triangles.filter { $0.material != nil }, by: { $0.material! })
        for (name, group) in byMaterial.sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending }) {
            let keys = Set(group.map { box.doc.surfaceKey($0.attribute) })
            let surface = keys.count == 1 ? box.doc.flagName(keys.first!) : "Mixed surfaces"
            rows.append(SurfaceRow(target: .material(name), baseType: box.doc.surfaceKey(group[0].attribute), count: group.count, label: "\(name) (\(surface))"))
        }
        let byBase = Dictionary(grouping: box.doc.triangles.filter { $0.material == nil }, by: { box.doc.surfaceKey($0.attribute) })
        for (base, group) in byBase.sorted(by: { $0.key < $1.key }) {
            let byAttribute = Dictionary(grouping: group, by: { $0.attribute })
            let overriddenAttributes = byAttribute.keys.filter { box.flagTextureOverrides[$0] != nil }.sorted()
            let defaultCount = byAttribute.filter { !overriddenAttributes.contains($0.key) }.reduce(0) { $0 + $1.value.count }
            if defaultCount > 0 || overriddenAttributes.isEmpty {
                rows.append(SurfaceRow(target: .base(base), baseType: base, count: defaultCount, label: box.doc.flagName(base)))
            }
            for attribute in overriddenAttributes {
                rows.append(SurfaceRow(target: .override(attribute), baseType: base, count: byAttribute[attribute]?.count ?? 0, label: box.doc.flagName(attribute)))
            }
        }
        return rows
    }

    /// Writes the collision to a fresh temporary folder as an .obj and asks whether to open it.
    private func exportOBJForEditing() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Revolution Editor KCL \(UUID().uuidString.prefix(8))")
        let url = dir.appendingPathComponent("collision.obj")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try OBJExporter.writeKCL(box.doc.triangles, color: { [bco = box.doc.isBCO] in kclFlagColor($0, bco: bco) }, to: url)
            exportedOBJ = url
        } catch {
            importErrorMessage = error.localizedDescription
        }
    }

    private func openForEditing(_ url: URL) {
        if let editor = ExternalEditorPrefs.modelEditorURL {
            NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Parses the chosen .obj and hands its triangles to `objImportSheet` for the user to assign a
    /// surface type per material to, rather than importing immediately with the old one
    /// automatic-sequential-flag behavior, see `OBJMaterialAssignment`'s doc comment.
    private func importOBJ() {
        PanelPresenter.openFile(configure: {
            $0.allowedContentTypes = ModelFile.contentTypes
        }, completion: beginOBJImport)
    }

    private func beginOBJImport(_ pickedURL: URL?) {
        guard let pickedURL else { return }
        do {
            let (text, url) = try ModelFile.objSource(pickedURL)
            let objTriangles = OBJImporter.parse(text)
            guard !objTriangles.isEmpty else {
                importErrorMessage = "No triangles were found in that model file."
                return
            }
            guard objTriangles.count <= 65535 else {
                importErrorMessage = "That model has \(objTriangles.count) triangles, but KCL prisms are limited to 65535. Simplify the mesh and try again."
                return
            }
            let mtlMaterials = OBJImporter.loadMTLMaterials(objText: text, objURL: url)
            objMaterialAssignments = Self.materialAssignments(for: objTriangles, mtlMaterials: mtlMaterials, objURL: url)
            pendingOBJTriangles = objTriangles
        } catch {
            importErrorMessage = error.localizedDescription
        }
    }

    /// One row per distinct `usemtl` material actually used (in first-seen order), defaulting to
    /// a flag guessed from the material's or its texture's name (`OBJImporter.guessFlag`), plus one more
    /// row for any triangle with no material at all, if the .obj has any (a plain hex field there
    /// replaces the old standalone "fallback flag" text field). Each row's `image` comes from the
    /// .obj's companion .mtl, if it has one and covers that material, see `OBJMaterialAssignment`.
    private static func materialAssignments(for triangles: [OBJImporter.Triangle], mtlMaterials: [String: OBJImporter.MTLMaterial], objURL: URL) -> [OBJMaterialAssignment] {
        var seen: [String] = []
        var seenSet = Set<String>()
        var hasUnnamed = false
        for t in triangles {
            if let name = t.materialName {
                if seenSet.insert(name).inserted { seen.append(name) }
            } else {
                hasUnnamed = true
            }
        }
        func resolveImage(_ materialName: String) -> NSImage? {
            guard let mtl = mtlMaterials[materialName] else { return nil }
            if let path = mtl.diffuseTexturePath {
                let imageURL = objURL.deletingLastPathComponent().appendingPathComponent(path)
                if let image = NSImage(contentsOf: imageURL) { return image }
            }
            if let c = mtl.diffuseColor { return ImageUtil.solidColor(r: c.r, g: c.g, b: c.b) }
            return nil
        }
        var out = seen.map { name in
            OBJMaterialAssignment(materialName: name, hexText: String(OBJImporter.guessFlag(materialName: name, textureName: mtlMaterials[name]?.diffuseTexturePath), radix: 16), image: resolveImage(name))
        }
        if hasUnnamed {
            out.append(OBJMaterialAssignment(materialName: "(no material)", hexText: "0"))
        }
        return out
    }

    /// Review sheet shown after `importOBJ` parses a model, one row per material with a Type
    /// picker (sets the base 5 bits) and a raw hex field (for the variant/effect bits a name alone
    /// can't cover), matching how flags are already edited elsewhere in this editor.
    private var objImportSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Assign Surface Types").font(.title2.bold())
            Text("This model has \(objMaterialAssignments.count) material\(objMaterialAssignments.count == 1 ? "" : "s") (from its usemtl groups). Give each one a collision flag, every triangle using that material becomes that surface type once imported.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Convert Z-up to Y-up (Blender/most DCC tools)", isOn: $convertZUpToYUp)
                .font(.caption)
                .help("Mario Kart Wii uses Y-up coordinates. Most 3D tools (Blender, Maya, etc.) export OBJ in Z-up. Enable this to swap Y/Z axes so floors face up correctly in-game.")
            List($objMaterialAssignments) { $assignment in
                objMaterialRow($assignment)
            }
            .listStyle(.inset)
            .frame(minHeight: 200, idealHeight: 280)
            HStack {
                Spacer()
                Button("Cancel") { cancelOBJImport() }
                Button("Import") { confirmOBJImport() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 480)
    }

    private func objMaterialRow(_ assignment: Binding<OBJMaterialAssignment>) -> some View {
        let currentFlag = UInt16(assignment.wrappedValue.hexText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0
        return HStack {
            Toggle("", isOn: assignment.include).labelsHidden()
                .help("Untick to leave this material's triangles out of the collision.")
            if let image = assignment.wrappedValue.image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 16, height: 16).clipShape(RoundedRectangle(cornerRadius: 3))
                    .help("From this model's companion .mtl file, will be linked as this flag's reference texture on import.")
            }
            Text(assignment.wrappedValue.materialName).font(.caption).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(box.doc.flagName(currentFlag)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            kclFlagMenu(bco: box.doc.isBCO) { newBase in
                // Keep only the BLIGHT-index/wheel-depth/effect bits (8-15) from whatever was
                // typed before; base *and* variant (0-7) come from the menu, a plain base-type
                // button leaves variant at 0, a variant submenu entry sets it explicitly. Masking
                // the menu's own variant bits back out here (as this used to) silently discarded
                // it, so picking e.g. "Solid Fall - Ice" applied "Solid Fall" with whatever
                // variant happened to be there already.
                let merged = box.doc.isBCO ? newBase : (currentFlag & ~UInt16(0xFF)) | (newBase & 0xFF)
                assignment.wrappedValue.hexText = String(merged, radix: 16)
            }
            TextField("hex", text: assignment.hexText).textFieldStyle(.roundedBorder).frame(width: 60)
            if !box.doc.isBCO {
                Toggle("Trick", isOn: Binding(get: { currentFlag & Self.trickBit != 0 },
                                              set: { assignment.wrappedValue.hexText = String($0 ? currentFlag | Self.trickBit : currentFlag & ~Self.trickBit, radix: 16) }))
                    .toggleStyle(.checkbox).font(.caption)
                    .help("Trickable: players can perform a trick off this surface (collision-effect bit 0x2000).")
            }
        }
    }

    private func cancelOBJImport() {
        pendingOBJTriangles = nil
        objMaterialAssignments = []
    }

    private func confirmOBJImport() {
        guard let parsed = pendingOBJTriangles else { return }
        var flagForMaterial: [String: UInt16] = [:]
        var materialTextures: [String: NSImage] = [:]
        var fallbackFlag: UInt16 = 0
        let excluded = Set(objMaterialAssignments.filter { !$0.include }.map(\.materialName))
        let triangles = parsed.filter { !excluded.contains($0.materialName ?? "(no material)") }
        guard !triangles.isEmpty else { importErrorMessage = "Every material is unticked, nothing to import."; return }
        for assignment in objMaterialAssignments where assignment.include {
            let cleaned = assignment.hexText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "0x", with: "")
            let flag = UInt16(cleaned, radix: 16) ?? 0
            if assignment.materialName == "(no material)" {
                fallbackFlag = flag
            } else {
                flagForMaterial[assignment.materialName] = flag
            }
            // The .mtl-resolved image (if any) becomes this material's row texture in the list.
            if let image = assignment.image, assignment.materialName != "(no material)" {
                materialTextures[assignment.materialName] = image
            }
        }
        // Fresh retail thickness/radius (300/250), not the open file's: copying them forward kept
        // KCLs made by the old 30/25 defaults broken forever, items sank through the floor.
        let newDoc = KCLDocument()
        newDoc.bcoSource = box.doc.bcoSource // a .bco stays a .bco
        newDoc.triangles = triangles.map { t in
            let flag = t.materialName.flatMap { flagForMaterial[$0] } ?? fallbackFlag
            var v0 = t.v0, v1 = t.v1, v2 = t.v2
            if convertZUpToYUp {
                // Convert from Z-up (Blender, most DCC tools) to Y-up (Mario Kart Wii):
                // x' = x, y' = z, z' = -y
                func convert(_ v: Vec3) -> Vec3 { Vec3(x: v.x, y: v.z, z: -v.y) }
                v0 = convert(v0); v1 = convert(v1); v2 = convert(v2)
            }
            var triangle = KCLTriangle.facingUp(v0, v1, v2, attribute: flag)
            triangle.material = t.materialName
            return triangle
        }
        box.materialTextures = materialTextures
        box.doc = newDoc
        box.isDirty = true
        selectedTriangleIndex = nil
        bulkFromAttribute = nil
        editRevision += 1
        pushHistory("Import OBJ")
        cancelOBJImport()
    }

    // MARK: Per-triangle editing

    /// Bulk reassignment always targets a whole base+variant surface type (see `surfaceRows`),
    /// even when tapping an override row, selects that row's own first triangle (its exact
    /// attribute for an override row, or the first non-overridden triangle of the base+variant
    /// otherwise).
    /// Removes every triangle a surface row covers, and its reference texture.
    private func rowContains(_ row: SurfaceRow, _ t: KCLTriangle) -> Bool {
        switch row.target {
        case .material(let m): return t.material == m
        case .override(let attribute): return t.material == nil && t.attribute == attribute
        case .base(let base): return t.material == nil && box.doc.surfaceKey(t.attribute) == base && box.flagTextureOverrides[t.attribute] == nil
        }
    }

    private static let trickBit: UInt16 = 0x2000

    private func isTrickable(_ row: SurfaceRow) -> Bool {
        let tris = box.doc.triangles.filter { rowContains(row, $0) }
        return !tris.isEmpty && tris.allSatisfy { $0.attribute & Self.trickBit != 0 }
    }

    private func setTrickable(_ on: Bool, in row: SurfaceRow) {
        for i in box.doc.triangles.indices where rowContains(row, box.doc.triangles[i]) {
            let old = box.doc.triangles[i].attribute
            let new = on ? old | Self.trickBit : old & ~Self.trickBit
            box.doc.triangles[i].attribute = new
            // Overrides are keyed by the full attribute, so carry the texture over to the new key.
            if old != new, let img = box.flagTextureOverrides[old] {
                box.flagTextureOverrides[new] = img
                box.flagTextureOverrideLabels[new] = box.flagTextureOverrideLabels[old]
                box.flagTextureOverrides[old] = nil
                box.flagTextureOverrideLabels[old] = nil
            }
        }
        bulkFromAttribute = nil
        box.isDirty = true
        editRevision += 1
        box.objectWillChange.send()
        pushHistory(on ? "Make \(row.label) Trickable" : "Make \(row.label) Not Trickable")
    }

    private func deleteTriangles(in row: SurfaceRow) {
        box.doc.triangles.removeAll { rowContains(row, $0) }
        setTexture(nil, label: nil, for: row.target)
        selectedTriangleIndex = nil
        connectedSelection = []
        bulkFromAttribute = nil
        box.isDirty = true
        box.objectWillChange.send()
        pushHistory("Delete \(row.label) Triangles")
    }

    private func selectFirst(_ row: SurfaceRow) {
        bulkFromAttribute = row.baseType
        bulkRow = row
        bulkToHexText = String(row.baseType, radix: 16)
        selectedTriangleIndex = box.doc.triangles.firstIndex { rowContains(row, $0) }
    }

    /// Reassigns every triangle whose base+variant matches `bulkFromAttribute` to the exact full
    /// attribute value typed in `bulkToHexText`.
    private func applyBulkReassign() {
        guard let from = bulkFromAttribute else { return }
        let cleaned = bulkToHexText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "0x", with: "")
        guard let newAttribute = UInt16(cleaned, radix: 16) else { return }
        let row = bulkRow.flatMap { $0.baseType == from ? $0 : nil }
        for i in box.doc.triangles.indices where row.map({ rowContains($0, box.doc.triangles[i]) }) ?? (box.doc.surfaceKey(box.doc.triangles[i].attribute) == from) {
            box.doc.triangles[i].attribute = newAttribute
        }
        bulkRow = nil
        bulkFromAttribute = nil
        box.isDirty = true
        editRevision += 1
        box.objectWillChange.send()
        pushHistory("Reassign Surface Type")
    }

    /// Flood-fills out from `clickedIndex` (reported by a click in the 3D preview, see
    /// `KCLScenePreviewView.onTriangleClick`) across triangles that both share its current material
    /// key (the same thing `surfaceRows`/the scene's own per-group nodes key on: an override's exact
    /// attribute, or otherwise the base+variant surface type) and are connected to it, a "magic
    /// wand" selection so a whole contiguous patch (e.g. one lane of road) can be retagged in one go
    /// without touching every other triangle sharing that same flag elsewhere on the track.
    private func selectConnected(from clickedIndex: Int) {
        let triangles = box.doc.triangles
        guard triangles.indices.contains(clickedIndex) else { return }

        func materialKey(_ t: KCLTriangle) -> String {
            if let m = t.material { return "m:" + m }
            return "a:\(box.flagTextureOverrides[t.attribute] != nil ? t.attribute : box.doc.surfaceKey(t.attribute))"
        }
        let targetKey = materialKey(triangles[clickedIndex])

        // Two triangles are "connected" if they share a vertex position, rounded to the nearest
        // whole unit as a small tolerance for triangles authored to share an edge exactly but that
        // drifted by a hair during modeling/export, without merging distinct vertices
        // that just happen to be close together on a real track-scale mesh.
        func vertexKey(_ v: Vec3) -> String { "\(Int(v.x.rounded())),\(Int(v.y.rounded())),\(Int(v.z.rounded()))" }
        var vertexToTriangles: [String: [Int]] = [:]
        for (i, t) in triangles.enumerated() {
            for v in [t.v0, t.v1, t.v2] { vertexToTriangles[vertexKey(v), default: []].append(i) }
        }

        var visited: Set<Int> = [clickedIndex]
        var queue = [clickedIndex]
        while let current = queue.popLast() {
            let t = triangles[current]
            for v in [t.v0, t.v1, t.v2] {
                for neighbor in vertexToTriangles[vertexKey(v), default: []] where !visited.contains(neighbor) {
                    guard materialKey(triangles[neighbor]) == targetKey else { continue }
                    visited.insert(neighbor)
                    queue.append(neighbor)
                }
            }
        }

        connectedSelection = visited
        connectedReassignHexText = String(box.doc.surfaceKey(triangles[clickedIndex].attribute), radix: 16)
        selectedTriangleIndex = clickedIndex
        bulkFromAttribute = nil
    }

    private func applyConnectedReassign() {
        guard !connectedSelection.isEmpty else { return }
        let cleaned = connectedReassignHexText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "0x", with: "")
        guard let newAttribute = UInt16(cleaned, radix: 16) else { return }
        for i in connectedSelection where box.doc.triangles.indices.contains(i) {
            box.doc.triangles[i].attribute = newAttribute
        }
        connectedSelection = []
        box.isDirty = true
        editRevision += 1
        box.objectWillChange.send()
        pushHistory("Reassign Connected Triangles")
    }

    /// Commits a single triangle's attribute, called once, when `HexFlagField` below decides the
    /// user is done editing (Enter or focus loss), not per keystroke. Bumping `editRevision` (and
    /// so rebuilding the whole SceneKit scene) on every single character typed into this field was
    /// the actual cause of the reported "app crashes when I edit a kcl flag": on a real
    /// several-thousand-triangle track mesh, a full scene rebuild fired many times a second while
    /// typing is expensive enough to lock up or crash the app, not just feel slow.
    private func setTriangleAttribute(_ index: Int, _ value: UInt16) {
        guard box.doc.triangles.indices.contains(index) else { return }
        box.doc.triangles[index].attribute = value
        box.isDirty = true
        editRevision += 1
        box.objectWillChange.send()
        pushHistory("Edit Flag")
    }

    private func deleteTriangle(_ index: Int) {
        guard box.doc.triangles.indices.contains(index) else { return }
        box.doc.triangles.remove(at: index)
        selectedTriangleIndex = nil
        bulkFromAttribute = nil
        box.isDirty = true
        editRevision += 1
        box.objectWillChange.send()
        pushHistory("Delete Triangle")
    }
}

/// Surface colours the user picked in the collision editor's list, shared by every KCL/BCO: one
/// "game-SURF=RRGGBB" entry per surface (type + variant), newline-separated in one defaults string,
/// so the editor can observe it with `@AppStorage` and redraw on a change.
enum KCLFlagColors {
    static let defaultsKey = "kclFlagColors"

    static func key(_ attribute: UInt16, bco: Bool) -> String {
        (bco ? "bco-" : "kcl-") + String(format: "%04X", bco ? attribute : attribute & 0xFF)
    }

    static func parse(_ text: String) -> [String: String] {
        Dictionary(text.split(separator: "\n").compactMap { line -> (String, String)? in
            let parts = line.split(separator: "=")
            return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
        }, uniquingKeysWith: { $1 })
    }

    static func custom(_ attribute: UInt16, bco: Bool) -> NSColor? {
        guard let hex = parse(UserDefaults.standard.string(forKey: defaultsKey) ?? "")[key(attribute, bco: bco)],
              let v = UInt32(hex, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// Sets (or with nil, resets to the default hue) one surface's colour.
    static func set(_ color: NSColor?, for attribute: UInt16, bco: Bool) {
        var all = parse(UserDefaults.standard.string(forKey: defaultsKey) ?? "")
        if let c = color?.usingColorSpace(.sRGB) {
            all[key(attribute, bco: bco)] = String(format: "%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
        } else {
            all[key(attribute, bco: bco)] = nil
        }
        UserDefaults.standard.set(all.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n"), forKey: defaultsKey)
    }
}

/// One distinct color per base surface type (0x00-0x1F, see `kclBaseTypeNames`), evenly spaced
/// around the hue wheel rather than picked from a small fixed palette, a prior version reused
/// `NSColor.systemGray` for 9 of the 32 base types (and repeated several other colors 2-4x), so
/// most distinct surface types rendered *identically* in both the 3D preview and the "Surface
/// Types" list, which is what actually lay behind "the KCL editor doesn't show flags [distinctly]
/// by [surface] type", the flags data and rendering were fine, but a third of them shared a
/// color with several others. `base * 7 % 32` (7 and 32 are coprime) reorders the 32 evenly-spaced
/// hues so adjacent base-type indices (which read next to each other in the surface list) don't
/// also land next to each other on the hue wheel.
func kclFlagColor(_ attribute: UInt16, bco: Bool) -> NSColor {
    if let custom = KCLFlagColors.custom(attribute, bco: bco) { return custom }
    let base = Int(bco ? attribute >> 8 : attribute & 0x1F)
    let variant = Int(bco ? attribute & 0x7 : (attribute >> 5) & 0x7)
    let step = (base * 7) % 32
    let hue = CGFloat(step) / 32
    // Variant shades brightness (and a touch of saturation) around the base's own hue, so
    // different variants of the same surface type, now independently visible as their own rows
    // and scene nodes, see `surfaceRows`, read as a family (same hue) while still being visibly
    // distinct from each other, not just from other base types.
    let brightness = 0.65 + 0.25 * (CGFloat(variant) / 7)
    let saturation = 0.55 + 0.15 * (CGFloat(7 - variant) / 7)
    return NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
}

/// A hex field that edits a *local* buffer and only calls `onCommit` when the user finishes (Enter
/// or clicking away), not on every keystroke, see `KCLEditorView.setTriangleAttribute`'s doc
/// comment for why that distinction matters here specifically. The caller re-seeds this by giving
/// it a fresh `.id()` (the selected triangle's index) whenever `initialValue` should change out
/// from under it.
/// A dropdown of every named KCL base surface type (0x00-0x1F, see `kclBaseTypeNames`), for
/// picking a flag by name instead of having to know/type its hex value. Each base type appears
/// exactly once; where the wiki documents what its 8 variant values (bits 5-7) mean, that one
/// entry opens a submenu of its variants instead of being a plain button, so picking e.g. "Solid
/// Fall" then "Ice" sets the flag to base 0x0A with variant 3 in one action rather than requiring
/// the hex field afterward. A base type with no documented variants stays a single button setting
/// variant 0, the raw hex field next to this menu still covers exact/undocumented control.
/// For a Double Dash .bco, the list is MKDD's surface types instead, each with the variants retail courses use.
private func kclFlagMenu(bco: Bool, onSelect: @escaping (UInt16) -> Void) -> some View {
    Menu {
        if bco {
            ForEach(BCO.typeNames.keys.sorted(), id: \.self) { type in
                if let variants = BCO.retailVariants[type], variants.count > 1 || variants.first?.variant != 0 {
                    Menu(BCO.typeNames[type] ?? "Unknown") {
                        ForEach(variants, id: \.variant) { v in
                            Button("Variant \(v.variant). \(v.usedIn)") { onSelect(type << 8 | v.variant) }
                        }
                    }
                } else {
                    Button(BCO.flagName(type << 8)) { onSelect(type << 8) }
                }
            }
        } else {
        ForEach(UInt16(0)...0x1F, id: \.self) { base in
            if let variants = kclVariants(forBase: Int(base)) {
                Menu(kclBaseTypeName(Int(base))) {
                    ForEach(Array(variants.enumerated()), id: \.offset) { variant, name in
                        Button(name) { onSelect(base | (UInt16(variant) << 5)) }
                    }
                }
            } else {
                Button(kclFlagName(base)) { onSelect(base) }
            }
        }
        }
    } label: {
        Image(systemName: "chevron.down.circle")
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .help("Choose a surface type by name")
}

private struct HexFlagField: View {
    let initialValue: UInt16
    let onCommit: (UInt16) -> Void
    @State private var text: String
    @FocusState private var focused: Bool

    init(initialValue: UInt16, onCommit: @escaping (UInt16) -> Void) {
        self.initialValue = initialValue
        self.onCommit = onCommit
        _text = State(initialValue: String(initialValue, radix: 16))
    }

    var body: some View {
        TextField("0", text: $text)
            .textFieldStyle(.roundedBorder)
            .frame(width: 70)
            .focused($focused)
            .onSubmit { commit() }
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
    }

    private func commit() {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "0x", with: "")
        guard let value = UInt16(cleaned, radix: 16), value != initialValue else { return }
        onCommit(value)
    }
}

/// Small `.brres`-decoded texture candidate for the "From .brres/.szs..." texture-link picker.
private struct TextureCandidate: Identifiable {
    var id: String { name }
    let name: String
    let image: NSImage
}

/// Modal grid for picking one decoded texture out of a `.brres`/`.szs` to link to a KCL flag.
private struct TextureCandidatePickerView: View {
    let candidates: [TextureCandidate]
    let onPick: (TextureCandidate) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose a Texture").font(.headline).padding([.top, .horizontal])
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 10) {
                    ForEach(candidates) { c in
                        VStack(spacing: 4) {
                            Image(nsImage: c.image).resizable().aspectRatio(contentMode: .fit)
                                .frame(width: 64, height: 64)
                                .background(Color.secondary.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            Text(c.name).font(.caption2).lineLimit(1)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { onPick(c); dismiss() }
                    }
                }
                .padding()
            }
            Button("Cancel") { dismiss() }.padding([.horizontal, .bottom])
        }
        .frame(width: 360, height: 400)
    }
}

/// Holds a weak reference to the live view so SwiftUI buttons outside the `NSViewRepresentable`
/// can drive its camera, the same `NavigationSCNView` the 3D track preview uses.
@MainActor final class KCLPreviewController: ObservableObject {
    weak var view: NavigationSCNView?
    func zoom(inward: Bool) { view?.zoomStep(inward ? 0.3 : -0.3) }
    func resetView() { view?.perform(.returnToStart) }
}

/// Orbit-able SceneKit viewport for the decoded collision mesh, colored per surface-type group
/// (or textured with that type's linked reference texture, if any), with the currently-selected
/// triangle outlined in white.
/// One node per surface-type group in the preview (see `KCLScenePreviewView.buildScene`), tagged
/// with which real `KCLDocument.triangles` index each of its faces is, in the same order
/// `SCNHitTestResult.faceIndex` counts them, so a click on this node's mesh can resolve back to
/// exactly which document triangle was hit (see `KCLScenePreviewView.bindClickHandler`).
private final class KCLTriangleGroupNode: SCNNode {
    var triangleIndices: [Int] = []
}

private struct KCLScenePreviewView: NSViewRepresentable {
    let document: KCLDocument
    var selectedTriangleIndex: Int?
    var flagTextures: [UInt16: NSImage] = [:]
    var flagTextureOverrides: [UInt16: NSImage] = [:]
    var materialTextures: [String: NSImage] = [:]
    var controller: KCLPreviewController?
    /// Bumped by the editor on every attribute/delete/texture edit, see
    /// `KCLEditorView.editRevision`.
    var editRevision: Int
    var wireframeMode: Bool = false
    var cullMode: KCLCullMode = .none
    var flatShading: Bool = true
    /// The custom surface colours (`KCLFlagColors`), so picking one redraws the scene.
    var customColors: String = ""
    /// Connected same-material triangle patch selected by clicking the preview, see
    /// `KCLEditorView.selectConnected`. Rendered as a distinct outline from `selectedTriangleIndex`.
    var connectedSelection: Set<Int> = []
    /// Reports the document-triangle index a plain click (not a camera-orbit drag) landed on, or
    /// nil if it missed the mesh entirely, wired to `NavigationSCNView.onClick` in `bindClickHandler`.
    var onTriangleClick: ((Int) -> Void)?

    /// See `SceneKitMeshPreviewView` in `SceneKitPreviewView.swift`: `updateNSView` runs on
    /// almost every unrelated SwiftUI update, so without a cheap change check, replacing the
    /// scene each time would silently reset SceneKit's `allowsCameraControl` orbit/zoom state.
    /// `editRevision` (rather than re-scanning every triangle's attribute) is what catches a flag
    /// or texture-link edit that doesn't change the triangle count or first vertex.
    private var signature: String {
        "\(document.triangles.count)|\(document.triangles.first.map { "\($0.v0.x),\($0.v0.y),\($0.v0.z)" } ?? "-")|\(selectedTriangleIndex ?? -1)|\(editRevision)|\(wireframeMode)|\(cullMode.rawValue)|\(flatShading)|\(customColors)|\(connectedSelection.count)|\(connectedSelection.sorted().map(String.init).joined(separator: ","))"
    }

    final class Coordinator {
        var signature: String?
        private var timer: Timer?
        func startTimer(for view: NavigationSCNView) {
            let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak view] _ in view?.tick(dt: 1.0 / 60.0) }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        func stopTimer() { timer?.invalidate(); timer = nil }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NavigationSCNView {
        let view = NavigationSCNView()
        view.clicksWhenNotEditable = true
        view.clicksThroughStacks = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = NSColor.windowBackgroundColor
        view.antialiasingMode = .multisampling4X
        install(buildScene(), in: view, keepCamera: false)
        context.coordinator.signature = signature
        context.coordinator.startTimer(for: view)
        controller?.view = view
        bindClickHandler(view)
        return view
    }

    func updateNSView(_ nsView: NavigationSCNView, context: Context) {
        controller?.view = nsView
        bindClickHandler(nsView)
        guard signature != context.coordinator.signature else { return }
        context.coordinator.signature = signature
        install(buildScene(), in: nsView, keepCamera: true)
    }

    static func dismantleNSView(_ nsView: NavigationSCNView, coordinator: Coordinator) { coordinator.stopTimer() }

    /// Sets the scene and the navigation's start pose/bounds from its camera. An edit rebuilds the
    /// scene, so `keepCamera` carries the user's current view over instead of snapping back.
    private func install(_ scene: SCNScene, in view: NavigationSCNView, keepCamera: Bool) {
        let old = view.pointOfView?.simdWorldTransform
        view.scene = scene
        guard let cam = scene.rootNode.childNodes.first(where: { $0.camera != nil }) else { return }
        let extent = Float(cam.camera!.zFar) / 20
        view.startPose = (cam.position, SCNVector3Zero)
        view.bounds3D = (SIMD3(repeating: -extent / 3.2), SIMD3(repeating: extent / 3.2))
        view.moveSpeed = max(extent / 4, 50)
        view.pointOfView = cam
        if keepCamera, let old { cam.simdWorldTransform = old } else { view.pivot = .zero }
    }

    /// (Re)binds the click callback to the *current* `onTriangleClick` every time this runs --
    /// `makeNSView` only ever runs once, so binding only there would forever call back into
    /// whichever `KCLEditorView` state existed at that first render.
    private func bindClickHandler(_ view: NavigationSCNView) {
        view.onClick = { hit, _ in
            guard let hit, let node = hit.node as? KCLTriangleGroupNode,
                  node.triangleIndices.indices.contains(hit.faceIndex) else { return }
            onTriangleClick?(node.triangleIndices[hit.faceIndex])
        }
    }

    private func buildScene() -> SCNScene {
        let scene = SCNScene()
        let triangles = document.triangles
        guard !triangles.isEmpty else { return scene }

        var bmin = Vec3(x: .greatestFiniteMagnitude, y: .greatestFiniteMagnitude, z: .greatestFiniteMagnitude)
        var bmax = Vec3(x: -.greatestFiniteMagnitude, y: -.greatestFiniteMagnitude, z: -.greatestFiniteMagnitude)
        for t in triangles {
            for v in [t.v0, t.v1, t.v2] {
                bmin = Vec3(x: min(bmin.x, v.x), y: min(bmin.y, v.y), z: min(bmin.z, v.z))
                bmax = Vec3(x: max(bmax.x, v.x), y: max(bmax.y, v.y), z: max(bmax.z, v.z))
            }
        }
        let center = SCNVector3((bmin.x + bmax.x) / 2, (bmin.y + bmax.y) / 2, (bmin.z + bmax.z) / 2)

        // Grouped by base surface type + variant (0-255), not the full 16-bit attribute, see
        // `KCLEditorView.surfaceRows` for why (a real track's full attribute values routinely
        // number in the hundreds, which would mean hundreds of separate nodes/materials here) --
        // except a triangle whose *exact* attribute has an explicit override texture
        // (`flagTextureOverrides`) gets split into its own node/group, mirroring that same list's
        // rows: this only grows with how many overrides someone actually created, not with every
        // distinct raw attribute in the mesh.
        let indexedTriangles = Array(triangles.enumerated())
        // A triangle whose source material has a texture is drawn with that texture instead.
        struct GroupKey: Hashable { let material: String?; let attribute: UInt16 }
        let groups = Dictionary(grouping: indexedTriangles) { pair -> GroupKey in
            let t = pair.element
            if let m = t.material, materialTextures[m] != nil { return GroupKey(material: m, attribute: document.surfaceKey(t.attribute)) }
            return GroupKey(material: nil, attribute: flagTextureOverrides[t.attribute] != nil ? t.attribute : document.surfaceKey(t.attribute))
        }
        for (groupKey, group) in groups {
            let key = groupKey.attribute
            var positions: [SCNVector3] = []
            var triangleIndices: [Int] = []
            positions.reserveCapacity(group.count * 3)
            triangleIndices.reserveCapacity(group.count)
            let linkedTexture = groupKey.material.flatMap { materialTextures[$0] } ?? flagTextureOverrides[key] ?? flagTextures[document.surfaceKey(key)] ?? flagTextures[document.baseType(key)]
            var uvs: [CGPoint] = []
            if linkedTexture != nil { uvs.reserveCapacity(group.count * 3) }
            for (originalIndex, t) in group {
                positions.append(SCNVector3(t.v0.x, t.v0.y, t.v0.z))
                positions.append(SCNVector3(t.v1.x, t.v1.y, t.v1.z))
                positions.append(SCNVector3(t.v2.x, t.v2.y, t.v2.z))
                triangleIndices.append(originalIndex)
                if linkedTexture != nil {
                    // No real UVs exist for collision geometry, a simple world-space planar
                    // projection (tiled every ~5m) is purely a "what does this surface look like"
                    // visual aid, not meant to look seamless.
                    let tile: Float = 500
                    uvs.append(CGPoint(x: CGFloat(t.v0.x / tile), y: CGFloat(t.v0.z / tile)))
                    uvs.append(CGPoint(x: CGFloat(t.v1.x / tile), y: CGFloat(t.v1.z / tile)))
                    uvs.append(CGPoint(x: CGFloat(t.v2.x / tile), y: CGFloat(t.v2.z / tile)))
                }
            }
            let indices: [Int32] = Array(0..<Int32(positions.count))
            var sources = [SCNGeometrySource(vertices: positions)]
            if linkedTexture != nil { sources.append(SCNGeometrySource(textureCoordinates: uvs)) }
            let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
            let geometry = SCNGeometry(sources: sources, elements: [element])
            let material = SCNMaterial()
            if let linkedTexture {
                material.diffuse.contents = linkedTexture
                material.diffuse.wrapS = .repeat
                material.diffuse.wrapT = .repeat
            } else {
                material.diffuse.contents = kclFlagColor(key, bco: document.isBCO)
            }
            material.lightingModel = flatShading ? .constant : .lambert
            switch cullMode {
            case .none:
                material.isDoubleSided = true
            case .clockwise:
                material.isDoubleSided = false
                material.cullMode = .back
            case .counterClockwise:
                material.isDoubleSided = false
                material.cullMode = .front
            }
            material.fillMode = wireframeMode ? .lines : .fill
            geometry.materials = [material]
            let node = KCLTriangleGroupNode()
            node.geometry = geometry
            node.triangleIndices = triangleIndices
            node.position = SCNVector3(-center.x, -center.y, -center.z)
            scene.rootNode.addChildNode(node)
        }

        if let selectedTriangleIndex, triangles.indices.contains(selectedTriangleIndex) {
            let t = triangles[selectedTriangleIndex]
            let outline = [SCNVector3(t.v0.x, t.v0.y, t.v0.z), SCNVector3(t.v1.x, t.v1.y, t.v1.z), SCNVector3(t.v2.x, t.v2.y, t.v2.z)]
            let source = SCNGeometrySource(vertices: outline)
            let element = SCNGeometryElement(indices: [Int32(0), 1, 1, 2, 2, 0], primitiveType: .line)
            let geometry = SCNGeometry(sources: [source], elements: [element])
            let material = SCNMaterial()
            material.diffuse.contents = NSColor.white
            material.lightingModel = .constant
            geometry.materials = [material]
            let node = SCNNode(geometry: geometry)
            node.position = SCNVector3(-center.x, -center.y, -center.z)
            node.renderingOrder = 10
            scene.rootNode.addChildNode(node)
        }

        if !connectedSelection.isEmpty {
            // One combined line geometry for the whole connected patch, rather than a node per
            // triangle, keeps the node count low regardless of how big the clicked patch is.
            var outlinePositions: [SCNVector3] = []
            var outlineIndices: [Int32] = []
            var nextVertex: Int32 = 0
            for i in connectedSelection where triangles.indices.contains(i) {
                let t = triangles[i]
                outlinePositions.append(SCNVector3(t.v0.x, t.v0.y, t.v0.z))
                outlinePositions.append(SCNVector3(t.v1.x, t.v1.y, t.v1.z))
                outlinePositions.append(SCNVector3(t.v2.x, t.v2.y, t.v2.z))
                outlineIndices.append(contentsOf: [nextVertex, nextVertex + 1, nextVertex + 1, nextVertex + 2, nextVertex + 2, nextVertex])
                nextVertex += 3
            }
            let source = SCNGeometrySource(vertices: outlinePositions)
            let element = SCNGeometryElement(indices: outlineIndices, primitiveType: .line)
            let geometry = SCNGeometry(sources: [source], elements: [element])
            let material = SCNMaterial()
            material.diffuse.contents = NSColor.cyan
            material.lightingModel = .constant
            geometry.materials = [material]
            let node = SCNNode(geometry: geometry)
            node.position = SCNVector3(-center.x, -center.y, -center.z)
            node.renderingOrder = 10
            scene.rootNode.addChildNode(node)
        }

        let span = max(bmax.x - bmin.x, max(bmax.y - bmin.y, bmax.z - bmin.z))
        let radius = span.isFinite && span > 0 ? span * 1.6 : 500
        let camera = SCNCamera()
        camera.zFar = Double(radius * 20)
        camera.zNear = Double(max(radius * 0.01, 0.1))
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, radius * 0.6, radius)
        cameraNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(cameraNode)
        return scene
    }
}
