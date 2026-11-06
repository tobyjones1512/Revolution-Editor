import Foundation

/// Nintendo's "Texture Palette Library", a standalone container for one or more GX textures
/// (used for things like loading-screen images, UI icons, and `savebanner.tpl`), as opposed to
/// BRRES's TEX0 which is always embedded in a `.brres`. Layout verified against the
/// community-documented structure. Its image format IDs
/// and palette format IDs are numerically identical to this app's existing `GXTextureFormat`/
/// `GXPaletteFormat` enums (same GX hardware formats BRRES's TEX0/PLT0 use), so decoding reuses
/// `TextureCodec` directly rather than duplicating it.
nonisolated struct TPLImage {
    var width: Int
    var height: Int
    var format: GXTextureFormat
    /// Tightly-packed RGBA8, or nil if this image's format/palette couldn't be decoded.
    var rgba: [UInt8]?
    /// Set for textures that carry a name (a J3D model's TEX1 entries, a `.bti`'s file name).
    var name: String? = nil
}

nonisolated final class TPLDocument {
    var images: [TPLImage] = []

    init() {}

    /// GameCube J3D textures (a model's TEX1, or a `.bti`) shown with the same viewer.
    convenience init(j3d textures: [J3DModel.Texture]) {
        self.init()
        images = textures.map { TPLImage(width: $0.width, height: $0.height, format: $0.format, rgba: $0.decoded(), name: $0.name) }
    }

    private static let fileIdentifier: UInt32 = 0x0020_AF30

    static func parse(_ data: Data) throws -> TPLDocument {
        guard data.count >= 12, data.be32(0) == fileIdentifier else {
            throw WSError.badStructure("Not a TPL file (bad file identifier).")
        }
        let count = Int(data.be32(4))
        let tableOffset = Int(data.be32(8))
        guard count > 0, count < 10_000, tableOffset >= 0 else {
            throw WSError.badStructure("TPL image count looks invalid.")
        }

        let doc = TPLDocument()
        for i in 0..<count {
            let entryOffset = tableOffset + i * 8
            guard entryOffset + 8 <= data.count else { break }
            let imageHeaderOfs = Int(data.be32(entryOffset))
            let paletteHeaderOfs = Int(data.be32(entryOffset + 4))
            guard imageHeaderOfs > 0, imageHeaderOfs + 0x0C <= data.count else { continue }

            let height = Int(data.be16(imageHeaderOfs))
            let width = Int(data.be16(imageHeaderOfs + 2))
            guard width > 0, height > 0, let format = GXTextureFormat(rawValue: data.be32(imageHeaderOfs + 4)) else { continue }
            let imageDataAddr = Int(data.be32(imageHeaderOfs + 8))
            guard imageDataAddr > 0, imageDataAddr <= data.count else { continue }

            var palette: [(UInt8, UInt8, UInt8, UInt8)]?
            if paletteHeaderOfs > 0, paletteHeaderOfs + 12 <= data.count {
                let entryCount = Int(data.be16(paletteHeaderOfs))
                if entryCount > 0, entryCount < 4096, let pfmt = GXPaletteFormat(rawValue: data.be32(paletteHeaderOfs + 4)) {
                    let paletteDataAddr = Int(data.be32(paletteHeaderOfs + 8))
                    if paletteDataAddr > 0 {
                        var entries: [(UInt8, UInt8, UInt8, UInt8)] = []
                        entries.reserveCapacity(entryCount)
                        for e in 0..<entryCount {
                            let off = paletteDataAddr + e * 2
                            guard off + 2 <= data.count else { break }
                            entries.append(TextureCodec.decodePaletteEntry(data.be16(off), format: pfmt))
                        }
                        palette = entries
                    }
                }
            }

            let rgba = TextureCodec.decode(data: data, offset: imageDataAddr, width: width, height: height, format: format, palette: palette)
            doc.images.append(TPLImage(width: width, height: height, format: format, rgba: rgba))
        }
        return doc
    }
}
