import Foundation
import Combine
import AppKit
import UniformTypeIdentifiers

/// Drives the Workbench (IDE) window: open tabs, the project navigator, and open/save/close for
/// every supported format. This is the "new" primary experience the app was redesigned around;
/// the original disc-scrubbing tools still exist in full, just as their own separate window (see
/// `AppState` / `DiscScrubberView`).
/// What the Project Navigator sidebar is currently showing: a real folder on disk, or a Wii disc
/// image browsed/edited in place exactly like a folder of files.
enum ProjectSource {
    case folder(ProjectNode)
    case discImage(url: URL, disc: any DiscImageReader)
}

@MainActor final class WorkbenchState: ObservableObject {
    @Published var tabs: [EditorTab] = [] {
        didSet { persistOpenTabsIfNeeded() }
    }
    /// Switching tabs hands the menu bar back to the tab (see `convertTarget`).
    @Published var selectedTabID: UUID? {
        didSet { if oldValue != selectedTabID { selectedNavigatorNode = nil } }
    }
    @Published var project: ProjectSource?
    /// Folders opened as projects this session, shown as tabs above the navigator; `project` is the active one.
    @Published var folderTabs: [URL] = []
    /// Navigator rows (by `ProjectNode.id`) currently expanded.
    @Published var navigatorExpanded: Set<String> = []
    /// "Open archive opens its folder": an archive to reveal (expand to) once its folder has loaded.
    private var pendingReveal: URL?
    static let archiveOpensFolderKey = "archiveOpensFolder"
    @Published var logLines: [String] = ["Revolution Editor, open a file (.szs/.kmp/.brres), a folder, or a Wii/GCN disc image to begin."]
    @Published var errorMessage: String?
    /// Non-nil while a long job runs; `WorkbenchView` shows it in a modal progress dialog.
    @Published var busyMessage: String?
    /// Set by the app menu's "About Revolution Editor" (`RevolutionIDEApp`'s `CommandGroup(replacing:
    /// .appInfo)`), which replaces macOS's bare default About panel, otherwise unaware of
    /// `WorkbenchView`'s own local sheet state. `WorkbenchView` watches this and shows `AboutView`.
    @Published var showAboutSheet = false
    /// New > Skybox > From Game (see `SkyboxFromGameSheet`).
    @Published var skyboxPicker: SkyboxPickerRequest?
    /// File > New > Double Dash > Course from Model: the folder the new slot archives go in.
    @Published var newDoubleDashCourse: NewDoubleDashCourseRequest?
    /// Plain files opened via `openFile`, most-recent-first, trimmed to the "Recent Files to
    /// Remember" setting (`recentFilesLimit`), backs the File > Open Recent menu.
    @Published private(set) var recentFileURLs: [URL] = []
    /// Folders and disc images opened as projects, most-recent-first, the Welcome window's list.
    @Published private(set) var recentProjectURLs: [URL] = []

    /// Every currently-open `.szs`/`.arc` archive window, keyed by id so the `WindowGroup(for:
    /// UUID.self)` in `RevolutionIDEApp` can look one up regardless of which OS window shows it.
    @Published var szsWindowSessions: [UUID: SZSWindowSession] = [:]
    /// Set right after a new session is added to `szsWindowSessions`; any view holding
    /// `@Environment(\.openWindow)` watches this and calls `openWindow(id:value:)` then clears
    /// it, centralizing "who actually opens the window" in the view layer without every call
    /// site (project navigator, SZS tree, disc tree, ...) needing its own `openWindow` plumbing.
    @Published var pendingSZSWindowID: UUID?

    /// Same idea as `szsWindowSessions`/`pendingSZSWindowID`, for `.szs`/`.arc` archives that
    /// turn out to be a New Super Mario Bros. Wii level (detected by content, not extension --
    /// both formats share the same U8 container) instead of a generic archive.
    @Published var nsmbwWindowSessions: [UUID: NSMBWWindowSession] = [:]
    @Published var pendingNSMBWWindowID: UUID?

    /// Same idea again, for "Preview Track" (see `TrackPreviewWindowSession`'s doc comment on why
    /// it's a dedicated window rather than a sheet).
    @Published var trackPreviewWindowSessions: [UUID: TrackPreviewWindowSession] = [:]
    @Published var pendingTrackPreviewWindowID: UUID?

    func openTrackPreviewWindow(_ request: TrackPreviewRequest) {
        let session = TrackPreviewWindowSession(request: request)
        trackPreviewWindowSessions[session.id] = session
        pendingTrackPreviewWindowID = session.id
    }

    let git = GitState()
    let emulator = EmulatorLauncher()
    let homebrew = HomebrewBuilder()
    @Published var showNewHomebrew = false

    var selectedTab: EditorTab? { tabs.first { $0.id == selectedTabID } }

    /// Whether this is the app's first window, the one whose tabs are remembered across
    /// launches (File > New Window opens empty windows that don't touch that list).
    let isPrimary: Bool

    init(isPrimary: Bool = true) {
        self.isPrimary = isPrimary
        loadRecentFiles()
        recentProjectURLs = (UserDefaults.standard.stringArray(forKey: "WorkbenchState.recentProjects") ?? []).map { URL(fileURLWithPath: $0) }
        if isPrimary { restorePersistedTabs() }
    }

    /// Kept for source-compatibility with the folder-only navigator path; nil when a disc image
    /// is the current project.
    var projectRoot: ProjectNode? {
        if case .folder(let root) = project { return root }
        return nil
    }

    /// Whether the open folder is a Wii homebrew project (drives the toolbar's Build & Run button).
    var isHomebrewProject: Bool {
        guard let root = projectRoot else { return false }
        return root.children.contains { $0.name == "Makefile" } && HomebrewTemplate.isProject(root.url)
    }

    /// Builds the open homebrew project and, if `thenRun`, boots the resulting `.dol` in Dolphin.
    func buildHomebrew(thenRun: Bool = false, viaChannel: Bool = false, clean: Bool = false) {
        guard let root = projectRoot else { return }
        // Builds read the files on disk, so write out the designs, graphs and code that are open and changed first.
        for tab in tabs where tab.isDirty {
            if case .file(let url) = tab.source, url.path.hasPrefix(root.url.path + "/"), ["wiiui", "wiinodes", "swift", "c", "cpp", "h", "json"].contains(url.pathExtension.lowercased()) { save(tab) }
        }
        if !clean {
            do { for line in try HomebrewGenerator.generate(project: root.url) { log(line) } }
            catch { report(error); announceBuild(success: false, project: root.name); return }
        }
        Task {
            let dol = await homebrew.build(project: root.url, clean: clean) { [weak self] in self?.log($0) }
            announceBuild(success: dol != nil, project: root.name)
            refreshFolderTree()
            if thenRun, let dol { emulator.run(path: dol) }
            if viaChannel, dol != nil { runViaHomebrewChannel(project: root.url) }
        }
    }

    @Published var showHomebrewInfo = false

    /// The latest build result, shown as a popup over the Workbench.
    struct BuildOutcome: Identifiable { let id = UUID(); let success: Bool }
    @Published var buildOutcome: BuildOutcome?

    private func announceBuild(success: Bool, project: String) {
        buildOutcome = BuildOutcome(success: success)
        AppNotifications.buildFinished(success: success, project: project)
    }

    /// Copies a project file/folder into the app's folder on Dolphin's synced SD card.
    func addToDolphinSD(_ item: URL) {
        guard let root = projectRoot else { return }
        do { log("Added to Dolphin SD card: \(try HomebrewPackage.addToDolphinSD(item, project: root.url).path)") }
        catch { report(error) }
    }

    /// Installs the app on Dolphin's synced SD card and boots the Homebrew Channel from the Wii NAND.
    private func runViaHomebrewChannel(project: URL) {
        guard HomebrewPackage.channelTitleID != nil else {
            errorMessage = "The Homebrew Channel isn't installed on Dolphin's Wii NAND. Install its WAD in Dolphin (Tools > Install WAD), then try again."
            log("ERROR: \(errorMessage ?? "")")
            return
        }
        do {
            log("Installed to Dolphin SD card: \(try HomebrewPackage.installToDolphinSD(project: project).path)")
            HomebrewPackage.enableSDSync()
            emulator.runHomebrewChannel()
        } catch { report(error) }
    }

    /// Installs the last build (boot.dol, meta.xml, icon.png) into Dolphin's synced SD card.
    func installToDolphinSD() {
        guard let root = projectRoot else { return }
        do {
            log("Installed to Dolphin SD card: \(try HomebrewPackage.installToDolphinSD(project: root.url).path)")
            log("In Dolphin, turn on Config > Wii > SD Card > \"Automatically sync with folder\" to see it in the Homebrew Channel.")
        } catch { report(error) }
    }

    func log(_ s: String) {
        logLines.append(s)
        if logLines.count > 2000 { logLines.removeFirst(logLines.count - 2000) }
    }

    func report(_ error: Error) {
        let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        errorMessage = msg
        log("ERROR: \(msg)")
    }

    // MARK: Opening

    /// Watches the currently-open folder project for changes made outside the app (Finder, git,
    /// an extraction into the folder) so the navigator reflects them without the user having to
    /// close and reopen the project. One watcher at a time, replaced whenever a new folder opens.
    private var folderWatcher: FolderWatcher?

    func openFolder(url: URL) {
        // The on-disk spelling ("Tracks" vs "tracks"), so one folder never gets two tabs.
        let url = (try? url.resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? url
        Task.detached(priority: .userInitiated) {
            let scan = await ProjectNode.scan(at: url)
            await MainActor.run { [weak self] in self?.applyOpenedFolder(scan, url: url) }
        }
    }

    /// Opens `url` as the project (another folder tab), expanding down to `archive` inside it.
    func openFolder(url: URL, revealing archive: URL) {
        pendingReveal = archive
        openFolder(url: url)
    }

    func closeFolderTab(_ url: URL) {
        folderTabs.removeAll { $0 == url }
        guard case .folder(let root) = project, root.url == url else { return }
        if let next = folderTabs.last { openFolder(url: next) } else { project = nil }
    }

    private func applyOpenedFolder(_ scan: ProjectNode.Scan, url: URL) {
        project = .folder(ProjectNode.build(from: scan))
        if !folderTabs.contains(url) { folderTabs.append(url) }
        if let archive = pendingReveal {
            pendingReveal = nil
            var dir = archive
            while dir.path != url.path, dir.pathComponents.count > url.pathComponents.count { navigatorExpanded.insert(dir.path); dir.deleteLastPathComponent() }
        }
        recordRecentProject(url)
        log("Opened project folder: \(url.path)")
        git.refresh(repoURL: url)
        folderWatcher = FolderWatcher(url: url) { [weak self] in
            Task { @MainActor in self?.refreshFolderTree() }
        }
    }

    /// Bumped on every `refreshFolderTree()` call so a scan that finishes after a newer one was
    /// already started (or after the project changed/closed entirely) gets discarded instead of
    /// clobbering fresher state, rename/delete/duplicate/etc. can all trigger overlapping refreshes.
    private var folderRefreshGeneration = 0

    /// Reloads the folder project's tree from disk, used both after an external change
    /// (`folderWatcher`'s callback), anywhere else the navigator needs to catch up with the
    /// filesystem, and the Project Navigator's own manual "Refresh" button (some external tools/
    /// network volumes don't reliably trigger the watcher). A no-op if a folder isn't the current
    /// project (e.g. the user switched to a disc-as-project or closed it since the watcher's
    /// callback was scheduled). The actual disk walk runs off the main thread (see
    /// `ProjectNode.Scan`), rebuilding the whole tree synchronously on every single-file rename/
    /// move/delete is what used to make those feel slow on anything bigger than a tiny project.
    func refreshFolderTree() {
        guard case .folder(let root) = project else { return }
        folderRefreshGeneration += 1
        let generation = folderRefreshGeneration
        let rootURL = root.url
        Task.detached(priority: .userInitiated) {
            let scan = await ProjectNode.scan(at: rootURL)
            await MainActor.run { [weak self] in self?.applyFolderScan(scan, generation: generation, rootURL: rootURL) }
        }
    }

    private func applyFolderScan(_ scan: ProjectNode.Scan, generation: Int, rootURL: URL) {
        guard folderRefreshGeneration == generation else { return }
        guard case .folder(let currentRoot) = project, currentRoot.url == rootURL else { return }
        project = .folder(ProjectNode.build(from: scan))
    }

    // MARK: Project Navigator file operations
    //
    // Real filesystem operations for the folder-project tree only, `node.discContext != nil`
    // means the node's bytes actually live inside an opened `.iso`/`.wbfs` (see `ProjectNode`'s
    // doc comment), which these don't touch; disc images have their own, much more careful
    // FST-aware mutation path (`FileOperations.swift`) that a plain rename/move/copy would corrupt.

    /// Renames a real file/folder and keeps any open tab pointed at the new location, so a later
    /// Save doesn't silently write to (or fail on) the path that no longer exists. A file's own
    /// extension is kept fixed regardless of what's typed (see `nameKeepingExtension`), folders
    /// have no such thing to protect.
    func renameProjectItem(_ node: ProjectNode, to newName: String) {
        guard node.discContext == nil else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let finalName = node.isDirectory ? trimmed : Self.nameKeepingExtension(of: node.name, renamedTo: trimmed)
        guard finalName != node.name else { return }
        let newURL = node.url.deletingLastPathComponent().appendingPathComponent(finalName)
        do {
            try FileManager.default.moveItem(at: node.url, to: newURL)
            for tab in tabs where isFileTab(tab, at: node.url) {
                if case .file = tab.source { tab.source = .file(newURL) }
                tab.title = finalName
            }
            log("Renamed \(node.name) to \(finalName).")
            refreshFolderTree()
            if case .folder(let root) = project { git.refresh(repoURL: root.url) }
        } catch {
            report(error)
        }
    }

    /// Keeps a file's own extension fixed across a rename: whatever extension `newName` itself
    /// has (if any) is dropped and `originalName`'s re-appended, so a rename can't accidentally
    /// reclassify a file's type (a `.szs` fat-fingered into `.zss`, an `.obj` typed without any
    /// extension at all, ...), nearly everything in this app (which editor opens a file, what
    /// "Make .brres"/"New Archive" name their result, ...) keys off a file's own extension. Only
    /// ever applied to files, never folders, a dot in a folder name is just a dot, not something
    /// worth protecting the same way.
    private static func nameKeepingExtension(of originalName: String, renamedTo newName: String) -> String {
        let ext = (originalName as NSString).pathExtension
        guard !ext.isEmpty else { return newName }
        let base = (newName as NSString).deletingPathExtension
        return "\(base.isEmpty ? newName : base).\(ext)"
    }

    /// Moves a real file/folder to the Trash, recoverable, unlike a permanent delete, and
    /// closes any tab open on it or on something inside it.
    func deleteProjectItem(_ node: ProjectNode) {
        guard node.discContext == nil else { return }
        do {
            try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
            tabs.removeAll { isFileTab($0, at: node.url) || isFileTab($0, underDirectory: node.url) }
            if let selectedTabID, !tabs.contains(where: { $0.id == selectedTabID }) {
                self.selectedTabID = tabs.first?.id
            }
            log("Moved \(node.name) to the Trash.")
            refreshFolderTree()
            if case .folder(let root) = project { git.refresh(repoURL: root.url) }
        } catch {
            report(error)
        }
    }

    /// Copies a real file/folder alongside itself under a Finder-style "name copy"/"name copy 2" name.
    func duplicateProjectItem(_ node: ProjectNode) {
        guard node.discContext == nil else { return }
        let dir = node.url.deletingLastPathComponent()
        let ext = node.url.pathExtension
        let base = ext.isEmpty ? node.name : String(node.name.dropLast(ext.count + 1))
        var candidate = ext.isEmpty ? "\(base) copy" : "\(base) copy.\(ext)"
        var n = 2
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(base) copy \(n)" : "\(base) copy \(n).\(ext)"
            n += 1
        }
        do {
            try FileManager.default.copyItem(at: node.url, to: dir.appendingPathComponent(candidate))
            log("Duplicated \(node.name) as \(candidate).")
            refreshFolderTree()
            if case .folder(let root) = project { git.refresh(repoURL: root.url) }
        } catch {
            report(error)
        }
    }

