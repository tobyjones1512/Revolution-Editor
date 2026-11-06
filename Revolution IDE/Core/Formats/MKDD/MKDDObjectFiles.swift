import Foundation

/// Which files a Double Dash course needs for the objects its course data places, and where to
/// get them: retail courses carry each object's models and animations in their own `objects/`
/// folder, named after the object (TMapObjWanwan: `wanwan1.bmd`, `wanwan1.bca`,
/// `wanwan1pile.bmd`...). Objects with no such files anywhere on the disc (item boxes, the sun's
/// lens flare...) come from the game's shared data and need nothing.
nonisolated enum MKDDObjectFiles {
    /// Every file in every retail course's `objects/` folder, by lowercased name (first copy found).
    static func index(_ disc: GameCubeDisc) throws -> [String: Data] {
        func find(_ n: DiscNode, _ name: String) -> DiscNode? { n.name == name ? n : n.children.lazy.compactMap { find($0, name) }.first }
        guard let course = find(disc.root, "Course") else { return [:] }
        var out: [String: Data] = [:]
        for arc in course.children where arc.name.hasSuffix(".arc") && !arc.name.hasSuffix("L.arc") {
            guard let (root, _) = try? SZS.open(try disc.readFile(node: arc)),
                  let objects = root.children.first(where: { $0.isDirectory && $0.name.lowercased() == "objects" }) else { continue }
            for f in objects.children where !f.isDirectory {
                if out[f.name.lowercased()] == nil, let d = f.data { out[f.name.lowercased()] = d }
            }
        }
        return out
    }

    /// The file-name stem an object's files start with: its class name without the engine
    /// prefix, lowercased (TMapObjSkyShip -> "skyship", GeoMarioTree1 -> "mariotree1").
    static func stem(_ id: UInt16) -> String? {
        guard let name = BOL.objectNames[id] else { return nil }
        for prefix in ["TMapObj", "TSMA", "Geo", "T"] where name.hasPrefix(prefix) && name.count > prefix.count {
            return String(name.dropFirst(prefix.count)).lowercased()
        }
        return name.lowercased()
    }

    private static let stems: [String] = BOL.objectNames.keys.compactMap(stem).filter { $0.count >= 3 }

    /// The object a file belongs to: the longest object stem it starts with ("peachtree2.bmd" is
    /// TMapObjPeachTree2's, not TMapObjPeachTree's).
    static func owner(of file: String) -> String? {
        stems.filter { file.hasPrefix($0) }.max { $0.count < $1.count }
    }

    /// The files `ids` need that `present` (lowercased file names in the course) lacks, as
    /// `objects/<name>` paths with their retail contents.
    static func missing(for ids: Set<UInt16>, present: Set<String>, index: [String: Data]) -> [(path: [String], data: Data)] {
        var out: [(path: [String], data: Data)] = []
        for id in ids.sorted() {
            guard let stem = stem(id), stem.count >= 3 else { continue }
            for name in index.keys.sorted() where owner(of: name) == stem && !present.contains(name) {
                out.append((["objects", name], index[name]!))
            }
        }
        // Two objects can share files (a pile and its chain dog): each file once.
        var seen = Set<String>()
        return out.filter { seen.insert($0.path[1]).inserted }
    }
}
