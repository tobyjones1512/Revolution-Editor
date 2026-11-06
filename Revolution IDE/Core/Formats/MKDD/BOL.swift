import Foundation

/// Mario Kart: Double Dash!! course data (`*_course.bol`, magic "0015"), opened into the same
/// `KMPDocument` the KMP editor and 3D track editor edit. Layout per mkdd.org's "BOL (File
/// Format)" and Yoshi2's mkdd-track-editor (libbol), checked against every retail course.
///
/// Header 0x7C: settings, lap count (0x18), section counts (u16 from 0x1A: enemy points,
/// checkpoint groups, objects, areas, cameras, routes, respawns; u8 kart starts 0x3B, light
/// params 0x3D, minigame params 0x3E), then 11 section offsets from 0x44, sections back to back.
///
/// Mapping: enemy points -> ENPT/ENPH (a group's last point links to every group whose first point
/// carries the same link number), checkpoint groups -> CKPT/CKPH, routes -> POTI, objects -> GOBJ
/// (Double Dash object IDs), kart starts -> KTPT, areas -> AREA, cameras -> CAME, respawns -> JGPT.
/// Directions (s16 forward + up vectors, x10000) become Euler degrees in SceneKit's X-Y-Z order,
/// facing +Z. Every entry keeps its original record (`bol`), so fields the KMP model has no place
/// for (drift settings, fog, presence flags, camera names, ...) survive, and an unedited file
/// saves byte-identical. Light and minigame params are carried through as-is.
nonisolated enum BOL {
    struct Source { let original: Data }

    static func isBOL(_ d: Data) -> Bool { d.count >= 0x7C && d.asciiString(at: 0, length: 4) == "0015" }

    /// An empty course file to build a new course on: mkdd-track-editor's new-course header
    /// (ambient 64 64 64, white light, 3 laps, fog off from 8000 to 230000, no light or minigame
    /// params) with `musicID`, each retail slot has its own, 0x21 (Baby Park) to 0x33.
    static func blankSource(musicID: UInt8 = 0x21) -> Source {
        var h = Data("0015".utf8)
        h.append(0)                                   // roll
        h.append(contentsOf: [0x64, 0x64, 0x64])     // ambient
        h.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF]) // light
        h.append(Data(count: 12))                     // light source
        h.append(3); h.append(musicID)                // laps, music
        h.append(Data(count: 14))                     // section counts
        h.append(0); h.append(contentsOf: [0x64, 0x64, 0x64]) // fog type, colour
        h.append(be32(Float(8000).bitPattern)); h.append(be32(Float(230_000).bitPattern))
        h.append(contentsOf: [0, 0, 0, 0])            // LOD bias, dummy start line, snow, shadow opacity
        h.append(contentsOf: [0, 0, 0])               // shadow colour
        h.append(contentsOf: [0, 0, 0, 0, 0])         // starts, sky follow, light params, minigame params, pad
        h.append(Data(count: 4))                      // file start
        for _ in 0..<11 { h.append(be32(0x7C)) }      // section offsets (all empty)
        h.append(Data(count: 12))
        precondition(h.count == 0x7C)
        return Source(original: h)
    }

    /// A new, empty Double Dash course document (saves as a .bol).
    static func newDocument(musicID: UInt8 = 0x21) -> KMPDocument {
        let doc = KMPDocument()
        doc.bolSource = blankSource(musicID: musicID)
        doc.stgi.lapCount = 3
        return doc
    }

    /// A new battle stage's course file: 8 start points, one per player 0-7, in a ring facing
    /// the middle, retail Block City's layout (Mini5). Battle stages have no enemy route or
    /// checkpoints.
    static func battleTemplate(musicID: UInt8 = 0x21) -> KMPDocument {
        let doc = newDocument(musicID: musicID)
        let d: Float = 2134, r: Float = 3000
        let ring: [(Int16, Float, Float, Float)] = [(0, 0, r, 180), (1, 0, -r, 0), (2, -r, 0, 90), (3, r, 0, -90),
                                                    (4, d, -d, -45), (5, -d, d, 135), (6, -d, -d, 45), (7, d, d, -135)]
        doc.ktpt = ring.map { KTPTEntry(position: Vec3(x: $0.1, y: 0, z: $0.2), rotation: Vec3(x: 0, y: $0.3, z: 0), playerIndex: $0.0) }
        return doc
    }

    private static let sizes = [0x20, 0x14, 0x10, 0x20, 0x40, 0x28, 0x38, 0x48, 0x20, 0x14, 0x08]

    static func parse(_ d: Data) throws -> KMPDocument {
        guard isBOL(d) else { throw WSError.badStructure("Not a Double Dash course file (missing '0015' magic).") }
        let d = Data(d) // zero-based indices
        let off = (0..<11).map { Int(d.be32(0x44 + $0 * 4)) }
        let enemyCount = Int(d.be16(0x1A)), groupCount = Int(d.be16(0x1C)), objectCount = Int(d.be16(0x1E))
        let areaCount = Int(d.be16(0x20)), cameraCount = Int(d.be16(0x22)), routeCount = Int(d.be16(0x24))
        let respawnCount = Int(d.be16(0x26)), startCount = Int(d.u8(0x3B))
        func record(_ section: Int, _ i: Int) throws -> Data {
            let o = off[section] + i * sizes[section]
            guard o >= 0x7C, o + sizes[section] <= d.count else { throw WSError.badStructure("Double Dash course data is truncated.") }
            return d.subdata(in: o..<(o + sizes[section]))
        }
        let doc = KMPDocument()
        doc.bolSource = Source(original: d)
        doc.stgi.lapCount = d.u8(0x18)

        // Enemy points, grouped by group ID in order of first appearance.
        var groupOrder: [UInt8] = [], points: [UInt8: [Data]] = [:]
        for i in 0..<enemyCount {
            let r = try record(0, i)
            let g = r.u8(0x16)
            if points[g] == nil { groupOrder.append(g) }
            points[g, default: []].append(r)
        }
        let groups = groupOrder.map { points[$0]! }
        for (gi, g) in groups.enumerated() {
            var link = PathLinkEntry()
            link.startIndex = UInt8(clamping: doc.enpt.count)
            link.pointCount = UInt8(clamping: g.count)
            let endLink = Int16(bitPattern: g.last!.be16(0x0E)), startLink = Int16(bitPattern: g.first!.be16(0x0E))
            let next = endLink < 0 ? [] : groups.indices.filter { Int16(bitPattern: groups[$0].first!.be16(0x0E)) == endLink }
            let prev = startLink < 0 ? [] : groups.indices.filter { Int16(bitPattern: groups[$0].last!.be16(0x0E)) == startLink }
            link.nextGroups = slots(next, 6); link.previousGroups = slots(prev, 6)
            link.bol = Data([groupOrder[gi]])
            doc.enph.append(link)
            for r in g { doc.enpt.append(ENPTEntry(position: vec(r, 0), radius: r.beFloat32(0x10), bol: r)) }
        }

        // Checkpoint groups, then all their checkpoints.
        var ckStart = off[1] + groupCount * 0x14
        for i in 0..<groupCount {
            let r = try record(1, i)
            var link = PathLinkEntry()
            link.startIndex = UInt8(clamping: doc.ckpt.count)
            link.pointCount = UInt8(clamping: Int(r.be16(0)))
            link.previousGroups = slots((0..<4).map { Int(Int16(bitPattern: r.be16(4 + $0 * 2))) }.filter { $0 >= 0 }, 6)
            link.nextGroups = slots((0..<4).map { Int(Int16(bitPattern: r.be16(0x0C + $0 * 2))) }.filter { $0 >= 0 }, 6)
            link.bol = r
            doc.ckph.append(link)
            for _ in 0..<Int(r.be16(0)) {
                guard ckStart + 0x1C <= off[2] else { throw WSError.badStructure("Double Dash checkpoints are truncated.") }
                let c = d.subdata(in: ckStart..<(ckStart + 0x1C))
                var e = CKPTEntry()
                e.left = Vec2(x: c.beFloat32(0), y: c.beFloat32(8)); e.right = Vec2(x: c.beFloat32(0x0C), y: c.beFloat32(0x14))
                e.bol = c
                doc.ckpt.append(e)
                ckStart += 0x1C
            }
        }

        for i in 0..<routeCount {
            let r = try record(2, i)
            var route = POTIRoute(); route.bol = r
            let first = Int(r.be16(2))
            for k in 0..<Int(r.be16(0)) {
                let p = try record(3, first + k)
                route.points.append(RoutePoint(position: vec(p, 0), bol: p))
            }
            doc.poti.append(route)
        }
        for i in 0..<objectCount {
            let r = try record(4, i)
            doc.gobj.append(GOBJEntry(objectID: r.be16(0x24), position: vec(r, 0), rotation: euler(r, 0x18), scale: vec(r, 0x0C),
                                      routeID: r.be16(0x26), settings: (0..<8).map { r.be16(0x30 + $0 * 2) }, bol: r))
        }
        for i in 0..<startCount {
            let r = try record(5, i)
            doc.ktpt.append(KTPTEntry(position: vec(r, 0), rotation: euler(r, 0x18), playerIndex: r.u8(0x25) == 0xFF ? -1 : Int16(r.u8(0x25)), bol: r))
            if i == 0 { doc.stgi.polePosition = r.u8(0x24) }
        }
        for i in 0..<areaCount {
            let r = try record(6, i)
            let cam = Int16(bitPattern: r.be16(0x26))
            doc.area.append(AREAEntry(shape: r.u8(0x24), type: r.u8(0x25), cameraIndex: cam < 0 ? 0xFF : UInt8(clamping: cam),
                                      position: vec(r, 0), rotation: euler(r, 0x18), scale: vec(r, 0x0C), bol: r))
        }
        // Look-at points: the game's mTargetPos (0x24) is the start, mTargetPos2 (0x18) the end (MKDD
        // decomp CrsData::Camera; mkdd-track-editor's Start/End Point). Read the other way round, every
        // intro previewed, and ported, panning backwards.
        for i in 0..<cameraCount {
            let r = try record(7, i)
            func s8(_ o: Int) -> UInt8 { let v = Int16(bitPattern: r.be16(o)); return v < 0 ? 0xFF : UInt8(clamping: v) }
            doc.came.append(CAMEEntry(type: r.be16(0x30), next: s8(0x42), routeID: s8(0x3C), pointVelocity: r.be16(0x3E),
                                      startFlag: UInt8(clamping: r.be16(0x36)), position: vec(r, 0), rotation: euler(r, 0x0C),
                                      zoomStart: Float(r.be16(0x32)), zoomEnd: Float(r.be16(0x40)),
                                      viewPositionStart: vec(r, 0x24), viewPositionEnd: vec(r, 0x18), time: Float(r.be16(0x34)), bol: r))
        }
        doc.openingCameraIndex = UInt8(clamping: doc.came.firstIndex { $0.startFlag != 0 } ?? 0xFF)
        for i in 0..<respawnCount {
            let r = try record(8, i)
            doc.jgpt.append(JGPTEntry(position: vec(r, 0), rotation: euler(r, 0x0C), respawnID: r.be16(0x18), extra: r.be16(0x1A), bol: r))
        }
        return doc
    }

    static func serialize(_ doc: KMPDocument, source: Source) -> Data {
        let o = source.original
        var header = Data(o.prefix(0x7C))
        header[0x18] = doc.stgi.lapCount
        var sections = [Data](repeating: Data(), count: 11)

        // Enemy points: a group's ID is its original one when still unique, else its index;
        // link numbers join a group's end to its next groups' starts.
        var ids: [UInt8] = []
        for (gi, g) in doc.enph.enumerated() {
            let original = g.bol?.first
            ids.append(original.map { id in ids.contains(id) ? UInt8(clamping: gi) : id } ?? UInt8(clamping: gi))
        }
        let links = enemyLinks(doc)
        for (gi, g) in doc.enph.enumerated() {
            let range = Int(g.startIndex)..<min(doc.enpt.count, Int(g.startIndex) + Int(g.pointCount))
            for (k, i) in range.enumerated() {
                let e = doc.enpt[i]
                var r = e.bol ?? Data(count: 0x20)
                put(&r, 0, e.position)
                // Mid-group points keep their own link (retail uses a few as extra junctions).
                var link: Int16 = e.bol == nil ? -1 : Int16(bitPattern: r.be16(0x0E))
                if k == range.count - 1 { link = links.end[gi] }
                if k == 0 { link = links.start[gi] }
                r.replaceSubrange(0x0E..<0x10, with: be16(UInt16(bitPattern: link)))
                r.replaceSubrange(0x10..<0x14, with: be32(e.radius.bitPattern))
                r[0x16] = ids[gi]
                sections[0].append(r)
            }
        }

        // A new checkpoint takes the height of the one before it, the first, the start's.
        let startY = doc.ktpt.first?.position.y ?? 0
        var checkpoints = Data(), lastY: (Float, Float) = (startY, startY)
        let main = mainCheckpointGroups(doc)
        for (gi, g) in doc.ckph.enumerated() {
            var r = g.bol ?? cat(be16(0), be16(UInt16(gi)), Data(repeating: 0xFF, count: 16))
            let range = Int(g.startIndex)..<min(doc.ckpt.count, Int(g.startIndex) + Int(g.pointCount))
            r.replaceSubrange(0..<2, with: be16(UInt16(range.count)))
            r.replaceSubrange(2..<4, with: be16(r.be16(2) & 0x7FFF | (main.contains(gi) ? 0 : 0x8000)))
            for k in 0..<4 {
                r.replaceSubrange(4 + k * 2..<6 + k * 2, with: be16(slot(g.previousGroups, k)))
                r.replaceSubrange(0x0C + k * 2..<0x0E + k * 2, with: be16(slot(g.nextGroups, k)))
            }
            sections[1].append(r)
            for i in range {
                let e = doc.ckpt[i]
                var c = e.bol ?? Data(count: 0x1C)
                if e.bol == nil { c.replaceSubrange(4..<8, with: be32(lastY.0.bitPattern)); c.replaceSubrange(0x10..<0x14, with: be32(lastY.1.bitPattern)) }
                lastY = (c.beFloat32(4), c.beFloat32(0x10))
                c.replaceSubrange(0..<4, with: be32(e.left.x.bitPattern)); c.replaceSubrange(8..<12, with: be32(e.left.y.bitPattern))
                c.replaceSubrange(0x0C..<0x10, with: be32(e.right.x.bitPattern)); c.replaceSubrange(0x14..<0x18, with: be32(e.right.y.bitPattern))
                checkpoints.append(c)
            }
        }
        sections[1].append(checkpoints)

        var pointIndex = 0
        for route in doc.poti {
            var r = route.bol ?? Data(count: 0x10)
            r.replaceSubrange(0..<2, with: be16(UInt16(route.points.count)))
            r.replaceSubrange(2..<4, with: be16(UInt16(pointIndex)))
            sections[2].append(r)
            for p in route.points {
                var pr = p.bol ?? Data(count: 0x20)
                put(&pr, 0, p.position)
                sections[3].append(pr)
            }
            pointIndex += route.points.count
        }
        for e in doc.gobj {
            var r = e.bol ?? defaultObject
            var settings = e.settings
            if e.bol == nil && e.objectID == 1 {
                // A new item box as every retail one is (all 200+ on the disc): filter 0x0F, and
                // setting 1 = 0x87, left at 0, Double Dash read a float as a pointer and froze.
                r[0x2C] = 0x0F
                if settings.first == 0 { settings[0] = 0x87 }
            }
            put(&r, 0, e.position); put(&r, 0x0C, e.scale); putRotation(&r, 0x18, e.rotation)
            r.replaceSubrange(0x24..<0x28, with: be16(e.objectID) + be16(e.routeID))
            for k in 0..<8 { r.replaceSubrange(0x30 + k * 2..<0x32 + k * 2, with: be16(k < settings.count ? settings[k] : 0)) }
            sections[4].append(r)
        }
        for e in doc.ktpt {
            var r = e.bol ?? defaultStart
            put(&r, 0, e.position); putRotation(&r, 0x18, e.rotation)
            r[0x24] = doc.stgi.polePosition
            r[0x25] = e.playerIndex < 0 ? 0xFF : UInt8(clamping: e.playerIndex)
            sections[5].append(r)
        }
        for e in doc.area {
            var r = e.bol ?? defaultArea
            put(&r, 0, e.position); put(&r, 0x0C, e.scale); putRotation(&r, 0x18, e.rotation)
            r[0x24] = e.shape; r[0x25] = e.type
            r.replaceSubrange(0x26..<0x28, with: be16(e.cameraIndex == 0xFF ? 0xFFFF : UInt16(e.cameraIndex)))
            sections[6].append(r)
        }
        for e in doc.came {
            var r = e.bol ?? defaultCamera
            func s16(_ v: UInt8) -> Data { be16(v == 0xFF ? 0xFFFF : UInt16(v)) }
            func u16(_ f: Float) -> Data { be16(UInt16(clamping: f.rounded().clampedInt)) }
            put(&r, 0, e.position); putRotation(&r, 0x0C, e.rotation); put(&r, 0x24, e.viewPositionStart); put(&r, 0x18, e.viewPositionEnd)
            r.replaceSubrange(0x30..<0x32, with: be16(e.type))
            r.replaceSubrange(0x32..<0x34, with: u16(e.zoomStart))
            r.replaceSubrange(0x34..<0x36, with: u16(e.time))
            r.replaceSubrange(0x36..<0x38, with: be16(UInt16(e.startFlag)))
            r.replaceSubrange(0x3C..<0x40, with: s16(e.routeID) + be16(e.pointVelocity))
            r.replaceSubrange(0x40..<0x44, with: u16(e.zoomEnd) + s16(e.next))
            sections[7].append(r)
        }
        for e in doc.jgpt {
            var r = e.bol ?? defaultRespawn
            put(&r, 0, e.position); putRotation(&r, 0x0C, e.rotation)
            r.replaceSubrange(0x18..<0x1C, with: be16(e.respawnID) + be16(respawnEnemyPoint(e, doc)))
            sections[8].append(r)
        }
        // Light and minigame params: as they were.
        let oldOff = (0..<11).map { Int(o.be32(0x44 + $0 * 4)) }
        sections[9] = o.subdata(in: min(oldOff[9], o.count)..<min(max(oldOff[9], oldOff[10]), o.count))
        sections[10] = o.subdata(in: min(oldOff[10], o.count)..<o.count)

        header.replaceSubrange(0x1A..<0x28, with: [doc.enpt.count, doc.ckph.count, doc.gobj.count, doc.area.count, doc.came.count, doc.poti.count, doc.jgpt.count]
            .reduce(Data()) { $0 + be16(UInt16(clamping: $1)) })
        header[0x3B] = UInt8(clamping: doc.ktpt.count)
        var out = header, offset = 0x7C
        for (i, s) in sections.enumerated() {
            out.replaceSubrange(0x44 + i * 4..<0x48 + i * 4, with: be32(UInt32(offset)))
            offset += s.count
        }
        sections.forEach { out.append($0) }
        return out
    }

    /// A respawn point's enemy-route point (the one a rescued kart rejoins the route at): its own
    /// when set, else, on a race course, the nearest. Every retail race course sets one; left at
    /// 0xFFFF the game indexes the route with -1 and reads through a null pointer every frame
    /// (only battle stages, which have no route, leave it unset).
    static func respawnEnemyPoint(_ e: JGPTEntry, _ doc: KMPDocument) -> UInt16 {
        guard e.extra == 0xFFFF, !doc.enpt.isEmpty else { return e.extra }
        let nearest = doc.enpt.indices.min { (doc.enpt[$0].position - e.position).length < (doc.enpt[$1].position - e.position).length }!
        return UInt16(nearest)
    }

    /// Link numbers for each enemy group's first and last point: groups joined by ENPH share one
    /// (a group's end = its next groups' starts), reusing the file's own numbers where they still fit.
    static func enemyLinks(_ doc: KMPDocument) -> (start: [Int16], end: [Int16]) {
        let n = doc.enph.count
        var parent = Array(0..<(2 * n)) // 0..<n = starts, n..<2n = ends
        func find(_ x: Int) -> Int { var x = x; while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }; return x }
        func union(_ a: Int, _ b: Int) { parent[find(a)] = find(b) }
        var joined = Set<Int>()
        for (g, e) in doc.enph.enumerated() {
            for next in e.nextGroups where Int(next) < n { union(n + g, Int(next)); joined.formUnion([n + g, Int(next)]) }
            for prev in e.previousGroups where Int(prev) < n { union(g, n + Int(prev)); joined.formUnion([g, n + Int(prev)]) }
            if e.pointCount == 1 { union(g, n + g) } // one point carries both ends
        }
        func original(_ x: Int) -> Int16? {
            let g = x % n, e = doc.enph[g]
            let i = Int(e.startIndex) + (x < n ? 0 : max(0, Int(e.pointCount) - 1))
            guard doc.enpt.indices.contains(i), let r = doc.enpt[i].bol else { return nil }
            let v = Int16(bitPattern: r.be16(0x0E))
            return v < 0 ? nil : v
        }
        var number: [Int: Int16] = [:], used = Set<Int16>()
        let roots = Set((0..<(2 * n)).filter(joined.contains).map(find)).sorted()
        for root in roots {
            let members = (0..<(2 * n)).filter { joined.contains($0) && find($0) == root }
            let candidates = Set(members.compactMap(original))
            if candidates.count == 1, let c = candidates.first, !used.contains(c) { number[root] = c; used.insert(c) }
        }
        var fresh: Int16 = 0
        for root in roots where number[root] == nil {
            while used.contains(fresh) { fresh += 1 }
            number[root] = fresh; used.insert(fresh)
        }
        // Every retail course numbers the link at enemy group 0's first point 0, and the game walks
        // the route from link 0: anything else read through a null route pointer every frame.
        if n > 0, joined.contains(0), let first = number[find(0)], first != 0 {
            if let other = number.first(where: { $0.value == 0 })?.key { number[other] = first }
            number[find(0)] = 0
        }
        func link(_ x: Int) -> Int16 { joined.contains(x) ? number[find(x)] ?? -1 : -1 }
        return ((0..<n).map(link), (0..<n).map { link(n + $0) })
    }

    // MARK: Rotation (s16 forward + up, x10000) <-> Euler degrees, R = Rx * Ry * Rz, +Z = forward

    static func euler(forward f: Vec3, up u: Vec3) -> Vec3 {
        let deg: Float = 180 / .pi
        if abs(u.x) < 1e-4, abs(u.z) < 1e-4, u.y > 0, abs(f.y) < 1e-4 {
            return Vec3(x: 0, y: atan2(f.x, f.z) * deg, z: 0)
        }
        let x = Vec3.cross(u, f)
        return Vec3(x: atan2(-f.y, f.z) * deg, y: asin(max(-1, min(1, f.x))) * deg, z: atan2(-u.x, x.x) * deg)
    }

    static func vectors(_ e: Vec3) -> (forward: Vec3, up: Vec3) {
        let r: Float = .pi / 180
        let (ca, sa, cb, sb, cc, sc) = (cos(e.x * r), sin(e.x * r), cos(e.y * r), sin(e.y * r), cos(e.z * r), sin(e.z * r))
        // Columns of Rx(a) * Ry(b) * Rz(c): Y = up, Z = forward.
        let up = Vec3(x: -cb * sc, y: ca * cc - sa * sb * sc, z: sa * cc + ca * sb * sc)
        let forward = Vec3(x: sb, y: -sa * cb, z: ca * cb)
        return (forward, up)
    }

    private static func direction(_ r: Data, _ o: Int) -> Vec3 {
        Vec3(x: Float(Int16(bitPattern: r.be16(o))) / 10000, y: Float(Int16(bitPattern: r.be16(o + 2))) / 10000, z: Float(Int16(bitPattern: r.be16(o + 4))) / 10000)
    }
    private static func euler(_ r: Data, _ o: Int) -> Vec3 { euler(forward: direction(r, o), up: direction(r, o + 6)) }
    /// Writes a rotation, keeping the stored vectors when it's unchanged (they don't round-trip exactly).
    private static func putRotation(_ r: inout Data, _ o: Int, _ e: Vec3) {
        guard euler(r, o) != e else { return }
        let (f, u) = vectors(e)
        for (k, v) in [f.x, f.y, f.z, u.x, u.y, u.z].enumerated() {
            r.replaceSubrange(o + k * 2..<o + k * 2 + 2, with: be16(UInt16(bitPattern: Int16(clamping: (v * 10000).rounded().clampedInt))))
        }
    }

    // MARK: Helpers

    private static func vec(_ r: Data, _ o: Int) -> Vec3 { Vec3(x: r.beFloat32(o), y: r.beFloat32(o + 4), z: r.beFloat32(o + 8)) }
    private static func put(_ r: inout Data, _ o: Int, _ v: Vec3) {
        r.replaceSubrange(o..<o + 12, with: be32(v.x.bitPattern) + be32(v.y.bitPattern) + be32(v.z.bitPattern))
    }
    private static func slots(_ list: [Int], _ count: Int) -> [UInt8] {
        (0..<count).map { $0 < list.count ? UInt8(clamping: list[$0]) : 0xFF }
    }
    private static func slot(_ list: [UInt8], _ k: Int) -> UInt16 { k < list.count && list[k] != 0xFF ? UInt16(list[k]) : 0xFFFF }
    private static func be16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
    private static func be32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }

    /// New-entry records, with libbol's defaults: scale 1, facing +Z, no route/camera/next.
    private static func cat(_ parts: Data...) -> Data { parts.reduce(Data(), +) }
    private static let identity = cat(be16(0), be16(0), be16(10000), be16(0), be16(10000), be16(0))
    private static let ones = cat(be32(Float(1).bitPattern), be32(Float(1).bitPattern), be32(Float(1).bitPattern))
    private static let defaultObject = cat(Data(count: 12), ones, identity, be16(1), be16(0xFFFF), be16(0), be16(0xFFFF), Data([0x8F, 3, 1, 0]), Data(count: 16)) // 0x2E = 1 on (nearly) every retail object
    private static let defaultStart = cat(Data(count: 12), ones, identity, Data([0, 0xFF, 0, 0]))
    private static let defaultArea = cat(Data(count: 12), ones, identity, Data([0, 0]), be16(0xFFFF), Data(count: 16))
    private static let defaultCamera = cat(Data(count: 12), identity, Data(count: 24), be16(0), be16(45), be16(360), be16(0), Data(count: 4),
                                           be16(0xFFFF), be16(0), be16(45), be16(0xFFFF), Data("null".utf8))
    private static let defaultRespawn = cat(Data(count: 12), identity, be16(0), be16(0), be16(0xFFFF), be16(0xFFFF))

    // MARK: Object names (Double Dash IDs), from mkdd-track-editor's object list

    static func objectName(_ id: UInt16) -> String {
        objectNames[id].map { "\($0) (\(id))" } ?? "Object \(id)"
    }
}

extension KMPDocument {
    /// An object's name in this document's game.
    func objectName(_ id: UInt16) -> String { isBOL ? BOL.objectName(id) : gobjDisplayName(id) }
}
