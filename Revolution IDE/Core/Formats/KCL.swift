import Foundation

/// Mario Kart Wii's collision-mesh format: a big-endian octree of triangular prisms used for fast
/// collision detection against track geometry (walls, road surfaces, fall boundaries, etc.).
/// Structure per the tockdom wiki "KCL (File Format)" page, cross-checked against
/// KillzXGaming's KCollisionLibrary (MIT) reader/writer and Nintendo's decompiled
/// `DynamicCollisionObj::updateCollisionHeader` / `KCollisionOctree::searchBlock`.
///
/// Only the single-model "V1 with sphere radius" header (0x3C bytes) that Mario Kart Wii itself
/// uses is written; other games' KCL variants (no sphere radius, DS fixed-point, or the
/// multi-model "V2" wrapper used by newer titles) are not this app's concern.
nonisolated struct KCLTriangle: Codable {
    var v0 = Vec3()
    var v1 = Vec3()
    var v2 = Vec3()
    /// 16-bit collision flag: bits 0-4 base surface type, 5-7 variant, 8-10 BLIGHT index,
    /// 11-12 wheel depth, 13-15 collision-effect bits. See `kclBaseTypeName`.
    var attribute: UInt16 = 0
    /// Double Dash (.bco) only, see `BCO`: the camera code (0x19) and the settings word (0x20).
    var bcoCamera: UInt8 = 1
    var bcoSettings: UInt32 = 0
    /// The source model's material this triangle came from: editor-only (the KCL editor lists
    /// surfaces by it), never written to the file.
    var material: String?

    /// For triangles coming from an .obj, whose winding is often inconsistent: a floor- or
    /// ceiling-like face (|normal.y| at least 0.3 of its length) is turned to face up, since a
    /// prism collides only from its front and karts drive on top. Walls keep their own winding --
    /// their normal's Y sign is just noise, and flipping on it left walls facing away from the
    /// track.
    static func facingUp(_ v0: Vec3, _ v1: Vec3, _ v2: Vec3, attribute: UInt16) -> KCLTriangle {
        let n = Vec3.cross(v1 - v0, v2 - v0)
        let flip = n.length > 0 && abs(n.y) >= 0.3 * n.length && n.y < 0
        return flip ? KCLTriangle(v0: v0, v1: v2, v2: v1, attribute: attribute)
                    : KCLTriangle(v0: v0, v1: v1, v2: v2, attribute: attribute)
    }
}

