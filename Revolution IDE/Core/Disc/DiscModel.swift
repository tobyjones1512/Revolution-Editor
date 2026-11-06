import Foundation

nonisolated enum WiiConstants {
    static let clusterSize: UInt64 = 0x8000
    static let hashBlockSize: UInt64 = 0x400
    static let dataPerCluster: UInt64 = 0x7C00
    static let h3Size: UInt64 = 0x18000
    static let partitionTableAddress: UInt64 = 0x40000
    static let ticketSize: UInt64 = 0x2A4
    static let wiiMagic: UInt32 = 0x5D1C9EA3
    static let gcMagic: UInt32 = 0xC2339F3D
    static let partitionAlignment: UInt64 = 0x20000 // Wii wants partitions on 128KB boundaries
}

nonisolated enum PartitionKind: UInt32 {
    case data = 0
    case update = 1
    case channel = 2
    case unknown = 0xFFFFFFFF

    init(raw: UInt32) {
        self = PartitionKind(rawValue: raw) ?? .unknown
    }

    var label: String {
        switch self {
        case .data: return "DATA"
        case .update: return "UPDATE"
        case .channel: return "CHANNEL"
        case .unknown: return "UNKNOWN"
        }
    }
}

nonisolated struct PartitionTableEntry {
    var tableIndex: Int
    var indexInTable: Int
    var offset: UInt64
    var kind: PartitionKind
}

/// The fields we read out of a partition header (right after the ticket).
nonisolated struct PartitionHeaderInfo {
    var tmdSize: UInt32
    var tmdOffset: UInt64
    var certSize: UInt32
    var certOffset: UInt64
    var h3Offset: UInt64
    var dataOffset: UInt64
    var dataSize: UInt64
}

nonisolated struct FSTEntry {
    var index: Int
    var isDirectory: Bool
    var nameOffset: UInt32
    var name: String
    /// For files: byte offset (already <<2'd) into the de-hashed partition data stream.
    /// For directories: index of the parent entry.
    var fileOffsetOrParent: UInt64
    /// For files: length in bytes. For directories: index of the entry one past the last
    /// descendant (i.e. next sibling / uncle).
    var lengthOrNextIndex: UInt64
}

/// A node in the tree the UI displays: "WII DISC" -> partitions -> ticket.bin/tmd.bin/cert.bin/h3.bin
/// and the regular file/folder tree from the FST.
nonisolated final class DiscNode: Identifiable, Hashable {
    static func == (lhs: DiscNode, rhs: DiscNode) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    enum Kind {
        case root
        case partition(Int)
        case partitionComponent(String) // ticket.bin / tmd.bin / cert.bin / h3.bin
        case directory
        case file
    }

    let id = UUID()
    var name: String
    var kind: Kind
    var partitionIndex: Int?
    var fstIndex: Int?
    /// Offset into the de-hashed partition data stream (files only).
    var fileOffset: UInt64 = 0
    var fileSize: UInt64 = 0
    var children: [DiscNode] = []
    weak var parent: DiscNode?

    init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }

    /// For SwiftUI's `OutlineGroup`/`List(children:)`, which wants `nil` (not an empty array) for
    /// leaves so they don't render a disclosure triangle.
    var childrenOrNil: [DiscNode]? { children.isEmpty ? nil : children }

    var isFile: Bool { if case .file = kind { return true }; return false }
    var isDirectory: Bool {
        switch kind {
        case .directory, .root, .partition: return true
        default: return false
        }
    }

    /// A negative index means "system file": ticket.bin, tmd.bin, cert.bin, h3.bin, boot.bin,
    /// bi2.bin, apploader.img and fst.bin aren't real FST entries, so they get a negative
    /// pseudo-index just so the tree can show them.
    var displayFSTIndex: Int {
        fstIndex ?? -1
    }
}

nonisolated struct RuntimePartition {
    var entry: PartitionTableEntry
    var titleID: UInt64
    var commonKeyIndex: UInt8
    var titleKey: [UInt8]
    var header: PartitionHeaderInfo
    var tmdData: Data
    var ticketData: Data
    var numContents: Int
    var gameTitle: String = ""
    var gameID: String = ""
    var root: DiscNode!
    var fst: [FSTEntry] = []
    /// Offset/size (in the de-hashed data stream) of fst.bin itself, and the space originally
    /// reserved for it. Everything from stream offset 0 through `fstOffset + fstSize` is
    /// boot.bin/bi2.bin/apploader.img/main.dol/fst.bin, never free space, even though only
    /// fst.bin's own bounds are known precisely (apploader/dol have no FST entries).
    var fstOffset: UInt64 = 0
    var fstSize: UInt64 = 0
    var maxFSTSize: UInt64 = 0
    /// Byte length of the FST-referenced data (sum of all file sizes), shown as the
    /// "size of data on the disc" figure.
    var usedDataSize: UInt64 = 0
}

/// A disc image whose files can be browsed and read, a Wii disc (`WiiDisc`, decrypted) or a
/// GameCube disc (`GameCubeDisc`). Disc projects and their editors work through this so both
/// consoles open the same way.
nonisolated protocol DiscImageReader: AnyObject {
    var root: DiscNode! { get }
    var gameID: String { get }
    var gameTitle: String { get }
    func readFile(node: DiscNode) throws -> Data
}

extension WiiDisc: DiscImageReader {}
extension GameCubeDisc: DiscImageReader {}

/// Opens a disc image as whichever console it's for.
nonisolated func openDiscImage(_ url: URL, commonKey: [UInt8]?, koreanKey: [UInt8]?) throws -> any DiscImageReader {
    if GameCubeDisc.isGameCubeDisc(url) { return try GameCubeDisc(url: url) }
    return try WiiDisc(url: url, commonKey: commonKey, koreanKey: koreanKey)
}
