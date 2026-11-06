import Foundation

/// The course-data checks mkdd-track-editor runs before saving (its `ErrorAnalyzer`: the
/// community's list of what makes Double Dash freeze or crash), and a repair for the one a port
/// from Mario Kart Wii actually trips: checkpoint quads that aren't convex. Mario Kart Wii puts
/// up with a fan of checkpoints round a hairpin (several sharing one inner end); Double Dash's
/// "which quad is the kart in" search doesn't, and froze loading a ported course.
nonisolated extension BOL {
    /// mkdd-track-editor's `check_checkpoints`: the quad between two consecutive checkpoints
    /// (left = start, right = end) turns the same way at all four corners.
    static func isConvex(_ c1: CKPTEntry, _ c2: CKPTEntry) -> Bool {
        var last: Bool?
        for (p1, mid, p3) in [(c1.left, c2.left, c2.right), (c2.left, c2.right, c1.right),
                              (c2.right, c1.right, c1.left), (c1.right, c1.left, c2.left)] {
            let s1 = Vec2(x: p1.x - mid.x, y: p1.y - mid.y), s2 = Vec2(x: p3.x - mid.x, y: p3.y - mid.y)
            let turn = s1.x * s2.y - s2.x * s1.y > 0
            if let last, last != turn { return false }
            last = turn
        }
        return true
    }

    /// Every consecutive checkpoint pair the game forms a quad from: along each group, then each
    /// group's last checkpoint to the first of every group after it.
    static func checkpointPairs(_ doc: KMPDocument) -> [(Int, Int)] {
        var pairs: [(Int, Int)] = []
        for g in doc.ckph {
            let start = Int(g.startIndex), end = min(doc.ckpt.count, start + Int(g.pointCount))
            guard start < end else { continue }
            for i in start..<(end - 1) { pairs.append((i, i + 1)) }
            for n in g.nextGroups where n != 0xFF && Int(n) < doc.ckph.count {
                let first = Int(doc.ckph[Int(n)].startIndex)
                if doc.ckph[Int(n)].pointCount > 0, first < doc.ckpt.count { pairs.append((end - 1, first)) }
            }
        }
        return pairs
    }

    // Double Dash's lap counter (decomp `Course::createSector`, `KartChecker::checkLap`): each
    // checkpoint-to-checkpoint quad is a sector numbered by how many quads lie behind it, and a lap
    // counts only once every number up to the main path's length has been passed in order. So
    // every way round must cross the same number of quads, retail's parallel branches are equal
    // length, and a group off the main path has 0x8000 in its link word (`BOL.serialize`).

    /// The main path's checkpoint groups: from group 0, each group's first next group, round to the start.
    static func mainCheckpointGroups(_ doc: KMPDocument) -> Set<Int> {
        var main = Set<Int>(), g = 0
        while doc.ckph.indices.contains(g), main.insert(g).inserted { g = Int(doc.ckph[g].nextGroups.first ?? 0xFF) }
        return main
    }

    /// Group links into a group (or, for group 0, round to the start) that arrive after fewer
    /// quads than the longest way there: (from group, into group, quads short).
    static func shortCheckpointBranches(_ doc: KMPDocument) -> [(from: Int, to: Int, short: Int)] {
        let n = doc.ckph.count
        guard n > 1 else { return [] }
        func next(_ g: Int) -> [Int] { doc.ckph[g].nextGroups.prefix(4).prefix { $0 != 0xFF }.map(Int.init).filter { $0 < n } }
        var start = [Int](repeating: -1, count: n), lap = -1
        start[0] = 0
        for _ in 0..<n { // longest path; the only way back to group 0 is the lap
            for g in 0..<n where start[g] >= 0 {
                let end = start[g] + Int(doc.ckph[g].pointCount)
                for m in next(g) { if m == 0 { lap = max(lap, end) } else { start[m] = max(start[m], end) } }
            }
        }
        var out: [(Int, Int, Int)] = []
        for g in 0..<n where start[g] >= 0 {
            let end = start[g] + Int(doc.ckph[g].pointCount)
            for m in next(g) where end < (m == 0 ? lap : start[m]) { out.append((g, m, (m == 0 ? lap : start[m]) - end)) }
        }
        return out
    }

    /// Evens out parallel branches (see `shortCheckpointBranches`): a short branch gets checkpoints
    /// halfway along its longest gaps, which keeps its quads convex. Returns what changed.
    @discardableResult
    static func repairCheckpointBranches(_ doc: KMPDocument) -> [String] {
        var added: [Int: Int] = [:]
        for _ in 0..<64 {
            guard let (g, to, short) = shortCheckpointBranches(doc).first, doc.ckph[g].pointCount > 0 else { break }
            guard doc.ckpt.count + short <= 255 else { return ["Couldn't even out checkpoint group \(g + 1): too many checkpoints. Double Dash won't count laps."] }
            for _ in 0..<short {
                let first = Int(doc.ckph[g].startIndex), last = first + Int(doc.ckph[g].pointCount) - 1
                let exit = doc.ckpt[Int(doc.ckph[to].startIndex)]
                func mid(_ c: CKPTEntry) -> Vec2 { Vec2(x: (c.left.x + c.right.x) / 2, y: (c.left.y + c.right.y) / 2) }
                func gap(_ a: CKPTEntry, _ b: CKPTEntry) -> Float { let p = mid(a), q = mid(b); return hypot(q.x - p.x, q.y - p.y) }
                // Insert before index k, between checkpoints a and b.
                let gaps = (first..<last).map { (k: $0 + 1, a: doc.ckpt[$0], b: doc.ckpt[$0 + 1]) } + [(k: last + 1, a: doc.ckpt[last], b: exit)]
                let w = gaps.max { gap($0.a, $0.b) < gap($1.a, $1.b) }!
                let c = CKPTEntry(left: Vec2(x: (w.a.left.x + w.b.left.x) / 2, y: (w.a.left.y + w.b.left.y) / 2),
                                  right: Vec2(x: (w.a.right.x + w.b.right.x) / 2, y: (w.a.right.y + w.b.right.y) / 2),
                                  respawnIndex: w.a.respawnIndex, lapCounterType: -1)
                doc.ckpt.insert(c, at: w.k)
                for h in doc.ckph.indices where h != g && Int(doc.ckph[h].startIndex) >= w.k { doc.ckph[h].startIndex += 1 }
                doc.ckph[g].pointCount += 1
            }
            added[g, default: 0] += short
        }
        var report = added.sorted { $0.key < $1.key }.map { "Added \($0.value) checkpoint(s) to group \($0.key + 1) so every way round has as many as Double Dash's lap counter needs." }
        if !shortCheckpointBranches(doc).isEmpty { report.append("Couldn't even out the checkpoint branches. Double Dash won't count laps.") }
        return report
    }

    /// mkdd-track-editor's error analysis, for a race course or battle stage.
    static func problems(_ doc: KMPDocument) -> [String] {
        var out: [String] = []
        let battle = doc.ktpt.count == 8
        if doc.ktpt.count != 1 && !battle {
            out.append("A track needs 1 kart start point (a battle arena 8); this one has \(doc.ktpt.count).")
        } else if !battle, doc.ktpt[0].playerIndex != -1 {
            out.append("The kart start point must be for all players.")
        }
        if !battle {
            if doc.enph.isEmpty || doc.enpt.isEmpty { out.append("At least one enemy route is needed.") }
            for (i, g) in doc.enph.enumerated() where g.pointCount == 0 { out.append("Enemy route group \(i + 1) is empty.") }
            if !doc.enph.isEmpty {
                // Every route group's first and last point must join another group's, to form a loop.
                let links = enemyLinks(doc)
                if links.start.first != 0 { out.append("Enemy route group 0's first point must carry link 0, where the game starts the route.") }
                for g in doc.enph.indices where doc.enph[g].pointCount > 0 {
                    if links.start[g] == -1 { out.append("Enemy route group \(g + 1)'s start doesn't join another group, so the route doesn't loop.") }
                    if links.end[g] == -1 { out.append("Enemy route group \(g + 1)'s end doesn't join another group, so the route doesn't loop.") }
                }
            }
            if doc.ckph.isEmpty { out.append("At least one checkpoint group is needed.") }
            for (i, g) in doc.ckph.enumerated() where g.pointCount == 0 { out.append("Checkpoint group \(i + 1) is empty.") }
            for (a, b) in checkpointPairs(doc) where !isConvex(doc.ckpt[a], doc.ckpt[b]) {
                out.append("The quad between checkpoints \(a) and \(b) isn't convex.")
            }
            for (from, to, short) in shortCheckpointBranches(doc) {
                out.append("Checkpoint group \(from + 1) reaches group \(to + 1) \(short) checkpoint(s) short of the other way there, so Double Dash won't count laps.")
            }
        }
        if !battle {
            for (i, j) in doc.jgpt.enumerated() where Int(respawnEnemyPoint(j, doc)) >= doc.enpt.count {
                out.append("Respawn point \(i + 1) doesn't name an enemy route point to rejoin.")
            }
        }
        var ids = Set<UInt16>()
        for (i, j) in doc.jgpt.enumerated() where !ids.insert(j.respawnID).inserted {
            out.append("Respawn point \(i + 1) reuses ID \(j.respawnID).")
        }
        // The intro sequence: next-camera links must not loop.
        if doc.came.indices.contains(Int(doc.openingCameraIndex)) {
            var seen = Set<Int>(), c = Int(doc.openingCameraIndex)
            while doc.came.indices.contains(c) {
                guard seen.insert(c).inserted else { out.append("The intro cameras loop back on themselves."); break }
                let next = Int(doc.came[c].next)
                if next == 0xFF { break }
                c = next
            }
        }
        return out
    }

    /// Joins every enemy route group that nothing leads into (or that leads nowhere) to the group
    /// whose end (or start) is nearest, the way Double Dash needs its route to loop. Mario Kart
    /// Wii allows a group only reached by respawning. Returns what changed.
    @discardableResult
    static func repairEnemyRouteLinks(_ doc: KMPDocument) -> [String] {
        var report: [String] = []
        func point(_ g: Int, last: Bool) -> Vec3? {
            let e = doc.enph[g], i = Int(e.startIndex) + (last ? Int(e.pointCount) - 1 : 0)
            return e.pointCount > 0 && doc.enpt.indices.contains(i) ? doc.enpt[i].position : nil
        }
        func add(_ v: UInt8, to list: inout [UInt8]) -> Bool {
            if list.contains(v) { return true }
            guard let free = list.firstIndex(of: 0xFF) else { return false }
            list[free] = v; return true
        }
        for _ in 0..<2 { // ends first fixed can complete a start, so go round twice
            let links = enemyLinks(doc)
            for g in doc.enph.indices where doc.enph[g].pointCount > 0 {
                if links.start[g] == -1, let p = point(g, last: false),
                   let from = doc.enph.indices.filter({ $0 != g }).min(by: { (point($0, last: true).map { ($0 - p).length } ?? .infinity) < (point($1, last: true).map { ($0 - p).length } ?? .infinity) }),
                   add(UInt8(g), to: &doc.enph[from].nextGroups), add(UInt8(from), to: &doc.enph[g].previousGroups) {
                    report.append("Enemy route group \(g + 1) now follows group \(from + 1).")
                }
                if links.end[g] == -1, let p = point(g, last: true),
                   let to = doc.enph.indices.filter({ $0 != g }).min(by: { (point($0, last: false).map { ($0 - p).length } ?? .infinity) < (point($1, last: false).map { ($0 - p).length } ?? .infinity) }),
                   add(UInt8(to), to: &doc.enph[g].nextGroups), add(UInt8(g), to: &doc.enph[to].previousGroups) {
                    report.append("Enemy route group \(g + 1) now leads on to group \(to + 1).")
                }
            }
        }
        return report
    }

    /// Makes every checkpoint quad convex: a checkpoint in a bad quad is narrowed towards its
    /// middle a step at a time (which pulls apart a fan's shared inner end), and only if that
    /// can't fix it is a checkpoint that doesn't count laps dropped. Returns what changed.
    @discardableResult
    static func repairCheckpointQuads(_ doc: KMPDocument) -> [String] {
        var report: [String] = []
        func badCount() -> Int { checkpointPairs(doc).filter { !isConvex(doc.ckpt[$0.0], doc.ckpt[$0.1]) }.count }
        func narrowed(_ c: CKPTEntry, _ s: Float) -> CKPTEntry {
            let m = Vec2(x: (c.left.x + c.right.x) / 2, y: (c.left.y + c.right.y) / 2)
            var out = c
            out.left = Vec2(x: m.x + (c.left.x - m.x) * s, y: m.y + (c.left.y - m.y) * s)
            out.right = Vec2(x: m.x + (c.right.x - m.x) * s, y: m.y + (c.right.y - m.y) * s)
            return out
        }
        var guardCount = 0
        while guardCount < 200, let (a, b) = checkpointPairs(doc).first(where: { !isConvex(doc.ckpt[$0.0], doc.ckpt[$0.1]) }) {
            guardCount += 1
            let before = badCount()
            var fixed = false
            // Narrow one end of the pair, keeping the change only if it leaves fewer bad quads.
            for k in [b, a] where !fixed {
                let original = doc.ckpt[k]
                for s: Float in [0.95, 0.9, 0.8, 0.7, 0.6, 0.5] {
                    doc.ckpt[k] = narrowed(original, s)
                    if isConvex(doc.ckpt[a], doc.ckpt[b]), badCount() < before {
                        report.append("Narrowed checkpoint \(k + 1) to \(Int(s * 100))% so its quad is convex.")
                        fixed = true
                        break
                    }
                }
                if !fixed { doc.ckpt[k] = original }
            }
            if fixed { continue }
            // Drop one that doesn't count laps (and isn't its group's only checkpoint).
            let droppable = [b, a].first { k in
                doc.ckpt[k].lapCounterType == -1 && doc.ckph.contains {
                    (Int($0.startIndex)..<Int($0.startIndex) + Int($0.pointCount)).contains(k) && $0.pointCount > 1
                }
            }
            guard let k = droppable else { report.append("Couldn't make the quad between checkpoints \(a) and \(b) convex."); break }
            doc.ckpt.remove(at: k)
            for g in doc.ckph.indices {
                let start = Int(doc.ckph[g].startIndex)
                if (start..<start + Int(doc.ckph[g].pointCount)).contains(k) { doc.ckph[g].pointCount -= 1 }
                else if start > k { doc.ckph[g].startIndex -= 1 }
            }
            report.append("Removed checkpoint \(k + 1): no narrower version of it made a convex quad.")
        }
        return report
    }

    /// Double Dash's Make Testable: fills in what `problems` says a course (or, with 8 starts, a
    /// battle stage) can't load or be raced without, a start, a checkpoint group, unique respawn IDs, a looping enemy route, convex checkpoint quads, and leaves
    /// anything already valid alone. `ground` gives the collision's height at an X/Z.
    @discardableResult
    static func makeTestable(_ doc: KMPDocument, ground: ((Float, Float) -> Float?)? = nil) -> [String] {
        var fixes: [String] = []
        let battle = doc.ktpt.count == 8
        func grounded(_ p: Vec3) -> Vec3 { ground?(p.x, p.z).map { Vec3(x: p.x, y: $0 + 10, z: p.z) } ?? p }
        if doc.ktpt.isEmpty {
            doc.ktpt.append(KTPTEntry(position: grounded(Vec3())))
            fixes.append("No start point, added one at the origin, on the ground. Move it onto the start line.")
        } else if !battle, doc.ktpt.count > 1 {
            doc.ktpt.removeSubrange(1...)
            fixes.append("A track has one start point for every kart (a battle arena has 8), kept the first.")
        }
        if !battle, doc.ktpt[0].playerIndex != -1 {
            doc.ktpt[0].playerIndex = -1
            fixes.append("The start point was for one player, set it to all players.")
        }
        let start = doc.ktpt[0].position
        // No respawn point is needed: the battle stages and Luigi Circuit ship without one.
        var seen = Set<UInt16>()
        if doc.jgpt.contains(where: { !seen.insert($0.respawnID).inserted }) {
            for k in doc.jgpt.indices { doc.jgpt[k].respawnID = UInt16(k) }
            fixes.append("Respawn points shared IDs, numbered them 0, 1, 2...")
        }
        if !battle {
            if doc.ckpt.isEmpty {
                let half: Float = 3000
                doc.ckpt = [CKPTEntry(left: Vec2(x: start.x - half, y: start.z), right: Vec2(x: start.x + half, y: start.z), respawnIndex: 0, lapCounterType: 0)]
                doc.ckph = [PathLinkEntry(startIndex: 0, pointCount: 1, previousGroups: [0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF], nextGroups: [0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])]
                fixes.append("No checkpoints, added one gate at the start so a lap can count. Draw the rest round the track.")
            } else if doc.ckph.count == 1, doc.ckph[0].nextGroups.allSatisfy({ $0 == 0xFF }) {
                doc.ckph[0].nextGroups[0] = 0
                doc.ckph[0].previousGroups[0] = 0
                fixes.append("The checkpoint group led nowhere, looped it back to itself so laps continue.")
            }
            if !doc.enph.isEmpty { fixes += repairEnemyRouteLinks(doc) }
            fixes += repairCheckpointBranches(doc) + repairCheckpointQuads(doc)
        }
        // Intro cameras that loop forever: end the chain where it first comes back round.
        if doc.came.indices.contains(Int(doc.openingCameraIndex)) {
            var visited = Set<Int>(), c = Int(doc.openingCameraIndex)
            while doc.came.indices.contains(c), doc.came[c].next != 0xFF {
                visited.insert(c)
                let next = Int(doc.came[c].next)
                if visited.contains(next) {
                    doc.came[c].next = 0xFF
                    fixes.append("The intro cameras looped back on themselves, camera \(c + 1) now ends the sequence.")
                    break
                }
                c = next
            }
        }
        return fixes
    }
}