nonisolated final class KCLDocument {
    var triangles: [KCLTriangle] = []

    /// Depth of a triangular prism along its face normal; collision beyond this depth is ignored.
    /// 300 in every retail Mario Kart Wii KCL (checked across the disc; the wiki gives the same).
    /// A prior default of 30 made generated floors thin enough for a falling kart to pass through.
    var prismThickness: Float = 300
    /// Maximum radius of a sphere that can be reliably collided against this file. Only used when
    /// (re)building the octree, so leaf cubes get padded enough that an object straddling a cube
    /// boundary still finds every prism it could touch. Mario Kart Wii requires this field, and
    /// every retail KCL sets it to 250.
    var sphereRadius: Float = 250
    /// Set when this mesh came from a Mario Kart: Double Dash!! `.bco`, it's then saved back as
    /// one (see `BCO`), and `attribute` holds MKDD's surface type << 8 | variant.
    var bcoSource: BCO.Source?
    var isBCO: Bool { bcoSource != nil }

    init() {}

    // MARK: Parse

    static func parse(_ data: Data) throws -> KCLDocument {
        if BCO.isBCO(data) { return try BCO.parse(data) }
        guard data.count >= 0x38 else { throw WSError.badStructure("Not a KCL file (too small for a header).") }
        let posOffset = Int(data.be32(0x00))
        let nrmOffset = Int(data.be32(0x04))
        let prismOffsetField = Int(data.be32(0x08))
        let blockOffset = Int(data.be32(0x0C))
        guard posOffset >= 0x38, posOffset <= data.count, nrmOffset >= 0, nrmOffset <= data.count,
              blockOffset >= 0, blockOffset <= data.count else {
            throw WSError.badStructure("Not a KCL file (section offsets out of range).")
        }
        // Section 3 (prisms) is stored 0x10 bytes before its real start, since the octree's leaf
        // lists reference prisms with 1-based indices (index 0 means "end of list").
        let prismOffset = prismOffsetField + 0x10

        let doc = KCLDocument()
        doc.prismThickness = data.beFloat32(0x10)
        if posOffset > 56 { doc.sphereRadius = data.beFloat32(0x38) }

        // None of the four sections store their own element count, and per the format docs they
        // may appear in any order, bound each by the next-higher section offset (or EOF).
        // Reading a little too far only yields a few unused trailing entries (alignment padding),
        // never a crash, since every prism index into positions/normals is bounds-checked below.
        let boundaries = [posOffset, nrmOffset, prismOffset, blockOffset, data.count].sorted()
        func upperBound(after start: Int) -> Int { boundaries.first(where: { $0 > start }) ?? data.count }

        let posCount = max(0, (upperBound(after: posOffset) - posOffset) / 12)
        let nrmCount = max(0, (upperBound(after: nrmOffset) - nrmOffset) / 12)
        let prismCount = max(0, (upperBound(after: prismOffset) - prismOffset) / 16)

        var positions: [Vec3] = []; positions.reserveCapacity(posCount)
        for i in 0..<posCount { positions.append(Vec3(data, at: posOffset + i * 12)) }
        var normals: [Vec3] = []; normals.reserveCapacity(nrmCount)
        for i in 0..<nrmCount { normals.append(Vec3(data, at: nrmOffset + i * 12)) }

        doc.triangles.reserveCapacity(prismCount)
        for i in 0..<prismCount {
            let b = prismOffset + i * 16
            let height = data.beFloat32(b)
            guard height > 0, height.isFinite else { continue } // padding/garbage tail entries
            let posIndex = Int(data.be16(b + 4))
            let faceIndex = Int(data.be16(b + 6))
            let aIndex = Int(data.be16(b + 8))
            let bIndex = Int(data.be16(b + 10))
            let cIndex = Int(data.be16(b + 12))
            let attribute = data.be16(b + 14)
            guard positions.indices.contains(posIndex), normals.indices.contains(faceIndex),
                  normals.indices.contains(aIndex), normals.indices.contains(bIndex), normals.indices.contains(cIndex)
            else { continue }

            // Decode per the wiki's documented algorithm (Mario Kart 7's
            // KDGndCol::PolygonMesh::parseModel, identical to the Wii format):
            //   CrossA = cross(enrm1, fnrm); CrossB = cross(enrm2, fnrm)
            //   Vertex1 = pos
            //   Vertex2 = pos + CrossB * (height / dot(CrossB, enrm3))
            //   Vertex3 = pos + CrossA * (height / dot(CrossA, enrm3))
            let pos = positions[posIndex]
            let faceN = normals[faceIndex], nA = normals[aIndex], nB = normals[bIndex], nC = normals[cIndex]
            let crossA = Vec3.cross(nA, faceN)
            let crossB = Vec3.cross(nB, faceN)
            let dotBC = Vec3.dot(crossB, nC)
            let dotAC = Vec3.dot(crossA, nC)
            guard dotBC != 0, dotAC != 0 else { continue }

            let v0 = pos
            let v1 = pos + crossB * (height / dotBC)
            let v2 = pos + crossA * (height / dotAC)
            guard v1.x.isFinite, v2.x.isFinite else { continue }
            doc.triangles.append(KCLTriangle(v0: v0, v1: v1, v2: v2, attribute: attribute))
        }
        return doc
    }

    // MARK: Serialize

    /// Rebuilds a complete, valid Mario Kart Wii KCL file (header + positions + normals + prisms
    /// + a freshly generated collision octree) from `triangles`. The octree is always regenerated
    /// rather than edited in place, it's a derived spatial index, not authored data.
    func serialize() -> Data {
        if let bcoSource { return BCO.serialize(triangles, source: bcoSource) }
        if BuildCompatibility.current == .hardware {
            let built = KCLWiimm.build(triangles, prismThickness: prismThickness, sphereRadius: sphereRadius)
            if !built.data.isEmpty { return built.data }
        }
        return KCLBuilder.build(triangles: triangles, prismThickness: prismThickness, sphereRadius: sphereRadius)
    }
}

// MARK: - Octree builder

private nonisolated final class KCLOctreeNode {
    var children: [KCLOctreeNode]?
    var triangleIndices: [UInt16] = []
    /// Filled in once the tree is flattened into BFS batches; the index into that batch array
    /// where this node's own 8 children live.
    var childBatchIndex: Int = -1
}

