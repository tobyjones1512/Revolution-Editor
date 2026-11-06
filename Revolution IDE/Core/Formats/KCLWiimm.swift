import Foundation

/// Mario Kart Wii collision built the way Wiimm's `wkclt encode` builds it with its default
/// ("MEDIUM") settings, the encoder Blender MKW Utilities and most custom-track tools hand a
/// model to. A Swift port of `lib-kcl.c` (Wiimm's SZS Tools): `CalcNormalsTriData`,
/// `CheckMetricsTriData`, `CreateOctreeKCL`/`CalcCube` and `CreateRawKCL`, checked against the
/// real tool's output in `Tests/KCLWiimmCheck`.
///
/// What it does that the quicker `KCLBuilder` doesn't: normals and heights computed in double
/// precision; slivers dropped (area under 1 square unit, or any height under 1 unit, a long thin
/// prism's edge normals are too unstable to collide with); triangles snapped to whole units
/// relative to the octree; every octree cube padded by 400 units when testing which triangles
/// belong in it; base cubes sized from the triangle count; up to 30 triangles a leaf; and leaf
/// lists shared wherever one is a copy of (or the tail of) another.
nonisolated enum KCLWiimm {
    struct Profile {
        var blow = 400          // KCL_BLOW: cube padding when collecting triangles
        var maxTriangles = 30   // KCL_MAX_TRI
        var maxDepth = 10       // KCL_MAX_DEPTH
        var minCubeSize = 512   // KCL_MIN_SIZE
        var maxCubeSize = 0x100000 // KCL_MAX_SIZE
        var minArea = 1.0       // --tri-area
        var minHeight = 1.0     // --tri-height
        static let medium = Profile()
    }

    /// `dropped`: triangles too thin or small to collide with, kept out of the octree.
    struct Result { var data: Data; var dropped: Int }

    private typealias D3 = SIMD3<Double>

    private struct Tri {
        var pt: (D3, D3, D3)
        var normals: [SIMD3<Float>] // face, edge 1 (CA), edge 2 (AB), edge 3 (BC)
        var length: Float
        var flag: UInt16
    }

    static func build(_ triangles: [KCLTriangle], prismThickness: Float = 300, sphereRadius: Float = 250,
                      profile: Profile = .medium) -> Result {
        func d(_ v: Vec3) -> SIMD3<Double> { SIMD3(Double(v.x), Double(v.y), Double(v.z)) }
        return build(triangles.map { (d($0.v0), d($0.v1), d($0.v2), $0.attribute) }, prismThickness: prismThickness,
                     sphereRadius: sphereRadius, profile: profile)
    }

    /// The same, from double-precision corners, what wkclt itself works from when it reads an .obj.
    static func build(_ triangles: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>, UInt16)], prismThickness: Float = 300,
                      sphereRadius: Float = 250, profile: Profile = .medium) -> Result {
        // As Wiimm's dclib macros, term for term (Length3, Unit3, DotProd3, CrossProd3): the order
        // of the additions decides the last bit of every normal.
        func dot(_ a: D3, _ b: D3) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
        func unit(_ v: D3) -> D3 { let l = dot(v, v).squareRoot(); return l != 0 ? D3(v.x / l, v.y / l, v.z / l) : v }
        func cross(_ a: D3, _ b: D3) -> D3 {
            D3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
        }

        // MARK: Triangles (CalcNormalsTriData + CheckMetricsTriData). As in wkclt, an invalid
        // triangle stays in the prism list (no octree list ever names it) and still counts towards
        // the area the octree covers; one whose own height is degenerate is stored with height 0.
        var tris: [Tri] = []
        var valid: [Bool] = []
        var dropped = 0
        for (q0, q1, q2, flag) in triangles {
            // wkclt's .obj reader turns "-0" into 0.
            let p0 = q0 + 0.0, p1 = q1 + 0.0, p2 = q2 + 0.0
            let d20 = p2 - p0, d10 = p1 - p0, d12 = p1 - p2
            let n0 = unit(cross(d10, d20))
            let n1 = unit(cross(n0, d20))
            let n2 = unit(cross(d10, n0))
            let n3 = unit(cross(n0, d12))
            var length = dot(d10, n3)
            let normals = [n0, n1, n2, n3]
            // Two separate checks, in wkclt's order. On loading, CheckMetricsTriData drops slivers
            // from the octree (CalcTriMetrics: Heron's formula from the squared sides; a NaN from a
            // zero-length side passes, as it does there). Later, CalcNormalsTriData zeroes the
            // stored height of a triangle whose own height is degenerate, after the octree is
            // built, so that triangle stays in it.
            let x = p1 - p0, y = p2 - p1, z = p0 - p2
            let a2 = dot(x, x), b2 = dot(y, y), c2 = dot(z, z)
            let area = ((2 * (a2 * b2 + a2 * c2 + b2 * c2) - a2 * a2 - b2 * b2 - c2 * c2) * 0.0625).squareRoot()
            let h = [2 * area / a2.squareRoot(), 2 * area / b2.squareRoot(), 2 * area / c2.squareRoot()]
            let minHeight = h[0] < h[1] ? (h[0] < h[2] ? h[0] : h[2]) : (h[1] < h[2] ? h[1] : h[2]) // MinMax3p
            let ok = !(area < profile.minArea || minHeight < profile.minHeight)
            if !length.isNormal || abs(length) < profile.minHeight || !normals.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) {
                length = 0
            }
            if !ok { dropped += 1 }
            tris.append(Tri(pt: (p0, p1, p2), normals: normals.map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) },
                            length: Float(length), flag: flag))
            valid.append(ok)
        }
        guard valid.contains(true), tris.count < 0x10000 else { return Result(data: Data(), dropped: dropped) }

        // MARK: Octree shape (CreateOctreeKCL)
        var lo = tris[0].pt.0, hi = tris[0].pt.0
        for t in tris { for p in [t.pt.0, t.pt.1, t.pt.2] { lo = pointwiseMin(lo, p); hi = pointwiseMax(hi, p) } }
        let blow = Double(profile.blow)
        var minOctree = D3(), relevant = [Int](repeating: 0, count: 3), mask = [UInt32](repeating: 0, count: 3)
        for p in 0..<3 {
            minOctree[p] = lo[p].rounded(.down) - blow
            let span = hi[p] + blow - minOctree[p]
            let e = span > 0 ? Int(frexp(span).1) : 0 // frexp: span = m * 2^e, m in [0.5, 1)
            relevant[p] = max(0, e)
            mask[p] = relevant[p] >= 32 ? 0 : ~UInt32(0) << UInt32(relevant[p])
        }
        var maxBits = Int(log(Double(tris.count)) / log(2))
        maxBits = min(10, max(5, maxBits))
        var rshift = 1
        while 1 << rshift < profile.minCubeSize { rshift += 1 }
        var nbits = [0, 0, 0]
        while true {
            nbits = relevant.map { max(0, $0 - rshift) }
            if nbits.reduce(0, +) <= maxBits { break }
            rshift += 1
        }

        // MARK: Triangles in whole units relative to the octree (setup_oct_tri)
        struct ITri { var pt: [[Int]]; var lo: [Int]; var hi: [Int] }
        let itris: [ITri] = tris.map { t in
            let pts = [t.pt.0, t.pt.1, t.pt.2].map { v in (0..<3).map { Int(Int32(bitPattern: UInt32(truncatingIfNeeded: Int64((v[$0] - minOctree[$0]).rounded())))) } }
            return ITri(pt: pts, lo: (0..<3).map { a in pts.map { $0[a] }.min()! }, hi: (0..<3).map { a in pts.map { $0[a] }.max()! })
        }

        /// OctCubeTriangleOverlaped: Akenine-Moller triangle/box test on the padded cube.
        func overlaps(_ cmin: [Int], _ cmax: [Int], _ t: ITri) -> Bool {
            for a in 0..<3 where t.lo[a] > cmax[a] || t.hi[a] < cmin[a] { return false }
            let half = Double((cmax[0] - cmin[0]) / 2)
            let mid = (0..<3).map { Double(cmin[$0]) + half }
            let v0 = D3(Double(t.pt[0][0]) - mid[0], Double(t.pt[0][1]) - mid[1], Double(t.pt[0][2]) - mid[2])
            let v1 = D3(Double(t.pt[1][0]) - mid[0], Double(t.pt[1][1]) - mid[1], Double(t.pt[1][2]) - mid[2])
            let v2 = D3(Double(t.pt[2][0]) - mid[0], Double(t.pt[2][1]) - mid[1], Double(t.pt[2][2]) - mid[2])
            let e = [v1 - v0, v2 - v1, v0 - v2]
            func test(_ pa: Double, _ pb: Double, _ fa: Double, _ fb: Double) -> Bool {
                let mn = min(pa, pb), mx = max(pa, pb), rad = (fa + fb) * half
                return !(mn > rad || mx < -rad)
            }
            for (k, ed) in e.enumerated() {
                let fx = abs(ed.x), fy = abs(ed.y), fz = abs(ed.z)
                // X axis
                let (xa, xb): (D3, D3) = k == 2 ? (v0, v1) : (v0, v2)
                guard test(ed.z * xa.y - ed.y * xa.z, ed.z * xb.y - ed.y * xb.z, fz, fy) else { return false }
                // Y axis
                let (ya, yb): (D3, D3) = k == 2 ? (v0, v1) : (v0, v2)
                guard test(-ed.z * ya.x + ed.x * ya.z, -ed.z * yb.x + ed.x * yb.z, fz, fx) else { return false }
                // Z axis
                let (za, zb): (D3, D3) = k == 1 ? (v0, v1) : (v1, v2)
                guard test(ed.y * za.x - ed.x * za.y, ed.y * zb.x - ed.x * zb.y, fy, fx) else { return false }
            }
            let normal = cross(e[0], e[1])
            var vmin = D3(), vmax = D3()
            for p in 0..<3 {
                let v = v0[p]
                if normal[p] > 0 { vmin[p] = -half - v; vmax[p] = half - v } else { vmin[p] = half - v; vmax[p] = -half - v }
            }
            return dot(normal, vmin) <= 0 && dot(normal, vmax) >= 0
        }

        // MARK: Recursion (CalcCube)
        var olist = [UInt32](repeating: 0, count: (1 << nbits[0]) * (1 << nbits[1]) * (1 << nbits[2]))
        var tlist: [UInt16] = []
        var runStart: [[UInt16]: Int] = [:]   // every suffix of every list in tlist -> its first offset
        func calcCube(_ cmin: [Int], size: Int, depth: Int, candidates: [Int]) -> UInt32 {
            let b = profile.blow
            let pmin = cmin.map { $0 - b }, pmax = cmin.map { $0 + size + b }
            let inside = candidates.filter { overlaps(pmin, pmax, itris[$0]) }
            let depth = depth + 1
            if size <= profile.maxCubeSize && inside.count <= profile.maxTriangles || size <= profile.minCubeSize || depth > profile.maxDepth {
                guard !inside.isEmpty else { return 0 }
                let list = inside.map { UInt16($0 + 1) } + [0]
                // Reuse an identical run anywhere in the lists written so far. A list's only 0 is its
                // terminator, so any match is a suffix of an earlier list: look those up instead of
                // scanning tlist (quadratic, minutes per track in a Debug build).
                if let start = runStart[list] { return 0x8000_0000 | UInt32(start * 2) }
                let result = 0x8000_0000 | UInt32(tlist.count * 2)
                for i in list.indices where runStart[Array(list[i...])] == nil { runStart[Array(list[i...])] = tlist.count + i }
                tlist += list
                return result
            }
            let at = olist.count
            olist += [UInt32](repeating: 0, count: 8)
            let half = size / 2
            var k = at
            for z in 0..<2 { for y in 0..<2 { for x in 0..<2 {
                let r = calcCube([cmin[0] + x * half, cmin[1] + y * half, cmin[2] + z * half], size: half, depth: depth, candidates: inside)
                olist[k] = r; k += 1
            }}}
            return UInt32(at * 4)
        }
        let cube = 1 << rshift
        let all = tris.indices.filter { valid[$0] }
        var root = 0
        for z in 0..<(1 << nbits[2]) { for y in 0..<(1 << nbits[1]) { for x in 0..<(1 << nbits[0]) {
            olist[root] = calcCube([x * cube, y * cube, z * cube], size: cube, depth: 0, candidates: all)
            root += 1
        }}}
        if tlist.isEmpty { tlist = [0] }

        // Absolute offsets -> relative to each node's 8-entry group (the root group as one).
        let tsize = tlist.count * 2
        var toffset = UInt32(olist.count * 4)
        let nullOffset = (UInt32(tsize) + toffset - 4) | 0x8000_0000
        toffset -= 2 // lists are read from the u16 before their first entry
        var idx = 0, end = (1 << nbits[0]) * (1 << nbits[1]) * (1 << nbits[2])
        while idx < olist.count {
            let base = UInt32(idx * 4)
            while idx < end {
                let v = olist[idx]
                olist[idx] = v == 0 ? nullOffset - base : (v & 0x8000_0000 != 0 ? v &+ toffset &- base : v - base)
                idx += 1
            }
            end = idx + 8
        }

        // MARK: Vertices and normals, each value stored once (CreateRawKCL)
        // Stored once per exact bit pattern (so -0.0 and 0.0 stay apart, as in wkclt).
        var vertices: [SIMD3<Float>] = [], vertexIndex: [SIMD3<UInt32>: Int] = [:]
        var normals: [SIMD3<Float>] = [], normalIndex: [SIMD3<UInt32>: Int] = [:]
        func insert(_ v: SIMD3<Float>, _ list: inout [SIMD3<Float>], _ index: inout [SIMD3<UInt32>: Int]) -> Int {
            let key = SIMD3(v.x.bitPattern, v.y.bitPattern, v.z.bitPattern)
            if let i = index[key] { return i }
            list.append(v); index[key] = list.count - 1; return list.count - 1
        }
        var roundTable = [17, 14, 11, 8, 6, 4, 3, 2, 1, 0][...]
        var prisms: [[Int]] = []
        while true {
            vertices = []; vertexIndex = [:]; normals = []; normalIndex = [:]; prisms = []
            for t in tris {
                let v = SIMD3<Float>(Float(t.pt.0.x), Float(t.pt.0.y), Float(t.pt.0.z))
                prisms.append([insert(v, &vertices, &vertexIndex)] + t.normals.map { insert($0, &normals, &normalIndex) })
            }
            if normals.count < 0x10000 { break }
            // Too many normals: truncate them a step coarser and try again.
            guard let r = roundTable.popFirst(), r > 0 else { return Result(data: Data(), dropped: dropped) }
            for i in tris.indices { tris[i].normals = tris[i].normals.map { $0.map { ldexpf(truncf(ldexpf($0, Int32(r))), -Int32(r)) } } }
        }

        // MARK: File
        let w = MutableDataWriter()
        let vertexOffset = 0x3C
        let normalOffset = vertexOffset + vertices.count * 12
        let triangleOffset = normalOffset + normals.count * 12
        let octreeOffset = triangleOffset + tris.count * 16
        w.putU32(UInt32(vertexOffset)); w.putU32(UInt32(normalOffset))
        w.putU32(UInt32(triangleOffset - 0x10)); w.putU32(UInt32(octreeOffset))
        w.putFloat32(prismThickness)
        for p in 0..<3 { w.putFloat32(Float(minOctree[p])) }
        for p in 0..<3 { w.putU32(mask[p]) }
        w.putU32(UInt32(rshift)); w.putU32(UInt32(nbits[0])); w.putU32(UInt32(nbits[0] + nbits[1]))
        w.putFloat32(sphereRadius)
        for v in vertices { w.putFloat32(v.x); w.putFloat32(v.y); w.putFloat32(v.z) }
        for n in normals { w.putFloat32(n.x); w.putFloat32(n.y); w.putFloat32(n.z) }
        for (t, p) in zip(tris, prisms) {
            w.putFloat32(t.length)
            for i in p { w.putU16(UInt16(i)) }
            w.putU16(t.flag)
        }
        for v in olist { w.putU32(v) }
        for v in tlist { w.putU16(v) }
        return Result(data: w.data, dropped: dropped)
    }
}

nonisolated private extension SIMD3 where Scalar == Float {
    func map(_ f: (Float) -> Float) -> SIMD3<Float> { SIMD3(f(x), f(y), f(z)) }
}
