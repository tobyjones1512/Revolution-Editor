import SwiftUI
import UniformTypeIdentifiers
import CoreTransferable

/// A file entry's location inside a `.szs`/`.arc`, as a `Transferable` drag payload, lets
/// dragging a file entry *out* of an archive (`ProjectNavigatorView`'s `.itemProvider`/
/// `.dropDestination`) use the same native drag-and-drop machinery as a real file's `URL`, instead
/// of the older `NSItemProvider`-based `onDrag`/`onDrop` (which, on a `List`/`OutlineGroup` row
/// specifically, has a long-standing reputation for missing drag starts/drops intermittently;
/// `.draggable`/`.dropDestination` are the modern, `List`-integrated replacement and don't have
/// that problem). An `NSItemProvider`/`Transferable` can only carry serializable data, not a live
/// `U8Node` reference anyway, the dragged node is a disconnected preview parse (see
/// `ProjectNode.archiveEntryContext`'s doc comment), so this is looked back up by path once
/// dropped, the same way every other archive-entry operation in `WorkbenchState` does.
struct ArchiveEntryDragItem: Codable, Transferable {
    var location: WorkbenchState.ArchiveEntryLocation

    /// `CodableRepresentation` alone only lets this be dropped *inside* this app (another row's
    /// `.dropDestination(for: ArchiveEntryDragItem.self)`). Finder has no way to interpret raw
    /// JSON as a file. `FileRepresentation` adds that: dragging out to Finder (or any other app
    /// expecting a real file) exports the entry's current bytes to a throwaway temp file first.
    /// `Transferable` tries representations in the order they're listed, so an in-app drop still
    /// prefers the cheap `CodableRepresentation` and only Finder-style drops fall through to this.
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .revolutionIDEArchiveEntry)
        FileRepresentation(exportedContentType: .data) { item in
            let data = try item.diskData()
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let fileURL = dir.appendingPathComponent(item.location.pathComponents.last ?? "file")
            try data.write(to: fileURL)
            return SentTransferredFile(fileURL)
        }
    }

    /// Reads this entry's current bytes straight from disk (a fresh, throwaway parse) for
    /// exporting to Finder, this runs in the drag-export machinery, outside `WorkbenchState`, so
    /// it can't consult a live box the way `WorkbenchState.archiveEntryData` does. In practice this
    /// rarely matters: every Project Navigator archive edit auto-saves immediately (see
    /// `WorkbenchState.mutateArchive`), so the on-disk copy is almost always current.
    private func diskData() throws -> Data {
        let raw = try Data(contentsOf: location.archiveURL)
        let (root, _) = try SZS.open(raw)
        guard let entry = root.find(path: location.pathComponents), let data = entry.data else {
            throw WSError.badStructure("Couldn't find that entry in the archive anymore.")
        }
        return data
    }
}

extension UTType {
    static let revolutionIDEArchiveEntry = UTType(exportedAs: "org.revolutioneditor.app.archive-entry")
}

struct ProjectNavigatorView: View {
    @EnvironmentObject var workbench: WorkbenchState
    @AppStorage(GameTools.marioKartWii.defaultsKey) private var marioKartWiiTools = true
    @AppStorage(GameTools.nsmbw.defaultsKey) private var nsmbwTools = true
    @AppStorage(GameTools.marioKartDoubleDash.defaultsKey) private var doubleDashTools = true
    @State private var creatingMapFor: MapModelRequest?
    @State private var shadowing: ShadowMapRequest?
    @State private var doubleDashShadow: DoubleDashShadowRequest?
    @State private var doubleDashMinimap: DoubleDashMinimapRequest?
    @State private var scalingDoubleDash: URL?
    @State private var previewingUI: UIPreviewRequest?
    @State private var portingDoubleDash: DoubleDashPortRequest?
    @State private var portingToDoubleDash: WiiToDoubleDashRequest?
    @State private var scalingTrack: URL?
    @State private var previewTrackError: String?
    @State private var renamingNode: ProjectNode?
    @State private var renameText: String = ""
    @State private var deletingNode: ProjectNode?
    /// The file/folder entry pending a delete confirmation when it's previewed inside a
    /// `.szs`/`.arc` rather than a real filesystem node, `deletingNode` doesn't apply there,
    /// since deleting one goes through `WorkbenchState.deleteArchiveEntry` by path instead of a
    /// `ProjectNode`. Kept as the archive's URL alongside the (disconnected-preview) `U8Node`
    /// purely for the confirmation alert's title/message; the actual delete re-locates the entry
    /// by path (`U8Node.pathFromRoot`) itself.
    @State private var deletingArchiveEntry: (archiveURL: URL, node: U8Node)?
    /// Nodes pending one combined delete confirmation from a multi-selection (see
    /// `multiSelectionMenu`), covers both real files (Trashed) and archive entries (deleted
    /// outright) in the same selection, unlike `deletingNode`/`deletingArchiveEntry` which are
    /// each single-kind.
    @State private var pendingMultiDelete: [ProjectNode]?
    /// Drags currently hovering a row, as [highlighted row id, destination kind, hovered row id] --
    /// drives the drop-target highlight in `rowView`. Keyed per kind and per hovered row so neither
    /// a row's two destinations nor sibling files sharing a parent's highlight clear each other.
    @State private var dropTargets: Set<[String]> = []
    /// Multi-selection, driven natively by `List(selection:)`, `ProjectNode.id` (a path-derived
    /// `String`, see its doc comment) rather than the node itself, since `List` needs a `Hashable`
    /// identity it can diff cheaply across tree rebuilds. Right-clicking a row that's part of a
    /// selection of more than one applies bulk actions to the whole selection (see
    /// `targets(for:)`/`multiSelectionMenu`); right-clicking anything else (including a lone
    /// selected row) acts on just that row, unchanged from before multi-select existed.
    @State private var selectedIDs = Set<String>()
    @AppStorage("confirmBeforeDelete") private var confirmBeforeDelete = true
    /// Bumped by "Mark/Unmark for Hot Swap" to force a redraw, `HotSwapMarks` lives in
    /// `UserDefaults`, not an `@Published` property this view already observes, so nothing else
    /// would tell SwiftUI a row's mark badge is stale. Changing a `@State` this view itself owns
    /// re-invokes `body` (and so every row) regardless of whether this property is read anywhere.
    @State private var hotSwapMarksVersion = 0