    /// Appends " 2", " 3", ... until `name` doesn't collide with an existing entry in `folder` --
    /// shared by `createFolder` (Finder-style unique default names) and the drop handlers below
    /// (so a dropped file never silently overwrites one already there).
    private func uniqueFileURL(preferredName name: String, in folder: URL) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        var n = 2
        while true {
            let newName = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = folder.appendingPathComponent(newName)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    /// The real folder a new item created "in" `node` should land in: `node.url` itself for a
    /// real directory, its containing folder for a real file, or the project root when `node` is
    /// nil (the navigator's empty-space/background context menu). Nil for anything this doesn't
    /// apply to, a disc-image or in-archive node, or no folder project open at all.
    private func realFolderURL(for node: ProjectNode?) -> URL? {
        guard case .folder(let root) = project else { return nil }
        guard let node else { return root.url }
        guard node.discContext == nil, node.archiveEntryContext == nil else { return nil }
        return node.isDirectory ? node.url : node.url.deletingLastPathComponent()
    }

    /// Right-click "New Folder" in the Project Navigator. Finder-style unique-named, created
    /// under `parent` (or the project root when `parent` is nil).
    func createFolder(in parent: ProjectNode?) {
        guard let base = realFolderURL(for: parent) else { return }
        let url = uniqueFileURL(preferredName: "New Folder", in: base)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            log("Created \(url.lastPathComponent).")
            refreshFolderTree()
        } catch { report(error) }
    }

    // MARK: Project Navigator drag & drop / copy & paste
    //
    // Dropping files (from Finder, or a real node dragged from elsewhere in this same tree) onto a
    // Project Navigator row: a real folder gets them moved in; a `.szs`/`.arc` file (or a folder
    // previewed inside one) gets them moved into the archive as new entries (the original file on
    // disk is removed once it's safely inside). Disc-image nodes aren't a valid drop target, same
    // real-filesystem-only restriction as rename/delete/duplicate above. Copy/Paste (see further
    // down) shares this same destination logic, just without removing the original.

    /// Moves (or, with `move: false`, copies) `urls` into `folder` on disk (Finder-style
    /// unique-named on a collision, never overwriting) and refreshes the tree to show them. A
    /// `url` already directly inside `folder` is left alone rather than moved onto/renamed
    /// against its own name as a "collision", copying it there instead still makes a Finder-
    /// style "name copy", the same as Finder's own Copy/Paste would.
    private func transferFiles(_ urls: [URL], into folder: URL, move: Bool) {
        let fm = FileManager.default
        var done: [String] = []
        for src in urls {
            if move, src.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL { continue }
            // A folder dropped onto itself or one of its own subfolders.
            if folder.standardizedFileURL.path == src.standardizedFileURL.path
                || folder.standardizedFileURL.path.hasPrefix(src.standardizedFileURL.path + "/") {
                log("Can't put \(src.lastPathComponent) inside itself.")
                continue
            }
            let dest = uniqueFileURL(preferredName: src.lastPathComponent, in: folder)
            do {
                if move {
                    try fm.moveItem(at: src, to: dest)
                    // Retarget tabs on the moved file, or on anything inside a moved folder.
                    for tab in tabs {
                        guard case .file(let u) = tab.source else { continue }
                        if u == src { tab.source = .file(dest) }
                        else if u.path.hasPrefix(src.path + "/") { tab.source = .file(URL(fileURLWithPath: dest.path + u.path.dropFirst(src.path.count))) }
                    }
                } else {
                    try fm.copyItem(at: src, to: dest)
                }
                done.append(dest.lastPathComponent)
            } catch { report(error) }
        }
        guard !done.isEmpty else { return }
        log("\(move ? "Moved" : "Copied") \(done.joined(separator: ", ")) to \(folder.lastPathComponent).")
        refreshFolderTree()
        if case .folder(let root) = project { git.refresh(repoURL: root.url) }
    }

    /// Appends " 2", " 3", ... until `name` doesn't collide with an existing sibling inside a U8
    /// archive, same idea as `uniqueFileURL`, just against a `U8Node`'s children instead of the
    /// real filesystem.
    private func uniqueU8Name(_ name: String, in parent: U8Node) -> String {
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

    /// Adds `urls`' contents as new entries inside the `.szs`/`.arc` at `archiveURL`, under the
    /// folder at `pathComponents` (empty for the archive's own top level), folders among them
    /// are silently skipped, since a U8 archive entry is always a single file. With
    /// `deletingOriginals: true` (a drag, which reads as a move), each file's original on disk is
    /// removed (and any tab open on it closed) once its bytes are safely inside the archive; with
    /// `false` (Paste, which always copies) the originals are left alone. Goes through
    /// `mutateArchive`, so the archive is saved immediately either way (reusing a live box's
    /// already-parsed tree when a tab or window already has this archive open).
    private func addFilesToArchive(_ urls: [URL], archiveURL: URL, pathComponents: [String], deletingOriginals: Bool) {
        let fm = FileManager.default
        var skippedFolder = false
        let newEntries: [(url: URL, name: String, data: Data)] = urls.compactMap { url in
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                skippedFolder = true
                return nil
            }
            guard let data = try? Data(contentsOf: url) else { return nil }
            return (url, url.lastPathComponent, data)
        }
        if skippedFolder { log("Archives can only hold files here, skipped any folders in the drop.") }
        guard !newEntries.isEmpty else { return }

        var found = true
        let result = mutateArchive(at: archiveURL) { root in
            guard let parent = root.find(path: pathComponents) else { found = false; return }
            for entry in newEntries {
                let node = U8Node(name: self.uniqueU8Name(entry.name, in: parent), isDirectory: false, data: entry.data)
                node.parent = parent
                parent.children.append(node)
            }
        }
        guard found else {
            log("Couldn't find that folder inside \(archiveURL.lastPathComponent), it may have changed.")
            return
        }
        guard result == .succeeded else { return }

        let verb = deletingOriginals ? "Moved" : "Copied"
        let names = newEntries.count == 1 ? newEntries[0].name : "\(newEntries.count) files"
        log("\(verb) \(names) into \(archiveURL.lastPathComponent).")

        guard deletingOriginals else { return }
        for entry in newEntries {
            try? fm.removeItem(at: entry.url)
            tabs.removeAll { isFileTab($0, at: entry.url) }
        }
        if let selectedTabID, !tabs.contains(where: { $0.id == selectedTabID }) {
            self.selectedTabID = tabs.first?.id
        }
        refreshFolderTree()
        if case .folder(let root) = project { git.refresh(repoURL: root.url) }
    }

    /// "Dragging Files Should Copy" (Settings > Appearance), off by default, matching Finder's
    /// own same-volume drag (a move) rather than its cross-volume one (a copy). Read fresh at drop
    /// time rather than cached, since it can change without the app restarting.
    private var dragShouldCopy: Bool { UserDefaults.standard.bool(forKey: "dragFilesShouldCopy") }

    /// Finder's rules for whether a drop moves or copies: a drag from inside the project moves, one
    /// from outside it (the Desktop, another volume, another app) copies so the original is never
    /// deleted out from under the user; holding Option at drop time flips whichever applies.
    private func dragMoves(_ urls: [URL]) -> Bool {
        guard case .folder(let root) = project else { return false }
        let rootPath = root.url.standardizedFileURL.path + "/"
        let fromProject = urls.allSatisfy { $0.standardizedFileURL.path.hasPrefix(rootPath) }
        return (fromProject && !dragShouldCopy) != NSEvent.modifierFlags.contains(.option)
    }

    /// `dragMoves` for an entry dragged out of an archive, always from inside the project.
    private var archiveDragMoves: Bool { !dragShouldCopy != NSEvent.modifierFlags.contains(.option) }

    /// Entry point for a Finder (or in-tree) file drop onto a specific Project Navigator row.
    /// `ProjectNavigatorView.canAcceptDrop` is what actually gates which rows this ever gets
    /// called for; this re-checks the same shape so it's never relied on as the only guard.
    func handleProjectNavigatorDrop(_ urls: [URL], onto node: ProjectNode) {
        guard !urls.isEmpty, node.discContext == nil else { return }
        let move = dragMoves(urls)
        if let ctx = node.archiveEntryContext {
            // A drop on a file entry lands in the folder holding it, like Finder.
            let path = ctx.node.isDirectory ? ctx.node.pathFromRoot : Array(ctx.node.pathFromRoot.dropLast())
            addFilesToArchive(urls, archiveURL: ctx.archiveURL, pathComponents: path, deletingOriginals: move)
        } else if node.isArchive {
            addFilesToArchive(urls, archiveURL: node.url, pathComponents: [], deletingOriginals: move)
        } else {
            transferFiles(urls, into: node.isDirectory ? node.url : node.url.deletingLastPathComponent(), move: move)
        }
    }

    /// A drop onto empty space in the navigator (below/around the tree, not on any specific row) --
    /// lands in the project's own root folder.
    func handleProjectNavigatorRootDrop(_ urls: [URL]) {
        guard case .folder(let root) = project, !urls.isEmpty else { return }
        transferFiles(urls, into: root.url, move: dragMoves(urls))
    }

    /// The Project Navigator's "Paste", same destinations as `handleProjectNavigatorDrop`, just
    /// always a copy (matching what Finder's own Copy/Paste always does, drag-and-drop
    /// notwithstanding). Called with whatever `copyProjectItem`/`copyArchiveEntry` most recently
    /// put on `NSPasteboard.general`, see `ProjectNavigatorView.pasteInto`.
    func handleProjectNavigatorPaste(_ urls: [URL], onto node: ProjectNode) {
        guard !urls.isEmpty, node.discContext == nil else { return }
        if let ctx = node.archiveEntryContext {
            guard ctx.node.isDirectory else { return }
            addFilesToArchive(urls, archiveURL: ctx.archiveURL, pathComponents: ctx.node.pathFromRoot, deletingOriginals: false)
        } else if node.isArchive {
            addFilesToArchive(urls, archiveURL: node.url, pathComponents: [], deletingOriginals: false)
        } else if node.isDirectory {
            transferFiles(urls, into: node.url, move: false)
        }
    }

    /// A Paste onto empty navigator space (or the root folder's own "Paste"), lands in the
    /// project's own root folder, mirroring `handleProjectNavigatorRootDrop`.
    func handleProjectNavigatorPasteToRoot(_ urls: [URL]) {
        guard case .folder(let root) = project, !urls.isEmpty else { return }
        transferFiles(urls, into: root.url, move: false)
    }

    // MARK: Managing files inside an archive from the Project Navigator
    //
    // Rename/Delete/Duplicate/drag-in/drag-out/Paste for a file or folder previewed inside a
    // `.szs`/`.arc`, the archive counterparts to `renameProjectItem`/`deleteProjectItem`/
    // `duplicateProjectItem`/dragging a real file. All of them go through `mutateArchive`, which
    // auto-saves: a file changed from the Project Navigator writes straight back to the archive on
    // disk immediately (reusing a live box's already-parsed tree, and clearing its dirty flag,
    // when a tab or window already has this archive open, rather than always re-parsing it from
    // disk), there's no separate "unsaved" state to leave behind the way manually editing inside
    // the dedicated archive window/tab still has (that's unrelated, its own explicit Save is
    // for the file *contents* you're actively editing there, not these one-shot tree operations).

    private enum ArchiveMutationResult: Equatable { case succeeded, failed }

    private func mutateArchive(at archiveURL: URL, _ mutate: (U8Node) -> Void) -> ArchiveMutationResult {
        if let box = liveArchiveBox(atFileURL: archiveURL) {
            mutate(box.root)
            let data = SZS.save(root: box.root, compressed: box.wasCompressed)
            do {
                try data.write(to: archiveURL, options: .atomic)
                box.isDirty = false
                box.objectWillChange.send()
                refreshFolderTree()
                if case .folder(let projectRoot) = project { git.refresh(repoURL: projectRoot.url) }
                return .succeeded
            } catch {
                // The in-memory tree already reflects the edit even though the disk write failed
                //, leave it marked dirty so the edit isn't silently lost, matching what an
                // ordinary failed Save already does elsewhere.
                box.isDirty = true
                box.objectWillChange.send()
                report(error)
                return .failed
            }
        }
        do {
            let raw = try Data(contentsOf: archiveURL)
            let (root, compressed) = try SZS.open(raw)
            mutate(root)
            try SZS.save(root: root, compressed: compressed).write(to: archiveURL, options: .atomic)
            refreshFolderTree()
            if case .folder(let projectRoot) = project { git.refresh(repoURL: projectRoot.url) }
            return .succeeded
        } catch {
            report(error)
            return .failed
        }
    }

    /// A read-only peek at one entry, file or folder, from a live box if the archive's open,
    /// else a throwaway fresh parse, used by `moveArchiveEntryOut`/`moveArchiveEntryOutToRoot`
    /// to grab it *before* deciding where it's going, without marking anything dirty just to look.
    /// The caller always `deepCopyU8Node`s whatever comes back before inserting it anywhere, so
    /// it's never left aliasing a live box's own tree.
    private func archiveEntrySubtree(archiveURL: URL, pathComponents: [String]) -> U8Node? {
        if let box = liveArchiveBox(atFileURL: archiveURL) {
            return box.root.find(path: pathComponents)
        }
        guard let raw = try? Data(contentsOf: archiveURL), let (root, _) = try? SZS.open(raw) else { return nil }
        return root.find(path: pathComponents)
    }

