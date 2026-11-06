import Foundation

/// The user's own Mario Kart Wii disc image, linked once in Settings > Games, used as a library of
/// object resources: when a track uses an object whose model isn't in the project, the files are
/// found on the disc and copied in.
///
/// What an object needs comes from the game's own object table (`Common.szs/ObjFlow.bin`): each
/// entry names its resources, `;`-separated (`itembox`, `Block;itembox;Press`, `-` for none). A
/// resource ships in a course archive as `<name>.brres` (plus `<name>.kcl` etc. for some) or, for
/// effects, a folder `effect/<name>/`. Every resource a track's objects use is imported into the
/// track, even ones `Common.szs` also has (retail courses all carry their own `itembox.brres`
/// too). Nothing is bundled or downloaded, only the linked disc is read.
nonisolated final class BaseGameLibrary: @unchecked Sendable {
    static let shared = BaseGameLibrary()
    static let bookmarkKey = "BaseGame.isoBookmark"

    struct Index {
        let disc: WiiDisc
        /// Object ID -> resource names.
        let resources: [UInt16: [String]]
        /// Lowercased names `Common.szs` provides (file base names and folder names).
        let common: Set<String>
        /// Lowercased resource name -> a retail archive that contains it (a course where one has it,
        /// else `Common.szs`).
        let donors: [String: DiscNode]
    }

    enum LibraryError: LocalizedError {
        case notLinked, noObjFlow
        var errorDescription: String? {
            switch self {
            case .notLinked: return "No base game disc is linked. Choose your Mario Kart Wii disc image in Settings > Games."
            case .noObjFlow: return "The linked disc has no Common.szs/ObjFlow.bin, is it Mario Kart Wii?"
            }
        }
    }

    private let lock = NSLock()
    private var cached: (path: String, index: Index)?

    /// The linked disc image, from its security-scoped bookmark.
    static var linkedISO: URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        return url
    }

    static func link(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        if let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        }
        shared.lock.lock(); shared.cached = nil; shared.lock.unlock()
    }

    static func unlink() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        shared.lock.lock(); shared.cached = nil; shared.lock.unlock()
    }

    /// Reads the disc's object table and every course archive once (slow, call off the main
    /// thread), then reuses the result.
    func index(commonKey: [UInt8]?, koreanKey: [UInt8]?) throws -> Index {
        guard let url = Self.linkedISO else { throw LibraryError.notLinked }
        lock.lock()
        if let cached, cached.path == url.path { lock.unlock(); return cached.index }
        lock.unlock()

        let disc = try WiiDisc(url: url, commonKey: commonKey, koreanKey: koreanKey)
        // Every archive on the disc can donate: retail courses aren't all `*_course.szs`
        // (`old_donkey_64.szs`, battle arenas, demos, `Competition/CommonObj/*`). Normal race
        // courses are searched first, then their `_d` multiplayer twins, then everything else.
        var found: [(node: DiscNode, path: String)] = []
        func walk(_ n: DiscNode, _ path: String) {
            if n.isDirectory { n.children.forEach { walk($0, path + "/" + $0.name) } }
            else if n.name.lowercased().hasSuffix(".szs") { found.append((n, path)) }
        }
        walk(disc.root, "")
        func rank(_ a: (node: DiscNode, path: String)) -> Int {
            let isCourse = a.path.contains("/Race/Course/")
            let isMultiplayer = a.node.name.lowercased().hasSuffix("_d.szs")
            return isCourse ? (isMultiplayer ? 1 : 0) : 2
        }
        let archives = found.sorted { (rank($0), $0.path) < (rank($1), $1.path) }.map(\.node)

        var resources: [UInt16: [String]] = [:]
        var common = Set<String>()
        var donors: [String: DiscNode] = [:]
        var commonNode: DiscNode?
        for node in archives {
            guard let data = try? disc.readFile(node: node), let (root, _) = try? SZS.open(data) else { continue }
            if node.name == "Common.szs" {
                Self.names(in: root).forEach { common.insert($0) }
                if let flow = Self.find("ObjFlow.bin", in: root)?.data { resources = Self.parseObjFlow(flow) }
                commonNode = node
            } else {
                for name in Self.names(in: root) where donors[name] == nil { donors[name] = node }
            }
        }
        if let commonNode { for name in common where donors[name] == nil { donors[name] = commonNode } }
        guard !resources.isEmpty else { throw LibraryError.noObjFlow }
        let index = Index(disc: disc, resources: resources, common: common, donors: donors)
        lock.lock(); cached = (url.path, index); lock.unlock()
        return index
    }

    /// Resources the given objects need that aren't in the project (`present`, lowercased file base
    /// names and folder names), split into those the disc has (`importable`) and those no archive
    /// on the retail disc contains at all
    /// (`unavailable`: cut/unused objects, or ones the game builds at runtime).
    func missingResources(for objectIDs: Set<UInt16>, present: Set<String>, in index: Index) -> (importable: [String], unavailable: [String]) {
        var importable: [String] = [], unavailable: [String] = []
        for id in objectIDs.sorted() {
            for r in index.resources[id] ?? [] {
                let key = r.lowercased()
                guard !present.contains(key),
                      !(importable + unavailable).contains(where: { $0.lowercased() == key }) else { continue }
                if index.donors[key] != nil { importable.append(r) } else { unavailable.append(r) }
            }
        }
        return (importable, unavailable)
    }

    /// Every file belonging to `resources`, copied out of the retail archives that hold them,
    /// with paths relative to the course root (`itembox.brres`, `effect/Flash_L/x.breff`). Also
    /// returns the resources no retail course carries.
    func files(for resources: [String], in index: Index) -> (files: [(path: [String], data: Data)], notFound: [String]) {
        var files: [(path: [String], data: Data)] = []
        var notFound: [String] = []
        var archiveCache: [String: U8Node] = [:]
        for r in resources {
            let key = r.lowercased()
            guard let donor = index.donors[key] else { notFound.append(r); continue }
            let root: U8Node
            if let cachedRoot = archiveCache[donor.name] { root = cachedRoot }
            else {
                guard let data = try? index.disc.readFile(node: donor), let (opened, _) = try? SZS.open(data) else { notFound.append(r); continue }
                archiveCache[donor.name] = opened
                root = opened
            }
            func collect(_ node: U8Node, path: [String], inside: Bool) {
                for child in node.children {
                    let p = path + [child.name]
                    let matches = inside || Self.baseName(child.name).lowercased() == key
                    if child.isDirectory { collect(child, path: p, inside: matches) }
                    else if matches, let d = child.data, !files.contains(where: { $0.path == p }) { files.append((p, d)) }
                }
            }
            collect(root, path: [], inside: false)
        }
        return (files, notFound)
    }

    private var openArchives: [String: U8Node] = [:]

    /// `<name>.brres` from the disc: `Common.szs` first (what the game itself loads it from),
    /// else a course archive that carries it. Opened archives are kept for the next lookup.
    func brres(named name: String, in index: Index) -> Data? {
        let key = name.lowercased()
        var candidates: [DiscNode] = []
        if index.common.contains(key), let common = Self.find(disc: index.disc.root, "Common.szs") { candidates.append(common) }
        if let donor = index.donors[key] { candidates.append(donor) }
        for node in candidates {
            lock.lock(); var root = openArchives[node.name]; lock.unlock()
            if root == nil {
                guard let data = try? index.disc.readFile(node: node), let (opened, _) = try? SZS.open(data) else { continue }
                lock.lock(); openArchives[node.name] = opened; lock.unlock()
                root = opened
            }
            if let root, let file = Self.find(key + ".brres", in: root, caseInsensitive: true)?.data { return file }
        }
        return nil
    }

    /// A file from the disc's game partition by its path, e.g. `Race/Common.szs`.
    static func file(at path: String, on disc: WiiDisc) -> Data? {
        for partition in disc.root.children {
            var node: DiscNode? = partition
            for part in path.split(separator: "/") { node = node?.children.first { $0.name.caseInsensitiveCompare(part) == .orderedSame } }
            if let node, !node.isDirectory, let data = try? disc.readFile(node: node) { return data }
        }
        return nil
    }

    private static func find(disc node: DiscNode, _ name: String) -> DiscNode? {
        if !node.isDirectory { return node.name == name ? node : nil }
        for c in node.children { if let f = find(disc: c, name) { return f } }
        return nil
    }

    private var wu8References: (path: String, files: [String: Data])?

    /// The retail files .wbz/.wlz archives are coded against (see `WiimmArchive`), taken from the
    /// linked disc's courses in the same order Wiimm's tools take them. Loaded once, then cached.
    func wu8References(commonKey: [UInt8]?, koreanKey: [UInt8]?) throws -> [String: Data] {
        let index = try index(commonKey: commonKey, koreanKey: koreanKey)
        guard let url = Self.linkedISO else { throw LibraryError.notLinked }
        lock.lock()
        if let wu8References, wu8References.path == url.path { lock.unlock(); return wu8References.files }
        lock.unlock()

        var byName: [String: DiscNode] = [:]
        func walk(_ n: DiscNode) {
            if n.isDirectory { n.children.forEach(walk) } else { byName[n.name] = n }
        }
        walk(index.disc.root)
        var files: [String: Data] = [:]
        for name in WiimmArchive.referenceArchiveOrder.flatMap({ ["\($0).szs", "\($0)_d.szs"] }) {
            guard files.count < WiimmArchive.wu8ReferenceFiles.count, let node = byName[name],
                  let data = try? index.disc.readFile(node: node), let (root, _) = try? SZS.open(data) else { continue }
            func collect(_ n: U8Node, _ path: String) {
                for c in n.children {
                    let p = path.isEmpty || path == "." ? c.name : path + "/" + c.name
                    if c.isDirectory { collect(c, p) }
                    else if files[p] == nil, WiimmArchive.wu8ReferenceFiles.contains(p), let d = c.data { files[p] = d }
                }
            }
            collect(root, "")
        }
        lock.lock(); wu8References = (url.path, files); lock.unlock()
        return files
    }

    /// Lowercased file base names and folder names anywhere in `root`, what "present" means.
    static func names(in root: U8Node) -> Set<String> {
        var out = Set<String>()
        func walk(_ n: U8Node) {
            for c in n.children {
                out.insert(baseName(c.name).lowercased())
                if c.isDirectory { walk(c) }
            }
        }
        walk(root)
        return out
    }

    /// The same for a folder on disk.
    static func names(inFolder url: URL) -> Set<String> {
        var out = Set<String>()
        let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
        while let item = items?.nextObject() as? URL { out.insert(baseName(item.lastPathComponent).lowercased()) }
        return out
    }

    static func baseName(_ name: String) -> String {
        guard let dot = name.firstIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }

    private static func find(_ name: String, in node: U8Node, caseInsensitive: Bool = false) -> U8Node? {
        for c in node.children {
            if !c.isDirectory, caseInsensitive ? c.name.lowercased() == name : c.name == name { return c }
            if c.isDirectory, let f = find(name, in: c, caseInsensitive: caseInsensitive) { return f }
        }
        return nil
    }

    /// `ObjFlow.bin`: u16 count, then 0x74-byte entries, u16 object ID, a 0x20-byte name, a
    /// 0x40-byte `;`-separated resource list (`-` = none).
    static func parseObjFlow(_ d: Data) -> [UInt16: [String]] {
        guard d.count >= 2 else { return [:] }
        let count = Int(d.be16(0))
        var out: [UInt16: [String]] = [:]
        for i in 0..<count {
            let e = 2 + i * 0x74
            guard e + 0x62 <= d.count else { break }
            let raw = d.subdata(in: (d.startIndex + e + 0x22)..<(d.startIndex + e + 0x62))
            let text = String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            out[d.be16(e)] = text == "-" ? [] : text.split(separator: ";").map(String.init).filter { !$0.isEmpty }
        }
        return out
    }
}

nonisolated extension U8Node {
    /// Writes `data` at `path` below this node, creating folders as needed and replacing an existing file.
    func setFile(at path: [String], data: Data) {
        guard let first = path.first else { return }
        if path.count == 1 {
            if let existing = children.first(where: { !$0.isDirectory && $0.name == first }) { existing.data = data; return }
            let file = U8Node(name: first, isDirectory: false, data: data)
            file.parent = self
            children.append(file)
            return
        }
        let dir: U8Node
        if let existing = children.first(where: { $0.isDirectory && $0.name == first }) { dir = existing }
        else { dir = U8Node(name: first, isDirectory: true); dir.parent = self; children.append(dir) }
        dir.setFile(at: Array(path.dropFirst()), data: data)
    }
}
