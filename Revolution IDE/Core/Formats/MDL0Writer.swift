import Foundation

/// Builds a real, loadable MDL0 model from OBJ-imported triangles: one static mesh per `usemtl`
/// group under one root bone (no skinning), each with its own material, shader and, when the
/// companion `.mtl` gave that material a real `map_Kd` image, its own texture sampler.
///
/// MDL0's material block embeds raw GameCube/Wii GPU (Flipper/Hollywood "TEV") microcode, which
/// this project's MDL0 *reader* never needed to decode, so writing one meant deriving the
/// register-level encoding. Every structural decision below was checked against a retail Mario
/// Kart Wii `course_model.brres` pulled off a real disc, the exact mesh header layout, the
/// contents of a mesh's setup display list, the material display list's command sequence and the
/// texture-link section are all reproduced from that file. The specific GPU
/// register addresses are public GameCube/Wii hardware facts (the same table published in
/// Dolphin's source and in libogc).
///
/// Things a real file has that this writer still does not produce: per-vertex (rather than
/// per-face) normals, mipmaps, animations, LOD, and TEV setups beyond retail's one-stage
/// texture x vertex colour x 2. None of those stop a model loading.
nonisolated enum MDL0Writer {
    /// One `usemtl` group's material. `textureName` is the name of a TEX0 resource sitting in the
    /// same BRRES; it is written into this MDL0's own string table, which is all the runtime needs
    /// to bind the two together (it resolves textures by name, not by pointer).
    struct MaterialSpec {
        var name: String
        var color: (r: Float, g: Float, b: Float) = (1, 1, 1)
        var textureName: String?
        /// GX cull mode: 0 none, 1 front, 2 back.
        var cull: UInt32 = 0
        /// Texture wrap S/T: 0 clamp, 1 repeat, 2 mirror.
        var wrap: (s: UInt32, t: UInt32) = (1, 1)
        /// Alpha test: comp0, ref0, op, comp1, ref1 (GX compare functions; 7 = always).
        var alphaTest: (UInt8, UInt8, UInt8, UInt8, UInt8) = (7, 0, 0, 7, 0)
        /// Blend factors (GX): set, the mesh is drawn in the translucent pass.
        var blend: (src: UInt8, dst: UInt8)? = nil
        var depthWrite = true
        /// The texture carries mip levels: sample it trilinearly.
        var mipmapped = false
        /// A baked shadow map ("kage") drawn over the texture from a second UV set, the way retail
        /// courses shade: stage 0 blends the vertex colour toward `shadowColor` where the map is
        /// dark, stage 1 multiplies by the texture x2. Bytes copied from retail
        /// `beginner_course` `a_MainRoad_m`. Needs the group's `shadowUVs`.
        var shadowMap: String? = nil
        /// Colour the darkest shadow fades to (retail Luigi Circuit road: 4C 4C 56).
        var shadowColor: (r: UInt8, g: UInt8, b: UInt8) = (0x4C, 0x4C, 0x56)
        var translucent: Bool { blend != nil }
        var alphaTested: Bool { !(alphaTest.0 == 7 && alphaTest.3 == 7) }
    }

    typealias RGBA = (UInt8, UInt8, UInt8, UInt8)
    /// The neutral vertex colour for a textured material: Mario Kart Wii's course shader is
    /// texture x vertex colour x 2 (retail vertex colours average 0x80-0xB0), so white doubles
    /// every texture's brightness.
    static let neutralVertexColor: RGBA = (0x80, 0x80, 0x80, 0xFF)

    struct Group {
        var material: MaterialSpec
        var triangles: [OBJImporter.Triangle]
        /// Optional grey level (0-255) per triangle, written as real vertex colours, how retail
        /// minimaps draw darker areas inside their single mesh (castle_course: 0x66/0x80/0xFF).
        /// `nil` keeps the single flat `material.color` entry.
        var triangleShades: [UInt8]? = nil
        /// Optional per-vertex colours (3 per triangle), multiplied into the texture in-game --
        /// 0x80 is neutral for a textured material (see `neutralVertexColor`).
        var vertexColors: [RGBA]? = nil
        /// Shadow-map texture coordinates, 3 per triangle, already in GX orientation (V down).
        var shadowUVs: [Vec2]? = nil

    }

    /// Splits `triangles` into one group per distinct `usemtl` name, in first-seen order, asking
    /// the caller what material each name maps to. Triangles with no `usemtl` at all become a
    /// single group under `spec(nil)`.
    static func groups(from triangles: [OBJImporter.Triangle], spec: (String?) -> MaterialSpec) -> [Group] {
        var order: [String?] = []
        var byMaterial: [String: [OBJImporter.Triangle]] = [:]
        var unnamed: [OBJImporter.Triangle] = []
        for t in triangles {
            guard let name = t.materialName else {
                if unnamed.isEmpty { order.append(nil) }
                unnamed.append(t)
                continue
            }
            if byMaterial[name] == nil { order.append(name) }
            byMaterial[name, default: []].append(t)
        }
        return order.map { key in
            Group(material: spec(key), triangles: key.map { byMaterial[$0] ?? [] } ?? unnamed)
        }
    }

    /// A single MDL0 mesh addresses its vertices with 16-bit indices, so no one group may exceed
    /// this many vertices (3 per triangle).
    static let maxVerticesPerMesh = 65535

    private struct BuiltVertex { var position: Vec3; var normal: Vec3; var uv: Vec2; var shadowUV = Vec2() }

    /// One mesh's vertex arrays with duplicates merged, and each drawn vertex's index into them.
    private struct IndexedMesh {
        var positions: [Vec3] = [], normals: [Vec3] = [], uvs: [Vec2] = [], colors: [RGBA] = [], shadowUVs: [Vec2] = []
        var indices: [(p: Int, n: Int, t: Int, c: Int, s: Int)] = []
        var colorIndex16: Bool { colors.count > 256 }

        init(vertices: [BuiltVertex], colors vertexColors: [RGBA]) {
            var p: [[UInt32]: Int] = [:], n: [[UInt32]: Int] = [:], t: [[UInt32]: Int] = [:], c: [UInt32: Int] = [:], sh: [[UInt32]: Int] = [:]
            func add<K: Hashable, V>(_ key: K, _ value: V, _ map: inout [K: Int], _ list: inout [V]) -> Int {
                if let i = map[key] { return i }
                list.append(value); map[key] = list.count - 1
                return list.count - 1
            }
            for (i, v) in vertices.enumerated() {
                let col = vertexColors[i]
                indices.append((add([v.position.x.bitPattern, v.position.y.bitPattern, v.position.z.bitPattern], v.position, &p, &positions),
                                add([v.normal.x.bitPattern, v.normal.y.bitPattern, v.normal.z.bitPattern], v.normal, &n, &normals),
                                add([v.uv.x.bitPattern, v.uv.y.bitPattern], v.uv, &t, &uvs),
                                add(UInt32(col.0) << 24 | UInt32(col.1) << 16 | UInt32(col.2) << 8 | UInt32(col.3), col, &c, &colors),
                                add([v.shadowUV.x.bitPattern, v.shadowUV.y.bitPattern], v.shadowUV, &sh, &shadowUVs)))
            }
        }
    }

    /// Returns the finished MDL0 bytes, or nil if there is nothing to build (no triangles at all,
    /// or a single group too big for one mesh).
    /// A finished MDL0 and the names it refers to.
    ///
    /// The names are *not* part of `data`. A real BRRES keeps every string in one pool shared by
    /// the whole file, past the last resource and outside any resource's declared length, and an
    /// MDL0 reaches its own bones, materials, meshes and texture links through offsets into that
    /// pool. So the blob is emitted with those offset fields left at zero, and the container fills
    /// them in once it knows where both this resource and the pool have landed (see
    /// `BRRESDocument.rebuild`).
    struct Built {
        var data: Data
        var stringReferences: [BRRESStringReference]
    }

    /// A bone that carries no geometry, just a fixed world-space position under a fixed name --
    /// what Mario Kart Wii's own `map_model.brres` uses `posLD`/`posRU` for: two corner markers
    /// the minimap HUD looks up by name to scale/position kart icons against the track's bounds.
    /// A map model missing them crashes on load (`g3d_resnode_ac.h ResNode::ref: Object not
    /// valid`, confirmed against the wiki's documented "Missing Map Model Bones" crash cause,
    /// and against retail's own map models, which all carry exactly these two).
    struct MarkerBone {
        var name: String
        var translation: Vec3
    }

    /// `strips`: draw with triangle strips, as RiiStudio's importer does (the hardware-compatible
    /// setting), otherwise one triangle list per mesh.
    static func build(name: String, groups rawGroups: [Group], markerBones: [MarkerBone] = [],
                      mapStyle: Bool = false, strips: Bool = BuildCompatibility.current == .hardware) -> Built? {
        let groups = rawGroups.filter { !$0.triangles.isEmpty }
        guard !groups.isEmpty else { return nil }
        guard groups.allSatisfy({ $0.triangles.count * 3 <= maxVerticesPerMesh }) else { return nil }

        // MARK: Resolve geometry up front.

        var groupVertices: [[BuiltVertex]] = []
        let textured = groups.map { $0.material.textureName != nil }
        let shadowed = groups.indices.map { textured[$0] && groups[$0].material.shadowMap != nil && groups[$0].shadowUVs?.count == groups[$0].triangles.count * 3 }
        for (gi, group) in groups.enumerated() {
            var vertices: [BuiltVertex] = []
            vertices.reserveCapacity(group.triangles.count * 3)
            for (k, t) in group.triangles.enumerated() {
                let normal = faceNormal(t.v0, t.v1, t.v2)
                func sh(_ j: Int) -> Vec2 { shadowed[gi] ? group.shadowUVs![k * 3 + j] : Vec2() }
                vertices.append(BuiltVertex(position: t.v0, normal: normal, uv: t.uv0 ?? Vec2(), shadowUV: sh(0)))
                vertices.append(BuiltVertex(position: t.v1, normal: normal, uv: t.uv1 ?? Vec2(), shadowUV: sh(1)))
                vertices.append(BuiltVertex(position: t.v2, normal: normal, uv: t.uv2 ?? Vec2(), shadowUV: sh(2)))
            }
            groupVertices.append(vertices)
        }
        // Each drawn vertex's colour: per-vertex when given, per-triangle shades (minimaps), or
        // one flat colour, neutral grey when textured, the material colour otherwise.
        let meshes: [IndexedMesh] = groups.enumerated().map { index, group in
            let count = groupVertices[index].count
            var colors: [RGBA]
            func byte(_ f: Float) -> UInt8 { UInt8(max(0, min(255, (f * 255).rounded()))) }
            if let vc = group.vertexColors, vc.count == count {
                colors = vc
            } else if !textured[index], let shades = group.triangleShades, shades.count * 3 == count {
                colors = []
                for g in shades { let c: RGBA = (g, g, g, 255); colors += [c, c, c] }
            } else {
                let c = group.material.color
                colors = Array(repeating: textured[index] ? neutralVertexColor : (byte(c.r), byte(c.g), byte(c.b), 255), count: count)
            }
            return IndexedMesh(vertices: groupVertices[index], colors: colors)
        }
        // Retail map models carry no normals at all (see `vcdLow` and `MapModelBuilder`'s doc), so
        // the minimap path emits pos+colour0 only; every other model keeps normals.
        let includeNormals = !mapStyle
        // What each mesh's draw list holds: (GX primitive opcode, drawn vertices as indices into
        // that mesh's `indices`). Strips share vertices only where the whole vertex matches
        // (position, normal, texcoord, colour); triangles that join no strip go in one list.
        let primitives: [[(op: UInt8, verts: [Int])]] = meshes.map { mesh in
            // Minimaps keep retail's single triangle list (every retail map_model draws one).
            guard strips, !mapStyle else { return [(0x90, Array(mesh.indices.indices))] }
            var id: [[Int]: Int] = [:], first: [Int] = []
            let ids = mesh.indices.enumerated().map { (i, x) -> Int in
                let key = [x.p, x.n, x.t, x.c, x.s]
                if let k = id[key] { return k }
                id[key] = first.count; first.append(i); return first.count - 1
            }
            var out: [(op: UInt8, verts: [Int])] = [], loose: [Int] = []
            for strip in TriangleStrips.stripify(ids, vertexCount: first.count) {
                if strip.count == 3 { loose += strip.map { first[$0] } } else { out.append((0x98, strip.map { first[$0] })) }
            }
            if !loose.isEmpty { out.append((0x90, loose)) }
            return out
        }
        let totalVertices = groupVertices.reduce(0) { $0 + $1.count }
        let totalTriangles = groups.reduce(0) { $0 + $1.triangles.count }

        var minB = Vec3(x: .greatestFiniteMagnitude, y: .greatestFiniteMagnitude, z: .greatestFiniteMagnitude)
        var maxB = Vec3(x: -.greatestFiniteMagnitude, y: -.greatestFiniteMagnitude, z: -.greatestFiniteMagnitude)
        for vertices in groupVertices {
            for v in vertices {
                minB.x = min(minB.x, v.position.x); minB.y = min(minB.y, v.position.y); minB.z = min(minB.z, v.position.z)
                maxB.x = max(maxB.x, v.position.x); maxB.y = max(maxB.y, v.position.y); maxB.z = max(maxB.z, v.position.z)
            }
        }

        // Names. Material names must be unique inside their dictionary, so a duplicate `usemtl`
        // (or a group with no name at all) gets a positional fallback rather than colliding.
        var usedNames = Set<String>()
        let materialNames: [String] = groups.enumerated().map { index, group in
            var candidate = group.material.name.isEmpty ? "material\(index)" : group.material.name
            while usedNames.contains(candidate) { candidate += "_\(index)" }
            usedNames.insert(candidate)
            return candidate
        }
        let meshNames = groups.indices.map { "polygon\($0)" }
        let positionNames = groups.indices.map { "position\($0)" }
        let normalNames = groups.indices.map { "normal\($0)" }
        let colorNames = groups.indices.map { "color\($0)" }
        // Texcoord buffers: one per textured group, plus its shadow-map set straight after it.
        var uvIndexForGroup: [Int?] = [], shadowUVIndexForGroup: [Int?] = []
        var uvBufferCount = 0
        for index in groups.indices {
            if textured[index] { uvIndexForGroup.append(uvBufferCount); uvBufferCount += 1 } else { uvIndexForGroup.append(nil) }
            if shadowed[index] { shadowUVIndexForGroup.append(uvBufferCount); uvBufferCount += 1 } else { shadowUVIndexForGroup.append(nil) }
        }
        let uvNames = (0..<uvBufferCount).map { "texcoord\($0)" }
        // One texture-link entry per distinct texture, listing every material that samples it.
        var textureLinkOrder: [String] = []
        var textureLinkUsers: [String: [Int]] = [:]
        // (material, sampler slot) pairs.
        var textureLinkSlots: [String: [(material: Int, slot: Int)]] = [:]
        for (index, group) in groups.enumerated() {
            guard let texture = group.material.textureName else { continue }
            if textureLinkUsers[texture] == nil { textureLinkOrder.append(texture) }
            textureLinkUsers[texture, default: []].append(index)
            textureLinkSlots[texture, default: []].append((index, 0))
        }
        for (index, group) in groups.enumerated() where shadowed[index] {
            let texture = group.material.shadowMap!
            if textureLinkUsers[texture] == nil { textureLinkOrder.append(texture) }
            textureLinkUsers[texture, default: []].append(index)
            textureLinkSlots[texture, default: []].append((index, 1))
        }

        // MARK: Pass 1, lay out every offset.

        func align32(_ n: Int) -> Int { (n + 31) & ~31 }
        /// Start offset for a block whose *data* (after a `headerSize` prefix) must land on a
        /// 32-byte boundary, which the GPU requires for vertex arrays and display lists.
        func alignedStart(_ cursor: Int, headerSize: Int) -> Int { align32(cursor + headerSize) - headerSize }

        let headerSize = 0x48
        let nameFieldSize = 4
        // One view matrix per bone, retail map models declare 3 (map, posLD, posRU) with the
        // LUT [0, 1, 2], and each marker bone's own matrixId indexes into it.
        let matrixCount = 1 + markerBones.count
        let infoSize = 0x44 + 4 * matrixCount // BinaryModelInfo (0x40) + mtxToBoneLUT (count + entries)
        let preambleEnd = headerSize + nameFieldSize + infoSize

        var cursor = preambleEnd
        func reserveDict(_ names: [String]) -> Int {
            guard !names.isEmpty else { return 0 }
            let start = cursor
            cursor += dictByteSize(names: names)
            return start
        }
        // Three lists, not two: DrawXlu is emitted below alongside DrawOpa, and reserving space
        // for only two left the emitted dictionary 0x18 bytes longer than its slot, it ran over
        // the Bones dictionary, which then overwrote DrawOpa's and DrawXlu's own entries.
        // A map-style model (`mapStyle`) carries only NodeTree + DrawOpa, exactly like every
        // retail `map_model.brres` on the disc (confirmed across all 52: none have a DrawXlu
        // draw list).
        let rootName = mapStyle ? "map" : "root"
        let ofsRenderTree = reserveDict(mapStyle ? ["NodeTree", "DrawOpa"] : ["NodeTree", "DrawOpa", "DrawXlu"])
        let ofsBones = reserveDict([rootName] + markerBones.map(\.name))
        let ofsPositions = reserveDict(positionNames)
        let ofsNormals = includeNormals ? reserveDict(normalNames) : 0
        let ofsColors = reserveDict(colorNames)
        let ofsUVs = reserveDict(uvNames)
        let ofsMaterials = reserveDict(materialNames)
        let ofsShaders = reserveDict(materialNames)
        let ofsMeshes = reserveDict(meshNames)
        let ofsTextureLinks = reserveDict(textureLinkOrder)

        // Render-tree bytecode. Opcode 2 = NodeDescendence (5 bytes), 4 = Draw (8 bytes), 1 = end
        // of list, all three verified against a real file's own bytecode. One NodeDescendence
        // per bone, root plus any marker bones, each a flat top-level entry (no parent/child
        // nesting, matches how this writer's single root bone was already emitted).
        let nodeTreeSize = 5 * (1 + markerBones.count) + 1
        let opaque = groups.indices.filter { !groups[$0].material.translucent }
        let translucent = groups.indices.filter { groups[$0].material.translucent }
        let drawOpaSize = opaque.count * 8 + 1
        // Every material this writer builds is opaque (`flag: 0` in buildMaterialAndShader), so
        // DrawXlu holds nothing, just its own terminator. Retail's DrawXlu only lists the
        // specific objects that are actually alpha-blended; duplicating every already-opaque draw
        // into it as well drew each mesh twice from two different scene-graph slots, which is what
        // crashed with "g3d_resnode_ac.h ResNode::ref: Object not valid".
        let drawXluSize = translucent.count * 8 + 1
        let nodeTreeStart = cursor
        let drawOpaStart = nodeTreeStart + nodeTreeSize
        let drawXluStart = drawOpaStart + drawOpaSize
        cursor = mapStyle ? drawOpaStart + drawOpaSize : drawXluStart + drawXluSize

        // The bytecode lists above are odd-sized (a map model's come to 25 bytes), so bones must be
        // re-aligned: they're read with float/paired-single loads, which the Wii's CPU refuses
        // from a misaligned address (an alignment exception, a crash the moment the game binds
        // the model; Dolphin doesn't emulate it). Retail starts its bones on a 32-byte boundary.
        let boneStart = align32(cursor)
        let boneSize = 0xD0
        cursor = boneStart + boneSize * (1 + markerBones.count)

        let posHeaderSize = 0x38 // has min/max
        let nrmHeaderSize = 0x20 // no min/max
        let colorHeaderSize = 0x20 // matches Mdl0ColourGroup's own header size (NW4R layout)
        let uvHeaderSize = 0x30 // has min/max
        var posStart: [Int] = [], nrmStart: [Int] = [], colorStart: [Int] = [], uvStart: [Int] = []
        for (index, vertices) in groupVertices.enumerated() {
            _ = vertices
            let mesh = meshes[index]
            let p = alignedStart(cursor, headerSize: posHeaderSize)
            posStart.append(p)
            cursor = p + posHeaderSize + mesh.positions.count * 12
            if includeNormals {
                let n = alignedStart(cursor, headerSize: nrmHeaderSize)
                nrmStart.append(n)
                cursor = n + nrmHeaderSize + mesh.normals.count * 12
            }
            // A single shared rgba8 entry (opaque white), referenced by every vertex via its
            // INDEX8 colour0 index (always 0), not because this writer bakes any real vertex
            // colour, but because retail's own course meshes never declare a normal *without*
            // also declaring colour0 (confirmed against every one of `beginner_course.szs`'s 22
            // meshes: none use this writer's old normal-only, no-colour0 combination at all). The
            // TEV stage never actually reads it (raster colour is disabled in both the textured
            // and untextured combiners), so its value doesn't matter, only its *presence* does.
            let c = alignedStart(cursor, headerSize: colorHeaderSize)
            colorStart.append(c)
            // One rgba8 entry per shade (just one when unshaded), padded to 32 like retail (0x40).
            cursor = c + colorHeaderSize + align32(mesh.colors.count * 4)
            if textured[index] {
                let u = alignedStart(cursor, headerSize: uvHeaderSize)
                uvStart.append(u)
                cursor = u + uvHeaderSize + mesh.uvs.count * 8
            }
            if shadowed[index] {
                let u = alignedStart(cursor, headerSize: uvHeaderSize)
                uvStart.append(u)
                cursor = u + uvHeaderSize + mesh.shadowUVs.count * 8
            }
        }

        var matStart: [Int] = [], shaderStart: [Int] = [], samplerStart: [Int?] = []
        var materialBlobs: [Data] = []
        for (index, group) in groups.enumerated() {
            let start = align32(cursor)
            let (bytes, materialSize, samplerLocal) = buildMaterialAndShader(spec: group.material, textured: textured[index], shadowed: shadowed[index])
            matStart.append(start)
            shaderStart.append(start + materialSize)
            samplerStart.append(samplerLocal.map { start + $0 })
            materialBlobs.append(bytes)
            cursor = start + bytes.count
        }

        let meshHeaderSize = 0x68
        let boneTableSize = 4 // one u32 count of 0, this model is rigid, every mesh rides bone 0
        var meshStart: [Int] = [], setupStart: [Int] = [], mainStart: [Int] = []
        let setupDLSize = 0xE0
        var mainDLSize: [Int] = []
        for (index, vertices) in groupVertices.enumerated() {
            let start = align32(cursor)
            meshStart.append(start)
            let setup = align32(start + meshHeaderSize + boneTableSize)
            setupStart.append(setup)
            let main = setup + setupDLSize
            mainStart.append(main)
            // One GX_TRIANGLES command (opcode + u16 count) then per-vertex indices: position
            // (16-bit), normal (16-bit, unless a map-style model carries none), colour0 (8-bit)
            // always, plus texcoord0 (16-bit) when textured.
            let bytesPerVertex = self.bytesPerVertex(textured: textured[index], includeNormals: includeNormals, color16: meshes[index].colorIndex16) + (shadowed[index] ? 2 : 0)
            _ = vertices
            let size = align32(primitives[index].reduce(0) { $0 + 3 + $1.verts.count * bytesPerVertex })
            mainDLSize.append(size)
            cursor = main + size
        }

        var textureLinkStart: [Int] = []
        for texture in textureLinkOrder {
            textureLinkStart.append(cursor)
            cursor += 4 + (textureLinkSlots[texture]?.count ?? 0) * 8
        }

        let fileSize = cursor

        // MARK: Pass 2, emit.

        var d = Data(count: fileSize)
        func put(_ bytes: [UInt8], at offset: Int) { d.replaceSubrange(offset..<(offset + bytes.count), with: bytes) }
        func putU8(_ v: UInt8, at o: Int) { put([v], at: o) }
        func putU16(_ v: UInt16, at o: Int) { put([UInt8(v >> 8), UInt8(v & 0xFF)], at: o) }
        func putU32(_ v: UInt32, at o: Int) {
            put([UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)], at: o)
        }
        func putS32(_ v: Int32, at o: Int) { putU32(UInt32(bitPattern: v), at: o) }
        func putF32(_ v: Float, at o: Int) { putU32(v.bitPattern, at: o) }

        // Strings all live in one table appended after everything else; every reference is stored
        // self-relative to an anchor, so where the table ends up doesn't matter.
        var pendingStrings: [(text: String, fieldAt: Int, anchor: Int)] = []
        func scheduleString(_ s: String, fieldAt: Int, anchor: Int) {
            pendingStrings.append((s, fieldAt, anchor))
        }

        putASCII4("MDL0", &d, at: 0)
        putU32(UInt32(fileSize), at: 4)
        putU32(11, at: 8) // version 11. Mario Kart Wii will not load any other
        putS32(0, at: 0xC) // ofsBRRES, irrelevant until embedded
        // [0]RenderTree [1]Bones [2]Positions [3]Normals [4]Colors [5]UVs [6]FurVec [7]FurPos
        // [8]Materials [9]Shaders [10]Meshes [11]TextureLinks [12]PaletteLinks [13]UserData
        let secOfs = [ofsRenderTree, ofsBones, ofsPositions, ofsNormals, ofsColors, ofsUVs, 0, 0,
                      ofsMaterials, ofsShaders, ofsMeshes, ofsTextureLinks, 0, 0]
        for (i, ofs) in secOfs.enumerated() { putS32(Int32(ofs), at: 0x10 + i * 4) }
        scheduleString(name, fieldAt: headerSize, anchor: 0)

        let info = headerSize + nameFieldSize
        putU32(0x40, at: info)
        putS32(-Int32(info), at: info + 4) // mdlOffset
        putU32(0, at: info + 8) // scalingRule
        putU32(0, at: info + 12) // texMtxMode
        putU32(UInt32(totalVertices), at: info + 16)
        putU32(UInt32(totalTriangles), at: info + 20)
        putU32(0, at: info + 24) // sourceLocation
        putU32(UInt32(matrixCount), at: info + 28) // numViewMtx
        // info+0x20: needNrmMtxArray, 1 in retail course models, 0 in retail map models (no normals).
        putU8(includeNormals ? 1 : 0, at: info + 32); putU8(0, at: info + 33); putU8(0, at: info + 34); putU8(0, at: info + 35)
        putU32(0x40, at: info + 36) // ofsMtxToBoneLUT, relative to info start
        putF32(minB.x, at: info + 40); putF32(minB.y, at: info + 44); putF32(minB.z, at: info + 48)
        putF32(maxB.x, at: info + 52); putF32(maxB.y, at: info + 56); putF32(maxB.z, at: info + 60)
        putU32(UInt32(matrixCount), at: info + 0x40)
        for i in 0..<matrixCount { putS32(Int32(i), at: info + 0x44 + i * 4) } // matrix i -> bone i

        // Render tree. Opcode 2 = NodeDescendence (5 bytes), 4 = Draw (8 bytes), 1 = end of list.
        // Retail course_model.brres has BOTH DrawOpa and DrawXlu lists. Emit both to match.
        // drawXluStart/drawXluSize already computed in layout pass.
        emitDict(&d, groupStart: ofsRenderTree,
                 entries: [("NodeTree", nodeTreeStart), ("DrawOpa", drawOpaStart)]
                    + (mapStyle ? [] : [("DrawXlu", drawXluStart)]), schedule: scheduleString)
        for i in 0..<(1 + markerBones.count) {
            let o = nodeTreeStart + i * 5
            putU8(2, at: o) // NodeDescendence
            putU16(UInt16(i), at: o + 1) // bone i
            // Matrix 0 for every node, exactly as every retail map model descends its bones
            // (confirmed against `beginner_course.szs`'s own map_model: its render-tree descends
            // all three of map/posLD/posRU with matrix 0). This model is rigid, it declares a
            // single matrix (numViewMtx=1), so a marker node descending with matrix 1 or 2 (as
            // a prior version of this writer did) references a matrix slot that doesn't exist,
            // and the runtime can't resolve posLD/posRU's world matrices from their own SRT; the
            // minimap HUD then has no valid framing corners to draw the map within.
            putU16(0, at: o + 3) // matrix 0
        }
        putU8(1, at: nodeTreeStart + (1 + markerBones.count) * 5) // end of list
        // Each mesh is drawn from exactly one list: opaque ones first, blended ones after them.
        func emitDraws(_ list: [Int], at start: Int) {
            for (k, index) in list.enumerated() {
                let o = start + k * 8
                putU8(4, at: o) // Draw
                putU16(UInt16(index), at: o + 1) // material
                putU16(UInt16(index), at: o + 3) // mesh
                putU16(0, at: o + 5) // bone
                putU8(0, at: o + 7) // priority
            }
            putU8(1, at: start + list.count * 8) // end of list
        }
        emitDraws(opaque, at: drawOpaStart)
        if !mapStyle { emitDraws(translucent, at: drawXluStart) }

        // Root bone, plus any marker bones (see `MarkerBone`).
        emitDict(&d, groupStart: ofsBones,
                entries: [(rootName, boneStart)] + markerBones.enumerated().map { i, m in
                    (m.name, boneStart + boneSize * (i + 1))
                }, schedule: scheduleString)
        putU32(UInt32(boneSize), at: boneStart)
        putS32(Int32(-boneStart), at: boneStart + 4)
        scheduleString(rootName, fieldAt: boneStart + 8, anchor: boneStart)
        putU32(0, at: boneStart + 0xC) // id
        putU32(0, at: boneStart + 0x10) // matrixId
        // Flags: NoTransform | FixedTranslation | FixedRotation | FixedScale | ScaleEqual |
        // HasGeometry, confirmed byte-for-byte against a retail course's root bone (0x31F).
        // Every one of these is true for this bone (identity scale/rotation/translation,
        // meshes attached), but leaving the field at 0, what a prior version of this writer did
        //, tells the runtime this bone's world matrix isn't fixed and must be computed/cached at
        // draw time instead of just using the identity outright, which is the leading suspect for
        // the "Invalid write" crashes/hangs a model built by this writer produces in-game.
        putU32(0x31F, at: boneStart + 0x14) // flag
        putU32(0, at: boneStart + 0x18) // billboardType
        putU32(0, at: boneStart + 0x1C) // ancestorBillboardBone
        putF32(1, at: boneStart + 0x20); putF32(1, at: boneStart + 0x24); putF32(1, at: boneStart + 0x28)
        putF32(minB.x, at: boneStart + 0x44); putF32(minB.y, at: boneStart + 0x48); putF32(minB.z, at: boneStart + 0x4C)
        putF32(maxB.x, at: boneStart + 0x50); putF32(maxB.y, at: boneStart + 0x54); putF32(maxB.z, at: boneStart + 0x58)
        for row in 0..<3 {
            putF32(1, at: boneStart + 0x70 + row * 16 + row * 4) // modelMtx, identity 3x4
            putF32(1, at: boneStart + 0xA0 + row * 16 + row * 4) // inverseModelMtx
        }
        // Marker bones are children of the root, as in retail (map -> posLD -> posRU siblings).
        if !markerBones.isEmpty { putS32(Int32(boneSize), at: boneStart + 0x60) } // firstChild

        // Marker bones, no geometry, just a name the runtime looks up and a fixed world
        // position, matching retail's own `posLD`/`posRU` bones byte-for-byte in flag value
        // (0x11C: FixedRotation | FixedScale | ScaleEqual, but neither NoTransform nor
        // FixedTranslation, since, unlike root, these carry a non-identity
        // translation; not HasGeometry, since nothing draws from them).
        for (i, marker) in markerBones.enumerated() {
            let b = boneStart + boneSize * (i + 1)
            putU32(UInt32(boneSize), at: b)
            putS32(Int32(-b), at: b + 4)
            scheduleString(marker.name, fieldAt: b + 8, anchor: b)
            putU32(UInt32(i + 1), at: b + 0xC) // id
            putU32(UInt32(i + 1), at: b + 0x10) // matrixId
            putU32(0x11C, at: b + 0x14) // flag
            putU32(0, at: b + 0x18) // billboardType
            putU32(0, at: b + 0x1C) // ancestorBillboardBone
            putF32(1, at: b + 0x20); putF32(1, at: b + 0x24); putF32(1, at: b + 0x28)
            // The position lives in the SRT translation (0x38), which is what the runtime builds
            // the bone's world matrix from; bounds stay zero. Both confirmed against retail
            // `beginner_course.szs` map_model (posLD T=(-36000,0,66000), min/max all 0). A prior
            // version put the position only in the bounds, so both markers resolved to the origin
            // and the minimap had a zero-size frame, it never drew.
            putF32(marker.translation.x, at: b + 0x38); putF32(marker.translation.y, at: b + 0x3C); putF32(marker.translation.z, at: b + 0x40)
            putS32(Int32(boneStart - b), at: b + 0x5C) // parent: root
            if i + 1 < markerBones.count { putS32(Int32(boneSize), at: b + 0x64) } // next sibling
            if i > 0 { putS32(Int32(-boneSize), at: b + 0x68) } // previous sibling
            for row in 0..<3 {
                putF32(1, at: b + 0x70 + row * 16 + row * 4) // modelMtx: identity rotation/scale...
                putF32(1, at: b + 0xA0 + row * 16 + row * 4) // ...same for the inverse
            }
            // ...plus a translation in the 4th column of each row (and its negation, inverted).
            putF32(marker.translation.x, at: b + 0x70 + 0 * 16 + 12)
            putF32(marker.translation.y, at: b + 0x70 + 1 * 16 + 12)
            putF32(marker.translation.z, at: b + 0x70 + 2 * 16 + 12)
            putF32(-marker.translation.x, at: b + 0xA0 + 0 * 16 + 12)
            putF32(-marker.translation.y, at: b + 0xA0 + 1 * 16 + 12)
            putF32(-marker.translation.z, at: b + 0xA0 + 2 * 16 + 12)
        }

        // Vertex buffers.
        emitDict(&d, groupStart: ofsPositions, entries: zip(positionNames, posStart).map { ($0, $1) }, schedule: scheduleString)
        if includeNormals {
            emitDict(&d, groupStart: ofsNormals, entries: zip(normalNames, nrmStart).map { ($0, $1) }, schedule: scheduleString)
        }
        emitDict(&d, groupStart: ofsColors, entries: zip(colorNames, colorStart).map { ($0, $1) }, schedule: scheduleString)
        if !uvNames.isEmpty {
            emitDict(&d, groupStart: ofsUVs, entries: zip(uvNames, uvStart).map { ($0, $1) }, schedule: scheduleString)
        }
        for index in groupVertices.indices {
            let mesh = meshes[index]
            let p = posStart[index]
            putU32(UInt32(posHeaderSize + mesh.positions.count * 12), at: p)
            putS32(Int32(-p), at: p + 4)
            putS32(Int32(posHeaderSize), at: p + 8)
            scheduleString(positionNames[index], fieldAt: p + 12, anchor: p)
            putU32(UInt32(index), at: p + 0x10) // id
            putU32(1, at: p + 0x14) // componentCount: 1 = xyz
            putU32(4, at: p + 0x18) // componentType: float32
            putU8(0, at: p + 0x1C) // divisor (unused for float32)
            putU8(12, at: p + 0x1D) // stride
            putU16(UInt16(mesh.positions.count), at: p + 0x1E)
            var localMin = Vec3(x: .greatestFiniteMagnitude, y: .greatestFiniteMagnitude, z: .greatestFiniteMagnitude)
            var localMax = Vec3(x: -.greatestFiniteMagnitude, y: -.greatestFiniteMagnitude, z: -.greatestFiniteMagnitude)
            for v in mesh.positions {
                localMin.x = min(localMin.x, v.x); localMin.y = min(localMin.y, v.y); localMin.z = min(localMin.z, v.z)
                localMax.x = max(localMax.x, v.x); localMax.y = max(localMax.y, v.y); localMax.z = max(localMax.z, v.z)
            }
            putF32(localMin.x, at: p + 0x20); putF32(localMin.y, at: p + 0x24); putF32(localMin.z, at: p + 0x28)
            putF32(localMax.x, at: p + 0x2C); putF32(localMax.y, at: p + 0x30); putF32(localMax.z, at: p + 0x34)
            for (i, v) in mesh.positions.enumerated() {
                let o = p + posHeaderSize + i * 12
                putF32(v.x, at: o); putF32(v.y, at: o + 4); putF32(v.z, at: o + 8)
            }

            if includeNormals {
                let n = nrmStart[index]
                putU32(UInt32(nrmHeaderSize + mesh.normals.count * 12), at: n)
                putS32(Int32(-n), at: n + 4)
                putS32(Int32(nrmHeaderSize), at: n + 8)
                scheduleString(normalNames[index], fieldAt: n + 12, anchor: n)
                putU32(UInt32(index), at: n + 0x10)
                putU32(0, at: n + 0x14) // componentCount: 0 = xyz (normal semantics)
                putU32(4, at: n + 0x18)
                putU8(0, at: n + 0x1C)
                putU8(12, at: n + 0x1D)
                putU16(UInt16(mesh.normals.count), at: n + 0x1E)
                for (i, v) in mesh.normals.enumerated() {
                    let o = n + nrmHeaderSize + i * 12
                    putF32(v.x, at: o); putF32(v.y, at: o + 4); putF32(v.z, at: o + 8)
                }
            }

            // Colours0: a single shared opaque-white rgba8 entry, see the layout pass's own
            // comment on why this exists at all (every retail mesh with a normal also declares
            // colour0; this writer's own TEV never actually reads it).
            let c = colorStart[index]
            let colourCount = mesh.colors.count
            putU32(UInt32(colorHeaderSize + align32(colourCount * 4)), at: c)
            putS32(Int32(-c), at: c + 4)
            putS32(Int32(colorHeaderSize), at: c + 8) // DataOffset, self-relative like pos/normal
            scheduleString(colorNames[index], fieldAt: c + 12, anchor: c)
            putU32(UInt32(index), at: c + 0x10) // id
            putU32(1, at: c + 0x14) // Unknown14, 1 in every real Mdl0ColourGroup sampled
            putU32(5, at: c + 0x18) // Type: 5 = rgba8
            putU8(4, at: c + 0x1C) // Stride: 4 bytes/entry for rgba8
            putU8(0, at: c + 0x1D)
            putU16(UInt16(colourCount), at: c + 0x1E) // ColourCount
            // Channel 0 sources its colour from this vertex colour (see the material's chan block),
            // so an untextured material's flat colour is this entry; textured ones stay white.
            for (k, col) in mesh.colors.enumerated() {
                put([col.0, col.1, col.2, col.3], at: c + colorHeaderSize + k * 4)
            }

            func emitUVs(_ uvIndex: Int, _ uvs: [Vec2], flip: Bool) {
            let u = uvStart[uvIndex]
            putU32(UInt32(uvHeaderSize + uvs.count * 8), at: u)
            putS32(Int32(-u), at: u + 4)
            putS32(Int32(uvHeaderSize), at: u + 8)
            scheduleString(uvNames[uvIndex], fieldAt: u + 12, anchor: u)
            putU32(UInt32(uvIndex), at: u + 0x10)
            putU32(1, at: u + 0x14) // componentCount: 1 = st
            putU32(4, at: u + 0x18)
            putU8(0, at: u + 0x1C)
            putU8(8, at: u + 0x1D)
            putU16(UInt16(uvs.count), at: u + 0x1E)
            var minUV = Vec2(x: .greatestFiniteMagnitude, y: .greatestFiniteMagnitude)
            var maxUV = Vec2(x: -.greatestFiniteMagnitude, y: -.greatestFiniteMagnitude)
            for uv in uvs {
                // GX's V axis increases downward; OBJ is V-up, so flip once, here.
                let flipped = flip ? Vec2(x: uv.x, y: 1 - uv.y) : uv
                minUV.x = min(minUV.x, flipped.x); minUV.y = min(minUV.y, flipped.y)
                maxUV.x = max(maxUV.x, flipped.x); maxUV.y = max(maxUV.y, flipped.y)
            }
            putF32(minUV.x, at: u + 0x20); putF32(minUV.y, at: u + 0x24)
            putF32(maxUV.x, at: u + 0x28); putF32(maxUV.y, at: u + 0x2C)
            for (i, uv) in uvs.enumerated() {
                let o = u + uvHeaderSize + i * 8
                putF32(uv.x, at: o); putF32(flip ? 1 - uv.y : uv.y, at: o + 4)
            }
            }
            if let uvIndex = uvIndexForGroup[index] { emitUVs(uvIndex, mesh.uvs, flip: true) }
            if let uvIndex = shadowUVIndexForGroup[index] { emitUVs(uvIndex, mesh.shadowUVs, flip: false) }
        }

        // Materials + shaders.
        emitDict(&d, groupStart: ofsMaterials, entries: zip(materialNames, matStart).map { ($0, $1) }, schedule: scheduleString)
        emitDict(&d, groupStart: ofsShaders, entries: zip(materialNames, shaderStart).map { ($0, $1) }, schedule: scheduleString)
        for (index, blob) in materialBlobs.enumerated() {
            let m = matStart[index]
            put([UInt8](blob), at: m)
            putU32(UInt32(shaderStart[index] - m), at: m) // material size, up to where its shader starts
            putS32(Int32(-m), at: m + 4)
            scheduleString(materialNames[index], fieldAt: m + 8, anchor: m)
            putU32(UInt32(index), at: m + 0xC) // material id
            putU32(0x200, at: shaderStart[index])
            putS32(Int32(-shaderStart[index]), at: shaderStart[index] + 4)
            putU32(UInt32(index), at: shaderStart[index] + 8) // shader id
            if let sampler = samplerStart[index], let texture = groups[index].material.textureName {
                scheduleString(texture, fieldAt: sampler, anchor: sampler)
                if shadowed[index], let kage = groups[index].material.shadowMap {
                    scheduleString(kage, fieldAt: sampler + 0x34, anchor: sampler + 0x34)
                }
            }
        }

        // Meshes.
        emitDict(&d, groupStart: ofsMeshes, entries: zip(meshNames, meshStart).map { ($0, $1) }, schedule: scheduleString)
        for index in groupVertices.indices {
            let m = meshStart[index]
            let isTextured = textured[index]
            let setup = setupStart[index]
            let main = mainStart[index]
            putU32(UInt32(cursorEnd(index: index, meshStart: meshStart, mainStart: mainStart, mainDLSize: mainDLSize) - m), at: m)
            putS32(Int32(-m), at: m + 4)
            putS32(0, at: m + 8) // currentMatrix: bone 0, rigid
            // The three vertex-descriptor values the setup display list below actually programs --
            // real files cache them here verbatim.
            let color16 = meshes[index].colorIndex16
            putU32(vcdLow(includeNormals: includeNormals, color16: color16), at: m + 0xC)
            let vcdHigh: UInt32 = shadowed[index] ? 0xF : (isTextured ? 3 : 0) // texcoord0 (and texcoord1) INDEX16
            putU32(vcdHigh, at: m + 0x10)
            putU32(xfVertexSpec(textured: isTextured, includeNormals: includeNormals, texcoords: shadowed[index] ? 2 : nil), at: m + 0x14)
            putU32(UInt32(setupDLSize), at: m + 0x18)
            // Second size field of the setup display-list descriptor: the byte count the runtime
            // actually walks. Every mesh in retail course_model/vrcorn_model/map_model has the
            // same 0xE0/0x80 pair here. Leaving it 0 said "process no setup commands", so the GPU
            // kept the previous draw's vertex format and read this mesh's buffers as garbage.
            putU32(0x80, at: m + 0x1C)
            putS32(Int32(setup - (m + 0x18)), at: m + 0x20)
            putU32(UInt32(mainDLSize[index]), at: m + 0x24)
            putU32(UInt32(mainDLSize[index]), at: m + 0x28)
            putS32(Int32(main - (m + 0x24)), at: m + 0x2C)
            // Which attributes each vertex carries, as bit flags. This has to list exactly the
            // attributes `vcdLow`/`cpTex` declare, it is the same fact stated twice, so it is
            // derived from them rather than written out by hand.
            putU32(attributePresenceBits(textured: isTextured, includeNormals: includeNormals, color16: color16) | (shadowed[index] ? 1 << 14 : 0), at: m + 0x30)
            putU32(0, at: m + 0x34) // zero in every retail mesh sampled
            scheduleString(meshNames[index], fieldAt: m + 0x38, anchor: m)
            putU32(UInt32(index), at: m + 0x3C)
            putU32(UInt32(primitives[index].reduce(0) { $0 + $1.verts.count }), at: m + 0x40) // vertices drawn
            putU32(UInt32(groups[index].triangles.count), at: m + 0x44)
            putU16(UInt16(index), at: m + 0x48) // position buffer index
            putU16(includeNormals ? UInt16(index) : 0xFFFF, at: m + 0x4A) // normal buffer index (0xFFFF: none, as in retail maps)
            putU16(UInt16(index), at: m + 0x4C); putU16(0xFFFF, at: m + 0x4E) // colour0 buffer index; no colour1
            for i in 0..<8 { putU16(0xFFFF, at: m + 0x50 + i * 2) }
            if let uvIndex = uvIndexForGroup[index] { putU16(UInt16(uvIndex), at: m + 0x50) }
            if let uvIndex = shadowUVIndexForGroup[index] { putU16(UInt16(uvIndex), at: m + 0x52) }
            putU16(0xFFFF, at: m + 0x60); putU16(0xFFFF, at: m + 0x62) // no fur
            putS32(Int32(meshHeaderSize), at: m + 0x64) // bone table, immediately after this header
            putU32(0, at: m + meshHeaderSize) // ...holding zero entries

            // Setup display list. Without these six commands the GPU keeps whatever vertex format
            // the previous draw left behind and reads this mesh's buffers as garbage. The layout is
            // fixed, as in every retail file and RiiStudio's writer: the game *patches this list at
            // runtime*, 10 bytes at the start, and the vertex-array pointer commands after the
            // VAT block at 0x20, so the descriptor commands go at 0x0A and the VAT at 0x20, with
            // zeros (NOPs) everywhere else. Commands written from offset 0 got overwritten at race
            // start, leaving the GPU to run the rest of the list misaligned: Dolphin logs "FIFO:
            // Unknown Opcode" and skips it, a real Wii hangs.
            let descriptorGX = GXCommandWriter()
            descriptorGX.cp(reg: 0x50, val: vcdLow(includeNormals: includeNormals, color16: color16))
            descriptorGX.cp(reg: 0x60, val: vcdHigh)
            descriptorGX.xf(address: 0x1008, value: xfVertexSpec(textured: isTextured, includeNormals: includeNormals, texcoords: shadowed[index] ? 2 : nil))
            precondition(descriptorGX.data.count == 0x20 - 0x0A - 1)
            put([UInt8](descriptorGX.data), at: setup + 0x0A)
            let vatGX = GXCommandWriter()
            vatGX.cp(reg: 0x70, val: vatGroup0)
            vatGX.cp(reg: 0x80, val: vatGroup1)
            vatGX.cp(reg: 0x90, val: vatGroup2)
            put([UInt8](vatGX.data), at: setup + 0x20) // the rest stays 0x00: runtime array pointers, then NOPs

            // Main display list: GX_TRIANGLES (0x90) and, with strips on, GX_TRIANGLESTRIP (0x98)
            // primitives, each vertex's indices in ascending attribute order (position, normal, colour0, texcoord0), position and
            // normal as 16-bit indices (a map-style mesh carries no normal index at all), colour0
            // as an 8-bit index (0, the one shared entry, unless the group is shaded per triangle).
            var o = main
            for primitive in primitives[index] {
                putU8(primitive.op, at: o)
                putU16(UInt16(primitive.verts.count), at: o + 1)
                o += 3
                for v in primitive.verts {
                    let ix = meshes[index].indices[v]
                    putU16(UInt16(ix.p), at: o); o += 2
                    if includeNormals { putU16(UInt16(ix.n), at: o); o += 2 }
                    if color16 { putU16(UInt16(ix.c), at: o); o += 2 } else { putU8(UInt8(ix.c), at: o); o += 1 }
                    if isTextured { putU16(UInt16(ix.t), at: o); o += 2 }
                    if shadowed[index] { putU16(UInt16(ix.s), at: o); o += 2 }
                }
            }
        }

        // Texture links: how the runtime finds which materials/samplers each TEX0 feeds. At load
        // it looks each entry's texture up by name (a length-prefixed NW4R name, so it must live
        // in the BRRES string pool, see `emitDict`) and patches that pointer into every
        // (material, sampler) pair the entry lists; both offsets are relative to the entry's own
        // base (its "count" field), as in retail. Earlier attempts here appeared to desync the
        // GPU FIFO in-game; the real causes were the setup display list's layout (the runtime
        // patches it, see "Setup display list" above) and names stored without their length.
        if !textureLinkOrder.isEmpty {
            emitDict(&d, groupStart: ofsTextureLinks, entries: zip(textureLinkOrder, textureLinkStart).map { ($0, $1) }, schedule: scheduleString)
            for (linkIndex, texture) in textureLinkOrder.enumerated() {
                let users = textureLinkSlots[texture] ?? []
                let base = textureLinkStart[linkIndex]
                putS32(Int32(users.count), at: base)
                for (i, user) in users.enumerated() {
                    let materialIndex = user.material
                    // Self-relative to `base`, matching retail exactly (confirmed byte-for-byte).
                    // Earlier attempts at this (both signs) reproducibly desynced the GPU, but
                    // that was before the material/TEV display list byte-diff fix above. With the
                    // TEV stream now byte-identical to retail, the material tries to
                    // sample its texture, so an unresolved (always-invalid) sampler pointer here
                    // is no longer a safe no-op, it's a real bad read. This re-enables the patch.
                    putS32(Int32(matStart[materialIndex] - base), at: base + 4 + i * 8)
                    putS32(Int32((samplerStart[materialIndex] ?? 0) + user.slot * 0x34 - base), at: base + 8 + i * 8)
                }
            }
        }

        // The names go to the container, which owns the file's one string pool. `fileSize` in the
        // header already covers exactly these bytes and nothing more, which is what a retail MDL0
        // reports too, its own names sit past the end of it.
        return Built(data: d, stringReferences: pendingStrings.map {
            BRRESStringReference(fieldOffset: $0.fieldAt, anchorOffset: $0.anchor, text: $0.text)
        })
    }

    // MARK: Vertex format constants

    /// CP register 0x50, the vertex descriptor: it tells the GPU how many bytes each vertex in the
    /// main display list occupies, so it must describe exactly what that list writes, position
    /// and normal as 16-bit indices, and nothing else.
    ///
    /// The attribute status codes are GX_NONE=0, GX_DIRECT=1, GX_INDEX8=2, GX_INDEX16=3. A prior
    /// version used status 2 for position, normal *and* color0, believing 2 meant INDEX16 and that
    /// a colour attribute should be declared. Both were wrong: status 2 is INDEX8, and no colour
    /// buffer is written at all. The GPU therefore read 3 bytes per vertex (pos8+nrm8+col8) from a
    /// list supplying 4 or 6, so every vertex after the first was decoded from the middle of its
    /// predecessor. The model still loaded, nothing in the container was malformed, and drew
    /// nothing. Verified against retail: `beginner_course.szs` mesh 0 has cpVtx=0x5400 with
    /// bytes-per-vertex 4, which decodes as INDEX8 for pos/normal/color0 plus an INDEX8 texcoord,
    /// and it has a real Colors buffer backing that declaration. This writer has no colour buffer,
    /// so it declares none; the TEV stage reads GX_COLOR_NULL (textured) or konst (untextured) and
    /// never consumes a rasterised colour.
    /// Position: INDEX16. Colour0: INDEX8. Normal: INDEX16, retail always declares colour0
    /// alongside a normal (confirmed: every one of `beginner_course.szs`'s 22 meshes that has a
    /// normal also has colour0; none use this writer's old normal-without-colour0 combination).
    /// The colour buffer itself is a single shared, unused white entry, see `colorStart`'s own
    /// comment.
    ///
    /// A map-style model (`mapStyle`, the builder's minimap path) carries *no* normal at all --
    /// retail's own map models never have a Normals section (see `MapModelBuilder`'s doc), so
    /// their descriptor is pos INDEX16 + colour0 INDEX8 (0x4600, confirmed against the disc).
    private static func vcdLow(includeNormals: Bool, color16: Bool = false) -> UInt32 {
        (3 << 9) | (UInt32(includeNormals ? 3 : 0) << 11) | (UInt32(color16 ? 3 : 2) << 13)
    }

    /// Main display-list bytes per vertex: position and normal INDEX16, colour0 INDEX8 (INDEX16
    /// past 256 colours), texcoord0 INDEX16.
    private static func bytesPerVertex(textured: Bool, includeNormals: Bool, color16: Bool) -> Int {
        2 + (includeNormals ? 2 : 0) + (color16 ? 2 : 1) + (textured ? 2 : 0)
    }

    /// The mesh header's attribute-presence bitfield at offset 0x30: bit 9 position, bit 10
    /// normal, bit 11 colour0, bit 12 colour1, bits 13+ texcoord0-7. It must name exactly the
    /// attributes the vertex descriptor declares.
    ///
    /// This was previously two constants lifted from retail, 0x2E00 when textured and 0x6A00
    /// when not, read as if they were "textured" and "untextured" variants of one mesh. They are
    /// not: in `beginner_course.szs` they belong to two different meshes with different
    /// attributes. 0x2E00 is pos+normal+colour0+texcoord0 and 0x6A00 is pos+colour0+texcoord0+
    /// texcoord1 with *no normal*, each exactly mirroring its own mesh's descriptor. Copying them
    /// claimed a colour0 this writer never supplies, and claimed no normal on precisely the meshes
    /// that do have one. Both the runtime and this app's own `MDL0Parser` read this field to work
    /// out the per-vertex layout, which is why a model built here could not be previewed.
    private static func attributePresenceBits(textured: Bool, includeNormals: Bool, color16: Bool = false) -> UInt32 {
        let vcd = vcdLow(includeNormals: includeNormals, color16: color16)
        var bits: UInt32 = 0
        if (vcd >> 9) & 3 != 0 { bits |= 1 << 9 }   // position
        if (vcd >> 11) & 3 != 0 { bits |= 1 << 10 } // normal
        if (vcd >> 13) & 3 != 0 { bits |= 1 << 11 } // colour0
        if (vcd >> 15) & 3 != 0 { bits |= 1 << 12 } // colour1
        if textured { bits |= 1 << 13 }                // texcoord0
        return bits
    }

    /// XF register 0x1008 ("vertex specification"): how many colour *attributes*, normals and
    /// texture coordinates the vertex descriptor above supplies. It counts what is in the vertex
    /// stream, not what the material computes, retail mesh 1 of `beginner_course.szs` declares
    /// normal=NONE in its CP descriptor and 0 normals here, while still shading normally. `vcdLow`
    /// now always declares one colour0 attribute (see its own comment), so this always counts 1
    /// colour, matching every real mesh that also has a normal.
    private static func xfVertexSpec(textured: Bool, includeNormals: Bool, texcoords: Int? = nil) -> UInt32 {
        (1 /* one colour attribute in the vertex stream */)
            | (UInt32(includeNormals ? 1 : 0) << 2 /* one normal, when the descriptor has one */)
            | (UInt32(texcoords ?? (textured ? 1 : 0)) << 4)
    }

    /// CP 0x70/0x80/0x90, the vertex attribute table: every attribute is float32, un-quantised.
    /// Built field by field from the published GX layout; the two unused-texcoord words come out
    /// bit-identical to a real Mario Kart Wii mesh, which is a good sign the layout is right.
    private static let vatGroup0: UInt32 =
        1 | (4 << 1) // position: XYZ, float32
        | (0 << 9) | (4 << 10) // normal: XYZ, float32
        | (1 << 13) | (5 << 14) // colour0: RGBA, rgba8, what the colour buffer holds (retail: same)
        | (1 << 17) | (5 << 18) // colour1: RGBA, rgba8 (unused; retail declares it the same way)
        | (1 << 21) | (4 << 22) // texcoord0: ST, float32
        | (1 << 30) // byte dequant
    private static let vatGroup1: UInt32 =
        (1 | (4 << 1)) | ((1 << 9) | (4 << 10)) | ((1 << 18) | (4 << 19)) | ((1 << 27) | (4 << 28))
        | (1 << 31) // vertex cache enhance
    private static let vatGroup2: UInt32 =
        ((1 << 5) | (4 << 6)) | ((1 << 14) | (4 << 15)) | ((1 << 23) | (4 << 24))

    // MARK: Helpers

    private static func cursorEnd(index: Int, meshStart: [Int], mainStart: [Int], mainDLSize: [Int]) -> Int {
        mainStart[index] + mainDLSize[index]
    }

    private static func putASCII4(_ s: String, _ d: inout Data, at offset: Int) {
        d.replaceSubrange(offset..<(offset + 4), with: Array(s.utf8))
    }

    private static func faceNormal(_ a: Vec3, _ b: Vec3, _ c: Vec3) -> Vec3 {
        let ab = Vec3(x: b.x - a.x, y: b.y - a.y, z: b.z - a.z)
        let ac = Vec3(x: c.x - a.x, y: c.y - a.y, z: c.z - a.z)
        var n = Vec3(x: ab.y * ac.z - ab.z * ac.y, y: ab.z * ac.x - ab.x * ac.z, z: ab.x * ac.y - ab.y * ac.x)
        let len = (n.x * n.x + n.y * n.y + n.z * n.z).squareRoot()
        if len > 0.000001 { n = Vec3(x: n.x / len, y: n.y / len, z: n.z / len) }
        return n
    }

    private static func dictByteSize(names: [String]) -> Int {
        8 + (names.count + 1) * 16
    }

    /// Writes one index group, including the real NW4R radix tree the Wii runtime navigates when
    /// it looks a name up (see `BRRESIndexGroup.buildTree`). Entry names go in the BRRES's shared
    /// string pool through `schedule`, as in every retail file: NW4R names are length-prefixed
    /// (`ResName`), and lookups such as the render tree's "DrawOpa" or the minimap's "posLD"
    /// compare that length. Names packed into the group itself had no length before them.
    private static func emitDict(_ d: inout Data, groupStart: Int, entries: [(name: String, target: Int)],
                                 schedule: (String, Int, Int) -> Void) {
        guard !entries.isEmpty else { return }
        func put32(_ v: UInt32, at o: Int) {
            d.replaceSubrange(o..<(o + 4), with: [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
        }
        func put16(_ v: UInt16, at o: Int) {
            d.replaceSubrange(o..<(o + 2), with: [UInt8(v >> 8), UInt8(v & 0xFF)])
        }
        let nodeAreaSize = 8 + (entries.count + 1) * 16
        put32(UInt32(nodeAreaSize), at: groupStart)
        put32(UInt32(entries.count), at: groupStart + 4)
        let tree = BRRESIndexGroup.buildTree(names: entries.map(\.name))
        put16(tree[0].id, at: groupStart + 8)
        put16(tree[0].left, at: groupStart + 12)
        put16(tree[0].right, at: groupStart + 14)
        for (i, entry) in entries.enumerated() {
            let base = groupStart + 8 + (i + 1) * 16
            put16(tree[i + 1].id, at: base)
            put16(tree[i + 1].left, at: base + 4)
            put16(tree[i + 1].right, at: base + 6)
            schedule(entry.name, base + 8, groupStart)
            put32(UInt32(entry.target - groupStart), at: base + 12)
        }
    }

    /// Builds one material immediately followed by its shader/TEV block, the same contiguous
    /// layout real files use. Returns (bytes, offset of the shader within them, offset of the
    /// sampler's texture-name field within them, or nil when untextured).
    private static func buildMaterialAndShader(spec: MaterialSpec, textured: Bool, shadowed: Bool = false) -> (Data, Int, Int?) {
        let texPlttSize = (4 + 8 * 12) + (4 + 8 * 32)
        let texSrtSize = 4 + 4 + 8 * 20 + 8 * 52
        let chanSize = 2 * 20
        let samplerSize = 0x34
        let samplerBlockStart = 0x40 + texPlttSize + texSrtSize + chanSize
        let headerEnd = samplerBlockStart + (textured ? samplerSize : 0) * (shadowed ? 2 : 1)
        // The material's own display list is a GX display list too, called directly via its
        // `ofsDisplayLists` pointer, so it has to be 32-byte aligned,
        // which means padding here before writing it. `headerEnd` itself is never a
        // multiple of 32 (it's real NW4R struct sizes: texPltt/texSrt/chan/sampler blocks), so
        // skipping this padding leaves the material's own DL unaligned, the actual cause of
        // "g3d_resmat_ac.h ... Failed assertion !((u32)p & 0x1f)", distinct from the shader
        // block's own alignment (padded separately below, after the DL).
        let headerToDLStart = (headerEnd + 31) & ~31
        var mat = Data(count: headerToDLStart)

        func putU8(_ v: UInt8, at o: Int) { mat[mat.startIndex + o] = v }
        func putU32(_ v: UInt32, at o: Int) {
            mat.replaceSubrange((mat.startIndex + o)..<(mat.startIndex + o + 4), with: [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
        }
        func putS32(_ v: Int32, at o: Int) { putU32(UInt32(bitPattern: v), at: o) }
        func putF32(_ v: Float, at o: Int) { putU32(v.bitPattern, at: o) }

        // Size/mdlOffset/name/id at 0x00-0x0F are patched by the caller once this blob's real
        // position is known.
        putU32(spec.translucent ? 0x8000_0000 : 0, at: 0x10) // flag: translucent (XLU) or opaque
        // genMode: texGens, colour channels, TEV stages, indirect stages. Both counts have to
        // agree with the XF vertex specification each mesh programs (`xfVertexSpec`), the
        // graphics processor stalls on a mismatch, so the texgen count mirrors `xfVertexSpec`'s
        // texture count: 1 for a textured material (its one sampler), 0 for an untextured one.
        // The 0 is not guessed at, all 52 retail map models on the disc declare texGens=0 for
        // their untextured material (every one is nTex=0), which the writer previously violated
        // by always writing 1: the genMode said one texgen existed while the mesh's XF spec
        // supplied none, a jaw-to-quad-pipe mismatch that manifested as the generated minimap
        // rendering blank/black in-game even though the course (textured) drew fine.
        // Every real Mario Kart Wii material also declares one colour channel here even though
        // its own TEV stage never reads it, confirmed byte-for-byte against both a retail
        // `course_model.brres` (1 in every material sampled, never 0) and every retail map model
        // (1 there too). A prior version of this writer used 0 for every material, matching no
        // real file (see `xfVertexSpec`'s doc comment: this channel is sourced from a register,
        // not the vertex stream).
        putU8(shadowed ? 2 : textured ? 1 : 0, at: 0x14); putU8(1, at: 0x15); putU8(shadowed ? 2 : 1, at: 0x16); putU8(0, at: 0x17)
        putU32(spec.cull, at: 0x18) // cullMode (0 = none, so a mesh wound either way still draws)
        putU8(spec.alphaTested ? 0 : 1, at: 0x1C) // earlyZ, off when the alpha test must run first
        putU8(0xFF, at: 0x1D) // lightSetIndex: none
        putU8(0, at: 0x1E) // fogIndex
        putU8(0, at: 0x1F)
        for i in 0..<4 { putU8(0, at: 0x20 + i) } // indMethod
        for i in 0..<4 { putU8(0xFF, at: 0x24 + i) } // normalMapLightIndices
        // Every offset below is relative to this material's own start, confirmed against a real
        // file, where ofsDisplayLists lands exactly on the 0x180-byte display list at the end.
        putS32(Int32(headerToDLStart + 0x180), at: 0x28) // ofsTev
        putU32(shadowed ? 2 : textured ? 1 : 0, at: 0x2C) // nTex
        putS32(textured ? Int32(samplerBlockStart) : 0, at: 0x30) // ofsSamplers
        putU32(0, at: 0x34) // ofsFur
        putU32(0, at: 0x38) // ofsUserData
        putS32(Int32(headerToDLStart), at: 0x3C) // ofsDisplayLists

        // texSrtData: identity SRT and identity effect matrix for all 8 slots. The leading flag word
        // (4 bits per texture: enabled, identity scale, rotation, translation. RiiStudio's
        // BuildTexMatrixFlags; retail's one-texture materials carry 0xF) is what makes the game
        // load texture matrix 0 for this material. Left 0, it never did: texcoords ran through
        // whatever matrix another object (water, karts, effects) last left in that slot, so the
        // road texture swam under a parked kart, it looked as though the kart was drifting.
        let srtBase = 0x40 + texPlttSize
        putU32(shadowed ? 0xFF : textured ? 0xF : 0, at: srtBase)
        for i in 0..<8 {
            let o = srtBase + 8 + i * 20
            putF32(1, at: o); putF32(1, at: o + 4)
        }
        let effectBase = srtBase + 8 + 8 * 20
        for i in 0..<8 {
            let o = effectBase + i * 52
            putU8(0xFF, at: o); putU8(0xFF, at: o + 1); putU8(0, at: o + 2); putU8(1, at: o + 3)
            for row in 0..<3 { putF32(1, at: o + 4 + row * 16 + row * 4) }
        }

        // Lighting channels. Every retail material (all of beginner_course's course_model and
        // map_model) carries exactly this: chan0 flag 0x3F, material colour, ambient 0x000000FF,
        // colour/alpha control 0x701 (material source = vertex colour, lighting off); chan1 flag
        // 0x0F, material 0x000000FF, controls 0. Left zero, chan0 sources a black, alpha-0
        // register, and the untextured TEV stage outputs exactly that raster colour, so a
        // generated minimap drew fully transparent.
        let chanBase = 0x40 + texPlttSize + texSrtSize
        putU32(0x3F, at: chanBase); putU32(textured ? 0xFFFF_FFFF : 0x8080_80FF, at: chanBase + 4)
        putU32(0xFF, at: chanBase + 8); putU32(0x701, at: chanBase + 12); putU32(0x701, at: chanBase + 16)
        putU32(0x0F, at: chanBase + 20); putU32(0xFF, at: chanBase + 24)

        // The one sampler. Its leading field is the texture-name offset (filled in by the caller);
        // the rest are the sane defaults a real material uses, repeat wrapping and linear
        // filtering. Left at zero these mean clamp + nearest-neighbour, which looks wrong on a
        // tiled track texture.
        if textured {
            let s = samplerBlockStart
            putU32(spec.wrap.s, at: s + 0x18) // wrap S
            putU32(spec.wrap.t, at: s + 0x1C) // wrap T
            putU32(spec.mipmapped ? 5 : 1, at: s + 0x20) // min filter: linear, or linear between mip levels
            putU32(1, at: s + 0x24) // mag filter: linear
            putF32(0, at: s + 0x28) // LOD bias
        }
        // The shadow map's sampler, as retail's: texmap/tlut 1, repeat, linear, no mips.
        if shadowed {
            let s = samplerBlockStart + samplerSize
            for o in stride(from: 0x10, through: 0x24, by: 4) { putU32(1, at: s + o) }
        }

        // MARK: Material display list, exactly 0x180 bytes, command-for-command in the same
        // order a real Mario Kart Wii material uses.
        let gx = GXCommandWriter()
        // Alpha test: always pass. Z: enabled, LEqual, writes depth. Blend: opaque, with the
        // dither/colour-update/alpha-update bits masked off so the GPU's defaults survive.
        let at = spec.alphaTest
        gx.bp(reg: 243, val: pack([(UInt32(at.1), 0, 8), (UInt32(at.4), 8, 8), (UInt32(at.0 & 7), 16, 3), (UInt32(at.3 & 7), 19, 3), (UInt32(at.2 & 3), 22, 2)]))
        gx.bp(reg: 64, val: pack([(1, 0, 1), (3, 1, 3), (spec.depthWrite ? 1 : 0, 4, 1)]))
        gx.bpMask(0xFFE3)
        // PE_CMODE0: retail's opaque value (blend off, src alpha / inverse src alpha, copy), or
        // blending on with the material's own factors.
        if let blend = spec.blend {
            gx.bp(reg: 65, val: 0x3001 | (UInt32(blend.dst & 7) << 5) | (UInt32(blend.src & 7) << 8))
        } else {
            gx.bp(reg: 65, val: 0x34A0)
        }
        gx.bp(reg: 66, val: 0)
        gx.align32()
        // TEV registers 1-3 (unused by a one-stage material). A non-konst register write is
        // repeated twice more, a documented real-hardware timing workaround real files also do.
        // Confirmed byte-for-byte against a retail material's own display list: this write is
        // *entirely* zero (r=g=b=a=0), not a=255 as a prior version of this writer had, the
        // alpha channel of an otherwise-unused register still has to match, or this display
        // list's bytes diverge from retail's from this point on.
        // A shadowed material keeps its shadow colour in register C0 (reg 1), which stage 0 fades
        // the vertex colour toward where the shadow map is dark (retail a_MainRoad_m: 4C 4C 56).
        let shadow = spec.shadowColor
        for reg in 1...3 {
            if shadowed && reg == 1 { gx.setTevColor(reg: 1, r: Int(shadow.r), g: Int(shadow.g), b: Int(shadow.b), a: 0, isKonst: false) }
            else { gx.setTevColor(reg: reg, r: 0, g: 0, b: 0, a: 0, isKonst: false) }
        }
        gx.align32()
        // Confirmed byte-for-byte against BOTH a retail textured material (course_model) and a
        // retail untextured one (map_model): K0-K3 (all four konst registers, not just the
        // "unused" K1-3) are entirely zero here in both cases. A prior version of this writer put
        // the mesh's own diffuse colour in K0 for untextured materials, believing the untextured
        // combiner read K0 directly, it doesn't. Retail's own untextured TEV_COLOR_ENV_0 (see
        // below) actually selects RASC (the rasterised/vertex colour) as an input, meaning the
        // "flat colour" for an untextured material comes from the colour0 vertex buffer this
        // writer now supplies (see `colorStart`'s own comment), not from any konst register.
        // Retail's shadowed materials also carry K3 alpha 0x80 (unread by their stages; kept so the
        // display list matches retail byte for byte).
        for reg in 0...3 { gx.setTevColor(reg: reg, r: 0, g: 0, b: 0, a: shadowed && reg == 3 ? 0x80 : 0, isKonst: true) }
        gx.align32()
        gx.bp(reg: 37, val: 0) // indirect texture coord scale 0/1
        gx.bp(reg: 38, val: 0) // indirect texture coord scale 2/3
        gx.skip(15); gx.align32()
        gx.skip(15); gx.skip(15); gx.align32()
        // Texture-coordinate generation: 18 bytes per slot, 8 slots. Slot 0 generates texcoord0
        // straight from the mesh's own texcoord0 array (source row 5) through a 2x4 matrix, the
        // same pair of XF writes, with the same values, a real file emits.
        if shadowed {
            // texcoord1 from the mesh's texcoord1 array (source row 6).
            gx.xf(address: 0x1040, value: pack([(5, 12, 3), (5, 7, 5)]))
            gx.xf(address: 0x1050, value: 0)
            gx.xf(address: 0x1041, value: pack([(5, 12, 3), (6, 7, 5)]))
            gx.xf(address: 0x1051, value: 3) // post-transform matrix row 3 (texcoord 1's), as retail
            gx.skip(18 * 6)
        } else if textured {
            gx.xf(address: 0x1040, value: pack([(5, 12, 3), (5, 7, 5)]))
            gx.xf(address: 0x1050, value: 0)
            gx.skip(18 * 7)
        } else {
            gx.skip(18 * 8)
        }
        gx.align32()
        let matDL = gx.data
        precondition(matDL.count == 0x180, "material display list must be exactly 0x180 bytes")
        mat.append(matDL)
        // The shader/TEV block that follows is itself a GX display list. NW4R asserts its
        // pointer is 32-byte aligned (g3d_resmat_ac.h) before calling it, and `headerToDLStart +
        // 0x180` is not a multiple of 32. Pad up to the boundary so `materialSize` below lands the
        // shader on one; this is what crashed every custom course with "Failed assertion
        // !((u32)p & 0x1f)" despite matStart itself always being aligned.
        while mat.count % 32 != 0 { mat.append(0) }
        let materialSize = mat.count

        // MARK: Shader/TEV block, 32-byte header then a 0x1E0 display list, 0x200 total.
        var tev = Data(count: 32)
        func putTU8(_ v: UInt8, at o: Int) { tev[tev.startIndex + o] = v }
        putTU8(shadowed ? 2 : 1, at: 12) // numStages
        for i in 0..<8 { putTU8(0xFF, at: 16 + i) } // coordToMapLut
        if textured { putTU8(0, at: 16) } // texcoord slot 0 -> texmap 0
        if shadowed { putTU8(1, at: 17) } // texcoord slot 1 -> texmap 1

        let tgx = GXCommandWriter()
        if shadowed {
            // Retail beginner_course a_MainRoad_m's stage couple 0, verbatim: stage 0 samples the
            // shadow map (texmap 1, texcoord 1) and lerps C0 -> vertex colour by it; stage 1
            // samples the texture (texmap 0, texcoord 0) and multiplies, x2.
            let retailShadowedStageCouple0: [UInt8] = [
                0x61, 0xfe, 0x00, 0x00, 0x0f, 0x61, 0xf6, 0x00, 0x00, 0x04,
                0x61, 0xfe, 0x00, 0x00, 0x0f, 0x61, 0xf7, 0x00, 0x00, 0x0e,
                0x61, 0xfe, 0x00, 0x00, 0x0f, 0x61, 0xf8, 0x00, 0x00, 0x00,
                0x61, 0xfe, 0x00, 0x00, 0x0f, 0x61, 0xf9, 0x00, 0x00, 0x0c,
                0x61, 0xfe, 0x00, 0x00, 0x0f, 0x61, 0xfa, 0x00, 0x00, 0x05,
                0x61, 0xfe, 0x00, 0x00, 0x0f, 0x61, 0xfb, 0x00, 0x00, 0x0d,
                0x61, 0xfe, 0x00, 0x00, 0x0f, 0x61, 0xfc, 0x00, 0x00, 0x0a,
                0x61, 0xfe, 0x00, 0x00, 0x0f, 0x61, 0xfd, 0x00, 0x00, 0x0e,
                0x61, 0x27, 0xff, 0xff, 0xff,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x61, 0xfe, 0xff, 0xff, 0xf0,
                0x61, 0xf6, 0xff, 0xff, 0xf0,
                0x61, 0x28, 0x04, 0x00, 0x49,
                0x61, 0xc0, 0x08, 0x2a, 0x8f,
                0x61, 0xc2, 0x18, 0xf8, 0x0f,
                0x61, 0xc1, 0x08, 0xf2, 0xf0,
                0x61, 0xc3, 0x08, 0x1f, 0xf0,
                0x61, 0x10, 0x00, 0x00, 0x00,
                0x61, 0x11, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00,
            ]
            precondition(retailShadowedStageCouple0.count == 0x60 + 48)
            tgx.data.append(contentsOf: retailShadowedStageCouple0)
        } else if textured {
            // This entire region (swap tables, indirect texture order, stage-couple-0 konst
            // select, RAS1_TREF0, and both TEV_COLOR/ALPHA_ENV_0) is emitted as retail's own
            // exact bytes, verbatim, rather than hand-packed bitfields, a byte-for-byte diff
            // against a real textured `course_model.brres` material found several of the
            // hand-packed values here were wrong (the swap-table entries were never actually
            // identity, reg 0x27's "nothing indirect" was 0xFFFFFF not 0x000000, the konst-select
            // packing at reg 0xF6 differed, and both TEV_COLOR_ENV_0/TEV_ALPHA_ENV_0 differed) --
            // wrong enough to reproducibly desync the GPU command FIFO in-game despite every
            // structural/GX-decode check in this app passing, since those checks only validate
            // opcode syntax, not register semantics. Untextured materials keep the hand-packed
            // path below; they're unverified against a retail sample but were never implicated by
            // this diff, so left alone.
            let retailTexturedStageCouple0: [UInt8] = [
                0x61, 0xfe, 0x00, 0x00, 0x0f, 0x61, 0xf6, 0x00, 0x00, 0x04,
                0x61, 0xfe, 0x00, 0x00, 0x0f, 0x61, 0xf7, 0x00, 0x00, 0x0e,
                0x61, 0xfe, 0x00, 0x00, 0x0f, 0x61, 0xf8, 0x00, 0x00, 0x00,
                0x61, 0xfe, 0x00, 0x00, 0x0f, 0x61, 0xf9, 0x00, 0x00, 0x0c,
                0x61, 0xfe, 0x00, 0x00, 0x0f, 0x61, 0xfa, 0x00, 0x00, 0x05,
                0x61, 0xfe, 0x00, 0x00, 0x0f, 0x61, 0xfb, 0x00, 0x00, 0x0d,
                0x61, 0xfe, 0x00, 0x00, 0x0f, 0x61, 0xfc, 0x00, 0x00, 0x0a,
                0x61, 0xfe, 0x00, 0x00, 0x0f, 0x61, 0xfd, 0x00, 0x00, 0x0e,
                0x61, 0x27, 0xff, 0xff, 0xff,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x61, 0xfe, 0xff, 0xff, 0xf0,
                0x61, 0xf6, 0x00, 0x38, 0xc0,
                0x61, 0x28, 0x3b, 0xf0, 0x40,
                0x61, 0xc0, 0x18, 0xf8, 0xaf, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x61, 0xc1, 0x08, 0xf2, 0xf0, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x61, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            ]
            precondition(retailTexturedStageCouple0.count == 0x60 + 48)
            tgx.data.append(contentsOf: retailTexturedStageCouple0)
        } else {
            // Same treatment as the textured branch above, now verified against a retail
            // *untextured* material (`map_model.brres`'s own, byte-for-byte)
            // at. It's identical to the textured bytes except for RAS1_TREF0 (reg 0x28) and both
            // TEV_COLOR/ALPHA_ENV_0 (reg 0xC0/0xC1), decoding those confirms the untextured
            // combiner's real input isn't KONST at all, it's RASC (the rasterised/vertex colour),
            // which is why `colorStart` above supplies a real colour0 buffer rather than this
            // writer relying on K0 the way a previous version incorrectly did.
            let retailUntexturedStageCouple0: [UInt8] = [
                0x61, 0xfe, 0x00, 0x00, 0x0f, 0x61, 0xf6, 0x00, 0x00, 0x04,
                0x61, 0xfe, 0x00, 0x00, 0x0f, 0x61, 0xf7, 0x00, 0x00, 0x0e,
                0x61, 0xfe, 0x00, 0x00, 0x0f, 0x61, 0xf8, 0x00, 0x00, 0x00,
                0x61, 0xfe, 0x00, 0x00, 0x0f, 0x61, 0xf9, 0x00, 0x00, 0x0c,
                0x61, 0xfe, 0x00, 0x00, 0x0f, 0x61, 0xfa, 0x00, 0x00, 0x05,
                0x61, 0xfe, 0x00, 0x00, 0x0f, 0x61, 0xfb, 0x00, 0x00, 0x0d,
                0x61, 0xfe, 0x00, 0x00, 0x0f, 0x61, 0xfc, 0x00, 0x00, 0x0a,
                0x61, 0xfe, 0x00, 0x00, 0x0f, 0x61, 0xfd, 0x00, 0x00, 0x0e,
                0x61, 0x27, 0xff, 0xff, 0xff,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x61, 0xfe, 0xff, 0xff, 0xf0,
                0x61, 0xf6, 0x00, 0x38, 0xc0,
                0x61, 0x28, 0x3b, 0xf0, 0x3f,
                0x61, 0xc0, 0x08, 0xaf, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x61, 0xc1, 0x08, 0xbf, 0xf0, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x61, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            ]
            precondition(retailUntexturedStageCouple0.count == 0x60 + 48)
            tgx.data.append(contentsOf: retailUntexturedStageCouple0)
        }
        precondition(tgx.data.count == 0x60 + 48, "one stage couple must add exactly 48 bytes")
        tgx.skip(48 * 7) // stages 2-15, filler
        precondition(tgx.data.count == 0x1E0, "TEV display list must be exactly 0x1E0 bytes")
        tev.append(tgx.data)
        precondition(tev.count == 0x200)

        mat.append(tev)
        return (mat, materialSize, textured ? samplerBlockStart : nil)
    }

    /// Packs `(value, bitOffset, bitWidth)` tuples into one register word. Traps on a value that
    /// doesn't fit or fields that overlap, so a mistyped shift fails at the moment it's written
    /// rather than silently miscoding a GPU register.
    private static func pack(_ fields: [(value: UInt32, bit: Int, width: Int)]) -> UInt32 {
        var result: UInt32 = 0
        var used: UInt32 = 0
        for (value, bit, width) in fields {
            precondition(value < (1 << width), "field value \(value) doesn't fit \(width) bits")
            let mask = ((UInt32(1) << width) - 1) << bit
            precondition(used & mask == 0, "overlapping bit field at bit \(bit)")
            used |= mask
            result |= (value << bit) & mask
        }
        return result
    }
}

/// Minimal GX display-list command encoder: BP/CP/XF register writes in the exact wire format
/// this app's MDL0 reader already decodes out of real files.
private nonisolated class GXCommandWriter {
    var data = Data()

    func bp(reg: Int, val: UInt32) {
        let packed = (val & 0xFFFFFF) | (UInt32(reg & 0xFF) << 24)
        data.append(0x61)
        data.append(contentsOf: [UInt8((packed >> 24) & 0xFF), UInt8((packed >> 16) & 0xFF), UInt8((packed >> 8) & 0xFF), UInt8(packed & 0xFF)])
    }
    func bpMask(_ mask: UInt32) { bp(reg: 254, val: mask) }

    /// CP register write: tag, register, 32-bit value.
    func cp(reg: UInt8, val: UInt32) {
        data.append(0x08)
        data.append(reg)
        data.append(contentsOf: [UInt8((val >> 24) & 0xFF), UInt8((val >> 16) & 0xFF), UInt8((val >> 8) & 0xFF), UInt8(val & 0xFF)])
    }

    /// XF register write: tag, (count - 1), address, then that many 32-bit values. Only ever one
    /// value here.
    func xf(address: UInt16, value: UInt32) {
        data.append(0x10)
        data.append(contentsOf: [0x00, 0x00])
        data.append(contentsOf: [UInt8(address >> 8), UInt8(address & 0xFF)])
        data.append(contentsOf: [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    func skip(_ n: Int) { data.append(Data(count: n)) }
    func align32() { while data.count % 32 != 0 { data.append(0) } }

    func setTevColor(reg: Int, r: Int, g: Int, b: Int, a: Int, isKonst: Bool) {
        let type: UInt32 = isKonst ? 1 : 0
        let low: UInt32 = (UInt32(r) & 0x7FF) | ((UInt32(a) & 0x7FF) << 12) | (type << 23)
        let high: UInt32 = (UInt32(b) & 0x7FF) | ((UInt32(g) & 0x7FF) << 12) | (type << 23)
        bp(reg: 224 + reg * 2, val: low)
        bp(reg: 225 + reg * 2, val: high)
        if !isKonst {
            bp(reg: 225 + reg * 2, val: high)
            bp(reg: 225 + reg * 2, val: high)
        }
    }
}
