// Mario Kart Wii -> Double Dash port check: every retail Mario Kart Wii race track is ported to a
// Double Dash slot (with that slot's minimap rectangle from the Double Dash disc's main.dol), and:
// - the archives read back through the app's retail-checked Double Dash readers and pass the
//   "Custom Course" verifier;
// - the model keeps every triangle, textures fit the GameCube budget, collision is all flat with
//   wall strips (not over the enemy route), and the course data keeps the start, enemy route, checkpoints and item boxes;
// - porting the result back to Mario Kart Wii (the existing `MKDDPort`) gives a track whose laps
//   still count (`CheckpointVerifier`), the course data survives the round trip;
// - Double Dash's own lap rules hold (decomp `Course::createSector`): equal-length branches, off-path groups flagged.
//
//   find "Revolution IDE/Core" -name '*.swift' ! -path '*/Workbench/*' ! -name AppState.swift \
//     ! -name SyntaxHighlighter.swift | tr '\n' '\0' | xargs -0 swiftc -O -parse-as-library -o /tmp/wii2dd \
//     "Revolution IDE/Core/Workbench/BaseGameLibrary.swift" Tests/WiiToMKDDCheck/main.swift
//   /tmp/wii2dd [mkwii.iso] [common-key] [mkdd.iso]

import Foundation

