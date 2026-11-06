import Foundation

/// Minimal read-only GameCube disc support: browse and extract only. GameCube discs have no
/// encryption or partitions, so the Wii-side tools (scrub, replace, resize) don't apply.
nonisolated final class GameCubeDisc {
    let url: URL
    let file: RandomAccessFile
    var fileSize: UInt64 = 0
    var gameID: String = ""
    var gameTitle: String = ""
    var root: DiscNode!
    var fst: [FSTEntry] = []

    init(url: URL) throws {
        self.url = url
        self.file = try RandomAccessFile(forReadingFrom: url)
        self.fileSize = try file.fileSize()
        try parse()
    }

    deinit { file.close() }

    static func isGameCubeDisc(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 0x20), head.count == 0x20 else { return false }
        return head.be32(0x1C) == 0xC233_9F3D
    }

    /// Writes one file of a GameCube disc image in place (a disc project's Save): over its old
    /// data when it fits, else in free space or at the end, with its FST entry updated. Updates
    /// `node` to match.
    static func replaceInPlace(discURL: URL, node: DiscNode, data: Data) throws {
        guard let index = node.fstIndex else { throw WSError.badStructure("\(node.name) isn't a file on the disc.") }
        let h = try FileHandle(forUpdating: discURL)
        defer { try? h.close() }
        try h.seek(toOffset: 0)
        let header = try h.read(upToCount: 0x440) ?? Data()
        let fstOffset = Int(header.be32(0x424)), fstSize = Int(header.be32(0x428))
        try h.seek(toOffset: UInt64(fstOffset))
        let fst = try h.read(upToCount: fstSize) ?? Data()
        let count = Int(fst.be32(8))
        guard index > 0, index < count, fst.u8(index * 12) == 0 else { throw WSError.badStructure("\(node.name)'s disc entry is missing.") }
        var offset = Int(fst.be32(index * 12 + 4))
        let oldSize = Int(fst.be32(index * 12 + 8))
        if data.count > oldSize {
            // First gap (32 KB aligned) after the FST that no file uses, else the end of the disc.
            var used = [(0, fstOffset + fstSize)]
            for i in 1..<count where fst.u8(i * 12) == 0 && i != index { used.append((Int(fst.be32(i * 12 + 4)), Int(fst.be32(i * 12 + 4) + fst.be32(i * 12 + 8)))) }
            used.sort { $0.0 < $1.0 }
            let end = Int(try h.seekToEnd())
            var cursor = 0, found: Int?
            for (start, stop) in used {
                let aligned = (cursor + 0x7FFF) & ~0x7FFF
                if aligned + data.count <= start { found = aligned; break }
                cursor = max(cursor, stop)
            }
            offset = found ?? ((max(cursor, end) + 0x7FFF) & ~0x7FFF)
        }
        try h.seek(toOffset: UInt64(offset))
        try h.write(contentsOf: data)
        var patch = Data()
        patch.append(contentsOf: withUnsafeBytes(of: UInt32(offset).bigEndian, Array.init))
        patch.append(contentsOf: withUnsafeBytes(of: UInt32(data.count).bigEndian, Array.init))
        try h.seek(toOffset: UInt64(fstOffset + index * 12 + 4))
        try h.write(contentsOf: patch)
        node.fileOffset = UInt64(offset)
        node.fileSize = UInt64(data.count)
    }


    private func parse() throws {
        let header = try file.read(at: 0, count: 0x460)
        guard header.count == 0x460 else { throw WSError.ioError("Disc image too small.") }
        let gcMagic = header.be32(0x1C)
        guard gcMagic == WiiConstants.gcMagic else { throw WSError.notAWiiOrGameCubeDisc }

        gameID = header.asciiString(at: 0, length: 6)
        gameTitle = header.asciiString(at: 0x20, length: 0x40)

        let fstOffset = UInt64(header.be32(0x424))
        let fstSize = UInt64(header.be32(0x428))
        guard fstSize > 0, fstSize < 16 * 1024 * 1024 else { throw WSError.badStructure("Implausible GameCube fst.bin size.") }
        let fstData = try file.read(at: fstOffset, count: Int(fstSize))
        fst = try FSTBuilder.parse(fstData, shiftFileOffsets: false)

        root = DiscNode(name: "\(gameTitle) [\(gameID)] (GameCube)", kind: .root)
        let tree = FSTBuilder.buildTree(fst, partitionIndex: -1)
        for child in tree.children { child.parent = root }
        root.children = tree.children
    }

    func readFile(node: DiscNode) throws -> Data {
        guard node.isFile else { throw WSError.badStructure("Not a file.") }
        return try file.read(at: node.fileOffset, count: Int(node.fileSize))
    }
}
