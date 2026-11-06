import Foundation

/// Single-file extract and replace (the right-click Save / Replace items). Replace first tries
/// to write the new data over the file's existing byte range, which works when the new file is
/// the same size or smaller. If it's bigger, the file is moved into free space elsewhere in the
/// same partition's data area.
nonisolated enum FileOperations {

    static func extract(disc: any DiscImageReader, node: DiscNode, to destination: URL) throws {
        let data: Data
        if let compName = componentName(node), let wii = disc as? WiiDisc {
            data = try wii.readPartitionComponent(partitionIndex: node.partitionIndex!, name: compName)
        } else {
            data = try disc.readFile(node: node)
        }
        try data.write(to: destination, options: .atomic)
    }

    /// Saves one file back into a disc image: a Wii disc through its encrypted partition
    /// (`replace`), a GameCube disc in place (`GameCubeDisc.replaceInPlace`).
    static func writeDiscEntry(discURL: URL, disc: any DiscImageReader, node: DiscNode, data: Data, log: @escaping (String) -> Void) throws {
        if let wii = disc as? WiiDisc {
            try replace(discURL: discURL, disc: wii, node: node, newData: data, log: log)
        } else {
            try GameCubeDisc.replaceInPlace(discURL: discURL, node: node, data: data)
        }
    }

    private static func componentName(_ node: DiscNode) -> String? {
        if case .partitionComponent(let name) = node.kind { return name }
        return nil
    }

    /// Recursively extracts every regular file under `node` (a directory, a partition, or the
    /// whole disc's root) to `destination`, recreating the on-disc folder structure below it.
    /// `node` itself isn't created as a subfolder of `destination`, its children land directly
    /// inside it, so "Extract Whole Disc..." on the disc root produces a folder whose top level
    /// mirrors the disc's own partitions/directories. Partition components (ticket.bin/tmd.bin/
    /// cert.bin/h3.bin) are deliberately skipped here, they're raw crypto headers, not game
    /// files, and remain individually extractable via a single-file "Extract..." if ever needed.
    static func extractAll(disc: any DiscImageReader, node: DiscNode, to destination: URL, progress: (Double, String) -> Void) throws {
        var files: [DiscNode] = []
        func collect(_ n: DiscNode) {
            if n.isFile { files.append(n) }
            for c in n.children { collect(c) }
        }
        collect(node)
        guard !files.isEmpty else {
            progress(1, "No files to extract.")
            return
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for (i, file) in files.enumerated() {
            let dest = destination.appendingPathComponent(relativePath(of: file, upTo: node))
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            progress(Double(i) / Double(files.count), "Extracting \(file.name)... (\(i + 1)/\(files.count))")
            try extract(disc: disc, node: file, to: dest)
        }
        progress(1, "Extracted \(files.count) file\(files.count == 1 ? "" : "s").")
    }

    /// `node`'s path relative to `ancestor`, following `parent` links (e.g.
    /// "Race/Course/luigi_circuit.szs"), used to recreate the on-disc folder structure.
    private static func relativePath(of node: DiscNode, upTo ancestor: DiscNode) -> String {
        var components: [String] = []
        var current: DiscNode? = node
        while let c = current, c !== ancestor {
            components.append(c.name)
            current = c.parent
        }
        return components.reversed().joined(separator: "/")
    }

    /// Replaces a file's contents in-place on the opened disc image (which must be opened for
    /// writing, see `WiiDisc.openForWriting`). Updates the FST and, if the file moved or the
    /// partition's signed metadata was touched, fake-signs the partition's ticket/TMD.
    static func replace(discURL: URL, disc: WiiDisc, node: DiscNode, newData: Data, log: (String) -> Void) throws {
        guard node.isFile, let pIdx = node.partitionIndex else { throw WSError.badStructure("Select a file first.") }
        var p = disc.partitions[pIdx]
        let writer = try RandomAccessFile(forUpdating: discURL)
        defer { writer.close() }

        guard var entry = p.fst.first(where: { $0.index == node.fstIndex }) else {
            throw WSError.badStructure("FST entry not found.")
        }

        let oldOffset = entry.fileOffsetOrParent
        let oldSize = entry.lengthOrNextIndex
        var newOffset = oldOffset

        if UInt64(newData.count) > oldSize {
            log("New file is larger than the original (\(newData.count) vs \(oldSize) bytes), looking for free space in the partition...")
            newOffset = try findSpaceOrGrow(disc: disc, p: &p, excludingFSTIndex: entry.index,
                                             neededSize: UInt64(newData.count), itemName: node.name, writer: writer, log: log)
            log("Relocating \"\(node.name)\" to offset 0x\(String(newOffset, radix: 16)).")
        }

        log("Writing \(newData.count) bytes...")
        try ClusterCrypto.write(file: writer, header: p.header, titleKey: p.titleKey,
                                 streamOffset: newOffset, data: newData)

        entry.fileOffsetOrParent = newOffset
        entry.lengthOrNextIndex = UInt64(newData.count)
        if let i = p.fst.firstIndex(where: { $0.index == entry.index }) { p.fst[i] = entry }

        try rewriteFST(p: &p, writer: writer, disc: disc, log: log)
        try TruchaOps.signPartition(&p, writer: writer)
        disc.partitions[pIdx] = p

        node.fileOffset = newOffset
        node.fileSize = UInt64(newData.count)
        log("Replace complete.")
    }

    /// Finds a byte-range inside the partition's already-allocated `[0, dataSize)` region that
    /// isn't used by any other file (or by boot.bin/apploader/fst.bin/main.dol), big enough to
    /// hold `neededSize` bytes.
    static func findFreeSpace(p: RuntimePartition, excludingFSTIndex: Int?, neededSize: UInt64) -> UInt64? {
        var used: [(UInt64, UInt64)] = [(0, systemAreaEnd(p))]
        for e in p.fst where !e.isDirectory && e.index != excludingFSTIndex {
            used.append((e.fileOffsetOrParent, e.fileOffsetOrParent + e.lengthOrNextIndex))
        }
        used.sort { $0.0 < $1.0 }

        var cursor: UInt64 = 0
        for (start, end) in used {
            if start > cursor, start - cursor >= neededSize { return cursor }
            cursor = max(cursor, end)
        }
        let capacity = ClusterCrypto.streamCapacity(forDataSize: p.header.dataSize)
        if capacity > cursor, capacity - cursor >= neededSize { return cursor }
        return nil
    }

    /// Like `findFreeSpace`, but if the partition's already-declared data region has no room,
    /// grows the partition instead of failing, appending right after the highest byte currently
    /// in use and bumping its `data_size` header field. `ClusterCrypto.write` naturally extends
    /// the underlying ISO file when it writes past the current end, so this is all that's needed
    /// to let the disc image grow rather than block the save.
    ///
    /// Only done when `p` is the disc's last partition by offset, growing any other partition
    /// would silently write into whatever partition follows it, which a "the ISO can get bigger"
    /// allowance never covers.
    static func findSpaceOrGrow(disc: WiiDisc, p: inout RuntimePartition, excludingFSTIndex: Int?,
                                 neededSize: UInt64, itemName: String, writer: RandomAccessFile, log: (String) -> Void) throws -> UInt64 {
        if let offset = findFreeSpace(p: p, excludingFSTIndex: excludingFSTIndex, neededSize: neededSize) {
            return offset
        }
        guard disc.partitionTableEntries.allSatisfy({ $0.offset <= p.entry.offset }) else {
            throw WSError.ioError("""
            Not enough free space left in this partition to fit "\(itemName)", and it isn't the disc's \
            last partition, so growing it would overwrite the partition after it. Use Partition > \
            Resize/Shrink to make room first, or reorder/shuffle partitions so this one is last.
            """)
        }

        var cursor = systemAreaEnd(p)
        for e in p.fst where !e.isDirectory && e.index != excludingFSTIndex {
            cursor = max(cursor, e.fileOffsetOrParent + e.lengthOrNextIndex)
        }
        cursor = max(cursor, ClusterCrypto.streamCapacity(forDataSize: p.header.dataSize))
        let newDataSize = ClusterCrypto.dataSize(forStreamEnd: cursor + neededSize)

        log("""
        "\(itemName)" doesn't fit in this partition's current space, growing the partition to \
        0x\(String(newDataSize, radix: 16)) bytes (the ISO will end up larger than when it was opened).
        """)
        let headerBase = p.entry.offset + WiiConstants.ticketSize
        let w = MutableDataWriter(); w.putU32Shifted(newDataSize)
        try writer.write(w.data, at: headerBase + 0x18)
        p.header.dataSize = newDataSize
        return cursor
    }

    /// boot.bin + bi2.bin + apploader.img + main.dol + fst.bin region is never free space.
    /// apploader/dol have no FST entries of their own, so the only precisely-known lower bound
    /// for "everything system-related" is fst.bin's own end, which, on every standard disc
    /// layout, comes after both of them.
    static func systemAreaEnd(_ p: RuntimePartition) -> UInt64 {
        max(p.fstOffset + p.fstSize, 0x2440)
    }

    static func rewriteFST(p: inout RuntimePartition, writer: RandomAccessFile, disc: WiiDisc, log: (String) -> Void) throws {
        let newFST = FSTBuilder.serialize(p.fst)
        var targetOffset = p.fstOffset

        let newSize = UInt64(newFST.count)
        if newSize > max(p.maxFSTSize, p.fstSize) {
            log("fst.bin grew beyond its original reserved size; relocating it into free space too.")
            targetOffset = try findSpaceOrGrow(disc: disc, p: &p, excludingFSTIndex: nil,
                                                neededSize: newSize, itemName: "fst.bin", writer: writer, log: log)
        }
        // boot.bin 0x424 = FST offset, 0x428 = FST size, 0x42C = max FST size (all >> 2). The
        // loader reads exactly 0x428 bytes, so it must follow every size change, previously only
        // the offset and *max* size were updated, and only on relocation, leaving 0x428 stale.
        if targetOffset != p.fstOffset || newSize != p.fstSize {
            var newBoot = try ClusterCrypto.read(file: writer, partitionDataOffset: p.header.dataOffset,
                                                  titleKey: p.titleKey, streamOffset: 0, length: 0x480)
            let newMax = max(p.maxFSTSize, newSize)
            for (field, value) in [(0x424, targetOffset), (0x428, newSize), (0x42C, newMax)] {
                let w = MutableDataWriter(); w.putU32Shifted(value)
                newBoot.replaceSubrange(field..<(field + 4), with: w.data)
            }
            try ClusterCrypto.write(file: writer, header: p.header, titleKey: p.titleKey,
                                     streamOffset: 0, data: newBoot.subdata(at: 0, length: 0x480))
            p.maxFSTSize = newMax
        }
        try ClusterCrypto.write(file: writer, header: p.header, titleKey: p.titleKey,
                                 streamOffset: targetOffset, data: newFST)
        p.fstOffset = targetOffset
        p.fstSize = UInt64(newFST.count)
    }
}

/// Fake-signs a partition's ticket and TMD after its data/FST has been modified, using the
/// well-documented "Trucha bug" padding offsets (see `WiiCrypto.truchaSign`), and writes the
/// updated ticket/TMD bytes back to the disc image.
nonisolated enum TruchaOps {
    static func signPartition(_ p: inout RuntimePartition, writer: RandomAccessFile) throws {
        // H4: the TMD's content hash is the SHA-1 of the H3 table, which `ClusterCrypto.write`
        // keeps current, refresh it before signing, or IOS rejects the partition.
        let h3 = try writer.read(at: p.header.h3Offset, count: Int(WiiConstants.h3Size))
        if h3.count == Int(WiiConstants.h3Size), p.tmdData.count >= 0x208 {
            p.tmdData.replaceSubrange(0x1F4..<0x208, with: WiiCrypto.sha1(h3))
        }
        var ticket = p.ticketData
        WiiCrypto.truchaSign(&ticket, signedRange: 0x140..<Int(WiiConstants.ticketSize), paddingOffset: 0x262)
        try writer.write(ticket, at: p.entry.offset)
        p.ticketData = ticket

        var tmd = p.tmdData
        let tmdSignedEnd = tmd.count
        WiiCrypto.truchaSign(&tmd, signedRange: 0x140..<tmdSignedEnd, paddingOffset: 0x1E2)
        try writer.write(tmd, at: p.header.tmdOffset)
        p.tmdData = tmd
    }
}
