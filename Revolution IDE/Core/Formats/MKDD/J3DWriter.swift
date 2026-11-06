import Foundation

/// Writes a static GameCube J3D model (`.bmd`, "J3D2bmd3"), a Mario Kart: Double Dash!! course or
/// sky model, from textured, vertex-coloured triangles.
///
/// Laid out exactly as Nintendo's own course and sky models are (measured section by section on
/// the retail disc; `J3DModel` reads it back): INF1, VTX1, EVP1, DRW1, JNT1, SHP1, MAT3, TEX1, each
/// 32-byte aligned and padded with the same "This is padding data to align" filler; one joint,
/// no skinning; one shape per material with indexed float positions, RGBA8 colours and float UVs,
/// drawn as triangle lists. Every material is a copy of a retail sky material's record with its
/// texture, culling and transparency set, sharing the retail tables (channels, swap modes, fog
/// off, NBT scale, indirect stages off); its single TEV stage is texture x vertex colour (or vertex
/// colour alone when untextured). Double Dash's own course shading.
nonisolated enum J3DWriter {
    struct Texture {
        var name: String
        var format: GXTextureFormat
        var width: Int
        var height: Int
        /// Pixel data in `format`, every mip level back to back.
        var encoded: Data
        var mipCount = 1
        /// GX wrap: 0 clamp, 1 repeat, 2 mirror.
        var wrapS: UInt8 = 1
        var wrapT: UInt8 = 1
        var hasAlpha = false
    }

    enum Transparency { case opaque, alphaTest, translucent }

    struct Material {
        var name: String
        var texture: Int?
        /// GX cull: 0 none, 1 front, 2 back.
        var cull: UInt32 = 2
        var transparency: Transparency = .opaque
        /// A texture animation (BTK) moves this material's texture: as retail animated materials
        /// do, its texgen reads texture matrix 0, which gets its own entry (identity until animated).
        var animated = false
    }

    struct Vertex: Hashable {
        var position: Vec3
        var color: [UInt8] = [255, 255, 255, 255]
        var uv: Vec2?
        static func == (a: Vertex, b: Vertex) -> Bool { a.position == b.position && a.color == b.color && a.uv == b.uv }
        func hash(into h: inout Hasher) { h.combine(position.x); h.combine(position.y); h.combine(position.z); h.combine(color) }
    }

    struct Triangle { var v: (Vertex, Vertex, Vertex); var material: Int }

    static let maxIndex = 0xFFFF

    static func bmd(triangles: [Triangle], materials: [Material], textures: [Texture], jointName: String = "world_root") throws -> Data {
        guard !materials.isEmpty else { throw WSError.badStructure("A J3D model needs at least one material.") }
        // Shapes: one per material that draws anything, in material order.
        let used = materials.indices.filter { m in triangles.contains { $0.material == m } }
        guard !used.isEmpty else { throw WSError.badStructure("A J3D model needs at least one triangle.") }

        // MARK: Vertex arrays (deduplicated)
        var positions: [Vec3] = [], colors: [[UInt8]] = [], uvs: [Vec2] = []
        var posIndex: [SIMD3<Float>: Int] = [:], colorIndex: [[UInt8]: Int] = [:], uvIndex: [SIMD2<Float>: Int] = [:]
        func pi(_ p: Vec3) -> Int {
            let k = SIMD3(p.x, p.y, p.z)
            if let i = posIndex[k] { return i }
            posIndex[k] = positions.count; positions.append(p); return positions.count - 1
        }
        func ci(_ c: [UInt8]) -> Int {
            if let i = colorIndex[c] { return i }
            colorIndex[c] = colors.count; colors.append(c); return colors.count - 1
        }
        func ui(_ t: Vec2) -> Int {
            let k = SIMD2(t.x, t.y)
            if let i = uvIndex[k] { return i }
            uvIndex[k] = uvs.count; uvs.append(t); return uvs.count - 1
        }
        struct ShapeData { var material: Int; var textured: Bool; var corners: [(Int, Int, Int)]; var lo: Vec3; var hi: Vec3 }
        var shapes: [ShapeData] = []
        for m in used {
            let textured = materials[m].texture != nil
            var corners: [(Int, Int, Int)] = []
            var lo = Vec3(x: .infinity, y: .infinity, z: .infinity), hi = Vec3(x: -.infinity, y: -.infinity, z: -.infinity)
            for t in triangles where t.material == m {
                for v in [t.v.0, t.v.1, t.v.2] {
                    corners.append((pi(v.position), ci(v.color), textured ? ui(v.uv ?? Vec2()) : 0))
                    lo = Vec3(x: min(lo.x, v.position.x), y: min(lo.y, v.position.y), z: min(lo.z, v.position.z))
                    hi = Vec3(x: max(hi.x, v.position.x), y: max(hi.y, v.position.y), z: max(hi.z, v.position.z))
                }
            }
            shapes.append(ShapeData(material: m, textured: textured, corners: corners, lo: lo, hi: hi))
        }
        guard positions.count <= maxIndex + 1, colors.count <= maxIndex + 1, uvs.count <= maxIndex + 1 else {
            throw WSError.badStructure("The model has \(positions.count) distinct positions, \(colors.count) colours and \(uvs.count) UVs; a J3D model indexes each with 16 bits, so at most 65536. Simplify it.")
        }
        let modelLo = shapes.dropFirst().reduce(shapes[0].lo) { Vec3(x: min($0.x, $1.lo.x), y: min($0.y, $1.lo.y), z: min($0.z, $1.lo.z)) }
        let modelHi = shapes.dropFirst().reduce(shapes[0].hi) { Vec3(x: max($0.x, $1.hi.x), y: max($0.y, $1.hi.y), z: max($0.z, $1.hi.z)) }

        var sections: [Data] = []
        sections.append(inf1(shapeMaterials: shapes.map(\.material), vertexCount: positions.count))
        sections.append(vtx1(positions: positions, colors: colors, uvs: uvs))
        sections.append(evp1())
        sections.append(drw1())
        sections.append(jnt1(name: jointName, lo: modelLo, hi: modelHi))
        sections.append(shp1(shapes: shapes.map { ($0.textured, $0.corners, $0.lo, $0.hi) }))
        sections.append(try mat3(materials: materials, textureCount: textures.count))
        sections.append(tex1(textures))

        var out = Data("J3D2bmd3".utf8)
        out.append(be32(UInt32(0x20 + sections.reduce(0) { $0 + $1.count })))
        out.append(be32(UInt32(sections.count)))
        out.append(Data("SVR3".utf8))
        out.append(Data(repeating: 0xFF, count: 12))
        sections.forEach { out.append($0) }
        return out
    }

    // MARK: Sections

    /// Scene graph: joint 0, then each shape under its material, nested one level per pair as
    /// retail does, closed with two "up" nodes per shape.
    private static func inf1(shapeMaterials: [Int], vertexCount: Int) -> Data {
        var nodes = Data()
        func node(_ type: UInt16, _ index: Int) { nodes.append(be16(type)); nodes.append(be16(UInt16(index))) }
        node(0x10, 0); node(0x01, 0)
        for (s, m) in shapeMaterials.enumerated() {
            if s > 0 { node(0x01, 0) }
            node(0x11, m); node(0x01, 0); node(0x12, s)
        }
        for _ in 0..<(2 * shapeMaterials.count) { node(0x02, 0) }
        node(0x00, 0)
        var d = Data(), body = Data()
        body.append(be16(0)); body.append(be16(0xFFFF))
        body.append(be32(UInt32(shapeMaterials.count))) // packets: one per shape
        body.append(be32(UInt32(vertexCount)))
        body.append(be32(0x18))
        body.append(nodes)
        d = section("INF1", body)
        return d
    }

    private static func vtx1(positions: [Vec3], colors: [[UInt8]], uvs: [Vec2]) -> Data {
        // Format table at 0x40: position (XYZ float), colour 0 (RGBA8), tex 0 (ST float), end.
        var formats = Data()
        func fmt(_ attr: UInt32, _ comps: UInt32, _ type: UInt32) {
            formats.append(be32(attr)); formats.append(be32(comps)); formats.append(be32(type)); formats.append(Data([0, 0xFF, 0xFF, 0xFF]))
        }
        fmt(9, 1, 4); fmt(11, 1, 5)
        if !uvs.isEmpty { fmt(13, 1, 4) }
        fmt(0xFF, 1, 0)
        var arrays = Data()
        var offsets = [UInt32](repeating: 0, count: 13)
        let tableEnd = 0x40 + formats.count
        var cursor = align32(tableEnd)
        func add(_ slot: Int, _ data: Data) {
            offsets[slot] = UInt32(cursor)
            var padded = data
            pad(&padded, base: cursor)
            arrays.append(padded)
            cursor += padded.count
        }
        add(0, positions.reduce(into: Data()) { $0.append(f32($1.x)); $0.append(f32($1.y)); $0.append(f32($1.z)) })
        add(3, colors.reduce(into: Data()) { $0.append(contentsOf: $1) })
        if !uvs.isEmpty { add(5, uvs.reduce(into: Data()) { $0.append(f32($1.x)); $0.append(f32($1.y)) }) }

        // Header (8) + format-table offset + 13 array offsets = 0x40, where the format table starts.
        var body = Data()
        body.append(be32(0x40))
        offsets.forEach { body.append(be32($0)) }
        body.append(formats)
        body.append(paddingBytes(align32(tableEnd) - 8 - body.count, from: 0))
        body.append(arrays)
        return section("VTX1", body)
    }

    private static func evp1() -> Data {
        var body = Data()
        body.append(be16(0)); body.append(be16(0xFFFF))
        for _ in 0..<4 { body.append(be32(0)) }
        return section("EVP1", body)
    }

    /// One draw matrix, joint 0, unweighted.
    private static func drw1() -> Data {
        var body = Data()
        body.append(be16(1)); body.append(be16(0xFFFF))
        body.append(be32(0x14)); body.append(be32(0x16))
        body.append(0) // not weighted
        body.append(paddingBytes(1, from: 0))
        body.append(be16(0)) // joint 0
        return section("DRW1", body)
    }

    private static func jnt1(name: String, lo: Vec3, hi: Vec3) -> Data {
        var body = Data()
        body.append(be16(1)); body.append(be16(0xFFFF))
        body.append(be32(0x18)); body.append(be32(0x58)); body.append(be32(0x5C))
        // Joint: flags 0, no inherited scale, unit scale, no rotation, origin.
        body.append(Data([0, 0, 0, 0xFF]))
        for _ in 0..<3 { body.append(f32(1)) }
        for _ in 0..<3 { body.append(be16(0)) }
        body.append(be16(0xFFFF))
        for _ in 0..<3 { body.append(f32(0)) }
        body.append(f32(radius(lo, hi)))
        for v in [lo.x, lo.y, lo.z, hi.x, hi.y, hi.z] { body.append(f32(v)) }
        body.append(be16(0)) // remap
        body.append(paddingBytes(2, from: 0))
        body.append(nameTable([name]))
        return section("JNT1", body)
    }

    private static func shp1(shapes: [(textured: Bool, corners: [(Int, Int, Int)], lo: Vec3, hi: Vec3)]) -> Data {
        let count = shapes.count
        // Two attribute lists: textured (pos, colour, tex0) at 0, untextured (pos, colour) at 0x20.
        var attribs = Data()
        for (attr, type) in [(9, 3), (11, 3), (13, 3), (0xFF, 0)] { attribs.append(be32(UInt32(attr))); attribs.append(be32(UInt32(type))) }
        for (attr, type) in [(9, 3), (11, 3), (0xFF, 0), (0, 0)] { attribs.append(be32(UInt32(attr))); attribs.append(be32(UInt32(type))) }

        // Primitive data: one packet per shape, triangle lists of u16 indices, each packet padded to 32.
        var prims = Data()
        var packets: [(size: Int, offset: Int)] = []
        for s in shapes {
            var p = Data()
            var k = 0
            while k < s.corners.count {
                let n = min(0xFFFF / 3 * 3, s.corners.count - k)
                p.append(0x90); p.append(be16(UInt16(n)))
                for c in s.corners[k..<(k + n)] {
                    p.append(be16(UInt16(c.0))); p.append(be16(UInt16(c.1)))
                    if s.textured { p.append(be16(UInt16(c.2))) }
                }
                k += n
            }
            while p.count % 32 != 0 { p.append(0) }
            packets.append((p.count, prims.count))
            prims.append(p)
        }

        var off = 0x2C
        let initOfs = off; off += count * 0x28
        let remapOfs = off; off = align32(off + count * 2)
        let attribOfs = off; off = align32(off + attribs.count)
        let mtxTableOfs = off; off = align32(off + count * 2)
        let primOfs = off; off += prims.count
        let mtxDataOfs = off; off += count * 8
        let packetOfs = off; off += count * 8

        var body = Data()
        body.append(be16(UInt16(count))); body.append(be16(0xFFFF))
        for o in [initOfs, remapOfs, 0, attribOfs, mtxTableOfs, primOfs, mtxDataOfs, packetOfs] { body.append(be32(UInt32(o))) }
        func padTo(_ target: Int) { body.append(paddingBytes(target - (8 + body.count), from: 8 + body.count)) }
        for (i, s) in shapes.enumerated() {
            body.append(Data([0, 0xFF])); body.append(be16(1))
            body.append(be16(s.textured ? 0 : 0x20))
            body.append(be16(UInt16(i))); body.append(be16(UInt16(i))); body.append(be16(0xFFFF))
            body.append(f32(radius(s.lo, s.hi)))
            for v in [s.lo.x, s.lo.y, s.lo.z, s.hi.x, s.hi.y, s.hi.z] { body.append(f32(v)) }
        }
        for i in 0..<count { body.append(be16(UInt16(i))) }
        padTo(attribOfs); body.append(attribs)
        padTo(mtxTableOfs); for _ in 0..<count { body.append(be16(0)) }
        padTo(primOfs); body.append(prims)
        for i in 0..<count { body.append(be16(0)); body.append(be16(1)); body.append(be32(UInt32(i))) }
        for p in packets { body.append(be32(UInt32(p.size))); body.append(be32(UInt32(p.offset))) }
        return section("SHP1", body)
    }

    // MARK: MAT3

    /// A retail sky material's 0x14C record: every table index the game reads, pointing at the
    /// shared entries `mat3` writes in the same positions retail has them.
    private static let retailMaterial: [UInt8] = hexBytes("""
    01 01 00 00 00 01 00 00 00 00 00 00 00 00 00 00 00 01 00 02 00 00 00 01 FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF
    00 00 FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF 00 00 FF FF FF FF FF FF
    FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF
    FF FF FF FF FF FF FF FF FF FF FF FF 00 00 FF FF FF FF FF FF FF FF FF FF FF FF FF FF 00 00 00 01 00 01 00 01 0C 0C 0C 0C
    0C 0C 0C 0C 0C 0C 0C 0C 0C 0C 0C 0C 1C 1C 1C 1C 1C 1C 1C 1C 1C 1C 1C 1C 1C 1C 1C 1C 00 00 FF FF FF FF FF FF FF FF FF FF
    FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF 00 00 00 00 00 00 00 01 00 00 FF FF FF FF FF FF FF FF FF FF
    FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF 00 00 FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF
    FF FF FF FF FF FF FF FF FF FF FF FF 00 00 00 00 00 00 00 00 FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF
    FF FF FF FF 00 00 00 00 00 00 00 00
    """)

    /// A retail material's indirect-texturing record with indirect texturing off (0x138 bytes).
    private static let retailIndirectOff: [UInt8] = hexBytes("""
    00 00 FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF 3F 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 3F 00 00 00
    00 00 00 00 01 FF FF FF 3F 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 3F 00 00 00 00 00 00 00 01 FF FF FF 3F 00 00 00
    00 00 00 00 00 00 00 00 00 00 00 00 3F 00 00 00 00 00 00 00 01 FF FF FF 00 00 FF FF 00 00 FF FF 00 00 FF FF 00 00 FF FF
    00 00 00 00 00 00 00 00 00 FF FF FF 00 00 00 00 00 00 00 00 00 FF FF FF 00 00 00 00 00 00 00 00 00 FF FF FF 00 00 00 00
    00 00 00 00 00 FF FF FF 00 00 00 00 00 00 00 00 00 FF FF FF 00 00 00 00 00 00 00 00 00 FF FF FF 00 00 00 00 00 00 00 00
    00 FF FF FF 00 00 00 00 00 00 00 00 00 FF FF FF 00 00 00 00 00 00 00 00 00 FF FF FF 00 00 00 00 00 00 00 00 00 FF FF FF
    00 00 00 00 00 00 00 00 00 FF FF FF 00 00 00 00 00 00 00 00 00 FF FF FF 00 00 00 00 00 00 00 00 00 FF FF FF 00 00 00 00
    00 00 00 00 00 FF FF FF 00 00 00 00 00 00 00 00 00 FF FF FF 00 00 00 00 00 00 00 00 00 FF FF FF
    """)

    private static func mat3(materials: [Material], textureCount: Int) throws -> Data {
        precondition(retailMaterial.count == 0x14C && retailIndirectOff.count == 0x138)
        let n = materials.count
        // Tables, retail's entries first, so a retail index means what it does there; the
        // transparency/culling variants follow.
        let cullTable: [UInt32] = [2, 1, 0]
        let texGenCounts: [UInt8] = [1, 0]
        let stageCounts: [UInt8] = [1]
        let zModes: [[UInt8]] = [[1, 3, 1, 0xFF], [1, 3, 0, 0xFF]] // depth write on / off (translucent)
        let alphaComps: [[UInt8]] = [[7, 0, 1, 7, 0, 0xFF, 0xFF, 0xFF], [6, 0x80, 0, 3, 0xFF, 0xFF, 0xFF, 0xFF]]
        let blends: [[UInt8]] = [[0, 1, 0, 3], [1, 4, 5, 3]]
        let zCompLocs: [UInt8] = [0, 1] // 0: depth test after texturing (alpha-tested), 1: before
        // Stage 0: texture x vertex colour; stage 1: vertex colour alone.
        let stages: [[UInt8]] = [hexBytes("FF 0F 08 0A 0F 00 00 00 01 00 07 04 05 07 00 00 00 01 00 FF"),
                                 hexBytes("FF 0F 0F 0F 0A 00 00 00 01 00 07 07 07 05 00 00 00 01 00 FF")]
        let orders: [[UInt8]] = [[0, 0, 4, 0xFF], [0xFF, 0xFF, 4, 0xFF]]

        var entries = Data(), animatedCount = 0
        for m in materials {
            var e = retailMaterial
            let textured = m.texture != nil
            guard m.texture.map({ $0 >= 0 && $0 < textureCount }) ?? true else { throw WSError.badStructure("Material \(m.name) uses a texture that isn't in the model.") }
            e[0x00] = m.transparency == .opaque ? 1 : (m.transparency == .alphaTest ? 2 : 4)
            e[0x01] = UInt8(cullTable.firstIndex(of: m.cull) ?? 0)
            e[0x03] = textured ? 0 : 1
            e[0x05] = m.transparency == .alphaTest ? 0 : 1
            e[0x06] = m.transparency == .translucent ? 1 : 0
            put16(&e, 0x28, textured ? (m.animated ? 1 : 0) : 0xFFFF)        // texgen 0 (1: through texture matrix 0)
            if textured, m.animated {
                put16(&e, 0x48, UInt16(1 + animatedCount))                    // texture matrix 0: this material's own
                animatedCount += 1
            }
            put16(&e, 0x84, m.texture.map { UInt16($0) } ?? 0xFFFF)          // texture 0
            put16(&e, 0xBC, textured ? 0 : 1)                                // TEV order 0
            put16(&e, 0xE4, textured ? 0 : 1)                                // TEV stage 0
            put16(&e, 0x146, m.transparency == .alphaTest ? 1 : 0)           // alpha compare
            put16(&e, 0x148, m.transparency == .translucent ? 1 : 0)         // blend
            entries.append(contentsOf: e)
        }

        // Each table: bytes, plus whether it's present (Light/TexCoord2/TexMatrix2 aren't).
        var tables: [Data?] = []
        tables.append(entries)                                                        // 0 material data
        tables.append((0..<n).reduce(into: Data()) { $0.append(be16(UInt16($1))) })   // 1 index (remap)
        tables.append(nameTable(materials.map(\.name)))                                // 2 names
        tables.append(Data((0..<n).flatMap { _ in retailIndirectOff }))               // 3 indirect
        tables.append(cullTable.reduce(into: Data()) { $0.append(be32($1)) })         // 4 cull
        tables.append(Data([0xFF, 0xFF, 0xFF, 0xFF]))                                 // 5 material colour
        tables.append(Data([1]))                                                      // 6 channel count
        tables.append(Data(hexBytes("00 01 00 02 01 00 FF FF 01 00 00 01 00 00 FF FF 00 00 00 00 02 00 FF FF"))) // 7 channels
        tables.append(Data([0x80, 0x80, 0x80, 0x32, 0, 0, 0, 0]))                    // 8 ambient
        tables.append(Data())                                                         // 9 lights (none)
        tables.append(Data(texGenCounts))                                             // 10 texgen count
        tables.append(Data([1, 4, 0x3C, 0xFF, 1, 4, 0x1E, 0xFF]))                     // 11 texgen: 2x4 from TEX0, identity / texture matrix 0
        tables.append(nil)                                                            // 12 post texgen
        let identityMatrix = Data(hexBytes("01 00 FF FF 3F 00 00 00 3F 00 00 00 3F 00 00 00 3F 80 00 00 3F 80 00 00 00 00 FF FF 00 00 00 00 00 00 00 00")) + identity4x4()
        tables.append((0...animatedCount).reduce(into: Data()) { d, _ in d.append(identityMatrix) }) // 13 tex matrices: unused identity, then one per animated material
        tables.append(nil)                                                            // 14 post tex matrix
        tables.append((0..<max(1, textureCount)).reduce(into: Data()) { $0.append(be16(UInt16($1))) }) // 15 texture numbers
        tables.append(Data(orders.flatMap { $0 }))                                    // 16 TEV orders
        tables.append(Data(hexBytes("00 FF 00 FF 00 FF 00 FF 00 00 00 00 00 00 00 00"))) // 17 TEV colours
        tables.append(Data([0xE0, 0xE9, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]))        // 18 konst colours
        tables.append(Data(stageCounts))                                              // 19 stage count
        tables.append(Data(stages.flatMap { $0 }))                                    // 20 stages
        tables.append(Data([0, 0, 0xFF, 0xFF]))                                       // 21 swap modes
        tables.append(Data([0, 1, 2, 3]))                                             // 22 swap tables
        tables.append(Data(repeating: 0, count: 20) + Data([0xFF, 0xFF, 0xFF, 0xFF]) + Data(repeating: 0, count: 20)) // 23 fog off
        tables.append(Data(alphaComps.flatMap { $0 }))                                // 24 alpha compare
        tables.append(Data(blends.flatMap { $0 }))                                    // 25 blend
        tables.append(Data(zModes.flatMap { $0 }))                                    // 26 z mode
        tables.append(Data(zCompLocs))                                                // 27 z comp loc
        tables.append(Data([0, 1]))                                                   // 28 dither
        tables.append(Data(hexBytes("00 FF FF FF 3F 80 00 00 3F 80 00 00 3F 80 00 00"))) // 29 NBT scale

        // Laid out after the 0x84-byte header; each table padded to 4 (retail pads the small
        // ones with the filler string), material data first at 0x84 as retail.
        var body = Data()
        var offsets: [UInt32] = []
        var cursor = 0x84
        var blobs = Data()
        for t in tables {
            guard let t else { offsets.append(0); continue }
            offsets.append(UInt32(cursor))
            var padded = t
            padded.append(paddingBytes((4 - (cursor + t.count) % 4) % 4, from: 0))
            blobs.append(padded)
            cursor += padded.count
        }
        body.append(be16(UInt16(n))); body.append(be16(0xFFFF))
        offsets.forEach { body.append(be32($0)) }
        body.append(blobs)
        return section("MAT3", body)
    }

    // MARK: TEX1

    /// A texture's 0x20-byte header (the same in TEX1 and a standalone .bti), its data `dataOffset`
    /// bytes from the header's own start.
    static func textureHeader(_ t: Texture, dataOffset: Int) -> Data {
        var h = Data()
        h.append(UInt8(t.format.rawValue)); h.append(t.hasAlpha ? 1 : 0)
        h.append(be16(UInt16(t.width))); h.append(be16(UInt16(t.height)))
        h.append(t.wrapS); h.append(t.wrapT)
        // No palette; retail still points the palette offset at the data.
        h.append(0); h.append(0); h.append(be16(0)); h.append(be32(UInt32(dataOffset)))
        let mips = max(1, t.mipCount)
        h.append(mips > 1 ? 1 : 0); h.append(0); h.append(0); h.append(0)
        h.append(mips > 1 ? 5 : 1); h.append(1)                          // min/mag filter
        h.append(0); h.append(UInt8(clamping: (mips - 1) * 8))           // min/max LOD
        h.append(UInt8(mips)); h.append(0); h.append(be16(0))            // image count, LOD bias
        h.append(be32(UInt32(dataOffset)))
        return h
    }

    /// A standalone GameCube texture file (.bti), the header, then the data.
    static func bti(_ t: Texture) -> Data {
        var d = textureHeader(t, dataOffset: 0x20)
        d.append(t.encoded)
        return d
    }

    private static func tex1(_ textures: [Texture]) -> Data {
        let headersStart = 0x20
        var headers = Data(), data = Data()
        let dataStart = headersStart + textures.count * 0x20
        for (i, t) in textures.enumerated() {
            let headerAt = headersStart + i * 0x20
            headers.append(textureHeader(t, dataOffset: dataStart + data.count - headerAt))
            var d = t.encoded
            while d.count % 32 != 0 { d.append(0) }
            data.append(d)
        }
        var body = Data()
        body.append(be16(UInt16(textures.count))); body.append(be16(0xFFFF))
        let namesAt = dataStart + data.count
        body.append(be32(UInt32(headersStart))); body.append(be32(UInt32(namesAt)))
        body.append(paddingBytes(headersStart - 8 - body.count, from: 8 + body.count))
        body.append(headers); body.append(data)
        body.append(nameTable(textures.map(\.name)))
        return section("TEX1", body)
    }

    // MARK: Helpers

    /// J3D name table: count, 0xFFFF, (hash, offset) per name, then the NUL-terminated names.
    static func nameTable(_ names: [String]) -> Data {
        var d = Data()
        d.append(be16(UInt16(names.count))); d.append(be16(0xFFFF))
        var strings = Data()
        let base = 4 + names.count * 4
        for name in names {
            d.append(be16(hash(name))); d.append(be16(UInt16(base + strings.count)))
            strings.append(contentsOf: Array(name.utf8) + [0])
        }
        d.append(strings)
        return d
    }

    /// The J3D/RARC name hash.
    static func hash(_ name: String) -> UInt16 {
        var h: UInt16 = 0
        for c in name.utf8 { h = h &* 3 &+ UInt16(c) }
        return h
    }

    static let filler = Array("This is padding data to align".utf8)
    static func paddingBytes(_ count: Int, from _: Int) -> Data { Data((0..<max(0, count)).map { filler[$0 % filler.count] }) }

    /// Section with its magic and size, padded to 32 bytes with the filler string.
    static func section(_ magic: String, _ body: Data) -> Data {
        var d = Data(magic.utf8)
        d.append(be32(0))
        d.append(body)
        d.append(paddingBytes(align32(d.count) - d.count, from: 0))
        d.replaceSubrange(4..<8, with: be32(UInt32(d.count)))
        return d
    }

    private static func pad(_ d: inout Data, base: Int) {
        d.append(paddingBytes(align32(base + d.count) - base - d.count, from: 0))
    }

    static func align32(_ n: Int) -> Int { (n + 31) & ~31 }
    private static func radius(_ lo: Vec3, _ hi: Vec3) -> Float {
        let m = Vec3(x: max(abs(lo.x), abs(hi.x)), y: max(abs(lo.y), abs(hi.y)), z: max(abs(lo.z), abs(hi.z)))
        return (m.x * m.x + m.y * m.y + m.z * m.z).squareRoot()
    }
    private static func identity4x4() -> Data {
        var d = Data()
        for r in 0..<4 { for c in 0..<4 { d.append(f32(r == c ? 1 : 0)) } }
        return d
    }
    private static func put16(_ e: inout [UInt8], _ o: Int, _ v: UInt16) { e[o] = UInt8(v >> 8); e[o + 1] = UInt8(v & 0xFF) }
    static func hexBytes(_ s: String) -> [UInt8] { s.split(whereSeparator: \.isWhitespace).map { UInt8($0, radix: 16)! } }
    private static func be16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
    private static func be32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
    private static func f32(_ v: Float) -> Data { be32(v.bitPattern) }
}
