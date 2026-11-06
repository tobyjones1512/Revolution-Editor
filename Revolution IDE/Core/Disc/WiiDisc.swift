import Foundation

/// Opens a Wii disc image (plain, decrypted-header ISO layout, the standard ".iso"/".wbfs-free"
/// format every Wii scrubbing/backup tool of this era works with) and builds the browsable tree.
///
/// `nonisolated` so this whole engine layer can run on a background thread (the project defaults
/// new declarations to @MainActor isolation), callers (AppState) pass the keys in explicitly
/// rather than this type reaching into the @MainActor `KeyManager` itself.
nonisolated final class WiiDisc {
    let url: URL
    let file: RandomAccessFile
    var fileSize: UInt64 = 0

    var gameID: String = ""
    var gameTitle: String = ""
    var discNumber: UInt8 = 0
    var discVersion: UInt8 = 0
    var bootMode: UInt8 = 0 // first byte of the disc; 'R' (0x52) = normal, 0x00 = auto-boot

    var partitionTableEntries: [PartitionTableEntry] = []
    var partitions: [RuntimePartition] = []

    var root: DiscNode!

    private let commonKey: [UInt8]?
    private let koreanKey: [UInt8]?

    init(url: URL, commonKey: [UInt8]?, koreanKey: [UInt8]?) throws {
        self.url = url
        self.commonKey = commonKey
        self.koreanKey = koreanKey
        self.file = try RandomAccessFile(forReadingFrom: url)
        self.fileSize = try file.fileSize()
        try parse()
    }

    deinit { file.close() }

    private func key(for commonKeyIndex: UInt8) throws -> [UInt8] {
        switch commonKeyIndex {
        case 1:
            guard let k = koreanKey else { throw WSError.keyMissing("kkey.bin (Korean key) not loaded.") }
            return k
        default:
            guard let k = commonKey else { throw WSError.keyMissing("key.bin (common key) not loaded.") }
            return k
        }
    }

    private func parse() throws {
        let header = try file.read(at: 0, count: 0x60)
        guard header.count == 0x60 else { throw WSError.ioError("Disc image too small.") }

        let wiiMagic = header.be32(0x18)
        guard wiiMagic == WiiConstants.wiiMagic else {
            throw WSError.notAWiiOrGameCubeDisc
        }

        gameID = header.asciiString(at: 0, length: 6)
        bootMode = header.u8(0)
        discNumber = header.u8(6)
        discVersion = header.u8(7)

        let titleBlock = try file.read(at: 0x20, count: 0x40)
        gameTitle = titleBlock.asciiString(at: 0, length: 0x40)

        try readPartitionTables()
        try parseAllPartitions()
        buildRoot()
    }

    private func readPartitionTables() throws {
        let tocData = try file.read(at: WiiConstants.partitionTableAddress, count: 0x20)
        for t in 0..<4 {
            let countOff = t * 8
            let count = Int(tocData.be32(countOff))
            let tableOffset = tocData.be32Shifted(countOff + 4)
            guard count > 0, count < 64 else { continue }
            let tableData = try file.read(at: tableOffset, count: count * 8)
            for i in 0..<count {
                let off = i * 8
                let partOffset = tableData.be32Shifted(off)
                let partType = tableData.be32(off + 4)
                partitionTableEntries.append(PartitionTableEntry(
                    tableIndex: t, indexInTable: i, offset: partOffset, kind: PartitionKind(raw: partType)))
            }
        }
    }

    private func parseAllPartitions() throws {
        for entry in partitionTableEntries {
            do {
                let p = try parsePartition(entry)
                partitions.append(p)
            } catch {
                // Keep going, a single malformed/unreadable partition (common on discs missing
                // the Korean key, or with an unusual layout) shouldn't block browsing the rest.
                continue
            }
        }
    }

    private func parsePartition(_ entry: PartitionTableEntry) throws -> RuntimePartition {
        let ticketData = try file.read(at: entry.offset, count: Int(WiiConstants.ticketSize))
        guard ticketData.count == Int(WiiConstants.ticketSize) else {
            throw WSError.badStructure("Partition at 0x\(String(entry.offset, radix: 16)) has a truncated ticket.")
        }
        let titleID = ticketData.be64(0x1DC)
        let commonKeyIndex = ticketData.u8(0x1F1)
        let encryptedTitleKey = [UInt8](ticketData.subdata(at: 0x1BF, length: 16))

        var ivBytes = [UInt8](repeating: 0, count: 16)
        let titleIDBytes = withUnsafeBytes(of: titleID.bigEndian) { Array($0) }
        for i in 0..<8 { ivBytes[i] = titleIDBytes[i] }

        let partitionKey = try key(for: commonKeyIndex)
        let titleKeyData = WiiCrypto.aesDecrypt(key: partitionKey, iv: ivBytes, data: Data(encryptedTitleKey))
        guard titleKeyData.count == 16 else { throw WSError.ioError("Title key decrypt failed.") }
        let titleKey = [UInt8](titleKeyData)

        let headerBase = entry.offset + WiiConstants.ticketSize
        let headerData = try file.read(at: headerBase, count: 0x20)
        let header = PartitionHeaderInfo(
            tmdSize: headerData.be32(0x00),
            tmdOffset: entry.offset + headerData.be32Shifted(0x04),
            certSize: headerData.be32(0x08),
            certOffset: entry.offset + headerData.be32Shifted(0x0C),
            h3Offset: entry.offset + headerData.be32Shifted(0x10),
            dataOffset: entry.offset + headerData.be32Shifted(0x14),
            dataSize: headerData.be32Shifted(0x18)
        )

        let tmdData = try file.read(at: header.tmdOffset, count: Int(header.tmdSize))
        let numContents = Int(tmdData.be16(0x1DE))

        var p = RuntimePartition(
            entry: entry, titleID: titleID, commonKeyIndex: commonKeyIndex, titleKey: titleKey,
            header: header, tmdData: tmdData, ticketData: ticketData, numContents: numContents)

        // boot.bin lives at the very start of the de-hashed data stream.
        let bootBin = try ClusterCrypto.read(file: file, partitionDataOffset: header.dataOffset,
                                              titleKey: titleKey, streamOffset: 0, length: 0x480)
        p.gameID = bootBin.asciiString(at: 0, length: 6)
        p.gameTitle = bootBin.asciiString(at: 0x20, length: 0x40)

        let fstOffset = bootBin.be32Shifted(0x424)
        let fstSize = bootBin.be32Shifted(0x428)
        let maxFSTSize = bootBin.be32Shifted(0x42C)
        guard fstSize > 0, fstSize < 64 * 1024 * 1024 else {
            throw WSError.badStructure("Implausible fst.bin size for partition at 0x\(String(entry.offset, radix: 16)).")
        }
        let fstData = try ClusterCrypto.read(file: file, partitionDataOffset: header.dataOffset,
                                              titleKey: titleKey, streamOffset: fstOffset, length: fstSize)
        let entries = try FSTBuilder.parse(fstData)
        p.fst = entries
        p.fstOffset = fstOffset
        p.fstSize = fstSize
        p.maxFSTSize = maxFSTSize
        p.usedDataSize = entries.filter { !$0.isDirectory }.reduce(0) { $0 + $1.lengthOrNextIndex }
        p.root = nil // set by caller (buildRoot) once the index into `partitions` is known
        return p
    }

    private func buildRoot() {
        root = DiscNode(name: "WII DISC", kind: .root)
        for (i, entry) in partitionTableEntries.enumerated() {
            let pNode = DiscNode(name: "Partition \(entry.indexInTable) (table \(entry.tableIndex)) - \(entry.kind.label)", kind: .partition(i))
            pNode.partitionIndex = i
            root.children.append(pNode)

            guard let idx = partitions.firstIndex(where: { $0.entry.offset == entry.offset }) else {
                pNode.name += " [unreadable]"
                continue
            }
            var p = partitions[idx]
            if !p.gameTitle.isEmpty { pNode.name = "\(p.gameTitle) - " + pNode.name }

            for name in ["ticket.bin", "tmd.bin", "cert.bin", "h3.bin"] {
                let c = DiscNode(name: name, kind: .partitionComponent(name))
                c.partitionIndex = i
                pNode.children.append(c)
            }

            let fileTree = FSTBuilder.buildTree(p.fst, partitionIndex: i)
            for child in fileTree.children { child.parent = pNode }
            pNode.children.append(contentsOf: fileTree.children)
            p.root = fileTree
            partitions[idx] = p
        }
    }

    // MARK: Convenience accessors used by the UI / operations

    func partitionIndex(of node: DiscNode) -> Int? { node.partitionIndex }

    func readFile(node: DiscNode) throws -> Data {
        guard node.isFile, let pIdx = node.partitionIndex else { throw WSError.badStructure("Not a file.") }
        let p = partitions[pIdx]
        return try ClusterCrypto.read(file: file, partitionDataOffset: p.header.dataOffset,
                                       titleKey: p.titleKey, streamOffset: node.fileOffset, length: node.fileSize)
    }

    func readPartitionComponent(partitionIndex: Int, name: String) throws -> Data {
        let p = partitions[partitionIndex]
        switch name {
        case "ticket.bin": return p.ticketData
        case "tmd.bin": return p.tmdData
        case "cert.bin": return try file.read(at: p.header.certOffset, count: Int(p.header.certSize))
        case "h3.bin": return try file.read(at: p.header.h3Offset, count: Int(WiiConstants.h3Size))
        default: throw WSError.badStructure("Unknown partition component \(name).")
        }
    }
}
