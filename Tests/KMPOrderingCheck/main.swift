// KMP ordering and respawn check, on every retail Mario Kart Wii race track:
// - moving an enemy/item point, checkpoint, route point or respawn point later and back again,
//   and moving a route down and back up, gives back the byte-identical course.kmp;
// - after a move, everything that refers to points/routes by index still refers to the same
//   thing (areas' enemy points, checkpoints' respawn points, objects'/areas'/cameras' routes);
// - "Respawn per Checkpoint" makes one respawn per checkpoint, each on the collision's floor
//   (within 15 units, from the course's own height), facing its next checkpoint, and the laps
//   still count;
// - inserting a point after an enemy/item point, checkpoint or route point (mid-path and at a
//   path's end) puts it between its neighbours, keeps every group's points (and areas' enemy
//   points) the same, and the laps still count;
// - deleting a mid-path checkpoint/enemy point, and separating the end or start of a path into a
//   new group, keeps the groups tiling the points, areas on their enemy points, and laps counting;
// - copying the enemy paths to item paths (all, and without off-road branches) keeps every point
//   and link, drops only links to left-out branches (and branches that cuts off), leaves every
//   item path with a previous and a next one, and survives a save and re-read;
// - the verifier passes every retail track's item and checkpoint paths, and Make Testable's
//   unreachable-item-path removal leaves none without a previous path.
//
//   find "Revolution IDE/Core" -name '*.swift' ! -path '*/Workbench/*' ! -name AppState.swift | tr '\n' '\0' | xargs -0 swiftc -O -parse-as-library -o /tmp/ordercheck \
//     "Revolution IDE/Core/Workbench/"{BaseGameLibrary,KMPDocumentEditing,WorkbenchModels}.swift Tests/KMPOrderingCheck/*.swift
//   /tmp/ordercheck [mkwii.iso] [common-key]

import Foundation