nonisolated enum KCLBuilder {
    /// Mirrors community-tested defaults used by KillzXGaming's KCollisionLibrary and Wiimm's SZS
    /// tools for Mario Kart Wii track collision.
    // Root cube up to 16384 and leaves no smaller than 512: what retail uses (beginner_course:
    // 16384 root cube, leaves 512-16384, ~8 triangles each). With the retail 250 sphere-radius
    // padding, the old 2048/32 limits made octrees ~3x retail size (10 MB for a 23k-triangle
    // track); these reproduce retail's own sizes to within 3% on beginner_course/castle_course.
    private static let maxRootCubeSize: Float = 16384
    private static let minCubeSize: Float = 512
    private static let maxTrianglesPerLeaf = 10
    private static let maxOctreeDepth = 10
    /// Upper bound on the octree's top-level grid. A retail Mario Kart Wii course uses 32 root
    /// blocks; this leaves plenty of headroom while still ruling out the pathological grids a
    /// flat-and-wide track otherwise produces.
    private static let maxRootBlocks = 512
    private static let boundsPadding: Float = 50
    private static let maxIndexableCount = 65535 // prism/position/normal indices are UInt16

    /// Exact triangle-versus-axis-aligned-box overlap, by the separating axis theorem: the two
    /// shapes miss each other exactly when some axis exists on which their projections don't
    /// overlap, and for this pair only 13 axes need checking (the box's 3 face normals, the
    /// triangle's own plane normal, and the 9 cross products of their edge directions).
    static func triangleIntersectsBox(_ v0: Vec3, _ v1: Vec3, _ v2: Vec3, boxMin: Vec3, boxMax: Vec3) -> Bool {
        let center = (boxMin + boxMax) * 0.5
        let halfSize = (boxMax - boxMin) * 0.5
        let a = v0 - center, b = v1 - center, c = v2 - center
        let edges = [b - a, c - b, a - c]

        // The 3 box face normals.
        for axis in 0..<3 {
            let values = [component(a, axis), component(b, axis), component(c, axis)]
            if values.min()! > component(halfSize, axis) || values.max()! < -component(halfSize, axis) { return false }
        }

        // The triangle's plane against the box.
        let normal = Vec3.cross(edges[0], edges[1])
        let radius = abs(normal.x) * halfSize.x + abs(normal.y) * halfSize.y + abs(normal.z) * halfSize.z
        let distance = Vec3.dot(normal, a)
        if abs(distance) > radius { return false }

        // The 9 edge-cross-axis tests.
        for edge in edges {
            for axis in 0..<3 {
                var unit = Vec3()
                switch axis {
                case 0: unit = Vec3(x: 1)
                case 1: unit = Vec3(y: 1)
                default: unit = Vec3(z: 1)
                }
                let separating = Vec3.cross(unit, edge)
                guard separating.length > 1e-12 else { continue } // parallel edge: no new axis
                let projections = [Vec3.dot(separating, a), Vec3.dot(separating, b), Vec3.dot(separating, c)]
                let extent = abs(separating.x) * halfSize.x + abs(separating.y) * halfSize.y + abs(separating.z) * halfSize.z
                if projections.min()! > extent || projections.max()! < -extent { return false }
            }
        }
        return true
    }

    private static func component(_ v: Vec3, _ axis: Int) -> Float {
        axis == 0 ? v.x : (axis == 1 ? v.y : v.z)
    }

    static func build(triangles: [KCLTriangle], prismThickness: Float, sphereRadius: Float) -> Data {
        guard !triangles.isEmpty else { return Data() }

        // MARK: Encode triangles into (position, 4 normals, height, attribute) prisms, per the
        // wiki's documented encoding (mirrors SMG's DynamicCollisionObj::updateTriangle):
        //   fnrm = normalize(cross(V2-V1, V3-V1))
        //   enrm1 = normalize(cross(fnrm, V3-V1)); enrm2 = normalize(-cross(fnrm, V2-V1))
        //   enrm3 = normalize(cross(fnrm, V2-V3)); height = dot(V2-V1, enrm3)
        var positions: [Vec3] = []
        var normals: [Vec3] = []
        var positionLookup: [String: Int] = [:]
        var normalLookup: [String: Int] = [:]
        // How coarsely values are merged: nil = only bit-identical ones. Merging near-equal
        // normals is lossy, a corner is rebuilt from its normals and height, so on a long
        // triangle a 1e-4 change in a normal moved a corner by ~19 units on retail
        // beginner_course. So merge exactly, and only coarsen (below) when a big mesh would
        // otherwise overflow the format's 65535-normal limit.
        var mergeScale: Float? = nil
        func indexOf(_ v: Vec3, values: inout [Vec3], lookup: inout [String: Int]) -> Int {
            func rounded(_ f: Float) -> Float { mergeScale.map { (f * $0).rounded() / $0 } ?? f }
            let key = "\(rounded(v.x)),\(rounded(v.y)),\(rounded(v.z))"
            if let existing = lookup[key] { return existing }
            let index = values.count
            values.append(v)
            lookup[key] = index
            return index
        }

        struct Prism { var height: Float; var posIndex: Int; var faceIndex: Int; var aIndex: Int; var bIndex: Int; var cIndex: Int; var attribute: UInt16 }
        var prisms: [Prism] = []
        /// The three corners of each encoded prism, kept for the exact octree overlap test below.
        var prismVertices: [(Vec3, Vec3, Vec3)] = []
        var prismBoundsMin: [Vec3] = []
        var prismBoundsMax: [Vec3] = []

        func tryEncode(_ v0: Vec3, _ v1: Vec3, _ v2: Vec3, _ attribute: UInt16) -> Bool {
            let rawDirection = Vec3.cross(v1 - v0, v2 - v0)
            guard rawDirection.length > 0.0001 else { return false }
            let direction = rawDirection.normalized()
            let normalA = Vec3.cross(direction, v2 - v0).normalized()
            let normalB = (Vec3.cross(direction, v1 - v0) * -1).normalized()
            let normalC = Vec3.cross(direction, v1 - v2).normalized()
            let height = Vec3.dot(v1 - v0, normalC)
            guard height > 0.0001, height.isFinite else { return false }

            let posIndex = indexOf(v0, values: &positions, lookup: &positionLookup)
            let faceIndex = indexOf(direction, values: &normals, lookup: &normalLookup)
            let aIndex = indexOf(normalA, values: &normals, lookup: &normalLookup)
            let bIndex = indexOf(normalB, values: &normals, lookup: &normalLookup)
            let cIndex = indexOf(normalC, values: &normals, lookup: &normalLookup)
            prisms.append(Prism(height: height, posIndex: posIndex, faceIndex: faceIndex, aIndex: aIndex, bIndex: bIndex, cIndex: cIndex, attribute: attribute))
            prismVertices.append((v0, v1, v2))
            prismBoundsMin.append(Vec3(x: min(v0.x, v1.x, v2.x), y: min(v0.y, v1.y, v2.y), z: min(v0.z, v1.z, v2.z)))
            prismBoundsMax.append(Vec3(x: max(v0.x, v1.x, v2.x), y: max(v0.y, v1.y, v2.y), z: max(v0.z, v1.z, v2.z)))
            return true
        }

        // Winding is kept exactly as given: it decides which side of a prism collides, and a retail
        // KCL legitimately has downward-facing triangles (ceilings, bridge undersides). This used
        // to flip every triangle to face up, so merely re-saving a retail KCL (e.g. after editing
        // one flag) turned all of those around. Sloppy .obj winding is fixed on import instead --
        // see `KCLTriangle.facingUp`.
        for scale in [nil, 1_000_000, 100_000, 10_000] as [Float?] {
            mergeScale = scale
            positions = []; normals = []; positionLookup = [:]; normalLookup = [:]
            prisms = []; prismVertices = []; prismBoundsMin = []; prismBoundsMax = []
            for t in triangles { _ = tryEncode(t.v0, t.v1, t.v2, t.attribute) }
            if normals.count <= maxIndexableCount && positions.count <= maxIndexableCount { break }
        }
        guard !prisms.isEmpty, prisms.count <= maxIndexableCount,
              positions.count <= maxIndexableCount, normals.count <= maxIndexableCount else { return Data() }

        // MARK: Bounding box and octree shape (mirrors DynamicCollisionObj::updateCollisionHeader)
        // Over every corner of every triangle, not over `positions`, which only holds each
        // prism's *first* vertex (the other two are reconstructed from normals and a height, so
        // they never appear in it). Measuring the area from `positions` left every triangle that
        // reached beyond its own first corner partly outside the octree, and a point outside the
        // octree has no collision at all: karts fell straight through those edges of the track.
        var boundsMin = Vec3(x: .greatestFiniteMagnitude, y: .greatestFiniteMagnitude, z: .greatestFiniteMagnitude)
        var boundsMax = Vec3(x: -.greatestFiniteMagnitude, y: -.greatestFiniteMagnitude, z: -.greatestFiniteMagnitude)
        for i in prisms.indices {
            let lo = prismBoundsMin[i], hi = prismBoundsMax[i]
            boundsMin = Vec3(x: min(boundsMin.x, lo.x), y: min(boundsMin.y, lo.y), z: min(boundsMin.z, lo.z))
            boundsMax = Vec3(x: max(boundsMax.x, hi.x), y: max(boundsMax.y, hi.y), z: max(boundsMax.z, hi.z))
        }
        let areaMin = boundsMin - Vec3(x: boundsPadding, y: boundsPadding, z: boundsPadding)
        let areaMax = boundsMax + Vec3(x: boundsPadding, y: boundsPadding, z: boundsPadding)
        let size = areaMax - areaMin

        func nextExponent(_ v: Float) -> Int { v <= 1 ? 0 : Int(ceil(log2(Double(v)))) }
        let expX = nextExponent(size.x), expY = nextExponent(size.y), expZ = nextExponent(size.z)
        // Root cube size follows the smallest dimension, as real files do, but a track is
        // typically flat and wide, so that alone can ask for (2^expX / cube) * (2^expZ / cube)
        // root blocks, which for one real course meant 16384 of them and a 2 MB octree for a few
        // hundred triangles. Grow the cube until the root grid is a sane size; every level of
        // growth quarters the block count for a flat track.
        var cubeSizePower = min(nextExponent(min(size.x, min(size.y, size.z))), nextExponent(maxRootCubeSize))
        func rootBlockCount(_ power: Int) -> Int {
            [expX, expY, expZ].reduce(1) { $0 * max(1, 1 << max(0, $1 - power)) }
        }
        while cubeSizePower < 20, rootBlockCount(cubeSizePower) > maxRootBlocks { cubeSizePower += 1 }
        let cubeSize = Float(1 << max(0, cubeSizePower))

        let xBlocksShift = max(0, expX - cubeSizePower)
        let xyBlocksShift = xBlocksShift + max(0, expY - cubeSizePower)
        let maskShift: (Int) -> UInt32 = { exp in exp >= 32 ? 0 : (UInt32.max << exp) }

        let cubeCountX = max(1, Int(Float(1 << max(0, expX)) / cubeSize))
        let cubeCountY = max(1, Int(Float(1 << max(0, expY)) / cubeSize))
        let cubeCountZ = max(1, Int(Float(1 << max(0, expZ)) / cubeSize))

        // MARK: Recursive subdivision. A triangle goes in a cube when it really intersects that
        // cube, tested exactly (separating-axis), padded by a constant distance of `sphereRadius`
        // (per the format docs, not double it) so a collision sphere near a cube boundary still
        // finds every prism it could touch. A cheap bounding-box test rejects most candidates
        // first.
        //
        // The exact test matters more than it looks: with only bounding boxes, one large diagonal
        // triangle "overlaps" every cube its box spans, so a low-polygon track (a few hundred big
        // triangles) never gets under the per-leaf limit and subdivides to maximum depth
        // everywhere. That turned a 310-triangle test track into a 2 MB octree.
        //
        // That padding is a *fixed* distance, independent of cube size, so it must never be
        // let subdivide down to a cube smaller than itself: once cubeSize is in that ballpark, the
        // padded test region is dominated by the margin rather than the cube, every leaf in the
        // area starts spuriously "containing" nearly every nearby triangle, and the triangle count
        // stops shrinking as depth increases. Left unbounded, that turned one real ~520KB course
        // into three-figure-megabyte output (millions of nodes deep) instead of a valid octree --
        // `minCubeSize` alone doesn't protect against it since sphereRadius can exceed it.
        let margin = max(sphereRadius, 50)
        let leafCubeSize = max(minCubeSize, margin)
        // Depth alone doesn't bound total node count: geometry where a cube's candidates barely
        // thin out per split (e.g. a few huge triangles spanning most of the level) still fully
        // subdivides every root cube to maxOctreeDepth, and 8^10 nodes per root is enough to
        // exhaust memory before returning. Once the whole build has made this many nodes, stop
        // splitting and accept oversized leaves instead of crashing.
        var nodeCount = 0
        let maxNodes = 2_000_000
        func buildNode(candidates: [Int], cubeMin: Vec3, cubeSize: Float, depth: Int) -> KCLOctreeNode {
            nodeCount += 1
            let expandedMin = cubeMin - Vec3(x: margin, y: margin, z: margin)
            let expandedMax = cubeMin + Vec3(x: cubeSize, y: cubeSize, z: cubeSize) + Vec3(x: margin, y: margin, z: margin)
            let overlapping = candidates.filter { i in
                guard prismBoundsMin[i].x <= expandedMax.x, prismBoundsMax[i].x >= expandedMin.x,
                      prismBoundsMin[i].y <= expandedMax.y, prismBoundsMax[i].y >= expandedMin.y,
                      prismBoundsMin[i].z <= expandedMax.z, prismBoundsMax[i].z >= expandedMin.z
                else { return false }
                let (v0, v1, v2) = prismVertices[i]
                return triangleIntersectsBox(v0, v1, v2, boxMin: expandedMin, boxMax: expandedMax)
            }
            let node = KCLOctreeNode()
            if overlapping.count <= maxTrianglesPerLeaf || cubeSize <= leafCubeSize || depth >= maxOctreeDepth || nodeCount >= maxNodes {
                node.triangleIndices = overlapping.sorted().map { UInt16($0) }
                return node
            }
            let half = cubeSize / 2
            var children: [KCLOctreeNode] = []
            children.reserveCapacity(8)
            for z in 0..<2 { for y in 0..<2 { for x in 0..<2 {
                let childMin = cubeMin + Vec3(x: Float(x), y: Float(y), z: Float(z)) * half
                children.append(buildNode(candidates: overlapping, cubeMin: childMin, cubeSize: half, depth: depth + 1))
            }}}
            node.children = children
            return node
        }

        let allIndices = Array(0..<prisms.count)
        var roots: [KCLOctreeNode] = []
        roots.reserveCapacity(cubeCountX * cubeCountY * cubeCountZ)
        for z in 0..<cubeCountZ { for y in 0..<cubeCountY { for x in 0..<cubeCountX {
            let cubeMin = areaMin + Vec3(x: Float(x), y: Float(y), z: Float(z)) * cubeSize
            roots.append(buildNode(candidates: allIndices, cubeMin: cubeMin, cubeSize: cubeSize, depth: 0))
        }}}

        // MARK: Flatten into BFS batches (root batch, then every node's 8-child batch in
        // discovery order) so each node's key can reference its children by a simple byte offset.
        var batches: [[KCLOctreeNode]] = [roots]
        var cursor = 0
        while cursor < batches.count {
            for node in batches[cursor] where node.children != nil {
                node.childBatchIndex = batches.count
                batches.append(node.children!)
            }
            cursor += 1
        }
        var batchStart: [Int] = []
        var acc = 0
        for batch in batches { batchStart.append(acc); acc += batch.count * 4 }
        let totalKeyBytes = acc

        // Deduplicate identical leaf index-lists so repeated empty/simple regions share storage.
        var indexListOffset: [[UInt16]: Int] = [:]
        var indexListOrder: [[UInt16]] = []
        var poolOffset = 0
        for batch in batches {
            for node in batch where node.children == nil {
                if indexListOffset[node.triangleIndices] == nil {
                    indexListOffset[node.triangleIndices] = poolOffset
                    indexListOrder.append(node.triangleIndices)
                    poolOffset += (node.triangleIndices.count + 1) * 2 // +1 for the u16 terminator
                }
            }
        }

        // MARK: Write the octree section: all node keys in BFS order, then the trailing pool of
        // 1-based (V1 format) triangle-index lists, each terminated by 0x0000.
        let octreeWriter = MutableDataWriter()
        for (batchIndex, batch) in batches.enumerated() {
            for node in batch {
                if let children = node.children {
                    _ = children
                    let key = UInt32(batchStart[node.childBatchIndex] - batchStart[batchIndex])
                    octreeWriter.putU32(key)
                } else {
                    let listPos = totalKeyBytes + indexListOffset[node.triangleIndices]!
                    let key = 0x8000_0000 | UInt32(listPos - batchStart[batchIndex] - 2)
                    octreeWriter.putU32(key)
                }
            }
        }
        for indices in indexListOrder {
            for i in indices { octreeWriter.putU16(UInt16(i + 1)) } // 1-based; 0 is the terminator
            octreeWriter.putU16(0)
        }

        // MARK: Assemble the file.
        let headerSize = 0x3C
        let posOffset = headerSize
        let nrmOffset = posOffset + positions.count * 12
        let prismRealOffset = nrmOffset + normals.count * 12 + 0x10 // +0x10 dummy "prism 0" gap
        let prismOffsetField = prismRealOffset - 0x10
        let blockOffset = prismRealOffset + prisms.count * 16

        let w = MutableDataWriter()
        w.putU32(UInt32(posOffset))
        w.putU32(UInt32(nrmOffset))
        w.putU32(UInt32(prismOffsetField))
        w.putU32(UInt32(blockOffset))
        w.putFloat32(prismThickness)
        areaMin.write(w)
        w.putU32(maskShift(expX))
        w.putU32(maskShift(expY))
        w.putU32(maskShift(expZ))
        w.putU32(UInt32(cubeSizePower))
        w.putU32(UInt32(xBlocksShift))
        w.putU32(UInt32(xyBlocksShift))
        w.putFloat32(sphereRadius)

        for p in positions { p.write(w) }
        for n in normals { n.write(w) }
        w.pad(to: w.data.count + 0x10) // dummy prism before the 1-indexed real array

        for p in prisms {
            w.putFloat32(p.height)
            w.putU16(UInt16(p.posIndex))
            w.putU16(UInt16(p.faceIndex))
            w.putU16(UInt16(p.aIndex))
            w.putU16(UInt16(p.bIndex))
            w.putU16(UInt16(p.cIndex))
            w.putU16(p.attribute)
        }
        w.putData(octreeWriter.data)
        return w.data
    }
}

