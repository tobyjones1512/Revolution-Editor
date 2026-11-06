import Foundation

/// A node in the Workbench's Project Navigator sidebar, a real filesystem entry (not to be
/// confused with `U8Node`, which is inside an *opened* SZS archive) unless `discContext` is set
/// (see below). `id` is derived from the path rather than a fresh `UUID()` per load so that
/// rebuilding the whole tree (see `FolderWatcher`) preserves `OutlineGroup`'s expand/collapse
/// state instead of collapsing everything on every external file change.
@MainActor final class ProjectNode: Identifiable {
    var id: String {
        if let discContext { return "\(discContext.discURL.path)#\(ObjectIdentifier(discContext.node))" }
        if let archiveEntryContext { return "\(archiveEntryContext.archiveURL.path)#\(ObjectIdentifier(archiveEntryContext.node))" }
        return url.path
    }
    let url: URL
    let isDirectory: Bool
    /// True for a `.iso`/`.wbfs` disc image found inside a folder project, browsable in place
    /// (its partition/file tree becomes this node's children, loaded eagerly at tree-build time
    /// the same way "Open Disc as Project" already parses a disc synchronously) instead of
    /// requiring "Open Disc as Project" to replace the whole navigator.
    let isDiscImage: Bool
    /// True for a `.szs`/`.arc` archive found inside a folder project, browsable in place like
    /// a folder, its U8 contents becoming this node's children. Unlike disc images, this is loaded
    /// *lazily* (see `childrenOrNil`/`loadArchiveChildrenIfNeeded`): a real mod project's course
    /// folder routinely has 1000+ of these, and eagerly Yaz0-decompressing every one of them at
    /// tree-build time (the way the much-rarer disc-image case does) would freeze the navigator
    /// for a long time on open. `List`/`OutlineGroup` only evaluate a row's `childrenOrNil` while
    /// that row is actually on-screen, so parsing here on first access stays bounded to what's
    /// actually visible/expanded rather than the whole project.
    let isArchive: Bool
    private var archiveLoadAttempted = false
    var children: [ProjectNode] = []
    /// Set when this node's real bytes live *inside* a disc image rather than at `url` on disk
    /// (either this node itself is an inlined `.iso`/`.wbfs`'s descendant, or, for the disc
    /// image node itself, `node` is that disc's root). `url` for such a node is synthetic
    /// (display/icon purposes only, built by appending path components under the `.iso`'s own
    /// real `url`), callers that need to actually open/extract it must go through
    /// `WorkbenchState.openDiscEntry`/`extractFile`/`extractAll` with `discContext`'s `disc`/
    /// `discURL`/`node`, not treat `url` as a real file.
    var discContext: (disc: any DiscImageReader, discURL: URL, node: DiscNode)?
    /// Same idea as `discContext`, for a descendant of an inlined `.szs`/`.arc` (not the archive
    /// node itself, that one's `url` is real). `url` is synthetic here too; opening/extracting
    /// such a node should open `archiveURL` itself (a real file) rather than treat `url` as real,
    /// since there's no live `SZSDocumentBox` backing this preview tree to safely save edits
    /// through, see `ProjectNavigatorView.open`.
    var archiveEntryContext: (archiveURL: URL, node: U8Node)?

    init(url: URL, isDirectory: Bool, isDiscImage: Bool = false, isArchive: Bool = false) {
        self.url = url
        self.isDirectory = isDirectory
        self.isDiscImage = isDiscImage
        self.isArchive = isArchive
    }

    var name: String { url.lastPathComponent }
    var childrenOrNil: [ProjectNode]? {
        if isArchive { loadArchiveChildrenIfNeeded() }
        return (isDirectory || isDiscImage || isArchive) ? children : nil
    }

    /// Plain-value mirror of a folder-project entry, built by `scan(at:)` on a background thread.
    /// `ProjectNode` itself is `@MainActor` (SwiftUI's `OutlineGroup` reads it directly), so the
    /// actual disk walk, directory enumeration, sorting, and eager disc-image parsing, all real
    /// I/O, happens against this instead of `ProjectNode` itself. `build(from:)` turns a `Scan`
    /// into the real tree back on the main actor afterwards; that's pure object allocation with no
    /// I/O left to do, so it stays fast even for a several-thousand-entry tree. Without this split,
    /// every rename/move/delete's `refreshFolderTree()` re-walked the *entire* project synchronously
    /// on the main thread, which is what made those feel sluggish on anything but a tiny project.
    nonisolated struct Scan: Sendable {
        var url: URL
        var isDirectory: Bool
        var isDiscImage = false
        var isArchive = false
        /// Only set for a successfully-parsed `isDiscImage` entry, `WiiDisc`/`DiscNode` are
        /// `nonisolated` (safe to build off-main), unlike `ProjectNode`.
        var discRoot: (disc: any DiscImageReader, node: DiscNode)?
        var children: [Scan] = []
    }

