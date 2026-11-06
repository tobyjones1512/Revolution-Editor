import Foundation
import simd

/// Real MDL0 mesh geometry, unlike the rest of this codebase's BRRES support (which is a
/// from-scratch reimplementation from public docs), this parser's exact byte layout was verified
/// against `riidefi/RiiStudio`'s actual binary reader source (`librii/g3d/io/{ModelIO,PolygonIO}`)
/// and a real Nintendo-built sample (`kuribo.brres`), see the doc comments below
/// for the specific fields that came from that source. Only MDL0 version 11 (what Mario Kart Wii
/// and most Wii-era titles use) is supported; anything else fails to parse and the caller falls
/// back to the textures-only preview.
///
/// Enveloped (skinned) meshes come out in the model's bind pose with per-vertex bone weights;
/// a rigid mesh stays relative to its bone (`MDL0Mesh.matrixId`). What's deliberately not
/// implemented: NBT-encoded normals, single-component UVs, and per-stage TEV texture combining
/// (`textureName` below is a mesh's material's *first* sampler only, real materials can layer
/// several textures via TEV stages, which isn't emulated). Every one of those simply causes that
/// piece of data to be skipped/nil at, so a partially-understood model
/// degrades instead of rendering wrong.
nonisolated struct MDL0Vertex {
    var position: Vec3
    var normal: Vec3?
    var uv0: Vec2?
    /// Second UV set, lightmapped course materials (a `kage` shadow map plus the ground's own
    /// texture) give each sampler its own.
    var uv1: Vec2?
    /// Colour0, 0-1 RGBA (the game's course shader multiplies it into the texture x2).
    var color: SIMD4<Float>?
    /// For an enveloped mesh: the draw matrix this vertex uses (from its position-matrix index),
    /// then, once the model's bones are known, the bones and weights that move it.
    var drawMatrix: Int?
    var weights: [(bone: Int, weight: Float)] = []
}

nonisolated struct MDL0Mesh {
    var name: String
    /// Flattened triangle list (count is always a multiple of 3), ready to hand to a renderer.
    var vertices: [MDL0Vertex]
    /// This mesh's actual texture, resolved the way the real engine does it: RenderTree's
    /// DrawOpa/DrawXlu bytecode says which material draws this mesh, and that material's first
    /// TEV sampler names the TEX0, not guessed by matching names, an authentic material link.
    /// Nil if this mesh has no draw call, or its material has no sampler (rare, but real: e.g. a
    /// pure vertex-color material).
    var textureName: String?
    /// Every sampler's texture in that material, in slot order (`textureName` is the first).
    var textureNames: [String] = []
    /// The drawing material's name (what SRT0/CLR0/PAT0 animations target).
    var materialName: String?
    /// The drawing material, decoded (wraps, texture matrices, texgens, alpha state).
    var material: MDL0Material?
    /// The bone whose matrix places this mesh (the header's current matrix, matched to a bone's
    /// matrix id): a rigid mesh's vertices are relative to that bone. -1 for an enveloped mesh,
    /// whose vertices are already in the model's bind pose.
    var matrixId: Int = 0
}

/// One MDL0 bone (node), as `MDL0SceneKit` needs it to place and animate meshes. Layout per
/// RiiStudio's BoneIO and Wiimm's `mdl_sect1_t`: id 0x0C, matrix id 0x10, flags 0x14, billboard
/// 0x18, scale 0x20, rotation (degrees) 0x2C, translation 0x38, parent offset 0x5C.
nonisolated struct MDL0Bone {
    var name: String
    var matrixId: Int
    /// Index into the model's bones, nil for a root.
    var parent: Int?
    var scale: Vec3
    var rotation: Vec3
    var translation: Vec3
    /// 0 none, 1 standard, 2 perspective, 3 rotation, 4 perspective rotation, 5 Y, 6 perspective Y.
    var billboard: UInt32

    /// NW4R's bone matrix: scale, then rotate X, Y, Z (degrees), then translate.
    static func matrix(scale s: Vec3, rotation r: Vec3, translation t: Vec3) -> simd_float4x4 {
        let rad = Float.pi / 180
        let rx = simd_quatf(angle: r.x * rad, axis: [1, 0, 0]), ry = simd_quatf(angle: r.y * rad, axis: [0, 1, 0])
        let rz = simd_quatf(angle: r.z * rad, axis: [0, 0, 1])
        var m = simd_float4x4(rz * ry * rx) * simd_float4x4(diagonal: [s.x, s.y, s.z, 1])
        m.columns.3 = [t.x, t.y, t.z, 1]
        return m
    }
}

/// One MDL0 material, decoded only as far as this app's preview needs: its name (for logging/
/// matching) and its TEV samplers' texture names in slot order, everything else a real material
/// carries (TEV stages, blend/alpha state, texture matrices, lighting channels) is display state
/// this app doesn't render, so it's not parsed. Layout verified against RiiStudio's
/// `librii/g3d/io/MatIO.{hpp,cpp}` (`BinaryMaterial::read`, `BinarySampler::read`): a material
/// starts size(u32) mdlOffset(s32) nameOfs(s32) id(u32) flag(u32), then genMode(8B) + misc(12B)
/// bring it to 0x28, then ofsTev(s32)@0x28 nTex(u32)@0x2C ofsSamplers(s32)@0x30 (both offsets
/// relative to this material's own start). Each sampler is a fixed 0x34 bytes, textureNameOfs(s32,
/// relative to *that sampler's* own start) first.
nonisolated struct MDL0Material {
    var name: String
    var textureNames: [String]
    /// Each sampler's GX wrap (0 clamp, 1 repeat, 2 mirror), in slot order.
    var wraps: [(s: UInt8, t: UInt8)] = []
    /// Each texture matrix's SRT (Maya mode), nil where the material leaves it off.
    var texSRT: [TexSRT?] = []
    /// Each texgen's UV set (TEX0 = 0, ...), nil when it isn't generated from a UV set
    /// (environment or projection mapping).
    var texCoordSource: [Int?] = []
    /// Drawn in the translucent pass (material flag 0x80000000) with blending on.
    var blends = false
    /// The alpha compare can reject pixels (it isn't "always pass").
    var alphaTest = false

    struct TexSRT { var scale: Vec2, rotationDegrees: Float, translation: Vec2 }
}

