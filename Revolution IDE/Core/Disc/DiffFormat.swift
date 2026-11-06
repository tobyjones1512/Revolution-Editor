import Foundation

/// A simple, self-contained "what did scrubbing change" diff format used by this app's own
/// scrub/unscrub round trip: a sequence of (offset, original bytes) records.
///
/// This is the app's own format, not compatible with .dif files from other scrubbing tools.
/// A diff written by "Clean and Save" can always be used to "Unscrub" the image it came from.
nonisolated enum DiffFile {
    static let magic = "WSDF"

    static func write(records: [(offset: UInt64, original: Data)], originalSize: UInt64, to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        let header = MutableDataWriter()
        header.putData(magic.data(using: .ascii)!)
        header.putU32(1) // version
        header.putU64(originalSize)
        header.putU32(UInt32(records.count))
        try handle.write(contentsOf: header.data)

        for r in records {
            let rec = MutableDataWriter()
            rec.putU64(r.offset)
            rec.putU32(UInt32(r.original.count))
            try handle.write(contentsOf: rec.data)
            try handle.write(contentsOf: r.original)
        }
    }

    struct Loaded {
        var originalSize: UInt64
        var records: [(offset: UInt64, length: UInt32, fileOffsetInDiff: UInt64)]
        var url: URL
    }

    static func readHeader(_ url: URL) throws -> Loaded {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let magicData = try handle.read(upToCount: 4), String(data: magicData, encoding: .ascii) == magic else {
            throw WSError.badStructure("Not a Revolution Editor diff file.")
        }
        _ = try handle.read(upToCount: 4) // version
        guard let sizeData = try handle.read(upToCount: 8) else { throw WSError.badStructure("Truncated diff file.") }
        let originalSize = Data(sizeData).be64(0)
        guard let countData = try handle.read(upToCount: 4) else { throw WSError.badStructure("Truncated diff file.") }
        let count = Int(Data(countData).be32(0))

        var records: [(offset: UInt64, length: UInt32, fileOffsetInDiff: UInt64)] = []
        records.reserveCapacity(count)
        for _ in 0..<count {
            guard let recHeader = try handle.read(upToCount: 12), recHeader.count == 12 else {
                throw WSError.badStructure("Truncated diff file.")
            }
            let d = Data(recHeader)
            let offset = d.be64(0)
            let length = d.be32(8)
            let dataStart = handle.offsetInFile
            records.append((offset, length, dataStart))
            try handle.seek(toOffset: dataStart + UInt64(length))
        }
        return Loaded(originalSize: originalSize, records: records, url: url)
    }
}