    /// A deep copy of a copied/dragged archive entry (file or folder), by path, from a live box
    /// if that archive's open, else a fresh parse. Used by `ProjectNavigatorView`'s own Paste (via
    /// `transferArchiveEntry`) and by `SZSArchiveView`'s Paste, which has no `ProjectNode`
    /// destination to route through `copyArchiveEntry`/`transferArchiveEntry` and instead inserts
    /// straight into its own already-open `box`.
    func copiedArchiveEntry(_ location: ArchiveEntryLocation) -> U8Node? {
        guard let node = archiveEntrySubtree(archiveURL: location.archiveURL, pathComponents: location.pathComponents) else { return nil }
        return deepCopyU8Node(node, newName: node.name)
    }

    /// Recursively writes a `U8Node` (file or folder) out to a real path on disk, the "extract"
    /// side of copying/moving an archive entry onto a real folder, needed once folders (not just
    /// single files) became a valid source.
    private func writeU8NodeToDisk(_ node: U8Node, to url: URL) throws {
        if node.isDirectory {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for child in node.children {
                try writeU8NodeToDisk(child, to: url.appendingPathComponent(child.name))
            }
        } else {
            try (node.data ?? Data()).write(to: url, options: .atomic)
        }
    }

    private func deepCopyU8Node(_ node: U8Node, newName: String) -> U8Node {
        let copy = U8Node(name: newName, isDirectory: node.isDirectory, data: node.data)
        copy.children = node.children.map { deepCopyU8Node($0, newName: $0.name) }
        for child in copy.children { child.parent = copy }
        return copy
    }

    /// Right-click "Rename..." on a file or folder previewed inside a `.szs`/`.arc`, a file's own
    /// extension is kept fixed regardless of what's typed (see `nameKeepingExtension`), same as
    /// renaming a real file; a folder entry has no such thing to protect.
    func renameArchiveEntry(archiveURL: URL, pathComponents: [String], to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var problem = false
        var renamedTo: String?
        let result = mutateArchive(at: archiveURL) { root in
            guard let entry = root.find(path: pathComponents), let parent = entry.parent else { problem = true; return }
            let finalName = entry.isDirectory ? trimmed : Self.nameKeepingExtension(of: entry.name, renamedTo: trimmed)
            guard finalName != entry.name else { return } // nothing actually changes, a silent no-op, not an error
            guard !parent.children.contains(where: { $0 !== entry && $0.name == finalName }) else { problem = true; return }
            entry.name = finalName
            renamedTo = finalName
        }
        guard !problem else {
            log("Couldn't rename that entry inside \(archiveURL.lastPathComponent), either it changed, or that name is already taken there.")
            return
        }
        guard let renamedTo else { return }
        if result == .succeeded { log("Renamed to \(renamedTo) inside \(archiveURL.lastPathComponent).") }
    }

    /// Right-click "Delete" on a file or folder previewed inside a `.szs`/`.arc`.
    func deleteArchiveEntry(archiveURL: URL, pathComponents: [String]) {
        guard let entryName = pathComponents.last else { return }
        var found = true
        let result = mutateArchive(at: archiveURL) { root in
            guard let entry = root.find(path: pathComponents) else { found = false; return }
            entry.parent?.children.removeAll { $0 === entry }
        }
        guard found else {
            log("Couldn't find \(entryName) inside \(archiveURL.lastPathComponent), it may have changed.")
            return
        }
        if result == .succeeded { log("Deleted \(entryName) from \(archiveURL.lastPathComponent).") }
    }

    /// Right-click "Duplicate" on a file or folder previewed inside a `.szs`/`.arc`, a
    /// Finder-style unique-named copy right alongside the original (a folder's whole subtree is
    /// deep-copied, not just its own entry).
    func duplicateArchiveEntry(archiveURL: URL, pathComponents: [String]) {
        guard let entryName = pathComponents.last else { return }
        var found = true
        let result = mutateArchive(at: archiveURL) { root in
            guard let entry = root.find(path: pathComponents), let parent = entry.parent else { found = false; return }
            let copy = self.deepCopyU8Node(entry, newName: self.uniqueU8Name(entry.name, in: parent))
            copy.parent = parent
            if let idx = parent.children.firstIndex(where: { $0 === entry }) {
                parent.children.insert(copy, at: idx + 1)
            } else {
                parent.children.append(copy)
            }
        }
        guard found else {
            log("Couldn't find \(entryName) inside \(archiveURL.lastPathComponent), it may have changed.")
            return
        }
        if result == .succeeded { log("Duplicated \(entryName) inside \(archiveURL.lastPathComponent).") }
    }

    /// A file entry's location inside a `.szs`/`.arc`, encoded across the drag boundary as a
    /// custom `NSItemProvider` payload, an `NSItemProvider` can only carry serializable data,
    /// not a live `U8Node` reference, and the node dragged from is a disconnected preview parse
    /// anyway (see `ProjectNode.archiveEntryContext`'s doc comment), so this is looked back up by
    /// path once dropped, the same way every other archive-entry operation here does.
    struct ArchiveEntryLocation: Codable {
        var archiveURL: URL
        var pathComponents: [String]
    }

    /// Dragging a file or folder entry out of a `.szs`/`.arc` onto another Project Navigator row --
    /// a real folder (written to disk, recursively for a folder entry), a different archive/
    /// folder-inside-an-archive (deep-copied in as a new entry), or, with `removingSource: false`
    /// (Paste, or the same archive/folder Copy targets its own source, which always makes a
    /// duplicate rather than being a no-op like a move would be), copying it there instead.
    private func transferArchiveEntry(_ source: ArchiveEntryLocation, onto node: ProjectNode, removingSource: Bool) {
        guard node.discContext == nil, let entryName = source.pathComponents.last else { return }
        guard let sourceNode = archiveEntrySubtree(archiveURL: source.archiveURL, pathComponents: source.pathComponents) else {
            log("Couldn't find \(entryName) inside \(source.archiveURL.lastPathComponent), it may have changed.")
            return
        }

        func removeSourceIfNeeded() {
            guard removingSource else { return }
            _ = mutateArchive(at: source.archiveURL) { root in
                guard let entry = root.find(path: source.pathComponents) else { return }
                entry.parent?.children.removeAll { $0 === entry }
            }
        }
        let verb = removingSource ? "Moved" : "Copied"

        if let ctx = node.archiveEntryContext {
            let destinationPath = ctx.node.isDirectory ? ctx.node.pathFromRoot : Array(ctx.node.pathFromRoot.dropLast())
            guard !removingSource || ctx.archiveURL != source.archiveURL || destinationPath != Array(source.pathComponents.dropLast()) else { return }
            var found = true
            let result = mutateArchive(at: ctx.archiveURL) { root in
                guard let parent = root.find(path: destinationPath) else { found = false; return }
                let newNode = self.deepCopyU8Node(sourceNode, newName: self.uniqueU8Name(entryName, in: parent))
                newNode.parent = parent
                parent.children.append(newNode)
            }
            guard found, result != .failed else { return }
            removeSourceIfNeeded()
            log("\(verb) \(entryName) into \(ctx.archiveURL.lastPathComponent).")
        } else if node.isArchive {
            guard !removingSource || node.url != source.archiveURL else { return }
            let result = mutateArchive(at: node.url) { root in
                let newNode = self.deepCopyU8Node(sourceNode, newName: self.uniqueU8Name(entryName, in: root))
                newNode.parent = root
                root.children.append(newNode)
            }
            guard result != .failed else { return }
            removeSourceIfNeeded()
            log("\(verb) \(entryName) into \(node.url.lastPathComponent).")
        } else {
            let folder = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
            let dest = uniqueFileURL(preferredName: entryName, in: folder)
            do {
                try writeU8NodeToDisk(sourceNode, to: dest)
                removeSourceIfNeeded()
                log("\(verb) \(entryName) \(removingSource ? "out of" : "from") \(source.archiveURL.lastPathComponent) to \(folder.lastPathComponent).")
                refreshFolderTree()
                if case .folder(let root) = project { git.refresh(repoURL: root.url) }
            } catch { report(error) }
        }
    }

    /// Same idea as `transferArchiveEntry`, for a drop/paste onto empty navigator space, lands
    /// in the project's own root folder, mirroring `handleProjectNavigatorRootDrop`.
    private func transferArchiveEntryToRoot(_ source: ArchiveEntryLocation, removingSource: Bool) {
        guard case .folder(let projectRoot) = project, let entryName = source.pathComponents.last else { return }
        guard let sourceNode = archiveEntrySubtree(archiveURL: source.archiveURL, pathComponents: source.pathComponents) else {
            log("Couldn't find \(entryName) inside \(source.archiveURL.lastPathComponent), it may have changed.")
            return
        }
        let dest = uniqueFileURL(preferredName: entryName, in: projectRoot.url)
        do {
            try writeU8NodeToDisk(sourceNode, to: dest)
            if removingSource {
                _ = mutateArchive(at: source.archiveURL) { root in
                    guard let entry = root.find(path: source.pathComponents) else { return }
                    entry.parent?.children.removeAll { $0 === entry }
                }
            }
            log("\(removingSource ? "Moved" : "Copied") \(entryName) \(removingSource ? "out of" : "from") \(source.archiveURL.lastPathComponent) to \(projectRoot.url.lastPathComponent).")
            refreshFolderTree()
            git.refresh(repoURL: projectRoot.url)
        } catch { report(error) }
    }

    /// Dragging a file entry out of a `.szs`/`.arc` onto another Project Navigator row, see
    /// `transferArchiveEntry`. Respects "Dragging Files Should Copy" like every other drag.
    func moveArchiveEntryOut(_ source: ArchiveEntryLocation, onto node: ProjectNode) {
        transferArchiveEntry(source, onto: node, removingSource: archiveDragMoves)
    }

    /// Dragging a file entry out of a `.szs`/`.arc` onto empty navigator space, see
    /// `transferArchiveEntryToRoot`.
    func moveArchiveEntryOutToRoot(_ source: ArchiveEntryLocation) {
        transferArchiveEntryToRoot(source, removingSource: archiveDragMoves)
    }

    /// Pasting a copied file entry from a `.szs`/`.arc` onto another Project Navigator row.
    func copyArchiveEntry(_ source: ArchiveEntryLocation, onto node: ProjectNode) {
        transferArchiveEntry(source, onto: node, removingSource: false)
    }

    /// Pasting a copied file entry from a `.szs`/`.arc` onto empty navigator space (or the
    /// project root's own "Paste").
    func copyArchiveEntryToRoot(_ source: ArchiveEntryLocation) {
        transferArchiveEntryToRoot(source, removingSource: false)
    }

    private func isFileTab(_ tab: EditorTab, at url: URL) -> Bool {
        if case .file(let u) = tab.source { return u == url }
        return false
    }

    private func isFileTab(_ tab: EditorTab, underDirectory dir: URL) -> Bool {
        if case .file(let u) = tab.source { return u.path.hasPrefix(dir.path + "/") }
        return false
    }

    @discardableResult
    func openFile(url: URL, forceNewWindow: Bool = false) -> EditorTab? {
        let ext = url.pathExtension.lowercased()
        if ext == "iso" || ext == "wbfs" || ext == "gcm" {
            openDiscAsProject(url: url)
            return nil
        }
        if let existing = szsWindowSessions.values.first(where: {
            if case .file(let u) = $0.source { return u == url }
            return false
        }) {
            pendingSZSWindowID = existing.id
            return nil
        }
        if let existing = nsmbwWindowSessions.values.first(where: {
            if case .file(let u) = $0.source { return u == url }
            return false
        }) {
            pendingNSMBWWindowID = existing.id
            return nil
        }
        if let existing = tabs.first(where: { if case .file(let u) = $0.source { return u == url }; return false }) {
            selectedTabID = existing.id
            return existing
        }
        do {
            let data = try Data(contentsOf: url)
            recordRecentFile(url)
            if isArchive(name: url.lastPathComponent, data: data) {
                revealArchiveFolderIfOutsideProject(url)
                if forceNewWindow {
                    openArchiveInNewWindow(data: data, title: url.lastPathComponent, source: .file(url))
                } else {
                    openArchiveAsTab(data: data, title: url.lastPathComponent, source: .file(url))
                }
                return nil
            }
            let tab = EditorTab(title: url.lastPathComponent, payload: .loading, source: .file(url))
            tabs.append(tab)
            selectedTabID = tab.id
            loadPayload(into: tab, name: url.lastPathComponent, data: data, source: .file(url), successLog: "Opened \(url.lastPathComponent).")
            return tab
        } catch {
            report(error)
            return nil
        }
    }

    /// Opening an archive from outside the project (File > Open, Finder) brings up its folder as
    /// the project with the archive expanded, so its contents are browsable straight away.
    private func revealArchiveFolderIfOutsideProject(_ url: URL) {
        guard UserDefaults.standard.object(forKey: Self.archiveOpensFolderKey) as? Bool ?? true else { return }
        switch project {
        case .discImage: return
        case .folder(let root) where url.path.hasPrefix(root.url.path + "/"): return
        default: openFolder(url: url.deletingLastPathComponent(), revealing: url)
        }
    }

    /// Opens a Wii or GameCube disc image as the project, exactly like opening a folder: its partition/file
    /// tree appears in the navigator, and double-clicking a file (including .szs/.kmp/.brres
    /// found inside a partition) opens it as a tab whose Save writes back into the disc in place.
    func openDiscAsProject(url: URL) {
        KeyManager.shared.autoLoad(nextTo: url)
        do {
            let disc = try openDiscImage(url, commonKey: KeyManager.shared.commonKey, koreanKey: KeyManager.shared.koreanKey)
            project = .discImage(url: url, disc: disc)
            recordRecentProject(url)
            log("Opened \(disc is GameCubeDisc ? "GameCube" : "Wii") disc as project: \(disc.gameTitle.isEmpty ? disc.gameID : disc.gameTitle) [\(disc.gameID)]")
            git.refresh(repoURL: url.deletingLastPathComponent())
        } catch {
            report(error)
        }
    }