nonisolated struct MDL0Model {
    var name: String
    var meshes: [MDL0Mesh]
    var bones: [MDL0Bone] = []

    var boundsMin: Vec3 {
        var m = Vec3(x: .greatestFiniteMagnitude, y: .greatestFiniteMagnitude, z: .greatestFiniteMagnitude)
        for mesh in meshes { for v in mesh.vertices {
            m.x = min(m.x, v.position.x); m.y = min(m.y, v.position.y); m.z = min(m.z, v.position.z)
        } }
        return m
    }
    var boundsMax: Vec3 {
        var m = Vec3(x: -.greatestFiniteMagnitude, y: -.greatestFiniteMagnitude, z: -.greatestFiniteMagnitude)
        for mesh in meshes { for v in mesh.vertices {
            m.x = max(m.x, v.position.x); m.y = max(m.y, v.position.y); m.z = max(m.z, v.position.z)
        } }
        return m
    }
}

nonisolated enum MDL0Parser {
    /// Top-level entry point. Returns nil for anything this parser doesn't confidently
    /// understand (wrong magic/version, missing sections, unsupported vertex encodings) rather
    /// than risk rendering incorrect geometry.
    ///
    /// `rawFile` is the *whole* file `resource` came from (`BRRESDocument.rawData`), needed
    /// only to resolve sampler texture-name string references, which (confirmed against a real
    /// course.brres from a real MKWii disc, not assumed) point outside this MDL0 resource's own
    /// byte range: they're offsets from this resource's absolute position in the whole file, not
    /// from its own local start, because BRRES materials share one string pool across the whole
    /// container rather than each resource carrying its own. See `parseMaterials`.
    static func parse(_ resource: BRRESResource, rawFile: Data) -> MDL0Model? {
        guard resource.magic == "MDL0" else { return nil }
        let d = resource.data
        // Header: "MDL0"(4) + fileSize(4) + version(4) + ofsBRRES(4) + 14 section offsets(4 each).
        guard d.count >= 0x10 + 14 * 4, d.asciiString(at: 0, length: 4) == "MDL0" else { return nil }
        guard d.be32(8) == 11 else { return nil } // Only version 11 (MKWii and most Wii titles) is handled.

        func secOfs(_ i: Int) -> Int { Int(Int32(bitPattern: d.be32(0x10 + i * 4))) }
        // Section order verified against RiiStudio's ModelIO.cpp `secOfs` union:
        // [0]=RenderTree [1]=Bones [2]=Positions [3]=Normals [4]=Colors [5]=UVs
        // [6]=FurVec [7]=FurPos [8]=Materials [9]=Shaders [10]=Meshes [11]=TextureLinks
        // [12]=PaletteLinks [13]=UserData
        let ofsRenderTree = secOfs(0), ofsPositions = secOfs(2), ofsNormals = secOfs(3), ofsUVs = secOfs(5)
        let ofsMaterials = secOfs(8), ofsMeshes = secOfs(10)

        // Every dictionary inside an MDL0 names into the file-wide string pool, not into the
        // resource's own bytes, the same thing `parseMeshTextureLinks` already accounts for.
        // Reading them locally happened to work only for models this app wrote before it kept its
        // strings where a retail file does, and left every mesh and buffer nameless in a real one.
        let names = (wholeFile: rawFile, offset: resource.fileOffset)

        func buffers<T>(_ ofs: Int, _ parseOne: (Int) -> T?) -> [T?] {
            guard ofs != 0, ofs > 0, ofs < d.count else { return [] }
            return BRRESIndexGroup.parse(d, groupStart: ofs, names: names).map { parseOne($0.dataOffset) }
        }

        let positionBuffers = buffers(ofsPositions) { parsePositions(d, start: $0) }
        let normalBuffers = buffers(ofsNormals) { parseNormals(d, start: $0) }
        let uvBuffers = buffers(ofsUVs) { parseUVs(d, start: $0) }
        let colorBuffers = buffers(secOfs(4)) { parseColors(d, start: $0) }

        let materials = parseMaterials(d, ofs: ofsMaterials, rawFile: rawFile, fileOffset: resource.fileOffset)
        let meshLinks = parseMeshTextureLinks(d, renderTreeOfs: ofsRenderTree, materials: materials,
                                               rawFile: rawFile, fileOffset: resource.fileOffset)

        guard ofsMeshes > 0, ofsMeshes < d.count else { return nil }
        let meshEntries = BRRESIndexGroup.parse(d, groupStart: ofsMeshes, names: names)
        guard !meshEntries.isEmpty else { return nil }

        var meshes: [MDL0Mesh] = []
        for (_, entry) in meshEntries.enumerated() {
            guard let result = parseOneMesh(d, meshStart: entry.dataOffset,
                                               positionBuffers: positionBuffers,
                                               normalBuffers: normalBuffers,
                                               uvBuffers: uvBuffers, colorBuffers: colorBuffers), !result.vertices.isEmpty else { continue }
            let link = meshLinks[result.id]
            let textures = link?.textures ?? []
            meshes.append(MDL0Mesh(name: entry.name, vertices: result.vertices, textureName: textures.first, textureNames: textures,
                                   materialName: link?.material?.name, material: link?.material, matrixId: Int(Int32(bitPattern: d.be32(entry.dataOffset + 8)))))
        }
        guard !meshes.isEmpty else { return nil }
        let bones = parseBones(d, ofs: secOfs(1), names: names)
        resolveEnvelopes(&meshes, bones: bones, mixes: parseNodeMix(d, renderTreeOfs: ofsRenderTree, names: names))
        return MDL0Model(name: resource.name, meshes: meshes, bones: bones)
    }

    /// Just the material list (name + its samplers' texture names), without parsing any mesh
    /// geometry, what `SRT0DetailView` needs to resolve an SRT0 material's name to the actual
    /// texture its live preview should transform, reusing the exact same offset resolution `parse`
    /// itself uses rather than duplicating it.
    static func materials(in resource: BRRESResource, rawFile: Data) -> [MDL0Material] {
        guard resource.magic == "MDL0" else { return [] }
        let d = resource.data
        guard d.count >= 0x10 + 14 * 4, d.asciiString(at: 0, length: 4) == "MDL0", d.be32(8) == 11 else { return [] }
        func secOfs(_ i: Int) -> Int { Int(Int32(bitPattern: d.be32(0x10 + i * 4))) }
        return parseMaterials(d, ofs: secOfs(8), rawFile: rawFile, fileOffset: resource.fileOffset)
    }

    /// One UV buffer's raw on-disk identity, enough for `UVMapEditorView` to both show a mesh's
    /// real UV coordinates and patch edited ones straight back into `resource.data`, byte-for-byte
    /// in place, the same "known-safe fixed-width field patch" approach `Data.setU8`/`setBE16` etc.
    /// already document as this app's accepted pattern for formats (like BRLYT) it deliberately
    /// doesn't fully re-serialize. Multiple meshes can share one UV buffer (the format dedupes
    /// identical UV sets); editing patches the shared buffer, so every mesh using it changes too --
    /// the same thing editing it in a real modeling tool would do.
    struct UVBufferRef {
        let byteOffset: Int // absolute offset (within resource.data) of entry 0's first component
        let componentCount: Int // 1 (U only) or 2 (UV)
        let type: UInt32
        let divisor: UInt32
        let entries: [Vec2]
    }

    /// Finds the named mesh's first UV channel (`uvIdx[0]`, the only one this app's own geometry
    /// preview reads either, see `MDL0Vertex.uv0`) and resolves it to a real buffer. `nil` when
    /// the mesh doesn't exist, has no UV channel, or the buffer can't be read.
    static func uvBuffer(forMeshNamed meshName: String, in resource: BRRESResource, rawFile: Data) -> UVBufferRef? {
        guard resource.magic == "MDL0" else { return nil }
        let d = resource.data
        guard d.count >= 0x10 + 14 * 4, d.asciiString(at: 0, length: 4) == "MDL0", d.be32(8) == 11 else { return nil }
        func secOfs(_ i: Int) -> Int { Int(Int32(bitPattern: d.be32(0x10 + i * 4))) }
        let ofsUVs = secOfs(5), ofsMeshes = secOfs(10)
        let names = (wholeFile: rawFile, offset: resource.fileOffset)

        guard ofsMeshes > 0, ofsMeshes < d.count else { return nil }
        guard let meshEntry = BRRESIndexGroup.parse(d, groupStart: ofsMeshes, names: names).first(where: { $0.name == meshName }) else { return nil }
        let meshStart = meshEntry.dataOffset
        guard meshStart >= 0, meshStart + 0x68 <= d.count else { return nil }
        let uvSlot0 = Int(d.beInt16(meshStart + 0x50)) // uvIdx[0], see parseOneMesh's header doc comment
        guard uvSlot0 >= 0 else { return nil } // -1 ("no channel") is stored as 0xFFFF

        guard ofsUVs > 0, ofsUVs < d.count else { return nil }
        let uvBufferEntries = BRRESIndexGroup.parse(d, groupStart: ofsUVs, names: names)
        guard uvBufferEntries.indices.contains(uvSlot0) else { return nil }
        let bufStart = uvBufferEntries[uvSlot0].dataOffset
        guard bufStart >= 0, bufStart + 0x20 <= d.count, let entries = parseUVs(d, start: bufStart) else { return nil }

        let startOfs = Int(Int32(bitPattern: d.be32(bufStart + 0x08)))
        let compCount = d.be32(bufStart + 0x14)
        let type = d.be32(bufStart + 0x18)
        var divisor = UInt32(d.u8(bufStart + 0x1C))
        if type == 4 { divisor = 0 }
        let byteOffset = bufStart + startOfs
        guard byteOffset >= 0 else { return nil }
        return UVBufferRef(byteOffset: byteOffset, componentCount: compCount == 0 ? 1 : 2, type: type, divisor: divisor, entries: entries)
    }

    /// The exact inverse of `decodeComponent`, patching `newValues` (must be the same count as
    /// `ref.entries`) back into `data` at `ref.byteOffset` using the buffer's own original
    /// type/divisor, an in-place patch, not a re-emit, so nothing else about the file changes.
    static func writeUVBuffer(_ ref: UVBufferRef, newValues: [Vec2], into data: inout Data) {
        guard newValues.count == ref.entries.count else { return }
        let scale = Float(1 << min(ref.divisor, 30))
        var pos = ref.byteOffset
        func put(_ value: Float) {
            switch ref.type {
            case 0: data.setU8(UInt8(clamping: Int((value * scale).rounded())), at: pos); pos += 1
            case 1: data.setU8(UInt8(bitPattern: Int8(clamping: Int((value * scale).rounded()))), at: pos); pos += 1
            case 2: data.setBE16(UInt16(clamping: Int((value * scale).rounded())), at: pos); pos += 2
            case 3: data.setBE16(UInt16(bitPattern: Int16(clamping: Int((value * scale).rounded()))), at: pos); pos += 2
            default: data.setBEFloat32(value, at: pos); pos += 4
            }
        }
        for v in newValues {
            put(v.x)
            if ref.componentCount == 2 { put(v.y) }
        }
    }

    // MARK: Materials / real texture linking

    /// Sampler texture-name string offsets are *not* relative to this MDL0 resource's own local
    /// byte range, confirmed against a real `course_model.brres` pulled live off a real MKWii
    /// disc (see [[reference-no-test-assets]]): a first attempt reading them as
    /// `sampStart + texNameOfs` (matching every other offset in this format) always landed either
    /// out of bounds or on garbage. Dumping the raw bytes showed the *material's own* name offset
    /// and a *sampler's* texture-name offset, from two different local anchors, resolving to the
    /// exact same target address once each was added to its own anchor, meaning both really are
    /// self-relative, just against the sampler/material's position in the *whole original file*
    /// (`rawFile`, at `fileOffset + sampStart`), not this resource's local start. That target
    /// address (computed purely from the file's own internal offsets) then landed inside `rawFile`
    /// exactly where a real, sane material name ("ef_dushBoard") was sitting, confirming this
    /// reading rather than assuming it. This matches how BRRES shares one string pool across a
    /// whole container instead of giving each resource its own.
    private static func parseMaterials(_ d: Data, ofs: Int, rawFile: Data, fileOffset: Int) -> [MDL0Material] {
        guard ofs != 0, ofs > 0, ofs < d.count else { return [] }
        return BRRESIndexGroup.parse(d, groupStart: ofs, names: (rawFile, fileOffset)).map { entry in
            let matStart = entry.dataOffset
            guard matStart >= 0, matStart + 0x34 <= d.count else { return MDL0Material(name: entry.name, textureNames: []) }
            let nTex = Int(d.be32(matStart + 0x2C))
            let ofsSamplers = Int(Int32(bitPattern: d.be32(matStart + 0x30)))
            guard nTex > 0, nTex <= 8, ofsSamplers != 0 else { return MDL0Material(name: entry.name, textureNames: []) }
            var textures: [String] = []
            for i in 0..<nTex {
                let sampStart = matStart + ofsSamplers + i * 0x34
                guard sampStart >= 0, sampStart + 4 <= d.count else { break }
                let texNameOfs = Int(Int32(bitPattern: d.be32(sampStart)))
                let strAt = fileOffset + sampStart + texNameOfs
                guard strAt >= 0, strAt < rawFile.count else { continue }
                let name = rawFile.asciiString(at: strAt, length: rawFile.count - strAt)
                guard !name.isEmpty else { continue }
                textures.append(name)
            }
            var m = MDL0Material(name: entry.name, textureNames: textures)
            // Layout per RiiStudio's BinaryMaterial/BinarySampler (librii/g3d/io/MatIO).
            for i in 0..<nTex {
                let s = matStart + ofsSamplers + i * 0x34
                guard s + 0x20 <= d.count else { break }
                m.wraps.append((UInt8(clamping: d.be32(s + 0x18)), UInt8(clamping: d.be32(s + 0x1C))))
            }
            if matStart + 0x1B0 + 8 * 0x14 <= d.count {
                let flag = d.be32(matStart + 0x1A8)
                m.texSRT = (0..<nTex).map { i in
                    guard (flag >> (i * 4)) & 1 != 0 else { return nil }
                    let o = matStart + 0x1B0 + i * 0x14
                    return .init(scale: Vec2(x: d.beFloat32(o), y: d.beFloat32(o + 4)), rotationDegrees: d.beFloat32(o + 8),
                                 translation: Vec2(x: d.beFloat32(o + 12), y: d.beFloat32(o + 16)))
                }
            }
            m.blends = d.be32(matStart + 0x10) & 0x8000_0000 != 0
            // The material display list: BP pixel state, then XF texgens.
            let dl = matStart + Int(Int32(bitPattern: d.be32(matStart + 0x3C)))
            var texGens: [Int?] = Array(0..<nTex), blendOn = false, pos = dl
            while pos < min(d.count, dl + 0x200) {
                switch d.u8(pos) {
                case 0x61 where pos + 5 <= d.count:
                    let reg = d.u8(pos + 1), v = d.be32(pos + 1) & 0xFFFFFF
                    if reg == 0xF3 { // alpha compare: comp0 bits 16-18, comp1 19-21, op 22-23 (7 = always)
                        let c0 = (v >> 16) & 7, c1 = (v >> 19) & 7, op = (v >> 22) & 3
                        let pass0 = c0 == 7, pass1 = c1 == 7
                        m.alphaTest = !(op == 0 ? pass0 && pass1 : op == 1 ? pass0 || pass1 : false)
                    }
                    if reg == 0x41 { blendOn = v & 1 != 0 }
                    pos += 5
                case 0x10 where pos + 5 <= d.count:
                    let count = Int(d.be16(pos + 1)) + 1, addr = Int(d.be16(pos + 3))
                    for k in 0..<count where pos + 5 + k * 4 + 4 <= d.count {
                        let r = addr + k - 0x1040
                        if r >= 0, r < nTex { // texgen: source row bits 7-11 (5 + n = TEXn), type bits 4-6 (0 regular)
                            let v = d.be32(pos + 5 + k * 4), row = Int((v >> 7) & 0x1F)
                            texGens[r] = (v >> 4) & 7 == 0 && row >= 5 ? row - 5 : nil
                        }
                    }
                    pos += 5 + count * 4
                case 0x08: pos += 6
                default: pos += 1 // NOP / padding
                }
            }
            m.texCoordSource = texGens
            m.blends = m.blends && blendOn
            return m
        }
    }

    /// Walks RenderTree's `DrawOpa`/`DrawXlu` bytecode entries (the two dictionary nodes that
    /// actually contain `Draw` commands, `NodeTree`/`NodeMix` are bone-hierarchy bookkeeping,
    /// not draw calls) to build mesh-index -> texture-name, exactly how the real engine resolves
    /// what a mesh is drawn with. Command encoding verified against RiiStudio's
    /// `ByteCodeLists::ParseStream` (`librii/g3d/io/ModelIO.hpp`): a stream is a flat run of
    /// 1-byte-tagged, unaligned commands (`Draw` = matId(u16) polyId(u16) boneId(u16) prio(u8))
    /// terminated by a Return tag: NoOp=0 Return=1 NodeDescendence=2(+4B) NodeMixing=3(+3B then
    /// numBlend*6B) Draw=4(+7B) EnvelopeMatrix=5(+4B); MatrixCopy=6 doesn't appear in real files
    /// (RiiStudio itself rejects it), so hitting it (or any other tag) just stops this mesh's scan
    /// safely rather than risk misreading the rest of the stream.
    private static func parseBones(_ d: Data, ofs: Int, names: (wholeFile: Data, offset: Int)) -> [MDL0Bone] {
        guard ofs > 0, ofs < d.count else { return [] }
        let entries = BRRESIndexGroup.parse(d, groupStart: ofs, names: names).filter { $0.dataOffset > 0 && $0.dataOffset + 0xD0 <= d.count }
        let starts = entries.map(\.dataOffset)
        return entries.map { e in
            let b = e.dataOffset
            func v(_ o: Int) -> Vec3 { Vec3(x: d.beFloat32(b + o), y: d.beFloat32(b + o + 4), z: d.beFloat32(b + o + 8)) }
            let parentOfs = Int(Int32(bitPattern: d.be32(b + 0x5C)))
            return MDL0Bone(name: e.name, matrixId: Int(d.be32(b + 0x10)),
                            parent: parentOfs == 0 ? nil : starts.firstIndex(of: b + parentOfs),
                            scale: v(0x20), rotation: v(0x2C), translation: v(0x38), billboard: d.be32(b + 0x18))
        }
    }

    /// RenderTree's `NodeMix`: each envelope draw matrix's (bone draw matrix, weight) blend.
    private static func parseNodeMix(_ d: Data, renderTreeOfs: Int, names: (wholeFile: Data, offset: Int)) -> [Int: [(Int, Float)]] {
        guard renderTreeOfs > 0, renderTreeOfs < d.count else { return [:] }
        guard let entry = BRRESIndexGroup.parse(d, groupStart: renderTreeOfs, names: names).first(where: { $0.name == "NodeMix" }) else { return [:] }
        var out: [Int: [(Int, Float)]] = [:]
        var pos = entry.dataOffset
        loop: while pos >= 0, pos < d.count {
            let tag = d.u8(pos); pos += 1
            switch tag {
            case 0: continue
            case 2: pos += 4
            case 3:
                guard pos + 3 <= d.count else { break loop }
                let mtx = Int(d.be16(pos)), n = Int(d.u8(pos + 2))
                pos += 3
                guard pos + n * 6 <= d.count else { break loop }
                out[mtx] = (0..<n).map { (Int(d.be16(pos + $0 * 6)), d.beFloat32(pos + $0 * 6 + 2)) }
                pos += n * 6
            case 5: pos += 4
            default: break loop
            }
        }
        return out
    }

    /// Puts an enveloped mesh's vertices into the model's bind pose and gives each its bone
    /// weights: a vertex on a single bone's matrix is stored relative to that bone (so it's moved
    /// by the bone's bind matrix here); one on a blended envelope is already in model space.
    private static func resolveEnvelopes(_ meshes: inout [MDL0Mesh], bones: [MDL0Bone], mixes: [Int: [(Int, Float)]]) {
        guard !bones.isEmpty else { return }
        var world: [simd_float4x4?] = Array(repeating: nil, count: bones.count)
        func bindWorld(_ i: Int) -> simd_float4x4 {
            if let w = world[i] { return w }
            let b = bones[i]
            let local = MDL0Bone.matrix(scale: b.scale, rotation: b.rotation, translation: b.translation)
            let w = (b.parent.map { $0 != i ? bindWorld($0) : matrix_identity_float4x4 } ?? matrix_identity_float4x4) * local
            world[i] = w
            return w
        }
        var boneOfMatrix: [Int: Int] = [:]
        for (i, b) in bones.enumerated() where boneOfMatrix[b.matrixId] == nil { boneOfMatrix[b.matrixId] = i }
        for m in meshes.indices where meshes[m].matrixId < 0 {
            for v in meshes[m].vertices.indices {
                guard let mtx = meshes[m].vertices[v].drawMatrix else { continue }
                if let mix = mixes[mtx] {
                    meshes[m].vertices[v].weights = mix.compactMap { e in boneOfMatrix[e.0].map { ($0, e.1) } }
                } else if let b = boneOfMatrix[mtx] {
                    let w = bindWorld(b)
                    var vtx = meshes[m].vertices[v]
                    let p = w * SIMD4(vtx.position.x, vtx.position.y, vtx.position.z, 1)
                    vtx.position = Vec3(x: p.x, y: p.y, z: p.z)
                    if let n = vtx.normal {
                        let r = simd_normalize(simd_float3x3(SIMD3(w.columns.0.x, w.columns.0.y, w.columns.0.z), SIMD3(w.columns.1.x, w.columns.1.y, w.columns.1.z),
                                                             SIMD3(w.columns.2.x, w.columns.2.y, w.columns.2.z)) * SIMD3(n.x, n.y, n.z))
                        vtx.normal = Vec3(x: r.x, y: r.y, z: r.z)
                    }
                    vtx.weights = [(b, 1)]
                    meshes[m].vertices[v] = vtx
                }
            }
        }
    }

    private static func parseMeshTextureLinks(_ d: Data, renderTreeOfs: Int, materials: [MDL0Material],
                                               rawFile: Data, fileOffset: Int) -> [Int: (textures: [String], material: MDL0Material?)] {
        guard renderTreeOfs != 0, renderTreeOfs > 0, renderTreeOfs < d.count else { return [:] }
        var out: [Int: (textures: [String], material: MDL0Material?)] = [:]
        let entries = BRRESIndexGroup.parse(d, groupStart: renderTreeOfs, names: (rawFile, fileOffset))
        for entry in entries where entry.name == "DrawOpa" || entry.name == "DrawXlu" {
            var pos = entry.dataOffset
            loop: while pos >= 0, pos < d.count {
                let tag = d.u8(pos); pos += 1
                switch tag {
                case 0: continue // NoOp
                case 1: break loop // Return
                case 2: pos += 4 // NodeDescendence: boneId(u16) + parentMtxId(u16)
                case 3: // NodeMixing: mtxId(u16) + numBlend(u8) + numBlend * (mtxId(u16) + ratio(f32))
                    guard pos + 3 <= d.count else { break loop }
                    let numBlend = Int(d.u8(pos + 2))
                    pos += 3 + numBlend * 6
                case 4: // Draw: matId(u16) polyId(u16) boneId(u16) prio(u8)
                    guard pos + 7 <= d.count else { break loop }
                    let matId = Int(d.be16(pos)), polyId = Int(d.be16(pos + 2))
                    pos += 7
                    if out[polyId] == nil, materials.indices.contains(matId) {
                        out[polyId] = (materials[matId].textureNames, materials[matId])
                    }
                case 5: pos += 4 // EnvelopeMatrix: mtxId(u16) + nodeId(u16)
                default: break loop // MatrixCopy or an unrecognized tag, bail safely
                }
            }
        }
        return out
    }

    // MARK: Vertex buffers
    //
    // Header layout (verified against ModelIO.cpp's `readGenericBuffer`): size(u32) @0x00,
    // mdl0Offset(u32) @0x04, startOfs(s32, relative to this buffer's own start) @0x08,
    // nameOfs(s32) @0x0C, id(u32) @0x10, componentCount(u32) @0x14, componentType(u32) @0x18,
    // then either [divisor(u8), stride(u8)] or [stride(u8), pad(u8)] @0x1C depending on whether
    // this buffer kind caches a divisor, then entryCount(u16) @0x1E, then (for buffers that cache
    // a min/max) two more raw-float vectors, unneeded here since `startOfs` already tells us
    // exactly where the real quantized data begins, so there's no need to compute past it.

    private static func componentByteSize(_ type: UInt32) -> Int {
        switch type { case 0, 1: return 1; case 2, 3: return 2; default: return 4 }
    }

    /// Decodes one fixed-point (or float) component per GX's 5 generic vertex types, matching
    /// `readGenericComponentSingle` exactly: integer types divide by `2^divisor`, f32 is direct.
    private static func decodeComponent(_ d: Data, _ pos: inout Int, type: UInt32, divisor: UInt32) -> Float {
        let scale = Float(1 << min(divisor, 30))
        switch type {
        case 0: let v = d.u8(pos); pos += 1; return Float(v) / scale
        case 1: let v = Int8(bitPattern: d.u8(pos)); pos += 1; return Float(v) / scale
        case 2: let v = d.be16(pos); pos += 2; return Float(v) / scale
        case 3: let v = d.beInt16(pos); pos += 2; return Float(v) / scale
        default: let v = d.beFloat32(pos); pos += 4; return v
        }
    }

    private static let maxBufferEntries = 200_000

    /// Position buffer: HasMinimum=true, HasDivisor=true; component count 0=xy, 1=xyz.
    private static func parsePositions(_ d: Data, start: Int) -> [Vec3]? {
        guard start >= 0, start + 0x20 <= d.count else { return nil }
        let startOfs = Int(Int32(bitPattern: d.be32(start + 0x08)))
        let compCount = d.be32(start + 0x14)
        let type = d.be32(start + 0x18)
        var divisor = UInt32(d.u8(start + 0x1C))
        if type == 4 { divisor = 0 }
        let entryCount = Int(d.be16(start + 0x1E))
        guard entryCount >= 0, entryCount < maxBufferEntries else { return nil }
        let nComponents = compCount == 0 ? 2 : 3
        var pos = start + startOfs
        guard pos >= 0 else { return nil }
        let compSize = componentByteSize(type)
        var out: [Vec3] = []
        out.reserveCapacity(entryCount)
        for _ in 0..<entryCount {
            guard pos + compSize * nComponents <= d.count else { break }
            var v = Vec3()
            v.x = decodeComponent(d, &pos, type: type, divisor: divisor)
            v.y = decodeComponent(d, &pos, type: type, divisor: divisor)
            v.z = nComponents == 3 ? decodeComponent(d, &pos, type: type, divisor: divisor) : 0
            out.append(v)
        }
        return out
    }

    /// Normal buffer: HasMinimum=false, HasDivisor=true; only plain xyz normals are supported
    /// (NBT/NBT3-encoded normals are rare and fall back to "no normals" for that buffer).
    /// Divisor is forced to 6/14/0 for s8/s16/f32 regardless of the stored value, matching
    /// ModelIO.cpp's override (the file's divisor byte for normals is not authoritative).
    private static func parseNormals(_ d: Data, start: Int) -> [Vec3]? {
        guard start >= 0, start + 0x20 <= d.count else { return nil }
        guard d.be32(start + 0x14) == 0 else { return nil } // component count != xyz
        let startOfs = Int(Int32(bitPattern: d.be32(start + 0x08)))
        let type = d.be32(start + 0x18)
        var divisor: UInt32
        switch type {
        case 1: divisor = 6
        case 3: divisor = 14
        case 4: divisor = 0
        default: divisor = UInt32(d.u8(start + 0x1C))
        }
        let entryCount = Int(d.be16(start + 0x1E))
        guard entryCount >= 0, entryCount < maxBufferEntries else { return nil }
        var pos = start + startOfs
        guard pos >= 0 else { return nil }
        let compSize = componentByteSize(type)
        var out: [Vec3] = []
        out.reserveCapacity(entryCount)
        for _ in 0..<entryCount {
            guard pos + compSize * 3 <= d.count else { break }
            var v = Vec3()
            v.x = decodeComponent(d, &pos, type: type, divisor: divisor)
            v.y = decodeComponent(d, &pos, type: type, divisor: divisor)
            v.z = decodeComponent(d, &pos, type: type, divisor: divisor)
            out.append(v)
        }
        return out
    }

    /// UV buffer: HasMinimum=true, HasDivisor=true; component count 0=s (1 component), 1=st (2).
    /// A colour buffer: header 0x20, type at 0x18 (0 RGB565, 1 RGB8, 2 RGBX8, 3 RGBA4, 4 RGBA6,
    /// 5 RGBA8), entry count at 0x1E, data at the self-relative offset in 0x08.
    private static func parseColors(_ d: Data, start: Int) -> [SIMD4<Float>]? {
        guard start >= 0, start + 0x20 <= d.count else { return nil }
        let pos = start + Int(Int32(bitPattern: d.be32(start + 0x08)))
        let type = Int(d.be32(start + 0x18)), count = Int(d.be16(start + 0x1E))
        guard type <= 5, count < maxBufferEntries else { return nil }
        let size = [2, 3, 4, 2, 3, 4][type]
        var out: [SIMD4<Float>] = []
        for i in 0..<count {
            let o = pos + i * size
            guard o + size <= d.count else { break }
            switch type {
            case 0: let v = d.be16(o); out.append(SIMD4(Float(v >> 11) / 31, Float((v >> 5) & 63) / 63, Float(v & 31) / 31, 1))
            case 1, 2: out.append(SIMD4(Float(d.u8(o)), Float(d.u8(o + 1)), Float(d.u8(o + 2)), 255) / 255)
            case 3: let v = d.be16(o); out.append(SIMD4(Float(v >> 12), Float((v >> 8) & 15), Float((v >> 4) & 15), Float(v & 15)) / 15)
            case 4:
                let v = (UInt32(d.u8(o)) << 16) | (UInt32(d.u8(o + 1)) << 8) | UInt32(d.u8(o + 2))
                out.append(SIMD4(Float((v >> 18) & 63), Float((v >> 12) & 63), Float((v >> 6) & 63), Float(v & 63)) / 63)
            default: out.append(SIMD4(Float(d.u8(o)), Float(d.u8(o + 1)), Float(d.u8(o + 2)), Float(d.u8(o + 3))) / 255)
            }
        }
        return out
    }

    private static func parseUVs(_ d: Data, start: Int) -> [Vec2]? {
        guard start >= 0, start + 0x20 <= d.count else { return nil }
        let startOfs = Int(Int32(bitPattern: d.be32(start + 0x08)))
        let compCount = d.be32(start + 0x14)
        let type = d.be32(start + 0x18)
        var divisor = UInt32(d.u8(start + 0x1C))
        if type == 4 { divisor = 0 }
        let entryCount = Int(d.be16(start + 0x1E))
        guard entryCount >= 0, entryCount < maxBufferEntries else { return nil }
        let nComponents = compCount == 0 ? 1 : 2
        var pos = start + startOfs
        guard pos >= 0 else { return nil }
        let compSize = componentByteSize(type)
        var out: [Vec2] = []
        out.reserveCapacity(entryCount)
        for _ in 0..<entryCount {
            guard pos + compSize * nComponents <= d.count else { break }
            var v = Vec2()
            v.x = decodeComponent(d, &pos, type: type, divisor: divisor)
            v.y = nComponents == 2 ? decodeComponent(d, &pos, type: type, divisor: divisor) : 0
            out.append(v)
        }
        return out
    }

    // MARK: Mesh (Object/Polygon) parsing
    //
    // Header layout (verified against PolygonIO.cpp's `BinaryPolygon::read`), all offsets
    // relative to `meshStart`: size(u32)@0x00, mdl0Offset(u32)@0x04, currentMatrix(s32)@0x08,
    // vtxDescvCache[3](u32 each)@0x0C, primitiveSetupDL{bufSize(u32),cmdSize(u32),ofsBuf(s32)}
    // @0x18, primitiveDataDL{bufSize(u32),cmdSize(u32),ofsBuf(s32)}@0x24, vcdBitfield(u32)@0x30,
    // flag(u32)@0x34, nameOfs(s32)@0x38, id(u32)@0x3C, vtxCount(u32)@0x40, triCount(u32)@0x44,
    // posIdx(s16)@0x48, nrmIdx(s16)@0x4A, colorIdx[2](s16 each)@0x4C, uvIdx[8](s16 each)@0x50.

    private static func parseOneMesh(_ d: Data, meshStart: Int,
                                      positionBuffers: [[Vec3]?], normalBuffers: [[Vec3]?],
                                      uvBuffers: [[Vec2]?], colorBuffers: [[SIMD4<Float>]?] = []) -> (id: Int, vertices: [MDL0Vertex])? {
        guard meshStart >= 0, meshStart + 0x68 <= d.count else { return nil }
        let id = Int(d.be32(meshStart + 0x3C))
        let posIdx = Int(d.beInt16(meshStart + 0x48))
        guard posIdx >= 0, positionBuffers.indices.contains(posIdx), let positions = positionBuffers[posIdx] else { return nil }
        let nrmIdx = Int(d.beInt16(meshStart + 0x4A))
        let normals: [Vec3] = (nrmIdx >= 0 && normalBuffers.indices.contains(nrmIdx)) ? (normalBuffers[nrmIdx] ?? []) : []
        let uv0Idx = Int(d.beInt16(meshStart + 0x50))
        let uvs: [Vec2] = (uv0Idx >= 0 && uvBuffers.indices.contains(uv0Idx)) ? (uvBuffers[uv0Idx] ?? []) : []
        let uv1Idx = Int(d.beInt16(meshStart + 0x52))
        let uvs1: [Vec2] = (uv1Idx >= 0 && uvBuffers.indices.contains(uv1Idx)) ? (uvBuffers[uv1Idx] ?? []) : []
        let colorIdx = Int(d.beInt16(meshStart + 0x4C))
        let colors: [SIMD4<Float>] = (colorIdx >= 0 && colorBuffers.indices.contains(colorIdx)) ? (colorBuffers[colorIdx] ?? []) : []

        let setupTagStart = meshStart + 0x18
        let setupBufSize = Int(d.be32(setupTagStart))
        let setupOfsBuf = Int(Int32(bitPattern: d.be32(setupTagStart + 8)))
        let setupDataStart = setupTagStart + setupOfsBuf
        guard setupBufSize >= 0, setupDataStart >= 0, setupDataStart + setupBufSize <= d.count else { return nil }
        let hex = parseVCDHex(d, start: setupDataStart, size: setupBufSize)

        let dataTagStart = meshStart + 0x24
        let dataBufSize = Int(d.be32(dataTagStart))
        let dataOfsBuf = Int(Int32(bitPattern: d.be32(dataTagStart + 8)))
        let dataStart = dataTagStart + dataOfsBuf
        guard dataBufSize >= 0, dataStart >= 0, dataStart + dataBufSize <= d.count else { return nil }

        let vcdBitfield = d.be32(meshStart + 0x30)
        guard let active = activeAttributes(vcdBitfield: vcdBitfield, hex: hex) else { return nil }
        guard active.contains(where: { if case .position = $0.role { return true }; return false }) else { return nil }

        let vertices = decodeDisplayList(d, start: dataStart, size: dataBufSize, active: active,
                                  positions: positions, normals: normals, uvs: uvs, uvs1: uvs1, colors: colors,
                                         hasMatrixIndex: vcdBitfield & 1 != 0)
        return (id: id, vertices: vertices)
    }

    /// Interprets the small "vertex setup" display list, which contains just enough GX CP
    /// register writes (0x50 then 0x60) to reconstruct the 64-bit vertex-descriptor word whose
    /// 2-bit fields say how each attribute is encoded in the *real* mesh display list. Combining
    /// formula (`Hex = reg50 | (reg60 << 17)`) verified against RiiStudio's
    /// `DLPixShader.cpp: QDisplayListVertexSetupHandler::onCommandCP`.
    private static func parseVCDHex(_ d: Data, start: Int, size: Int) -> UInt64 {
        var hex: UInt64 = 0
        var pos = start
        let end = min(start + size, d.count)
        while pos < end {
            let tag = d.u8(pos); pos += 1
            switch tag {
            case 0x00: continue // NOP
            case 0x08: // CP command: reg(u8) + val(u32)
                guard pos + 5 <= d.count else { return hex }
                let reg = d.u8(pos)
                let val = d.be32(pos + 1)
                pos += 5
                if reg == 0x50 { hex = UInt64(val) } else if reg == 0x60 { hex |= UInt64(val) << 17 }
            case 0x61: pos += 4 // BP command
            case 0x10: // XF command: nCmd(u16) + reg(u16) + (nCmd+1) * u32
                guard pos + 4 <= d.count else { return hex }
                let nCmd = Int(d.be16(pos))
                pos += 4 + (nCmd + 1) * 4
            default:
                return hex // unexpected tag in what should be a tiny setup list, bail safely
            }
        }
        return hex
    }

    private enum AttrRole { case position, normal, color0, color1, uv(Int), other }
    private struct ActiveAttr { var role: AttrRole; var byteSize: Int }

    /// Walks the 21 meaningful `VertexAttribute` bit positions in order (matching the real
    /// per-vertex field order in the display list): bit 0 = position/normal matrix index, bits
    /// 1-8 = texture 0-7 matrix index (always 1-byte "Direct" when present), bits 9-20 =
    /// Position/Normal/Color0/Color1/TexCoord0-7, whose 2-bit status in `hex` says
    /// none(0)/direct(1, unsupported here)/8-bit index(2)/16-bit index(3).
    private static func activeAttributes(vcdBitfield: UInt32, hex: UInt64) -> [ActiveAttr]? {
        var out: [ActiveAttr] = []
        for bit in 0..<21 {
            guard vcdBitfield & (1 << bit) != 0 else { continue }
            if bit <= 8 {
                out.append(ActiveAttr(role: .other, byteSize: 1)) // matrix index, always Direct
                continue
            }
            let statusIdx = bit - 9 // 0=Position 1=Normal 2=Color0 3=Color1 4...11=TexCoord0...7
            let status = Int((hex >> UInt64(9 + statusIdx * 2)) & 0x3)
            guard status == 2 || status == 3 else { return nil } // none/direct: unsupported here
            let byteSize = status == 2 ? 1 : 2
            let role: AttrRole
            switch statusIdx {
            case 0: role = .position
            case 1: role = .normal
            case 2: role = .color0
            case 3: role = .color1
            default: role = .uv(statusIdx - 4)
            }
            out.append(ActiveAttr(role: role, byteSize: byteSize))
        }
        return out
    }

    /// Decodes the real per-triangle draw commands, resolving each vertex's attribute indices
    /// against the already-parsed buffers and converting every GX primitive type to a flat
    /// triangle list.
    private static func decodeDisplayList(_ d: Data, start: Int, size: Int, active: [ActiveAttr],
                                           positions: [Vec3], normals: [Vec3], uvs: [Vec2], uvs1: [Vec2] = [], colors: [SIMD4<Float>] = [],
                                           hasMatrixIndex: Bool = false) -> [MDL0Vertex] {
        var out: [MDL0Vertex] = []
        var slots: [Int: Int] = [:]
        var pos = start
        let end = min(start + size, d.count)
        while pos < end {
            let tag = d.u8(pos); pos += 1
            switch tag {
            case 0x00: continue
            case 0x08: pos += 5
            case 0x61: pos += 4
            case 0x10:
                guard pos + 4 <= d.count else { return out }
                let nCmd = Int(d.be16(pos))
                pos += 4 + (nCmd + 1) * 4
            case 0x20: // indexed position-matrix load: draw matrix id, then XF address (12 words a slot)
                guard pos + 4 <= d.count else { return out }
                slots[Int(d.be16(pos + 2) & 0xFFF) / 12] = Int(d.be16(pos))
                pos += 4
            case 0x28, 0x30, 0x38:
                pos += 4
            default:
                guard tag & 0x80 != 0 else { return out } // unrecognized tag: stop, keep what we have
                let primitive = (UInt32(tag) & 0x78) >> 3
                guard pos + 2 <= d.count else { return out }
                let nVerts = Int(d.be16(pos)); pos += 2
                var faceVerts: [MDL0Vertex] = []
                faceVerts.reserveCapacity(nVerts)
                for _ in 0..<nVerts {
                    var vPos: Int?, vNrm: Int?, vUV0: Int?, vUV1: Int?, vCol: Int?, vMtx: Int?
                    for (k, attr) in active.enumerated() {
                        guard pos + attr.byteSize <= d.count else { break }
                        let v = attr.byteSize == 1 ? Int(d.u8(pos)) : Int(d.be16(pos))
                        pos += attr.byteSize
                        switch attr.role {
                        case .position: vPos = v
                        case .normal: vNrm = v
                        case .uv(0): vUV0 = v
                        case .uv(1): vUV1 = v
                        case .color0: vCol = v
                        case .other where k == 0 && hasMatrixIndex: vMtx = v
                        default: break
                        }
                    }
                    guard let pIdx = vPos, positions.indices.contains(pIdx) else { continue }
                    var vtx = MDL0Vertex(position: positions[pIdx])
                    if let n = vNrm, normals.indices.contains(n) { vtx.normal = normals[n] }
                    if let u = vUV0, uvs.indices.contains(u) { vtx.uv0 = uvs[u] }
                    if let u = vUV1, uvs1.indices.contains(u) { vtx.uv1 = uvs1[u] }
                    if let c = vCol, colors.indices.contains(c) { vtx.color = colors[c] }
                    if let m = vMtx { vtx.drawMatrix = slots[m / 3] }
                    faceVerts.append(vtx)
                }
                appendTriangles(from: faceVerts, primitive: primitive, into: &out)
            }
        }
        return out
    }

    /// GX primitive-type ordinals (`(opcode & 0x78) >> 3`): 0=Quads, 1=Quads2, 2=Triangles,
    /// 3=TriangleStrip, 4=TriangleFan, 5=Lines, 6=LineStrip, 7=Points.
    private static func appendTriangles(from verts: [MDL0Vertex], primitive: UInt32, into out: inout [MDL0Vertex]) {
        switch primitive {
        case 2: // Triangles
            var i = 0
            while i + 2 < verts.count { out.append(verts[i]); out.append(verts[i + 1]); out.append(verts[i + 2]); i += 3 }
        case 3: // TriangleStrip
            guard verts.count >= 3 else { return }
            for i in 2..<verts.count {
                if i % 2 == 0 { out.append(verts[i - 2]); out.append(verts[i - 1]); out.append(verts[i]) }
                else { out.append(verts[i - 1]); out.append(verts[i - 2]); out.append(verts[i]) }
            }
        case 4: // TriangleFan
            guard verts.count >= 3 else { return }
            for i in 2..<verts.count { out.append(verts[0]); out.append(verts[i - 1]); out.append(verts[i]) }
        case 0, 1: // Quads, Quads2
            var i = 0
            while i + 3 < verts.count {
                out.append(verts[i]); out.append(verts[i + 1]); out.append(verts[i + 2])
                out.append(verts[i]); out.append(verts[i + 2]); out.append(verts[i + 3])
                i += 4
            }
        default: break // Lines/LineStrip/Points: not renderable as triangles
        }
    }
}
