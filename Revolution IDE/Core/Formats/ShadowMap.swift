import Foundation
import simd

/// Baked course shadows, the way retail courses have them: a grey
/// "kage" texture on a second UV set, darkening the ground wherever the sun is blocked. The
/// material side (two samplers, retail's two-stage shader) is `MDL0Writer.MaterialSpec.shadowMap`.
///
/// Lightmap UVs: every triangle gets its own chart, laid flat in its own plane at one shared
/// texel density and shelf-packed into the square, so area (not triangle count) decides how much
/// of the map a surface gets. Each chart keeps a gutter so filtering never reads a neighbour.
/// ponytail: one chart per triangle; merging coplanar neighbours into bigger charts would use the
/// map better and hide seams on very coarse meshes, if those ever show.
nonisolated enum ShadowMap {
    struct Options: Equatable, Codable {
        /// Sun direction: compass angle (0 = from +X, 90 = from +Z) and height above the horizon.
        var azimuth: Float = 225
        var elevation: Float = 50
        var size = 1024
        /// Penumbra: the sun's angular radius in degrees (0 = hard shadows).
        var softness: Float = 1.5
        /// Rays per texel when soft.
        var samples = 8
        /// Also darken faces turned away from the sun, not just cast shadows.
        var shadeSlopes = true
        /// How dark a full shadow is, 0 (black, then tinted by the material's shadow colour) to 1.
        var darkness: Float = 1
        var sunDirection: SIMD3<Float> {
            let a = azimuth * .pi / 180, e = elevation * .pi / 180
            return simd_normalize(SIMD3(cos(e) * cos(a), sin(e), cos(e) * sin(a)))
        }
    }

    struct Triangle {
        var a, b, c: SIMD3<Float>
        /// Its front faces the other way from `cross(b - a, c - a)`: retail models wind
        /// clockwise (their vertex normals disagree with that cross product), OBJ imports don't.
        var flip = false
    }

    /// Lightmap UVs (0-1, V down) for each triangle's corners, in order, and the texel rect
    /// each chart occupies.
    struct Atlas {
        var uvs: [SIMD2<Float>]
        let size: Int
        let texelsPerUnit: Float
    }

    // MARK: Atlas

    /// nil when even the smallest charts (a few texels each) don't all fit in a `size` map.
    static func atlas(_ tris: [Triangle], size: Int) -> Atlas? {
        let gutter: Float = 2
        // Each triangle in its own 2D frame: a at the origin, b along +x.
        let flat: [(SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)] = tris.map { t in
            let ab = t.b - t.a, ac = t.c - t.a
            let lab = simd_length(ab)
            guard lab > 1e-6 else { return (.zero, .zero, .zero) }
            let x = ab / lab
            let n = simd_cross(ab, ac)
            let y = simd_length(n) > 1e-9 ? simd_normalize(simd_cross(simd_normalize(n), x)) : SIMD3<Float>(0, 0, 0)
            var p = [SIMD2<Float>(0, 0), SIMD2(lab, 0), SIMD2(simd_dot(ac, x), simd_dot(ac, y))]
            let minX = p.map(\.x).min()!
            p = p.map { SIMD2($0.x - minX, $0.y) }
            return (p[0], p[1], p[2])
        }
        func extent(_ f: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)) -> SIMD2<Float> {
            SIMD2(max(f.0.x, f.1.x, f.2.x), max(f.0.y, f.1.y, f.2.y))
        }
        let order = tris.indices.sorted { extent(flat[$0]).y > extent(flat[$1]).y }
        let side = Float(size)
        /// Shelf-packs at `density` texels per unit; nil if it overflows.
        func pack(_ density: Float) -> [SIMD2<Float>]? {
            var origin = [SIMD2<Float>](repeating: .zero, count: tris.count)
            var x: Float = 0, y: Float = 0, shelf: Float = 0
            for i in order {
                let e = extent(flat[i]) * density
                let w = max(e.x, 1) + 2 * gutter, h = max(e.y, 1) + 2 * gutter
                if x + w > side { x = 0; y += shelf; shelf = 0 }
                guard y + h <= side, w <= side else { return nil }
                origin[i] = SIMD2(x + gutter, y + gutter)
                x += w; shelf = max(shelf, h)
            }
            return origin
        }
        let area = flat.reduce(Float(0)) { $0 + extent($1).x * extent($1).y }
        var lo: Float = 0, hi = area > 0 ? (side * side / area).squareRoot() : 1
        guard var best = pack(0) else { return nil }
        // In case the estimate is low (capped: zero-area triangles fit at any density).
        for _ in 0..<40 where pack(hi) != nil { lo = hi; hi *= 2 }
        if let p = pack(lo) { best = p } else { lo = 0 }
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if let p = pack(mid) { lo = mid; best = p } else { hi = mid }
        }
        var uvs: [SIMD2<Float>] = []
        uvs.reserveCapacity(tris.count * 3)
        for i in tris.indices {
            for p in [flat[i].0, flat[i].1, flat[i].2] { uvs.append((best[i] + p * lo) / side) }
        }
        return Atlas(uvs: uvs, size: size, texelsPerUnit: lo)
    }

    // MARK: Baking

    /// The shadow map, as grey RGBA8 (255 lit, 0 fully shadowed).
    /// `casters` (default: `tris` themselves) are what can block the sun.
    static func bake(_ tris: [Triangle], atlas: Atlas, options o: Options, casters: [Triangle]? = nil) -> [UInt8] {
        let size = atlas.size
        var shade = [Float](repeating: -1, count: size * size) // -1: no chart here
        let bvh = BVH(casters ?? tris)
        let sun = o.sunDirection
        // A small cone of directions around the sun for soft edges.
        let rays = sunRays(o)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: tris.count) { i in
            let t = tris[i]
            let p0 = atlas.uvs[i * 3] * Float(size), p1 = atlas.uvs[i * 3 + 1] * Float(size), p2 = atlas.uvs[i * 3 + 2] * Float(size)
            let n0 = simd_cross(t.b - t.a, t.c - t.a) * (t.flip ? -1 : 1)
            guard simd_length(n0) > 1e-9 else { return }
            let n = simd_normalize(n0)
            let den = (p1.y - p2.y) * (p0.x - p2.x) + (p2.x - p1.x) * (p0.y - p2.y)
            guard abs(den) > 1e-9 else { return }
            // The chart plus its gutter: texels just outside the triangle take its nearest edge.
            let minX = max(0, (min(p0.x, p1.x, p2.x) - 2).rounded(.down).clampedInt), maxX = min(size - 1, (max(p0.x, p1.x, p2.x) + 2).rounded(.up).clampedInt)
            let minY = max(0, (min(p0.y, p1.y, p2.y) - 2).rounded(.down).clampedInt), maxY = min(size - 1, (max(p0.y, p1.y, p2.y) + 2).rounded(.up).clampedInt)
            guard minX <= maxX, minY <= maxY else { return }
            let facing = simd_dot(n, sun)
            let offset = n * (facing >= 0 ? 1 : -1) * max(1, 1 / max(atlas.texelsPerUnit, 1e-3)) * 0.5
            var local: [(Int, Float, Bool)] = []
            for y in minY...maxY {
                for x in minX...maxX {
                    let px = Float(x) + 0.5, py = Float(y) + 0.5
                    var w0 = ((p1.y - p2.y) * (px - p2.x) + (p2.x - p1.x) * (py - p2.y)) / den
                    var w1 = ((p2.y - p0.y) * (px - p2.x) + (p0.x - p2.x) * (py - p2.y)) / den
                    var w2 = 1 - w0 - w1
                    let inside = w0 >= 0 && w1 >= 0 && w2 >= 0
                    if !inside {
                        w0 = max(0, w0); w1 = max(0, w1); w2 = max(0, w2)
                        let s = w0 + w1 + w2
                        guard s > 0 else { continue }
                        w0 /= s; w1 /= s; w2 /= s
                    }
                    let world = t.a * w0 + t.b * w1 + t.c * w2 + offset
                    var lit: Float = 0
                    if !(o.shadeSlopes && facing <= 0) {
                        for d in rays where !bvh.hits(origin: world, direction: d) { lit += 1 }
                        lit /= Float(rays.count)
                    }
                    if o.shadeSlopes { lit *= min(1, max(0, facing) * 1.5 + 0.25) }
                    local.append((y * size + x, lit, inside))
                }
            }
            lock.lock()
            for (k, v, inside) in local where inside || shade[k] < 0 { shade[k] = v }
            lock.unlock()
        }
        var out = [UInt8](repeating: 255, count: size * size * 4)
        for k in 0..<(size * size) {
            let v = shade[k] < 0 ? 1 : 1 - o.darkness * (1 - shade[k])
            let g = UInt8(max(0, min(255, (v * 255).rounded())))
            out[k * 4] = g; out[k * 4 + 1] = g; out[k * 4 + 2] = g
        }
        return out
    }

    /// A small cone of directions round the sun, for soft shadow edges.
    static func sunRays(_ o: Options) -> [SIMD3<Float>] {
        let sun = o.sunDirection
        guard o.softness > 0, o.samples > 1 else { return [sun] }
        let up = abs(sun.y) < 0.99 ? SIMD3<Float>(0, 1, 0) : SIMD3(1, 0, 0)
        let u = simd_normalize(simd_cross(sun, up)), v = simd_cross(sun, u)
        let r = tan(o.softness * .pi / 180)
        return (0..<o.samples).map { k in
            // Golden-angle spiral over the sun's disc.
            let t = (Float(k) + 0.5) / Float(o.samples), a = Float(k) * 2.39996
            return simd_normalize(sun + (u * cos(a) + v * sin(a)) * (r * t.squareRoot()))
        }
    }

    // MARK: Ray casting

    /// Bounding-volume hierarchy for "does this ray hit anything" queries.
    final class BVH: @unchecked Sendable { // read-only once built
        private struct Node { var lo, hi: SIMD3<Float>; var left = -1, right = -1, start = 0, count = 0 }
        private var nodes: [Node] = []
        private var order: [Int]
        private let tris: [Triangle]

        init(_ tris: [Triangle]) {
            self.tris = tris
            order = Array(tris.indices)
            if !tris.isEmpty { _ = build(0, tris.count) }
        }

        private func bounds(_ s: Int, _ e: Int) -> (SIMD3<Float>, SIMD3<Float>) {
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
            for i in order[s..<e] { let t = tris[i]; lo = simd_min(lo, simd_min(t.a, simd_min(t.b, t.c))); hi = simd_max(hi, simd_max(t.a, simd_max(t.b, t.c))) }
            return (lo, hi)
        }

        private func build(_ s: Int, _ e: Int) -> Int {
            let (lo, hi) = bounds(s, e)
            nodes.append(Node(lo: lo, hi: hi))
            let me = nodes.count - 1
            if e - s <= 4 { nodes[me].start = s; nodes[me].count = e - s; return me }
            let ext = hi - lo
            let axis = ext.x > ext.y && ext.x > ext.z ? 0 : (ext.y > ext.z ? 1 : 2)
            order[s..<e].sort { a, b in
                let ca = (tris[a].a + tris[a].b + tris[a].c)[axis], cb = (tris[b].a + tris[b].b + tris[b].c)[axis]
                return ca < cb
            }
            let mid = (s + e) / 2
            let l = build(s, mid), r = build(mid, e)
            nodes[me].left = l; nodes[me].right = r
            return me
        }

        func hits(origin: SIMD3<Float>, direction d: SIMD3<Float>) -> Bool {
            guard !nodes.isEmpty else { return false }
            let inv = SIMD3<Float>(1 / d.x, 1 / d.y, 1 / d.z)
            var stack = [0]
            while let n = stack.popLast() {
                let node = nodes[n]
                let t0 = (node.lo - origin) * inv, t1 = (node.hi - origin) * inv
                let tmin = simd_reduce_max(simd_min(t0, t1)), tmax = simd_reduce_min(simd_max(t0, t1))
                guard tmax >= max(tmin, 0) else { continue }
                if node.count > 0 {
                    for i in order[node.start..<(node.start + node.count)] where Self.intersects(tris[i], origin, d) { return true }
                } else {
                    stack.append(node.left); stack.append(node.right)
                }
            }
            return false
        }

        /// Moller-Trumbore, either face.
        private static func intersects(_ t: Triangle, _ o: SIMD3<Float>, _ d: SIMD3<Float>) -> Bool {
            let e1 = t.b - t.a, e2 = t.c - t.a
            let p = simd_cross(d, e2), det = simd_dot(e1, p)
            guard abs(det) > 1e-9 else { return false }
            let inv = 1 / det, s = o - t.a
            let u = simd_dot(s, p) * inv
            guard u >= 0, u <= 1 else { return false }
            let q = simd_cross(s, e1), v = simd_dot(d, q) * inv
            guard v >= 0, u + v <= 1 else { return false }
            return simd_dot(e2, q) * inv > 1e-3
        }
    }
}

