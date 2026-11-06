import Foundation

/// Mario Kart Double Dash > Port > To Mario Kart Wii: turns a Mario Kart: Double Dash!! course archive
/// (`Course/*.arc`) into a complete Mario Kart Wii course (`.szs`), model, background, collision
/// with walls, minimap, and course data (start, CPU/item paths, checkpoints, respawn points,
/// item boxes, intro cameras).
///
/// Scale: Nintendo's own Wii remake of GCN Mario Circuit is ~1.18x the Double Dash original, but
/// played on real hardware ports felt ~10% small at that, so everything is scaled by `scale`
/// (default 1.32).
///
/// Surface types are mapped from what the course model's textures show on each Double Dash type
/// across every retail course (road, dirt/grass off-road, sand, dash panels, water/void). Rarer
/// types that couldn't be identified that way become plain road, driveable, and editable
/// afterwards in the KCL editor.
nonisolated enum MKDDPort {
    struct Result {
        var archive: Data
        var report: [String]
    }

    static let defaultScale: Float = 1.32

    /// Double Dash surface type -> Mario Kart Wii KCL flag (base type | variant << 5).
    /// What Double Dash's wall strips (types 0x02 and 0x12) become by default. They lie flat, and a
    /// flat Mario Kart Wii wall is almost always wrong, so the port asks (see `wallStripChoices`);
    /// the real walls are the upright ones `collision` adds along the track's edges.
    static let defaultWallStripFlag: UInt16 = 0x0002

    /// KCL flags offered for the wall strips: walls are listed but flagged as usually wrong.
    static let wallStripChoices: [UInt16] = [0x0002, 0x0003, 0x0004, 0x0000, 0x0010, 0x000C]

    static func kclFlag(for type: UInt8, wallStrip: UInt16 = defaultWallStripFlag) -> UInt16? {
        switch type {
        case 0x02, 0x12: return wallStrip
        case 0x01: return 0x0000          // road
        case 0x11: return 0x0002          // beach sand -> weak off-road
        case 0x03: return 0x0003          // grass -> off-road
        case 0x08: return 0x0006          // dash panel -> boost panel
        case 0x0F: return 0x0010          // water / void -> fall boundary
        default: return 0x0000            // unidentified -> road
        }
    }

    /// `itemBoxFiles` are the Mario Kart Wii files item boxes need (`itembox.brres` and friends,
    /// e.g. from `BaseGameLibrary`); without them item boxes are left out rather than crashing.
    static func port(_ archiveData: Data, name: String, scale s: Float = defaultScale,
                     itemBoxFiles: [(path: [String], data: Data)] = [], wallStrip: UInt16 = defaultWallStripFlag) throws -> Result {
        let rarc = try RARC.open(archiveData)
        func file(_ suffix: String) -> Data? { rarc.children.first { !$0.isDirectory && $0.name.lowercased().hasSuffix(suffix) }?.data }
        guard let bmd = file("_course.bmd") ?? file("_course.bdl") else { throw WSError.badStructure("\(name) has no *_course.bmd course model, is it a Double Dash course archive?") }
        guard let bcoData = file("_course.bco") else { throw WSError.badStructure("\(name) has no *_course.bco collision.") }
        guard let bolData = file("_course.bol") else { throw WSError.badStructure("\(name) has no *_course.bol course data.") }
        var report: [String] = []
        func scaled(_ v: Vec3) -> Vec3 { Vec3(x: v.x * s, y: v.y * s, z: v.z * s) }

        // MARK: Models
        let course = try J3DModel.parse(bmd)
        // Texture animations, under retail Mario Kart Wii's SRT0 names.
        func animations(_ pairs: [(String, String)]) -> [(name: String, btk: J3DAnimation.Animation)] {
            pairs.compactMap { suffix, name in file(suffix).flatMap { try? J3DAnimation.parse($0) }.flatMap { $0.kind == .textureSRT ? (name, $0) : nil } }
        }
        let courseAnims = animations([("_course.btk", "course"), ("_course_02.btk", "course2"), ("_course_03.btk", "course3")])
        let courseBRRES = try J3DToWii.brres(from: course, modelName: "course", scale: s, animations: courseAnims)
        report.append("Course model: \(course.triangles.count) triangles, \(course.materials.count) materials, \(course.textures.count) textures.")
        let skyBRRES: Data
        if let skyData = file("_sky.bmd"), let sky = try? J3DModel.parse(skyData) {
            skyBRRES = try J3DToWii.brres(from: sky, modelName: "vrcorn", scale: s, animations: animations([("_sky.btk", "vrcorn")]))
            report.append("Background: \(sky.triangles.count) triangles.")
        } else {
            // Some courses draw their sky inside the course model; the game still needs a vrcorn.
            let far: Float = -1_000_000
            func v(_ x: Float, _ z: Float) -> J3DModel.Vertex { J3DModel.Vertex(position: Vec3(x: x, y: far, z: z)) }
            let tiny = J3DModel.Triangle(v: (v(0, 0), v(1, 0), v(0, 1)), material: 0)
            skyBRRES = try J3DToWii.brres(from: J3DModel.Model(triangles: [tiny], materials: [J3DModel.Material(name: "vrcorn")], textures: []), modelName: "vrcorn", scale: 1)
            report.append("Background: none (this course's sky is part of its model), added an empty one.")
        }

        // MARK: Collision
        let bco = try MKDDCollision.parse(bcoData)
        let floors = groundedTriangles(bco, visual: course, scale: s)
        let (kcl, floorForMap, mapShades, walls, seams) = collision(bco, floors: floors, scale: s, wallStrip: wallStrip)
        let kclDoc = KCLDocument()
        kclDoc.triangles = kcl
        let kclData = kclDoc.serialize()
        guard !kclData.isEmpty else { throw WSError.badStructure("The collision is too complex for one KCL file.") }
        report.append("Collision: \(bco.triangles.count) surfaces + walls along \(walls) track edges (\(seams) seams between surfaces left open).")

        // MARK: Course data
        let kmp = kmpDocument(from: try MKDDCourse.parse(bolData), fullCourse: try? BOL.parse(bolData), scale: s, kclDoc: kclDoc, floorForMap: floorForMap, hasItemBoxFiles: !itemBoxFiles.isEmpty, report: &report)

        // MARK: Minimap, the driveable surfaces, off-road shaded darker.
        let mapData = try MapModelBuilder.build(triangles: floorForMap, shades: mapShades, modelName: "map")

        // MARK: Archive
        let root = U8Node(name: ".", isDirectory: true)
        root.setFile(at: ["course_model.brres"], data: courseBRRES)
        root.setFile(at: ["vrcorn_model.brres"], data: skyBRRES)
        root.setFile(at: ["map_model.brres"], data: mapData)
        root.setFile(at: ["course.kcl"], data: kclData)
        root.setFile(at: ["course.kmp"], data: kmp.serialize())
        if !kmp.gobj.isEmpty { for f in itemBoxFiles { root.setFile(at: f.path, data: f.data) } }
        return Result(archive: SZS.save(root: root, compressed: true), report: report)
    }

    /// Double Dash collision -> Mario Kart Wii: every surface becomes a KCL floor, plus a wall along each edge with nothing past it.
    /// `floors` are the BCO's triangles already scaled (and lifted onto the visible ground, if a model was available).
    static func collision(_ bco: MKDDCollision, floors: [(Vec3, Vec3, Vec3)], scale s: Float, wallStrip: UInt16 = defaultWallStripFlag) -> (kcl: [KCLTriangle], floorForMap: [OBJImporter.Triangle], mapShades: [UInt8], walls: Int, seams: Int) {
        // Triangles bucketed by XZ cell, to ask "is there floor just past this edge?"
        let cell: Float = 500 * s
        var buckets: [SIMD2<Int32>: [Int]] = [:]
        func key(_ x: Float, _ z: Float) -> SIMD2<Int32> { SIMD2(Int32((x / cell).rounded(.down)), Int32((z / cell).rounded(.down))) }
        for (i, f) in floors.enumerated() {
            let k0 = key(min(f.0.x, f.1.x, f.2.x), min(f.0.z, f.1.z, f.2.z)), k1 = key(max(f.0.x, f.1.x, f.2.x), max(f.0.z, f.1.z, f.2.z))
            for x in k0.x...k1.x { for z in k0.y...k1.y { buckets[SIMD2(x, z), default: []].append(i) } }
        }
        /// Surface height at (x, z) within `range` of `y`, from any collision triangle but `except`.
        func floorNear(_ x: Float, _ z: Float, y: Float, range: Float, except: Int) -> Bool {
            for i in buckets[key(x, z)] ?? [] where i != except {
                let (a, b, c) = floors[i]
                let den = (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
                guard abs(den) > 1e-6 else { continue }
                let u = ((b.z - c.z) * (x - c.x) + (c.x - b.x) * (z - c.z)) / den
                let v = ((c.z - a.z) * (x - c.x) + (a.x - c.x) * (z - c.z)) / den
                guard u >= -0.01, v >= -0.01, u + v <= 1.01 else { continue }
                if abs(u * a.y + v * b.y + (1 - u - v) * c.y - y) <= range { return true }
            }
            return false
        }
        var kcl: [KCLTriangle] = []
        var floorForMap: [OBJImporter.Triangle] = []
        var mapShades: [UInt8] = []
        let wallHeight: Float = 1500 * s
        var walls = 0, seams = 0
        for (ti, t) in bco.triangles.enumerated() {
            let (a, b, c) = floors[ti]
            let flag = kclFlag(for: t.type, wallStrip: wallStrip) ?? 0
            kcl.append(KCLTriangle.facingUp(a, b, c, attribute: flag))
            if flag != 0x0010 {
                floorForMap.append(OBJImporter.Triangle(v0: a, v1: b, v2: c, uv0: nil, uv1: nil, uv2: nil, materialName: nil))
                mapShades.append(flag == 0 || flag == 0x0006 ? 0xFF : 0x99)
                // Walls along this floor's outer edges, facing back into the track.
                let centre = Vec3(x: (a.x + b.x + c.x) / 3, y: 0, z: (a.z + b.z + c.z) / 3)
                for (p, q, n) in [(a, b, t.neighbours.0), (b, c, t.neighbours.1), (c, a, t.neighbours.2)] where n < 0 {
                    // An edge with no neighbour is only the track's edge if nothing continues
                    // past it: separately-modelled pieces (road next to a kerb or verge) meet at
                    // edges that aren't shared, and a wall there traps karts on open road.
                    let mid = Vec3(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2, z: (p.z + q.z) / 2)
                    let out = Vec2(x: mid.x - centre.x, y: mid.z - centre.z)
                    let len = max(0.001, (out.x * out.x + out.y * out.y).squareRoot())
                    let probe: Float = 40 * s
                    if floorNear(mid.x + out.x / len * probe, mid.z + out.y / len * probe, y: mid.y, range: 200 * s, except: ti) {
                        seams += 1
                        continue
                    }
                    let pTop = Vec3(x: p.x, y: p.y + wallHeight, z: p.z), qTop = Vec3(x: q.x, y: q.y + wallHeight, z: q.z)
                    let pLow = Vec3(x: p.x, y: p.y - 200 * s, z: p.z), qLow = Vec3(x: q.x, y: q.y - 200 * s, z: q.z)
                    let inward = Vec3(x: centre.x - (p.x + q.x) / 2, y: 0, z: centre.z - (p.z + q.z) / 2)
                    for (v0, v1, v2) in [(pLow, qLow, qTop), (pLow, qTop, pTop)] {
                        let normal = Vec3.cross(v1 - v0, v2 - v0)
                        let faces = normal.x * inward.x + normal.z * inward.z > 0
                        kcl.append(faces ? KCLTriangle(v0: v0, v1: v1, v2: v2, attribute: 0x000C)
                                         : KCLTriangle(v0: v0, v1: v2, v2: v1, attribute: 0x000C))
                    }
                    walls += 1
                }
            }
        }
        return (kcl, floorForMap, mapShades, walls, seams)
    }

    /// Double Dash course data -> a Mario Kart Wii KMP. `kclDoc` supplies ground heights; `floorForMap` the bounds for the intro camera.
    static func kmpDocument(from bol: MKDDCourse, fullCourse: KMPDocument? = nil, scale s: Float, kclDoc: KCLDocument, floorForMap: [OBJImporter.Triangle],
                            hasItemBoxFiles: Bool, report: inout [String]) -> KMPDocument {
        func scaled(_ v: Vec3) -> Vec3 { Vec3(x: v.x * s, y: v.y * s, z: v.z * s) }
        let kmp = KMPDocument()
        kmp.stgi.lapCount = UInt8(min(9, bol.lapCount))
        kmp.stgi.lensFlareFlag = 1
        kmp.stgi.flareColor = (0x00, 0xE6, 0xE6, 0xE6)
        kmp.stgi.flareTransparency = 0x4B
        func yaw(_ f: Vec3) -> Float { atan2(f.x, f.z) * 180 / .pi }
        func ground(_ p: Vec3) -> Vec3 {
            guard let y = kclDoc.floorHeight(x: p.x, z: p.z) else { return p }
            return Vec3(x: p.x, y: y + 10, z: p.z)
        }
        kmp.ktpt = [KTPTEntry(position: ground(scaled(bol.startPosition)), rotation: Vec3(x: 0, y: yaw(bol.startForward), z: 0), playerIndex: -1)]

        // Enemy and item paths: one group per run of the same group number; a group's end joins
        // any group starting with the same link number (how Double Dash marks forks and loops).
        var groupRanges: [(start: Int, count: Int)] = []
        for (i, p) in bol.enemyPoints.enumerated() {
            if let last = groupRanges.last, bol.enemyPoints[last.start].group == p.group, last.start + last.count == i {
                groupRanges[groupRanges.count - 1].count += 1
            } else {
                groupRanges.append((i, 1))
            }
        }
        var links = groupRanges.map { _ in PathLinkEntry() }
        for (g, r) in groupRanges.enumerated() {
            links[g].startIndex = UInt8(clamping: r.start)
            links[g].pointCount = UInt8(clamping: r.count)
            let endLink = bol.enemyPoints[r.start + r.count - 1].link
            var nexts = groupRanges.indices.filter { endLink >= 0 && bol.enemyPoints[groupRanges[$0].start].link == endLink && $0 != g }
            if nexts.isEmpty { nexts = [(g + 1) % groupRanges.count] }
            links[g].nextGroups = (nexts.prefix(6).map { UInt8($0) } + Array(repeating: 0xFF, count: 6)).prefix(6).map { $0 }
        }
        for g in links.indices {
            let prevs = links.indices.filter { links[$0].nextGroups.contains(UInt8(g)) }
            links[g].previousGroups = (prevs.prefix(6).map { UInt8($0) } + Array(repeating: 0xFF, count: 6)).prefix(6).map { $0 }
        }
        kmp.enpt = bol.enemyPoints.map { ENPTEntry(position: scaled($0.position), radius: max(300, $0.scale * s)) }
        kmp.enph = links
        kmp.itpt = bol.enemyPoints.map { ITPTEntry(position: scaled($0.position), radius: max(300, $0.scale * s)) }
        kmp.itph = links
        if kmp.enpt.count > 255 { report.append("Warning: \(kmp.enpt.count) CPU path points; paths over 255 points per group may need splitting.") }

        // Checkpoints: left/right chosen so each gate faces the way the track is driven (the same
        // orientation every retail Wii course uses).
        let cps = bol.checkpoints
        // Each checkpoint's real successor: the next in its group, or the first of its group's
        // first next group. (The next one in the array is a different branch at a fork's end --
        // using it flipped the gates there, and Mushroom City lost track of every lap.)
        var successor = Array(cps.indices.map { ($0 + 1) % max(1, cps.count) })
        var groupStart: [Int] = []
        var acc = 0
        for g in bol.checkpointGroups { groupStart.append(acc); acc += g.count }
        for (gi, g) in bol.checkpointGroups.enumerated() where g.count > 0 {
            let last = groupStart[gi] + g.count - 1
            if let n = g.next.first(where: { groupStart.indices.contains($0) }), cps.indices.contains(last), cps.indices.contains(groupStart[n]) {
                successor[last] = groupStart[n]
            }
        }
        var ckpt: [CKPTEntry] = []
        for (i, c) in cps.enumerated() {
            let a = scaled(c.start), b = scaled(c.end)
            let next = scaled(cps[successor[i]].start), nextEnd = scaled(cps[successor[i]].end)
            let fwd = Vec2(x: (next.x + nextEnd.x - a.x - b.x) / 2, y: (next.z + nextEnd.z - a.z - b.z) / 2)
            // cross(forward, right->left) must be negative.
            let aIsLeft = fwd.x * (a.z - b.z) - fwd.y * (a.x - b.x) < 0
            let left = aIsLeft ? a : b, right = aIsLeft ? b : a
            ckpt.append(CKPTEntry(left: Vec2(x: left.x, y: left.z), right: Vec2(x: right.x, y: right.z), respawnIndex: 0, lapCounterType: -1))
        }
        // Groups first: key placement and respawns depend on how they link up.
        var ckph: [PathLinkEntry] = []
        var start = 0
        for g in bol.checkpointGroups {
            var entry = PathLinkEntry(startIndex: UInt8(clamping: start), pointCount: UInt8(clamping: g.count))
            entry.previousGroups = (g.previous.prefix(6).map { UInt8(clamping: $0) } + Array(repeating: 0xFF, count: 6)).prefix(6).map { $0 }
            entry.nextGroups = (g.next.prefix(6).map { UInt8(clamping: $0) } + Array(repeating: 0xFF, count: 6)).prefix(6).map { $0 }
            ckph.append(entry)
            start += g.count
        }
        kmp.ckph = ckph
        if !ckpt.isEmpty {
            ckpt[0].lapCounterType = 0 // the finish line
            // Keys 1-3 spread along the route, only on checkpoints every lap passes: a key on one
            // branch of a fork is never reached by a kart taking the other branch, and a lap that
            // misses the last key doesn't count.
            let groupNext = ckph.map { g in g.nextGroups.filter { Int($0) < ckph.count }.map(Int.init) }
            let order = CheckpointVerifier.drivingOrder(groupNext: groupNext)
            let must = CheckpointVerifier.unavoidableGroups(groupNext: groupNext)
            let line = order.filter(must.contains).flatMap { g in (Int(ckph[g].startIndex)..<(Int(ckph[g].startIndex) + Int(ckph[g].pointCount))).filter(ckpt.indices.contains) }
            for k in 1...3 { let i = line.count * k / 4; if i > 0, i < line.count { ckpt[line[i]].lapCounterType = Int8(k) } }
        }
        // Respawn points: one every few checkpoints, on the ground at the gate's middle, facing
        // along the track; each checkpoint respawns at the last one it passed.
        var respawnForCheckpoint: [Int] = []
        let step = max(1, ckpt.count / 12)
        let groupStarts = Set(ckph.map { Int($0.startIndex) })
        for (i, c) in ckpt.enumerated() {
            // Every group starts with its own, so a branch never respawns onto a parallel one.
            if i % step == 0 || groupStarts.contains(i) {
                let mid = Vec3(x: (c.left.x + c.right.x) / 2, y: 0, z: (c.left.y + c.right.y) / 2)
                let n = ckpt[successor[i]]
                let f = Vec3(x: (n.left.x + n.right.x) / 2 - mid.x, y: 0, z: (n.left.y + n.right.y) / 2 - mid.z)
                let y = kclDoc.floorHeight(x: mid.x, z: mid.z) ?? scaled(cps[i].start).y
                kmp.jgpt.append(JGPTEntry(position: Vec3(x: mid.x, y: y + 10, z: mid.z), rotation: Vec3(x: 0, y: yaw(f), z: 0)))
            }
            respawnForCheckpoint.append(kmp.jgpt.count - 1)
        }
        for i in ckpt.indices { ckpt[i].respawnIndex = UInt8(clamping: max(0, respawnForCheckpoint[i])) }
        if kmp.jgpt.isEmpty {
            // Battle arenas have no checkpoints; the game still needs somewhere to respawn.
            kmp.jgpt = [JGPTEntry(position: kmp.ktpt[0].position, rotation: kmp.ktpt[0].rotation)]
            report.append("This looks like a battle arena (no checkpoints): it's ported as a race-course slot with one respawn point at the start. Battle start points aren't converted.")
        }
        kmp.ckpt = ckpt

        // Item boxes (Double Dash object 1), if the Wii item box files are available.
        let itemBoxes = bol.objects.filter { $0.id == 1 }
        if !itemBoxes.isEmpty {
            if !hasItemBoxFiles {
                report.append("\(itemBoxes.count) item boxes left out, link your Mario Kart Wii disc in Settings > Games so the port can include itembox.brres.")
            } else {
                kmp.gobj = itemBoxes.map { GOBJEntry(objectID: 0x0065, position: scaled($0.position)) }
                report.append("Item boxes: \(itemBoxes.count).")
            }
        }
        let others = bol.objects.filter { $0.id != 1 }.count
        if others > 0 { report.append("\(others) other Double Dash objects (scenery, hazards) aren't ported. Mario Kart Wii has different objects.") }

        // Intro cameras.
        let xs = floorForMap.flatMap { [$0.v0.x, $0.v1.x, $0.v2.x] }, zs = floorForMap.flatMap { [$0.v0.z, $0.v1.z, $0.v2.z] }
        let ys = floorForMap.flatMap { [$0.v0.y, $0.v1.y, $0.v2.y] }
        if let x0 = xs.min(), let x1 = xs.max(), let z0 = zs.min(), let z1 = zs.max(), let y0 = ys.min(), let y1 = ys.max() {
            KMPCameraSequence.makeStandardIntro(in: kmp, boundsMin: Vec3(x: x0, y: y0, z: z0), boundsMax: Vec3(x: x1, y: y1, z: z1))
        }

        if let fullCourse {
            let replay = ReplayTransfer.ddToWii(fullCourse, into: kmp, scale: s)
            if replay.areas > 0 { report.append("Replay cameras: \(replay.cameras) cameras in \(replay.areas) areas.") }
        }

        if !kmp.ckpt.isEmpty {
            let laps = CheckpointVerifier.verify(kmp)
            let errors = laps.issues.filter { $0.severity == .error }
            report.append(errors.isEmpty
                ? "Checkpoints: verified, drove the CPU route \(laps.loopsDriven) laps, all \(laps.lapsCounted) counted."
                : "Warning: checkpoints may not count laps, " + errors.map(\.message).joined(separator: " ") + " Open course.kmp and use Check Laps.")
        }
        return kmp
    }

    /// The collision's triangles, scaled, with floors lifted onto the visible ground.
    ///
    /// Double Dash sinks karts into off-road and sand by modelling that collision *below* the
    /// visible surface (measured across every retail course: off-road up to ~200 units, sand
    /// ~35-50). Mario Kart Wii keeps collision flush with the model almost everywhere (retail sand
    /// sits at most ~20 below), so copied verbatim those surfaces left karts visibly sunk into
    /// the ground. Each floor corner moves up to the lowest up-facing visual surface within
    /// `maxLift` above a point just inside its own triangle, per triangle, not per shared
    /// vertex, since a road edge can meet a verge modelled ~180 higher at the very same vertex.
    /// Roads, already flush, find themselves (even under a bridge) and stay put; where the
    /// visual ground is continuous, neighbouring corners land at the same height.
    static func groundedTriangles(_ bco: MKDDCollision, visual: J3DModel.Model, scale s: Float) -> [(Vec3, Vec3, Vec3)] {
        let verts = bco.vertices.map { $0 * s }
        let maxLift: Float = 250 * s
        let cell: Float = 500 * s
        func key(_ x: Float, _ z: Float) -> SIMD2<Int32> { SIMD2(Int32((x / cell).rounded(.down)), Int32((z / cell).rounded(.down))) }
        var tris: [(Vec3, Vec3, Vec3)] = []
        var buckets: [SIMD2<Int32>: [Int]] = [:]
        for t in visual.triangles {
            let a = t.v.0.position * s, b = t.v.1.position * s, c = t.v.2.position * s
            let n = Vec3.cross(b - a, c - a)
            // J3D ground winds clockwise seen from above (n.y < 0 here, on every course checked);
            // the other side is an overhang's underside, which must never pull a floor up.
            guard n.length > 0, n.y <= -0.3 * n.length else { continue }
            let k0 = key(min(a.x, b.x, c.x), min(a.z, b.z, c.z)), k1 = key(max(a.x, b.x, c.x), max(a.z, b.z, c.z))
            guard k1.x - k0.x < 64, k1.y - k0.y < 64 else { continue } // a giant backdrop, not ground
            for x in k0.x...k1.x { for z in k0.y...k1.y { buckets[SIMD2(x, z), default: []].append(tris.count) } }
            tris.append((a, b, c))
        }
        func lift(at p: Vec3) -> Float {
            var lowest: Float?
            for j in buckets[key(p.x, p.z)] ?? [] {
                let (a, b, c) = tris[j]
                let den = (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
                guard abs(den) > 1e-9 else { continue }
                let u = ((b.z - c.z) * (p.x - c.x) + (c.x - b.x) * (p.z - c.z)) / den
                let v = ((c.z - a.z) * (p.x - c.x) + (a.x - c.x) * (p.z - c.z)) / den
                guard u >= -1e-4, v >= -1e-4, u + v <= 1 + 1e-4 else { continue }
                let dy = u * a.y + v * b.y + (1 - u - v) * c.y - p.y
                if dy >= -1, dy <= maxLift, lowest == nil || dy < lowest! { lowest = dy }
            }
            return (lowest ?? 0) > 0.5 ? lowest! : 0
        }
        return bco.triangles.map { t in
            var (a, b, c) = (verts[t.indices.0], verts[t.indices.1], verts[t.indices.2])
            let n = Vec3.cross(b - a, c - a)
            // Walls and fall boundaries stay exactly where Double Dash put them.
            guard kclFlag(for: t.type) != 0x0010, n.length > 0, abs(n.y) >= 0.5 * n.length else { return (a, b, c) }
            let centre = (a + b + c) * (1 / 3)
            func inside(_ p: Vec3) -> Vec3 {
                let d = centre - p, len = d.length
                return len > 0 ? p + d * min(0.1, 10 * s / len) : p
            }
            // Sample every corner before moving any, so each sample sees the original triangle.
            let la = lift(at: inside(a)), lb = lift(at: inside(b)), lc = lift(at: inside(c))
            a.y += la; b.y += lb; c.y += lc
            return (a, b, c)
        }
    }
}