@main enum KMPOrderingCheck {
    @MainActor static func main() throws {
        var failures = 0, tracks = 0
        func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL", what); failures += 1 } }
        let args = CommandLine.arguments, roms = "\(ProcessInfo.processInfo.environment["ROMS_DIR"] ?? "Roms")/"
        let wii = try WiiDisc(url: URL(fileURLWithPath: args.count > 1 ? args[1] : roms + "Wii/MKWii/Mario Kart Wii (USA) (En,Fr,Es).iso"),
                              commonKey: [UInt8](try Data(contentsOf: URL(fileURLWithPath: args.count > 2 ? args[2] : roms + "Wii/Keys/common-key"))), koreanKey: nil)
        var courses: [DiscNode] = []
        func walk(_ n: DiscNode) { if n.isDirectory { n.children.forEach(walk) } else if n.name.hasSuffix("_course.szs") || (n.name.hasPrefix("old_") && !n.name.hasSuffix("_d.szs") && !n.name.hasPrefix("old_mario_gc_") && !BattleArena.slots.contains { $0.file == n.name }) { courses.append(n) } }
        walk(wii.root)
        for node in courses.sorted(by: { $0.name < $1.name }) {
            let (root, _) = try SZS.open(try wii.readFile(node: node))
            let original = root.children.first { $0.name == "course.kmp" }!.data!
            let kcl = try KCLDocument.parse(root.children.first { $0.name == "course.kcl" }!.data!)
            let name = node.name

            // Move-and-back round trips.
            for sel in [KMPSelection.enpt(0), .itpt(0), .ckpt(0), .jgpt(0), .poti(route: 0, point: 0)] {
                let doc = try KMPDocument.parse(original)
                guard doc.canMovePoint(sel, by: 1), let moved = doc.movePoint(sel, by: 1) else { continue }
                doc.movePoint(moved, by: -1)
                check(doc.serialize() == original, "\(name): \(sel) later and back is identical")
            }
            if let doc = try? KMPDocument.parse(original), doc.poti.count >= 2 {
                let route0 = doc.poti[0].points.map(\.position), users = doc.gobj.indices.filter { doc.gobj[$0].routeID == 0 }
                doc.moveRoute(0, by: 1)
                check(doc.poti[1].points.map(\.position) == route0 && users.allSatisfy { doc.gobj[$0].routeID == 1 }, "\(name): objects follow their route when it moves")
                doc.moveRoute(1, by: -1)
                check(doc.serialize() == original, "\(name): route down and back up is identical")
            }
            // References: an area pointing at an enemy point keeps pointing at that point.
            if let doc = try? KMPDocument.parse(original), let a = doc.area.firstIndex(where: { $0.enptID != 0xFF && doc.enpt.indices.contains(Int($0.enptID)) }) {
                let i = Int(doc.area[a].enptID), p = doc.enpt[i].position
                if let moved = doc.movePoint(.enpt(i), by: doc.canMovePoint(.enpt(i), by: 1) ? 1 : -1), case .enpt(let j) = moved {
                    check(doc.area[a].enptID == UInt8(j) && doc.enpt[j].position == p, "\(name): area's enemy point follows the move")
                }
            }
            // Inserting between points.
            for make in [{ KMPSelection.enpt($0) }, { .itpt($0) }, { .ckpt($0) }] as [(Int) -> KMPSelection] {
                for pick in ["middle", "tail"] {
                    let doc = try KMPDocument.parse(original)
                    let (groups, count): ([PathLinkEntry], Int) = {
                        switch make(0) { case .enpt: return (doc.enph, doc.enpt.count); case .itpt: return (doc.itph, doc.itpt.count); default: return (doc.ckph, doc.ckpt.count) }
                    }()
                    guard let g = groups.first(where: { $0.pointCount >= 3 }) else { continue }
                    let i = Int(g.startIndex) + (pick == "middle" ? 1 : Int(g.pointCount) - 1)
                    func pos(_ d: KMPDocument, _ k: Int) -> Vec3 {
                        switch make(0) { case .enpt: return d.enpt[k].position; case .itpt: return d.itpt[k].position
                        default: let c = d.ckpt[k]; return Vec3(x: c.left.x + c.right.x, y: 0, z: c.left.y + c.right.y) }
                    }
                    func members(_ d: KMPDocument) -> [[Vec3]] {
                        let gs: [PathLinkEntry] = { switch make(0) { case .enpt: return d.enph; case .itpt: return d.itph; default: return d.ckph } }()
                        return gs.map { e in (Int(e.startIndex)..<Int(e.startIndex) + Int(e.pointCount)).map { pos(d, $0) } }
                    }
                    let before = members(doc)
                    let areaTargets = doc.area.compactMap { $0.enptID != 0xFF && doc.enpt.indices.contains(Int($0.enptID)) ? doc.enpt[Int($0.enptID)].position : nil }
                    guard doc.canInsertPoint(after: make(i)), doc.insertPoint(after: make(i)) == make(i + 1) else { check(false, "\(name): insert after \(make(i))"); continue }
                    var after = members(doc)
                    let gi = before.firstIndex { $0.contains(pos(doc, i)) }!
                    let added = after[gi].remove(at: i + 1 - Int(g.startIndex))
                    check(after == before, "\(name): groups keep their points after inserting after \(make(i)) (\(pick))")
                    check(doc.serialize().count == original.count + 0x14, "\(name): one entry (0x14 bytes) larger")
                    if pick == "middle" {
                        let a = pos(doc, i), c = pos(doc, i + 2)
                        check(abs(added.x - (a.x + c.x) / 2) < 0.01 && abs(added.z - (a.z + c.z) / 2) < 0.01, "\(name): inserted halfway after \(make(i))")
                    }
                    let areaNow = doc.area.compactMap { $0.enptID != 0xFF && doc.enpt.indices.contains(Int($0.enptID)) ? doc.enpt[Int($0.enptID)].position : nil }
                    check(areaNow == areaTargets, "\(name): areas keep their enemy points")
                    if make(0) == .ckpt(0) {
                        let laps = CheckpointVerifier.verify(try KMPDocument.parse(doc.serialize()))
                        check(laps.issues.allSatisfy { $0.severity != .error } && laps.lapsCounted == laps.loopsDriven && laps.loopsDriven >= 3, "\(name): laps count after inserting a checkpoint (\(pick))")
                    }
                }
            }
            if let doc = try? KMPDocument.parse(original), let r = doc.poti.firstIndex(where: { $0.points.count >= 2 }) {
                let pts = doc.poti[r].points.map(\.position)
                doc.insertPoint(after: .poti(route: r, point: 0))
                let p = doc.poti[r].points.map(\.position)
                check(p.count == pts.count + 1 && p[0] == pts[0] && Array(p[2...]) == Array(pts[1...]) && abs(p[1].x - (pts[0].x + pts[1].x) / 2) < 0.01, "\(name): route point inserted halfway")
            }
            // Deleting mid-path, and separating a path's end/start into its own group.
            func tiles(_ g: [PathLinkEntry], _ count: Int) -> Bool {
                var next = 0
                for e in g { guard Int(e.startIndex) == next, e.pointCount > 0 else { return false }; next += Int(e.pointCount) }
                return next == count
            }
            func lapsCount(_ d: KMPDocument) throws -> Bool {
                let laps = CheckpointVerifier.verify(try KMPDocument.parse(d.serialize()))
                return laps.issues.allSatisfy { $0.severity != .error } && laps.lapsCounted == laps.loopsDriven && laps.loopsDriven >= 3
            }
            // Insert before: mid-path lands halfway from the previous point; before a path's first
            // point lands half a step back; either way the path keeps its points and laps count.
            if let doc = try? KMPDocument.parse(original), let g = doc.enph.first(where: { $0.pointCount >= 3 }) {
                let s = Int(g.startIndex), pts = doc.enpt.map(\.position), targets = doc.area.map(\.enptID)
                check(doc.insertPoint(before: .enpt(s + 1)) == .enpt(s + 1), "\(name): insert before mid-path")
                let p = doc.enpt[s + 1].position
                check(abs(p.x - (pts[s].x + pts[s + 1].x) / 2) < 0.01 && doc.enpt[s + 2].position == pts[s + 1], "\(name): inserted halfway before")
                let next = doc.enpt[s + 1].position
                check(doc.insertPoint(before: .enpt(s)) == .enpt(s), "\(name): insert before a path's first point")
                let q = doc.enpt[s].position, first = pts[s], mid = Vec3(x: (first.x + next.x) / 2, y: 0, z: (first.z + next.z) / 2)
                check(doc.enpt[s + 1].position == first && abs(q.x - (2 * first.x - mid.x)) < 0.01 && abs(q.z - (2 * first.z - mid.z)) < 0.01, "\(name): half a step before the first point")
                check(try tiles(doc.enph, doc.enpt.count) || !tiles(KMPDocument.parse(original).enph, pts.count), "\(name): enemy groups still tile after insert before")
                check(zip(targets, doc.area.map(\.enptID)).allSatisfy { a, b in a == 0xFF || pts[Int(a)] == doc.enpt[Int(b)].position }, "\(name): areas keep their enemy points after insert before")
            }
            if let doc = try? KMPDocument.parse(original), let g = doc.ckph.first {
                doc.insertPoint(before: .ckpt(Int(g.startIndex) + 1))
                check(try lapsCount(doc), "\(name): laps count after inserting a checkpoint before")
            }
            for kind in ["ckpt", "enpt"] {
                for op in ["delete", "tail", "head"] {
                    let box = KMPDocumentBox(doc: try KMPDocument.parse(original))
                    let d = box.doc
                    let groups = kind == "ckpt" ? d.ckph : d.enph
                    guard let gi = groups.firstIndex(where: { $0.pointCount >= 5 }) else { continue }
                    let g = groups[gi], s = Int(g.startIndex), n = Int(g.pointCount)
                    let make: (Int) -> KMPSelection = { kind == "ckpt" ? .ckpt($0) : .enpt($0) }
                    let areaTargets = d.area.compactMap { $0.enptID != 0xFF && d.enpt.indices.contains(Int($0.enptID)) && Int($0.enptID) != s + 2 ? d.enpt[Int($0.enptID)].position : nil }
                    switch op {
                    case "delete": box.remove(make(s + 2))
                    case "tail": check(box.separateToNewGroup([make(s + n - 2), make(s + n - 1)]), "\(name): separate \(kind) tail")
                    default: check(box.separateToNewGroup([make(s), make(s + 1)]), "\(name): separate \(kind) head")
                    }
                    let now = kind == "ckpt" ? d.ckph : d.enph
                    check(tiles(now, kind == "ckpt" ? d.ckpt.count : d.enpt.count), "\(name): \(kind) groups tile the points after \(op)")
                    if op != "delete" {
                        check(now.count == groups.count + 1 && now.last!.pointCount == 2, "\(name): \(kind) \(op) makes a 2-point group")
                    }
                    let areaNow = d.area.compactMap { $0.enptID != 0xFF && d.enpt.indices.contains(Int($0.enptID)) ? d.enpt[Int($0.enptID)].position : nil }
                    if kind == "enpt" { check(areaNow == areaTargets, "\(name): areas keep their enemy points after \(op)") }
                    if kind == "ckpt" { check(try lapsCount(d), "\(name): laps count after checkpoint \(op)") }
                }
            }
            // Enemy paths to item paths.
            do {
                let d = try KMPDocument.parse(original)
                let cut0 = d.itemPathsCutOff(excluding: [])
                d.copyEnemyPathsToItemPaths(excluding: [])
                check(d.itph.count == d.enph.count - cut0.count, "\(name): only unreachable enemy paths (\(cut0.sorted())) left out of item paths")
                func links(_ l: [UInt8]) -> Set<UInt8> { Set(l).subtracting([0xFF]) }
                check(!cut0.isEmpty || zip(d.itph, d.enph).allSatisfy { $0.startIndex == $1.startIndex && $0.pointCount == $1.pointCount && links($0.nextGroups).isSuperset(of: links($1.nextGroups)) && links($0.previousGroups).isSuperset(of: links($1.previousGroups)) }
                      && d.itpt.map(\.position) == d.enpt.map(\.position), "\(name): item paths copy the enemy paths (every link kept)")
                check(d.itph.indices.allSatisfy { i in d.itph[i].nextGroups.allSatisfy { $0 == 0xFF || d.itph[Int($0)].previousGroups.contains(UInt8(i)) } }, "\(name): converted links listed from both ends")
                // The sheet's default: off-road paths that are a real alternative branch.
                let offroad = Set(d.enph.indices.filter { g in
                    let into = d.enph.indices.filter { d.enph[$0].nextGroups.contains(UInt8(g)) }
                    return d.enpt.indices.contains(Int(d.enph[g].startIndex)) && d.enpt[Int(d.enph[g].startIndex)].setting1 == 1
                        && !into.isEmpty && into.allSatisfy { p in d.enph[p].nextGroups.contains { $0 != 0xFF && $0 != UInt8(g) } }
                })
                let cutOff = d.itemPathsCutOff(excluding: offroad)
                d.copyEnemyPathsToItemPaths(excluding: offroad)
                check(d.itph.count == d.enph.count - offroad.count - cutOff.count && d.itph.allSatisfy { ($0.nextGroups + $0.previousGroups).allSatisfy { $0 == 0xFF || Int($0) < d.itph.count } }, "\(name): leaving out \(offroad.count) off-road paths keeps links in range")
                check(d.itph.allSatisfy { $0.previousGroups.contains { $0 != 0xFF } && $0.nextGroups.contains { $0 != 0xFF } }, "\(name): every converted item path has a previous and a next path")
                let back = try KMPDocument.parse(d.serialize())
                check(back.itpt.map(\.position) == d.itpt.map(\.position) && back.itph.map(\.nextGroups) == d.itph.map(\.nextGroups), "\(name): converted item paths survive save")
                check(d.itph.count * 2 > d.enph.count, "\(name): the default keeps most paths (\(d.itph.count) of \(d.enph.count))")
                if !cutOff.isEmpty { print("  \(name): leaving out off-road paths also cuts off enemy path(s) \(cutOff.sorted())") }
            }
            do {
                let v = ModVerifier.verify(.mkwiiCourse, root: root)
                for c in v.checks where c.label.hasPrefix("Item paths") || c.label.hasPrefix("Checkpoint groups") { check(c.passed, "\(name): retail passes \(c.label): \(c.detail)") }
            }
            // Respawn per checkpoint.
            let doc = try KMPDocument.parse(original)
            let count = doc.makeRespawnPerCheckpoint(collision: kcl)
            check(count == doc.ckpt.count && doc.jgpt.count == count && doc.ckpt.indices.allSatisfy { Int(doc.ckpt[$0].respawnIndex) == $0 }, "\(name): one respawn per checkpoint")
            let ground = DriverPath.GroundQuery(kcl)
            let next = CheckpointVerifier.successors(doc)
            var offGround = 0, backwards = 0
            for (i, j) in doc.jgpt.enumerated() {
                if let y = ground.height(x: j.position.x, z: j.position.z, near: j.position.y), abs(j.position.y - y - 10) > 15 { offGround += 1 }
                if let n = next[i].first {
                    let c = doc.ckpt[n], to = ((c.left.x + c.right.x) / 2 - j.position.x, (c.left.y + c.right.y) / 2 - j.position.z)
                    let yaw = j.rotation.y * .pi / 180
                    if sin(yaw) * to.0 + cos(yaw) * to.1 <= 0 { backwards += 1 }
                }
            }
            check(offGround == 0 && backwards == 0, "\(name): respawns on the ground (\(offGround) off) facing on (\(backwards) backwards)")
            let laps = CheckpointVerifier.verify(try KMPDocument.parse(doc.serialize()))
            check(laps.issues.allSatisfy { $0.severity != .error } && laps.lapsCounted == laps.loopsDriven && laps.loopsDriven >= 3, "\(name): laps still count")
            tracks += 1
        }
        print(failures == 0 ? "ok   \(tracks) retail tracks: moves round-trip, references follow, inserts land between neighbours, delete/separate keep paths whole, respawn per checkpoint grounded" : "FAIL \(failures)")
        if failures > 0 { exit(1) }
    }
}
