import Foundation

/// Nintendo's RARC archive, the GameCube-era container Mario Kart: Double Dash!! keeps each course
/// in (`Course/*.arc`, Yaz0-compressed). Read into the same `U8Node` tree the rest of the app uses
/// for U8/SZS archives. Layout checked against every course archive on a retail MKDD disc.
///
/// Header: "RARC", file size, header size (0x20), data offset (+0x20), ... then an info block at
/// 0x20: node count, node offset, entry count, entry offset, string-table size and offset (all
/// offsets +0x20). Nodes (0x10): type, name offset, hash, entry count, first entry. Entries
/// (0x14): id, hash, flags (0x0200 = directory), name offset, data offset or node index, size.
nonisolated enum RARC {
    static func isRARC(_ data: Data) -> Bool { data.count >= 4 && data.asciiString(at: 0, length: 4) == "RARC" }

    /// Decompresses Yaz0 if needed, then parses.
    static func open(_ data: Data) throws -> U8Node {
        try parse(Yaz0.isYaz0(data) ? try Yaz0.decode(data) : data)
    }

    static func parse(_ d: Data) throws -> U8Node {
        guard isRARC(d), d.count >= 0x40 else { throw WSError.badStructure("Not a RARC archive (missing 'RARC' magic).") }
        let dataStart = Int(d.be32(0x0C)) + 0x20
        let nodeCount = Int(d.be32(0x20))
        let nodeTable = Int(d.be32(0x24)) + 0x20
        let entryTable = Int(d.be32(0x2C)) + 0x20
        let stringTable = Int(d.be32(0x34)) + 0x20
        func name(_ offset: Int) -> String {
            let start = stringTable + offset
            guard start < d.count else { return "" }
            var end = start
            while end < d.count, d[d.startIndex + end] != 0 { end += 1 }
            return String(decoding: d[(d.startIndex + start)..<(d.startIndex + end)], as: UTF8.self)
        }
        var visited = Set<Int>()
        func build(nodeIndex: Int, into dir: U8Node) throws {
            guard nodeIndex < nodeCount, !visited.contains(nodeIndex) else { return }
            visited.insert(nodeIndex)
            let node = nodeTable + nodeIndex * 0x10
            guard node + 0x10 <= d.count else { throw WSError.badStructure("RARC node table out of range.") }
            let count = Int(d.be16(node + 0x0A)), first = Int(d.be32(node + 0x0C))
            for e in first..<(first + count) {
                let entry = entryTable + e * 0x14
                guard entry + 0x14 <= d.count else { throw WSError.badStructure("RARC entry table out of range.") }
                let flags = d.be16(entry + 4)
                let entryName = name(Int(d.be16(entry + 6)))
                if entryName == "." || entryName == ".." { continue }
                let value = Int(d.be32(entry + 8)), size = Int(d.be32(entry + 12))
                if flags & 0x0200 != 0 {
                    let child = U8Node(name: entryName, isDirectory: true)
                    child.parent = dir
                    dir.children.append(child)
                    try build(nodeIndex: value, into: child)
                } else {
                    let start = dataStart + value
                    guard start >= 0, start + size <= d.count else { throw WSError.badStructure("RARC file \(entryName) out of range.") }
                    let file = U8Node(name: entryName, isDirectory: false, data: d.subdata(in: (d.startIndex + start)..<(d.startIndex + start + size)))
                    file.parent = dir
                    dir.children.append(file)
                }
            }
        }
        let root = U8Node(name: name(Int(d.be32(nodeTable + 4))), isDirectory: true)
        root.isRARC = true
        try build(nodeIndex: 0, into: root)
        return root
    }

    /// Writes `root` back as a RARC the way Nintendo's tool lays one out: nodes breadth-first,
    /// each node's entries in order then "." and "..", file IDs = entry indices (the "synced" IDs
    /// flag set), and the tables and every file's data 32-byte aligned.
    static func serialize(_ root: U8Node) -> Data {
        var nodes: [U8Node] = [root], i = 0
        while i < nodes.count { nodes += nodes[i].children.filter(\.isDirectory); i += 1 }
        let nodeIndex = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { (ObjectIdentifier($1), $0) })

        var strings = Data(), stringOffset: [String: Int] = [:]
        func string(_ s: String) -> Int {
            if let o = stringOffset[s] { return o }
            stringOffset[s] = strings.count
            strings.append(Data(s.utf8)); strings.append(0)
            return stringOffset[s]!
        }
        _ = string("."); _ = string(".."); _ = string(root.name)

        var nodeTable = Data(), entries = Data(), fileData = Data(), entryCount = 0
        for node in nodes {
            let type = nodeTable.isEmpty ? "ROOT" : String(node.name.uppercased().prefix(4)).padding(toLength: 4, withPad: " ", startingAt: 0)
            nodeTable.append(Data(type.utf8.prefix(4)))
            nodeTable.append(be32(UInt32(string(node.name)))); nodeTable.append(be16(hash(node.name)))
            nodeTable.append(be16(UInt16(node.children.count + 2))); nodeTable.append(be32(UInt32(entryCount)))
            func entry(id: UInt16, name: String, flags: UInt16, value: UInt32, size: UInt32) {
                entries.append(be16(id)); entries.append(be16(hash(name))); entries.append(be16(flags))
                entries.append(be16(UInt16(string(name)))); entries.append(be32(value)); entries.append(be32(size)); entries.append(be32(0))
                entryCount += 1
            }
            for child in node.children {
                if child.isDirectory {
                    entry(id: 0xFFFF, name: child.name, flags: 0x0200, value: UInt32(nodeIndex[ObjectIdentifier(child)]!), size: 0x10)
                } else {
                    let d = child.data ?? Data()
                    entry(id: UInt16(truncatingIfNeeded: entryCount), name: child.name, flags: 0x1100, value: UInt32(fileData.count), size: UInt32(d.count))
                    fileData.append(d); pad(&fileData)
                }
            }
            entry(id: 0xFFFF, name: ".", flags: 0x0200, value: UInt32(nodeIndex[ObjectIdentifier(node)]!), size: 0x10)
            let parent = node.parent.flatMap { nodeIndex[ObjectIdentifier($0)] }
            entry(id: 0xFFFF, name: "..", flags: 0x0200, value: parent.map(UInt32.init) ?? 0xFFFF_FFFF, size: 0x10)
        }

        var out = Data(count: 0x40)
        out.append(nodeTable); pad(&out)
        let entryStart = out.count
        out.append(entries); pad(&out)
        let stringStart = out.count
        out.append(strings); pad(&out)
        let stringSize = out.count - stringStart, dataStart = out.count
        out.append(fileData)
        func set(_ o: Int, _ v: Data) { out.replaceSubrange(o..<(o + v.count), with: v) }
        set(0, Data("RARC".utf8)); set(4, be32(UInt32(out.count))); set(8, be32(0x20)); set(0x0C, be32(UInt32(dataStart - 0x20)))
        set(0x10, be32(UInt32(fileData.count))); set(0x14, be32(UInt32(fileData.count)))
        set(0x20, be32(UInt32(nodes.count))); set(0x24, be32(0x20)); set(0x28, be32(UInt32(entryCount))); set(0x2C, be32(UInt32(entryStart - 0x20)))
        set(0x30, be32(UInt32(stringSize))); set(0x34, be32(UInt32(stringStart - 0x20))); set(0x38, be16(UInt16(truncatingIfNeeded: entryCount))); set(0x3A, Data([1]))
        return out
    }

    /// Nintendo's RARC name hash.
    static func hash(_ name: String) -> UInt16 {
        let bytes = Array(name.utf8)
        let multiplier: UInt16 = bytes.count + 1 == 2 ? 2 : bytes.count + 1 >= 3 ? 3 : 1
        return bytes.reduce(UInt16(0)) { $0 &* multiplier &+ UInt16($1) }
    }

    private static func pad(_ d: inout Data) { if d.count % 32 != 0 { d.append(Data(count: 32 - d.count % 32)) } }
    private static func be16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
    private static func be32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
}
