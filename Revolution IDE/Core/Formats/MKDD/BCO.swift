import Foundation

/// Mario Kart: Double Dash!! collision (`*_course.bco`), opened into the same `KCLDocument` the KCL
/// editor edits. Layout per mkdd.org's "BCO (File Format)" and Yoshi2's mkdd-collision (whose
/// grid writer is the community's in-game-tested one), checked against every retail course:
///
/// Header (0x2C): "0003", grid width/length (u16), grid origin X/Z and cell size X/Z (s32),
/// material count (u16), pad, then offsets of the grid index lists, triangles, vertices and the
/// material table. The grid (from 0x2C) is 8-byte entries, triangle count (u8), pad, first child
/// (u16, 0 = leaf; children are 4 consecutive quadrants x-/z-, x+/z-, x-/z+, x+/z+) and the first
/// index into the u16 triangle-index lists, one per cell, row by row, then the quadtree levels.
/// Triangles (0x24): vertex indices (u32 x3), plane distance (f32), normal (s16 x3, x10000),
/// type (u8) + variant (u8), min/max X/Z vertex lookup (u8), camera code (u8), neighbours (s16 x3),
/// settings (u32). Vertices: f32 XYZ. Materials (12): type+variant, sound, 2 x u32.
///
/// Saving an unchanged-shape mesh patches the original file in place (only surface types, camera
/// codes and settings change), so it stays byte-identical to retail apart from the edits. A
/// changed shape rebuilds everything the way mkdd-collision does.
nonisolated enum BCO {
    struct Source {
        let original: Data
        /// Vertex positions of every original triangle, in order, a changed shape means a rebuild.
        let geometry: [Float]
        /// Surface types the original used, retail tables don't list them all, and that's kept.
        let types: Set<UInt16>
    }

    static func isBCO(_ d: Data) -> Bool { d.count >= 0x2C && d.asciiString(at: 0, length: 4) == "0003" }

    static func parse(_ d: Data) throws -> KCLDocument {
        guard isBCO(d) else { throw WSError.badStructure("Not a Double Dash collision file (missing '0003' magic).") }
        let triStart = Int(d.be32(0x20)), vtxStart = Int(d.be32(0x24)), vtxEnd = Int(d.be32(0x28))
        guard triStart <= vtxStart, vtxStart <= vtxEnd, vtxEnd <= d.count else { throw WSError.badStructure("Double Dash collision sections out of range.") }
        let vertices = stride(from: vtxStart, to: vtxEnd - 11, by: 12).map { Vec3(x: d.beFloat32($0), y: d.beFloat32($0 + 4), z: d.beFloat32($0 + 8)) }
        let doc = KCLDocument()
        var geometry: [Float] = []
        for o in stride(from: triStart, to: vtxStart - 0x23, by: 0x24) {
            let i = [Int(d.be32(o)), Int(d.be32(o + 4)), Int(d.be32(o + 8))]
            guard i.allSatisfy(vertices.indices.contains) else { throw WSError.badStructure("Double Dash collision triangle uses a missing vertex.") }
            let t = KCLTriangle(v0: vertices[i[0]], v1: vertices[i[1]], v2: vertices[i[2]], attribute: d.be16(o + 0x16),
                                bcoCamera: d.u8(o + 0x19), bcoSettings: d.be32(o + 0x20))
            doc.triangles.append(t)
            geometry += flat(t)
        }
        doc.bcoSource = Source(original: d, geometry: geometry, types: Set(doc.triangles.map(\.attribute)))
        return doc
    }

    static func serialize(_ triangles: [KCLTriangle], source: Source) -> Data {
        let d = source.original
        let matStart = Int(d.be32(0x28))
        var table: [(key: UInt16, rest: Data)] = (0..<Int(d.be16(0x18))).compactMap { i in
            let o = matStart + i * 12
            return o + 12 <= d.count ? (d.be16(o), d.subdata(in: (d.startIndex + o + 2)..<(d.startIndex + o + 12))) : nil
        }
        // New surface types borrow the sound of the same type if the table has it; otherwise
        // mkdd-collision's default (sound 2).
        for key in Set(triangles.map(\.attribute)).subtracting(source.types).sorted() where !table.contains(where: { $0.key == key }) {
            let rest = table.first(where: { $0.key >> 8 == key >> 8 })?.rest ?? Data([0, 2] + [UInt8](repeating: 0, count: 8))
            table.append((key, rest))
        }

        var out: Data
        if triangles.flatMap(flat) == source.geometry {
            out = Data(d.prefix(matStart))
            let triStart = Int(d.be32(0x20))
            for (i, t) in triangles.enumerated() {
                let o = triStart + i * 0x24
                out.replaceSubrange(o + 0x16..<o + 0x18, with: be16(t.attribute))
                out[o + 0x19] = t.bcoCamera
                out.replaceSubrange(o + 0x20..<o + 0x24, with: be32(t.bcoSettings))
            }
        } else {
            out = rebuild(triangles)
        }
        out.replaceSubrange(0x18..<0x1A, with: be16(UInt16(table.count)))
        out.replaceSubrange(0x28..<0x2C, with: be32(UInt32(out.count)))
        for entry in table { out.append(be16(entry.key)); out.append(entry.rest) }
        return out
    }

    /// A new collision file from triangles alone: every surface type gets mkdd-collision's
    /// default material entry (sound 2).
    static func build(_ triangles: [KCLTriangle]) -> Data {
        var out = rebuild(triangles)
        let keys = Set(triangles.map(\.attribute)).sorted()
        out.replaceSubrange(0x18..<0x1A, with: be16(UInt16(keys.count)))
        out.replaceSubrange(0x28..<0x2C, with: be32(UInt32(out.count)))
        for key in keys { out.append(be16(key)); out.append(Data([0, 2] + [UInt8](repeating: 0, count: 8))) }
        return out
    }

    // MARK: Rebuild

    static let cellSize = 1000
    /// A cell or quadrant with more triangles than this is split into quadrants (twice at most,
    /// unless a quadrant would overflow the u8 triangle count, up to 8 levels, since splitting
    /// can't separate a fan of over 250 triangles meeting at one point).
    static let maxTrianglesPerEntry = 20

    /// Header + grid + index lists + triangles + vertices (material table left to the caller).
    /// The grid's cells start at retail's 1000 units and double until the grid fits the format's
    /// 16-bit entry indices (a course scaled up 2x outgrows 1000-unit cells; mkdd-collision takes
    /// a cell size option for the same reason).
    static func rebuild(_ input: [KCLTriangle]) -> Data {
        var size = cellSize
        while true {
            if let out = rebuild(input, cellSize: size) { return out }
            size *= 2
        }
    }

    private static func rebuild(_ input: [KCLTriangle], cellSize: Int) -> Data? {
        // Highest first: mkdd-collision orders triangles by average height.
        let triangles = input.sorted { ($0.v0.y + $0.v1.y + $0.v2.y) > ($1.v0.y + $1.v1.y + $1.v2.y) }
        var vertices: [Vec3] = [], vertexIndex: [[UInt32]: Int] = [:]
        func index(_ v: Vec3) -> Int {
            let key = [v.x.bitPattern, v.y.bitPattern, v.z.bitPattern]
            if let i = vertexIndex[key] { return i }
            vertices.append(v); vertexIndex[key] = vertices.count - 1
            return vertices.count - 1
        }
        let corners = triangles.map { [index($0.v0), index($0.v1), index($0.v2)] }

        let xs = vertices.map(\.x), zs = vertices.map(\.z)
        let c = Float(cellSize)
        let startX = Int((((xs.min() ?? 0) / c).rounded(.down))) * cellSize
        let startZ = Int((((zs.min() ?? 0) / c).rounded(.down))) * cellSize
        let width = max(1, Int((((xs.max() ?? 0) / c).rounded(.up))) - startX / cellSize)
        let length = max(1, Int((((zs.max() ?? 0) / c).rounded(.up))) - startZ / cellSize)

        struct Box { var x0: Float, z0: Float, x1: Float, z1: Float }
        func bounds(_ t: KCLTriangle) -> Box {
            Box(x0: min(t.v0.x, t.v1.x, t.v2.x), z0: min(t.v0.z, t.v1.z, t.v2.z), x1: max(t.v0.x, t.v1.x, t.v2.x), z1: max(t.v0.z, t.v1.z, t.v2.z))
        }
        let triBounds = triangles.map(bounds)
        // Bounds first, then the triangle's own edges (mkdd-collision stops at bounds, which lists
        // a long diagonal triangle in every cell of its bounding box and bloats the file).
        func overlaps(_ i: Int, _ b: Box) -> Bool {
            let t = triBounds[i]
            guard t.x1 >= b.x0 && t.x0 <= b.x1 && t.z1 >= b.z0 && t.z0 <= b.z1 else { return false }
            let v = [triangles[i].v0, triangles[i].v1, triangles[i].v2]
            let box = [(b.x0, b.z0), (b.x1, b.z0), (b.x0, b.z1), (b.x1, b.z1)]
            for k in 0..<3 {
                let p = v[k], q = v[(k + 1) % 3], r = v[(k + 2) % 3]
                let nx = -(q.z - p.z), nz = q.x - p.x
                func d(_ x: Float, _ z: Float) -> Float { (x - p.x) * nx + (z - p.z) * nz }
                let inside = d(r.x, r.z)
                // The box is wholly on the far side of this edge.
                if inside > 0 ? box.allSatisfy({ d($0.0, $0.1) < 0 }) : inside < 0 && box.allSatisfy({ d($0.0, $0.1) > 0 }) { return false }
            }
            return true
        }
        func touching(_ list: [Int], _ b: Box) -> [Int] { list.filter { overlaps($0, b) } }
        func quadrants(_ b: Box) -> [Box] {
            let mx = (b.x0 + b.x1) / 2, mz = (b.z0 + b.z1) / 2
            return [Box(x0: b.x0, z0: b.z0, x1: mx, z1: mz), Box(x0: mx, z0: b.z0, x1: b.x1, z1: mz),
                    Box(x0: b.x0, z0: mz, x1: mx, z1: b.z1), Box(x0: mx, z0: mz, x1: b.x1, z1: b.z1)]
        }

        // Cells, row by row (Z outer), each listing the triangles whose XZ bounds touch it.
        var cells = [[Int]](repeating: [], count: width * length)
        for (i, b) in triBounds.enumerated() {
            let ix0 = max(0, Int(((b.x0 - Float(startX)) / c).rounded(.up)) - 1), ix1 = min(width - 1, Int(((b.x1 - Float(startX)) / c).rounded(.down)))
            let iz0 = max(0, Int(((b.z0 - Float(startZ)) / c).rounded(.up)) - 1), iz1 = min(length - 1, Int(((b.z1 - Float(startZ)) / c).rounded(.down)))
            guard ix0 <= ix1, iz0 <= iz1 else { continue }
            for iz in iz0...iz1 {
                for ix in ix0...ix1 where overlaps(i, Box(x0: Float(startX + ix * cellSize), z0: Float(startZ + iz * cellSize),
                                                         x1: Float(startX + (ix + 1) * cellSize), z1: Float(startZ + (iz + 1) * cellSize))) {
                    cells[iz * width + ix].append(i)
                }
            }
        }

        // Grid entries breadth-first, as mkdd-collision writes them.
        var entries = Data(), groups: [[Int]] = [], groupIndex = 0
        struct Pending { var triangles: [Int]; var box: Box; var firstIndex: Int }
        var level: [Pending] = [], nextBase = width * length
        var overflow = false
        func entry(count: Int, child: Int, first: Int) {
            if child > 0xFFFF { overflow = true }
            entries.append(contentsOf: [UInt8(min(count, 255)), 0]); entries.append(be16(UInt16(truncatingIfNeeded: child))); entries.append(be32(UInt32(first)))
        }
        func split(_ list: [Int], _ box: Box, into next: inout [Pending]) {
            for q in quadrants(box) {
                let sub = touching(list, q)
                next.append(Pending(triangles: sub, box: q, firstIndex: groupIndex))
                groups.append(sub); groupIndex += sub.count
            }
        }
        for iz in 0..<length {
            for ix in 0..<width {
                let list = cells[iz * width + ix]
                if list.count > maxTrianglesPerEntry {
                    entry(count: 0, child: nextBase + level.count, first: groupIndex)
                    let box = Box(x0: Float(startX + ix * cellSize), z0: Float(startZ + iz * cellSize),
                                  x1: Float(startX + (ix + 1) * cellSize), z1: Float(startZ + (iz + 1) * cellSize))
                    split(list, box, into: &level)
                } else {
                    entry(count: list.count, child: 0, first: groupIndex)
                    groups.append(list); groupIndex += list.count
                }
            }
        }
        var depth = 1
        while !level.isEmpty {
            nextBase += level.count
            var next: [Pending] = []
            for p in level {
                if (depth < 2 && p.triangles.count > maxTrianglesPerEntry) || (p.triangles.count > 250 && depth < 8) {
                    entry(count: 0, child: nextBase + next.count, first: groupIndex)
                    split(p.triangles, p.box, into: &next)
                } else {
                    entry(count: p.triangles.count, child: 0, first: p.firstIndex)
                }
            }
            level = next; depth += 1
        }

        guard !overflow, width <= 0xFFFF, length <= 0xFFFF else { return nil }
        var out = Data("0003".utf8)
        out.append(be16(UInt16(width))); out.append(be16(UInt16(length)))
        out.append(be32(UInt32(bitPattern: Int32(startX)))); out.append(be32(UInt32(bitPattern: Int32(startZ))))
        out.append(be32(UInt32(cellSize))); out.append(be32(UInt32(cellSize)))
        out.append(Data(count: 4 + 16)) // material count, pad, offsets (filled below)
        out.append(entries)
        let listStart = out.count
        for g in groups { for t in g { out.append(be16(UInt16(truncatingIfNeeded: t))) } }
        if out.count % 4 != 0 { out.append(Data(count: 4 - out.count % 4)) }
        let triStart = out.count
        for (t, i) in zip(triangles, corners) {
            let v = [t.v0, t.v1, t.v2]
            var n = Vec3.cross(v[1] - v[0], v[2] - v[0])
            if n.length > 0 { n = n * (1 / n.length) }
            let r = Vec3(x: (n.x * 10000).rounded() / 10000, y: (n.y * 10000).rounded() / 10000, z: (n.z * 10000).rounded() / 10000)
            let mid = (v[0] + v[1] + v[2]) * (1 / 3)
            i.forEach { out.append(be32(UInt32($0))) }
            out.append(be32((-Vec3.dot(r, mid)).bitPattern))
            [r.x, r.y, r.z].forEach { out.append(be16(UInt16(bitPattern: Int16(($0 * 10000).rounded())))) }
            out.append(be16(t.attribute))
            func extreme(_ better: (Float, Float) -> Bool, _ axis: KeyPath<Vec3, Float>) -> UInt8 {
                var best = 0
                for k in 1..<3 where better(v[k][keyPath: axis], v[best][keyPath: axis]) { best = k }
                return UInt8(best)
            }
            out.append(extreme(>, \.z) << 6 | extreme(>, \.x) << 4 | extreme(<, \.z) << 2 | extreme(<, \.x))
            out.append(t.bcoCamera)
            out.append(Data(repeating: 0xFF, count: 6)) // neighbours: none, as mkdd-collision writes
            out.append(be32(t.bcoSettings))
        }
        let vtxStart = out.count
        for v in vertices { [v.x, v.y, v.z].forEach { out.append(be32($0.bitPattern)) } }
        out.replaceSubrange(0x1C..<0x28, with: be32(UInt32(listStart)) + be32(UInt32(triStart)) + be32(UInt32(vtxStart)))
        return out
    }

    private static func flat(_ t: KCLTriangle) -> [Float] { [t.v0.x, t.v0.y, t.v0.z, t.v1.x, t.v1.y, t.v1.z, t.v2.x, t.v2.y, t.v2.z] }
    private static func be16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
    private static func be32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }

    // MARK: Surface types

    /// Surface type names (the byte at 0x16), per mkdd.org.
    static let typeNames: [UInt16: String] = [
        0x00: "Dirt (Medium Off-Road)", 0x01: "Road", 0x02: "Wall", 0x03: "Grass (Medium Off-Road)", 0x04: "Ice",
        0x05: "Dead Zone (Flat)", 0x06: "Slip", 0x07: "Ramp Boost", 0x08: "Boost", 0x09: "Cannon", 0x0A: "Dead Zone (Circle)",
        0x0B: "Road 2", 0x0C: "Weak Off-Road", 0x0D: "Pipe / Teleport", 0x0E: "Sand Dead Zone", 0x0F: "Water Dead Zone",
        0x10: "Quicksand Sinkhole", 0x11: "Beach Sand", 0x12: "Kart-Only Wall", 0x13: "Heavy Off-Road",
        0x37: "Ramp Boost + Respawn", 0x47: "Ramp Boost + Respawn",
    ]

    /// Every type+variant (the byte at 0x17) the 24 retail courses use, with where, the variant
    /// byte's meaning isn't documented per type, so the menu offers these real, in-game-tested ones.
    static let retailVariants: [UInt16: [(variant: UInt16, usedIn: String)]] = [
        0x00: [(0x00, "Bowser's Castle, Luigi Circuit, Luigi Circuit (50cc) +4 more"), (0x01, "Waluigi Stadium"), (0x02, "Waluigi Stadium")],
        0x01: [(0x00, "Award Ceremony, Baby Park, Battle 1 +21 more"), (0x01, "Award Ceremony, Baby Park, Battle 1 +17 more"), (0x02, "Award Ceremony, Battle 1, Battle 8 +11 more"), (0x03, "Bowser's Castle, DK Mountain, Daisy Cruiser +7 more"), (0x04, "Bowser's Castle, Daisy Cruiser, Wario Colosseum"), (0x05, "Daisy Cruiser")],
        0x02: [(0x00, "Award Ceremony, Baby Park, Battle 1 +20 more"), (0x01, "Baby Park, Battle 1, Battle 7 +16 more"), (0x02, "Baby Park, Bowser's Castle, DK Mountain +11 more"), (0x03, "Bowser's Castle, DK Mountain, Dino Dino Jungle +7 more"), (0x04, "DK Mountain, Mario Circuit, Sherbet Land +1 more"), (0x05, "Mario Circuit")],
        0x03: [(0x00, "Award Ceremony, DK Mountain, Dino Dino Jungle +6 more")],
        0x04: [(0x00, "Sherbet Land")],
        0x05: [(0x00, "Baby Park"), (0x01, "Baby Park, Mushroom City"), (0x02, "Baby Park, Mushroom City, Wario Colosseum"), (0x03, "Baby Park, Mushroom City, Wario Colosseum"), (0x04, "Mushroom City"), (0x05, "Mushroom City"), (0x07, "Mushroom City"), (0x0A, "Wario Colosseum")],
        0x06: [(0x00, "Mario Circuit")],
        0x07: [(0x00, "Rainbow Road"), (0x02, "Waluigi Stadium"), (0x03, "Waluigi Stadium"), (0x04, "Waluigi Stadium"), (0x07, "Bowser's Castle"), (0x0C, "Peach Beach"), (0x0F, "Wario Colosseum"), (0x10, "Wario Colosseum"), (0x11, "Wario Colosseum"), (0x12, "Wario Colosseum"), (0x13, "Wario Colosseum")],
        0x08: [(0x00, "Dino Dino Jungle, Luigi Circuit, Luigi Circuit (50cc) +2 more")],
        0x09: [(0x00, "DK Mountain, Daisy Cruiser, Rainbow Road")],
        0x0A: [(0x00, "Mushroom City, Wario Colosseum"), (0x01, "Battle 5, DK Mountain, Dino Dino Jungle +4 more"), (0x02, "Battle 5, Bowser's Castle, DK Mountain +4 more"), (0x03, "Battle 5, DK Mountain, Dino Dino Jungle +3 more"), (0x04, "Battle 5, DK Mountain, Mushroom Bridge +2 more"), (0x05, "Mushroom Bridge, Rainbow Road, Wario Colosseum"), (0x06, "DK Mountain, Rainbow Road"), (0x07, "Rainbow Road, Wario Colosseum"), (0x08, "Mushroom City, Rainbow Road, Wario Colosseum"), (0x09, "Rainbow Road, Wario Colosseum"), (0x0A, "Rainbow Road, Wario Colosseum"), (0x0B, "Rainbow Road, Wario Colosseum"), (0x0C, "Rainbow Road, Wario Colosseum"), (0x0D, "Rainbow Road")],
        0x0C: [(0x00, "Dry Dry Desert")],
        0x0D: [(0x00, "Battle 8, Mushroom Bridge"), (0x01, "Battle 8"), (0x02, "Battle 8"), (0x03, "Battle 8"), (0x0A, "Peach Beach")],
        0x0E: [(0x00, "Dry Dry Desert"), (0x01, "Dry Dry Desert"), (0x02, "Dry Dry Desert"), (0x03, "Dry Dry Desert"), (0x04, "Dry Dry Desert"), (0x05, "Dry Dry Desert"), (0x06, "Dry Dry Desert"), (0x07, "Dry Dry Desert")],
        0x0F: [(0x00, "Bowser's Castle, Dino Dino Jungle, Mario Circuit +2 more"), (0x01, "Bowser's Castle, Daisy Cruiser, Yoshi Circuit"), (0x02, "Yoshi Circuit"), (0x03, "Bowser's Castle, Yoshi Circuit"), (0x04, "Bowser's Castle, Dino Dino Jungle, Yoshi Circuit"), (0x05, "Bowser's Castle, Yoshi Circuit"), (0x06, "Bowser's Castle, Yoshi Circuit")],
        0x10: [(0x00, "Dry Dry Desert")],
        0x11: [(0x00, "Peach Beach"), (0x01, "Peach Beach"), (0x02, "Peach Beach"), (0x03, "Peach Beach"), (0x04, "Peach Beach"), (0x05, "Peach Beach"), (0x06, "Peach Beach"), (0x07, "Peach Beach"), (0x08, "Peach Beach"), (0x09, "Award Ceremony, Peach Beach")],
        0x12: [(0x00, "Baby Park, Battle 3, Battle 7 +13 more"), (0x01, "Battle 7, Luigi Circuit (50cc), Mario Circuit +4 more"), (0x02, "Bowser's Castle, Luigi Circuit, Luigi Circuit (50cc) +3 more"), (0x03, "Mario Circuit, Wario Colosseum"), (0x05, "Mario Circuit")],
        0x13: [(0x00, "Battle 5, Dino Dino Jungle, Dry Dry Desert +1 more"), (0x01, "Dry Dry Desert")],
        0x37: [(0x08, "Bowser's Castle")],
        0x47: [(0x0D, "Wario Colosseum"), (0x0E, "Wario Colosseum")],
    ]

    static func flagName(_ attribute: UInt16) -> String {
        "\(typeNames[attribute >> 8] ?? "Unknown") (\(String(format: "0x%04X", attribute)))"
    }
}
