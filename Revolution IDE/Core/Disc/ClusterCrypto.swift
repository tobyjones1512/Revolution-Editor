import Foundation

/// Reads/writes the "de-hashed" 0x7C00-byte-per-cluster decrypted data stream that partition data
/// offsets (boot.bin, fst.bin, FST file offsets, ...) are expressed in.
///
/// Wii partition data is stored as consecutive 0x8000-byte clusters, each made of a 0x400-byte
/// encrypted hash block followed by 0x7C00 bytes of encrypted content. The content of a cluster is
/// decrypted with the partition's title key using, as IV, the *still-encrypted* bytes at offset
/// 0x3D0 within that same cluster's hash block (a well known quirk of the format, no need to
/// decrypt the hash block first to get it).
nonisolated enum ClusterCrypto {

    /// Read `length` bytes starting at `streamOffset` (offset into the de-hashed stream) from a
    /// partition's data area, decrypting as needed.
    static func read(file: RandomAccessFile, partitionDataOffset: UInt64, titleKey: [UInt8],
                      streamOffset: UInt64, length: UInt64) throws -> Data {
        guard length > 0 else { return Data() }
        var result = Data(capacity: Int(length))
        var remaining = length
        var pos = streamOffset

        while remaining > 0 {
            let clusterIndex = pos / WiiConstants.dataPerCluster
            let intraOffset = pos % WiiConstants.dataPerCluster
            let clusterFileOffset = partitionDataOffset + clusterIndex * WiiConstants.clusterSize
            let raw = try file.read(at: clusterFileOffset, count: Int(WiiConstants.clusterSize))
            guard raw.count == Int(WiiConstants.clusterSize) else {
                throw WSError.ioError("Unexpected EOF reading cluster \(clusterIndex).")
            }
            let iv = [UInt8](raw.subdata(at: 0x3D0, length: 16))
            let cipherData = raw.subdata(at: Int(WiiConstants.hashBlockSize), length: Int(WiiConstants.dataPerCluster))
            let plain = WiiCrypto.aesDecrypt(key: titleKey, iv: iv, data: cipherData)

            let take = min(remaining, WiiConstants.dataPerCluster - intraOffset)
            result.append(plain.subdata(at: Int(intraOffset), length: Int(take)))
            remaining -= take
            pos += take
        }
        return result
    }

    /// Write `data` at `streamOffset` into a partition's data area, then rebuild the hash tree
    /// over every 64-cluster group it touched, the H0/H1/H2 tables in each cluster's 0x400-byte
    /// hash block and that group's H3 entry, so `TruchaOps.signPartition` can refresh the TMD's
    /// hash of the H3 table (H4). A real Wii verifies this tree on every disc read and refuses a
    /// cluster that doesn't match (Dolphin never checks, so an unhashed edit only fails on
    /// hardware). Fake-signing only gets past the ticket/TMD signatures, not these hashes.
    static func write(file: RandomAccessFile, header: PartitionHeaderInfo, titleKey: [UInt8],
                       streamOffset: UInt64, data: Data) throws {
        guard !data.isEmpty else { return }
        var remaining = data.count
        var srcOffset = 0
        var pos = streamOffset

        while remaining > 0 {
            let clusterIndex = pos / WiiConstants.dataPerCluster
            let intraOffset = Int(pos % WiiConstants.dataPerCluster)
            let clusterFileOffset = header.dataOffset + clusterIndex * WiiConstants.clusterSize

            var raw = try file.read(at: clusterFileOffset, count: Int(WiiConstants.clusterSize))
            if raw.count != Int(WiiConstants.clusterSize) {
                raw = Data(repeating: 0, count: Int(WiiConstants.clusterSize))
            }
            let iv = [UInt8](raw.subdata(at: 0x3D0, length: 16))
            var cipherData = raw.subdata(at: Int(WiiConstants.hashBlockSize), length: Int(WiiConstants.dataPerCluster))
            var plain = WiiCrypto.aesDecrypt(key: titleKey, iv: iv, data: cipherData)

            let take = min(remaining, Int(WiiConstants.dataPerCluster) - intraOffset)
            plain.replaceSubrange(intraOffset..<(intraOffset + take), with: data.subdata(at: srcOffset, length: take))

            cipherData = WiiCrypto.aesEncrypt(key: titleKey, iv: iv, data: plain)
            raw.replaceSubrange(Int(WiiConstants.hashBlockSize)..<Int(WiiConstants.clusterSize), with: cipherData)
            try file.write(raw, at: clusterFileOffset)

            remaining -= take
            srcOffset += take
            pos += UInt64(take)
        }

        let first = streamOffset / WiiConstants.dataPerCluster, last = (pos - 1) / WiiConstants.dataPerCluster
        let clusterLimit = max(header.dataSize / WiiConstants.clusterSize, last + 1)
        for group in (first / 64)...(last / 64) {
            try rehash(file: file, header: header, titleKey: titleKey, group: group, clusterLimit: clusterLimit)
        }
    }

    /// Rebuilds one group's hash tree from its clusters' current contents. Each cluster's hash
    /// block: H0 (0x000, a SHA-1 of each of its 31 0x400-byte data blocks), H1 (0x280, the SHA-1
    /// of each H0 table in its 8-cluster subgroup), H2 (0x340, the SHA-1 of each H1 table in the
    /// group); the H3 table (one SHA-1 of the H2 table per group) sits outside the data. The hash
    /// block is encrypted with a zero IV, and its encrypted bytes at 0x3D0 are the data's IV --
    /// so every cluster's data is re-encrypted too. Clusters past `clusterLimit` (the next
    /// partition, or not on disc) are hashed as zeros and never written.
    private static func rehash(file: RandomAccessFile, header: PartitionHeaderInfo, titleKey: [UInt8],
                               group: UInt64, clusterLimit: UInt64) throws {
        let count = Int(min(64, clusterLimit - group * 64))
        var plains: [Data] = []
        var h0Tables: [Data] = []
        for k in 0..<count {
            let offset = header.dataOffset + (group * 64 + UInt64(k)) * WiiConstants.clusterSize
            let raw = try file.read(at: offset, count: Int(WiiConstants.clusterSize))
            let plain = raw.count == Int(WiiConstants.clusterSize)
                ? WiiCrypto.aesDecrypt(key: titleKey, iv: [UInt8](raw.subdata(at: 0x3D0, length: 16)),
                                       data: raw.subdata(at: Int(WiiConstants.hashBlockSize), length: Int(WiiConstants.dataPerCluster)))
                : Data(count: Int(WiiConstants.dataPerCluster))
            var h0 = Data(capacity: 0x26C)
            for b in 0..<31 { h0.append(WiiCrypto.sha1(plain.subdata(at: b * 0x400, length: 0x400))) }
            plains.append(plain)
            h0Tables.append(h0)
        }
        let zeroHash = Data(count: 20)
        // H1 table per subgroup, H2 table for the group.
        var h1Tables: [Data] = []
        for sub in 0..<8 {
            var h1 = Data(capacity: 0xA0)
            for k in sub * 8..<(sub * 8 + 8) { h1.append(k < count ? WiiCrypto.sha1(h0Tables[k]) : zeroHash) }
            h1Tables.append(h1)
        }
        var h2 = Data(capacity: 0xA0)
        for sub in 0..<8 { h2.append(sub * 8 < count ? WiiCrypto.sha1(h1Tables[sub]) : zeroHash) }

        for k in 0..<count {
            var block = Data(count: Int(WiiConstants.hashBlockSize))
            block.replaceSubrange(0..<0x26C, with: h0Tables[k])
            block.replaceSubrange(0x280..<0x320, with: h1Tables[k / 8])
            block.replaceSubrange(0x340..<0x3E0, with: h2)
            let encryptedBlock = WiiCrypto.aesEncrypt(key: titleKey, iv: [UInt8](repeating: 0, count: 16), data: block)
            let encryptedData = WiiCrypto.aesEncrypt(key: titleKey, iv: [UInt8](encryptedBlock.subdata(at: 0x3D0, length: 16)), data: plains[k])
            let offset = header.dataOffset + (group * 64 + UInt64(k)) * WiiConstants.clusterSize
            try file.write(encryptedBlock + encryptedData, at: offset)
        }
        try file.write(WiiCrypto.sha1(h2), at: header.h3Offset + group * 20)
    }

    /// How many data-stream bytes a partition whose header says `dataSize` holds. The header's
    /// size counts whole 0x8000-byte encrypted clusters; file offsets count 0x7C00-byte payloads.
    static func streamCapacity(forDataSize dataSize: UInt64) -> UInt64 {
        dataSize / WiiConstants.clusterSize * WiiConstants.dataPerCluster
    }

    /// The header `dataSize` (whole encrypted clusters) for a data stream ending at `streamEnd`.
    static func dataSize(forStreamEnd streamEnd: UInt64) -> UInt64 {
        clusterCount(forDataSize: streamEnd) * WiiConstants.clusterSize
    }

    /// Number of whole+partial clusters spanned by a partition data region of `dataSize` bytes.
    static func clusterCount(forDataSize dataSize: UInt64) -> UInt64 {
        (dataSize + WiiConstants.dataPerCluster - 1) / WiiConstants.dataPerCluster
    }
}
