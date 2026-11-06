import Foundation
import simd

/// Double Dash's "Create Shadow Map": retail courses darken shadowed ground through their vertex
/// colours rather than a lightmap texture, so this bakes `ShadowMap`'s sun into the course
/// model's vertex colours. The model goes through the port's own pipeline (`J3DToWii` then
/// `MKWiiToMKDD.model`) and is written fresh with `J3DWriter`, so materials come back as the
/// course builder's (texture x vertex colour), like Mario Kart Wii's Create Shadow Map resets them.
nonisolated enum MKDDShadow {
    /// The course model, ready to bake (or re-bake with other settings).
    static func load(_ bmd: Data) throws -> MKDDTrackBuilder.Model {
        let j3d = try J3DModel.parse(bmd)
        let brres = try J3DToWii.brres(from: j3d, modelName: "course", scale: 1)
        var report: [String] = []
        return try MKWiiToMKDD.model(brres, modelName: "course", place: MKWiiToMKDD.Placement(scale: 1), report: &report)
    }

    /// `model` with every vertex colour darkened towards `shadowColor` where the sun is blocked.
    /// ponytail: per vertex (as retail bakes it), so a shadow is only as sharp as the mesh is
    /// dense; and two-sided, since the model carries no normals to tell a face's front.
    static func bake(_ model: MKDDTrackBuilder.Model, options o: ShadowMap.Options, shadowColor: (r: UInt8, g: UInt8, b: UInt8)) -> MKDDTrackBuilder.Model {
        let tris = model.triangles.map { ShadowMap.Triangle(a: simd($0.v.0.position), b: simd($0.v.1.position), c: simd($0.v.2.position)) }
        let bvh = ShadowMap.BVH(tris)
        let sun = o.sunDirection
        let rays = ShadowMap.sunRays(o)
        let extent = tris.reduce(into: (SIMD3<Float>(repeating: .greatestFiniteMagnitude), SIMD3<Float>(repeating: -.greatestFiniteMagnitude))) {
            $0.0 = simd_min($0.0, simd_min($1.a, simd_min($1.b, $1.c))); $0.1 = simd_max($0.1, simd_max($1.a, simd_max($1.b, $1.c)))
        }
        let lift = max(1, simd_length(extent.1 - extent.0) * 1e-4)
        var shade = [Float](repeating: 1, count: tris.count * 3)
        DispatchQueue.concurrentPerform(iterations: tris.count) { i in
            let t = tris[i]
            let n0 = simd_cross(t.b - t.a, t.c - t.a)
            guard simd_length(n0) > 1e-9 else { return }
            var n = simd_normalize(n0)
            if simd_dot(n, sun) < 0 { n = -n } // two-sided: the side the sun can see
            let facing = simd_dot(n, sun)
            var out: [Float] = []
            for p in [t.a, t.b, t.c] {
                // Nudged into the triangle and off its surface, so a corner shared with a wall
                // isn't shadowed by that wall.
                let inward = (t.a + t.b + t.c) / 3 - p
                let origin = p + inward * 0.05 + n * lift
                var lit: Float = 0
                for d in rays where !bvh.hits(origin: origin, direction: d) { lit += 1 }
                lit /= Float(rays.count)
                if o.shadeSlopes { lit *= min(1, facing * 1.5 + 0.25) }
                out.append(1 - o.darkness * (1 - lit))
            }
            shade.withUnsafeMutableBufferPointer { b in for k in 0..<3 { b[i * 3 + k] = out[k] } }
        }
        var baked = model
        let sc = [Float(shadowColor.r), Float(shadowColor.g), Float(shadowColor.b)].map { $0 / 255 }
        func darken(_ v: inout J3DWriter.Vertex, _ s: Float) {
            for k in 0..<3 { v.color[k] = UInt8(clamping: Int((Float(v.color[k]) * (sc[k] + (1 - sc[k]) * s)).rounded())) }
        }
        for i in baked.triangles.indices {
            darken(&baked.triangles[i].v.0, shade[i * 3])
            darken(&baked.triangles[i].v.1, shade[i * 3 + 1])
            darken(&baked.triangles[i].v.2, shade[i * 3 + 2])
        }
        return baked
    }

    /// The `.bmd` for a (baked) course model, textures fitted to the course budget.
    static func write(_ model: MKDDTrackBuilder.Model) throws -> Data {
        let (textures, _) = GCTextures.optimize(model.textures, budget: GCTextures.courseBudget)
        return try J3DWriter.bmd(triangles: model.triangles, materials: model.materials, textures: textures)
    }

    private static func simd(_ v: Vec3) -> SIMD3<Float> { SIMD3(v.x, v.y, v.z) }
}
