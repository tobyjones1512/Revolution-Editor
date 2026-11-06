import Foundation

/// Binary Revolution LaYouT, the UI layout format for Wii menu/HUD screens (used together with
/// BRLAN animations, BRFNT fonts, and BRCTR files in Mario Kart Wii). Structure verified against
/// wiki.tockdom.com's "BRLYT (File Format)" page (community-documented byte offsets).
///
/// This is a deliberately scoped reader/patcher, not a full editor: the `mat1` material section
/// alone encodes a near-complete GX TEV pipeline (up to 8 texture maps/texgens/stages, indirect
/// texture stages, swap tables, blend/alpha-compare settings...) that a real layout tool would
/// need to fully model just to round-trip safely, so materials/textures/fonts are read for
/// reference (names/filenames) only, not edited. Panes are different: each `Pane` common
/// substructure (position/rotation/scale/size/visibility) is a small set of fixed-width fields at
/// a known absolute offset, so those are made editable by *patching the original file's
/// bytes in place* (`BRLYTDocument.rawData`) rather than attempting a from-scratch re-serialize --
/// which would risk silently breaking one of BRLYT's many other internal byte offsets (string
/// tables, material-ID indices, per-section lengths) this reader doesn't fully reproduce.
nonisolated final class BRLYTPane: Identifiable {
    let id = UUID()
    var kind: String // "pan1" (plain), "pic1" (picture), "bnd1" (bounds), "txt1" (text), "wnd1" (window)
    var name: String
    var visible: Bool
    var translation = Vec3()
    var rotation = Vec3()
    var scale = Vec2(x: 1, y: 1)
    var width: Float = 0
    var height: Float = 0
    /// Which point of the pane its translation places: 0-8 across a 3x3 grid, left-to-right then
    /// top-to-bottom (0 = top-left, 4 = centre, 8 = bottom-right).
    var origin: UInt8 = 4
    var alpha: UInt8 = 255
    /// Pane flag bit 1: children multiply in this pane's alpha.
    var influencesChildAlpha = false
    /// The material a picture, text or window pane draws with (index into `materials`).
    var materialIndex: Int?
    /// Window panes: the content area's four corner colours, averaged, what fills its middle.
    var windowFill: (UInt8, UInt8, UInt8, UInt8)?
    /// Picture panes: the first texture-coordinate set's bounds (sMin, tMin, sMax, tMax). Spans
    /// over 1 tile the texture (retail's checkered patterns use 8x5, 30x4...).
    var texCoordBounds: (Float, Float, Float, Float)?
    /// Picture panes' four corner colours' alpha, averaged.
    var vertexAlpha: UInt8 = 255
    /// Text panes: the string (UTF-16 in the file), size, colour and alignment.
    var text: String?
    var fontSize = Vec2(x: 16, y: 16)
    var textColor: (UInt8, UInt8, UInt8, UInt8) = (255, 255, 255, 255)
    /// 0-8 on the same 3x3 grid as `origin`.
    var textPosition: UInt8 = 4
    var children: [BRLYTPane] = []
    weak var parent: BRLYTPane?

    /// Absolute offset (into `BRLYTDocument.rawData`) of this pane's common `Pane` struct --
    /// where in-place field edits get patched back in.
    let fileOffset: Int

    init(kind: String, name: String, fileOffset: Int) {
        self.kind = kind
        self.name = name
        self.fileOffset = fileOffset
        self.visible = true
    }

    var childrenOrNil: [BRLYTPane]? { children.isEmpty ? nil : children }
}

nonisolated struct BRLYTMaterial {
    var name: String
    /// Indices into `textureFilenames`, one per texture map (the first is what a preview draws).
    var textureIndices: [Int] = []
    /// TEV "black" and "white" colours (RGBA): a texture's dark end maps to black, its light end
    /// to white, how the game tints greyscale UI textures.
    var blackColor: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
    var whiteColor: (UInt8, UInt8, UInt8, UInt8) = (255, 255, 255, 255)
}

nonisolated struct BRLYTGroup {
    var name: String
    var paneNames: [String]
}

