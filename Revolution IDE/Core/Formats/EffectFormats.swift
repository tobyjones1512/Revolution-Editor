import Foundation

// MKWii's small fixed-layout course files (post effects, lighting, the Mii-statue material) and
// the NW4R particle-effect pair (BREFF/BREFT). Layouts from the community documentation,
// checked against every retail copy on the disc by Tests/EffectFormatsCheck.

/// One editable value at a fixed offset in a fixed-layout binary file.
nonisolated struct BinaryField: Identifiable {
    enum Kind: Equatable { case u8, u16, u32, f32, rgba, text(Int) }
    let offset: Int
    let label: String
    let kind: Kind
    /// Section heading this field is listed under ("Header", "Light 3", ...).
    let group: String
    var id: Int { offset }

    var size: Int {
        switch kind {
        case .u8: 1
        case .u16: 2
        case .u32, .f32, .rgba: 4
        case .text(let n): n
        }
    }
}

/// The field list for each fixed-layout format this app edits in place, picked by magic (or, for
/// the headerless `.bmm`, by extension and size).
nonisolated enum BinaryFieldSchema {
    static let extensions: Set<String> = ["bblm", "bblm1", "bdof", "blight", "blmap", "bmm"]

    static func fields(fileName: String, data: Data) -> (title: String, summary: String, fields: [BinaryField])? {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let magic = data.count >= 4 ? data.asciiString(at: 0, length: 4) : ""
        switch magic {
        case "PBLM" where data.count >= 0xA4: return ("Bloom (BBLM)", "Post-effect bloom: which bright parts of the screen glow, and how much.", bloom)
        case "PDOF" where data.count >= 0x50: return ("Depth of Field (BDOF)", "Post-effect depth-of-field blur by distance from the camera.", depthOfField)
        case "LGHT" where data.count >= 0x28: return ("Light Set (BLIGHT)", "The light objects (sun, ambient, spot) the course and karts are lit with.", lightSet(data))
        case "LMAP" where data.count >= 0x20: return ("Light Map (BLMAP)", "Gradient lighting stages that use the BLIGHT light objects.", lightMap(data))
        default: break
        }
        if ext == "bmm", data.count == 0x14 {
            return ("Mii Statue Material (BMM)", "Material for the Mii-head statues (MiiStatue objects), used only when racing as a Mii.", [
                BinaryField(offset: 0x00, label: "Constant colour", kind: .rgba, group: "Material"),
                BinaryField(offset: 0x04, label: "course.btiMat S scale", kind: .f32, group: "Material"),
                BinaryField(offset: 0x08, label: "course.btiMat S translation", kind: .f32, group: "Material"),
                BinaryField(offset: 0x0C, label: "course.btiMat T scale", kind: .f32, group: "Material"),
                BinaryField(offset: 0x10, label: "course.btiMat T translation", kind: .f32, group: "Material"),
            ])
        }
        return nil
    }

    private static let bloom: [BinaryField] = [
        BinaryField(offset: 0x10, label: "Threshold intensity", kind: .f32, group: "Threshold"),
        BinaryField(offset: 0x14, label: "Threshold colour", kind: .rgba, group: "Threshold"),
        BinaryField(offset: 0x18, label: "Tint colour", kind: .rgba, group: "Threshold"),
        BinaryField(offset: 0x1C, label: "Flags", kind: .u16, group: "Threshold"),
        BinaryField(offset: 0x20, label: "First blur strength", kind: .f32, group: "Blur"),
        BinaryField(offset: 0x24, label: "First blur colour intensity", kind: .f32, group: "Blur"),
        BinaryField(offset: 0x40, label: "Second blur stage 1 strength", kind: .f32, group: "Blur"),
        BinaryField(offset: 0x44, label: "Second blur stage 1 colour intensity", kind: .f32, group: "Blur"),
        BinaryField(offset: 0x64, label: "Second blur stage 2 colour intensity", kind: .f32, group: "Blur"),
        BinaryField(offset: 0x81, label: "Second blur stage count", kind: .u8, group: "Blur"),
        BinaryField(offset: 0x80, label: "Output blend mode", kind: .u8, group: "Output"),
        BinaryField(offset: 0x9C, label: "Bloom intensity, stage 1", kind: .f32, group: "Output"),
        BinaryField(offset: 0xA0, label: "Bloom intensity, stage 2", kind: .f32, group: "Output"),
    ]

    private static let depthOfField: [BinaryField] = [
        BinaryField(offset: 0x10, label: "Filter flags (bit 15: indirect texture)", kind: .u16, group: "Blend"),
        BinaryField(offset: 0x12, label: "Inverse alpha", kind: .u8, group: "Blend"),
        BinaryField(offset: 0x13, label: "Alpha", kind: .u8, group: "Blend"),
        BinaryField(offset: 0x14, label: "Draw mode (1 inverse only, 2 both)", kind: .u8, group: "Depth of field"),
        BinaryField(offset: 0x15, label: "Draw amount", kind: .u8, group: "Depth of field"),
        BinaryField(offset: 0x16, label: "Curve type", kind: .u8, group: "Depth of field"),
        BinaryField(offset: 0x18, label: "Plane distance", kind: .f32, group: "Depth of field"),
        BinaryField(offset: 0x1C, label: "Plane range", kind: .f32, group: "Depth of field"),
        BinaryField(offset: 0x24, label: "Expand (higher is blurrier)", kind: .f32, group: "Depth of field"),
        BinaryField(offset: 0x28, label: "Scroll speed S", kind: .f32, group: "Indirect texture"),
        BinaryField(offset: 0x2C, label: "Scroll speed T", kind: .f32, group: "Indirect texture"),
        BinaryField(offset: 0x30, label: "Indirect scale S", kind: .f32, group: "Indirect texture"),
        BinaryField(offset: 0x34, label: "Indirect scale T", kind: .f32, group: "Indirect texture"),
        BinaryField(offset: 0x38, label: "Scale S", kind: .f32, group: "Indirect texture"),
        BinaryField(offset: 0x3C, label: "Scale T", kind: .f32, group: "Indirect texture"),
    ]

    private static func lightSet(_ data: Data) -> [BinaryField] {
        var out = [BinaryField(offset: 0x14, label: "Ambient black colour", kind: .rgba, group: "Header")]
        let lobjCount = Int(data.be16(0x10)), ambientCount = Int(data.be16(0x12))
        for i in 0..<lobjCount {
            let b = 0x28 + i * 0x50, g = "Light \(i)"
            guard b + 0x50 <= data.count, data.asciiString(at: b, length: 4) == "LOBJ" else { break }
            out += [
                BinaryField(offset: b + 0x13, label: "Type (0 point, 1 directional, 2 spot)", kind: .u8, group: g),
                BinaryField(offset: b + 0x12, label: "Coordinate system", kind: .u8, group: g),
                BinaryField(offset: b + 0x16, label: "Flags", kind: .u16, group: g),
                BinaryField(offset: b + 0x18, label: "Origin X", kind: .f32, group: g),
                BinaryField(offset: b + 0x1C, label: "Origin Y", kind: .f32, group: g),
                BinaryField(offset: b + 0x20, label: "Origin Z", kind: .f32, group: g),
                BinaryField(offset: b + 0x24, label: "Target X", kind: .f32, group: g),
                BinaryField(offset: b + 0x28, label: "Target Y", kind: .f32, group: g),
                BinaryField(offset: b + 0x2C, label: "Target Z", kind: .f32, group: g),
                BinaryField(offset: b + 0x30, label: "Intensity", kind: .f32, group: g),
                BinaryField(offset: b + 0x34, label: "Colour", kind: .rgba, group: g),
                BinaryField(offset: b + 0x38, label: "Light map ambient colour", kind: .rgba, group: g),
                BinaryField(offset: b + 0x14, label: "Ambient light index", kind: .u16, group: g),
                BinaryField(offset: b + 0x3C, label: "Spot cutoff angle", kind: .f32, group: g),
                BinaryField(offset: b + 0x10, label: "Angle falloff function", kind: .u8, group: g),
                BinaryField(offset: b + 0x11, label: "Distance falloff function", kind: .u8, group: g),
                BinaryField(offset: b + 0x40, label: "Falloff reference distance", kind: .f32, group: g),
                BinaryField(offset: b + 0x44, label: "Falloff reference brightness", kind: .f32, group: g),
            ]
        }
        let ambientBase = 0x28 + lobjCount * 0x50
        for i in 0..<ambientCount where ambientBase + i * 8 + 4 <= data.count {
            out.append(BinaryField(offset: ambientBase + i * 8, label: "Ambient light \(i)", kind: .rgba, group: "Ambient lights"))
        }
        return out
    }

    private static func lightMap(_ data: Data) -> [BinaryField] {
        var out: [BinaryField] = []
        var b = 0x20
        for i in 0..<Int(data.be16(0x10)) {
            guard b + 0x3C <= data.count, data.asciiString(at: b, length: 4) == "LTEX" else { break }
            let g = "Light texture \(i)"
            out += [
                BinaryField(offset: b + 0x14, label: "Texture name (starts with lm_)", kind: .text(32), group: g),
                BinaryField(offset: b + 0x34, label: "Gradient type (0-2)", kind: .u8, group: g),
                BinaryField(offset: b + 0x38, label: "Active BLIGHT lights (bit mask)", kind: .u32, group: g),
            ]
            for s in 0..<Int(data.be16(b + 0x10)) where b + 0x3C + s * 8 + 8 <= data.count {
                let o = b + 0x3C + s * 8
                out.append(BinaryField(offset: o, label: "Stage \(s) intensity (0-1)", kind: .f32, group: g))
                out.append(BinaryField(offset: o + 4, label: "Stage \(s) gradient", kind: .u8, group: g))
            }
            b += Int(data.be32(b + 4))
        }
        return out
    }

    // MARK: Reading and writing values

    static func value(_ f: BinaryField, in data: Data) -> String {
        switch f.kind {
        case .u8: return String(data.u8(f.offset))
        case .u16: return String(format: "0x%04X", data.be16(f.offset))
        case .u32: return String(format: "0x%08X", data.be32(f.offset))
        case .f32: return "\(Float(bitPattern: data.be32(f.offset)))" // shortest form that reads back exactly
        case .rgba: return String(format: "%08X", data.be32(f.offset))
        case .text(let n):
            let bytes = Data(data).subdata(in: f.offset..<(f.offset + n)).prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    /// Writes `text` into `data` at the field, or returns false (leaving `data` alone) if it
    /// doesn't parse as that field's type.
    static func set(_ f: BinaryField, to text: String, in data: inout Data) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        func int(_ max: UInt64) -> UInt64? {
            let v = t.lowercased().hasPrefix("0x") ? UInt64(t.dropFirst(2), radix: 16) : UInt64(t)
            return v.flatMap { $0 <= max ? $0 : nil }
        }
        let base = data.startIndex + f.offset
        func put(_ v: UInt64, _ n: Int) { for i in 0..<n { data[base + i] = UInt8((v >> (8 * UInt64(n - 1 - i))) & 0xFF) } }
        switch f.kind {
        case .u8: guard let v = int(0xFF) else { return false }; put(v, 1)
        case .u16: guard let v = int(0xFFFF) else { return false }; put(v, 2)
        case .u32: guard let v = int(0xFFFF_FFFF) else { return false }; put(v, 4)
        case .f32: guard let v = Float(t), v.isFinite else { return false }; put(UInt64(v.bitPattern), 4)
        case .rgba: guard t.count == 8, let v = UInt64(t, radix: 16) else { return false }; put(v, 4)
        case .text(let n):
            let bytes = Array(t.utf8)
            guard bytes.count < n else { return false }
            for i in 0..<n { data[base + i] = i < bytes.count ? bytes[i] : 0 }
        }
        return true
    }
}

// MARK: - BREFT / BREFF

/// The NW4R effect texture archive: a name table of GX textures the matching `.breff` emitters
/// draw with. Decoded into a `TPLDocument` so it reuses the TPL gallery and export.
nonisolated enum REFT {
    static func parse(_ data: Data) throws -> TPLDocument {
        let table = try tableEntries(data, magic: "REFT")
        let doc = TPLDocument()
        for e in table {
            let h = e.offset
            guard h + 0x20 <= data.count else { continue }
            let width = Int(data.be16(h + 4)), height = Int(data.be16(h + 6))
            guard width > 0, height > 0, let format = GXTextureFormat(rawValue: UInt32(data.u8(h + 0x0C))) else { continue }
            var palette: [(UInt8, UInt8, UInt8, UInt8)]?
            let paletteCount = Int(data.be16(h + 0x0E))
            if paletteCount > 0, let pf = GXPaletteFormat(rawValue: UInt32(data.u8(h + 0x0D))) {
                let p = h + 0x20 + Int(data.be32(h + 0x08))
                palette = (0..<paletteCount).compactMap { i in p + i * 2 + 2 <= data.count ? TextureCodec.decodePaletteEntry(data.be16(p + i * 2), format: pf) : nil }
            }
            var rgba = TextureCodec.decode(data: data, offset: h + 0x20, width: width, height: height, format: format, palette: palette)
            // Intensity textures are alpha masks in effects: show them that way.
            if format == .i4 || format == .i8, var px = rgba { for i in stride(from: 0, to: px.count, by: 4) { px[i + 3] = px[i] }; rgba = px }
            doc.images.append(TPLImage(width: width, height: height, format: format, rgba: rgba, name: e.name))
        }
        return doc
    }

    /// The shared REFF/REFT layout: a 0x10 file header, then one block whose u32 at +0x08 points
    /// (from +0x08) at a name table of `u16 length, name, u32 offset, u32 size` entries, offsets
    /// counted from the table's start.
    static func tableEntries(_ data: Data, magic: String) throws -> [(name: String, offset: Int, size: Int)] {
        guard data.count >= 0x30, data.asciiString(at: 0, length: 4) == magic, data.asciiString(at: 0x10, length: 4) == magic else {
            throw WSError.badStructure("Not a \(magic) file (bad magic).")
        }
        let table = 0x18 + Int(data.be32(0x18))
        guard table + 8 <= data.count else { throw WSError.badStructure("\(magic) name table is out of range.") }
        var out: [(String, Int, Int)] = []
        var p = table + 8
        for _ in 0..<Int(data.be16(table + 4)) {
            guard p + 2 <= data.count else { break }
            let len = Int(data.be16(p))
            guard p + 2 + len + 8 <= data.count else { break }
            let name = String(decoding: data.subdata(in: (p + 2)..<(p + 2 + len)).prefix { $0 != 0 }, as: UTF8.self)
            let o = p + 2 + len
            out.append((name, table + Int(data.be32(o)), Int(data.be32(o + 4))))
            p = o + 8
        }
        return out
    }
}

/// An NW4R particle effect project: its emitters and which `.breft` textures each one draws.
nonisolated struct REFFDocument {
    struct Emitter: Identifiable {
        let name: String
        let size: Int
        let textures: [String]
        var id: String { name }
    }
    var name: String
    var emitters: [Emitter]

    static func parse(_ data: Data) throws -> REFFDocument {
        let entries = try REFT.tableEntries(data, magic: "REFF")
        let nameLength = Int(data.be16(0x24))
        let name = data.count >= 0x28 + nameLength ? String(decoding: data.subdata(in: 0x28..<(0x28 + nameLength)).prefix { $0 != 0 }, as: UTF8.self) : ""
        let emitters = entries.map { e -> Emitter in
            Emitter(name: e.name, size: e.size, textures: textureNames(data, emitter: e.offset, end: min(e.offset + e.size, data.count)))
        }
        return REFFDocument(name: name, emitters: emitters)
    }

    /// Emitter entry: u32 runtime name pointer, u32 emitter size, the emitter, then u32 particle
    /// size and the particle, whose texture references start at +0x84 as length-prefixed names
    /// (up to three: colour, then two more layers).
    private static func textureNames(_ data: Data, emitter: Int, end: Int) -> [String] {
        guard emitter + 8 <= end else { return [] }
        let particle = emitter + 8 + Int(data.be32(emitter + 4))
        var p = particle + 4 + 0x84
        var names: [String] = []
        for _ in 0..<3 {
            guard p + 2 <= end else { break }
            let len = Int(data.be16(p))
            guard len > 0, len < 64, p + 2 + len <= end else { p += 2; continue }
            let name = String(decoding: data.subdata(in: (p + 2)..<(p + 2 + len)).prefix { $0 != 0 }, as: UTF8.self)
            if !name.isEmpty { names.append(name) }
            p += 2 + len
        }
        return names
    }
}
