import Foundation

/// Mario Kart: Double Dash!! collision (`*_course.bco`, magic "0003"). Layouts worked out from, and
/// checked against, every course on a retail disc:
///
/// Header: grid size (u16 x2), grid origin and cell size (s32), then offsets at 0x1C (grid index
/// lists), 0x20 (triangles), 0x24 (vertices), 0x28 (end of vertices). Vertices are float XYZ.
/// Triangles are 0x24 bytes: three u32 vertex indices, plane distance (f32), normal (s16 x3,
/// x10000), surface type (u8 @ 0x16), variant (u8 @ 0x17), ..., and the index of the neighbouring
/// triangle across each edge (s16 x3 @ 0x1A, -1 = none).
///
/// Every triangle is a floor. Double Dash has no wall triangles. A track's edge is an edge with
/// no neighbour (never shared with any other triangle, checked on every course), which is where
/// the port builds walls.
nonisolated struct MKDDCollision {
    struct Triangle {
        var indices: (Int, Int, Int)
        var type: UInt8
        var variant: UInt8
        var neighbours: (Int, Int, Int)
    }
    var vertices: [Vec3] = []
    var triangles: [Triangle] = []

    static func parse(_ d: Data) throws -> MKDDCollision {
        guard d.count >= 0x2C, d.asciiString(at: 0, length: 4) == "0003" else {
            throw WSError.badStructure("Not a Double Dash collision file (missing '0003' magic).")
        }
        let triStart = Int(d.be32(0x20)), vtxStart = Int(d.be32(0x24)), vtxEnd = Int(d.be32(0x28))
        guard triStart < vtxStart, vtxStart <= vtxEnd, vtxEnd <= d.count else { throw WSError.badStructure("Double Dash collision sections out of range.") }
        var c = MKDDCollision()
        for o in stride(from: vtxStart, to: vtxEnd - 11, by: 12) {
            c.vertices.append(Vec3(x: d.beFloat32(o), y: d.beFloat32(o + 4), z: d.beFloat32(o + 8)))
        }
        for o in stride(from: triStart, to: vtxStart - 0x23, by: 0x24) {
            let a = Int(d.be32(o)), b = Int(d.be32(o + 4)), cc = Int(d.be32(o + 8))
            guard a < c.vertices.count, b < c.vertices.count, cc < c.vertices.count else { continue }
            func nb(_ k: Int) -> Int { Int(Int16(bitPattern: d.be16(o + 0x1A + k * 2))) }
            c.triangles.append(Triangle(indices: (a, b, cc), type: d.u8(o + 0x16), variant: d.u8(o + 0x17), neighbours: (nb(0), nb(1), nb(2))))
        }
        return c
    }
}

/// Mario Kart: Double Dash!! course data (`*_course.bol`, magic "0015"), the parts a Wii port
/// needs. Header: lap count (u8 @ 0x18), section counts (u16 from 0x1A: enemy points, checkpoint
/// groups, objects, areas, cameras, routes, respawns), then 11 section offsets from 0x44 (enemy
/// points, checkpoint groups + checkpoints, routes, route points, objects, kart start, areas,
/// cameras, respawns, light params, minigame params). Every count matches its section's size on
/// every retail course.
nonisolated struct MKDDCourse {
    struct EnemyPoint { var position: Vec3; var link: Int; var scale: Float; var group: Int }
    struct CheckpointGroup { var count: Int; var previous: [Int]; var next: [Int] }
    struct Checkpoint { var start: Vec3; var end: Vec3 }
    struct Object { var position: Vec3; var forward: Vec3; var id: UInt16 }

    var lapCount = 3
    var enemyPoints: [EnemyPoint] = []
    var checkpointGroups: [CheckpointGroup] = []
    var checkpoints: [Checkpoint] = []
    var objects: [Object] = []
    var startPosition = Vec3()
    var startForward = Vec3(x: 0, y: 0, z: 1)

    static func parse(_ d: Data) throws -> MKDDCourse {
        guard d.count >= 0x70, d.asciiString(at: 0, length: 4) == "0015" else {
            throw WSError.badStructure("Not a Double Dash course file (missing '0015' magic).")
        }
        var c = MKDDCourse()
        c.lapCount = max(1, Int(d.u8(0x18)))
        let enemyCount = Int(d.be16(0x1A)), groupCount = Int(d.be16(0x1C)), objectCount = Int(d.be16(0x1E))
        let offsets = (0..<11).map { Int(d.be32(0x44 + $0 * 4)) }
        func vec(_ o: Int) -> Vec3 { Vec3(x: d.beFloat32(o), y: d.beFloat32(o + 4), z: d.beFloat32(o + 8)) }
        /// Directions are stored as s16 x10000.
        func dir(_ o: Int) -> Vec3 {
            Vec3(x: Float(Int16(bitPattern: d.be16(o))) / 10000, y: Float(Int16(bitPattern: d.be16(o + 2))) / 10000, z: Float(Int16(bitPattern: d.be16(o + 4))) / 10000)
        }
        // Enemy points (0x20): position, u16 setting, s16 link (joins path ends), f32 width, u16, u8 group.
        for i in 0..<enemyCount {
            let o = offsets[0] + i * 0x20
            guard o + 0x20 <= d.count else { break }
            c.enemyPoints.append(EnemyPoint(position: vec(o), link: Int(Int16(bitPattern: d.be16(o + 0x0E))), scale: d.beFloat32(o + 0x10), group: Int(d.u8(o + 0x16))))
        }
        // Checkpoint groups (0x14: count, link, 4 previous, 4 next), then all checkpoints (0x1C:
        // start XYZ, end XYZ, flags).
        var o = offsets[1]
        for _ in 0..<groupCount {
            guard o + 0x14 <= d.count else { break }
            let prev = (0..<4).map { Int(Int16(bitPattern: d.be16(o + 4 + $0 * 2))) }.filter { $0 >= 0 }
            let next = (0..<4).map { Int(Int16(bitPattern: d.be16(o + 0x0C + $0 * 2))) }.filter { $0 >= 0 }
            c.checkpointGroups.append(CheckpointGroup(count: Int(d.be16(o)), previous: prev, next: next))
            o += 0x14
        }
        for g in c.checkpointGroups {
            for _ in 0..<g.count where o + 0x1C <= d.count {
                c.checkpoints.append(Checkpoint(start: vec(o), end: vec(o + 12)))
                o += 0x1C
            }
        }
        // Objects (0x40): position, scale, forward (s16), up (s16), object ID (u16 @ 0x24).
        for i in 0..<objectCount {
            let e = offsets[4] + i * 0x40
            guard e + 0x40 <= d.count else { break }
            c.objects.append(Object(position: vec(e), forward: dir(e + 0x18), id: d.be16(e + 0x24)))
        }
        // Kart start (0x28): position, scale, forward (s16), up, pole, player.
        if offsets[5] + 0x28 <= d.count {
            c.startPosition = vec(offsets[5])
            c.startForward = dir(offsets[5] + 0x18)
        }
        return c
    }
}
