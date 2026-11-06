import Foundation

/// "Unscrub image": rebuilds the full ISO from a scrubbed ISO plus the .dif file this app
/// wrote when it scrubbed it (see `DiffFile`).
nonisolated enum Unscrubber {
    static func run(scrubbedURL: URL, diffURL: URL, destinationURL: URL,
                     progress: @escaping (Double, String) -> Void) throws {
        progress(0, "Reading diff header...")
        let loaded = try DiffFile.readHeader(diffURL)

        progress(0.05, "Copying scrubbed ISO...")
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: scrubbedURL, to: destinationURL)

        let outHandle = try FileHandle(forWritingTo: destinationURL)
        let diffHandle = try FileHandle(forReadingFrom: diffURL)
        defer { try? outHandle.close(); try? diffHandle.close() }

        let currentSize = try outHandle.seekToEnd()
        if currentSize < loaded.originalSize {
            try outHandle.truncate(atOffset: loaded.originalSize)
        }

        let total = max(loaded.records.count, 1)
        for (i, rec) in loaded.records.enumerated() {
            try diffHandle.seek(toOffset: rec.fileOffsetInDiff)
            guard let bytes = try diffHandle.read(upToCount: Int(rec.length)) else {
                throw WSError.ioError("Diff file truncated.")
            }
            try outHandle.seek(toOffset: rec.offset)
            try outHandle.write(contentsOf: bytes)
            if i % 64 == 0 {
                progress(0.05 + 0.95 * Double(i) / Double(total), "Restoring original data... (\(i)/\(loaded.records.count))")
            }
        }
        progress(1.0, "Unscrub complete.")
    }
}