// MARK: - Collision flag reference

/// Base surface type (bits 0-4 of the 16-bit collision flag), per the "KCL Flag" wiki page.
/// The remaining bits (variant, BLIGHT index, wheel depth, collision-effect) are shown as raw hex
/// rather than fully decoded, this is a best-effort reference for the editor UI, not a full
/// flag encoder.
private nonisolated let kclBaseTypeNames: [String] = [
    "Road", "Slippery Road 1", "Weak Off-road", "Off-road", "Heavy Off-road", "Slippery Road 2",
    "Boost", "Boost Ramp", "Jump Pad", "Item Road", "Solid Fall", "Moving Water", "Wall",
    "Invisible Wall", "Item Wall", "Wall 2", "Fall Boundary", "Cannon Trigger",
    "Force Recalculation", "Half-Pipe Ramp", "Player-Only Wall", "Moving Road", "Sticky Road",
    "Road 2", "Sound Trigger", "Weak Wall", "Effect Trigger", "Item State Modifier",
    "Half-Pipe Invisible Wall", "Rotating Road", "Special Wall", "Invisible Wall 2",
]

/// Variant (bits 5-7 of the flag) names for every base type the wiki documents a meaning for each
/// of the 8 variant values, a terrain/visual sub-type, a trick length, a launch target, and so
/// on. Sound Trigger's variants mean something different on every track slot, so they're just numbered.
private nonisolated let kclVariantNames: [Int: [String]] = [
    0: ["Normal Road", "Dirt with GFX", "Dirt without GFX", "Smooth", "Wood", "Snow with GFX", "Metal Grate", "Road with Sound Cutoff"], // Road
    1: ["White Sand", "Dirt", "Water (unused)", "Snow (unused)", "Grass (unused)", "Yellow Sand", "Sand without GFX (unused)", "Dirt without GFX (unused)"], // Slippery Road 1
    2: ["Orange Sand", "Dirt", "Water", "Grass, Darker GFX", "Sand, Lighter GFX", "Carpet", "Gravel", "Gravel, Different Impact SFX"], // Weak Off-road
    3: ["Sand", "Dirt", "Mud", "Water without GFX (unused)", "Grass", "Sand, Lighter GFX", "Gravel, Different Impact", "Carpet"], // Off-road
    4: ["Sand (unused)", "Dirt (unused)", "Mud", "Flowers", "Grass", "Snow", "Sand", "Dirt without GFX (unused)"], // Heavy Off-road
    5: ["Ice", "Mud without GFX (unused)", "Water without GFX (unused)", "Water without GFX (unused)", "Water without GFX (unused)", "Water without GFX (unused)", "Normal Road, Different Sound (unused)", "Normal Road, Different Sound (unused)"], // Slippery Road 2
    6: ["Default", "Rotates Counterclockwise with casino_roulette", "Unknown (unused)", "Unknown (unused)", "Unknown (unused)", "Unknown (unused)", "Unknown (unused)", "Unknown (unused)"], // Boost
    7: ["Double Flip Trick (85/95 frames)", "Single Flip Trick (70/80 frames)", "Stunt Trick (unused, 40/45 frames)", "Stunt Trick (unused, 40/45 frames)", "Stunt Trick (unused, 40/45 frames)", "Stunt Trick (unused, 40/45 frames)", "Stunt Trick (unused, 40/45 frames)", "Stunt Trick (unused, 40/45 frames)"], // Boost Ramp
    8: ["50 Speed, 35 Height (GBA Bowser Castle 3)", "50 Speed, 47 Height (SNES Ghost Valley 2)", "59 Speed, 30 Height (GBA Shy Guy Beach)", "73 Speed, 45 Height (Mushroom Gorge Ramps)", "73 Speed, 53 Height (Mushroom Gorge Bouncy Mushrooms)", "56 Speed, 50 Height (Chain Chomp Wheel)", "55 Speed, 35 Height (DS Yoshi Falls, Funky Stadium)", "56 Speed, 50 Height (unused, Gondola Roof)"], // Jump Pad
    9: ["Unknown", "Unknown", "Metal Grates", "Wooden Paths/Grass/Mushrooms", "Unknown (unused)", "Grass/Bushes", "Unknown (unused)", "Unknown (unused)"], // Item Road
    10: ["Sand", "Sand/Underwater", "Pavement/Tiles", "Ice", "Dirt", "Grass", "Wood", "Dark Sand with GFX"], // Solid Fall
    11: ["Route-Following, Pulls Downward", "Route-Following, Strongly Pulls Downward", "Acceleration Modifier (Settings 1/2)", "Disables Acceleration (Settings 1/2)", "Moving Asphalt (unused, as 0)", "Moving Asphalt (unused, as 0)", "Moving Road (unused, as 0)", "Moving Road (unused, as 0)"], // Moving Water
    12: ["Normal", "Rock", "Metal", "Wood", "Ice", "Bush with GFX", "Rope", "Rubber"], // Wall
    13: ["No Spark/Voice", "Spark and Voice (unused)", "Spark and Voice (unused)", "Same as 0 (unused)", "Same as 0 (unused)", "Same as 0 (unused)", "Same as 0 (unused)", "Same as 0 (unused)"], // Invisible Wall
    14: ["Unknown", "Rock Walls", "Metal Walls", "Unknown", "Unknown (unused)", "Grass/Bushes", "Unknown (unused)", "Unknown (unused)"], // Item Wall
    15: ["Normal", "Rock", "Metal", "Wood", "Ice", "Bush without GFX (unused)", "Rope", "Rubber"], // Wall 2
    16: ["Air Fall", "Water", "Lava", "Icy Water", "Lava without GFX", "Burning Air Fall", "Quicksand", "Short Fall"], // Fall Boundary
    17: ["Cannon Point 0", "Cannon Point 1", "Cannon Point 2", "Cannon Point 3", "Cannon Point 4", "Cannon Point 5", "Cannon Point 6", "Cannon Point 7"], // Cannon Trigger
    18: ["Default", "Unknown (unused)", "Unknown (unused)", "Unknown (unused)", "Unknown (unused)", "Unknown (unused)", "Unknown (unused)", "Unknown (unused)"], // Force Recalculation
    19: ["Default", "Applies Boost (Bowser's Castle)", "Unknown (unused)", "Unknown (unused)", "Unknown (unused)", "Unknown (unused)", "Unknown (unused)", "Unknown (unused)"], // Half-Pipe Ramp
    20: ["Normal (unused)", "Rock (unused)", "Metal (unused)", "Wood", "Ice (unused)", "Bush (unused)", "Rope (unused)", "No SFX/GFX"], // Player-Only Wall
    21: ["Moves West (Escalator/BeltCrossing)", "Moves East/West (by object)", "Moves East (BeltEasy)", "Moves West (BeltEasy)", "Rotates Clockwise (BeltCurveA)", "Rotates Counterclockwise (BeltCurveA)", "Unknown (unused)", "Unknown (unused)"], // Moving Road
    22: ["Wood", "Gravel, Different Impact", "Carpet", "Dirt without GFX", "Wood, Different Impact/Drift", "Normal Road, Slot 4.4", "Normal Road", "Mud with GFX"], // Sticky Road
    23: ["Normal, Lower Pitch", "Carpet", "Grass", "Normal (Green Mushrooms)", "Grass", "Glass Road", "Dirt", "Normal Road, Slot 4.4"], // Road 2
    24: ["Sound 0 (per track slot)", "Sound 1 (per track slot)", "Sound 2 (per track slot)", "Sound 3 (per track slot)", "Sound 4 (per track slot)", "Sound 5 (per track slot)", "Sound 6 (per track slot)", "Sound 7 (per track slot)"], // Sound Trigger
    25: ["Default", "Unknown (unused)", "Unknown (unused)", "Unknown (unused)", "Unknown (unused)", "Unknown (unused)", "Unknown (unused)", "Unknown (unused)"], // Weak Wall
    26: ["Change BLIGHT Index", "Change BLIGHT Index", "Trigger Water Splash", "Activate StarGate", "Half-Pipe Cancellation", "Coin Despawner", "Unknown (Chimneys)", "Unknown (unused)"], // Effect Trigger
    27: ["Default", "Unknown (unused)", "Unknown (unused)", "Unknown (unused)", "Unknown (unused)", "Unknown (unused)", "Unknown (unused)", "Unknown (unused)"], // Item State Modifier
    28: ["Default", "Unknown (unused)", "Unknown (unused)", "Unknown (unused)", "Unknown (unused)", "Unknown (unused)", "Unknown (unused)", "Unknown (unused)"], // Half-Pipe Invisible Wall
    29: ["Rope", "Normal, Different Sound (unused)", "Normal", "Glass", "Carpet", "No Sound, Star Crash (unused)", "Sand (unused)", "Dirt (unused)"], // Rotating Road
    30: ["Cactus Spinout", "No SFX/GFX (Lavafalls)", "Bouncy Wall (unused)", "No SFX/GFX (Finish Line)", "Rainbow Road Railings", "Mushroom Pad Sides", "Metal SFX", "Gate Sides (needs starGate)"], // Special Wall
    31: ["No SFX/GFX", "Same as 0 (unused)", "Same as 0 (unused)", "Same as 0 (unused)", "Same as 0 (unused)", "Same as 0 (unused)", "Same as 0 (unused)", "Same as 0 (unused)"], // Invisible Wall 2
]

