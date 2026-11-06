import Foundation

/// Typed view over a TEX0 resource's raw bytes.
///
/// Header layout verified against `riidefi/RiiStudio`'s actual reader/writer source
/// (`librii/g3d/io/TextureIO.cpp`) and confirmed against real course textures from a retail
/// Mario Kart Wii disc: magic(4)@0x00, size(4)@0x04, revision(4)@0x08 (1 or 3), BRRES
/// offset(4)@0x0C, **pixel data offset(4)@0x10** (a real field, conventionally 0x40 for
/// files this app or RiiStudio writes, but always read from the file rather than assumed),
/// name offset(4)@0x14, flag(4)@0x18, width(u16)@0x1C, height(u16)@0x1E, format(u32)@0x20,
/// mip count@0x24, minLod(f32)@0x28, maxLod(f32)@0x2C. A prior version of this reader had
/// width/height/format/mipCount each 0x0C too early (guessed rather than verified), so
/// `format` always landed on the wrong bytes, meaning it never matched a valid
/// `GXTextureFormat` raw value and every real texture silently failed to decode.
nonisolated struct TEX0View {
    let width: Int
    let height: Int
    let format: GXTextureFormat
    let mipCount: Int
    let pixelDataOffset: Int
    let data: Data

    static let minHeaderSize = 0x30

    init?(_ resource: BRRESResource) {
        let d = resource.data
        guard d.count >= TEX0View.minHeaderSize, d.asciiString(at: 0, length: 4) == "TEX0" else { return nil }
        let ofsTex = Int(d.be32(0x10))
        guard ofsTex > 0, ofsTex <= d.count else { return nil }
        width = Int(d.be16(0x1C))
        height = Int(d.be16(0x1E))
        guard let fmt = GXTextureFormat(rawValue: d.be32(0x20)) else { return nil }
        format = fmt
        mipCount = max(1, Int(d.be32(0x24)))
        pixelDataOffset = ofsTex
        data = d
    }

    func decodeRGBA(palette: [(UInt8, UInt8, UInt8, UInt8)]? = nil) -> [UInt8]? {
        TextureCodec.decode(data: data, offset: pixelDataOffset, width: width, height: height, format: format, palette: palette)
    }

    /// Builds a replacement TEX0 blob with the same header (format/size unchanged) but new pixel
    /// data re-encoded from RGBA8, the simplest, always-safe "replace texture" path. Every mip
    /// level the header declares is regenerated from the new pixels: re-encoding only the top
    /// level left a mipmapped texture (most retail course textures) with a header promising
    /// levels its data no longer had.
    static func rebuilding(_ resource: BRRESResource, withRGBA rgba: [UInt8]) -> Data? {
        guard let view = TEX0View(resource) else { return nil }
        var encoded = Data()
        for level in NormalMap.mipChain(rgba, width: view.width, height: view.height, count: view.mipCount) {
            guard let e = TextureCodec.encode(rgba: level.rgba, width: level.width, height: level.height, format: view.format) else { return nil }
            encoded.append(e)
        }
        var out = resource.data.prefix(view.pixelDataOffset)
        out.append(encoded)
        // Update length field.
        var d = Data(out)
        d.replaceSubrange(4..<8, with: withUnsafeBytes(of: UInt32(d.count).bigEndian) { Data($0) })
        return d
    }

    /// Builds a brand-new TEX0 resource blob from RGBA8 pixels, unlike `rebuilding` above (which
    /// only re-encodes an *existing* TEX0's own pixel data, keeping its header untouched), this is
    /// for adding a texture to a BRRES that doesn't have one yet, since this app previously had no
    /// from-scratch TEX0 encoder at all (only "Replace from Image..." for a texture that already
    /// exists). `pixelDataOffset` is fixed at the conventional 0x40 real files and this app's other
    /// writers already use. Nothing in this app ever dereferences a TEX0's own internal name field
    ///, the *wrapper* `BRRESResource.name` is what every lookup here actually uses (see
    /// `BRRESDocument.serialize`), so it's filled in with a trailing name string purely for
    /// compatibility with external tools that do read it, not because this app needs it.
    static func building(name: String, rgba: [UInt8], width: Int, height: Int, format: GXTextureFormat, mipCount: Int = 1) -> Data? {
        guard width > 0, height > 0 else { return nil }
        guard let encoded = TextureCodec.encode(rgba: rgba, width: width, height: height, format: format) else { return nil }
        return building(name: name, encoded: encoded, width: width, height: height, format: format, mipCount: mipCount)
    }

    /// The same, from pixel data already in `format` (e.g. a GameCube texture, which uses the
    /// identical GX encodings), copied as-is, so nothing is lost to re-encoding.
    static func building(name: String, encoded: Data, width: Int, height: Int, format: GXTextureFormat, mipCount: Int = 1) -> Data? {
        guard width > 0, height > 0 else { return nil }
        let headerSize = 0x40
        // An NW4R name (ResName): a u32 length, then the characters, lookups compare the length.
        let utf8 = name.data(using: .utf8) ?? Data()
        var nameBytes = Data(withUnsafeBytes(of: UInt32(utf8.count).bigEndian) { Array($0) }) + utf8 + Data([0])
        while nameBytes.count % 4 != 0 { nameBytes.append(0) }
        let nameStart = headerSize + encoded.count + 4

        let w = MutableDataWriter()
        w.putData("TEX0".data(using: .ascii)!)
        w.putU32(UInt32(nameStart - 4 + nameBytes.count)) // total resource size
        w.putU32(3) // revision
        w.putU32(0) // BRRES-relative offset, unused by this app's own reader
        w.putU32(UInt32(headerSize)) // pixel data offset
        // Relative to the TEX0's own start, not to this field, checked against retail
        // course_model.brres, where start + value lands exactly on each texture's name.
        w.putU32(UInt32(nameStart))
        w.putU32(0) // flag
        w.putU16(UInt16(width))
        w.putU16(UInt16(height))
        w.putU32(format.rawValue)
        w.putU32(UInt32(mipCount))
        w.putFloat32(0) // minLod
        w.putFloat32(Float(max(0, mipCount - 1))) // maxLod
        w.pad(to: headerSize)
        w.putData(encoded)
        w.putData(nameBytes)
        return w.data
    }
}

