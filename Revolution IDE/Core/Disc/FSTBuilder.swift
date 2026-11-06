import Foundation

/// Parses/serializes the Wii/GameCube "File System Table": a flat array of 12-byte entries
/// (directories and files interleaved depth-first) plus a trailing string table.
nonisolated enum FSTBuilder {

    /// `shiftFileOffsets`: true for Wii partition FSTs (file offsets are stored right-shifted by
    /// 2), false for GameCube FSTs (file offsets are stored as direct byte values).
    static func parse(_ fstData: Data, shiftFileOffsets: Bool = true) throws -> [FSTEntry] {
        guard fstData.count >= 12 else { throw WSError.badStructure("fst.bin too small.") }
        let rootNextIndex = Int(fstData.be32(8))
        guard rootNextIndex > 0, rootNextIndex * 12 <= fstData.count else {
            throw WSError.badStructure("fst.bin root entry count looks invalid.")
        }
        let stringTableOffset = rootNextIndex * 12
        var entries: [FSTEntry] = []
        entries.reserveCapacity(rootNextIndex)

        for i in 0..<rootNextIndex {
            let base = i * 12
            let typeAndNameOffset = fstData.be32(base)
            let isDir = (typeAndNameOffset >> 24) != 0
            let nameOffset = typeAndNameOffset & 0x00FFFFFF
            let field1 = fstData.be32(base + 4)
            let field2 = fstData.be32(base + 8)

            let name: String
            if i == 0 {
                name = "" // root
            } else {
                name = fstData.asciiString(at: stringTableOffset + Int(nameOffset), length: max(0, fstData.count - (stringTableOffset + Int(nameOffset))))
            }

            entries.append(FSTEntry(
                index: i,
                isDirectory: isDir,
                nameOffset: nameOffset,
                name: name,
                fileOffsetOrParent: isDir ? UInt64(field1) : (shiftFileOffsets ? UInt64(field1) << 2 : UInt64(field1)),
                lengthOrNextIndex: UInt64(field2)
            ))
        }
        return entries
    }

    /// Builds the DiscNode tree from a flat FST array.
    static func buildTree(_ entries: [FSTEntry], partitionIndex: Int) -> DiscNode {
        let root = DiscNode(name: "files", kind: .directory)
        root.partitionIndex = partitionIndex
        root.fstIndex = 0
        guard !entries.isEmpty else { return root }

        var stack: [(node: DiscNode, endIndex: Int)] = [(root, entries[0].lengthOrNextIndex == 0 ? entries.count : Int(entries[0].lengthOrNextIndex))]
        var i = 1
        while i < entries.count {
            while let top = stack.last, i >= top.endIndex { stack.removeLast() }
            guard let parent = stack.last?.node else { break }
            let e = entries[i]
            let node = DiscNode(name: e.name, kind: e.isDirectory ? .directory : .file)
            node.partitionIndex = partitionIndex
            node.fstIndex = e.index
            node.parent = parent
            if !e.isDirectory {
                node.fileOffset = e.fileOffsetOrParent
                node.fileSize = e.lengthOrNextIndex
            }
            parent.children.append(node)
            if e.isDirectory {
                stack.append((node, Int(e.lengthOrNextIndex)))
            }
            i += 1
        }
        return root
    }

    /// Re-serializes a (possibly edited) flat FST array back into fst.bin bytes.
    static func serialize(_ entries: [FSTEntry]) -> Data {
        let w = MutableDataWriter()
        var stringTable = Data()
        var nameOffsets: [Int: UInt32] = [:]

        for e in entries where e.index != 0 {
            nameOffsets[e.index] = UInt32(stringTable.count)
            stringTable.append(e.name.data(using: .utf8) ?? Data())
            stringTable.append(0)
        }

        for e in entries {
            let typeByte: UInt32 = e.isDirectory ? 1 : 0
            let nameOff = e.index == 0 ? 0 : (nameOffsets[e.index] ?? 0)
            w.putU32((typeByte << 24) | (nameOff & 0x00FFFFFF))
            if e.isDirectory {
                w.putU32(UInt32(truncatingIfNeeded: e.fileOffsetOrParent))
            } else {
                w.putU32Shifted(e.fileOffsetOrParent)
            }
            w.putU32(UInt32(truncatingIfNeeded: e.lengthOrNextIndex))
        }
        w.putData(stringTable)
        // boot.bin stores the FST size >> 2, so it must be a multiple of 4 or the last name's
        // terminator is cut off; retail pads exactly like this (checked on all 3 MKWii partitions).
        w.align(4)
        return w.data
    }
}
