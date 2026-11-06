import SwiftUI
import UniformTypeIdentifiers

import Combine

/// Resolves a `.szs` window's session from the id the `WindowGroup(for: UUID.self)` in
/// `RevolutionIDEApp` hands it. See `SZSArchiveView` for why a dedicated window is now the
/// exception rather than the default, most archives open as a Workbench tab instead.
struct SZSWindowContainerView: View {
    @EnvironmentObject var workbench: WorkbenchState
    let id: UUID?

    var body: some View {
        if let id, let session = workbench.szsWindowSessions[id] {
            SZSWindowView(session: session)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "shippingbox").font(.system(size: 32)).foregroundStyle(.tertiary)
                Text("This archive is no longer available.").foregroundStyle(.secondary)
                Text("Close this window and reopen the file.").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// One `.szs`/`.arc` archive shown in its own dedicated OS window, only when the user explicitly
/// asked for that via "Open in New Window" (see `SZSArchiveView`'s context menu). Double-clicking
/// an archive opens it as a Workbench tab by default instead, alongside every other file; this is
/// just a thin window-chrome wrapper around the same `SZSArchiveView` content the tab case uses.
struct SZSWindowView: View {
    @EnvironmentObject var workbench: WorkbenchState
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var session: SZSWindowSession
    /// See `SZSArchiveView.box`'s doc comment for why this needs to be observed directly rather
    /// than read through `session.box`.
    @ObservedObject private var box: SZSDocumentBox

    init(session: SZSWindowSession) {
        self.session = session
        self.box = session.box
    }

    var body: some View {
        SZSArchiveView(box: box)
            .navigationTitle(session.title)
            .toolbar {
                ToolbarItem {
                    Button {
                        NotificationCenter.default.post(name: .szsFlushPendingEdits, object: nil)
                        workbench.saveSZSWindow(session)
                    } label: { Label("Save", systemImage: "square.and.arrow.down") }
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

/// Tree-on-the-left, content-on-the-right view for one archive's contents, shared by the
/// dedicated SZS window (`SZSWindowView`, for archives explicitly opened "in a new window") and a
/// Workbench tab (`WorkbenchView`'s `.szs` case, the default for double-clicking an archive; see
/// `WorkbenchState.openArchiveAsTab`). A nested archive found inside opens as another Workbench
/// tab by default too, recursively; right-clicking it (here, or at the top level in the Project
/// Navigator) still offers "Open in New Window" for the old tree-in-its-own-window layout.
///
/// Doesn't handle `pendingSZSWindowID`/`pendingNSMBWWindowID` itself, whichever ambient window
/// this view is currently inside (`WorkbenchView` for the tab case, `SZSWindowView` for the
/// dedicated-window case) already does, so a nested "Open in New Window" pops a real window
/// either way without this view needing to know which one it's in.
struct SZSArchiveView: View {
    @EnvironmentObject var workbench: WorkbenchState
    /// `SZSWindowView`/the Workbench tab both hold this as their own `@ObservedObject` too and
    /// pass the same instance in, `box` is a class, so edits here are visible there immediately;
    /// this view just also needs to observe it directly to redraw when the tree/dirty state
    /// changes (see the identical reasoning on `SZSWindowView.box`).
    @ObservedObject var box: SZSDocumentBox

    @State private var selection: U8Node?
    @State private var showInfo = false
    @State private var showVerify = false
    @State private var pendingDelete: U8Node?
    @AppStorage("showArchiveInfoButton") private var showArchiveInfoButton = true
    @State private var showScale = false
    @AppStorage("showPlatformTags") private var showPlatformTags = true
    @AppStorage("confirmBeforeDelete") private var confirmBeforeDelete = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                headerBar
                AutoHistoryControls(initial: U8Archive.serialize(box.root), changes: box.objectWillChange,
                                    snapshot: { U8Archive.serialize(box.root) },
                                    restore: { data in
                                        guard let root = try? U8Archive.parse(data) else { return }
                                        root.isRARC = box.root.isRARC // snapshots are U8; keep saving as RARC
                                        box.root = root
                                        box.isDirty = true
                                    })
                    .padding(.trailing, 8)
            }
            Divider()
            HSplitView {
                treeList
                    .frame(minWidth: 220, idealWidth: 280)
                detailPane
                    .frame(minWidth: 420)
            }
        }
        .alert(
            pendingDelete.map { "Delete “\($0.name)”?" } ?? "",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let pendingDelete { delete(pendingDelete) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            if pendingDelete?.isDirectory == true {
                Text("This folder and everything inside it will be removed from the archive.")
            }
        }
    }

    private var headerBar: some View {
        HStack {
            Text("\(countFiles(box.root)) files").font(.caption).foregroundStyle(.secondary)
                .help("A .szs/.arc is just a folder of files (models, textures, course data, ...) packed into one compressed archive, browse it like any folder below and double-click a file to edit it in place.")
            Spacer()
            if showArchiveInfoButton {
                Button { showInfo.toggle() } label: { Label("Info", systemImage: "info.circle") }
                    .help("Learn about what files belong in each type of .szs archive")
                    .popover(isPresented: $showInfo) { SZSInfoPopoverView() }
            }
            Button { showVerify.toggle() } label: { Label("Verify Archive", systemImage: "checkmark.seal") }
                .help("Check whether this archive has what a specific kind of mod (Mario Kart Wii custom track, NSMBW custom level, ...) needs to actually load in-game.")
                .popover(isPresented: $showVerify) { ModVerifyView(root: box.root) }
            let doubleDash = box.root.children.contains { $0.name.lowercased().hasSuffix("_course.bol") || $0.name.lowercased().hasSuffix("_course.bco") }
            if doubleDash || box.root.children.contains(where: { $0.name == "course.kmp" || $0.name == "course.kcl" }) {
                Button { showScale.toggle() } label: { Label("Scale Track...", systemImage: "arrow.up.left.and.arrow.down.right") }
                    .help("Make the whole track bigger or smaller: the course, sky and minimap models, the collision and every course-data point scale together so they stay lined up.")
                    .popover(isPresented: $showScale) { TrackScaleView(onDone: { showScale = false },
                                                                       note: doubleDash ? "Double Dash fixes each slot's minimap area in the game itself, so a scaled track may no longer line up with its minimap. Redraw it with Mario Kart: Double Dash!! > Minimap Editor afterwards." : nil) { factor, objects in
                        _ = try TrackScaler.scale(archive: box.root, by: factor, objects: objects)
                        box.isDirty = true
                        box.objectWillChange.send()
                    } }
            }
            Button { addFiles(to: box.root) } label: { Label("Add File...", systemImage: "doc.badge.plus") }
                .help("Add one or more files to the archive's top level")
            Button { pasteInto(box.root) } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                .help("Paste file(s) copied in Finder or the Project Navigator into the archive's top level")
                .disabled(!canPaste)
            Button { newFolder(in: box.root) } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                .help("Add a subfolder inside the archive's currently selected folder (or the top level, if nothing's selected).")
            Toggle(isOn: Binding(get: { box.wasCompressed }, set: { box.wasCompressed = $0; box.isDirty = true })) {
                Label("Yaz0 Compress", systemImage: "arrow.down.circle")
            }
            .toggleStyle(.button)
            .font(.caption)
            .help("Yaz0 is Nintendo's compression for .szs/.arc archives. Leave this on to save a smaller compressed file matching what the game expects, turn it off only if you specifically need an uncompressed copy.")
        }
        .padding(8)
    }

    // MARK: Tree (left)

    private var treeList: some View {
        List(selection: $selection) {
            OutlineGroup(box.root.children, id: \.id, children: \.childrenOrNil) { node in
                row(node).tag(node)
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func row(_ node: U8Node) -> some View {
        HStack {
            Image(systemName: node.isDirectory ? "folder" : ProjectNavigatorView.fileIcon(extension: (node.name as NSString).pathExtension))
            Text(node.name)
            Spacer()
            if !node.isDirectory {
                Text(ByteCountFormatter.string(fromByteCount: Int64(node.data?.count ?? 0), countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard !node.isDirectory, isArchive(node) else { return }
            openNested(node, forceNewWindow: false)
        }
        .contextMenu {
            if !node.isDirectory {
                if isArchive(node) {
                    Button("Open") { openNested(node, forceNewWindow: false) }
                    Button("Open in New Window") { openNested(node, forceNewWindow: true) }
                    Divider()
                }
                Button("Extract...") { extract(node) }
                Button("Replace...") { replace(node) }
                Divider()
            } else {
                Button("Add File...") { addFiles(to: node) }
                Button("Paste") { pasteInto(node) }.disabled(!canPaste)
                Button("New Folder") { newFolder(in: node) }
                Divider()
            }
            Button("Delete", role: .destructive) {
                if confirmBeforeDelete { pendingDelete = node } else { delete(node) }
            }
        }
    }

    /// Same identifier `ProjectNavigatorView`'s Copy/Paste and drag-and-drop use for a copied
    /// archive entry, reading it here is what lets a folder (or file) copied from one archive's
    /// Project Navigator row get pasted straight into a *different* archive's own editor view.
    private static let archiveEntryPasteboardType = NSPasteboard.PasteboardType(UTType.revolutionIDEArchiveEntry.identifier)

    /// Whether `NSPasteboard.general` currently holds something Paste here can use, a copied
    /// archive entry (file or folder, from any archive's Project Navigator row), or one or more
    /// real file `URL`s (Finder's own Copy, or this app's "Copy" on a real file).
    private var canPaste: Bool {
        let pb = NSPasteboard.general
        if pb.data(forType: Self.archiveEntryPasteboardType) != nil { return true }
        return pb.canReadObject(forClasses: [NSURL.self], options: nil)
    }

    /// "Paste" on the header bar (top level) or a folder row. Tries a copied archive entry first
    /// (via `WorkbenchState.copiedArchiveEntry`, which already deep-copies it, folders included,
    /// unlike a real file paste below) and falls back to whatever real file(s) are on the
    /// pasteboard, same placement/skip-folders rules as `addFiles(to:)`, just for however many
    /// Copy/Finder put there instead of one chosen via a panel.
    private func pasteInto(_ parent: U8Node) {
        let pb = NSPasteboard.general
        if let data = pb.data(forType: Self.archiveEntryPasteboardType),
           let locations = try? JSONDecoder().decode([WorkbenchState.ArchiveEntryLocation].self, from: data) {
            var addedCount = 0
            for location in locations {
                guard let copy = workbench.copiedArchiveEntry(location) else { continue }
                copy.name = uniqueName(copy.name, in: parent)
                copy.parent = parent
                parent.children.append(copy)
                addedCount += 1
            }
            guard addedCount > 0 else { return }
            box.isDirty = true
            box.objectWillChange.send()
            return
        }
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty else { return }
        var addedCount = 0
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
                  let data = try? Data(contentsOf: url) else { continue }
            let node = U8Node(name: uniqueName(url.lastPathComponent, in: parent), isDirectory: false, data: data)
            node.parent = parent
            parent.children.append(node)
            addedCount += 1
        }
        guard addedCount > 0 else { return }
        box.isDirty = true
        box.objectWillChange.send()
    }

    private func isArchive(_ node: U8Node) -> Bool {
        let ext = (node.name as NSString).pathExtension.lowercased()
        return ext == "szs" || ext == "arc" || (node.data.map(Yaz0.isYaz0) ?? false)
    }

    private func openNested(_ node: U8Node, forceNewWindow: Bool) {
        guard let data = node.data else { return }
        if forceNewWindow {
            workbench.openArchiveInNewWindow(data: data, title: node.name, source: .szsEntry(archive: box, node: node))
        } else {
            workbench.openArchiveAsTab(data: data, title: node.name, source: .szsEntry(archive: box, node: node))
        }
    }

    // MARK: Detail (right)

    @ViewBuilder
    private var detailPane: some View {
        if let selection {
            if isArchive(selection) {
                VStack(spacing: 12) {
                    Image(systemName: "shippingbox").font(.system(size: 40)).foregroundStyle(.tertiary)
                    Text("\(selection.name) is itself an archive.").foregroundStyle(.secondary)
                    HStack {
                        Button("Open") { openNested(selection, forceNewWindow: false) }
                        Button("Open in New Window") { openNested(selection, forceNewWindow: true) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NestedEntryView(archive: box, node: selection)
                    .id(selection.id)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "cursorarrow.click").font(.system(size: 32)).foregroundStyle(.tertiary)
                Text("Select a file to view or edit it.").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func countFiles(_ node: U8Node) -> Int {
        node.children.reduce(0) { $0 + ($1.isDirectory ? countFiles($1) : 1) }
    }

    private func extract(_ node: U8Node) {
        PanelPresenter.saveFile(configure: { $0.nameFieldStringValue = node.name }) { url in
            guard let url, let data = node.data else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private func replace(_ node: U8Node) {
        PanelPresenter.openFile { url in
            guard let url, let data = try? Data(contentsOf: url) else { return }
            node.data = data
            box.isDirty = true
        }
    }

    private func addFiles(to parent: U8Node) {
        PanelPresenter.openFile(configure: { $0.canChooseDirectories = false }) { url in
            guard let url, let data = try? Data(contentsOf: url) else { return }
            let node = U8Node(name: uniqueName(url.lastPathComponent, in: parent), isDirectory: false, data: data)
            node.parent = parent
            parent.children.append(node)
            box.isDirty = true
            box.objectWillChange.send()
        }
    }

    private func newFolder(in parent: U8Node) {
        let node = U8Node(name: uniqueName("New Folder", in: parent), isDirectory: true)
        node.parent = parent
        parent.children.append(node)
        box.isDirty = true
        box.objectWillChange.send()
    }

    /// Appends " 2", " 3", ... until `name` doesn't collide with an existing sibling. U8 archives
    /// have no built-in duplicate-name protection, and silently shadowing an existing entry would
    /// be confusing (and, for two files sharing a name, ambiguous about which one actually round-trips).
    private func uniqueName(_ name: String, in parent: U8Node) -> String {
        guard parent.children.contains(where: { $0.name == name }) else { return name }
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if !parent.children.contains(where: { $0.name == candidate }) { return candidate }
            n += 1
        }
    }

    private func delete(_ node: U8Node) {
        node.parent?.children.removeAll { $0 === node }
        if selection === node { selection = nil }
        box.isDirty = true
        box.objectWillChange.send()
    }
}

/// Shows/edits one non-archive entry selected in the tree: a live editor for `.kmp`/`.brres`,
/// otherwise the same raw hex-dump fallback every other unrecognized format gets. Edits write
/// straight back into the archive's in-memory node as they happen, the archive's own Save is
/// what actually persists to disk (or into *its* parent, if this archive is nested).
private struct NestedEntryView: View {
    @EnvironmentObject var workbench: WorkbenchState
    @ObservedObject var archive: SZSDocumentBox
    let node: U8Node

    @State private var parsed: EditorPayload?
    @State private var writeThroughToken: AnyCancellable?
    /// The still-debouncing edit, if any, `nil` once it's actually been written back (whether by
    /// the debounce elapsing naturally or by `flushNow()`). See `flushNow()`'s doc comment.
    @State private var pendingFlush: ((_ sync: Bool) -> Void)?
    @State private var flushWorkItem: DispatchWorkItem?

    var body: some View {
        Group {
            switch parsed {
            case .kmp(let box): KMPEditorView(box: box, source: .szsEntry(archive: archive, node: node))
            case .brres(let box): BRRESEditorView(box: box)
            case .bmg(let box): BMGEditorView(box: box)
            case .tpl(let box): TPLEditorView(box: box)
            case .kcl(let box): KCLEditorView(box: box)
            case .szs(let box): SZSArchiveView(box: box)
            case .nsmbwLevel(let box): NSMBWLevelView(box: box)
            case .brstm(let box): BRSTMEditorView(box: box)
            case .brlyt(let box): BRLYTEditorView(box: box)
            case .brlan(let box): BRLANEditorView(doc: box.doc)
            case .brsar(let box): BRSAREditorView(doc: box.doc)
            case .j3d(let box): J3DEditorView(box: box)
            case .j3dAnimation(let box): J3DAnimationView(box: box)
            case .code(let box): CodeEditorView(box: box)
            case .raw(let box): RawEditorView(box: box, title: node.name)
            case .obj(let box): OBJEditorView(box: box)
            case .mtl(let box): MTLEditorView(box: box)
            case .uiDesign(let box): UIDesignerView(box: box)
            case .nodeGraph(let box): NodeEditorView(box: box)
            case .image(let box): ImageEditorView(box: box)
            case .fields(let box): BinaryFieldsEditorView(box: box)
            case .effect(let box): EffectEditorView(box: box)
            case nil, .loading:
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Parsing \(node.name)...").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: node.id) { parse() }
        .onDisappear { flushNow() }
        .onReceive(NotificationCenter.default.publisher(for: .szsFlushPendingEdits)) { _ in flushNow() }
    }

    /// Delegates the actual "which editor for this extension" decision to
    /// `WorkbenchState.resolvePayload`, the same function the top-level `openFile`/`openDiscEntry`
    /// path uses (see its doc comment). A parse failure here (or `.szs`/`.nsmbwLevel`, which
    /// `SZSArchiveView`'s `isArchive` check already diverts before this view is ever shown for
    /// them) falls back to the raw view, matching this view's own always-permissive behavior
    /// before this was centralized.
    private func parse() {
        let rawData = node.data ?? Data()
        let name = node.name

        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (Data, Bool) in
                let isYaz0 = Yaz0.isYaz0(rawData)
                let data = isYaz0 ? (try? Yaz0.decode(rawData)) ?? rawData : rawData
                return (data, isYaz0)
            }.value

            let data = result.0
            let compress: @Sendable (Data) -> Data = { d in result.1 ? Yaz0.encode(d) : d }
            let source = EditorTab.Source.szsEntry(archive: archive, node: node)
            let payload = (try? await workbench.resolvePayload(name: name, data: data, source: source)) ?? .raw(RawDocumentBox(data: data))
            installWriteThrough(for: payload, compress: compress)
            parsed = payload
        }
    }

    private func installWriteThrough(for payload: EditorPayload, compress: @escaping @Sendable (Data) -> Data) {
        switch payload {
        case .kmp(let box): writeThrough(box.objectWillChange, { box.doc.serialize() }, compress: compress)
        case .brres(let box): writeThrough(box.objectWillChange, { box.doc.serialize() }, compress: compress)
        case .bmg(let box): writeThrough(box.objectWillChange, { box.doc.serialize() }, compress: compress)
        case .kcl(let box): writeThrough(box.objectWillChange, { box.doc.serialize() }, compress: compress)
        case .brlyt(let box): writeThrough(box.objectWillChange, { box.doc.serialize() }, compress: compress)
        case .code(let box): writeThrough(box.objectWillChange, { Data(box.text.utf8) }, compress: compress)
        case .raw(let box): writeThrough(box.objectWillChange, { box.data }, compress: compress)
        case .uiDesign(let box): writeThrough(box.objectWillChange, { box.doc.serialize() }, compress: compress)
        case .nodeGraph(let box): writeThrough(box.objectWillChange, { box.graph.serialize() }, compress: compress)
        case .fields(let box): writeThrough(box.objectWillChange, { box.data }, compress: compress)
        case .tpl, .brstm, .brlan, .brsar, .j3d, .j3dAnimation, .obj, .mtl, .szs, .nsmbwLevel, .image, .effect, .loading:
            break // View-only formats (or, for .szs/.nsmbwLevel/.loading, unreachable here, see this method's doc comment): nothing to write back.
        }
    }

    /// Mirrors edits from the nested box straight back into the archive's node whenever it
    /// changes, so there's no separate "apply" step. The wait itself is a plain `DispatchWorkItem`
    /// timer (not a Combine `.debounce`) specifically so `flushNow()` can force it through early --
    /// a `.debounce`'s internal timer can only be cancelled, which used to silently discard the
    /// pending edit outright whenever this row disappeared (switching to another archive entry) or
    /// the archive was saved before the debounce happened to elapse.
    private func writeThrough(_ publisher: ObservableObjectPublisher, _ serialize: @escaping () -> Data, compress: @escaping @Sendable (Data) -> Data) {
        let delay = UserDefaults.standard.object(forKey: "autoSaveDebounceSeconds") as? Double ?? 0.5
        writeThroughToken = publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak archive, node] in
                // Deferred one more runloop tick, `objectWillChange` fires *before* the
                // underlying `@Published` value actually updates, so reading it synchronously here
                // would capture the stale value.
                DispatchQueue.main.async {
                    pendingFlush = { sync in
                        let rawData = serialize()
                        if sync {
                            // Only reached from `flushNow()`, i.e. right before this row
                            // disappears or the archive saves, a one-off synchronous compress
                            // (not offloaded, unlike the routine debounce-elapsed path below) is
                            // the only way to *guarantee* `node.data` is current before the caller
                            // (Save, or this row going away) proceeds.
                            node.data = compress(rawData)
                            archive?.isDirty = true
                        } else {
                            Task {
                                let finalData = await Task.detached(priority: .userInitiated) { compress(rawData) }.value
                                node.data = finalData
                                archive?.isDirty = true
                            }
                        }
                    }
                    flushWorkItem?.cancel()
                    let workItem = DispatchWorkItem {
                        pendingFlush?(false)
                        pendingFlush = nil
                        flushWorkItem = nil
                    }
                    flushWorkItem = workItem
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
                }
            }
    }

    /// Forces whatever edit is still waiting out its debounce to happen right now, synchronously,
    /// so the archive's `node.data` is guaranteed current before the caller proceeds. Called from
    /// this row's own `onDisappear` (switching to another entry) and from `.szsFlushPendingEdits`
    /// (posted by every Save action just before it actually reads/serializes the archive tree --
    /// `SZSWindowView`'s toolbar Save and `WorkbenchView.save()` for a `.szs` opened as a tab).
    private func flushNow() {
        flushWorkItem?.cancel()
        flushWorkItem = nil
        pendingFlush?(true)
        pendingFlush = nil
    }
}

extension Notification.Name {
    /// Posted just before any Save action reads/serializes a `.szs`/`.arc` archive tree, so every
    /// currently-mounted `NestedEntryView` (at any nesting depth, an archive inside an archive
    /// gets its own instance) flushes its still-debouncing edit first instead of Save racing it.
    static let szsFlushPendingEdits = Notification.Name("SZSArchiveView.flushPendingEdits")
}



/// Popover behind the "Verify Mod" button, picks a target mod type and runs `ModVerifier`
/// against this archive's already-parsed tree, showing per-file pass/fail with details.
private struct ModVerifyView: View {
    let root: U8Node
    @State private var selectedType: ModVerifier.ModType
    @State private var result: ModVerifier.Result?

    init(root: U8Node) {
        self.root = root
        // Start on the battle rules when the archive's course.kmp is a battle arena.
        let isBattle = root.children.first { !$0.isDirectory && $0.name == "course.kmp" }?.data
            .flatMap { try? KMPDocument.parse($0) }.map(BattleArena.isBattle) ?? false
        _selectedType = State(initialValue: root.isRARC ? .mkddCourse : (isBattle ? .mkwiiBattle : .mkwiiCourse))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "checkmark.seal")
                Text("Verify Archive Compatibility").font(.headline)
            }

            Picker("Mod Type", selection: $selectedType) {
                ForEach(ModVerifier.ModType.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .onChange(of: selectedType) { _, _ in result = nil }

            Button("Check") { result = ModVerifier.verify(selectedType, root: root) }

            if let result {
                Divider()
                Label(
                    result.passed
                        ? "This archive has what it needs to work as a \(result.modName) mod."
                        : {
                            let missing = result.checks.filter { !$0.passed && $0.required }.map { $0.label }.joined(separator: ", ")
                            return "This archive is missing: \(missing)"
                        }(),
                    systemImage: result.passed ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
                .foregroundStyle(result.passed ? .green : .red)
                .font(.subheadline.bold())
                .fixedSize(horizontal: false, vertical: true)

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(result.checks) { check in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: check.passed ? "checkmark.circle.fill" : (check.required ? "xmark.circle.fill" : "minus.circle"))
                                    .foregroundStyle(check.passed ? .green : (check.required ? .red : .secondary))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(check.label).font(.caption).bold()
                                    Text(check.detail).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
        .padding()
        .frame(width: 380)
    }
}

struct SZSInfoPopoverView: View {
    var body: some View {
        FormatInfoPopoverView(title: "Archive Types Info", games: Self.games)
    }

    static let games: [GameCategory] = [
        GameCategory(
            name: "Mario Kart Wii",
            platform: .wii,
            archives: [
                ArchiveType(
                    title: "Custom Track / Course Archive (course.szs)",
                    description: "The main archive for a race track, containing its 3D model, collision, and route data. Placed in the 'Race/Course' folder.",
                    files: [
                        ("course.kcl", "Collision data (drives physics and surface types)."),
                        ("course.kmp", "Course map data (checkpoints, routes, objects, respawns)."),
                        ("course_model.brres", "The main visual 3D model for the track."),
                        ("vrcorn_model.brres", "The background/skybox 3D model (optional)."),
                        ("map_model.brres", "The minimap model shown on the screen (optional)."),
                        ("posteffect/posteffect.bpe", "Post-processing effects and lighting (optional)."),
                        ("obj/*.brres", "Custom 3D objects specifically for this track (optional).")
                    ]
                ),
                ArchiveType(
                    title: "Character/Vehicle Archive (e.g. la_bike-mr.szs)",
                    description: "Contains the 3D models and animations for a specific character riding a specific vehicle.",
                    files: [
                        ("driver_model.brres", "The character's 3D model and animations."),
                        ("kart_model.brres", "The vehicle's 3D model and animations."),
                        ("bike_model.brres", "The bike's 3D model and animations.")
                    ]
                ),
                ArchiveType(
                    title: "UI / Menus (MenuSingle.szs, Race.szs, etc)",
                    description: "Archives storing the game's 2D user interfaces, menus, and HUD.",
                    files: [
                        ("*.brlyt", "Layout files defining the placement of UI elements."),
                        ("*.brlan", "Animation files for the UI layouts."),
                        ("*.tpl", "Texture palettes containing images/sprites."),
                        ("*.brfnt", "Fonts (usually in Font.szs).")
                    ]
                ),
                ArchiveType(
                    title: "Common/Shared Objects (Common.szs)",
                    description: "Global items, objects, and particles loaded into every race.",
                    files: [
                        ("item_model.brres", "3D models for item boxes, shells, bananas, etc."),
                        ("obj_model.brres", "Common objects like item boxes, trees, etc."),
                        ("effect/*.breff", "Particle effect configurations."),
                        ("effect/*.breft", "Particle effect textures.")
                    ]
                )
            ]
        ),
        GameCategory(
            name: "Mario Kart: Double Dash!!",
            platform: .gamecube,
            archives: [
                ArchiveType(
                    title: "Course Archive (e.g. baby_course.arc)",
                    description: "Main archive for a race track. MKDD mainly uses uncompressed .arc files instead of .szs.",
                    files: [
                        ("*.bmd / *.bdl", "The visual 3D model and collision geometry for the track."),
                        ("*.bol", "Course map data (similar to KMP: checkpoints, objects, routes)."),
                        ("*.btk", "Texture animation files.")
                    ]
                ),
                ArchiveType(
                    title: "Character/Kart Archive",
                    description: "Models for racers and their vehicles.",
                    files: [
                        ("driver_*.bmd", "The character's 3D model and animations."),
                        ("kart_*.bmd", "The vehicle's 3D model.")
                    ]
                )
            ]
        ),
        GameCategory(
            name: "New Super Mario Bros. Wii",
            platform: .wii,
            archives: [
                ArchiveType(
                    title: "Level Archive (e.g. 01-01.arc)",
                    description: "Contains the raw Level Header data outlining zones, terrain, objects, and backgrounds.",
                    files: [
                        ("LHcd / LHpd", "Custom binary chunks parsed directly by the IDE's level editor.")
                    ]
                ),
                ArchiveType(
                    title: "Tileset / Palette (e.g. Pa1_A.arc)",
                    description: "Contains 3D terrain models and textures used for level geometry.",
                    files: [
                        ("*.brres", "3D tileset models and material data.")
                    ]
                ),
                ArchiveType(
                    title: "World Map Archive (e.g. W1.szs)",
                    description: "3D map layout and pathing for the overworld map screens.",
                    files: [
                        ("*.brres", "World map visual model."),
                        ("*.kcl", "Collision and pathing data for Mario's movement.")
                    ]
                ),
                ArchiveType(
                    title: "Sprite / Object Archive",
                    description: "Enemy and object models loaded dynamically into levels.",
                    files: [
                        ("*.brres", "The sprite's 3D model and animations.")
                    ]
                )
            ]
        ),
        GameCategory(
            name: "Super Mario Galaxy 1 & 2",
            platform: .wii,
            archives: [
                ArchiveType(
                    title: "Stage/Galaxy Archive (e.g. GoodEggGalaxy.arc)",
                    description: "Contains layout data, 3D models, and settings for a galaxy/stage.",
                    files: [
                        ("Stage/stage.bcsv", "Object placement and layout data."),
                        ("Map/map_model.bdl", "The main stage collision/visual model."),
                        ("Light/light.bcsv", "Lighting parameters and configurations."),
                        ("Sound/sound.bcsv", "Audio zones and triggers.")
                    ]
                ),
                ArchiveType(
                    title: "Object/Enemy Archive (e.g. Kuribo.arc)",
                    description: "3D models, animations, and properties for a specific entity/enemy (like a Goomba).",
                    files: [
                        ("*.bdl / *.bmd", "The character/enemy 3D model."),
                        ("*.bck", "Skeletal animation data."),
                        ("*.btk", "Texture animation data.")
                    ]
                ),
                ArchiveType(
                    title: "UI / HUD Archives",
                    description: "Archives containing screen and menu assets.",
                    files: [
                        ("*.brlyt", "Layout data for UI screens."),
                        ("*.brlan", "Animation data for UI screens.")
                    ]
                )
            ]
        ),
        GameCategory(
            name: "Super Mario Sunshine",
            platform: .gamecube,
            archives: [
                ArchiveType(
                    title: "Stage Archive (e.g. bianco0.szs)",
                    description: "Yaz0 compressed U8 archives containing layout and model data for a level/episode.",
                    files: [
                        ("map/map.bmd", "The primary stage model/collision."),
                        ("marobj.bmd", "Additional stage objects."),
                        ("scene/scene.bin", "Object placement and scene setup.")
                    ]
                )
            ]
        ),
        GameCategory(
            name: "Zelda: Twilight Princess / Skyward Sword",
            platform: .wii, // TP is also GameCube but Wii is fine
            archives: [
                ArchiveType(
                    title: "Room/Stage Archive (e.g. R00_00.arc)",
                    description: "Contains level geometry and room-specific objects.",
                    files: [
                        ("dzb / dzs", "Collision and room layout data."),
                        ("bmd / bdl", "Visual geometry and stage models."),
                        ("bck / btk", "Animations for objects within the room.")
                    ]
                ),
                ArchiveType(
                    title: "Event/Cutscene Archive",
                    description: "Event camera and sequence data for game cutscenes.",
                    files: [
                        ("dat / evt", "Event sequence and cutscene scripts."),
                        ("cam", "Camera movement files.")
                    ]
                )
            ]
        )
    ]
}

/// "Scale Track..." popover: one factor applied to every course file at once (see `TrackScaler`).
struct TrackScaleView: View {
    let onDone: () -> Void
    /// Something game-specific to know before scaling (Double Dash's fixed minimap area).
    var note: String? = nil
    /// Applies the factor (and the scale-objects flag) to whatever archive this popover is for.
    let scale: (Float, Bool) throws -> Void
    @State private var factor: Double = 1.5
    @State private var scaleObjects = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Scale Track").font(.headline)
            HStack {
                Text("Scale")
                TextField("Scale", value: $factor, format: .number.precision(.fractionLength(0...3)))
                    .textFieldStyle(.roundedBorder).frame(width: 70)
                Text("x").foregroundStyle(.secondary)
                Stepper("", value: $factor, in: 0.1...10, step: 0.1).labelsHidden()
            }
            Toggle("Scale objects too", isOn: $scaleObjects)
                .help("Also multiplies every object's (GOBJ) own scale, so trees, item boxes and the like grow with the track. Off keeps them their original size, just moved.")
            Text("Scales course, skybox and minimap models, course.kcl and course.kmp (positions, enemy/item point widths, checkpoints, areas, cameras and route speeds) about the world origin. Object models and karts keep their size.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let note { Label(note, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel", action: onDone)
                Button("Scale") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!(factor > 0) || factor == 1)
            }
        }
        .padding()
        .frame(width: 340)
    }

    private func apply() {
        do {
            try scale(Float(factor), scaleObjects)
            onDone()
        } catch let WSError.badStructure(message) {
            error = message
        } catch {
            self.error = error.localizedDescription
        }
    }
}