/// Typed view over a PLT0 (palette) resource's raw bytes, for decoding the CI4/CI8-indexed
/// textures that are extremely common in real Wii game data (most in-game/course textures use an
/// indexed format to save VRAM, unlike the direct-color formats). Header layout mirrors the same
/// fixed, widely-observed convention `TEX0View` already uses for its sibling NW4R resource type:
/// a 0x40 header (count @ 0x10, GX palette format @ 0x14) followed immediately by the raw 16-bit
/// palette entries.
nonisolated struct PLT0View {
    let format: GXPaletteFormat
    let entries: [(UInt8, UInt8, UInt8, UInt8)]

    static let headerSize = 0x40

    init?(_ resource: BRRESResource) {
        let d = resource.data
        guard d.count >= PLT0View.headerSize, d.asciiString(at: 0, length: 4) == "PLT0" else { return nil }
        guard let fmt = GXPaletteFormat(rawValue: d.be32(0x14)) else { return nil }
        format = fmt
        let count = Int(d.be32(0x10))
        guard count > 0, count < 4096 else { return nil }
        var out: [(UInt8, UInt8, UInt8, UInt8)] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            out.append(TextureCodec.decodePaletteEntry(d.be16(PLT0View.headerSize + i * 2), format: fmt))
        }
        entries = out
    }
}

/// Best-effort structural summary of an MDL0 model, purely for browsing.
///
/// MDL0's exact section-offset table differs across format versions and isn't something this app
/// trusts blindly; instead it scans every 4-byte-aligned position in the blob for whatever looks
/// like a valid BRRES index group (a small, count-bounded, plausibly-named dictionary) and lists
/// each group it finds along with its member names. This can't reliably say "this group is bones
/// vs. materials vs. shapes" without the exact section table, so it's presented as-is, still
/// useful for seeing what a model contains. Geometry extraction for the 3D preview is
/// attempted separately (see `MDL0GeometryExtractor`) and never depends on this succeeding.
nonisolated struct MDL0Summary {
    struct Group { var offset: Int; var names: [String] }
    var groups: [Group] = []

    static func scan(_ resource: BRRESResource) -> MDL0Summary {
        let d = resource.data
        var summary = MDL0Summary()
        var seen = Set<String>()
        var offset = 0x10
        while offset + 4 <= d.count {
            let entries = BRRESIndexGroup.parse(d, groupStart: offset)
            if !entries.isEmpty, entries.allSatisfy({ isPlausibleName($0.name) }) {
                let key = entries.map(\.name).joined(separator: ",")
                if !seen.contains(key) {
                    seen.insert(key)
                    summary.groups.append(Group(offset: offset, names: entries.map(\.name)))
                }
            }
            offset += 4
        }
        return summary
    }

    private static func isPlausibleName(_ s: String) -> Bool {
        !s.isEmpty && s.count < 64 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_.-() ".contains($0)) }
    }
}