    /// Opens a file living inside the currently-open disc-as-project (double-click in the
    /// navigator). Saving writes back into the disc image in place via the same engine the Disc
    /// Scrubber window uses. A `.szs`/`.arc` found on the disc opens as a tab by default (`forceNewWindow`
    /// for the right-click "Open in New Window" case), exactly like one opened from a folder
    /// project or picked directly, saving it still writes back into the disc image in place.
    func openDiscEntry(node: DiscNode, disc: any DiscImageReader, discURL: URL, forceNewWindow: Bool = false) {
        if let existing = szsWindowSessions.values.first(where: {
            if case .discEntry(_, _, let n) = $0.source { return n === node }
            return false
        }) {
            pendingSZSWindowID = existing.id
            return
        }
        if let existing = nsmbwWindowSessions.values.first(where: {
            if case .discEntry(_, _, let n) = $0.source { return n === node }
            return false
        }) {
            pendingNSMBWWindowID = existing.id
            return
        }
        if let existing = tabs.first(where: {
            if case .discEntry(_, _, let n) = $0.source { return n === node }
            return false
        }) {
            selectedTabID = existing.id
            return
        }
        do {
            let data = try disc.readFile(node: node)
            let source = EditorTab.Source.discEntry(discURL: discURL, disc: disc, node: node)
            if isArchive(name: node.name, data: data) {
                if forceNewWindow {
                    openArchiveInNewWindow(data: data, title: node.name, source: source)
                } else {
                    openArchiveAsTab(data: data, title: node.name, source: source)
                }
                return
            }
            let tab = EditorTab(title: node.name, payload: .loading, source: source)
            tabs.append(tab)
            selectedTabID = tab.id
            loadPayload(into: tab, name: node.name, data: data, source: source, successLog: "Opened \(node.name) from the disc.")
        } catch {
            report(error)
        }
    }

    // MARK: Extracting from a disc-as-project

    @Published var isExtracting = false