nonisolated final class BRLYTDocument {
    /// Kept byte-exact except for in-place field patches, see the type's doc comment for why
    /// this format isn't fully re-serialized from the parsed model.
    var rawData: Data

    var isCentered = false
    var layoutWidth: Float = 0
    var layoutHeight: Float = 0
    var textureFilenames: [String] = []
    var fontFilenames: [String] = []
    var materials: [BRLYTMaterial] = []
    var rootPanes: [BRLYTPane] = []
    var groups: [BRLYTGroup] = []

    init(rawData: Data) { self.rawData = rawData }

    var allPanes: [BRLYTPane] {
        var out: [BRLYTPane] = []
        func walk(_ p: BRLYTPane) { out.append(p); for c in p.children { walk(c) } }
        for r in rootPanes { walk(r) }
        return out
    }

    // MARK: Parse

    private static let paneSectionKinds: Set<String> = ["pan1", "pic1", "bnd1", "txt1", "wnd1"]

    static func parse(_ data: Data) throws -> BRLYTDocument {
        guard data.count >= 0x10, data.asciiString(at: 0, length: 4) == "RLYT" else {
            throw WSError.badStructure("Not a BRLYT file (missing 'RLYT' magic).")
        }
        guard data.be16(4) == 0xFEFF else {
            throw WSError.badStructure("Little-endian BRLYT files aren't supported.")
        }
        let doc = BRLYTDocument(rawData: data)

        // Pane nesting: pas1 pushes a new "current children list" (the next sibling panes belong
        // to whichever pane was just read), pae1 pops it, the same stack-based approach this app
        // already uses for U8/NSMBW trees.
        var paneStack: [BRLYTPane] = []
        func appendPane(_ pane: BRLYTPane) {
            if let parent = paneStack.last {
                pane.parent = parent
                parent.children.append(pane)
            } else {
                doc.rootPanes.append(pane)
            }
        }

        var offset = 0x10
        while offset + 8 <= data.count {
            let magic = data.asciiString(at: offset, length: 4)
            let sectionLength = Int(data.be32(offset + 4))
            guard sectionLength >= 8, offset + sectionLength <= data.count else { break }

            switch magic {
            case "lyt1":
                doc.isCentered = data.u8(offset + 8) != 0
                doc.layoutWidth = data.beFloat32(offset + 0x0C)
                doc.layoutHeight = data.beFloat32(offset + 0x10)

            case "txl1", "fnl1":
                let count = Int(data.be16(offset + 8))
                let tableStart = offset + 0x0C
                var names: [String] = []
                for i in 0..<count {
                    let entry = tableStart + i * 8
                    guard entry + 4 <= data.count else { break }
                    let strOffset = tableStart + Int(data.be32(entry))
                    names.append(data.asciiString(at: strOffset, length: min(256, data.count - strOffset)))
                }
                if magic == "txl1" { doc.textureFilenames = names } else { doc.fontFilenames = names }

            case "mat1":
                let count = Int(data.be16(offset + 8))
                let offsetsStart = offset + 0x0C
                for i in 0..<count {
                    let entry = offsetsStart + i * 4
                    guard entry + 4 <= data.count else { break }
                    let matOffset = offset + Int(data.be32(entry))
                    guard matOffset + 20 <= data.count else { continue }
                    var material = BRLYTMaterial(name: data.asciiString(at: matOffset, length: 20))
                    // Flags at +0x3C; the low 4 bits count the texture maps that follow at +0x40,
                    // 4 bytes each (u16 texture index, wrap S, wrap T). Checked against every
                    // retail Mario Kart Wii layout: every index is in range.
                    if matOffset + 0x24 <= data.count {
                        func channel(_ o: Int) -> UInt8 { UInt8(clamping: Int(Int16(bitPattern: data.be16(o)))) }
                        material.blackColor = (channel(matOffset + 0x14), channel(matOffset + 0x16), channel(matOffset + 0x18), channel(matOffset + 0x1A))
                        material.whiteColor = (channel(matOffset + 0x1C), channel(matOffset + 0x1E), channel(matOffset + 0x20), channel(matOffset + 0x22))
                    }
                    if matOffset + 0x40 <= data.count {
                        let maps = Int(data.be32(matOffset + 0x3C) & 0xF)
                        for k in 0..<maps where matOffset + 0x40 + k * 4 + 2 <= data.count {
                            material.textureIndices.append(Int(data.be16(matOffset + 0x40 + k * 4)))
                        }
                    }
                    doc.materials.append(material)
                }

            case "pas1":
                if let last = paneStack.last ?? doc.rootPanes.last { paneStack.append(last) }

            case "pae1":
                if !paneStack.isEmpty { paneStack.removeLast() }

            case _ where paneSectionKinds.contains(magic):
                let paneStructOffset = offset + 8
                guard paneStructOffset + 0x44 <= data.count else { break }
                let name = data.asciiString(at: paneStructOffset + 0x04, length: 16)
                let pane = BRLYTPane(kind: magic, name: name, fileOffset: paneStructOffset)
                // Flags: bit 0 visible, bit 1 influences children's alpha, bit 2 location adjust.
                // Checked against every retail MKWii layout (almost every pane is 0x01, hidden ones 0x00).
                pane.visible = (data.u8(paneStructOffset) & 0x01) != 0
                pane.translation = Vec3(data, at: paneStructOffset + 0x1C)
                pane.rotation = Vec3(data, at: paneStructOffset + 0x28)
                pane.scale = Vec2(data, at: paneStructOffset + 0x34)
                pane.width = data.beFloat32(paneStructOffset + 0x3C)
                pane.height = data.beFloat32(paneStructOffset + 0x40)
                pane.origin = data.u8(paneStructOffset + 1)
                pane.alpha = data.u8(paneStructOffset + 2)
                pane.influencesChildAlpha = (data.u8(paneStructOffset) & 0x02) != 0
                // Type-specific data after the 0x4C-byte pane header (offsets from the section start).
                switch magic {
                case "pic1" where offset + 0x5E <= data.count:
                    let alphas = (0..<4).map { Int(data.u8(offset + 0x4C + $0 * 4 + 3)) }
                    pane.vertexAlpha = UInt8(alphas.reduce(0, +) / 4)
                    pane.materialIndex = Int(data.be16(offset + 0x5C))
                    if data.u8(offset + 0x5E) > 0, offset + 0x80 <= data.count {
                        let uv = (0..<8).map { data.beFloat32(offset + 0x60 + $0 * 4) }
                        let s = [uv[0], uv[2], uv[4], uv[6]], t = [uv[1], uv[3], uv[5], uv[7]]
                        pane.texCoordBounds = (s.min()!, t.min()!, s.max()!, t.max()!)
                    }
                case "txt1" where offset + 0x74 <= data.count:
                    let strBytes = Int(data.be16(offset + 0x4E))
                    pane.materialIndex = Int(data.be16(offset + 0x50))
                    pane.textPosition = data.u8(offset + 0x54)
                    let textOffset = offset + Int(data.be32(offset + 0x58))
                    pane.textColor = (data.u8(offset + 0x5C), data.u8(offset + 0x5D), data.u8(offset + 0x5E), data.u8(offset + 0x5F))
                    pane.fontSize = Vec2(x: data.beFloat32(offset + 0x64), y: data.beFloat32(offset + 0x68))
                    if strBytes > 0, textOffset + strBytes <= data.count {
                        let raw = data.subdata(in: (data.startIndex + textOffset)..<(data.startIndex + textOffset + strBytes))
                        pane.text = String(data: raw, encoding: .utf16BigEndian)?.replacingOccurrences(of: "\0", with: "")
                    }
                case "wnd1" where offset + 0x64 <= data.count:
                    let content = offset + Int(data.be32(offset + 0x60))
                    if content + 0x12 <= data.count {
                        pane.materialIndex = Int(data.be16(content + 0x10))
                        func avg(_ k: Int) -> UInt8 { UInt8((0..<4).map { Int(data.u8(content + $0 * 4 + k)) }.reduce(0, +) / 4) }
                        pane.windowFill = (avg(0), avg(1), avg(2), avg(3))
                    }
                default: break
                }
                appendPane(pane)

            case "grp1":
                let name = data.asciiString(at: offset + 8, length: 16)
                let count = Int(data.be16(offset + 0x18))
                var paneNames: [String] = []
                for i in 0..<count {
                    let nameOffset = offset + 0x1C + i * 16
                    guard nameOffset + 16 <= data.count else { break }
                    paneNames.append(data.asciiString(at: nameOffset, length: 16))
                }
                doc.groups.append(BRLYTGroup(name: name, paneNames: paneNames))

            default:
                break // usd1, grs1/gre1 (group nesting, flattened here), or unrecognized: skip.
            }

            offset += sectionLength
            if sectionLength == 0 { break } // guard against a corrupt zero-length section looping forever
        }
        return doc
    }

    // MARK: In-place field patches

    func setVisible(_ pane: BRLYTPane, _ visible: Bool) {
        pane.visible = visible
        var flags = rawData.u8(pane.fileOffset)
        if visible { flags |= 0x01 } else { flags &= ~0x01 }
        rawData.setU8(flags, at: pane.fileOffset)
    }

    func setTranslation(_ pane: BRLYTPane, _ v: Vec3) {
        pane.translation = v
        rawData.setBEFloat32(v.x, at: pane.fileOffset + 0x1C)
        rawData.setBEFloat32(v.y, at: pane.fileOffset + 0x20)
        rawData.setBEFloat32(v.z, at: pane.fileOffset + 0x24)
    }

    func setRotation(_ pane: BRLYTPane, _ v: Vec3) {
        pane.rotation = v
        rawData.setBEFloat32(v.x, at: pane.fileOffset + 0x28)
        rawData.setBEFloat32(v.y, at: pane.fileOffset + 0x2C)
        rawData.setBEFloat32(v.z, at: pane.fileOffset + 0x30)
    }

    func setScale(_ pane: BRLYTPane, _ v: Vec2) {
        pane.scale = v
        rawData.setBEFloat32(v.x, at: pane.fileOffset + 0x34)
        rawData.setBEFloat32(v.y, at: pane.fileOffset + 0x38)
    }

    func setSize(_ pane: BRLYTPane, width: Float, height: Float) {
        pane.width = width
        pane.height = height
        rawData.setBEFloat32(width, at: pane.fileOffset + 0x3C)
        rawData.setBEFloat32(height, at: pane.fileOffset + 0x40)
    }

    func serialize() -> Data { rawData }
}
