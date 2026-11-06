import Foundation

/// Hot Swap for GameCube games (Mario Kart: Double Dash!!). Riivolution, what Wii Hot Swap uses
///, is Wii-only, so instead this makes a patched copy of the base disc: an APFS clone (instant,
/// no extra space until written) with each marked file written over the disc file of the same
/// name, exactly the matching Wii Hot Swap uses. The original disc is never touched. The copy
/// boots in Dolphin, and also works in Nintendont on a real Wii.
///
/// GameCube disc layout: magic 0xC2339F3D at 0x1C; FST offset/size at 0x424/0x428. FST entries are
/// 12 bytes, flags+name offset, then (file) disc offset and size, or (directory) parent and
/// next index; the string table follows the entries.
nonisolated enum GameCubeHotSwap {
    static func isGameCubeDisc(_ url: URL) -> Bool { GameCubeDisc.isGameCubeDisc(url) }

    struct Result { var replaced: [String]; var unmatched: [String]; var moved: [String] }

    static func buildPatchedDisc(base: URL, modRoot: URL, files: [String], output: URL) throws -> Result {
        let fm = FileManager.default
        try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: output.path) { try fm.removeItem(at: output) }
        try fm.copyItem(at: base, to: output) // clonefile on APFS
        let h = try FileHandle(forUpdating: output)
        defer { try? h.close() }
        func read(_ offset: Int, _ count: Int) throws -> Data {
            try h.seek(toOffset: UInt64(offset))
            return try h.read(upToCount: count) ?? Data()
        }
        let header = try read(0, 0x440)
        let fstOffset = Int(header.be32(0x424)), fstSize = Int(header.be32(0x428))
        let fst = try read(fstOffset, fstSize)
        let count = Int(fst.be32(8))
        let strings = count * 12
        let discSize = Int(try h.seekToEnd())

        struct Entry { var index: Int; var name: String; var offset: Int; var size: Int }
        var entries: [Entry] = []
        for i in 1..<count where fst.u8(i * 12) == 0 {
            let nameOffset = Int(fst.be32(i * 12) & 0x00FF_FFFF)
            var e = strings + nameOffset
            while e < fst.count, fst.u8(e) != 0 { e += 1 }
            let name = String(decoding: fst[(fst.startIndex + strings + nameOffset)..<(fst.startIndex + e)], as: UTF8.self)
            entries.append(Entry(index: i, name: name, offset: Int(fst.be32(i * 12 + 4)), size: Int(fst.be32(i * 12 + 8))))
        }
        // Space nothing uses, for a replacement bigger than the file it replaces.
        var used: [(Int, Int)] = [(0, fstOffset + fstSize)] + entries.map { ($0.offset, $0.offset + $0.size) }
        used.sort { $0.0 < $1.0 }
        func allocate(_ size: Int) -> Int {
            var cursor = 0
            for (start, end) in used {
                let aligned = (cursor + 0x7FFF) & ~0x7FFF
                if aligned + size <= start { used.append((aligned, aligned + size)); used.sort { $0.0 < $1.0 }; return aligned }
                cursor = max(cursor, end)
            }
            let aligned = (max(cursor, discSize) + 0x7FFF) & ~0x7FFF
            used.append((aligned, aligned + size))
            return aligned
        }

        var result = Result(replaced: [], unmatched: [], moved: [])
        for relative in files {
            let name = (relative as NSString).lastPathComponent
            let matches = entries.filter { $0.name == name }
            guard !matches.isEmpty else { result.unmatched.append(relative); continue }
            let data = try Data(contentsOf: modRoot.appendingPathComponent(relative))
            for m in matches {
                var offset = m.offset
                if data.count > m.size {
                    offset = allocate(data.count)
                    result.moved.append(name)
                }
                try h.seek(toOffset: UInt64(offset))
                try h.write(contentsOf: data)
                var patch = Data()
                patch.append(contentsOf: withUnsafeBytes(of: UInt32(offset).bigEndian, Array.init))
                patch.append(contentsOf: withUnsafeBytes(of: UInt32(data.count).bigEndian, Array.init))
                try h.seek(toOffset: UInt64(fstOffset + m.index * 12 + 4))
                try h.write(contentsOf: patch)
            }
            result.replaced.append(name)
        }
        return result
    }
}