    /// Extracts a single file/partition-component from the currently-open disc project, the
    /// main-UI equivalent of the legacy Disc Scrubber window's "Save / Extract...".
    func extractFile(node: DiscNode, disc: any DiscImageReader, to destination: URL) {
        guard !isExtracting else { return }
        isExtracting = true
        log("Extracting \(node.name)...")
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try FileOperations.extract(disc: disc, node: node, to: destination)
                await MainActor.run {
                    self?.isExtracting = false
                    self?.log("Extracted \(node.name) to \(destination.path).")
                }
            } catch {
                await MainActor.run {
                    self?.isExtracting = false
                    self?.report(error)
                }
            }
        }
    }

    /// Recursively extracts every file under `node` (a directory, a partition, or the whole disc
    /// root, "Extract Whole Disc...") to `destination`. Logs progress every 5% rather than per
    /// file, since a full retail disc can be well over a thousand files.
    func extractAll(node: DiscNode, disc: any DiscImageReader, to destination: URL) {
        guard !isExtracting else { return }
        isExtracting = true
        log("Extracting \(node.name.isEmpty ? "disc" : node.name) to \(destination.path)...")
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                var lastLoggedPercent = -1
                try FileOperations.extractAll(disc: disc, node: node, to: destination) { p, msg in
                    let percent = Int(p * 100)
                    guard percent != lastLoggedPercent, percent % 5 == 0 || p >= 1 else { return }
                    lastLoggedPercent = percent
                    Task { @MainActor in self?.log("\(percent)%. \(msg)") }
                }
                await MainActor.run {
                    self?.isExtracting = false
                    self?.log("Extraction to \(destination.path) complete.")
                }
            } catch {
                await MainActor.run {
                    self?.isExtracting = false
                    self?.report(error)
                }
            }
        }
    }

    private func isArchive(name: String, data: Data) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ext == "szs" || ext == "arc" || Yaz0.isYaz0(data)
    }

    private func sourcesMatch(_ a: EditorTab.Source, _ b: EditorTab.Source) -> Bool {
        switch (a, b) {
        case (.file(let x), .file(let y)): return x == y
        case (.szsEntry(_, let x), .szsEntry(_, let y)): return x === y
        case (.discEntry(_, _, let x), .discEntry(_, _, let y)): return x === y
        default: return false
        }
    }

    /// The already-open `SZSDocumentBox` for the `.szs`/`.arc` file at `url`, from an existing
    /// tab or dedicated window, if there is one. Shared by `openArchiveEntry` and the Project
    /// Navigator drag-and-drop path (`addFilesToArchive`), both of which need to mutate that same
    /// live box rather than a second, disconnected parse that could silently clobber it on save.
    private func liveArchiveBox(atFileURL url: URL) -> SZSDocumentBox? {
        szsWindowSessions.values.first(where: { sourcesMatch($0.source, .file(url)) })?.box
            ?? tabs.compactMap { tab -> SZSDocumentBox? in
                guard case .szs(let box) = tab.payload, sourcesMatch(tab.source, .file(url)) else { return nil }
                return box
            }.first
    }

    /// Opens a `.szs`/`.arc` archive as a Workbench tab, the default for double-clicking one
    /// (see `EditorPayload`'s doc comment for why a dedicated window became the exception).
    /// Always the generic tree-on-the-left archive view, `.arc` included, this used to
    /// content-sniff for an NSMBW level and silently open that editor instead, which meant an
    /// ordinary `.arc` double-click could land somewhere the file extension gave no hint of. NSMBW
    /// level editing is opt-in now, via the explicit "New Super Mario Bros. Wii > Edit Level"
    /// context-menu item (`openArchiveAsNSMBWLevelTab`/`...Window`), this still routes back to
    /// an NSMBW tab/window already open on the same source, since re-opening that file shouldn't
    /// spawn a second, disconnected view of it.
    func openArchiveAsTab(data: Data, title: String, source: EditorTab.Source) {
        if let existingWindow = szsWindowSessions.values.first(where: { sourcesMatch($0.source, source) }) {
            pendingSZSWindowID = existingWindow.id
            return
        }
        if let existingWindow = nsmbwWindowSessions.values.first(where: { sourcesMatch($0.source, source) }) {
            pendingNSMBWWindowID = existingWindow.id
            return
        }
        if let existingTab = tabs.first(where: { tab in
            switch tab.payload {
            case .szs, .nsmbwLevel: return sourcesMatch(tab.source, source)
            default: return false
            }
        }) {
            selectedTabID = existingTab.id
            return
        }
        do {
            let (root, compressed) = try SZS.open(data)
            let box = SZSDocumentBox(root: root, wasCompressed: compressed)
            let tab = EditorTab(title: title, payload: .szs(box), source: source)
            tabs.append(tab)
            selectedTabID = tab.id
            log("Opened \(title).")
        } catch {
            report(error)
        }
    }

    /// Opens a `.szs`/`.arc` archive (from any source) in its own dedicated, generic
    /// tree-on-the-left `SZSWindowView` window, see `openArchiveAsTab`'s doc comment on why this
    /// no longer content-sniffs for an NSMBW level. `pendingSZSWindowID` is picked up by whichever
    /// currently-visible view holds `@Environment(\.openWindow)`. This is the explicit "Open in
    /// New Window" path, `openArchiveAsTab` is what double-clicking uses.
    func openArchiveInNewWindow(data: Data, title: String, source: EditorTab.Source) {
        do {
            let (root, compressed) = try SZS.open(data)
            let session = SZSWindowSession(box: SZSDocumentBox(root: root, wasCompressed: compressed), title: title, source: source)
            szsWindowSessions[session.id] = session
            pendingSZSWindowID = session.id
            log("Opened \(title) in a new window.")
        } catch {
            report(error)
        }
    }

    /// The explicit "New Super Mario Bros. Wii > Edit Level" path, unlike `openArchiveAsTab`,
    /// this *does* parse for a level and says clearly when the archive isn't one, rather than
    /// silently falling back to the generic view with no explanation.
    func openArchiveAsNSMBWLevelTab(data: Data, title: String, source: EditorTab.Source) {
        if let existingWindow = nsmbwWindowSessions.values.first(where: { sourcesMatch($0.source, source) }) {
            pendingNSMBWWindowID = existingWindow.id
            return
        }
        if let existingTab = tabs.first(where: { if case .nsmbwLevel = $0.payload { return sourcesMatch($0.source, source) }; return false }) {
            selectedTabID = existingTab.id
            return
        }
        do {
            let (root, compressed) = try SZS.open(data)
            guard let levelDoc = try? NSMBWLevelDocument.parse(root: root) else {
                log("\(title) doesn't look like a New Super Mario Bros. Wii level (no readable course/courseN.bin).")
                return
            }
            let box = NSMBWDocumentBox(doc: levelDoc, root: root, wasCompressed: compressed)
            let tab = EditorTab(title: title, payload: .nsmbwLevel(box), source: source)
            tabs.append(tab)
            selectedTabID = tab.id
            log("Opened \(title) as an NSMBW level.")
        } catch {
            report(error)
        }
    }

    /// The "Edit Level" window counterpart, for a level opened via "Open in New Window" instead.
    func openArchiveAsNSMBWLevelWindow(data: Data, title: String, source: EditorTab.Source) {
        do {
            let (root, compressed) = try SZS.open(data)
            guard let levelDoc = try? NSMBWLevelDocument.parse(root: root) else {
                log("\(title) doesn't look like a New Super Mario Bros. Wii level (no readable course/courseN.bin).")
                return
            }
            let box = NSMBWDocumentBox(doc: levelDoc, root: root, wasCompressed: compressed)
            let session = NSMBWWindowSession(box: box, title: title, source: source)
            nsmbwWindowSessions[session.id] = session
            pendingNSMBWWindowID = session.id
            log("Opened \(title) as an NSMBW level in a new window.")
        } catch {
            report(error)
        }
    }

    /// Real-file counterpart to `openArchiveAsNSMBWLevelTab`/`...Window`, for the "Edit Level"
    /// context-menu item on an ordinary `.szs`/`.arc` in the project (as opposed to one nested
    /// inside another archive, see `openArchiveEntryAsNSMBWLevel` for that case).
    func openFileAsNSMBWLevel(url: URL, forceNewWindow: Bool = false) {
        do {
            let data = try Data(contentsOf: url)
            if forceNewWindow {
                openArchiveAsNSMBWLevelWindow(data: data, title: url.lastPathComponent, source: .file(url))
            } else {
                openArchiveAsNSMBWLevelTab(data: data, title: url.lastPathComponent, source: .file(url))
            }
        } catch {
            report(error)
        }
    }

    /// The "Edit Level" counterpart for a `.szs`/`.arc` nested inside another archive, same
    /// already-open-box reuse as `openArchiveEntry`, just always routed to the NSMBW level tab
    /// rather than content-sniffed.
    func openArchiveEntryAsNSMBWLevel(archiveURL: URL, pathComponents: [String]) {
        let box: SZSDocumentBox
        if let existingBox = liveArchiveBox(atFileURL: archiveURL) {
            box = existingBox
        } else {
            do {
                let data = try Data(contentsOf: archiveURL)
                let (root, compressed) = try SZS.open(data)
                box = SZSDocumentBox(root: root, wasCompressed: compressed)
            } catch {
                report(error)
                return
            }
        }
        guard let entry = box.root.find(path: pathComponents) else {
            log("Couldn't find \(pathComponents.joined(separator: "/")) inside \(archiveURL.lastPathComponent), it may have changed on disk.")
            return
        }
        guard !entry.isDirectory, let entryData = entry.data else {
            log("\(entry.name) is a folder, not a file, inside \(archiveURL.lastPathComponent).")
            return
        }
        openArchiveAsNSMBWLevelTab(data: entryData, title: entry.name, source: .szsEntry(archive: box, node: entry))
    }

    /// Opens one specific entry *inside* a `.szs`/`.arc` archive directly, as its own tab, or
    /// (if it's itself an archive and `forceNewWindow`) its own dedicated window, instead of
    /// landing on the containing archive's own tree with nothing selected, which is
    /// all a plain `openFile(url: archiveURL)` could do. `pathComponents` locates the entry via
    /// `U8Node.find(path:)`; the caller (`ProjectNavigatorView`, for a folder project's nested-
    /// archive preview) only ever has a node from its own disconnected sidebar-preview parse --
    /// see `ProjectNode.archiveEntryContext`'s doc comment, never a live one, so the path is
    /// what actually identifies the entry here, not the node reference itself.
    ///
    /// Reuses the archive's already-open `SZSDocumentBox` (from an existing tab or window) when
    /// there is one, rather than always parsing a fresh copy, parsing fresh regardless would
    /// create a second, disconnected box for the same file that could silently clobber the real
    /// one on save (both believing they're the authoritative in-memory copy).
    func openArchiveEntry(archiveURL: URL, pathComponents: [String], forceNewWindow: Bool) {
        let box: SZSDocumentBox
        if let existingBox = liveArchiveBox(atFileURL: archiveURL) {
            box = existingBox
        } else {
            do {
                let data = try Data(contentsOf: archiveURL)
                let (root, compressed) = try SZS.open(data)
                box = SZSDocumentBox(root: root, wasCompressed: compressed)
                box.fileURL = archiveURL
            } catch {
                report(error)
                return
            }
        }

        guard let entry = box.root.find(path: pathComponents) else {
            log("Couldn't find \(pathComponents.joined(separator: "/")) inside \(archiveURL.lastPathComponent), it may have changed on disk.")
            return
        }
        guard !entry.isDirectory, let entryData = entry.data else {
            log("\(entry.name) is a folder, not a file, inside \(archiveURL.lastPathComponent).")
            return
        }

        if isArchive(name: entry.name, data: entryData) {
            if forceNewWindow {
                openArchiveInNewWindow(data: entryData, title: entry.name, source: .szsEntry(archive: box, node: entry))
            } else {
                openArchiveAsTab(data: entryData, title: entry.name, source: .szsEntry(archive: box, node: entry))
            }
            return
        }

        let tab = EditorTab(title: entry.name, payload: .loading, source: .szsEntry(archive: box, node: entry))
        tabs.append(tab)
        selectedTabID = tab.id
        loadPayload(into: tab, name: entry.name, data: entryData, source: .szsEntry(archive: box, node: entry), successLog: "Opened \(entry.name) from \(archiveURL.lastPathComponent).")
    }

    func saveNSMBWWindow(_ session: NSMBWWindowSession) {
        saveNSMBWLevel(box: session.box, title: session.title, source: session.source)
    }

    private func saveNSMBWLevel(box: NSMBWDocumentBox, title: String, source: EditorTab.Source) {
        box.doc.write(into: box.root)
        let data = SZS.save(root: box.root, compressed: box.wasCompressed)
        switch source {
        case .file(let url):
            do {
                try data.write(to: url, options: .atomic)
                box.isDirty = false
                log("Saved \(title).")
                if case .folder(let root) = project { git.refresh(repoURL: root.url) }
            } catch {
                report(error)
            }
        case .szsEntry(let archive, let node):
            node.data = data
            archive.isDirty = true
            box.isDirty = false
            log("Updated \(title) inside its parent archive (save that archive's window to write it to disk).")
        case .discEntry(let discURL, let disc, let node):
            guard !isSavingToDisc else { return }
            isSavingToDisc = true
            log("Writing \(title) back into the disc image...")
            Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    try FileOperations.writeDiscEntry(discURL: discURL, disc: disc, node: node, data: data) { msg in
                        Task { @MainActor in self?.log(msg) }
                    }
                    await MainActor.run {
                        box.isDirty = false
                        self?.isSavingToDisc = false
                        self?.log("Saved \(title) into the disc image.")
                    }
                } catch {
                    await MainActor.run {
                        self?.isSavingToDisc = false
                        self?.report(error)
                    }
                }
            }
        }
    }

    func closeNSMBWWindow(_ id: UUID) {
        nsmbwWindowSessions.removeValue(forKey: id)
    }

    func saveSZSWindow(_ session: SZSWindowSession) {
        let data = SZS.save(root: session.box.root, compressed: session.box.wasCompressed)
        switch session.source {
        case .file(let url):
            do {
                try data.write(to: url, options: .atomic)
                session.box.isDirty = false
                log("Saved \(session.title).")
                if case .folder(let root) = project { git.refresh(repoURL: root.url) }
            } catch {
                report(error)
            }
        case .szsEntry(let archive, let node):
            node.data = data
            archive.isDirty = true
            session.box.isDirty = false
            log("Updated \(session.title) inside its parent archive (save that archive's window to write it to disk).")
        case .discEntry(let discURL, let disc, let node):
            guard !isSavingToDisc else { return }
            isSavingToDisc = true
            log("Writing \(session.title) back into the disc image...")
            Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    try FileOperations.writeDiscEntry(discURL: discURL, disc: disc, node: node, data: data) { msg in
                        Task { @MainActor in self?.log(msg) }
                    }
                    await MainActor.run {
                        session.box.isDirty = false
                        self?.isSavingToDisc = false
                        self?.log("Saved \(session.title) into the disc image.")
                    }
                } catch {
                    await MainActor.run {
                        self?.isSavingToDisc = false
                        self?.report(error)
                    }
                }
            }
        }
    }

    func closeSZSWindow(_ id: UUID) {
        szsWindowSessions.removeValue(forKey: id)
    }

    /// Formats `NSImage(data:)` can actually decode, what "open an image file" means here.
    /// Not `private`: `SZSWindowView`'s nested-entry viewer reuses this same list.
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "heic", "webp", "ico"]

    /// Appends `tab` (already in `tabs` with a `.loading` payload) and parses its real payload in
    /// the background, swapping it in via `EditorTab.finishLoading` once ready, see
    /// `resolvePayload`'s doc comment for why the parse itself doesn't block the main thread. A
    /// thrown parse failure closes the placeholder tab and reports the error, matching what the
    /// old synchronous open did (abort with no tab left behind).
    private func loadPayload(into tab: EditorTab, name: String, data: Data, source: EditorTab.Source, successLog: String) {
        Task { [weak self, weak tab] in
            guard let self, let tab else { return }
            do {
                let payload = try await self.resolvePayload(name: name, data: data, source: source)
                tab.finishLoading(payload)
                self.log(successLog)
            } catch {
                self.closeTab(tab)
                self.report(error)
            }
        }
    }

    /// Runs `body` on a background thread and hops back once it's done, used to keep a format's
    /// actual byte-parsing (`KCLDocument.parse` and friends, all plain nonisolated types) off the
    /// main thread, so opening a large file doesn't hitch the UI. Only the lightweight step of
    /// wrapping the parsed result in its `@MainActor` `*DocumentBox` runs back here on the main
    /// actor, see `resolvePayload`.
    private func parseOffMain<T>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try body() }.value
    }

    /// The one place that decides which editor a file's bytes get, by extension: this app's
    /// own built-in formats, and finally the raw hex-dump fallback for anything
    /// unrecognized. Shared by `loadPayload` (top-level open, via `openFile`/`openDiscEntry`/
    /// `openArchiveEntry`) and `NestedEntryView.parse()` (an entry selected inside an open
    /// archive), see each call site for how they handle a thrown parse failure differently
    /// (top-level aborts the open with an error; nested falls back to the raw view, matching this
    /// function's own fallback behavior for every other unrecognized/malformed case).
    /// The `.bmd`/`.bdl` a `.btk` animates: the one beside it with the same name (or the name it
    /// extends, e.g. `x_course_02.btk` -> `x_course.bmd`), else any model beside it.
    private static func siblingModelData(for name: String, source: EditorTab.Source) -> Data? {
        let stem = (name as NSString).deletingPathExtension.lowercased()
        func pick(_ names: [String]) -> String? {
            let models = names.filter { ["bmd", "bdl"].contains(($0 as NSString).pathExtension.lowercased()) }
            func s(_ n: String) -> String { (n as NSString).deletingPathExtension.lowercased() }
            return models.first { s($0) == stem } ?? models.filter { stem.hasPrefix(s($0)) }.max { s($0).count < s($1).count } ?? models.first
        }
        switch source {
        case .file(let url):
            let dir = url.deletingLastPathComponent()
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path), let n = pick(names) else { return nil }
            return try? Data(contentsOf: dir.appendingPathComponent(n))
        case .szsEntry(_, let node):
            let siblings = node.parent?.children ?? []
            guard let n = pick(siblings.map(\.name)), let raw = siblings.first(where: { $0.name == n })?.data else { return nil }
            return Yaz0.isYaz0(raw) ? try? Yaz0.decode(raw) : raw
        case .discEntry:
            return nil
        }
    }

    func resolvePayload(name: String, data: Data, source: EditorTab.Source) async throws -> EditorPayload {
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "kmp" || ext == "bol" {
            let doc = try await parseOffMain { try KMPDocument.parse(data) }
            return .kmp(KMPDocumentBox(doc: doc))
        } else if ext == "brres" {
            let doc = try await parseOffMain { try BRRESDocument.parse(data) }
            return .brres(BRRESDocumentBox(doc: doc, fileName: name))
        } else if ext == "bmg" {
            let doc = try await parseOffMain { try BMGDocument.parse(data) }
            return .bmg(BMGDocumentBox(doc: doc))
        } else if ext == "breft" {
            let doc = try await parseOffMain { try REFT.parse(data) }
            return .tpl(TPLDocumentBox(doc: doc, rawData: data))
        } else if ext == "breff" {
            let doc = try await parseOffMain { try REFFDocument.parse(data) }
            return .effect(EffectDocumentBox(doc: doc, rawData: data))
        } else if BinaryFieldSchema.extensions.contains(ext), let box = BinaryFieldsBox(fileName: name, data: data) {
            return .fields(box)
        } else if ext == "bti" || ext == "btienv" || ext == "btimat" {
            let doc = try await parseOffMain { TPLDocument(j3d: [try J3DModel.bti(data, name: name)]) }
            return .tpl(TPLDocumentBox(doc: doc, rawData: data))
        } else if ext == "bmd" || ext == "bdl" {
            let stem = (name as NSString).deletingPathExtension
            let (model, preview, lookup, textures, metrics) = try await parseOffMain { () -> (J3DModel.Model, MDL0Model?, [String: DecodedTexture], TPLDocument, [TrackBudget.Metric: Int]?) in
                let model = try J3DModel.parse(data)
                let brres = (try? J3DToWii.brres(from: model, modelName: stem, scale: 1)).flatMap { try? BRRESDocument.parse($0) }
                let preview = brres.flatMap { doc in doc.resources.first { $0.magic == "MDL0" }.flatMap { MDL0Parser.parse($0, rawFile: doc.rawData) } }
                return (model, preview, brres.map(MDL0SceneKit.textureImages) ?? [:], TPLDocument(j3d: model.textures), TrackBudget.j3dMetrics(data))
            }
            return .j3d(J3DDocumentBox(model: model, preview: preview, textureLookup: lookup, textures: textures, rawData: data, metrics: metrics))
        } else if ext == "btk" || ext == "bca" {
            let modelData = ext == "btk" ? Self.siblingModelData(for: name, source: source) : nil
            let (animation, model, images) = try await parseOffMain { () -> (J3DAnimation.Animation, J3DModel.Model?, [NSImage?]) in
                let model = modelData.flatMap { try? J3DModel.parse($0) }
                let images = model?.textures.map { t in t.decoded().flatMap { ImageUtil.nsImage(fromRGBA: $0, width: t.width, height: t.height) } } ?? []
                return (try J3DAnimation.parse(data), model, images)
            }
            let box = J3DAnimationDocumentBox(animation: animation, rawData: data)
            box.model = model
            box.textureImages = images
            return .j3dAnimation(box)
        } else if ext == "tpl" {
            let doc = try await parseOffMain { try TPLDocument.parse(data) }
            return .tpl(TPLDocumentBox(doc: doc, rawData: data))
        } else if ext == "kcl" || ext == "bco" {
            let doc = try await parseOffMain { try KCLDocument.parse(data) }
            let box = KCLDocumentBox(doc: doc)
            if case .file(let u) = source { box.pendingOBJURL = pendingKCLOBJ.removeValue(forKey: u) }
            return .kcl(box)
        } else if ext == "brstm" {
            let doc = try await parseOffMain { try BRSTMDocument.parse(data) }
            return .brstm(BRSTMDocumentBox(doc: doc, rawData: data))
        } else if ext == "brlyt" {
            let doc = try await parseOffMain { try BRLYTDocument.parse(data) }
            return .brlyt(BRLYTDocumentBox(doc: doc))
        } else if ext == "brlan" {
            let doc = try await parseOffMain { try BRLANDocument.parse(data) }
            return .brlan(BRLANDocumentBox(doc: doc, rawData: data))
        } else if ext == "brsar" {
            let doc = try await parseOffMain { try BRSARDocument.parse(data) }
            return .brsar(BRSARDocumentBox(doc: doc, rawData: data))
        } else if ext == "obj", let text = String(data: data, encoding: .utf8) {
            var url: URL?
            if case .file(let u) = source { url = u }
            return .obj(OBJDocumentBox(text: text, rawData: data, objURL: url))
        } else if ext == "dae" {
            // Shown with the same mesh viewer as an .obj; the file itself is never rewritten.
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("dae-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            var folder = temp
            if case .file(let u) = source { folder = u.deletingLastPathComponent() }
            let (text, mtl) = try DAEImporter.convert(data, name: "model.dae", base: "model", modelFolder: folder, textureFolder: temp)
            try mtl.write(to: temp.appendingPathComponent("model.mtl"), atomically: true, encoding: .utf8)
            return .obj(OBJDocumentBox(text: text, rawData: data, objURL: temp.appendingPathComponent("model.obj")))
        } else if ext == "wiiui" {
            var url: URL?
            if case .file(let u) = source { url = u }
            return .uiDesign(UIDesignBox(doc: try UIDocument.parse(data), url: url))
        } else if ext == "wiinodes" {
            var url: URL?
            if case .file(let u) = source { url = u }
            return .nodeGraph(NodeGraphBox(graph: try NodeGraph.parse(data), url: url))
        } else if ext == "mtl", let text = String(data: data, encoding: .utf8) {
            let url: URL?
            if case .file(let u) = source { url = u } else { url = nil }
            return .mtl(MTLDocumentBox(text: text, rawData: data, url: url))
        } else if AudioFileImport.convertibleExtensions.contains(ext) {
            // AVFoundation reads from a URL: use the file itself, or a temporary copy of an
            // archive/disc entry's bytes.
            let url: URL
            if case .file(let u) = source { url = u } else {
                url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
                try data.write(to: url)
            }
            let audio = try await parseOffMain { try AudioFileImport.load(url, sampleRate: 32000) }
            let doc = BRSTMDocument()
            doc.replaceAudio(channels: audio.channels, sampleRate: audio.sampleRate)
            return .brstm(BRSTMDocumentBox(doc: doc, rawData: data, sourceAudioName: name))
        } else if Self.imageExtensions.contains(ext) {
            return .image(ImageDocumentBox(rawData: data))
        } else if CodeLanguage.allRecognizedExtensions.contains(ext), let text = String(data: data, encoding: .utf8) {
            let language = CodeLanguage.detect(fileName: name, contents: text)
            return .code(CodeDocumentBox(text: text, language: language))
        } else {
            return .raw(RawDocumentBox(data: data))
        }
    }

    // MARK: Saving

    @Published var isSavingToDisc = false

    func save(_ tab: EditorTab) {
        do {
            let data = try serialize(tab)
            switch tab.source {
            case .file(let url):
                try data.write(to: url, options: .atomic)
                clearDirty(tab)
                log("Saved \(tab.title).")
                if case .folder(let root) = project { git.refresh(repoURL: root.url) }
            case .szsEntry(let archive, let node):
                node.data = data
                // Opened from a closed archive: nothing else will ever save it, so write it now.
                if let url = archive.fileURL, liveArchiveBox(atFileURL: url) == nil {
                    try SZS.save(root: archive.root, compressed: archive.wasCompressed).write(to: url, options: .atomic)
                    archive.isDirty = false
                    clearDirty(tab)
                    log("Saved \(tab.title) into \(url.lastPathComponent).")
                    if case .folder(let root) = project { git.refresh(repoURL: root.url) }
                    return
                }
                archive.isDirty = true
                clearDirty(tab)
                log("Updated \(tab.title) inside its parent archive (save that archive's window to write it to disk).")
            case .discEntry(let discURL, let disc, let node):
                guard !isSavingToDisc else { return }
                isSavingToDisc = true
                log("Writing \(tab.title) back into the disc image...")
                Task.detached(priority: .userInitiated) { [weak self] in
                    do {
                        try FileOperations.writeDiscEntry(discURL: discURL, disc: disc, node: node, data: data) { msg in
                            Task { @MainActor in self?.log(msg) }
                        }
                        await MainActor.run {
                            self?.clearDirty(tab)
                            self?.isSavingToDisc = false
                            self?.log("Saved \(tab.title) into the disc image.")
                        }
                    } catch {
                        await MainActor.run {
                            self?.isSavingToDisc = false
                            self?.report(error)
                        }
                    }
                }
            }
        } catch {
            report(error)
        }
    }

    func saveSelected() {
        guard let tab = selectedTab, !tab.isLoading else { return }
        // Flush a nested entry's pending write-back first so the archive serializes with the edit.
        NotificationCenter.default.post(name: .szsFlushPendingEdits, object: nil)
        save(tab)
    }

    func saveSelectedAs() {
        guard let tab = selectedTab, !tab.isLoading else { return }
        NotificationCenter.default.post(name: .szsFlushPendingEdits, object: nil)
        PanelPresenter.saveFile(configure: { $0.nameFieldStringValue = tab.title }) { [weak self] url in
            if let url { self?.saveAs(tab, to: url) }
        }
    }

    typealias Conversion = (title: String, ext: String, run: (URL) throws -> Void)

    private static func exportOBJ(_ doc: BRRESDocument, to url: URL) throws {
        guard let r = doc.resources.first(where: { $0.magic == "MDL0" && $0.name == "course" }) ?? doc.resources.first(where: { $0.magic == "MDL0" }),
              let model = MDL0Parser.parse(r, rawFile: doc.rawData) else { throw WSError.badStructure("No readable model in this BRRES.") }
        try OBJExporter.write(model, textures: MDL0SceneKit.textureImages(in: doc), to: url)
    }

    /// The conversions available for a file on disk (right-click in the Project Navigator), read when run.
    /// A Project Navigator row's conversions: a file on disk, or a file inside an open or closed .szs/.arc.
    func entryConversions(for node: ProjectNode) -> [Conversion] {
        guard !node.isDirectory, node.discContext == nil else { return [] }
        if let ctx = node.archiveEntryContext {
            let archive = ctx.archiveURL, path = ctx.node.pathFromRoot
            return Self.fileConversions(name: node.name) { [weak self] in
                guard let data = self?.archiveEntrySubtree(archiveURL: archive, pathComponents: path)?.data else {
                    throw WSError.badStructure("Couldn't read \(node.name) from \(archive.lastPathComponent).")
                }
                return data
            }
        }
        let url = node.url
        return Self.fileConversions(name: node.name) { try Data(contentsOf: url) }
    }

    static func fileConversions(name: String, read: @escaping () throws -> Data) -> [Conversion] {
        let ext = (name as NSString).pathExtension.lowercased(), stem = (name as NSString).deletingPathExtension
        func data(_ title: String, _ ext: String, _ make: @escaping (Data) throws -> Data) -> Conversion {
            (title, ext, { try make(read()).write(to: $0, options: .atomic) })
        }
        switch ext {
        case "kcl": return [data("Convert to Double Dash BCO...", "bco") {
            let kcl = try KCLDocument.parse($0)
            guard let choices = BCOSurfaceChoicesView.ask(MKWiiToMKDD.unmatchedTypes(in: kcl)) else { throw CocoaError(.userCancelled) }
            return MKDDFileConvert.kclToBCO(kcl, choices: choices)
        }]
        case "bco": return [data("Convert to Mario Kart Wii KCL...", "kcl") {
            guard let wallStrip = WallStripPicker.ask() else { throw CocoaError(.userCancelled) }
            return try MKDDFileConvert.bcoToKCL($0, wallStrip: wallStrip).serialize()
        }]
        case "kmp": return [data("Convert to Double Dash BOL...", "bol") { try MKDDFileConvert.kmpToBOL(try KMPDocument.parse($0)).serialize() }]
        case "bol": return [data("Convert to Mario Kart Wii KMP...", "kmp") { try MKDDFileConvert.bolToKMP($0).serialize() }]
        case "bmd", "bdl": return [data("Convert to Mario Kart Wii BRRES...", "brres") { try MKDDFileConvert.bmdToBRRES($0) }]
        case "btk": return [data("Convert to Mario Kart Wii Texture Animation (BRRES)...", "brres") { try MKDDFileConvert.btkToSRT0BRRES($0, name: stem) }]
        case "brres":
            var items: [Conversion] = [data("Convert Model to Double Dash BMD...", "bmd") { try MKDDFileConvert.brresToBMD($0) }]
            items.append(("Export Model as OBJ...", "obj", { try exportOBJ(try BRRESDocument.parse(read()), to: $0) }))
            items.append(data("Convert Texture Animation (SRT0) to Double Dash BTK...", "btk") { try MKDDFileConvert.brresToBTK($0) })
            return items
        default: return []
        }
    }

    /// The file the Project Navigator has selected (nil for none or several), for the Convert menu.
    @Published var selectedNavigatorNode: ProjectNode?

    /// What the menu bar's Convert menu acts on: the file just clicked in the Project Navigator
    /// (until the user switches tab), else the open tab's file. `archiveURL` is set for a `.szs`/`.wbz`/`.wlz` on disk, which can be
    /// rewritten in another archive format.
    var convertTarget: (name: String, conversions: [Conversion], archiveURL: URL?)? {
        func archive(_ url: URL) -> URL? { WiimmArchive.Format(rawValue: url.pathExtension.lowercased()) != nil ? url : nil }
        if let n = selectedNavigatorNode, !n.isDirectory, n.discContext == nil {
            return (n.name, entryConversions(for: n), n.archiveEntryContext == nil ? archive(n.url) : nil)
        }
        if let tab = selectedTab, case .file(let url) = tab.source {
            return (url.lastPathComponent, Self.fileConversions(name: url.lastPathComponent) { try Data(contentsOf: url) }, archive(url))
        }
        return nil
    }

    /// Asks where to save, then runs a conversion.
    func runConversion(_ c: Conversion, suggestedName: String) {
        let name = (suggestedName as NSString).deletingPathExtension + "." + c.ext
        PanelPresenter.saveFile(configure: { $0.nameFieldStringValue = name }) { [weak self] url in
            guard let url else { return }
            do {
                try c.run(url)
                self?.log("Wrote \(url.lastPathComponent).")
                AppNotifications.conversion(success: true, detail: "Wrote \(url.lastPathComponent).")
            }
            catch CocoaError.userCancelled {}
            catch {
                self?.report(error)
                AppNotifications.conversion(success: false, detail: error.localizedDescription)
            }
        }
    }

    func saveAs(_ tab: EditorTab, to url: URL) {
        do {
            let data = try serialize(tab)
            try data.write(to: url, options: .atomic)
            tab.source = .file(url)
            tab.title = url.lastPathComponent
            clearDirty(tab)
            log("Saved as \(url.lastPathComponent).")
        } catch {
            report(error)
        }
    }

    private func serialize(_ tab: EditorTab) throws -> Data {
        switch tab.payload {
        case .kmp(let box):
            return box.doc.serialize()
        case .brres(let box):
            return box.doc.serialize()
        case .bmg(let box):
            return box.doc.serialize()
        case .tpl(let box):
            return box.rawData
        case .kcl(let box):
            return box.doc.serialize()
        case .szs(let box):
            return SZS.save(root: box.root, compressed: box.wasCompressed)
        case .nsmbwLevel(let box):
            box.doc.write(into: box.root)
            return SZS.save(root: box.root, compressed: box.wasCompressed)
        case .brstm(let box):
            // A plain audio file is only previewed here; its bytes are never replaced by a BRSTM.
            return box.sourceAudioName == nil ? box.doc.serialize() : box.rawData
        case .brlyt(let box):
            return box.doc.serialize()
        case .brlan(let box):
            return box.rawData
        case .brsar(let box):
            return box.rawData
        case .j3d(let box):
            return box.rawData
        case .j3dAnimation(let box):
            return box.rawData
        case .code(let box):
            return Data(box.text.utf8)
        case .raw(let box):
            return box.data
        case .obj(let box):
            return box.rawData
        case .mtl(let box):
            return box.rawData
        case .uiDesign(let box):
            return box.doc.serialize()
        case .nodeGraph(let box):
            return box.graph.serialize()
        case .image(let box):
            return box.rawData
        case .fields(let box):
            return box.data
        case .effect(let box):
            return box.rawData
        case .loading:
            return Data()
        }
    }

    private func clearDirty(_ tab: EditorTab) {
        switch tab.payload {
        case .kmp(let box): box.isDirty = false
        case .brres(let box): box.isDirty = false
        case .bmg(let box): box.isDirty = false
        case .tpl: break
        case .kcl(let box): box.isDirty = false
        case .szs(let box): box.isDirty = false
        case .nsmbwLevel(let box): box.isDirty = false
        case .brstm(let box): box.isDirty = false
        case .brlyt(let box): box.isDirty = false
        case .brlan: break
        case .brsar: break
        case .j3d, .j3dAnimation: break
        case .code(let box): box.isDirty = false
        case .raw(let box): box.isDirty = false
        case .obj: break
        case .mtl: break
        case .uiDesign(let box): box.isDirty = false
        case .nodeGraph(let box): box.isDirty = false
        case .image: break
        case .fields(let box): box.isDirty = false
        case .effect: break
        case .loading: break
        }
    }

    func markDirty(_ tab: EditorTab) {
        switch tab.payload {
        case .kmp(let box): box.isDirty = true
        case .brres(let box): box.isDirty = true
        case .bmg(let box): box.isDirty = true
        case .tpl: break
        case .kcl(let box): box.isDirty = true
        case .szs(let box): box.isDirty = true
        case .nsmbwLevel(let box): box.isDirty = true
        case .brstm(let box): box.isDirty = true
        case .brlyt(let box): box.isDirty = true
        case .brlan: break
        case .brsar: break
        case .j3d, .j3dAnimation: break
        case .code(let box): box.isDirty = true
        case .raw(let box): box.isDirty = true
        case .obj: break
        case .mtl(let box): box.isDirty = true
        case .uiDesign(let box): box.isDirty = true
        case .nodeGraph(let box): box.isDirty = true
        case .image: break
        case .fields(let box): box.isDirty = true
        case .effect: break
        case .loading: break
        }
    }

    // MARK: Creating a new KCL from an .obj

    /// The only way to get a `.kcl` onto a mesh that isn't already an existing `.kcl` file or
    /// archive entry: pick a source `.obj`, pick where the new file should live, write it, and
    /// open it as a tab. (An *existing* open `.kcl` tab can also wholesale-replace its mesh from
    /// an `.obj` via `KCLEditorView`'s own "Create From .obj", this is for starting from scratch.)
    /// Source .obj to review in the editor once the freshly written .kcl at this URL finishes loading.
    private var pendingKCLOBJ: [URL: URL] = [:]

    func newKCLFromOBJ(in directoryURL: URL? = nil) {
        PanelPresenter.openFile(configure: {
            $0.allowedContentTypes = ModelFile.contentTypes
        }) { [weak self] objURL in
            guard let self, let objURL else { return }
            do {
                let (text, sourceURL) = try ModelFile.objSource(objURL)
                let triangles = OBJImporter.parse(text)
                guard !triangles.isEmpty else {
                    self.errorMessage = "No triangles were found in that model file."
                    return
                }
                guard triangles.count <= 65535 else {
                    self.errorMessage = "That model has \(triangles.count) triangles, but KCL prisms are limited to 65535. Simplify the mesh and try again."
                    return
                }
                let flags = OBJImporter.assignFlagsByMaterial(triangles, materials: OBJImporter.loadMTLMaterials(objText: text, objURL: sourceURL))
                let doc = KCLDocument()
                doc.triangles = zip(triangles, flags).map { KCLTriangle.facingUp($0.v0, $0.v1, $0.v2, attribute: $1) }
                PanelPresenter.saveFile(configure: {
                    if let kclType = UTType(filenameExtension: "kcl") { $0.allowedContentTypes = [kclType] }
                    $0.nameFieldStringValue = "course"
                    if let directoryURL { $0.directoryURL = directoryURL }
                }) { [weak self] destURL in
                    guard let self, let destURL else { return }
                    // Serialize off the main thread: on a big track mesh it takes long enough to
                    // freeze the UI. `serialize()` silently returns empty data if the mesh needs
                    // more than 65535 prisms/positions/normals (the format's index limit); writing
                    // that out would make a 0-byte .kcl that crashes the game.
                    nonisolated(unsafe) let doc = doc
                    self.busyMessage = "Building collision for \(triangles.count) triangles..."
                    Task {
                        let data = await Task.detached(priority: .userInitiated) { doc.serialize() }.value
                        self.busyMessage = nil
                        guard !data.isEmpty else {
                            self.errorMessage = "This mesh is too complex to fit in one KCL file (over 65535 prisms, positions, or normals after processing). Simplify it and try again."
                            return
                        }
                        do {
                            try data.write(to: destURL, options: .atomic)
                        } catch {
                            self.report(error)
                            return
                        }
                        self.log("Created \(destURL.lastPathComponent) from \(objURL.lastPathComponent) (\(triangles.count) triangles).")
                        // A tab already showing the file it replaced would keep (and save over it
                        // with) the old collision, and never show the material review.
                        for tab in self.tabs { if case .file(let u) = tab.source, u == destURL { self.closeTab(tab) } }
                        self.pendingKCLOBJ[destURL] = objURL
                        self.openFile(url: destURL)
                    }
                }
            } catch {
                self.report(error)
            }
        }
    }

    // MARK: Creating a new BRRES (real MDL0 model) from an .obj

    /// Builds a real, loadable MDL0 model from an `.obj` mesh (flat-shaded, untextured, no
    /// skinning, see `MDL0Writer`'s doc comment for exactly what that means and its limits) and
    /// wraps it in a fresh `.brres`, the only way to get an `.obj` mesh into a format the game/
    /// Dolphin can actually draw.
    func newBRRESFromOBJ(in directoryURL: URL? = nil) {
        PanelPresenter.openFile(configure: {
            $0.allowedContentTypes = ModelFile.contentTypes
        }) { [weak self] objURL in
            guard let self, let objURL else { return }
            do {
                let (text, sourceURL) = try ModelFile.objSource(objURL)
                let objFileName = objURL.deletingPathExtension().lastPathComponent
                let modelName: String
                let suggestedBRRESName: String
                
                if objFileName.hasSuffix("_model") {
                    // For files like "course_model.obj", use "course" as model name
                    modelName = String(objFileName.dropLast(6)) // Remove "_model"
                    suggestedBRRESName = objFileName // Keep "course_model" for .brres
                } else {
                    // For files like "my_track.obj", use "my_track" as model name
                    // and suggest "my_track_model.brres" as the BRRES filename
                    modelName = objFileName
                    suggestedBRRESName = "\(objFileName)_model"
                }
                
                PanelPresenter.saveFile(configure: {
                    if let brresType = UTType(filenameExtension: "brres") { $0.allowedContentTypes = [brresType] }
                    $0.nameFieldStringValue = suggestedBRRESName
                    if let directoryURL { $0.directoryURL = directoryURL }
                }) { [weak self] destURL in
                    guard let self, let destURL else { return }
                    // Built only once the destination is known: saving as `course_model.brres`
                    // means the MDL0 inside has to be named `course`, or the game won't find it.
                    guard let (doc, triangleCount) = self.buildBRRESFromOBJ(
                        text: text, objURL: sourceURL, modelName: modelName,
                        brresFileName: destURL.lastPathComponent) else { return }
                    do {
                        try doc.serialize().write(to: destURL, options: .atomic)
                        self.log("Created \(destURL.lastPathComponent) from \(objURL.lastPathComponent) (\(triangleCount) triangles).")
                        self.openFile(url: destURL)
                    } catch {
                        self.report(error)
                    }
                }
            } catch {
                self.report(error)
            }
        }
    }

    /// Right-click "Make .brres" on a real `.obj` file already in the Project Navigator: the same
    /// conversion `newBRRESFromOBJ` does (a same-named companion `.mtl`, if present, picked up the
    /// same way), just with the source and destination already implied by the file being
    /// right-clicked, no file panels needed, and the result is written alongside the `.obj`.
    /// Reads the textures a `.brres` model offers to keep or drop when building a map model
    /// (see `MapModelBuilder`). Returns nil, having said why in the console, when there's
    /// nothing to offer, so a model this app can't read geometry out of never opens an empty
    /// picker.
    func mapModelOptions(inBRRES data: Data, named name: String) -> [MapModelBuilder.TextureOption]? {
        guard let options = MapModelBuilder.options(inBRRES: data), !options.isEmpty else {
            log("\(name): \(MapModelBuilder.BuildError.noReadableModel.localizedDescription)")
            return nil
        }
        return options
    }

    func mapModelOptions(forBRRESAt url: URL) -> [MapModelBuilder.TextureOption]? {
        do {
            return mapModelOptions(inBRRES: try Data(contentsOf: url), named: url.lastPathComponent)
        } catch {
            report(error)
            return nil
        }
    }

    /// Mario Kart Wii looks a course's minimap model up by the fixed name `map_model.brres`,
    /// whose model resource is named `map`, the same rule `OBJToBRRES.requiredModelNames`
    /// already encodes for the .obj import path.
    private static let mapModelFileName = "map_model.brres"

    private func buildMapModel(from data: Data, keeping selected: [String: UInt8]) throws -> Data {
        try MapModelBuilder.build(fromBRRES: data, shades: selected,
                                  modelName: OBJToBRRES.modelName(forBRRESNamed: Self.mapModelFileName, fallback: "map"))
    }

    /// Writes the minimap model beside a `.brres` that lives in the project as a real file.
    func createMapModel(fromBRRESAt url: URL, keeping selected: [String: UInt8]) {
        do {
            let out = try buildMapModel(from: try Data(contentsOf: url), keeping: selected)
            // Always the fixed name, overwriting a previous map model rather than
            // `uniqueFileURL`'s "make a new file" behavior. Mario Kart Wii only ever loads a
            // course's minimap from the exact filename `map_model.brres`, so a regenerated map
            // landing at `map_model 2.brres` next to a stale original is silently never loaded
            // by the game (the reported "map model still doesn't appear" bug).
            let destURL = url.deletingLastPathComponent().appendingPathComponent(Self.mapModelFileName)
            try out.write(to: destURL, options: .atomic)
            log("Created \(destURL.lastPathComponent) from \(url.lastPathComponent) (\(selected.count) texture(s) kept).")
            refreshFolderTree()
            if case .folder(let root) = project { git.refresh(repoURL: root.url) }
            openFile(url: destURL)
        } catch {
            report(error)
        }
    }

    /// Replaces one entry's bytes inside a `.szs`/`.arc`, by path, `TrackPreviewView`'s "Save"
    /// (after placing an object or editing course.kmp), for a course archive nested inside another
    /// archive. Goes through `mutateArchive` like everything else here, so it reuses an already-open
    /// live box instead of risking two disconnected copies of the same file.
    func replaceArchiveEntryData(archiveURL: URL, pathComponents: [String], data: Data) {
        let result = mutateArchive(at: archiveURL) { root in
            guard let entry = root.find(path: pathComponents) else { return }
            entry.data = data
        }
        guard result == .succeeded else { return }
        log("Saved \(pathComponents.last ?? "entry") in \(archiveURL.lastPathComponent).")
    }

    /// Writes the minimap model as an entry in the archive the source model already lives in,
    /// alongside it, where a real course `.szs` keeps its own `map_model.brres`. Replaces an
    /// existing entry of that exact name instead of `newArchiveFile`'s uniquified name, for the
    /// same reason as the on-disk path above: the game loads by that exact filename only.
    func createMapModel(fromBRRESData data: Data, named name: String, keeping selected: [String: UInt8],
                        archiveURL: URL, pathComponents: [String]) {
        do {
            let out = try buildMapModel(from: data, keeping: selected)
            var found = true
            let result = mutateArchive(at: archiveURL) { root in
                guard let parent = root.find(path: pathComponents) else { found = false; return }
                if let existing = parent.children.first(where: { $0.name == Self.mapModelFileName && !$0.isDirectory }) {
                    existing.data = out
                } else {
                    let node = U8Node(name: Self.mapModelFileName, isDirectory: false, data: out)
                    node.parent = parent
                    parent.children.append(node)
                }
            }
            guard found else {
                log("Couldn't find that folder inside \(archiveURL.lastPathComponent), it may have changed.")
                return
            }
            guard result == .succeeded else { return }
            log("Created \(Self.mapModelFileName) in \(archiveURL.lastPathComponent) from \(name) (\(selected.count) texture(s) kept).")
        } catch {
            report(error)
        }
    }

    func makeBRRES(fromOBJAt objURL: URL) {
        do {
            let (text, sourceURL) = try ModelFile.objSource(objURL)
            let objFileName = objURL.deletingPathExtension().lastPathComponent
            let modelName: String
            let suggestedBRRESName: String

            if objFileName.hasSuffix("_model") {
                // For files like "course_model.obj", use "course" as model name
                modelName = String(objFileName.dropLast(6)) // Remove "_model"
                suggestedBRRESName = objFileName + ".brres" // Keep "course_model" for .brres
            } else {
                // For files like "my_track.obj", use "my_track" as model name
                // and suggest "my_track_model.brres" as the BRRES filename
                modelName = objFileName
                suggestedBRRESName = "\(objFileName)_model.brres"
            }

            let destURL = uniqueFileURL(preferredName: suggestedBRRESName, in: objURL.deletingLastPathComponent())
            guard let (doc, triangleCount) = buildBRRESFromOBJ(text: text, objURL: sourceURL, modelName: modelName, brresFileName: destURL.lastPathComponent) else { return }
            try doc.serialize().write(to: destURL, options: .atomic)
            log("Created \(destURL.lastPathComponent) from \(objURL.lastPathComponent) (\(triangleCount) triangles).")
            refreshFolderTree()
            if case .folder(let root) = project { git.refresh(repoURL: root.url) }
            openFile(url: destURL)
        } catch {
            report(error)
        }
    }

    /// Right-click "Make Archive" on a real folder in the Project Navigator, packs its whole
    /// contents into a new, Finder-style unique-named `.szs`/`.wbz`/`.wlz` alongside it. The source
    /// folder itself is only ever read, never deleted or moved.
    func makeArchive(fromFolderAt folderURL: URL, format: WiimmArchive.Format) {
        do {
            let root = U8Node(name: "", isDirectory: true)
            try populateU8Node(root, fromDirectory: folderURL)
            let destURL = uniqueFileURL(preferredName: "\(folderURL.lastPathComponent).\(format.rawValue)", in: folderURL.deletingLastPathComponent())
            writeArchive(from: { U8Archive.serialize(root) }, to: destURL, format: format, sourceName: folderURL.lastPathComponent)
        } catch {
            report(error)
        }
    }

    /// Right-click "Convert To" on a `.szs`/`.wbz`/`.wlz`: writes the same archive in another
    /// format beside it (same name, new extension, made unique if taken).
    func convertArchive(at url: URL, to format: WiimmArchive.Format) {
        let destURL = uniqueFileURL(preferredName: url.deletingPathExtension().lastPathComponent + "." + format.rawValue, in: url.deletingLastPathComponent())
        let references = Self.wu8References()
        writeArchive(from: {
            try WiimmArchive.decode(try Data(contentsOf: url), references: references)
        }, to: destURL, format: format, sourceName: url.lastPathComponent)
    }

    /// Off the main thread: `.wbz`/`.wlz` are coded against the retail object files, which are
    /// read from the linked base game disc the first time.
    private func writeArchive(from makeU8: @escaping @Sendable () throws -> Data, to destURL: URL, format: WiimmArchive.Format, sourceName: String) {
        if format != .szs, let iso = BaseGameLibrary.linkedISO { KeyManager.shared.autoLoad(nextTo: iso) }
        let references = Self.wu8References()
        let safeguards = HotSwapPreflight.enabled
        Task.detached(priority: .userInitiated) {
            do {
                let u8 = try makeU8()
                // A track that's likely to crash isn't built (see `HotSwapPreflight.crashRisks`).
                if safeguards, let root = try? SZS.open(u8).root {
                    let risks = HotSwapPreflight.crashRisks(root)
                    if !risks.isEmpty {
                        throw WSError.badStructure("\(sourceName) wasn't built because it would likely crash the game. Fix these first, or turn off Safeguards in Settings > Emulator: " + risks.map { "\($0.label): \($0.detail)" }.joined(separator: " "))
                    }
                }
                let data = try WiimmArchive.encode(u8, as: format, references: references)
                try data.write(to: destURL, options: .atomic)
                await MainActor.run {
                    self.log("Created \(destURL.lastPathComponent) from \(sourceName).")
                    AppNotifications.conversion(success: true, detail: "Created \(destURL.lastPathComponent) from \(sourceName).")
                    self.refreshFolderTree()
                    if case .folder(let root) = self.project { self.git.refresh(repoURL: root.url) }
                }
            } catch {
                await MainActor.run {
                    self.report(error)
                    AppNotifications.conversion(success: false, detail: error.localizedDescription)
                }
            }
        }
    }

    /// Looks WU8 reference files up on the linked disc, loading them on first use.
    private static func wu8References() -> WiimmArchive.References {
        let (common, korean) = (KeyManager.shared.commonKey, KeyManager.shared.koreanKey)
        return { path in try BaseGameLibrary.shared.wu8References(commonKey: common, koreanKey: korean)[path] }
    }

    /// Recursively reads a real folder's contents into `node`'s children, the inverse of
    /// `writeU8NodeToDisk`, used by `makeArchive`.
    private func populateU8Node(_ node: U8Node, fromDirectory url: URL) throws {
        let fm = FileManager.default
        let items = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for item in items {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let child = U8Node(name: item.lastPathComponent, isDirectory: isDir, data: isDir ? nil : try Data(contentsOf: item))
            child.parent = node
            node.children.append(child)
            if isDir { try populateU8Node(child, fromDirectory: item) }
        }
    }

    /// Shared by `newBRRESFromOBJ` and `makeBRRES`: builds a real, loadable MDL0 model from an
    /// `.obj` mesh (flat-shaded, untextured unless a companion `.mtl` supplies a `map_Kd` texture
    /// or color, see `MDL0Writer`'s doc comment for exactly what that means and its limits) and
    /// wraps it in a fresh `.brres`. Returns nil (after setting `errorMessage` itself, so both
    /// callers can just bail) for anything that isn't a usable mesh.
    private func buildBRRESFromOBJ(text: String, objURL: URL, modelName: String, brresFileName: String? = nil) -> (doc: BRRESDocument, triangleCount: Int)? {
        let resolvedName = OBJToBRRES.modelName(forBRRESNamed: brresFileName, fallback: modelName)
        guard let result = OBJToBRRES.convert(objText: text, objURL: objURL, modelName: resolvedName) else {
            errorMessage = "Couldn't build a model from that .obj file, it has no triangles, or one of its materials covers more than \(MDL0Writer.maxVerticesPerMesh / 3) triangles (the most a single MDL0 mesh can hold)."
            return nil
        }
        let doc = BRRESDocument()
        doc.resources.append(contentsOf: result.textures)
        doc.resources.append(result.model)
        if !result.missingTextures.isEmpty {
            log("Couldn't load \(result.missingTextures.count) texture image(s) referenced by the .mtl: \(result.missingTextures.joined(separator: ", ")).")
        }
        return (doc, result.triangleCount)
    }

    // MARK: Creating other new (blank) documents

    /// The generic "File > New > ..." path for every format that can start from a valid empty
    /// document: prompts for where to save it, writes it, and opens it as a tab, same shape as
    /// `newKCLFromOBJ`'s final step, just without needing a source file first.
    private func newDocument(defaultName: String, extensionHint: String, in directoryURL: URL? = nil, makeData: @escaping () -> Data) {
        PanelPresenter.saveFile(configure: {
            // NSSavePanel appends the allowed type's extension onto whatever's already in
            // nameFieldStringValue when allowedContentTypes is set, if that string already ends
            // in the same extension (as `defaultName` does, e.g. "Untitled.kmp"), this doubles it
            // ("Untitled.kmp.kmp") rather than recognizing it's already there. Stripping it here
            // and letting allowedContentTypes supply it avoids that.
            if let type = UTType(filenameExtension: extensionHint) { $0.allowedContentTypes = [type] }
            $0.nameFieldStringValue = (defaultName as NSString).deletingPathExtension
            if let directoryURL { $0.directoryURL = directoryURL }
        }) { [weak self] destURL in
            guard let self, let destURL else { return }
            do {
                try makeData().write(to: destURL, options: .atomic)
                self.log("Created \(destURL.lastPathComponent).")
                self.openFile(url: destURL)
            } catch {
                self.report(error)
            }
        }
    }

    /// `directoryURL` presets the save panel's folder, passed by the Project Navigator's
    /// right-click "New" (see `ProjectNavigatorView.newFileMenu`) so its items land next to
    /// wherever was clicked instead of wherever the panel last happened to be; File > New's
    /// versions of these calls omit it and get the panel's own default.
    /// New > Skybox > Custom: a `vrcorn_model.brres` from a panorama image or an `.obj` (see `Skybox`).
    func newCustomSkybox(in directoryURL: URL? = nil) {
        PanelPresenter.openFile(configure: {
            $0.allowedContentTypes = [.image] + ModelFile.contentTypes
            $0.message = "Choose a panorama image (2:1, wraps all the way round, top of the image overhead) or a sky model (.obj or .dae)."
        }) { [weak self] url in
            guard let self, let url else { return }
            do {
                let data = try Skybox.brres(from: url)
                self.saveSkybox(data, in: directoryURL)
            } catch { self.report(error) }
        }
    }

    func saveSkybox(_ data: Data, in directoryURL: URL? = nil) {
        newDocument(defaultName: "vrcorn_model.brres", extensionHint: "brres", in: directoryURL) { data }
    }

    func newKMP(in directoryURL: URL? = nil) { newDocument(defaultName: "course.kmp", extensionHint: "kmp", in: directoryURL) { KMPDocument().serialize() } }
    /// A battle arena's course.kmp: 12 per-player starts, 4 battle respawns, respawns and a CPU loop (see `BattleArena`).
    func newBattleKMP(in directoryURL: URL? = nil) { newDocument(defaultName: "course.kmp", extensionHint: "kmp", in: directoryURL) { BattleArena.template().serialize() } }
    func newBOL(in directoryURL: URL? = nil) {
        newDocument(defaultName: "course.bol", extensionHint: "bol", in: directoryURL) { let d = BOL.newDocument(); return BOL.serialize(d, source: d.bolSource!) }
    }
    /// A Double Dash battle stage's course data: 8 per-player starts (see `BOL.battleTemplate`).
    func newBattleBOL(in directoryURL: URL? = nil) {
        newDocument(defaultName: "course.bol", extensionHint: "bol", in: directoryURL) { let d = BOL.battleTemplate(); return BOL.serialize(d, source: d.bolSource!) }
    }
    /// Double Dash collision from a model: surfaces guessed from material names, as for the course
    /// builder (`MKDDTrackBuilder.surface`), opened in the collision editor to check.
    func newBCOFromOBJ(in directoryURL: URL? = nil) {
        PanelPresenter.openFile(configure: { $0.allowedContentTypes = ModelFile.contentTypes }) { [weak self] objURL in
            guard let self, let objURL else { return }
            do {
                let (text, _) = try ModelFile.objSource(objURL)
                let triangles = OBJImporter.parse(text).map {
                    KCLTriangle(v0: $0.v0, v1: $0.v1, v2: $0.v2, attribute: MKDDTrackBuilder.surface(forMaterial: $0.materialName ?? ""))
                }
                guard !triangles.isEmpty else { self.errorMessage = "No triangles were found in that model file."; return }
                self.newDocument(defaultName: objURL.deletingPathExtension().lastPathComponent + "_course.bco", extensionHint: "bco", in: directoryURL) { BCO.build(triangles) }
            } catch {
                self.report(error)
            }
        }
    }
    /// A Double Dash sky (`<course>_sky.bmd`) from a model: textures fitted to the sky budget,
    /// on the "VRcorn" joint retail skies use.
    func newDoubleDashSky(in directoryURL: URL? = nil) {
        PanelPresenter.openFile(configure: { $0.allowedContentTypes = ModelFile.contentTypes }) { [weak self] url in
            guard let self, let url else { return }
            do {
                let sky = try MKDDTrackBuilder.model(fromFile: url)
                let (textures, _) = GCTextures.optimize(sky.textures, budget: GCTextures.skyBudget, maxSize: 512)
                let data = try J3DWriter.bmd(triangles: sky.triangles, materials: sky.materials, textures: textures, jointName: "VRcorn")
                self.newDocument(defaultName: "course_sky.bmd", extensionHint: "bmd", in: directoryURL) { data }
            } catch {
                self.report(error)
            }
        }
    }

    /// A retail course's sky, copied from the linked Double Dash disc.
    func newDoubleDashSky(from slot: MKDDSlots.Slot, in directoryURL: URL? = nil) {
        do {
            guard let iso = DoubleDashDisc.linkedISO else { errorMessage = "Link your Double Dash disc in Settings > Games first."; return }
            let disc = try GameCubeDisc(url: iso)
            func find(_ n: DiscNode) -> DiscNode? { n.name == slot.archives[0].name ? n : n.children.lazy.compactMap(find).first }
            guard let node = find(disc.root), let sky = try SZS.open(try disc.readFile(node: node)).root.children.first(where: { $0.name.lowercased().hasSuffix("_sky.bmd") })?.data else {
                errorMessage = "\(slot.title) has no sky on this disc."
                return
            }
            newDocument(defaultName: "\(slot.fileStem)_sky.bmd", extensionHint: "bmd", in: directoryURL) { sky }
        } catch {
            report(error)
        }
    }

    func newBRRES(in directoryURL: URL? = nil) { newDocument(defaultName: "Untitled.brres", extensionHint: "brres", in: directoryURL) { BRRESDocument().serialize() } }
    /// A new streamed-music track from any audio file macOS can read (WAV, AIFF, MP3, M4A, FLAC...),
    /// resampled to 32 kHz like every retail track and looping the whole song by default, set the
    /// real loop point in the editor it opens in.
    func newBRSTMFromAudio(in directoryURL: URL? = nil) {
        PanelPresenter.openFile(configure: { $0.allowedContentTypes = AudioFileImport.contentTypes }) { [weak self] audioURL in
            guard let self, let audioURL else { return }
            do {
                let audio = try AudioFileImport.load(audioURL, sampleRate: 32000)
                let doc = BRSTMDocument()
                doc.replaceAudio(channels: audio.channels, sampleRate: audio.sampleRate)
                PanelPresenter.saveFile(configure: {
                    if let type = UTType(filenameExtension: "brstm") { $0.allowedContentTypes = [type] }
                    $0.nameFieldStringValue = audioURL.deletingPathExtension().lastPathComponent
                    if let directoryURL { $0.directoryURL = directoryURL }
                }) { [weak self] destURL in
                    guard let self, let destURL else { return }
                    do {
                        try doc.serialize().write(to: destURL, options: .atomic)
                        self.log("Created \(destURL.lastPathComponent) from \(audioURL.lastPathComponent).")
                        self.openFile(url: destURL)
                    } catch {
                        self.report(error)
                    }
                }
            } catch {
                self.report(error)
            }
        }
    }

    /// Mario Kart Double Dash > Port > To Mario Kart Wii: converts Double Dash course archives to Wii
    /// `.szs` tracks in `destination`, off the main thread. Item boxes are included when a Mario
    /// Kart Wii disc is linked (Settings > Games) to take `itembox.brres` from.
    func portFromDoubleDash(_ courses: [(name: String, data: Data)], to destination: URL, scale: Float = MKDDPort.defaultScale, wallStrip: UInt16) {
        if let iso = BaseGameLibrary.linkedISO { KeyManager.shared.autoLoad(nextTo: iso) }
        let (common, korean) = (KeyManager.shared.commonKey, KeyManager.shared.koreanKey)
        log("Porting \(courses.count) Double Dash course(s) to \(destination.lastPathComponent)/...")
        Task.detached(priority: .userInitiated) {
            var itemBox: [(path: [String], data: Data)] = []
            if BaseGameLibrary.linkedISO != nil, let index = try? BaseGameLibrary.shared.index(commonKey: common, koreanKey: korean) {
                itemBox = BaseGameLibrary.shared.files(for: ["itembox"], in: index).files
            }
            var lines: [String] = []
            var failed = 0
            do { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true) }
            catch {
                await MainActor.run {
                    self.report(error)
                    AppNotifications.port(success: false, detail: error.localizedDescription)
                }
                return
            }
            for course in courses {
                do {
                    let result = try MKDDPort.port(course.data, name: course.name, scale: scale, itemBoxFiles: itemBox, wallStrip: wallStrip)
                    let out = destination.appendingPathComponent(course.name).appendingPathExtension("szs")
                    try result.archive.write(to: out, options: .atomic)
                    lines.append("Ported \(course.name) -> \(out.lastPathComponent): " + result.report.joined(separator: " "))
                } catch {
                    lines.append("Couldn't port \(course.name): \(error.localizedDescription)")
                    failed += 1
                }
            }
            await MainActor.run { [lines, failed] in
                lines.forEach { self.log($0) }
                AppNotifications.port(success: failed == 0, detail: failed == 0
                    ? "Ported \(courses.count) Double Dash course\(courses.count == 1 ? "" : "s") to Mario Kart Wii."
                    : "\(failed) of \(courses.count) Double Dash course\(courses.count == 1 ? "" : "s") couldn't be ported. Check the console for details.")
                self.refreshFolderTree()
            }
        }
    }

    /// Right-click "Make .brstm" on an audio file in the project: converts it beside itself (same
    /// name, `.brstm`) and opens the result.
    func makeBRSTM(fromAudioAt url: URL) {
        let dest = url.deletingPathExtension().appendingPathExtension("brstm")
        Task.detached(priority: .userInitiated) {
            do {
                let audio = try AudioFileImport.load(url, sampleRate: 32000)
                let doc = BRSTMDocument()
                doc.replaceAudio(channels: audio.channels, sampleRate: audio.sampleRate)
                try doc.serialize().write(to: dest, options: .atomic)
                await MainActor.run {
                    self.log("Created \(dest.lastPathComponent) from \(url.lastPathComponent).")
                    self.refreshFolderTree()
                    self.openFile(url: dest)
                }
            } catch {
                await MainActor.run { self.report(error) }
            }
        }
    }

    func newBMG(in directoryURL: URL? = nil) { newDocument(defaultName: "Untitled.bmg", extensionHint: "bmg", in: directoryURL) { BMGDocument().serialize() } }
    func newUIDesign(in directoryURL: URL? = nil) {
        newDocument(defaultName: "Untitled.wiiui", extensionHint: "wiiui", in: directoryURL) { UIDocument.sample().serialize() }
    }

    /// A sprite actor: a .wiinodes whose logic runs once per spawned sprite. Starts by drifting upward.
    func newSpriteActor(in directoryURL: URL? = nil) {
        newDocument(defaultName: "Actor.wiinodes", extensionHint: "wiinodes", in: directoryURL) {
            var g = NodeGraph()
            g.actorSprite = ""
            let update = GraphNode.make(.onUpdate, x: 40, y: 40)
            var move = GraphNode.make(.moveSelf, x: 300, y: 40)
            move.params["by"] = "0, 2"
            g.nodes = [update, move]
            _ = g.connect(GraphEdge(fromNode: update.id, fromPort: "then", toNode: move.id, toPort: "in"))
            return g.serialize()
        }
    }

    func newNodeGraph(in directoryURL: URL? = nil) {
        newDocument(defaultName: "Untitled.wiinodes", extensionHint: "wiinodes", in: directoryURL) { NodeGraph().serialize() }
    }

    func newTextFile(in directoryURL: URL? = nil) { newDocument(defaultName: "Untitled.txt", extensionHint: "txt", in: directoryURL) { Data() } }

    /// An empty `.szs` archive, opens straight into the archive window (see
    /// `openArchiveInNewWindow`), the same as opening any other archive.
    func newSZSArchive(in directoryURL: URL? = nil) {
        newDocument(defaultName: "Untitled.szs", extensionHint: "szs", in: directoryURL) {
            SZS.save(root: U8Node(name: "archive", isDirectory: true), compressed: true)
        }
    }

    func newARCArchive(in directoryURL: URL? = nil) {
        newDocument(defaultName: "Untitled.arc", extensionHint: "arc", in: directoryURL) {
            SZS.save(root: U8Node(name: "archive", isDirectory: true), compressed: false)
        }
    }

    /// The Project Navigator's right-click "New" when the target is inside a `.szs`/`.arc` (its
    /// own root, or a folder previewed inside it), adds a fresh empty entry directly, unique-
    /// named against its siblings. No save panel: unlike `newDocument`'s on-disk version, there's
    /// no real path to choose here, just a name.
    func newArchiveFile(preferredName: String, archiveURL: URL, pathComponents: [String], makeData: () -> Data) {
        var found = true
        var createdName = ""
        let data = makeData()
        let result = mutateArchive(at: archiveURL) { root in
            guard let parent = root.find(path: pathComponents) else { found = false; return }
            createdName = self.uniqueU8Name(preferredName, in: parent)
            let node = U8Node(name: createdName, isDirectory: false, data: data)
            node.parent = parent
            parent.children.append(node)
        }
        guard found else {
            log("Couldn't find that folder inside \(archiveURL.lastPathComponent), it may have changed.")
            return
        }
        guard result == .succeeded else { return }
        log("Created \(createdName) in \(archiveURL.lastPathComponent).")
    }

    // MARK: Recent files

    private static let recentFilesDefaultsKey = "WorkbenchState.recentFiles"

    private func loadRecentFiles() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.recentFilesDefaultsKey) ?? []
        recentFileURLs = paths.map { URL(fileURLWithPath: $0) }
    }

    private func recordRecentFile(_ url: URL) {
        var urls = recentFileURLs.filter { $0 != url }
        urls.insert(url, at: 0)
        let limit = UserDefaults.standard.object(forKey: "recentFilesLimit") as? Int ?? 10
        if urls.count > limit { urls.removeLast(urls.count - limit) }
        recentFileURLs = urls
        UserDefaults.standard.set(urls.map(\.path), forKey: Self.recentFilesDefaultsKey)
    }

    private func recordRecentProject(_ url: URL) {
        var urls = recentProjectURLs.filter { $0 != url }
        urls.insert(url, at: 0)
        recentProjectURLs = Array(urls.prefix(20))
        UserDefaults.standard.set(recentProjectURLs.map(\.path), forKey: "WorkbenchState.recentProjects")
    }

    func clearRecentFiles() {
        recentProjectURLs = []
        UserDefaults.standard.removeObject(forKey: "WorkbenchState.recentProjects")
        recentFileURLs = []
        UserDefaults.standard.removeObject(forKey: Self.recentFilesDefaultsKey)
    }

    // MARK: Tab restore
    //
    // Only plain `.file(URL)` tabs are persisted/restored, a tab opened on an entry inside an
    // archive or disc image points at a live, in-memory parse (`SZSDocumentBox`/`WiiDisc`) that
    // doesn't exist yet at launch, so restoring those would need re-deriving that whole context
    // rather than just reopening a path; skipped for now rather than restored incorrectly.

    private static let restorableTabsDefaultsKey = "WorkbenchState.restorableTabs"

    private func persistOpenTabsIfNeeded() {
        guard isPrimary else { return }
        guard UserDefaults.standard.bool(forKey: "restoreTabsOnRelaunch") else {
            UserDefaults.standard.removeObject(forKey: Self.restorableTabsDefaultsKey)
            return
        }
        let paths = tabs.compactMap { tab -> String? in
            if case .file(let url) = tab.source { return url.path }
            return nil
        }
        UserDefaults.standard.set(paths, forKey: Self.restorableTabsDefaultsKey)
    }

    private func restorePersistedTabs() {
        guard UserDefaults.standard.bool(forKey: "restoreTabsOnRelaunch") else { return }
        let paths = UserDefaults.standard.stringArray(forKey: Self.restorableTabsDefaultsKey) ?? []
        for path in paths where FileManager.default.fileExists(atPath: path) {
            openFile(url: URL(fileURLWithPath: path))
        }
    }

    // MARK: Closing

    func closeTab(_ tab: EditorTab) {
        tabs.removeAll { $0.id == tab.id }
        // Any tabs whose bytes lived inside this one (nested SZS entries) become orphaned edits;
        // leave them open (still editable/exportable standalone) rather than force-closing them.
        if selectedTabID == tab.id { selectedTabID = tabs.last?.id }
    }
}
