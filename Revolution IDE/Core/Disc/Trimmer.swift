import Foundation

/// "Trim ISO": produces a copy of the disc image truncated right after the last partition's last
/// actually-used byte (rounded up to a whole cluster), instead of the full ~4.37GB disc size.
/// This mirrors what "trimmed" Wii images (as used by USB loaders) are, much smaller than a
/// real burnable disc image, but they carry every byte a game can actually read.
nonisolated enum Trimmer {
    static func run(disc: WiiDisc, sourceURL: URL, destinationURL: URL,
                     progress: @escaping (Double, String) -> Void) throws {
        guard let last = disc.partitions.max(by: { $0.header.dataOffset < $1.header.dataOffset }) else {
            throw WSError.badStructure("No partitions found to trim against.")
        }

        // Floor at the end of system data (boot.bin/bi2.bin/apploader.img/main.dol/fst.bin --
        // never a real FST file entry, so a partition whose files don't happen to extend past it
        // would otherwise trim into the middle of it). Matches `PartitionOperations.shrinkPartition`.
        var lastUsedInStream: UInt64 = FileOperations.systemAreaEnd(last)
        for e in last.fst where !e.isDirectory {
            lastUsedInStream = max(lastUsedInStream, e.fileOffsetOrParent + e.lengthOrNextIndex)
        }
        let trimmedClusters = ClusterCrypto.clusterCount(forDataSize: lastUsedInStream)
        let newDataSize = trimmedClusters * WiiConstants.dataPerCluster
        let newFileLength = last.header.dataOffset + trimmedClusters * WiiConstants.clusterSize

        if newFileLength >= disc.fileSize {
            throw WSError.ioError("Nothing to trim, this image is already trimmed.")
        }

        progress(0, "Copying trimmed data (0x\(String(newFileLength, radix: 16)) bytes)...")
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let input = try FileHandle(forReadingFrom: sourceURL)
        let output = try FileHandle(forWritingTo: destinationURL)
        defer { try? input.close(); try? output.close() }

        var remaining = newFileLength
        let chunkSize: UInt64 = 4 * 1024 * 1024
        var copied: UInt64 = 0
        while remaining > 0 {
            let toRead = Int(min(chunkSize, remaining))
            guard let chunk = try input.read(upToCount: toRead), !chunk.isEmpty else { break }
            try output.write(contentsOf: chunk)
            remaining -= UInt64(chunk.count)
            copied += UInt64(chunk.count)
            progress(Double(copied) / Double(newFileLength) * 0.9, "Copying trimmed data... (\(copied)/\(newFileLength))")
        }

        // Patch the partition header's data_size field (unsigned, no re-signing required) so
        // players/loaders know not to read past the new, shorter data region.
        progress(0.95, "Updating partition header data size...")
        let headerBase = last.entry.offset + WiiConstants.ticketSize
        let w = MutableDataWriter()
        w.putU32Shifted(newDataSize)
        try output.seek(toOffset: headerBase + 0x18)
        try output.write(contentsOf: w.data)

        progress(1.0, "Trim complete: 0x\(String(disc.fileSize, radix: 16)) -> 0x\(String(newFileLength, radix: 16)) bytes.")
    }
}