@main enum WiiToMKDDCheck {
    static func main() throws {
        let args = CommandLine.arguments
        let roms = "\(ProcessInfo.processInfo.environment["ROMS_DIR"] ?? "Roms")/"
        let wii = try WiiDisc(url: URL(fileURLWithPath: args.count > 1 ? args[1] : roms + "Wii/MKWii/Mario Kart Wii (USA) (En,Fr,Es).iso"),
                              commonKey: [UInt8](try Data(contentsOf: URL(fileURLWithPath: args.count > 2 ? args[2] : roms + "Wii/Keys/common-key"))), koreanKey: nil)
        let ddURL = URL(fileURLWithPath: args.count > 3 ? args[3] : roms + "GCN/MKDD/Mario Kart - Double Dash!! (USA).iso")
        let dd = try GameCubeDisc(url: ddURL)
        let dol = try MKDDSlots.dol(fromDisc: ddURL)
        let region = MKDDSlots.region(gameID: dd.gameID)!
        var courses: [DiscNode] = []
        func walk(_ n: DiscNode) { if n.isDirectory { n.children.forEach(walk) } else if n.name.hasSuffix("_course.szs") || (n.name.hasPrefix("old_") && !n.name.hasSuffix("_d.szs") && !n.name.hasPrefix("old_mario_gc_") && !BattleArena.slots.contains { $0.file == n.name }) { courses.append(n) } }
        walk(wii.root)
        let races = MKDDSlots.slots.filter { !$0.battle }
        var failures = 0, done = 0, animated = 0, routePoints = 0, routeOnWall = 0
        func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL", what); failures += 1 } }
        for (i, node) in courses.sorted(by: { $0.name < $1.name }).enumerated() {
            let slot = races[i % races.count]
            let szs = try wii.readFile(node: node)
            let out: MKDDTrackBuilder.Output
            do { out = try MKWiiToMKDD.port(szs, name: node.name, slot: slot, minimap: MKDDSlots.minimap(for: slot, dol: dol, region: region)) }
            catch { check(false, "\(node.name): \(error)"); continue }
            let (src, _) = try SZS.open(szs)
            let kmp = try KMPDocument.parse(src.children.first { $0.name == "course.kmp" }!.data!)
            let (root, _) = try SZS.open(out.archives[0].data)
            let stem = slot.fileStem
            func f(_ suffix: String) -> Data { root.children.first { $0.name == stem + suffix }!.data! }
            let v = ModVerifier.verify(.mkddCourse, root: root)
            check(v.passed, "\(node.name) -> \(slot.title): verifier \(v.checks.filter { $0.required && !$0.passed }.map { "\($0.label): \($0.detail)" })")
            let bmd = try J3DModel.parse(f("_course.bmd"))
            // Texture animations: each SRT0 that moves a coloured texture comes over as a retail-named BTK on materials the BMD has.
            let btkFiles = root.children.filter { $0.name.hasPrefix(stem + "_course") && $0.name.hasSuffix(".btk") }
            if !btkFiles.isEmpty { animated += 1 }
            for b in btkFiles {
                let anim = try J3DAnimation.parse(b.data!)
                check(anim.loopMode == 2 && anim.targets.allSatisfy { t in bmd.materials.contains { $0.name == t.name } && t.texMatrix == 0 }, "\(node.name): \(b.name) targets real materials")
            }
            let brres = try BRRESDocument.parse(src.children.first { $0.name == "course_model.brres" }!.data!)
            let mdl0 = MDL0Parser.parse(brres.resources.first { $0.magic == "MDL0" && $0.name == "course" }!, rawFile: brres.rawData)!
            // Zero-area triangles (degenerate strip joins) are skipped by the J3D reader, as in retail models.
            let wiiTris = mdl0.meshes.reduce(0) { n, m in
                n + stride(from: 0, to: m.vertices.count - 2, by: 3).filter { i in
                    let a = m.vertices[i].position, b = m.vertices[i + 1].position, c = m.vertices[i + 2].position
                    return a != b && b != c && a != c
                }.count
            }
            // Moving the track can collapse the odd sub-unit sliver to zero area in float; allow 0.1%.
            check(abs(bmd.triangles.count - wiiTris) <= max(1, wiiTris / 1000), "\(node.name): \(bmd.triangles.count) of \(wiiTris) triangles")
            // Materials draw as on the Wii: each sampler's wrap, its texture matrix baked into the UVs
            // (Luigi Circuit's grass repeats 25x), and its own transparency mode.
            if node.name == "beginner_course.szs" {
                let grass = bmd.triangles.filter { bmd.materials[$0.material].name == "t_kusa_070712c" }
                let us = grass.flatMap { [$0.v.0, $0.v.1, $0.v.2] }.compactMap { $0.uv[0]?.x }
                check((us.max() ?? 0) - (us.min() ?? 0) > 20, "Luigi Circuit's grass UVs carry its 25x texture matrix (span \((us.max() ?? 0) - (us.min() ?? 0)))")
                let wraps = Dictionary(bmd.textures.map { ($0.name, [$0.wrapS, $0.wrapT]) }, uniquingKeysWith: { a, _ in a })
                check(wraps["lc_ami"] == [1, 2] && wraps["hana"] == [2, 2] && wraps["t_tree_otubo"] == [1, 0], "Luigi Circuit's wrap modes carried over \(wraps)")
                let modes = Dictionary(bmd.materials.map { ($0.name, $0.mode) }, uniquingKeysWith: { a, _ in a })
                check(modes["t_tree_otubo"] == 2 && modes["mainROAD_all_mip"] == 1, "Luigi Circuit's trees alpha-tested, road opaque \(modes)")
            }
            let texBytes = bmd.textures.reduce(0) { $0 + ($1.encoded?.count ?? 0) }
            check(texBytes <= GCTextures.courseBudget * 4 / 3, "\(node.name): textures \(texBytes / 1024) KB within budget")
            let bco = try BCO.parse(f("_course.bco"))
            let steep = bco.triangles.filter { t in let n = Vec3.cross(t.v1 - t.v0, t.v2 - t.v0); return abs(n.y) < 0.3 * n.length }.count
            let wallStrips = bco.triangles.filter { $0.attribute >> 8 == 0x02 }.count
            check(steep == 0 && wallStrips > 0, "\(node.name): collision flat (\(steep) steep) with \(wallStrips) wall-strip triangles")
            let bol = try BOL.parse(f("_course.bol"))
            // Boost ramps and trickable surfaces stay drivable: a railing beside one used to cut it into wall.
            let kcl = try KCLDocument.parse(src.children.first { $0.name == "course.kcl" }!.data!)
            let mine = MKWiiToMKDD.collision(kcl, place: .init(scale: 1)).triangles
            var rampsOnWall = 0
            for t in kcl.triangles where [0x07, 0x08].contains(t.attribute & 0x1F) || t.attribute & 0x2000 != 0 {
                let n = Vec3.cross(t.v1 - t.v0, t.v2 - t.v0), p = (t.v0 + t.v1 + t.v2) * (1 / 3)
                guard abs(n.y) >= 0.3 * n.length else { continue }
                if let under = mine.first(where: { o in
                    let a = o.v0, b = o.v1, c = o.v2
                    let d = (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
                    guard abs(d) > 1e-6 else { return false }
                    let u = ((b.z - c.z) * (p.x - c.x) + (c.x - b.x) * (p.z - c.z)) / d, v = ((c.z - a.z) * (p.x - c.x) + (a.x - c.x) * (p.z - c.z)) / d
                    return u >= 0 && v >= 0 && u + v <= 1 && abs(u * a.y + v * b.y + (1 - u - v) * c.y - p.y) < 1
                }), [0x02, 0x12].contains(under.attribute >> 8) { rampsOnWall += 1 }
            }
            check(rampsOnWall == 0, "\(node.name): \(rampsOnWall) boost/trick ramp triangles became wall")
            // The enemy route runs on road: the surface under each point (the highest one not above it) isn't wall.
            for e in bol.enpt {
                var top: KCLTriangle?, topY = -Float.infinity
                for t in bco.triangles {
                    let a = t.v0, b = t.v1, c = t.v2, p = e.position
                    let d = (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
                    guard abs(d) > 1e-6 else { continue }
                    let u = ((b.z - c.z) * (p.x - c.x) + (c.x - b.x) * (p.z - c.z)) / d, v = ((c.z - a.z) * (p.x - c.x) + (a.x - c.x) * (p.z - c.z)) / d
                    guard u >= 0, v >= 0, u + v <= 1 else { continue }
                    let y = u * a.y + v * b.y + (1 - u - v) * c.y
                    if y < p.y + 100, y > topY { topY = y; top = t }
                }
                routePoints += 1
                if let top, [0x02, 0x12].contains(top.attribute >> 8) { routeOnWall += 1 }
            }
            // mkdd-track-editor's freeze/crash checks (non-convex checkpoint quads froze a real port).
            let bolProblems = BOL.problems(bol)
            check(bolProblems.isEmpty, "\(node.name): course data passes mkdd-track-editor's checks \(bolProblems)")
            // DUMP_PORT=<dir> writes Luigi Circuit's port as luigi_* files, ready to swap into Luigi.arc.
            if let dir = ProcessInfo.processInfo.environment["DUMP_PORT"], node.name == "beginner_course.szs" {
                for c in root.children where !c.isDirectory && c.name.hasPrefix(stem) {
                    try? c.data?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("luigi" + c.name.dropFirst(stem.count)))
                }
            }
            if let dir = ProcessInfo.processInfo.environment["DUMP_BOL"] { try? f("_course.bol").write(to: URL(fileURLWithPath: dir).appendingPathComponent(node.name + ".bol")) }
            // Double Dash's lap counter: every way round crosses as many checkpoints (`BOL.problems` above),
            // and every group off the main path is flagged so (link word 0x8000), as retail's are.
            let main = BOL.mainCheckpointGroups(bol)
            check(bol.ckph.indices.allSatisfy { g in (bol.ckph[g].bol!.be16(2) & 0x8000 == 0) == main.contains(g) }, "\(node.name): checkpoint groups off the main path are flagged")
            check(bol.enpt.count == kmp.enpt.count && bol.ckpt.count >= kmp.ckpt.count - 8 && bol.ktpt.count == 1
                  && bol.gobj.count == kmp.gobj.filter { $0.objectID == 0x65 || $0.objectID == 0x76 }.count
                  && bol.came.first?.startFlag == 1 && bol.came.last?.type == 8,
                  "\(node.name): course data \(bol.enpt.count)/\(kmp.enpt.count) enemy, \(bol.ckpt.count)/\(kmp.ckpt.count) checkpoints")
            // Back to Wii: laps must still count.
            do {
                let back = try MKDDPort.port(out.archives[0].data, name: slot.archive, scale: 1)
                let (wroot, _) = try SZS.open(back.archive)
                let backBRRES = try BRRESDocument.parse(wroot.children.first { $0.name == "course_model.brres" }!.data!)
                check(btkFiles.isEmpty || backBRRES.resources.contains { $0.magic == "SRT0" && $0.name == "course" }, "\(node.name): texture animation survives the round trip")
                let report = CheckpointVerifier.verify(try KMPDocument.parse(wroot.children.first { $0.name == "course.kmp" }!.data!))
                let errors = report.issues.filter { $0.severity == .error }
                check(errors.isEmpty && report.loopsDriven >= 3 && report.lapsCounted == report.loopsDriven,
                      "\(node.name): round trip laps \(report.lapsCounted)/\(report.loopsDriven) \(errors.map(\.message))")
            } catch { check(false, "\(node.name): port back to Wii failed: \(error)") }
            done += 1
            print("done \(node.name) -> \(slot.title): \(out.report.filter { $0.contains("Collision") || $0.contains("Textures") || $0.contains("fit") }.joined(separator: " | "))")
        }
        // Scale to Fit: the whole driveable floor lands inside the slot's minimap area.
        let slot = races.first { $0.archive == "Luigi2" }!, m = MKDDSlots.minimap(for: slot, dol: dol, region: region)!
        let farm = courses.first { $0.name == "farm_course.szs" }!
        let fitted = try MKWiiToMKDD.port(try wii.readFile(node: farm), name: farm.name, slot: slot, minimap: m, fitScale: true)
        let (froot, _) = try SZS.open(fitted.archives[0].data)
        let fbco = try BCO.parse(froot.children.first { $0.name == "luigi_course.bco" }!.data!)
        let floor = fbco.triangles.filter { MKDDMinimap.onMap(bcoFlag: $0.attribute) }.flatMap { [$0.v0, $0.v1, $0.v2] }
        let inside = floor.allSatisfy { $0.x >= min(m.corner1.x, m.corner2.x) - 1 && $0.x <= max(m.corner1.x, m.corner2.x) + 1 && $0.z >= min(m.corner1.y, m.corner2.y) - 1 && $0.z <= max(m.corner1.y, m.corner2.y) + 1 }
        check(inside && !fitted.report.contains { $0.contains("fall outside") }, "Scale to Fit puts Moo Moo Meadows inside Luigi Circuit's minimap area")
        // Before walls were cut from the floor behind them, 4.5% of enemy route points sat on wall strips laid over the road.
        check(routeOnWall * 100 <= routePoints, "enemy route on road: \(routeOnWall) of \(routePoints) points on a wall")
        print(failures == 0 ? "ok   \(done) tracks ported and verified (\(animated) with texture animations), Scale to Fit checked" : "FAIL \(failures)")
        if failures > 0 { exit(1) }
    }
}