// MARK: - Shadowing a model

nonisolated extension ShadowMap {
    struct Shadowed {
        var model: MDL0Writer.Built
        var kage: Data
        var kageName: String
        var map: [UInt8]
        var receivers: Int
    }

    enum Failure: Error, LocalizedError {
        case unreadable, tooBig(String), noReceivers, mapTooSmall(Int)
        var errorDescription: String? {
            switch self {
            case .unreadable: "This model couldn't be read (only MDL0 version 11 models can be shadowed)."
            case .tooBig(let m): "Material \(m) has more than \(MDL0Writer.maxVerticesPerMesh / 3) triangles, more than one mesh can hold."
            case .noReceivers: "No textured material is selected to receive shadows."
            case .mapTooSmall(let size): "The chosen materials have too many triangles to fit in a \(size) x \(size) map. Choose a bigger map size, or fewer materials."
            }
        }
    }

    /// Bakes `options`' sun over every mesh of `resource` and rebuilds it with a kage pass on
    /// each textured material in `receivers` (all of them when nil). Meshes sharing a material
    /// are merged, so material names, what SRT0/PAT0/CLR0 target, stay the same.
    static func shadow(_ resource: BRRESResource, in doc: BRRESDocument, options: Options, shadowColor: (r: UInt8, g: UInt8, b: UInt8),
                       kageName: String, receivers: Set<String>? = nil) throws -> Shadowed {
        guard let model = MDL0Parser.parse(resource, rawFile: doc.rawData) else { throw Failure.unreadable }
        // Rigid meshes sit in their bone's space; bring everything into world space.
        var world: [Int: simd_float4x4] = [:]
        func boneWorld(_ i: Int) -> simd_float4x4 {
            if let m = world[i] { return m }
            let b = model.bones[i]
            let m = (b.parent.map(boneWorld) ?? matrix_identity_float4x4) * MDL0Bone.matrix(scale: b.scale, rotation: b.rotation, translation: b.translation)
            world[i] = m
            return m
        }
        let materials = materialSpecs(resource, rawFile: doc.rawData)
        var order: [String] = []
        var groups: [String: MDL0Writer.Group] = [:]
        var colors: [String: [MDL0Writer.RGBA]] = [:]
        var flips: [String: [Bool]] = [:]
        // A lightmapped material may sample its old shadow map first (43 retail meshes do, e.g.
        // Moo Moo Meadows' grass: kage, gard): keep the colour texture, on its own UV set.
        var greyCache: [String: Bool] = [:]
        func isGrey(_ name: String) -> Bool {
            if let g = greyCache[name] { return g }
            let r = doc.resources.first { $0.magic == "TEX0" && $0.name == name }
            let g = r.flatMap { TEX0View($0) }.flatMap { v in v.decodeRGBA(palette: nil).flatMap { ImageUtil.decodedTexture(fromRGBA: $0, width: v.width, height: v.height)?.isGrayscale } } ?? false
            greyCache[name] = g
            return g
        }
        for mesh in model.meshes {
            let slots = mesh.textureNames.isEmpty ? mesh.textureName.map { [$0] } ?? [] : mesh.textureNames
            let colourSlot = slots.count > 1 ? slots.indices.first { !isGrey(slots[$0]) } ?? 0 : 0
            let useUV1 = colourSlot >= 1 && mesh.vertices.allSatisfy { $0.uv1 != nil }
            let name = mesh.materialName ?? mesh.name
            let bone = mesh.matrixId >= 0 ? model.bones.firstIndex { $0.matrixId == mesh.matrixId } : nil
            let m = bone.map(boneWorld) ?? matrix_identity_float4x4
            func place(_ p: Vec3) -> Vec3 { let w = m * SIMD4(p.x, p.y, p.z, 1); return Vec3(x: w.x, y: w.y, z: w.z) }
            if groups[name] == nil {
                order.append(name)
                var spec = materials[name] ?? MDL0Writer.MaterialSpec(name: name)
                spec.name = name
                spec.textureName = slots.isEmpty ? mesh.textureName : slots[colourSlot]
                groups[name] = MDL0Writer.Group(material: spec, triangles: [])
            }
            var k = 0
            while k + 2 < mesh.vertices.count {
                let v = mesh.vertices[k..<(k + 3)].map { $0 }
                // MDL0's V runs down the image; the writer takes OBJ's V-up and flips it back.
                func uv(_ x: MDL0Vertex) -> Vec2? { (useUV1 ? x.uv1 : x.uv0).map { Vec2(x: $0.x, y: 1 - $0.y) } }
                // Facing from the vertex normals; without them, a back-culled material's front is
                // clockwise (as on every retail course), anything else as written.
                let p = v.map { SIMD3<Float>($0.position.x, $0.position.y, $0.position.z) }
                if v.allSatisfy({ $0.normal != nil }) {
                    let n = v.reduce(SIMD3<Float>()) { $0 + SIMD3($1.normal!.x, $1.normal!.y, $1.normal!.z) }
                    flips[name, default: []].append(simd_dot(simd_cross(p[1] - p[0], p[2] - p[0]), n) < 0)
                } else {
                    flips[name, default: []].append((materials[name]?.cull ?? 0) == 2)
                }
                groups[name]!.triangles.append(OBJImporter.Triangle(v0: place(v[0].position), v1: place(v[1].position), v2: place(v[2].position),
                                                                    uv0: uv(v[0]), uv1: uv(v[1]), uv2: uv(v[2]), materialName: name))
                for x in v {
                    let c = x.color ?? SIMD4(Float(MDL0Writer.neutralVertexColor.0) / 255, Float(MDL0Writer.neutralVertexColor.1) / 255, Float(MDL0Writer.neutralVertexColor.2) / 255, 1)
                    func b(_ f: Float) -> UInt8 { UInt8(max(0, min(255, (f * 255).rounded()))) }
                    colors[name, default: []].append((b(c.x), b(c.y), b(c.z), b(c.w)))
                }
                k += 3
            }
        }
        for name in order where groups[name]!.triangles.count * 3 > MDL0Writer.maxVerticesPerMesh { throw Failure.tooBig(name) }

        // Every triangle casts; textured receivers get the map.
        let isReceiver = { (name: String) in groups[name]!.material.textureName != nil && (receivers?.contains(name) ?? true) }
        guard order.contains(where: isReceiver) else { throw Failure.noReceivers }
        func bakeTriangles(_ name: String) -> [Triangle] {
            zip(groups[name]!.triangles, flips[name] ?? []).map { t, flip in
                Triangle(a: SIMD3(t.v0.x, t.v0.y, t.v0.z), b: SIMD3(t.v1.x, t.v1.y, t.v1.z), c: SIMD3(t.v2.x, t.v2.y, t.v2.z), flip: flip)
            }
        }
        let all = order.flatMap(bakeTriangles)
        let receiving = order.filter(isReceiver).flatMap(bakeTriangles)
        guard let layout = atlas(receiving, size: options.size) else { throw Failure.mapTooSmall(options.size) }
        let map = bake(receiving, atlas: layout, options: options, casters: all)
        var cursor = 0
        var built: [MDL0Writer.Group] = []
        for name in order {
            var g = groups[name]!
            g.vertexColors = colors[name]
            if isReceiver(name) {
                let n = g.triangles.count * 3
                g.shadowUVs = layout.uvs[cursor..<(cursor + n)].map { Vec2(x: $0.x, y: $0.y) }
                cursor += n
                g.material.shadowMap = kageName
                g.material.shadowColor = shadowColor
            }
            built.append(g)
        }
        guard let mdl0 = MDL0Writer.build(name: resource.name, groups: built),
              let kage = TEX0View.building(name: kageName, rgba: map, width: options.size, height: options.size, format: .cmpr) else { throw Failure.unreadable }
        return Shadowed(model: mdl0, kage: kage, kageName: kageName, map: map, receivers: order.filter(isReceiver).count)
    }

    /// A copy of `doc` with `s` installed: the shadowed model in place of the original and the
    /// kage texture (replacing any older one of the same name), re-read to prove it parses.
    static func applying(_ s: ShadowMap.Shadowed, model: BRRESResource, to doc: BRRESDocument) -> BRRESDocument? {
        guard let copy = try? BRRESDocument.parse(doc.serialize()) else { return nil }
        copy.resources.removeAll { $0.magic == "TEX0" && $0.name == s.kageName }
        guard let i = copy.resources.firstIndex(where: { $0.magic == "MDL0" && $0.name == model.name }) else { return nil }
        copy.resources[i] = BRRESResource(name: model.name, folderName: model.folderName, data: s.model.data, stringReferences: s.model.stringReferences)
        copy.resources.append(BRRESResource(name: s.kageName, folderName: "Textures(NW4R)", data: s.kage))
        return try? BRRESDocument.parse(copy.serialize())
    }

    /// The writer settings each existing material already has: cull, wrap, mip filtering, alpha
    /// test, blending and depth writes, read from its header, first sampler and display list.
    static func materialSpecs(_ resource: BRRESResource, rawFile: Data) -> [String: MDL0Writer.MaterialSpec] {
        let d = resource.data
        let dict = Int(Int32(bitPattern: d.be32(0x10 + 8 * 4)))
        guard dict > 0, dict < d.count else { return [:] }
        var out: [String: MDL0Writer.MaterialSpec] = [:]
        for e in BRRESIndexGroup.parse(d, groupStart: dict, names: (rawFile, resource.fileOffset)) {
            let m = e.dataOffset
            guard m + 0x40 <= d.count else { continue }
            var spec = MDL0Writer.MaterialSpec(name: e.name)
            spec.cull = d.be32(m + 0x18)
            if d.be32(m + 0x2C) > 0 {
                let s = m + Int(Int32(bitPattern: d.be32(m + 0x30)))
                if s + 0x28 <= d.count {
                    spec.wrap = (min(d.be32(s + 0x18), 2), min(d.be32(s + 0x1C), 2))
                    spec.mipmapped = d.be32(s + 0x20) > 1
                }
            }
            // The material display list opens with alpha test (BP 0xF3), Z mode (0x40) and blend
            // mode (0x41) writes.
            var p = m + Int(Int32(bitPattern: d.be32(m + 0x3C)))
            let end = min(p + 0x20, d.count - 4)
            while p < end {
                guard d.u8(p) == 0x61 else { p += 1; continue }
                let reg = d.u8(p + 1), v = d.be32(p + 1) & 0xFFFFFF
                switch reg {
                case 0xF3: spec.alphaTest = (UInt8(v >> 16 & 7), UInt8(v & 0xFF), UInt8(v >> 22 & 3), UInt8(v >> 19 & 7), UInt8(v >> 8 & 0xFF))
                case 0x40: spec.depthWrite = v & 0x10 != 0
                case 0x41: if v & 1 != 0 { spec.blend = (UInt8(v >> 8 & 7), UInt8(v >> 5 & 7)) }
                default: break
                }
                p += 5
            }
            out[e.name] = spec
        }
        return out
    }
}
