import Foundation

/// Partition-table-level operations exposed on the "WII DISC" / partition right-click menus:
/// delete, resize, shrink (defragment), shuffle (close inter-partition gaps), export/import a raw
/// encrypted partition blob, and add a new partition. All of these operate on a copy of the disc
/// image the caller has already made (see AppState, every destructive op works on a save-as
/// target, never the originally opened file).
nonisolated enum PartitionOperations {

    /// Best-effort "how much room does this partition have before the next one starts / EOF".
    static func allocatedSize(of entry: PartitionTableEntry, allEntries: [PartitionTableEntry], fileSize: UInt64) -> UInt64 {
        let nextOffset = allEntries.map(\.offset).filter { $0 > entry.offset }.min() ?? fileSize
        return nextOffset - entry.offset
    }

    // MARK: Delete partition

    static func deletePartition(discURL: URL, disc: WiiDisc, partitionIndex: Int, log: (String) -> Void) throws {
        let entry = disc.partitions[partitionIndex].entry
        var remainingInTable = disc.partitionTableEntries.filter { $0.tableIndex == entry.tableIndex && $0.offset != entry.offset }

        let writer = try RandomAccessFile(forUpdating: discURL)
        defer { writer.close() }

        let tocCountOffset = WiiConstants.partitionTableAddress + UInt64(entry.tableIndex) * 8
        let tocInfo = try writer.read(at: tocCountOffset, count: 8)
        let tableOffset = tocInfo.be32Shifted(4)

        remainingInTable.sort { $0.offset < $1.offset }
        let w = MutableDataWriter()
        for e in remainingInTable {
            w.putU32Shifted(e.offset)
            w.putU32(e.kind.rawValue)
        }
        try writer.write(w.data, at: tableOffset)

        let countW = MutableDataWriter()
        countW.putU32(UInt32(remainingInTable.count))
        try writer.write(countW.data, at: tocCountOffset)

        log("Deleted partition at 0x\(String(entry.offset, radix: 16)) from table \(entry.tableIndex). \(remainingInTable.count) partition(s) left in that table.")
        log("Reload the disc (File > Open) to refresh the browser.")
    }

    // MARK: Resize partition (data_size field only)

    static func resizePartition(discURL: URL, disc: WiiDisc, partitionIndex: Int, newDataSize: UInt64, log: (String) -> Void) throws {
        let p = disc.partitions[partitionIndex]
        let allocated = allocatedSize(of: p.entry, allEntries: disc.partitionTableEntries, fileSize: disc.fileSize)
        let maxDataSize = allocated - (p.header.dataOffset - p.entry.offset)
        guard newDataSize <= maxDataSize else {
            throw WSError.ioError("Requested size (0x\(String(newDataSize, radix: 16))) exceeds the space available before the next partition/EOF (max 0x\(String(maxDataSize, radix: 16))).")
        }
        let writer = try RandomAccessFile(forUpdating: discURL)
        defer { writer.close() }
        let headerBase = p.entry.offset + WiiConstants.ticketSize
        let w = MutableDataWriter(); w.putU32Shifted(newDataSize)
        try writer.write(w.data, at: headerBase + 0x18)
        log("Resized partition data_size to 0x\(String(newDataSize, radix: 16)) bytes.")
    }

    // MARK: Shrink partition (defragment: pack all real data at the start, uses Trucha)

    static func shrinkPartition(discURL: URL, disc: WiiDisc, partitionIndex: Int, log: (String) -> Void) throws {
        var p = disc.partitions[partitionIndex]
        let writer = try RandomAccessFile(forUpdating: discURL)
        defer { writer.close() }

        let systemEnd = FileOperations.systemAreaEnd(p)
        log("Packing files starting at 0x\(String(systemEnd, radix: 16))...")

        var cursor = systemEnd
        var newFST = p.fst
        let filesByOldOffset = p.fst.enumerated().filter { !$0.element.isDirectory }.sorted { $0.element.fileOffsetOrParent < $1.element.fileOffsetOrParent }

        for (arrayIdx, e) in filesByOldOffset {
            if e.fileOffsetOrParent == cursor {
                cursor += e.lengthOrNextIndex
                continue
            }
            let bytes = try ClusterCrypto.read(file: writer, partitionDataOffset: p.header.dataOffset,
                                                titleKey: p.titleKey, streamOffset: e.fileOffsetOrParent, length: e.lengthOrNextIndex)
            try ClusterCrypto.write(file: writer, header: p.header, titleKey: p.titleKey,
                                     streamOffset: cursor, data: bytes)
            var updated = e
            updated.fileOffsetOrParent = cursor
            newFST[arrayIdx] = updated
            cursor += e.lengthOrNextIndex
        }
        p.fst = newFST

        try FileOperations.rewriteFST(p: &p, writer: writer, disc: disc, log: log)

        let newDataSize = ClusterCrypto.dataSize(forStreamEnd: max(p.fstOffset + p.fstSize, cursor))
        let headerBase = p.entry.offset + WiiConstants.ticketSize
        let w = MutableDataWriter(); w.putU32Shifted(newDataSize)
        try writer.write(w.data, at: headerBase + 0x18)
        p.header.dataSize = newDataSize

        try TruchaOps.signPartition(&p, writer: writer)
        disc.partitions[partitionIndex] = p
        log("Shrink complete. New used size: 0x\(String(newDataSize, radix: 16)) bytes. Reload the disc to refresh the browser.")
    }

    // MARK: Shuffle partitions (close inter-partition gaps, no Trucha needed, content untouched)

    static func shufflePartitions(discURL: URL, disc: WiiDisc, log: (String) -> Void) throws {
        // `disc.partitions` only holds partitions `WiiDisc.parseAllPartitions` could successfully
        // parse, it silently skips any it couldn't (e.g. a Korean-key partition with no kkey.bin
        // loaded), which still occupies real space on disk. Packing every *parsed* partition
        // back-to-back from the start, as this does below, has no idea that space is spoken for --
        // it would happily move a parsed partition on top of an unparsed one still sitting there,
        // corrupting both, while leaving the unparsed partition's own table entry pointing at its
        // now-overwritten original offset. Safer to refuse outright than guess at its real size.
        guard disc.partitions.count == disc.partitionTableEntries.count else {
            throw WSError.ioError("This disc has a partition this app couldn't fully parse (e.g. a Korean-key partition with no kkey.bin loaded). Shuffle can't safely run without risking overwriting it. Load the missing key first, or use Shrink on individual partitions instead.")
        }

        let writer = try RandomAccessFile(forUpdating: discURL)
        defer { writer.close() }

        let sorted = disc.partitions.sorted { $0.entry.offset < $1.entry.offset }
        var cursor: UInt64 = WiiConstants.partitionAlignment
        var newOffsets: [UInt64: UInt64] = [:] // old offset -> new offset

        for p in sorted {
            let aligned = alignUp(cursor, to: WiiConstants.partitionAlignment)
            if aligned != p.entry.offset {
                let size = allocatedRealSize(p)
                log("Moving partition from 0x\(String(p.entry.offset, radix: 16)) to 0x\(String(aligned, radix: 16)) (0x\(String(size, radix: 16)) bytes)...")
                try moveBlock(writer: writer, from: p.entry.offset, to: aligned, length: size)
            }
            newOffsets[p.entry.offset] = aligned
            cursor = aligned + allocatedRealSize(p)
        }

        for t in 0..<4 {
            let entries = disc.partitionTableEntries.filter { $0.tableIndex == t }
            guard !entries.isEmpty else { continue }
            let tocCountOffset = WiiConstants.partitionTableAddress + UInt64(t) * 8
            let tocInfo = try writer.read(at: tocCountOffset, count: 8)
            let tableOffset = tocInfo.be32Shifted(4)
            let w = MutableDataWriter()
            for e in entries.sorted(by: { $0.indexInTable < $1.indexInTable }) {
                w.putU32Shifted(newOffsets[e.offset] ?? e.offset)
                w.putU32(e.kind.rawValue)
            }
            try writer.write(w.data, at: tableOffset)
        }
        log("Shuffle complete. Reload the disc to refresh the browser.")
    }

    private static func allocatedRealSize(_ p: RuntimePartition) -> UInt64 {
        (p.header.dataOffset - p.entry.offset) + p.header.dataSize
    }

    private static func alignUp(_ v: UInt64, to alignment: UInt64) -> UInt64 {
        (v + alignment - 1) / alignment * alignment
    }

    private static func moveBlock(writer: RandomAccessFile, from src: UInt64, to dst: UInt64, length: UInt64) throws {
        guard dst != src else { return }
        precondition(dst < src, "moveBlock only supports moving to a lower offset (shuffle always closes gaps).")
        let chunkSize: UInt64 = 4 * 1024 * 1024
        var offset: UInt64 = 0
        while offset < length {
            let n = min(chunkSize, length - offset)
            let bytes = try writer.read(at: src + offset, count: Int(n))
            try writer.write(bytes, at: dst + offset)
            offset += n
        }
    }

    // MARK: Export / import a raw encrypted partition

    static func exportPartition(disc: WiiDisc, partitionIndex: Int, to destination: URL, progress: @escaping (Double) -> Void) throws {
        let p = disc.partitions[partitionIndex]
        let size = allocatedRealSize(p)
        let reader = disc.file
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        let chunkSize: UInt64 = 4 * 1024 * 1024
        var offset: UInt64 = 0
        while offset < size {
            let n = min(chunkSize, size - offset)
            let bytes = try reader.read(at: p.entry.offset + offset, count: Int(n))
            try out.write(contentsOf: bytes)
            offset += n
            progress(Double(offset) / Double(size))
        }
    }

    /// Imports a previously-exported crypted partition blob into the disc at `atOffset`
    /// (should be a free, 0x20000-aligned region) and registers it in the given partition table.
    static func importPartition(discURL: URL, blobURL: URL, atOffset: UInt64, tableIndex: Int, kind: PartitionKind,
                                 existingEntries: [PartitionTableEntry], log: (String) -> Void) throws {
        guard atOffset % WiiConstants.partitionAlignment == 0 else {
            throw WSError.ioError("Import offset must be aligned to 0x20000.")
        }
        let inTable = existingEntries.filter { $0.tableIndex == tableIndex }
        guard inTable.count < 3 else {
            throw WSError.ioError("Partition table \(tableIndex) already has the maximum of 3 partitions (a Wii disc limitation).")
        }

        let blobSize = try FileManager.default.attributesOfItem(atPath: blobURL.path)[.size] as? UInt64 ?? 0
        guard blobSize > 0 else { throw WSError.ioError("Empty partition file.") }

        let writer = try RandomAccessFile(forUpdating: discURL)
        defer { writer.close() }
        let input = try FileHandle(forReadingFrom: blobURL)
        defer { try? input.close() }
        var written: UInt64 = 0
        while let chunk = try input.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            try writer.write(chunk, at: atOffset + written)
            written += UInt64(chunk.count)
        }

        var newEntries = inTable
        newEntries.append(PartitionTableEntry(tableIndex: tableIndex, indexInTable: inTable.count, offset: atOffset, kind: kind))

        let tocCountOffset = WiiConstants.partitionTableAddress + UInt64(tableIndex) * 8
        let tocInfo = try writer.read(at: tocCountOffset, count: 8)
        let tableOffset = tocInfo.be32Shifted(4)
        let w = MutableDataWriter()
        for e in newEntries { w.putU32Shifted(e.offset); w.putU32(e.kind.rawValue) }
        try writer.write(w.data, at: tableOffset)
        let countW = MutableDataWriter(); countW.putU32(UInt32(newEntries.count))
        try writer.write(countW.data, at: tocCountOffset)

        log("Imported partition (\(blobSize) bytes) at 0x\(String(atOffset, radix: 16)) into table \(tableIndex). Reload the disc to refresh the browser.")
    }

    /// First 0x20000-aligned offset at/after the end of the disc's current highest partition,
    /// suggested as the default target for Import/Add Partition.
    static func suggestedFreeOffset(disc: WiiDisc) -> UInt64 {
        let end = disc.partitions.map { allocatedRealSize($0) + $0.entry.offset }.max() ?? WiiConstants.partitionAlignment
        return alignUp(end, to: WiiConstants.partitionAlignment)
    }
}