    var body: some View {
        Group {
            switch workbench.project {
            case .folder(let root):
                folderTree(root)
            case .discImage(let url, let disc):
                discTree(url: url, disc: disc)
            case nil:
                emptyState
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { folderTabStrip }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Button("Folder...") { chooseFolder() }
                    .help("Open a folder of loose mod files (e.g. an extracted/riivolution-style track or texture pack) as your project.")
                Button("Disc...") { chooseDisc() }
                    .help("Open a Wii/GCN disc image (.iso/.wbfs/.gcm) directly as your project, browse and edit its files like a folder, no separate extraction step needed.")
                if case .folder = workbench.project {
                    Spacer()
                    Button { workbench.refreshFolderTree() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Refresh from disk, picks up files added, removed, or changed in Finder (or another app) since this was last read. Usually automatic; use this if something looks out of date.")
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .padding(6)
        }
        .alert("Rename", isPresented: Binding(get: { renamingNode != nil }, set: { if !$0 { renamingNode = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let renamingNode {
                    if let ctx = renamingNode.archiveEntryContext {
                        workbench.renameArchiveEntry(archiveURL: ctx.archiveURL, pathComponents: ctx.node.pathFromRoot, to: renameText)
                    } else {
                        workbench.renameProjectItem(renamingNode, to: renameText)
                    }
                }
                renamingNode = nil
            }
            Button("Cancel", role: .cancel) { renamingNode = nil }
        }
        .alert(
            deletingNode.map { "Move “\($0.name)” to the Trash?" } ?? "",
            isPresented: Binding(get: { deletingNode != nil }, set: { if !$0 { deletingNode = nil } })
        ) {
            Button("Move to Trash", role: .destructive) {
                if let deletingNode { workbench.deleteProjectItem(deletingNode) }
                deletingNode = nil
            }
            Button("Cancel", role: .cancel) { deletingNode = nil }
        } message: {
            if deletingNode?.isDirectory == true {
                Text("This folder and everything inside it will be moved to the Trash.")
            }
        }
        .alert(
            deletingArchiveEntry.map { "Delete “\($0.node.name)”?" } ?? "",
            isPresented: Binding(get: { deletingArchiveEntry != nil }, set: { if !$0 { deletingArchiveEntry = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let deletingArchiveEntry {
                    workbench.deleteArchiveEntry(archiveURL: deletingArchiveEntry.archiveURL, pathComponents: deletingArchiveEntry.node.pathFromRoot)
                }
                deletingArchiveEntry = nil
            }
            Button("Cancel", role: .cancel) { deletingArchiveEntry = nil }
        } message: {
            if deletingArchiveEntry?.node.isDirectory == true {
                Text("This folder and everything inside it will be removed from the archive.")
            } else {
                Text("This can't be undone unless the archive itself is still unsaved.")
            }
        }
        .alert(
            pendingMultiDelete.map { "Delete \($0.count) items?" } ?? "",
            isPresented: Binding(get: { pendingMultiDelete != nil }, set: { if !$0 { pendingMultiDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let pendingMultiDelete { deleteAll(pendingMultiDelete) }
                pendingMultiDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingMultiDelete = nil }
        } message: {
            Text("Real files are moved to the Trash; entries inside an archive are removed immediately and can't be recovered unless the archive itself is still unsaved.")
        }
    }

    private func beginRename(_ n: ProjectNode) {
        renameText = n.name
        renamingNode = n
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "shippingbox").font(.system(size: 32)).foregroundStyle(.tertiary)
            Text("No project open").foregroundStyle(.secondary)
            Text("Open a folder of mod files or a Wii/GCN disc image (browsed/edited like a folder).")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    private func openNormal(_ url: URL, _ mode: NormalMapSheet.Mode) {
        guard let target = NormalMapTarget.file(url, onChange: { changed in
            workbench.refreshFolderTree()
            workbench.log("Wrote \(changed.lastPathComponent).")
        }) else {
            previewTrackError = "\(url.lastPathComponent) couldn't be read as an image."
            return
        }
        previewTrackError = target.run(mode)
    }

    // MARK: Folder project

    /// The folder tree as nested disclosure groups (not `OutlineGroup`) so rows can be expanded from code.
    private func treeRows(_ nodes: [ProjectNode]) -> AnyView {
        AnyView(ForEach(nodes, id: \.id) { n in
            if let kids = n.childrenOrNil {
                DisclosureGroup(isExpanded: Binding(
                    get: { workbench.navigatorExpanded.contains(n.id) },
                    set: { if $0 { workbench.navigatorExpanded.insert(n.id) } else { workbench.navigatorExpanded.remove(n.id) } }
                )) { treeRows(kids) } label: { rowView(n) }
            } else {
                rowView(n)
            }
        })
    }

    /// One chip per folder opened this session; shown once there's more than one.
    @ViewBuilder private var folderTabStrip: some View {
        if workbench.folderTabs.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(workbench.folderTabs, id: \.self) { url in
                        let active: Bool = { if case .folder(let r) = workbench.project { return r.url == url }; return false }()
                        HStack(spacing: 4) {
                            Image(systemName: "folder").font(.caption2)
                            Text(url.lastPathComponent).lineLimit(1)
                            Button { workbench.closeFolderTab(url) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                                .buttonStyle(.plain).help("Close this folder tab")
                        }
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(active ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12), in: Capsule())
                        .contentShape(Capsule())
                        .onTapGesture { if !active { workbench.openFolder(url: url) } }
                        .help(url.path)
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
            }
            Divider()
        }
    }

    private func folderTree(_ root: ProjectNode) -> some View {
        List(selection: $selectedIDs) {
            treeRows(root.children)
        }
        .onChange(of: selectedIDs) {
            let nodes = selectedNodes()
            workbench.selectedNavigatorNode = nodes.count == 1 ? nodes[0] : nil
        }
        .sheet(item: $creatingMapFor) { CreateMapSheet(request: $0) }
        .sheet(item: $doubleDashShadow) { DoubleDashShadowSheet(request: $0) }
        .sheet(item: $doubleDashMinimap) { DoubleDashMinimapSheet(request: $0) }
        .sheet(isPresented: Binding(get: { scalingDoubleDash != nil }, set: { if !$0 { scalingDoubleDash = nil } })) {
            if let url = scalingDoubleDash {
                TrackScaleView(onDone: { scalingDoubleDash = nil },
                               note: "Double Dash fixes each slot's minimap area in the game itself, so a scaled track may no longer line up with its minimap. Run the Minimap Editor afterwards to redraw it.") { factor, objects in
                    let (root, wasCompressed) = try SZS.open(try Data(contentsOf: url))
                    _ = try TrackScaler.scale(archive: root, by: factor, objects: objects)
                    try SZS.save(root: root, compressed: wasCompressed).write(to: url, options: .atomic)
                    workbench.log("Scaled \(url.lastPathComponent) by \(factor)x.")
                    workbench.refreshFolderTree()
                }
            }
        }
        .sheet(item: $shadowing) { r in ShadowMapSheet(box: r.box, model: r.model, onEdit: { _ in r.save(r.box.doc.serialize()) }) }
        .sheet(item: $previewingUI) { UIPreviewView(request: $0) }
        .sheet(item: $portingDoubleDash) { DoubleDashPortSheet(request: $0).environmentObject(workbench) }
        .sheet(item: $portingToDoubleDash) { WiiToDoubleDashSheet(request: $0).environmentObject(workbench) }
        .sheet(isPresented: Binding(get: { scalingTrack != nil }, set: { if !$0 { scalingTrack = nil } })) {
            if let url = scalingTrack { TrackScaleView(onDone: { scalingTrack = nil }) { factor, objects in
                let (root, wasCompressed) = try SZS.open(try Data(contentsOf: url))
                _ = try TrackScaler.scale(archive: root, by: factor, objects: objects)
                try SZS.save(root: root, compressed: wasCompressed).write(to: url, options: .atomic)
                workbench.log("Scaled \(url.lastPathComponent) by \(factor)x.")
                workbench.refreshFolderTree()
            } }
        }
        .alert("Couldn't Open Preview", isPresented: Binding(get: { previewTrackError != nil }, set: { if !$0 { previewTrackError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(previewTrackError ?? "") }
        .contextMenu {
            Button("New Folder") { workbench.createFolder(in: nil) }
            newFileMenu(in: root.url)
            Divider()
            Button("Paste") { pasteIntoRoot() }.disabled(!canPaste)
        }
        .dropDestination(for: URL.self) { urls, _ in
            workbench.handleProjectNavigatorRootDrop(urls)
            return true
        }
        .dropDestination(for: ArchiveEntryDragItem.self) { items, _ in
            for item in items { workbench.moveArchiveEntryOutToRoot(item.location) }
            return !items.isEmpty
        }
    }

    @ViewBuilder
    private func rowView(_ n: ProjectNode) -> some View {
        let decorated = rowContent(n)
        if n.discContext == nil {
            applyDragSource(applyDropDestinations(decorated, node: n), node: n).tag(n.id)
        } else {
            applyDragSource(decorated, node: n).tag(n.id)
        }
    }

    private func rowContent(_ n: ProjectNode) -> some View {
        HStack {
            Image(systemName: n.isDirectory ? "folder" : icon(for: n.url))
            Text(n.name)
            if let info = hotSwapInfo(for: n), info.marked {
                Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(.yellow)
                    .help(info.target.map { "Marked for Hot Swap, replaces \($0.path.joined(separator: " > ")) (\(HotSwapTargets.discFiles($0).joined(separator: ", ")))" }
                          ?? "Marked for Hot Swap, will replace this file on the base disc")
                if let target = info.target {
                    Text("\u{2192} \(target.title)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let badge = gitBadge(for: n) {
                Text(badge.0).font(.caption2.bold()).foregroundStyle(badge.1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard !n.isDirectory else { return }
            open(n)
        }
        // Clicking the already-selected file again (after switching tab) gives it the menu bar back.
        .simultaneousGesture(TapGesture().onEnded { if selectedIDs == [n.id] { workbench.selectedNavigatorNode = n } })
        .contextMenu {
            let selection = targets(for: n)
            if selection.count > 1 {
                multiSelectionMenu(selection)
            } else if !n.isDirectory {
                Button("Open") { open(n) }
                if isArchiveExtension(n.url.pathExtension) {
                    Button("Open in New Window") { open(n, forceNewWindow: true) }
                }
                if let edit = trackEditAction(for: n) {
                    Button("Edit Track in 3D...", action: edit)
                }
                if n.discContext == nil, n.archiveEntryContext == nil, ModelFile.isModel(n.url) {
                    Divider()
                    Button("Make .brres") { workbench.makeBRRES(fromOBJAt: n.url) }
                }
                if n.discContext == nil, n.archiveEntryContext == nil, WorkbenchState.imageExtensions.contains(n.url.pathExtension.lowercased()) {
                    Divider()
                    Button("Add Normal") { openNormal(n.url, .create) }
                        .help("Makes a normal map from this image and saves it beside it as <name>_n.png.")
                    Button("Apply Normal") { openNormal(n.url, .apply) }
                        .help("Bakes a normal map's relief into this image itself.")
                }
                if n.discContext == nil, n.archiveEntryContext == nil, AudioFileImport.convertibleExtensions.contains(n.url.pathExtension.lowercased()) {
                    Divider()
                    Button("Make .brstm") { workbench.makeBRSTM(fromAudioAt: n.url) }
                        .help("Converts this audio to a looping 32 kHz DSP-ADPCM .brstm beside it, then opens it in the BRSTM editor to set the loop point.")
                }
                if doubleDashTools, n.discContext == nil, n.archiveEntryContext == nil, n.url.lastPathComponent.lowercased().hasSuffix("_course.bmd") {
                    Divider()
                    Menu(GameTools.marioKartDoubleDash.displayName) {
                        Button("Create Shadow Map...") { beginDoubleDashShadow(bmd: n.url) }
                            .help("Bakes sunlight shadows across this track model into its vertex colours, the way retail Double Dash tracks are shaded.")
                    }
                }
                if marioKartWiiTools, n.discContext == nil, n.archiveEntryContext == nil,
                   n.url.pathExtension.lowercased() == "brres" {
                    Divider()
                    Menu(GameTools.marioKartWii.displayName) {
                        Button("Minimap Editor...") { beginCreateMap(n) }
                            .help("Builds a minimap model (map_model.brres) from this course model: pick which textures' meshes to keep, and they're flattened onto one plain white texture.")
                        Button("Create Shadow Map...") { beginShadowMap(n) }
                            .help("Bake sunlight shadows across this track model into a shadow map texture and give its materials a second, shadow pass, as retail courses have.")
                    }
                }
                if n.discContext == nil, n.archiveEntryContext == nil {
                    let ext = n.url.pathExtension.lowercased()
                    // Mario Kart Wii course archives are always `.szs`; NSMBW levels are always
                    // `.arc` (both are the same U8 container either way, but the extension is what
                    // real tracks/levels actually ship as, so it's what picks the menu here).
                    if marioKartWiiTools, ext == "szs" {
                        Divider()
                        Menu(GameTools.marioKartWii.displayName) {
                            Button("Edit Track in 3D...") { beginPreviewTrack(archiveAt: n.url) }
                                .help("Opens a 3D preview of this course: the track, background, and minimap models textured and placed as they'd appear in-game.")
                            Button("Scale Track...") { scalingTrack = n.url }
                                .help("Make the whole track bigger or smaller: the course, skybox and minimap models, the collision and every KMP point scale together so they stay lined up.")
                            Button("Preview UI...") { beginPreviewUI(n) }
                                .help("Shows the screen layouts (.brlyt) stored in this archive with their textures, for UI archives like Scene/UI/Race.szs.")
                            Menu("Port") {
                                Button("To Double Dash...") { portingToDoubleDash = WiiToDoubleDashRequest(url: n.url) }
                                    .help("Makes a Mario Kart: Double Dash!! course (the replaced slot's .arc files) from this track, in a Double Dash Ports folder beside it.")
                            }
                        }
                    } else if doubleDashTools, ext == "arc", isDoubleDashCourse(n.url) {
                        Divider()
                        Menu(GameTools.marioKartDoubleDash.displayName) {
                            Button("Edit Track in 3D...") { beginPreviewTrack(archiveAt: n.url) }
                                .help("Opens this Double Dash track in the 3D track editor (course data from the .bol, collision from the .bco). Saving writes back into this .arc.")
                            Button("Scale Track...") { scalingDoubleDash = n.url }
                                .help("Make the whole track bigger or smaller: the course and sky models, the collision and every course-data point scale together so they stay lined up.")
                            Button("Minimap Editor...") { beginDoubleDashMinimap(n.url) }
                                .help("Redraws this track's minimap (its _map.bti) from the collision: pick which surfaces appear on it.")
                            Button("Create Shadow Map...") { beginDoubleDashShadow(arc: n.url) }
                                .help("Bakes sunlight shadows across the track model into its vertex colours, the way retail Double Dash tracks are shaded.")
                            Menu("Port") {
                                Button("To Mario Kart Wii") { portDoubleDashArchive(n.url) }
                                    .help("Makes a Mario Kart Wii track (.szs) from this Double Dash track, beside it.")
                            }
                        }
                    } else if ["iso", "gcm"].contains(ext), doubleDashTools, GameCubeHotSwap.isGameCubeDisc(n.url) {
                        Divider()
                        Menu(GameTools.marioKartDoubleDash.displayName) {
                            Menu("Port") {
                                Button("To Mario Kart Wii...") { portingDoubleDash = DoubleDashPortRequest(id: n.url.path, isoURL: n.url) }
                                    .help("Makes Mario Kart Wii tracks (.szs) from the courses on this Double Dash disc.")
                            }
                        }
                    } else if nsmbwTools, ext == "arc" {
                        Divider()
                        Menu(GameTools.nsmbw.displayName) {
                            Button("Edit Level") { workbench.openFileAsNSMBWLevel(url: n.url) }
                                .help("Opens this archive's course data in the New Super Mario Bros. Wii level editor.")
                        }
                    }
                }
                if let ctx = n.discContext {
                    Divider()
                    Button("Extract...") { extractFile(node: ctx.node, disc: ctx.disc) }
                } else if let ctx = n.archiveEntryContext {
                    if marioKartWiiTools, n.url.pathExtension.lowercased() == "brres" {
                        Divider()
                        Menu(GameTools.marioKartWii.displayName) {
                            Button("Minimap Editor...") { beginCreateMap(archiveEntry: ctx, node: n) }
                                .help("Builds a minimap model (map_model.brres) from this course model, as a new entry in this archive: pick which textures' meshes to keep, and they're flattened onto one plain white texture.")
                            Button("Create Shadow Map...") { beginShadowMap(archiveEntry: ctx, node: n) }
                                .help("Bake sunlight shadows across this track model into a shadow map texture and give its materials a second, shadow pass, as retail courses have.")
                        }
                    }
                    if marioKartWiiTools, n.url.pathExtension.lowercased() == "szs" {
                        Divider()
                        Menu(GameTools.marioKartWii.displayName) {
                            Button("Edit Track in 3D...") { beginPreviewTrack(archiveEntry: ctx, node: n) }
                                .help("Opens a 3D preview of this course: the track, background, and minimap models textured and placed as they'd appear in-game.")
                        }
                    } else if nsmbwTools, n.url.pathExtension.lowercased() == "arc" {
                        Divider()
                        Menu(GameTools.nsmbw.displayName) {
                            Button("Edit Level") { workbench.openArchiveEntryAsNSMBWLevel(archiveURL: ctx.archiveURL, pathComponents: ctx.node.pathFromRoot) }
                                .help("Opens this archive's course data in the New Super Mario Bros. Wii level editor.")
                        }
                    }
                    Divider()
                    Button("Extract...") { extractArchiveFile(ctx.node) }
                    Button("Rename...") { beginRename(n) }
                    Button("Copy") { copyNode(n) }
                    Button("Duplicate") { workbench.duplicateArchiveEntry(archiveURL: ctx.archiveURL, pathComponents: ctx.node.pathFromRoot) }
                    Divider()
                    Button("Delete", role: .destructive) {
                        if confirmBeforeDelete { deletingArchiveEntry = (ctx.archiveURL, ctx.node) } else { workbench.deleteArchiveEntry(archiveURL: ctx.archiveURL, pathComponents: ctx.node.pathFromRoot) }
                    }
                }
            } else if let ctx = n.archiveEntryContext {
                // A folder previewed inside a .szs/.arc, no "Open"/"Extract", just entry
                // management (dragging files in/out is handled by this row's itemProvider/dropDestination).
                Button("Rename...") { beginRename(n) }
                Button("Copy") { copyNode(n) }
                Button("Duplicate") { workbench.duplicateArchiveEntry(archiveURL: ctx.archiveURL, pathComponents: ctx.node.pathFromRoot) }
                Divider()
                newArchiveEntryMenu(archiveURL: ctx.archiveURL, pathComponents: ctx.node.pathFromRoot)
                Divider()
                Button("Paste") { pasteInto(n) }.disabled(!canPaste)
                Divider()
                Button("Delete", role: .destructive) {
                    if confirmBeforeDelete { deletingArchiveEntry = (ctx.archiveURL, ctx.node) } else { workbench.deleteArchiveEntry(archiveURL: ctx.archiveURL, pathComponents: ctx.node.pathFromRoot) }
                }
            }
            // Disc-/archive-backed nodes' bytes live inside an .iso/.wbfs/.szs/.arc, not
            // at a real path on disk, a plain rename/copy/trash/new-item here doesn't apply to
            // them (see `WorkbenchState`'s doc comment on these operations). Skipped entirely
            // (like everything else above) once a multi-selection's bulk menu already ran.
            if selection.count <= 1, n.discContext == nil, n.archiveEntryContext == nil {
                // A file row always has something above (Open, plus whatever game-tools menus its
                // extension earned) that Show in Finder/Hot Swap aren't part of, separate them
                // rather than letting them run straight on. A folder row has nothing above this
                // point, so no leading divider is needed there.
                if !n.isDirectory { Divider() }
                Button("Show in Finder") { showInFinder(n) }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(n.url.path, forType: .string)
                }
                if let editor = ExternalEditorPrefs.codeEditorURL {
                    Button("Open in \(editor.deletingPathExtension().lastPathComponent)") { ExternalEditorPrefs.openInCodeEditor(n.url) }
                }
                if workbench.isHomebrewProject, case .folder(let root) = workbench.project, n.url.standardizedFileURL.path.hasPrefix(root.url.standardizedFileURL.path + "/") {
                    Button("Add to Homebrew in Dolphin") { workbench.addToDolphinSD(n.url) }
                        .help("Copies this to the app's folder on Dolphin's SD card (Load/WiiSDSync/apps/<name>/), so the app can read it at sd:/apps/<name>/.")
                } else if n.isDirectory, let info = hotSwapInfo(for: n) {
                    // A folder is packed into an archive at Run, then swapped in like a file.
                    let mode = HotSwapFolderModes.mode(for: info.relativePath, project: info.projectRoot)
                    Menu(info.marked ? "Hot Swap: \(info.target?.title ?? n.name + "." + mode.fileExtension)" : "Hot Swap as Archive") {
                        Picker("Pack As", selection: Binding(get: { mode }, set: {
                            HotSwapFolderModes.set($0, for: info.relativePath, project: info.projectRoot); hotSwapMarksVersion &+= 1
                        })) {
                            ForEach(HotSwapFolderPack.allCases) { Text($0.title).tag($0) }
                        }
                        Divider()
                        Button("\(n.name).\(mode.fileExtension)") { setHotSwap(info, target: nil) }
                            .help("Packs this folder and replaces the disc file with that name.")
                        ForEach(enabledHotSwapGames, id: \.self) { game in
                            Menu(game.title) {
                                HotSwapTargetMenu(nodes: HotSwapTargets.menu(for: game)) { setHotSwap(info, target: $0) }
                            }
                        }
                        if info.marked {
                            Divider()
                            Button("Remove from Hot Swap") {
                                HotSwapMarks.setMarked(false, relativePath: info.relativePath, forProject: info.projectRoot)
                                HotSwapTargetMarks.set(nil, for: info.relativePath, project: info.projectRoot)
                                hotSwapMarksVersion &+= 1
                            }
                        }
                    }
                    .help("Every time you Run with Hot Swap, this folder is packed into an archive (as chosen) and loaded in place of the file or track you pick, e.g. a 'My Track' folder as Luigi Circuit.")
                } else if let info = hotSwapInfo(for: n) {
                    // Replace the disc file of the same name, or pick what it replaces in a game.
                    Menu(info.marked ? "Hot Swap: \(info.target?.title ?? n.name)" : "Mark for Hot Swap") {
                        Button(n.name) { setHotSwap(info, target: nil) }
                            .help("Replaces the file with this exact name on the base disc.")
                        ForEach(enabledHotSwapGames, id: \.self) { game in
                            Menu(game.title) {
                                HotSwapTargetMenu(nodes: HotSwapTargets.menu(for: game)) { setHotSwap(info, target: $0) }
                            }
                        }
                        if info.marked {
                            Divider()
                            Button("Remove from Hot Swap") {
                                HotSwapMarks.setMarked(false, relativePath: info.relativePath, forProject: info.projectRoot)
                                HotSwapTargetMarks.set(nil, for: info.relativePath, project: info.projectRoot)
                                hotSwapMarksVersion &+= 1
                            }
                        }
                    }
                }
                Divider()
                if n.isDirectory {
                    Button("New Folder") { workbench.createFolder(in: n) }
                    newFileMenu(in: n.url)
                    Divider()
                    Menu("Make Archive") {
                        ForEach(WiimmArchive.Format.allCases) { format in
                            Button(format.title) { workbench.makeArchive(fromFolderAt: n.url, format: format) }
                        }
                    }
                    .help("Packs this folder's contents into a new archive alongside it, the folder itself is left untouched. .wbz/.wlz need your Mario Kart Wii disc linked in Settings > Games.")
                    if marioKartWiiTools, n.discContext == nil, n.archiveEntryContext == nil,
                       FileManager.default.fileExists(atPath: n.url.appendingPathComponent("course_model.brres").path) {
                        Menu(GameTools.marioKartWii.displayName) {
                            Button("Edit Track in 3D...") { beginPreviewTrack(folderAt: n.url) }
                                .help("Opens this unpacked course folder in the 3D track editor. Saving writes the changed files back into the folder.")
                        }
                    }
                    Divider()
                } else if n.isArchive {
                    newArchiveEntryMenu(archiveURL: n.url, pathComponents: [])
                    Divider()
                }
                Button("Rename...") { beginRename(n) }
                Button("Copy") { copyNode(n) }
                Button("Duplicate") { workbench.duplicateProjectItem(n) }
                if canAcceptDrop(n) {
                    Divider()
                    Button("Paste") { pasteInto(n) }.disabled(!canPaste)
                }
                Divider()
                Button("Delete", role: .destructive) {
                    if confirmBeforeDelete { deletingNode = n } else { workbench.deleteProjectItem(n) }
                }
            }
        }
        .background(dropTargets.contains { $0[0] == n.id } ? Color.accentColor.opacity(0.15) : Color.clear)
    }

    /// Whether `n` is a valid drop target for dragged files: a real folder, a real `.szs`/`.arc`
    /// file (its contents get added as new archive entries), or a folder previewed inside one.
    /// Disc-image nodes aren't, same restriction as rename/delete/duplicate.
    private func canAcceptDrop(_ n: ProjectNode) -> Bool {
        guard n.discContext == nil else { return false }
        if let ctx = n.archiveEntryContext { return ctx.node.isDirectory }
        return n.isDirectory || n.isArchive
    }

    /// The row a drop onto `n` actually lands in, `n` itself for a folder/archive, otherwise the
    /// folder holding it (Finder-style), so that's the row that lights up.
    private func dropHighlightID(_ n: ProjectNode) -> String {
        if canAcceptDrop(n) { return n.id }
        if let ctx = n.archiveEntryContext, let parent = ctx.node.parent {
            return parent.parent == nil ? ctx.archiveURL.path : "\(ctx.archiveURL.path)#\(ObjectIdentifier(parent))"
        }
        return n.url.deletingLastPathComponent().path
    }

    // MARK: Multi-selection

    /// Resolves `selectedIDs` back into the actual `ProjectNode`s currently in the tree, walked
    /// from the project root's already-loaded `children` (never `childrenOrNil`, which can trigger
    /// an archive/disc parse: everything selected is already on-screen, so its ancestors' children
    /// are already loaded, and a search has no business forcing more work than that).
    private func selectedNodes() -> [ProjectNode] {
        guard let root = workbench.projectRoot, !selectedIDs.isEmpty else { return [] }
        var found: [ProjectNode] = []
        func walk(_ node: ProjectNode) {
            if selectedIDs.contains(node.id) { found.append(node) }
            for child in node.children { walk(child) }
        }
        for child in root.children { walk(child) }
        return found
    }

    /// What a context-menu action on row `n` should act on: the whole multi-selection if `n` is
    /// part of one with more than one row (right-clicking any selected row acts on all of them,
    /// same as Finder), otherwise just `n`, so every existing single-row code path above is
    /// unaffected by multi-select ever having been added.
    private func targets(for n: ProjectNode) -> [ProjectNode] {
        guard selectedIDs.contains(n.id), selectedIDs.count > 1 else { return [n] }
        let nodes = selectedNodes()
        return nodes.isEmpty ? [n] : nodes
    }

    /// The bulk equivalent of the single-row Copy/Duplicate/Extract/Delete buttons, shown instead
    /// of them when more than one row is selected. Each real action loops the single-item
    /// operation `WorkbenchState` already exposes rather than adding new bulk APIs there --
    /// Rename has no bulk form (doesn't make sense for more than one item) and Paste stays
    /// single-target since a multi-selection doesn't imply a paste destination.
    @ViewBuilder
    private func multiSelectionMenu(_ nodes: [ProjectNode]) -> some View {
        let extractable = nodes.filter { $0.discContext != nil || ($0.archiveEntryContext != nil && !$0.archiveEntryContext!.node.isDirectory) }
        Text("\(nodes.count) items selected")
        Divider()
        Button("Copy") { copyNodes(nodes) }
        Button("Duplicate") { duplicateNodes(nodes) }
        if !extractable.isEmpty {
            Button("Extract \(extractable.count)...") { extractNodes(extractable) }
        }
        Divider()
        Button("Delete", role: .destructive) {
            if confirmBeforeDelete { pendingMultiDelete = nodes } else { deleteAll(nodes) }
        }
    }

    /// "Copy" for a multi-selection, real files all go on the pasteboard as `URL`s together (so
    /// pasting elsewhere, in this app or Finder, brings all of them); archive entries go on as a
    /// JSON array of `ArchiveEntryLocation`s under the same type `copyNode`'s single-entry version
    /// uses, so `pasteInto`/`pasteIntoRoot` just need to also try decoding an array. A selection
    /// mixing both kinds only copies the real files, archive entries and real files can't
    /// usefully share one paste destination anyway.
    private func copyNodes(_ nodes: [ProjectNode]) {
        let urls = nodes.filter { $0.discContext == nil && $0.archiveEntryContext == nil }.map { $0.url }
        let pb = NSPasteboard.general
        pb.clearContents()
        if !urls.isEmpty {
            pb.writeObjects(urls.map { $0 as NSURL })
            return
        }
        let locations = nodes.compactMap { n -> WorkbenchState.ArchiveEntryLocation? in
            guard let ctx = n.archiveEntryContext else { return nil }
            return WorkbenchState.ArchiveEntryLocation(archiveURL: ctx.archiveURL, pathComponents: ctx.node.pathFromRoot)
        }
        guard !locations.isEmpty, let data = try? JSONEncoder().encode(locations) else { return }
        pb.setData(data, forType: Self.archiveEntryPasteboardType)
    }

    private func duplicateNodes(_ nodes: [ProjectNode]) {
        for n in nodes {
            if let ctx = n.archiveEntryContext {
                workbench.duplicateArchiveEntry(archiveURL: ctx.archiveURL, pathComponents: ctx.node.pathFromRoot)
            } else if n.discContext == nil {
                workbench.duplicateProjectItem(n)
            }
        }
    }

    private func deleteAll(_ nodes: [ProjectNode]) {
        for n in nodes {
            if let ctx = n.archiveEntryContext {
                workbench.deleteArchiveEntry(archiveURL: ctx.archiveURL, pathComponents: ctx.node.pathFromRoot)
            } else if n.discContext == nil {
                workbench.deleteProjectItem(n)
            }
        }
    }

    /// "Extract N..." on a multi-selection, one folder-choose panel, then every extractable node
    /// (a disc file, or a non-directory entry previewed inside an archive) is written into it
    /// under its own name, Finder-style unique-named against anything already there or extracted
    /// earlier in the same batch.
    private func extractNodes(_ nodes: [ProjectNode]) {
        PanelPresenter.openFile(configure: {
            $0.canChooseDirectories = true
            $0.canChooseFiles = false
            $0.canCreateDirectories = true
            $0.prompt = "Extract"
        }) { destination in
            guard let destination else { return }
            var usedNames = Set(((try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []))
            func uniqueName(_ name: String) -> String {
                guard usedNames.contains(name) else { usedNames.insert(name); return name }
                let ext = (name as NSString).pathExtension
                let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
                var i = 2
                while true {
                    let candidate = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
                    if !usedNames.contains(candidate) { usedNames.insert(candidate); return candidate }
                    i += 1
                }
            }
            for n in nodes {
                let destURL = destination.appendingPathComponent(uniqueName(n.name))
                if let ctx = n.discContext {
                    workbench.extractFile(node: ctx.node, disc: ctx.disc, to: destURL)
                } else if let ctx = n.archiveEntryContext, let data = ctx.node.data {
                    try? data.write(to: destURL, options: .atomic)
                }
            }
        }
    }

    /// Accepts a real file (from Finder, or dragged from elsewhere in this same tree) or a file
    /// dragged out of an archive, and routes it to whichever of `WorkbenchState`'s two entry
    /// points applies. `.dropDestination` (native `Transferable` drag-and-drop, `List`/
    /// `OutlineGroup`-integrated) replaced this view's earlier `NSItemProvider`-based `onDrop` --
    /// that older API has a long-standing reputation for missing drops intermittently on `List`
    /// rows specifically, which is exactly what this was seeing.
    private func applyDropDestinations<V: View>(_ view: V, node n: ProjectNode) -> some View {
        let highlight = dropHighlightID(n)
        return view
            .dropDestination(for: URL.self) { urls, _ in
                dropTargets.removeAll()
                workbench.handleProjectNavigatorDrop(urls, onto: n)
                return true
            } isTargeted: { targeted in
                if targeted { dropTargets.insert([highlight, "url", n.id]) } else { dropTargets.remove([highlight, "url", n.id]) }
            }
            .dropDestination(for: ArchiveEntryDragItem.self) { items, _ in
                dropTargets.removeAll()
                for item in items { workbench.moveArchiveEntryOut(item.location, onto: n) }
                return !items.isEmpty
            } isTargeted: { targeted in
                if targeted { dropTargets.insert([highlight, "entry", n.id]) } else { dropTargets.remove([highlight, "entry", n.id]) }
            }
    }

    /// Makes `n` a drag source when it's a real file/folder (as its `URL`) or a file entry inside
    /// an archive (as an `ArchiveEntryDragItem`), everything else (a disc-image entry, or a
    /// folder previewed inside an archive) isn't draggable. `itemProvider` rather than
    /// `draggable`: inside a `List` with a selection, dragging any selected row then carries
    /// every selected row's provider (`draggable` only ever carries the row under the cursor).
    @ViewBuilder
    private func applyDragSource<V: View>(_ view: V, node n: ProjectNode) -> some View {
        if n.discContext == nil, n.archiveEntryContext == nil {
            view.itemProvider { NSItemProvider(object: n.url as NSURL) }
        } else if let ctx = n.archiveEntryContext, !ctx.node.isDirectory {
            let item = ArchiveEntryDragItem(location: .init(archiveURL: ctx.archiveURL, pathComponents: ctx.node.pathFromRoot))
            view.itemProvider {
                let provider = NSItemProvider()
                provider.register(item)
                return provider
            }
        } else {
            view
        }
    }

    /// Opens a folder-tree node, transparently routing through `openDiscEntry` instead of
    /// `openFile` when `n` actually lives inside an inlined `.iso`/`.wbfs` (`n.url` is synthetic
    /// there, not a real path, see `ProjectNode.discContext`). A file inside an inlined
    /// `.szs`/`.arc` similarly has no real path of its own, `ctx.node` here comes from this
    /// view's own disconnected sidebar-preview parse (see `ProjectNode.archiveEntryContext`'s doc
    /// comment), not a live archive box anything can save through, so this routes through
    /// `openArchiveEntry`, which re-locates the equivalent entry inside a real (reused-if-already-
    /// open, or freshly parsed) `SZSDocumentBox` by path and opens *that specific file* directly,
    /// the same way double-clicking a nested archive inside an already-open SZS window already
    /// does (see `SZSWindowView.openNested`), rather than just opening the containing archive's
    /// own tree tab with nothing selected.
    private func open(_ n: ProjectNode, forceNewWindow: Bool = false) {
        if let ctx = n.discContext {
            workbench.openDiscEntry(node: ctx.node, disc: ctx.disc, discURL: ctx.discURL, forceNewWindow: forceNewWindow)
        } else if let ctx = n.archiveEntryContext {
            workbench.openArchiveEntry(archiveURL: ctx.archiveURL, pathComponents: ctx.node.pathFromRoot, forceNewWindow: forceNewWindow)
        } else {
            workbench.openFile(url: n.url, forceNewWindow: forceNewWindow)
        }
    }

    /// Reveals a real Project Navigator item in Finder, selected, only ever called for a node
    /// with a real `url` (`discContext == nil && archiveEntryContext == nil`), never a synthetic
    /// path inside an `.iso`/`.szs`/`.arc`.
    private func showInFinder(_ n: ProjectNode) {
        NSWorkspace.shared.activateFileViewerSelecting([n.url])
    }

    /// The pasteboard type a copied archive entry's `WorkbenchState.ArchiveEntryLocation` is
    /// stored under, the same identifier `ArchiveEntryDragItem`'s `Transferable` conformance
    /// uses for dragging, so "Copy" on an archive entry and dragging it are interchangeable as far
    /// as "Paste"/a drop target are concerned.
    private static let archiveEntryPasteboardType = NSPasteboard.PasteboardType(UTType.revolutionIDEArchiveEntry.identifier)

    /// Right-click "Copy": a real file/folder goes on the pasteboard as its `URL` (so Paste
    /// elsewhere in this app, in Finder, or in any other app all work); a file entry inside a
    /// `.szs`/`.arc` goes on as its `WorkbenchState.ArchiveEntryLocation` instead, since it has no
    /// real file of its own to hand out.
    private func copyNode(_ n: ProjectNode) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let ctx = n.archiveEntryContext {
            let location = WorkbenchState.ArchiveEntryLocation(archiveURL: ctx.archiveURL, pathComponents: ctx.node.pathFromRoot)
            // Always a JSON array, even for one, `pasteInto`/`pasteIntoRoot` only need to
            // handle one shape, shared with `copyNodes`' multi-selection version.
            guard let data = try? JSONEncoder().encode([location]) else { return }
            pb.setData(data, forType: Self.archiveEntryPasteboardType)
        } else if n.discContext == nil {
            pb.writeObjects([n.url as NSURL])
        }
    }

    /// Whether `NSPasteboard.general` currently holds something "Paste" here can use, a copied
    /// archive entry, or one or more real file `URL`s (from this app's own Copy, or Finder's).
    private var canPaste: Bool {
        let pb = NSPasteboard.general
        if pb.data(forType: Self.archiveEntryPasteboardType) != nil { return true }
        return pb.canReadObject(forClasses: [NSURL.self], options: nil)
    }

    /// Right-click "Paste" onto a specific row, same destination logic as a drop (see
    /// `WorkbenchState.handleProjectNavigatorPaste`/`copyArchiveEntry`), just always a copy rather
    /// than possibly a move.
    private func pasteInto(_ n: ProjectNode) {
        let pb = NSPasteboard.general
        if let data = pb.data(forType: Self.archiveEntryPasteboardType),
           let locations = try? JSONDecoder().decode([WorkbenchState.ArchiveEntryLocation].self, from: data) {
            for location in locations { workbench.copyArchiveEntry(location, onto: n) }
            return
        }
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty else { return }
        workbench.handleProjectNavigatorPaste(urls, onto: n)
    }

    /// Right-click "Paste" on the navigator's empty background/root, lands in the project root,
    /// mirroring `pasteInto`.
    private func pasteIntoRoot() {
        let pb = NSPasteboard.general
        if let data = pb.data(forType: Self.archiveEntryPasteboardType),
           let locations = try? JSONDecoder().decode([WorkbenchState.ArchiveEntryLocation].self, from: data) {
            for location in locations { workbench.copyArchiveEntryToRoot(location) }
            return
        }
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty else { return }
        workbench.handleProjectNavigatorPasteToRoot(urls)
    }

    private func isArchiveExtension(_ ext: String) -> Bool {
        let e = ext.lowercased()
        return e == "szs" || e == "arc"
    }

    /// Right-click "New" on a real folder/root, same items as the File > New menu, just
    /// preset to save into `directoryURL` instead of wherever the panel last was.
    @ViewBuilder
    private func newFileMenu(in directoryURL: URL) -> some View {
        Menu("New") { NewFileMenuItems(workbench: workbench, directory: directoryURL) }
    }

    /// Right-click "New" on an archive's own root or a folder previewed inside it, writes
    /// straight in as a new entry (no save panel; there's no real path to choose). Skips the
    /// from-.obj conversions: those need a second file picker chained after this one, not worth
    /// it for the rare case of building a model/collision mesh straight inside an archive.
    @ViewBuilder
    private func newArchiveEntryMenu(archiveURL: URL, pathComponents: [String]) -> some View {
        Menu("New") {
            Button("BRRES (3D Model)") {
                workbench.newArchiveFile(preferredName: "Untitled.brres", archiveURL: archiveURL, pathComponents: pathComponents) { BRRESDocument().serialize() }
            }
            Button("BMG (Message Table)") {
                workbench.newArchiveFile(preferredName: "Untitled.bmg", archiveURL: archiveURL, pathComponents: pathComponents) { BMGDocument().serialize() }
            }
            Button("SZS Archive") {
                workbench.newArchiveFile(preferredName: "Untitled.szs", archiveURL: archiveURL, pathComponents: pathComponents) {
                    SZS.save(root: U8Node(name: "archive", isDirectory: true), compressed: true)
                }
            }
            Button("ARC Archive") {
                workbench.newArchiveFile(preferredName: "Untitled.arc", archiveURL: archiveURL, pathComponents: pathComponents) {
                    SZS.save(root: U8Node(name: "archive", isDirectory: true), compressed: false)
                }
            }
            if marioKartWiiTools {
                Divider()
                Menu(GameTools.marioKartWii.displayName) {
                    Button("KMP (Course Data)") {
                        workbench.newArchiveFile(preferredName: "course.kmp", archiveURL: archiveURL, pathComponents: pathComponents) { KMPDocument().serialize() }
                    }
                    Button("KMP (Battle Arena)") {
                        workbench.newArchiveFile(preferredName: "course.kmp", archiveURL: archiveURL, pathComponents: pathComponents) { BattleArena.template().serialize() }
                    }
                }
            }
            Divider()
            Button("Text File") {
                workbench.newArchiveFile(preferredName: "Untitled.txt", archiveURL: archiveURL, pathComponents: pathComponents) { Data() }
            }
        }
    }

    /// Reads what the model offers before showing the sheet, so a `.brres` this app can't pull
    /// geometry out of says so in the console instead of opening an empty picker.
    private func beginCreateMap(_ n: ProjectNode) {
        guard let options = workbench.mapModelOptions(forBRRESAt: n.url), let data = try? Data(contentsOf: n.url) else { return }
        creatingMapFor = MapModelRequest(id: n.url.path, sourceName: n.url.lastPathComponent, options: options, sourceData: data) { selected in
            workbench.createMapModel(fromBRRESAt: n.url, keeping: selected)
        }
    }

    /// The archive-entry counterpart: the model's bytes already live in memory, and the result
    /// goes back into the same archive folder the source sits in.
    private func beginCreateMap(archiveEntry ctx: (archiveURL: URL, node: U8Node), node n: ProjectNode) {
        guard let data = ctx.node.data,
              let options = workbench.mapModelOptions(inBRRES: data, named: ctx.node.name) else { return }
        let parentComponents = Array(ctx.node.pathFromRoot.dropLast())
        creatingMapFor = MapModelRequest(id: n.id, sourceName: ctx.node.name, options: options, sourceData: data) { selected in
            workbench.createMapModel(fromBRRESData: data, named: ctx.node.name, keeping: selected,
                                     archiveURL: ctx.archiveURL, pathComponents: parentComponents)
        }
    }

    /// A Double Dash course archive's course model, shadowed and written back into the archive.
    private func beginDoubleDashShadow(arc url: URL) {
        do {
            let (root, compressed) = try SZS.open(try Data(contentsOf: url))
            guard let node = root.children.first(where: { $0.name.lowercased().hasSuffix("_course.bmd") }), let bmd = node.data else {
                previewTrackError = "\(url.lastPathComponent) has no course model (*_course.bmd)."
                return
            }
            doubleDashShadow = DoubleDashShadowRequest(name: node.name, bmd: bmd) { data in
                node.data = data
                try SZS.save(root: root, compressed: compressed).write(to: url, options: .atomic)
                workbench.log("Baked shadows into \(node.name) in \(url.lastPathComponent).")
                workbench.refreshFolderTree()
            }
        } catch {
            previewTrackError = error.localizedDescription
        }
    }

    private func beginDoubleDashShadow(bmd url: URL) {
        guard let bmd = try? Data(contentsOf: url) else { previewTrackError = "\(url.lastPathComponent) couldn't be read."; return }
        doubleDashShadow = DoubleDashShadowRequest(name: url.lastPathComponent, bmd: bmd) { data in
            try data.write(to: url, options: .atomic)
            workbench.log("Baked shadows into \(url.lastPathComponent).")
        }
    }

    /// The course's collision and its slot's map area, for the Double Dash minimap editor.
    private func beginDoubleDashMinimap(_ url: URL) {
        do {
            let (root, compressed) = try SZS.open(try Data(contentsOf: url))
            guard let bco = root.children.first(where: { $0.name.lowercased().hasSuffix("_course.bco") })?.data else {
                previewTrackError = "\(url.lastPathComponent) has no collision (*_course.bco) to draw the minimap from."
                return
            }
            let collision = try BCO.parse(bco).triangles
            let slot = MKDDSlots.slot(forRoot: root.name)
            let (minimap, why) = slot.map { DoubleDashDisc.minimap(for: $0) } ?? (nil, "The archive's root folder isn't a Double Dash slot")
            let stem = slot?.fileStem ?? root.name
            doubleDashMinimap = DoubleDashMinimapRequest(archiveName: stem + ".arc", collision: collision, minimap: minimap,
                                                         note: why.map { "\($0), so the map is fitted to the course; markers may not line up in-game. Link your Double Dash disc in Settings > Games for the slot's real area." }) { data in
                let name = stem + "_map.bti"
                if let node = root.children.first(where: { $0.name.lowercased() == name.lowercased() }) { node.data = data } else {
                    let node = U8Node(name: name, isDirectory: false, data: data)
                    node.parent = root
                    root.children.append(node)
                }
                try SZS.save(root: root, compressed: compressed).write(to: url, options: .atomic)
                workbench.log("Redrew \(name) in \(url.lastPathComponent).")
                workbench.refreshFolderTree()
            }
        } catch {
            previewTrackError = error.localizedDescription
        }
    }

    private func beginShadowMap(_ n: ProjectNode) {
        beginShadowMap(data: try? Data(contentsOf: n.url), id: n.id, name: n.url.lastPathComponent) { data in
            do {
                try data.write(to: n.url, options: .atomic)
                workbench.log("Added a shadow map to \(n.url.lastPathComponent).")
                workbench.refreshFolderTree()
            } catch { workbench.report(error) }
        }
    }

    private func beginShadowMap(archiveEntry ctx: (archiveURL: URL, node: U8Node), node n: ProjectNode) {
        beginShadowMap(data: ctx.node.data, id: n.id, name: ctx.node.name) { data in
            workbench.replaceArchiveEntryData(archiveURL: ctx.archiveURL, pathComponents: ctx.node.pathFromRoot, data: data)
        }
    }

    /// Shadows the BRRES's course model (`course`, else its first MDL0) and writes the whole file back.
    private func beginShadowMap(data: Data?, id: String, name: String, save: @escaping (Data) -> Void) {
        guard let data, let doc = try? BRRESDocument.parse(data) else { previewTrackError = "\(name) couldn't be read as a BRRES."; return }
        let models = doc.resources.filter { $0.magic == "MDL0" }
        guard let model = models.first(where: { $0.name == "course" }) ?? models.first else { previewTrackError = "\(name) has no model to shadow."; return }
        shadowing = ShadowMapRequest(id: id, box: BRRESDocumentBox(doc: doc, fileName: name), model: model, save: save)
    }

    /// Reads and unpacks a `.szs`/`.arc` from a real file, so its own dedicated window (see
    /// `WorkbenchState.openTrackPreviewWindow`) has a real `U8Node` tree to pull
    /// `course_model.brres`/`vrcorn_model.brres`/`map_model.brres`/`course.kmp` out of --
    /// `TrackPreviewView` itself does the actual parsing/building, off the main thread.
    private func beginPreviewTrack(archiveAt url: URL) {
        do {
            let (root, wasCompressed) = try SZS.open(try Data(contentsOf: url))
            workbench.openTrackPreviewWindow(TrackPreviewRequest(id: url.path, root: root, sourceName: url.lastPathComponent, save: {
                let data = SZS.save(root: root, compressed: wasCompressed)
                do {
                    try data.write(to: url, options: .atomic)
                    workbench.log("Saved \(url.lastPathComponent).")
                    workbench.refreshFolderTree()
                } catch {
                    workbench.report(error)
                }
            }))
        } catch {
            previewTrackError = error.localizedDescription
        }
    }

    /// An unpacked course folder: its files become the same in-memory tree an `.szs` gives the 3D
    /// editor, and Save writes back only the files that are new or whose bytes changed (so the
    /// rest of the folder, and its modification dates / git status, is left alone).
    private func beginPreviewTrack(folderAt url: URL) {
        let root = U8Node(name: url.lastPathComponent, isDirectory: true)
        var onDisk: [String: Data] = [:]
        func load(_ dir: URL, into node: U8Node, prefix: String) throws {
            let items = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                                                                    options: [.skipsHiddenFiles])
            for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                let path = prefix + item.lastPathComponent
                if values.isDirectory == true {
                    let child = U8Node(name: item.lastPathComponent, isDirectory: true)
                    child.parent = node
                    node.children.append(child)
                    try load(item, into: child, prefix: path + "/")
                } else if values.isRegularFile == true {
                    let data = try Data(contentsOf: item)
                    let child = U8Node(name: item.lastPathComponent, isDirectory: false, data: data)
                    child.parent = node
                    node.children.append(child)
                    onDisk[path] = data
                }
            }
        }
        do {
            try load(url, into: root, prefix: "")
        } catch {
            previewTrackError = error.localizedDescription
            return
        }
        workbench.openTrackPreviewWindow(TrackPreviewRequest(id: url.path, root: root, sourceName: url.lastPathComponent, save: {
            var written: [String] = []
            @MainActor func save(_ node: U8Node, dir: URL, prefix: String) {
                for child in node.children {
                    let url = dir.appendingPathComponent(child.name)
                    let path = prefix + child.name
                    if child.isDirectory {
                        save(child, dir: url, prefix: path + "/")
                    } else if let data = child.data, onDisk[path] != data {
                        do {
                            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                            try data.write(to: url, options: .atomic)
                            onDisk[path] = data
                            written.append(path)
                        } catch {
                            workbench.report(error)
                        }
                    }
                }
            }
            save(root, dir: url, prefix: "")
            workbench.log(written.isEmpty ? "No changes to save in \(url.lastPathComponent)." : "Saved \(written.joined(separator: ", ")) in \(url.lastPathComponent).")
            workbench.refreshFolderTree()
        }))
    }

    /// "Edit Track in 3D" for a course-data file: a `.kmp`/`.bol` inside a course archive opens that
    /// archive; one sitting loose in a folder opens the folder as an unpacked course. Nil for anything else.
    private func trackEditAction(for n: ProjectNode) -> (() -> Void)? {
        let ext = n.url.pathExtension.lowercased()
        guard !n.isDirectory, n.discContext == nil, ext == "kmp" || ext == "bol" else { return nil }
        if let ctx = n.archiveEntryContext {
            guard FileManager.default.fileExists(atPath: ctx.archiveURL.path) else { return nil }
            return { beginPreviewTrack(archiveAt: ctx.archiveURL) }
        }
        let folder = n.url.deletingLastPathComponent()
        return { beginPreviewTrack(folderAt: folder) }
    }

    private func portDoubleDashArchive(_ url: URL) {
        guard let data = try? Data(contentsOf: url), let wallStrip = WallStripPicker.ask() else { return }
        workbench.portFromDoubleDash([(url.deletingPathExtension().lastPathComponent, data)], to: url.deletingLastPathComponent(), wallStrip: wallStrip)
    }

    /// A Double Dash course archive: a RARC (usually Yaz0-compressed). NSMBW's `.arc` levels are U8.
    private func isDoubleDashCourse(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url), let head = try? handle.read(upToCount: 0x20) else { return false }
        try? handle.close()
        if head.count >= 4, head.asciiString(at: 0, length: 4) == "RARC" { return true }
        // Yaz0: peek at the first decompressed bytes (the literal run right after the 16-byte header).
        return head.count >= 0x15 && head.asciiString(at: 0, length: 4) == "Yaz0" && head.asciiString(at: 0x11, length: 4) == "RARC"
    }

    private func beginPreviewUI(_ n: ProjectNode) {
        do {
            let (root, _) = try SZS.open(try Data(contentsOf: n.url))
            previewingUI = UIPreviewRequest(id: n.url.path, sourceName: n.url.lastPathComponent, root: root)
        } catch {
            previewTrackError = error.localizedDescription
        }
    }

    /// The archive-entry counterpart, for a `.szs`/`.arc` nested inside another archive.
    private func beginPreviewTrack(archiveEntry ctx: (archiveURL: URL, node: U8Node), node n: ProjectNode) {
        guard let data = ctx.node.data else { return }
        do {
            let (root, wasCompressed) = try SZS.open(data)
            let pathComponents = ctx.node.pathFromRoot
            workbench.openTrackPreviewWindow(TrackPreviewRequest(id: n.id, root: root, sourceName: ctx.node.name, save: {
                let newData = SZS.save(root: root, compressed: wasCompressed)
                workbench.replaceArchiveEntryData(archiveURL: ctx.archiveURL, pathComponents: pathComponents, data: newData)
            }))
        } catch {
            previewTrackError = error.localizedDescription
        }
    }

    /// Whether `n` is eligible for Hot Swap marking (a real, non-directory project file, not
    /// inside a disc image/archive, which have no real path Dolphin's Riivolution patch could
    /// point `external` at) and, if so, its disc-relative path and current marked state. `nil`
    /// return means "don't show the Mark/Unmark item or badge for this row at all".
    /// Games whose tools are switched on (Settings > Games), in menu order.
    private var enabledHotSwapGames: [HotSwapTargets.Game] {
        [(HotSwapTargets.Game.marioKartWii, marioKartWiiTools), (.marioKartDoubleDash, doubleDashTools), (.nsmbw, nsmbwTools)].filter(\.1).map(\.0)
    }

    private func setHotSwap(_ info: (projectRoot: URL, relativePath: String, marked: Bool, target: HotSwapTargets.Target?), target: HotSwapTargets.Target?) {
        HotSwapMarks.setMarked(true, relativePath: info.relativePath, forProject: info.projectRoot)
        HotSwapTargetMarks.set(target, for: info.relativePath, project: info.projectRoot)
        hotSwapMarksVersion &+= 1
    }

    private func hotSwapInfo(for n: ProjectNode) -> (projectRoot: URL, relativePath: String, marked: Bool, target: HotSwapTargets.Target?)? {
        _ = hotSwapMarksVersion // read so SwiftUI redraws rows when marks change
        guard n.discContext == nil, n.archiveEntryContext == nil,
              case .folder(let root) = workbench.project else { return nil }
        var relative = n.url.standardizedFileURL.path
        let rootPath = root.url.standardizedFileURL.path
        guard relative.hasPrefix(rootPath) else { return nil }
        relative.removeFirst(rootPath.count)
        if relative.hasPrefix("/") { relative.removeFirst() }
        guard !relative.isEmpty else { return nil }
        return (root.url, relative, HotSwapMarks.isMarked(relative, forProject: root.url), HotSwapTargetMarks.target(for: relative, project: root.url))
    }

    private func gitBadge(for node: ProjectNode) -> (String, Color)? {
        guard let root = workbench.git.repoRoot else { return nil }
        let rel = node.url.path.replacingOccurrences(of: root.path + "/", with: "")
        guard let entry = workbench.git.entries.first(where: { $0.path == rel || $0.path.hasPrefix(rel + "/") }) else { return nil }
        if entry.isUntracked { return ("U", .green) }
        let c = entry.workTreeStatus != " " ? entry.workTreeStatus : entry.indexStatus
        switch c {
        case "M": return ("M", .orange)
        case "A": return ("A", .green)
        case "D": return ("D", .red)
        case "R": return ("R", .purple)
        default: return (String(c), .secondary)
        }
    }

    private func icon(for url: URL) -> String {
        Self.fileIcon(extension: url.pathExtension)
    }

    /// One icon lookup shared by the folder tree, the disc tree, and (via `EditorTab.iconName`)
    /// the tab strip, so a given file type always shows the same icon everywhere it appears --
    /// see each format's own file for what it actually is; icons are chosen to read as that thing
    /// at a glance (a map for course data, a waveform for a music track, ...) rather than reused
    /// arbitrarily.
    static func fileIcon(extension ext: String) -> String {
        switch ext.lowercased() {
        case "szs", "arc": return "shippingbox"
        case "kmp", "bol": return "map"
        case "brres", "obj", "dae", "bmd", "bdl": return "cube.transparent"
        case "bmg": return "text.bubble"
        case "tpl", "bti", "btienv", "btimat", "breft": return "photo.stack"
        case "breff": return "sparkles"
        case "kcl", "bco": return "triangle"
        case "brstm": return "waveform"
        case "brsar": return "waveform.circle"
        case "brlyt": return "rectangle.3.group"
        case "brlan", "btk", "bca": return "play.rectangle"
        case "wad": return "app.badge"
        case "dol", "rel": return "cpu"
        case "iso", "wbfs", "gcm": return "opticaldiscdrive"
        case "bblm", "bblm1", "bdof", "blight", "blmap", "bmm": return "camera.filters"
        case "json": return "curlybraces"
        case "xml": return "chevron.left.slash.chevron.right"
        default:
            if WorkbenchState.imageExtensions.contains(ext.lowercased()) { return "photo" }
            return CodeLanguage.allRecognizedExtensions.contains(ext.lowercased())
                ? "chevron.left.forwardslash.chevron.right" : "doc"
        }
    }

    // MARK: Disc-as-project

    private func discTree(url: URL, disc: any DiscImageReader) -> some View {
        List {
            Section(disc.gameTitle.isEmpty ? disc.gameID : disc.gameTitle) {
                OutlineGroup([disc.root!], children: \.childrenOrNil) { node in
                    HStack {
                        Image(systemName: discIcon(for: node))
                        Text(node.name)
                        Spacer()
                        if node.isFile {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(node.fileSize), countStyle: .file))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        guard node.isFile else { return }
                        workbench.openDiscEntry(node: node, disc: disc, discURL: url)
                    }
                    .contextMenu {
                        if node.isFile {
                            Button("Open") { workbench.openDiscEntry(node: node, disc: disc, discURL: url) }
                            if isArchiveExtension((node.name as NSString).pathExtension) {
                                Button("Open in New Window") { workbench.openDiscEntry(node: node, disc: disc, discURL: url, forceNewWindow: true) }
                            }
                            Divider()
                            Button("Extract...") { extractFile(node: node, disc: disc) }
                        } else {
                            Button(isRoot(node) ? "Extract Whole Disc..." : "Extract Folder...") { extractFolder(node: node, disc: disc) }
                                .disabled(workbench.isExtracting)
                        }
                    }
                }
            }
        }
    }

    private func discIcon(for node: DiscNode) -> String {
        switch node.kind {
        case .root: return "opticaldiscdrive"
        case .partition: return "square.stack.3d.up"
        case .partitionComponent: return "doc.badge.gearshape"
        case .directory: return "folder"
        case .file: return Self.fileIcon(extension: (node.name as NSString).pathExtension)
        }
    }

    private func isRoot(_ node: DiscNode) -> Bool {
        if case .root = node.kind { return true }
        return false
    }

    private func extractFile(node: DiscNode, disc: any DiscImageReader) {
        PanelPresenter.saveFile(configure: { $0.nameFieldStringValue = node.name }) { url in
            guard let url else { return }
            workbench.extractFile(node: node, disc: disc, to: url)
        }
    }

    private func extractArchiveFile(_ node: U8Node) {
        PanelPresenter.saveFile(configure: { $0.nameFieldStringValue = node.name }) { url in
            guard let url, let data = node.data else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private func extractFolder(node: DiscNode, disc: any DiscImageReader) {
        PanelPresenter.openFile(configure: {
            $0.canChooseDirectories = true
            $0.canChooseFiles = false
            $0.canCreateDirectories = true
            $0.prompt = "Extract"
        }) { url in
            guard let url else { return }
            workbench.extractAll(node: node, disc: disc, to: url)
        }
    }

    // MARK: Actions

    private func chooseFolder() {
        PanelPresenter.openFile(configure: { $0.canChooseDirectories = true; $0.canChooseFiles = false }) { url in
            if let url { workbench.openFolder(url: url) }
        }
    }

    private func chooseDisc() {
        PanelPresenter.openFile(configure: { $0.allowsOtherFileTypes = true }) { url in
            if let url { workbench.openDiscAsProject(url: url) }
        }
    }
}

/// The nested Hot Swap target menu for one game (cups, classes, racers ... down to the target).
struct HotSwapTargetMenu: View {
    let nodes: [HotSwapTargets.Node]
    let pick: (HotSwapTargets.Target) -> Void

    var body: some View {
        ForEach(nodes) { node in
            switch node {
            case .group(let title, let children):
                Menu(title) { HotSwapTargetMenu(nodes: children, pick: pick) }
            case .target(let target):
                Button(target.title) { pick(target) }
                    .help("Replaces \(HotSwapTargets.discFiles(target).joined(separator: ", ")) on the base disc.")
            }
        }
    }
}

struct ShadowMapRequest: Identifiable {
    let id: String
    let box: BRRESDocumentBox
    let model: BRRESResource
    let save: (Data) -> Void
}