/// The named variants (bits 5-7) for a base surface type, if the wiki documents what each of the
/// 8 values means, nil when that base type's variant bits have no documented per-index meaning.
nonisolated func kclVariants(forBase base: Int) -> [String]? {
    kclVariantNames[base]
}

/// Just the base type's own name, with none of `kclFlagName`'s hex suffix, for a submenu title,
/// where the hex value isn't fixed (it depends on which variant gets picked underneath it).
nonisolated func kclBaseTypeName(_ base: Int) -> String {
    kclBaseTypeNames.indices.contains(base) ? kclBaseTypeNames[base] : "Unknown"
}

nonisolated func kclFlagName(_ attribute: UInt16) -> String {
    let base = Int(attribute & 0x1F)
    let variant = Int((attribute >> 5) & 0x7)
    let name = kclBaseTypeNames.indices.contains(base) ? kclBaseTypeNames[base] : "Unknown"
    let hex = String(format: "0x%02X", attribute)
    guard let variants = kclVariantNames[base], variants.indices.contains(variant) else {
        return "\(name) (\(hex))"
    }
    return "\(name) - \(variants[variant]) (\(hex))"
}

nonisolated extension KCLDocument {
    /// What the editor groups triangles by: a KCL flag's base type + variant (bits 0-7), or a
    /// .bco's whole type + variant.
    func surfaceKey(_ attribute: UInt16) -> UInt16 { isBCO ? attribute : attribute & 0xFF }
    /// The base surface type alone (what reference textures link to).
    func baseType(_ attribute: UInt16) -> UInt16 { isBCO ? attribute >> 8 : attribute & 0x1F }
    func flagName(_ attribute: UInt16) -> String { isBCO ? BCO.flagName(attribute) : kclFlagName(attribute) }

    /// The Y of the topmost up-facing triangle under `(x, z)` (a floor, not a wall or ceiling),
    /// falling back to any triangle when only walls/ceilings cover the point. Uses each triangle's
    /// plane rather than a long downward ray, which float precision would round below the surface.
    func floorHeight(x: Float, z: Float) -> Float? {
        var best: Float?, bestFloor: Float?
        for t in triangles {
            let (v0, v1, v2) = (t.v0, t.v1, t.v2)
            let den = (v1.z - v2.z) * (v0.x - v2.x) + (v2.x - v1.x) * (v0.z - v2.z)
            guard abs(den) > 1e-9 else { continue }
            let a = ((v1.z - v2.z) * (x - v2.x) + (v2.x - v1.x) * (z - v2.z)) / den
            let b = ((v2.z - v0.z) * (x - v2.x) + (v0.x - v2.x) * (z - v2.z)) / den
            let c = 1 - a - b
            guard a >= -1e-5, b >= -1e-5, c >= -1e-5 else { continue }
            let y = a * v0.y + b * v1.y + c * v2.y
            if best == nil || y > best! { best = y }
            if (v1.x - v0.x) * (v2.z - v0.z) - (v1.z - v0.z) * (v2.x - v0.x) > 0, bestFloor == nil || y > bestFloor! { bestFloor = y }
        }
        return bestFloor ?? best
    }
}
