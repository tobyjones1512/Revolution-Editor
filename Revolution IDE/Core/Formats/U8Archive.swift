import Foundation

/// A node (file or directory) in a U8 archive tree, the container format inside every .szs/.arc
/// (after Yaz0 decompression). Structurally the same idea as a Wii FST: a flat, depth-first node
/// array + string table, which this type also exposes as an actual tree for editing.
nonisolated final class U8Node: Identifiable, Hashable {
    static func == (lhs: U8Node, rhs: U8Node) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    let id = UUID()
    var name: String
    var isDirectory: Bool
    var data: Data?
    var children: [U8Node] = []
    weak var parent: U8Node?
    /// Root only: this tree came from a GameCube RARC archive (Double Dash `.arc`) and is saved
    /// back as one, see `SZS`.
    var isRARC = false

    init(name: String, isDirectory: Bool, data: Data? = nil) {
        self.name = name
        self.isDirectory = isDirectory
        self.data = data
    }

    var childrenOrNil: [U8Node]? { isDirectory ? children : nil }

    /// Only meaningful on a tree's root, and only when it came from a real archive.
    ///
    /// `flattenedWrapperName` is the single self-referential directory `parse` folded away, if
    /// there was one. Mario Kart Wii's archives nest everything inside a literal "." but the
    /// Wii's own Home Button and Mii archives put their real top-level folder there instead, so
    /// re-adding a "." unconditionally invented a directory those files never had.
    /// `reservedHeaderBytes` is the 16-byte run at 0x10, which MKWii's tools fill with 0xCC and
    /// the system archives leave as zeroes.
    var flattenedWrapperName: String?
    var reservedHeaderBytes: Data?

    /// Where this file's bytes sat in the archive it was read from.
    ///
    /// Archives on a single disc do not agree on how file data is ordered: Mario Kart Wii's own
    /// sort it by path, while `HomeButtonSe.arc` and `SpeakerSe.arc`, flat archives that encode
    /// their folders as backslashes inside the filenames, simply follow node order. Keeping the
    /// original offset lets an untouched archive be rebuilt in whatever order it already used,
    /// instead of having to pick one convention and be wrong about the other.
    var originalDataOffset: Int?

    func find(path: [String]) -> U8Node? {
        guard let first = path.first else { return self }
        guard let child = children.first(where: { $0.name == first }) else { return nil }
        return child.find(path: Array(path.dropFirst()))
    }

    /// Chain of names from the archive's own top level down to this node (empty for a top-level
    /// entry), lets a node from one parsed copy of an archive (e.g. a disconnected sidebar
    /// preview) be relocated by path in another copy of the same archive (a live open box, or a
    /// fresh reparse), via `find(path:)`, since the node reference itself only means something
    /// within the tree it came from.
    var pathFromRoot: [String] {
        var comps: [String] = []
        var current: U8Node? = self
        while let c = current, c.parent != nil {
            comps.append(c.name)
            current = c.parent
        }
        return comps.reversed()
    }
}

