import Foundation
import simd

/// Reads a GameCube J3D model (`.bmd`/`.bdl`, "J3D2bmd3"/"J3D2bdl4"), the format Mario Kart:
/// Double Dash!! course and sky models use, into triangles (positions, vertex colours, every
/// texture-coordinate set) plus each material's full GX state: textures, texgens and texture
/// matrices, colour channels, TEV stages and registers, alpha test, blending and depth. Section
/// layouts follow the J3D format as the community documents it (noclip's J3DLoader, SuperBMD)
/// and were checked against every course and sky model on a retail disc.
///
/// Skinned models are posed in their bind pose (joint-local vertices moved by their joint; envelope
/// vertices are stored in that pose already). Animations live in `J3DAnimation`.
nonisolated enum J3DModel {
    struct Texture {
        let name: String
        let format: GXTextureFormat
        let width: Int
        let height: Int
        /// Pixel data in `format`, for a lossless copy, or nil for a palette format, which is
        /// supplied decoded in `rgba` instead.
        let encoded: Data?
        let rgba: [UInt8]?
        /// GX wrap modes: 0 clamp, 1 repeat, 2 mirror.
        let wrapS: UInt8
        let wrapT: UInt8

        /// RGBA8 pixels, GX-style: intensity formats carry their intensity as alpha too.
        func decoded() -> [UInt8]? {
            if let rgba { return rgba }
            guard let encoded, var out = TextureCodec.decode(data: encoded, offset: 0, width: width, height: height, format: format) else { return nil }
            if format == .i4 || format == .i8 { for i in stride(from: 0, to: out.count, by: 4) { out[i + 3] = out[i] } }
            return out
        }
    }

    struct Vertex {
        var position: Vec3
        var color: (UInt8, UInt8, UInt8, UInt8) = (255, 255, 255, 255)
        /// Texture coordinate sets 0-7 (GX convention: V runs down the image).
        var uv: [Vec2?] = Array(repeating: nil, count: 8)
    }

    struct Triangle {
        var v: (Vertex, Vertex, Vertex)
        var material: Int
    }

    /// One TEV combiner half: out = (d (op) lerp(a, b, c) + bias) * scale.
    struct Combiner { var a, b, c, d, op, bias, scale, clamp, reg: UInt8 }
    struct Stage {
        var texCoord: UInt8, texMap: UInt8, channel: UInt8
        var color: Combiner, alpha: Combiner
        var kColorSel: UInt8, kAlphaSel: UInt8
    }
    struct TexGen { var type: UInt8, source: UInt8, matrix: UInt8 }
    struct TexMatrix { var info: UInt8; var center: Vec3; var scale: Vec2; var rotation: Float; var translation: Vec2 }
    struct Channel { var lighting: Bool; var fromVertex: Bool }

    struct Material {
        var name: String
        /// 1 opaque, 2 alpha-tested edge, 4 translucent.
        var mode: UInt8 = 1
        /// GX cull mode: 0 none, 1 front, 2 back, 3 all.
        var cull: UInt32 = 2
        /// TEX1 index per texture map slot.
        var textures: [Int?] = Array(repeating: nil, count: 8)
        var texGens: [TexGen] = []
        var texMatrices: [TexMatrix?] = Array(repeating: nil, count: 10)
        var colorChannel = Channel(lighting: false, fromVertex: true)
        var alphaChannel = Channel(lighting: false, fromVertex: true)
        var matColor: (UInt8, UInt8, UInt8, UInt8) = (255, 255, 255, 255)
        var stages: [Stage] = []
        var kColors: [(Float, Float, Float, Float)] = Array(repeating: (1, 1, 1, 1), count: 4)
        /// TEV colour registers C0, C1, C2, then PREV's initial value (checked on Mario Circuit,
        /// whose road adds C0 = black; the other order made it white).
        var tevColors: [(Float, Float, Float, Float)] = Array(repeating: (0, 0, 0, 0), count: 4)
        /// comp0, ref0, op, comp1, ref1 (GX compare functions; 7 = always).
        var alphaTest: (UInt8, UInt8, UInt8, UInt8, UInt8) = (7, 0, 0, 7, 0)
        /// type (0 none, 1 blend, 2 logic, 3 subtract), source factor, destination factor.
        var blend: (UInt8, UInt8, UInt8) = (0, 1, 0)
        /// enable, compare function, update.
        var zMode: (UInt8, UInt8, UInt8) = (1, 3, 1)
    }

    struct Model {
        var triangles: [Triangle]
        var materials: [Material]
        var textures: [Texture]
        /// Each joint's bind-pose world matrix.
        var joints: [simd_float4x4] = []
    }

    /// One 0x20-byte J3D texture header at `h` (a TEX1 entry, or a whole `.bti` at 0); its
    /// palette and image offsets are relative to the header itself.
    static func texture(_ d: Data, header h: Int, name: String) -> Texture {
        let width = Int(d.be16(h + 2)), height = Int(d.be16(h + 4))
        let wrapS = d.u8(h + 6), wrapT = d.u8(h + 7)
        let dataStart = h + Int(d.be32(h + 0x1C))
        let format = GXTextureFormat(rawValue: UInt32(d.u8(h))) ?? .rgba32
        if [.ci4, .ci8, .ci14x2].contains(format) {
            let palFormat = GXPaletteFormat(rawValue: UInt32(d.u8(h + 9))) ?? .rgb5a3
            let palStart = h + Int(d.be32(h + 0x0C))
            let palette = (0..<Int(d.be16(h + 0x0A))).map { TextureCodec.decodePaletteEntry(d.be16(palStart + $0 * 2), format: palFormat) }
            let rgba = TextureCodec.decode(data: d, offset: dataStart, width: width, height: height, format: format, palette: palette)
            return Texture(name: name, format: format, width: width, height: height, encoded: nil, rgba: rgba, wrapS: wrapS, wrapT: wrapT)
        }
        let bits = format == .i4 || format == .cmpr ? 4 : (format == .rgba32 ? 32 : ([.i8, .ia4].contains(format) ? 8 : 16))
        let bw = bits == 4 ? 8 : (bits == 8 ? 8 : 4), bh = bits == 32 || bits == 16 ? 4 : (bits == 4 ? 8 : 4)
        let size = ((width + bw - 1) / bw * bw) * ((height + bh - 1) / bh * bh) * bits / 8
        let encoded = dataStart + size <= d.count ? d.subdata(in: dataStart..<(dataStart + size)) : nil
        return Texture(name: name, format: format, width: width, height: height, encoded: encoded, rgba: nil, wrapS: wrapS, wrapT: wrapT)
    }

    /// A standalone GameCube texture (`.bti`): one texture header at offset 0.
    static func bti(_ data: Data, name: String) throws -> Texture {
        let d = Data(data)
        guard d.count >= 0x20, GXTextureFormat(rawValue: UInt32(d.u8(0))) != nil, d.be16(2) > 0, d.be16(4) > 0,
              Int(d.be32(0x1C)) >= 0x20, Int(d.be32(0x1C)) < d.count else {
            throw WSError.badStructure("Not a BTI texture (bad header).")
        }
        return texture(d, header: 0, name: name)
    }

    static func parse(_ d: Data) throws -> Model {
        let d = Data(d)
        guard d.count >= 0x20, d.asciiString(at: 0, length: 4) == "J3D2" else {
            throw WSError.badStructure("Not a J3D model (missing 'J3D2' magic).")
        }
        var sections: [String: Int] = [:]
        var off = 0x20
        while off + 8 <= d.count {
            let size = Int(d.be32(off + 4))
            guard size >= 8 else { break }
            sections[d.asciiString(at: off, length: 4)] = off
            off += size
        }
        guard let inf = sections["INF1"], let vtx = sections["VTX1"], let shp = sections["SHP1"] else {
            throw WSError.badStructure("J3D model is missing INF1/VTX1/SHP1.")
        }
        func string(_ table: Int, _ i: Int) -> String {
            let s = table + Int(d.be16(table + 4 + i * 4 + 2))
            var e = s
            while e < d.count, d.u8(e) != 0 { e += 1 }
            return String(decoding: d[s..<e], as: UTF8.self)
        }

        // MARK: VTX1, attribute arrays
        struct VertexArray { var comps: Int; var type: Int; var frac: Int; var start: Int; var end: Int }
        var arrays: [Int: VertexArray] = [:]
        let formatTable = vtx + Int(d.be32(vtx + 8))
        let dataOffsets = (0..<13).map { Int(d.be32(vtx + 0x0C + $0 * 4)) }
        let slotForAttr: [Int: Int] = [9: 0, 10: 1, 11: 3, 12: 4, 13: 5, 14: 6, 15: 7, 16: 8, 17: 9, 18: 10, 19: 11, 20: 12]
        var f = formatTable
        while f + 0x10 <= d.count, d.be32(f) != 0xFF {
            let attr = Int(d.be32(f))
            if let slot = slotForAttr[attr], dataOffsets[slot] != 0 {
                let start = vtx + dataOffsets[slot]
                let later = dataOffsets.enumerated().filter { $0.offset > slot && $0.element != 0 }.map { vtx + $0.element }
                let end = later.min() ?? (vtx + Int(d.be32(vtx + 4)))
                arrays[attr] = VertexArray(comps: Int(d.be32(f + 4)), type: Int(d.be32(f + 8)), frac: Int(d.u8(f + 12)), start: start, end: end)
            }
            f += 0x10
        }
        func component(_ a: VertexArray, _ index: Int, _ c: Int, count: Int) -> Float {
            let size = a.type <= 1 ? 1 : (a.type <= 3 ? 2 : 4)
            let o = a.start + (index * count + c) * size
            guard o + size <= a.end else { return 0 }
            let scale = Float(1 << a.frac)
            switch a.type {
            case 0: return Float(d.u8(o)) / scale
            case 1: return Float(Int8(bitPattern: d.u8(o))) / scale
            case 2: return Float(d.be16(o)) / scale
            case 3: return Float(Int16(bitPattern: d.be16(o))) / scale
            default: return d.beFloat32(o)
            }
        }
        func position(_ i: Int) -> Vec3 {
            guard let a = arrays[9] else { return Vec3() }
            let n = a.comps == 0 ? 2 : 3
            return Vec3(x: component(a, i, 0, count: n), y: component(a, i, 1, count: n), z: n == 3 ? component(a, i, 2, count: n) : 0)
        }
        func texcoord(_ attr: Int, _ i: Int) -> Vec2? {
            guard let a = arrays[attr] else { return nil }
            let n = a.comps == 0 ? 1 : 2
            return Vec2(x: component(a, i, 0, count: n), y: n == 2 ? component(a, i, 1, count: n) : 0)
        }
        /// GX colour formats: RGB565, RGB8, RGBX8, RGBA4, RGBA6, RGBA8.
        func color(_ attr: Int, _ i: Int) -> (UInt8, UInt8, UInt8, UInt8) {
            guard let a = arrays[attr] else { return (255, 255, 255, 255) }
            let size = [2, 3, 4, 2, 3, 4][min(5, a.type)]
            let o = a.start + i * size
            guard o + size <= a.end else { return (255, 255, 255, 255) }
            func x4(_ v: UInt16) -> UInt8 { UInt8(v * 17) }
            switch a.type {
            case 0: let v = d.be16(o); return (UInt8((v >> 11) * 255 / 31), UInt8(((v >> 5) & 63) * 255 / 63), UInt8((v & 31) * 255 / 31), 255)
            case 1, 2: return (d.u8(o), d.u8(o + 1), d.u8(o + 2), 255)
            case 3: let v = d.be16(o); return (x4(v >> 12), x4((v >> 8) & 15), x4((v >> 4) & 15), x4(v & 15))
            case 4:
                let v = (UInt32(d.u8(o)) << 16) | (UInt32(d.u8(o + 1)) << 8) | UInt32(d.u8(o + 2))
                func x6(_ s: UInt32) -> UInt8 { UInt8(((v >> s) & 63) * 255 / 63) }
                return (x6(18), x6(12), x6(6), x6(0))
            default: return (d.u8(o), d.u8(o + 1), d.u8(o + 2), d.u8(o + 3))
            }
        }

        // MARK: MAT3
        var materials: [Material] = []
        if let mat = sections["MAT3"] {
            let count = Int(d.be16(mat + 8))
            let table = (0..<30).map { mat + Int(d.be32(mat + 0x0C + $0 * 4)) }
            func idx(_ e: Int, _ o: Int) -> Int? { let v = d.be16(e + o); return v == 0xFFFF ? nil : Int(v) }
            func rgba8(_ o: Int) -> (UInt8, UInt8, UInt8, UInt8) { (d.u8(o), d.u8(o + 1), d.u8(o + 2), d.u8(o + 3)) }
            func s10(_ o: Int) -> (Float, Float, Float, Float) {
                let c = (0..<4).map { Float(Int16(bitPattern: d.be16(o + $0 * 2))) / 255 }
                return (c[0], c[1], c[2], c[3])
            }
            func combiner(_ o: Int) -> Combiner {
                Combiner(a: d.u8(o), b: d.u8(o + 1), c: d.u8(o + 2), d: d.u8(o + 3), op: d.u8(o + 4), bias: d.u8(o + 5),
                         scale: d.u8(o + 6), clamp: d.u8(o + 7), reg: d.u8(o + 8))
            }
            for m in 0..<count {
                let e = table[0] + Int(d.be16(table[1] + m * 2)) * 0x14C
                var material = Material(name: m < Int(d.be16(table[2])) ? string(table[2], m) : "material\(m)")
                material.mode = d.u8(e)
                material.cull = d.be32(table[4] + Int(d.u8(e + 1)) * 4)
                for k in 0..<8 { material.textures[k] = idx(e, 0x84 + k * 2).map { Int(d.be16(table[15] + $0 * 2)) } }
                let texGenCount = Int(d.u8(table[10] + Int(d.u8(e + 3))))
                for k in 0..<min(8, texGenCount) {
                    guard let g = idx(e, 0x28 + k * 2) else { continue }
                    let o = table[11] + g * 4
                    material.texGens.append(TexGen(type: d.u8(o), source: d.u8(o + 1), matrix: d.u8(o + 2)))
                }
                for k in 0..<10 {
                    guard let t = idx(e, 0x48 + k * 2) else { continue }
                    let o = table[13] + t * 0x64
                    material.texMatrices[k] = TexMatrix(info: d.u8(o + 1), center: Vec3(x: d.beFloat32(o + 4), y: d.beFloat32(o + 8), z: d.beFloat32(o + 12)),
                                                        scale: Vec2(x: d.beFloat32(o + 0x10), y: d.beFloat32(o + 0x14)),
                                                        rotation: Float(Int16(bitPattern: d.be16(o + 0x18))) / 0x7FFF * .pi,
                                                        translation: Vec2(x: d.beFloat32(o + 0x1C), y: d.beFloat32(o + 0x20)))
                }
                func channel(_ k: Int) -> Channel? {
                    idx(e, 0x0C + k * 2).map { Channel(lighting: d.u8(table[7] + $0 * 8) != 0, fromVertex: d.u8(table[7] + $0 * 8 + 1) != 0) }
                }
                material.colorChannel = channel(0) ?? material.colorChannel
                material.alphaChannel = channel(1) ?? material.alphaChannel
                if let c = idx(e, 0x08) { material.matColor = rgba8(table[5] + c * 4) }
                for k in 0..<4 {
                    if let c = idx(e, 0x94 + k * 2) { let v = rgba8(table[18] + c * 4); material.kColors[k] = (Float(v.0) / 255, Float(v.1) / 255, Float(v.2) / 255, Float(v.3) / 255) }
                    if let c = idx(e, 0xDC + k * 2) { material.tevColors[k] = s10(table[17] + c * 8) }
                }
                let stageCount = Int(d.u8(table[19] + Int(d.u8(e + 4))))
                for k in 0..<min(16, stageCount) {
                    guard let s = idx(e, 0xE4 + k * 2) else { continue }
                    let o = table[20] + s * 20
                    let order = idx(e, 0xBC + k * 2).map { table[16] + $0 * 4 }
                    material.stages.append(Stage(texCoord: order.map { d.u8($0) } ?? 0xFF, texMap: order.map { d.u8($0 + 1) } ?? 0xFF,
                                                 channel: order.map { d.u8($0 + 2) } ?? 0xFF,
                                                 color: combiner(o + 1), alpha: combiner(o + 10),
                                                 kColorSel: d.u8(e + 0x9C + k), kAlphaSel: d.u8(e + 0xAC + k)))
                }
                if let a = idx(e, 0x146) { let o = table[24] + a * 8; material.alphaTest = (d.u8(o), d.u8(o + 1), d.u8(o + 2), d.u8(o + 3), d.u8(o + 4)) }
                if let b = idx(e, 0x148) { let o = table[25] + b * 4; material.blend = (d.u8(o), d.u8(o + 1), d.u8(o + 2)) }
                let z = table[26] + Int(d.u8(e + 6)) * 4
                material.zMode = (d.u8(z), d.u8(z + 1), d.u8(z + 2))
                materials.append(material)
            }
        }

        // MARK: TEX1
        var textures: [Texture] = []
        if let tex = sections["TEX1"] {
            let count = Int(d.be16(tex + 8))
            let headers = tex + Int(d.be32(tex + 0x0C))
            let names = tex + Int(d.be32(tex + 0x10))
            for i in 0..<count { textures.append(texture(d, header: headers + i * 0x20, name: string(names, i))) }
        }

        // MARK: INF1, which material each shape draws with
        var shapeMaterial: [Int: Int] = [:]
        var materialStack: [Int] = []
        var lastMaterial: Int?
        var jointParent: [Int: Int] = [:]
        var jointStack: [Int?] = []
        var lastJoint: Int?
        var node = inf + Int(d.be32(inf + 0x14))
        while node + 4 <= d.count {
            let type = d.be16(node), index = Int(d.be16(node + 2))
            switch type {
            case 0x00: node = d.count; continue
            case 0x01: materialStack.append(lastMaterial ?? -1); jointStack.append(lastJoint)
            case 0x02: lastMaterial = materialStack.popLast().flatMap { $0 < 0 ? nil : $0 }; lastJoint = jointStack.popLast() ?? nil
            case 0x10: lastJoint = index; if let p = jointStack.last ?? nil { jointParent[index] = p }
            case 0x11: lastMaterial = index
            case 0x12: if let m = lastMaterial { shapeMaterial[index] = m }
            default: break
            }
            node += 4
        }

        // MARK: JNT1/DRW1, bind pose. A draw matrix is a joint's world matrix (its vertices are
        // stored joint-local) or an envelope, whose vertices are stored in model space already.
        // ponytail: scale compensation ignored, no retail Double Dash model seen relying on it.
        var jointWorld: [simd_float4x4] = []
        if let jnt = sections["JNT1"] {
            let entries = jnt + Int(d.be32(jnt + 0x0C)), remapJ = jnt + Int(d.be32(jnt + 0x10))
            let locals = (0..<Int(d.be16(jnt + 8))).map { i -> simd_float4x4 in
                let j = entries + Int(d.be16(remapJ + i * 2)) * 0x40
                func f(_ o: Int) -> Float { d.beFloat32(j + o) }
                func r(_ o: Int) -> Float { Float(Int16(bitPattern: d.be16(j + o))) / 0x7FFF * .pi }
                let (rx, ry, rz) = (r(0x10), r(0x12), r(0x14))
                let mx = simd_float4x4(rows: [[1, 0, 0, 0], [0, cos(rx), -sin(rx), 0], [0, sin(rx), cos(rx), 0], [0, 0, 0, 1]])
                let my = simd_float4x4(rows: [[cos(ry), 0, sin(ry), 0], [0, 1, 0, 0], [-sin(ry), 0, cos(ry), 0], [0, 0, 0, 1]])
                let mz = simd_float4x4(rows: [[cos(rz), -sin(rz), 0, 0], [sin(rz), cos(rz), 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]])
                var t = matrix_identity_float4x4
                t.columns.3 = SIMD4(f(0x18), f(0x1C), f(0x20), 1)
                return t * mz * my * mx * simd_float4x4(diagonal: SIMD4(f(4), f(8), f(12), 1))
            }
            jointWorld = locals
            func world(_ i: Int, _ depth: Int = 0) -> simd_float4x4 {
                guard let p = jointParent[i], p < locals.count, depth < 64 else { return locals[i] }
                return world(p, depth + 1) * locals[i]
            }
            for i in locals.indices { jointWorld[i] = world(i) }
        }
        var drawWeighted: [Bool] = [], drawIndex: [Int] = []
        if let drw = sections["DRW1"] {
            let n = Int(d.be16(drw + 8)), w = drw + Int(d.be32(drw + 0x0C)), x = drw + Int(d.be32(drw + 0x10))
            drawWeighted = (0..<n).map { d.u8(w + $0) != 0 }
            drawIndex = (0..<n).map { Int(d.be16(x + $0 * 2)) }
        }
        func bind(_ p: Vec3, drawMatrix m: Int) -> Vec3 {
            guard m < drawWeighted.count, !drawWeighted[m], drawIndex[m] < jointWorld.count else { return p }
            let v = jointWorld[drawIndex[m]] * SIMD4(p.x, p.y, p.z, 1)
            return Vec3(x: v.x, y: v.y, z: v.z)
        }

        // MARK: SHP1, display lists
        var triangles: [Triangle] = []
        let shapeCount = Int(d.be16(shp + 8))
        let shapeInit = shp + Int(d.be32(shp + 0x0C))
        let remap = shp + Int(d.be32(shp + 0x10))
        let attribTable = shp + Int(d.be32(shp + 0x18))
        let primitiveData = shp + Int(d.be32(shp + 0x20))
        let packetTable = shp + Int(d.be32(shp + 0x28))
        let matrixTable = shp + Int(d.be32(shp + 0x1C)), matrixData = shp + Int(d.be32(shp + 0x24))
        for s in 0..<shapeCount {
            let entry = shapeInit + Int(d.be16(remap + s * 2)) * 0x28
            let packetCount = Int(d.be16(entry + 2))
            var a = attribTable + Int(d.be16(entry + 4))
            let firstMatrixData = Int(d.be16(entry + 6)), firstPacket = Int(d.be16(entry + 8))
            var slots = [Int](repeating: 0, count: 10) // draw matrix per PNMTXIDX slot; 0xFFFF keeps the last packet's
            var attrs: [(attr: Int, type: Int)] = []
            while a + 8 <= d.count, d.be32(a) != 0xFF { attrs.append((Int(d.be32(a)), Int(d.be32(a + 4)))); a += 8 }
            let material = shapeMaterial[s] ?? 0
            for p in 0..<packetCount {
                let loc = packetTable + (firstPacket + p) * 8
                let size = Int(d.be32(loc)), start = primitiveData + Int(d.be32(loc + 4))
                let md = matrixData + (firstMatrixData + p) * 8
                for k in 0..<min(10, Int(d.be16(md + 2))) {
                    let v = d.be16(matrixTable + (Int(d.be32(md + 4)) + k) * 2)
                    if v != 0xFFFF { slots[k] = Int(v) }
                }
                var o = start
                while o + 3 <= start + size {
                    let op = d.u8(o)
                    guard op != 0 else { break }
                    let count = Int(d.be16(o + 1))
                    o += 3
                    var verts: [Vertex] = []
                    for _ in 0..<count {
                        var v = Vertex(position: Vec3())
                        var slot = 0
                        for (attr, type) in attrs {
                            var value = 0
                            switch type {
                            case 1: value = Int(d.u8(o)); o += 1 // direct: only matrix indices, 1 byte
                            case 2: value = Int(d.u8(o)); o += 1
                            case 3: value = Int(d.be16(o)); o += 2
                            default: break
                            }
                            switch attr {
                            case 0: slot = min(9, value / 3)
                            case 9: v.position = position(value)
                            case 11: v.color = color(11, value)
                            case 13...20: v.uv[attr - 13] = texcoord(attr, value)
                            default: break
                            }
                        }
                        v.position = bind(v.position, drawMatrix: slots[slot])
                        verts.append(v)
                    }
                    func tri(_ i: Int, _ j: Int, _ k: Int) {
                        let (a, b, c) = (verts[i], verts[j], verts[k])
                        guard a.position != b.position, b.position != c.position, a.position != c.position else { return } // degenerate strip joins
                        triangles.append(Triangle(v: (a, b, c), material: material))
                    }
                    switch op {
                    case 0x90: for t in stride(from: 0, to: count - 2, by: 3) { tri(t, t + 1, t + 2) }
                    case 0x98: for t in 0..<max(0, count - 2) { t % 2 == 0 ? tri(t, t + 1, t + 2) : tri(t + 1, t, t + 2) }
                    case 0xA0: for t in 1..<max(1, count - 1) { tri(0, t, t + 1) }
                    case 0x80: for q in stride(from: 0, to: count - 3, by: 4) { tri(q, q + 1, q + 2); tri(q, q + 2, q + 3) }
                    default: break // lines/points don't make surfaces
                    }
                }
            }
        }
        if materials.isEmpty { materials = [Material(name: "material")] }
        return Model(triangles: triangles, materials: materials, textures: textures, joints: jointWorld)
    }
}
