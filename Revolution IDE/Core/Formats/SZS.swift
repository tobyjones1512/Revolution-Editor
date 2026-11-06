import Foundation

/// A .szs is just a Yaz0-compressed U8 archive (.arc files are the same U8 archive, usually
/// uncompressed). This ties the two together for opening/saving. GameCube RARC archives (Double
/// Dash `.arc`) open into the same tree and save back as RARC (`U8Node.isRARC`).
nonisolated enum SZS {
    static func open(_ data: Data) throws -> (root: U8Node, wasCompressed: Bool) {
        let compressed = Yaz0.isYaz0(data)
        let raw = compressed ? try Yaz0.decode(data) : data
        return (RARC.isRARC(raw) ? try RARC.parse(raw) : try U8Archive.parse(raw), compressed)
    }

    static func save(root: U8Node, compressed: Bool) -> Data {
        let raw = root.isRARC ? RARC.serialize(root) : U8Archive.serialize(root)
        return compressed ? Yaz0.encode(raw) : raw
    }
}