nonisolated enum U8Archive {
    private static let magic: UInt32 = 0x55AA382D

    static func parse(_ data: Data) throws -> U8Node {
        guard data.count >= 32, data.be32(0) == magic else {
            throw WSError.badStructure("Not a U8 archive.")
        }
        let rootNodeOffset = Int(data.be32(4))
        let headerSize = Int(data.be32(8))
        let dataOffset = Int(data.be32(12))
        _ = headerSize; _ = dataOffset

        guard rootNodeOffset + 12 <= data.count else { throw WSError.badStructure("U8 archive truncated.") }
        let rootTotalCount = Int(data.be32(rootNodeOffset + 8))
        guard rootTotalCount > 0, rootNodeOffset + rootTotalCount * 12 <= data.count else {
            throw WSError.badStructure("U8 archive node count looks invalid.")
        }
        let stringTableOffset = rootNodeOffset + rootTotalCount * 12

        struct RawNode { var isDir: Bool; var nameOffset: Int; var dataOffsetOrParent: Int; var sizeOrNext: Int }
        var raw: [RawNode] = []
        raw.reserveCapacity(rootTotalCount)
        for i in 0..<rootTotalCount {
            let base = rootNodeOffset + i * 12
            let typeAndName = data.be32(base)
            let isDir = (typeAndName >> 24) != 0
            let nameOffset = Int(typeAndName & 0x00FFFFFF)
            let f1 = Int(data.be32(base + 4))
            let f2 = Int(data.be32(base + 8))
            raw.append(RawNode(isDir: isDir, nameOffset: nameOffset, dataOffsetOrParent: f1, sizeOrNext: f2))
        }

        let root = U8Node(name: "", isDirectory: true)
        var stack: [(node: U8Node, endIndex: Int)] = [(root, raw[0].sizeOrNext == 0 ? rootTotalCount : raw[0].sizeOrNext)]
        var i = 1
        while i < raw.count {
            while let top = stack.last, i >= top.endIndex { stack.removeLast() }
            guard let parent = stack.last?.node else { break }
            let r = raw[i]
            let name = data.asciiString(at: stringTableOffset + r.nameOffset, length: max(0, data.count - (stringTableOffset + r.nameOffset)))
            let node = U8Node(name: name, isDirectory: r.isDir)
            node.parent = parent
            if r.isDir {
                node.children = []
                parent.children.append(node)
                stack.append((node, r.sizeOrNext))
            } else {
                node.data = data.subdata(at: r.dataOffsetOrParent, length: r.sizeOrNext)
                node.originalDataOffset = r.dataOffsetOrParent
                parent.children.append(node)
            }
            i += 1
        }

        // Real Nintendo-built U8 archives (verified against a retail Mario Kart Wii disc's own
        // `beginner_course.szs`) put a literal "." directory entry as the true root's
        // first child, a self-reference to the root itself, not a real subfolder, and nest
        // every actual top-level file/folder inside *that* instead of directly under the root.
        // Flatten it away so callers (the tree UI, sibling-file auto-detection, ...) see a normal
        // archive layout instead of every file living one redundant "." level down.
        if root.children.count == 1, let dot = root.children.first, dot.isDirectory, dot.name == "." {
            root.flattenedWrapperName = dot.name
            for child in dot.children { child.parent = root }
            root.children = dot.children
        }
        root.reservedHeaderBytes = data.subdata(at: 16, length: 16)
        return root
    }

    /// Serializes a (possibly edited) tree back into U8 archive bytes. Matches the classic
    /// Nintendo layout: node array, then string table (padded to 32 bytes), then file data
    /// (each file 32-byte aligned).
    static func serialize(_ realRoot: U8Node) -> Data {
        // `parse` flattens away the literal "." directory every Nintendo-built archive nests its
        // contents in (see the end of `parse`), so put it back on the way out, an archive this
        // app rebuilt should have the same shape as the one it opened, not a subtly different one.
        let root: U8Node
        if realRoot.children.count == 1, realRoot.children[0].isDirectory, realRoot.children[0].name == "." {
            root = realRoot
        } else if let wrapperName = realRoot.flattenedWrapperName {
            root = U8Node(name: "", isDirectory: true)
            let wrapper = U8Node(name: wrapperName, isDirectory: true)
            wrapper.parent = root
            wrapper.children = realRoot.children
            root.children = [wrapper]
        } else if realRoot.reservedHeaderBytes != nil {
            // Came from an archive that had no wrapper directory (homeBtn.szs and the
            // rest of the Wii's own UI archives put their real top-level folder at the root).
            root = realRoot
        } else {
            // A brand-new archive: follow the convention this app's own target game uses.
            root = U8Node(name: "", isDirectory: true)
            let dot = U8Node(name: ".", isDirectory: true)
            dot.parent = root
            dot.children = realRoot.children
            root.children = [dot]
        }

        var flat: [U8Node] = [root]
        // Parents are tracked here rather than read from `node.parent`, since the "." directory
        // added above is not part of the caller's own tree (and re-pointing the caller's nodes at
        // it would corrupt the tree the editor is still showing).
        var parentOf: [ObjectIdentifier: U8Node] = [:]
        func walk(_ node: U8Node) {
            for c in node.children {
                flat.append(c)
                parentOf[ObjectIdentifier(c)] = node
                if c.isDirectory { walk(c) }
            }
        }
        walk(root)

        // next-index (for dirs) / string-table offsets need each node's position in `flat`.
        var indexOf: [ObjectIdentifier: Int] = [:]
        for (i, n) in flat.enumerated() { indexOf[ObjectIdentifier(n)] = i }

        func subtreeEnd(_ node: U8Node) -> Int {
            var count = 1
            for c in node.children { count += c.isDirectory ? subtreeCount(c) : 1 }
            return (indexOf[ObjectIdentifier(node)] ?? 0) + count
        }
        func subtreeCount(_ node: U8Node) -> Int {
            var count = 1
            for c in node.children { count += c.isDirectory ? subtreeCount(c) : 1 }
            return count
        }

        var stringTable = Data([0]) // root's name is empty, offset 0
        var nameOffsets: [ObjectIdentifier: Int] = [ObjectIdentifier(root): 0]
        for n in flat.dropFirst() {
            nameOffsets[ObjectIdentifier(n)] = stringTable.count
            stringTable.append(n.name.data(using: .utf8) ?? Data())
            stringTable.append(0)
        }

        let nodeArraySize = flat.count * 12
        let headerSize0x20 = 0x20
        let stringTableOffset = headerSize0x20 + nodeArraySize
        var fileDataStart = stringTableOffset + stringTable.count
        fileDataStart = (fileDataStart + 31) & ~31

        // File *data* is not laid out in node order. A retail archive orders it by full path,
        // case-insensitively, independently of where each file sits in the node array, verified
        // against `beginner_course.szs` off a real disc, where every boundary agrees:
        // `dokan_sfc.brres` < `effect/Flash_L/...` < `FlagB2.brres` (so 'e' sorts before 'F':
        // case-insensitive), `map_model.brres` < `MiiKanban.brres` (so 'a' before 'i', not 'M'
        // before 'm'), and `MiiStatueL3.brres` < `posteffect/...` < `skyship.brres`. Writing the
        // blob in node order instead put every subfolder's files at the end, which is still a
        // valid archive, offsets are explicit, but not the one Nintendo's tools produce.
        func fullPath(_ n: U8Node) -> String {
            var parts: [String] = []
            var cur: U8Node? = n
            while let c = cur, let parent = parentOf[ObjectIdentifier(c)] {
                parts.append(c.name)
                cur = parent === root ? nil : parent
            }
            return parts.reversed().joined(separator: "/")
        }
        // The comparison is "uppercase the path, then compare bytes", not a plain ASCII sort and
        // not Foundation's case-insensitive compare either. Retail puts `jugemu.brres` *before*
        // `jugem_battle.brres` and `kart_killer.brres` *after* `kartAIActionParam.bin`, which only
        // holds if the names are folded to upper case first: '_' is 0x5F, above every uppercase
        // letter but below every lowercase one, so the fold decides both. `course.kmp` before
        // `course_model.brres` and `map_model.brres` before `MiiKanban.brres` agree.
        func sortKey(_ n: U8Node) -> [UInt8] {
            Array(fullPath(n).utf8).map { $0 >= 0x61 && $0 <= 0x7A ? $0 - 0x20 : $0 }
        }
        func precedes(_ a: [UInt8], _ b: [UInt8]) -> Bool {
            for (x, y) in zip(a, b) where x != y { return x < y }
            return a.count < b.count
        }
        let files = flat.filter { !$0.isDirectory }
        let dataOrder: [U8Node]
        if !files.isEmpty, files.allSatisfy({ $0.originalDataOffset != nil }) {
            // Every file came from an archive and none were added, so the order it already used is
            // reproduced exactly, whichever convention built it.
            dataOrder = files.sorted { ($0.originalDataOffset ?? 0) < ($1.originalDataOffset ?? 0) }
        } else {
            dataOrder = files
                .map { (node: $0, key: sortKey($0)) }
                .sorted { precedes($0.key, $1.key) }
                .map(\.node)
        }

        var fileOffsets: [ObjectIdentifier: Int] = [:]
        var fileBlob = Data()
        for n in dataOrder {
            let d = n.data ?? Data()
            while (fileDataStart + fileBlob.count) % 32 != 0 { fileBlob.append(0) }
            fileOffsets[ObjectIdentifier(n)] = fileDataStart + fileBlob.count
            fileBlob.append(d)
        }

        let w = MutableDataWriter()
        w.putU32(magic)
        w.putU32(UInt32(headerSize0x20))  // root node offset (always 0x20)
        // "Header size" spans the node array and string table only, it is measured *from* the
        // root node offset, so the leading 0x20 is not part of it. A retail archive with a
        // 384-byte node array and a 446-byte string table stores 830 here, not 862.
        w.putU32(UInt32(nodeArraySize + stringTable.count))
        w.putU32(UInt32(fileDataStart))
        // Mario Kart Wii's own archives fill the reserved run at 0x10 with 0xCC; the Wii system
        // archives it ships alongside leave it zeroed. Whatever the file had is kept.
        if let reserved = realRoot.reservedHeaderBytes, reserved.count == 16 {
            w.putData(reserved)
        } else {
            while w.data.count < headerSize0x20 { w.putU8(0xCC) }
        }

        for n in flat {
            let nameOff = nameOffsets[ObjectIdentifier(n)] ?? 0
            let typeByte: UInt32 = n.isDirectory ? 1 : 0
            w.putU32((typeByte << 24) | (UInt32(nameOff) & 0x00FFFFFF))
            if n.isDirectory {
                let parentIdx = n === root ? 0 : (parentOf[ObjectIdentifier(n)].flatMap { indexOf[ObjectIdentifier($0)] } ?? 0)
                w.putU32(UInt32(parentIdx))
                w.putU32(UInt32(subtreeEnd(n)))
            } else {
                w.putU32(UInt32(fileOffsets[ObjectIdentifier(n)] ?? 0))
                w.putU32(UInt32(n.data?.count ?? 0))
            }
        }
        w.putData(stringTable)
        w.pad(to: fileDataStart)
        w.putData(fileBlob)
        return w.data
    }
}
