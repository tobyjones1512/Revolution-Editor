import Foundation

nonisolated enum ScrubType {
    /// Blanks unused padding with 0xFF and leaves signatures and the hash tree alone. A console
    /// never reads padding clusters during normal play, so nothing it verifies is affected.
    case fill0xFF
    /// Blanks unused padding with zeroes and fake-signs (Trucha bug) the ticket/TMD of every
    /// touched partition.
    case trucha
}

nonisolated enum ScrubOutput {
    case isoOnly
    case diffOnly
    case both
}

nonisolated struct ScrubOptions {
    var type: ScrubType = .fill0xFF
    var output: ScrubOutput = .isoOnly
    var keepHeaders: Bool = true
}

nonisolated enum Scrubber {

    /// Returns, per partition, the sorted list of whole clusters (as data-stream cluster indices)
    /// that contain no bytes referenced by boot.bin/apploader/dol/fst.bin or any FST file --
    /// i.e. safe-to-blank padding.
    static func unusedClusters(for p: RuntimePartition) -> [UInt64] {
        var used: [(UInt64, UInt64)] = [(0, FileOperations.systemAreaEnd(p))]
        for e in p.fst where !e.isDirectory {
            used.append((e.fileOffsetOrParent, e.fileOffsetOrParent + e.lengthOrNextIndex))
        }
        used.sort { $0.0 < $1.0 }

        let totalClusters = ClusterCrypto.clusterCount(forDataSize: p.header.dataSize)
        var unused: [UInt64] = []
        var usedIdx = 0
        for cluster in 0..<totalClusters {
            let clusterStart = cluster * WiiConstants.dataPerCluster
            let clusterEnd = clusterStart + WiiConstants.dataPerCluster
            while usedIdx < used.count, used[usedIdx].1 <= clusterStart { usedIdx += 1 }
            let overlaps = usedIdx < used.count && used[usedIdx].0 < clusterEnd
            if !overlaps { unused.append(cluster) }
        }
        return unused
    }

    static func run(disc: WiiDisc, sourceURL: URL, options: ScrubOptions,
                     isoDestination: URL?, diffDestination: URL?,
                     progress: @escaping (Double, String) -> Void) throws {
        guard options.output != .diffOnly || diffDestination != nil else {
            throw WSError.ioError("No diff destination given.")
        }
        guard options.output == .diffOnly || isoDestination != nil else {
            throw WSError.ioError("No ISO destination given.")
        }

        let fileSize = disc.fileSize
        let reader = try RandomAccessFile(forReadingFrom: sourceURL)
        defer { reader.close() }

        var workURL = isoDestination
        var writer: RandomAccessFile?
        if options.output != .diffOnly {
            progress(0, "Copying source ISO...")
            try copyFile(from: sourceURL, to: isoDestination!, totalSize: fileSize, progress: progress)
            writer = try RandomAccessFile(forUpdating: isoDestination!)
        } else {
            workURL = nil
        }
        defer { writer?.close() }

        var diffRecords: [(offset: UInt64, original: Data)] = []
        let fillByte: UInt8 = (options.type == .trucha) ? 0x00 : 0xFF

        var totalClusters: UInt64 = 0
        for p in disc.partitions { totalClusters += ClusterCrypto.clusterCount(forDataSize: p.header.dataSize) }
        var processedClusters: UInt64 = 0

        for (pIdx, p) in disc.partitions.enumerated() {
            progress(Double(processedClusters) / Double(max(totalClusters, 1)), "Scanning partition \(pIdx)...")
            let unused = unusedClusters(for: p)
            for clusterIndex in unused {
                let clusterFileOffset = p.header.dataOffset + clusterIndex * WiiConstants.clusterSize
                let regionOffset = options.keepHeaders ? clusterFileOffset + WiiConstants.hashBlockSize : clusterFileOffset
                let regionLength = options.keepHeaders ? WiiConstants.dataPerCluster : WiiConstants.clusterSize

                if options.output != .isoOnly {
                    let original = try reader.read(at: regionOffset, count: Int(regionLength))
                    if !original.allSatisfy({ $0 == fillByte }) {
                        diffRecords.append((regionOffset, original))
                    }
                }
                if let writer {
                    try writer.write(Data(repeating: fillByte, count: Int(regionLength)), at: regionOffset)
                }
                processedClusters += 1
            }
            processedClusters += ClusterCrypto.clusterCount(forDataSize: p.header.dataSize) - UInt64(unused.count)
            progress(Double(processedClusters) / Double(max(totalClusters, 1)), "Scrubbed partition \(pIdx): \(unused.count) padding clusters.")
        }

        if options.type == .trucha, let writer {
            progress(0.95, "Fake-signing (Trucha bug) modified partitions...")
            var updated = disc.partitions
            for i in updated.indices {
                try TruchaOps.signPartition(&updated[i], writer: writer)
            }
            disc.partitions = updated
        }

        if options.output != .isoOnly, let diffDestination {
            progress(0.98, "Writing diff file...")
            try DiffFile.write(records: diffRecords, originalSize: fileSize, to: diffDestination)
        }

        progress(1.0, "Scrub complete.")
        _ = workURL
    }

    private static func copyFile(from src: URL, to dst: URL, totalSize: UInt64, progress: @escaping (Double, String) -> Void) throws {
        if FileManager.default.fileExists(atPath: dst.path) {
            try FileManager.default.removeItem(at: dst)
        }
        FileManager.default.createFile(atPath: dst.path, contents: nil)
        let input = try FileHandle(forReadingFrom: src)
        let output = try FileHandle(forWritingTo: dst)
        defer { try? input.close(); try? output.close() }

        let chunkSize = 4 * 1024 * 1024
        var copied: UInt64 = 0
        while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
            copied += UInt64(chunk.count)
            if totalSize > 0 { progress(Double(copied) / Double(totalSize) * 0.5, "Copying source ISO... (\(copied)/\(totalSize))") }
        }
    }
}