    nonisolated static func scan(at url: URL, maxNodes: Int = 5000) async -> Scan {
        var budget = maxNodes
        var root = Scan(url: url, isDirectory: true)
        await scanChildren(of: &root, budget: &budget)
        return root
    }

    private nonisolated static func scanChildren(of node: inout Scan, budget: inout Int) async {
        guard budget > 0 else { return }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: node.url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
        let sorted = items.sorted { a, b in
            let aDir = (try? a.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let bDir = (try? b.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if aDir != bDir { return aDir && !bDir }
            return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }
        for item in sorted {
            guard budget > 0 else { break }
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let ext = item.pathExtension.lowercased()
            if !isDir, ext == "iso" || ext == "wbfs" || ext == "gcm" {
                var discScan = Scan(url: item, isDirectory: false, isDiscImage: true)
                // `KeyManager` is `@MainActor`; hop over just for the key lookup, then parse the
                // (possibly large) disc image itself back on this background thread.
                let (commonKey, koreanKey) = await MainActor.run { () -> ([UInt8]?, [UInt8]?) in
                    KeyManager.shared.autoLoad(nextTo: item)
                    return (KeyManager.shared.commonKey, KeyManager.shared.koreanKey)
                }
                if let disc = try? openDiscImage(item, commonKey: commonKey, koreanKey: koreanKey), let discRoot = disc.root {
                    discScan.discRoot = (disc, discRoot)
                }
                node.children.append(discScan)
                budget -= 1
                continue
            }
            if !isDir, ext == "szs" || ext == "arc" {
                node.children.append(Scan(url: item, isDirectory: false, isArchive: true))
                budget -= 1
                continue
            }
            var child = Scan(url: item, isDirectory: isDir)
            if isDir { await scanChildren(of: &child, budget: &budget) }
            node.children.append(child)
            budget -= 1
        }
    }

    /// Turns a background-scanned `Scan` into the real `ProjectNode` tree, call after `scan(at:)`
    /// completes, back on the main actor.
    @MainActor
    static func build(from scan: Scan) -> ProjectNode {
        let node = ProjectNode(url: scan.url, isDirectory: scan.isDirectory, isDiscImage: scan.isDiscImage, isArchive: scan.isArchive)
        if let discRoot = scan.discRoot {
            node.children = (discRoot.node.childrenOrNil ?? []).map { convertDiscNode($0, discURL: scan.url, disc: discRoot.disc, parentURL: scan.url) }
        } else {
            node.children = scan.children.map { build(from: $0) }
        }
        return node
    }

    /// Decompresses/parses this `.szs`/`.arc` the first time something actually asks for its
    /// children (see `isArchive`'s doc comment for why this can't be eager like disc images).
    /// `archiveLoadAttempted`, not `children.isEmpty`, guards re-parsing, so a empty
    /// or corrupt archive doesn't get retried on every access.
    private var archiveRoot: U8Node?

    private func loadArchiveChildrenIfNeeded() {
        guard isArchive, !archiveLoadAttempted else { return }
        archiveLoadAttempted = true
        guard let raw = try? Data(contentsOf: url), let root = try? SZS.open(raw).root else { return } // U8 or RARC
        self.archiveRoot = root
        children = root.children.map { Self.convertArchiveEntry($0, archiveURL: url, parentURL: url) }
    }

    private static func convertArchiveEntry(_ u8Node: U8Node, archiveURL: URL, parentURL: URL) -> ProjectNode {
        let syntheticURL = parentURL.appendingPathComponent(u8Node.name)
        let node = ProjectNode(url: syntheticURL, isDirectory: u8Node.isDirectory)
        node.archiveEntryContext = (archiveURL, u8Node)
        if u8Node.isDirectory {
            node.children = u8Node.children.map { convertArchiveEntry($0, archiveURL: archiveURL, parentURL: syntheticURL) }
        }
        return node
    }

    private static func convertDiscNode(_ discNode: DiscNode, discURL: URL, disc: any DiscImageReader, parentURL: URL) -> ProjectNode {
        let isDir = discNode.childrenOrNil != nil
        let syntheticURL = parentURL.appendingPathComponent(discNode.name)
        let node = ProjectNode(url: syntheticURL, isDirectory: isDir)
        node.discContext = (disc, discURL, discNode)
        if let kids = discNode.childrenOrNil {
            node.children = kids.map { convertDiscNode($0, discURL: discURL, disc: disc, parentURL: syntheticURL) }
        }
        return node
    }
}
