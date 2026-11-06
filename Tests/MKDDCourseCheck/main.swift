// Double Dash custom course check, against a retail Mario Kart: Double Dash!! disc:
// - every retail course archive (single and multiplayer, all 22 slots and Luigi Circuit's 50cc pair) passes the
//   "Custom Course" verifier;
// - a generated course (a textured ring road with grass, from an .obj + .mtl + PNG) built for
//   Luigi Circuit's slot, with that slot's minimap rectangle read from the disc's main.dol,
//   produces one Luigi2.arc (Hot Swap renames it into Luigi2L.arc and the 50cc Luigi.arc / LuigiL.arc) that reads back through the app's retail-checked readers:
//   RARC root names, luigi_* file names, the model's triangles, the collision's surfaces, the
//   course data, the minimap texture; once its course data has a route and checkpoints it passes
//   the verifier; and the existing Double Dash -> Wii port accepts it.
//
//   find "Revolution IDE/Core" -name '*.swift' ! -path '*/Workbench/*' ! -name AppState.swift \
//     ! -name SyntaxHighlighter.swift | tr '\n' '\0' | xargs -0 swiftc -O -parse-as-library -o /tmp/mkddcheck \
//     "Revolution IDE/Core/Workbench/"{BaseGameLibrary,HotSwapTargets,GameCubeHotSwap,HotSwapAutoFix}.swift Tests/MKDDCourseCheck/main.swift
//   /tmp/mkddcheck [mkdd.iso]

import AppKit

@main enum MKDDCourseCheck {
    static func main() throws {
        var failures = 0
        func check(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failures += 1 } }
        func failed(_ r: ModVerifier.Result) -> String { r.checks.filter { $0.required && !$0.passed }.map { "\($0.label): \($0.detail)" }.joined(separator: " | ") }
        let url = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "\(ProcessInfo.processInfo.environment["ROMS_DIR"] ?? "Roms")/GCN/MKDD/Mario Kart - Double Dash!! (USA).iso")
        let disc = try GameCubeDisc(url: url)
        var nodes: [String: DiscNode] = [:]
        func f(_ n: DiscNode) { if n.isDirectory { n.children.forEach(f) } else { nodes[n.name] = n } }
        f(disc.root)
        var retailOK = 0
        for slot in MKDDSlots.slots {
            for name in slot.archives.map(\.name) {
                let (root, _) = try SZS.open(try disc.readFile(node: nodes[name]!))
                let r = ModVerifier.verify(.mkddCourse, root: root)
                if r.passed { retailOK += 1 } else { check(false, "\(name) (retail) passes the verifier: \(failed(r))") }
            }
        }
        check(retailOK == 46, "all \(retailOK)/46 retail archives pass the Double Dash verifier (incl. Luigi Circuit 50cc)")

        // Camera look-at points: 0x24 is the start, 0x18 the end. Every retail intro's last shot that
        // pans (type 5/6) ends looking at the karts; one that watches its start point (type 4) has it on them.
        var introOK = 0, intros = 0
        for slot in MKDDSlots.slots where !slot.battle {
            let (root, _) = try SZS.open(try disc.readFile(node: nodes[slot.archives[0].name]!))
            guard let bolData = root.children.first(where: { $0.name.hasSuffix("_course.bol") })?.data else { continue }
            let bol = try BOL.parse(bolData)
            guard let last = KMPCameraSequence.chain(in: bol).last, let start = bol.ktpt.first?.position else { continue }
            let c = bol.came[last], s = (c.viewPositionStart - start).length, e = (c.viewPositionEnd - start).length
            intros += 1
            if c.type == 4 ? s < e : e < s { introOK += 1 }
        }
        check(intros == 16 && introOK == intros, "retail intros end on the karts: \(introOK)/\(intros) (look-at start/end the right way round)")

        // Texture animations port to Wii: every retail course/sky BTK becomes an SRT0 (course, course2,
        // course3, vrcorn) whose materials all exist in the Wii model and move texture slot 0.
        var animCourses = 0, animOK = 0
        for slot in MKDDSlots.slots where !slot.battle {
            let data = try disc.readFile(node: nodes[slot.archives[0].name]!)
            let (root, _) = try SZS.open(data)
            let btks = root.children.filter { $0.name.hasSuffix("_course.btk") || $0.name.hasSuffix("_course_02.btk") || $0.name.hasSuffix("_course_03.btk") || $0.name.hasSuffix("_sky.btk") }
            guard !btks.isEmpty else { continue }
            animCourses += 1
            let (wii, _) = try SZS.open(try MKDDPort.port(data, name: slot.archives[0].name).archive)
            var ok = true, srts = 0
            for file in ["course_model.brres", "vrcorn_model.brres"] {
                let brres = try BRRESDocument.parse(wii.children.first { $0.name == file }!.data!)
                let mdl0 = MDL0Parser.parse(brres.resources.first { $0.magic == "MDL0" }!, rawFile: brres.rawData)!
                let names = Set(mdl0.meshes.compactMap(\.materialName))
                for r in brres.resources where r.magic == "SRT0" {
                    srts += 1
                    guard let srt = SRT0Document.parse(r, rawFile: brres.rawData) else { ok = false; continue }
                    if !srt.materials.allSatisfy({ names.contains($0.name) && $0.matrices.allSatisfy { $0.slotIndex == 0 } }) { ok = false; print("  \(slot.archives[0].name) \(r.name): \(srt.materials.map(\.name).filter { !names.contains($0) })") }
                }
            }
            if ok && srts > 0 { animOK += 1 } else { print("  \(slot.archives[0].name): \(srts) SRT0s from \(btks.map(\.name))") }
        }
        check(animCourses > 0 && animOK == animCourses, "texture animations port to Wii SRT0s on real materials: \(animOK)/\(animCourses) courses")

        // Double Dash Check Laps / Make Testable: every retail course and stage checks clean and
        // Make Testable changes nothing; a course stripped of its start, respawns and checkpoints (retail needs no respawns)
        // comes back with nothing left for Check Laps to report.
        var clean = 0, untouched = 0, total = 0
        for slot in MKDDSlots.slots {
            let name = slot.archives[0].name
            let (root, _) = try SZS.open(try disc.readFile(node: nodes[name]!))
            guard let bolData = root.children.first(where: { $0.name.hasSuffix("_course.bol") })?.data else { continue }
            total += 1
            let doc = try BOL.parse(bolData)
            let problems = BOL.problems(doc)
            if problems.isEmpty { clean += 1 } else { print("     \(name): \(problems.prefix(2))") }
            let before = BOL.serialize(doc, source: doc.bolSource!)
            let fixes = BOL.makeTestable(doc)
            if fixes.isEmpty && BOL.serialize(doc, source: doc.bolSource!) == before { untouched += 1 } else { print("     \(name) Make Testable changed: \(fixes.prefix(2))") }
        }
        check(clean == total, "Check Laps: \(clean)/\(total) retail courses and stages clean")
        check(untouched == total, "Make Testable leaves \(untouched)/\(total) retail courses unchanged")
        let (luigiRoot, _) = try SZS.open(try disc.readFile(node: nodes["Luigi.arc"]!))
        let stripped = try BOL.parse(luigiRoot.children.first { $0.name.hasSuffix("_course.bol") }!.data!)
        stripped.ktpt = []; stripped.jgpt = []; stripped.ckpt = []; stripped.ckph = []
        let fixes = BOL.makeTestable(stripped)
        let left = BOL.problems(try BOL.parse(BOL.serialize(stripped, source: stripped.bolSource!)))
        check(fixes.count == 2 && left.isEmpty, "stripped Luigi Circuit (start + checkpoint): \(fixes.count) fixes, then Check Laps clean \(left)")
        check(BOL.problems(BOL.battleTemplate()).isEmpty && BOL.battleTemplate().ktpt.map(\.playerIndex).sorted() == Array(0...7), "new battle stage: 8 starts for players 0-7, Check Laps clean")

        // Hot Swap suggestions and Track Budget references hold for every retail course.
        var noSuggestions = 0
        var budget: [TrackBudget.Metric: [Int]] = [:]
        for slot in MKDDSlots.slots {
            let (root, _) = try SZS.open(try disc.readFile(node: nodes[slot.archives[0].name]!))
            let bol = try BOL.parse(root.children.first { $0.name.hasSuffix("_course.bol") }!.data!)
            let s = HotSwapPreflight.doubleDashSuggestions(bol)
            if s.isEmpty { noSuggestions += 1 } else { print("     \(slot.archive): \(s.map(\.0))") }
            for (k, v) in TrackBudget.j3dMetrics(root.children.first { $0.name.hasSuffix("_course.bmd") }!.data!)! { budget[k, default: []].append(v) }
        }
        check(noSuggestions == MKDDSlots.slots.count, "Hot Swap suggestions: none for \(noSuggestions)/\(MKDDSlots.slots.count) retail courses")
        let budgetOK = TrackBudget.Metric.allCases.allSatisfy { m in
            let v = budget[m]!.sorted(); let r = TrackBudget.reference(.course, m, game: .doubleDash)
            return r.median == v[v.count / 2] && r.max == v.last!
        }
        check(budgetOK, "Track Budget: Double Dash course references are the retail median and max")

        // Missing object files: no retail course lacks any file its own objects need, and Luigi
        // Circuit with its objects folder emptied gets its chain chomp and trees back.
        let objectIndex = try MKDDObjectFiles.index(disc)
        var noFalse = 0
        for slot in MKDDSlots.slots {
            let (root, _) = try SZS.open(try disc.readFile(node: nodes[slot.archives[0].name]!))
            let bol = try BOL.parse(root.children.first { $0.name.hasSuffix("_course.bol") }!.data!)
            let present = Set((root.children.first { $0.name == "objects" }?.children ?? []).map { $0.name.lowercased() })
            if MKDDObjectFiles.missing(for: Set(bol.gobj.map(\.objectID)), present: present, index: objectIndex).isEmpty { noFalse += 1 } else { print("     \(slot.archive) reports files missing it has") }
        }
        check(noFalse == MKDDSlots.slots.count, "object files: \(noFalse)/\(MKDDSlots.slots.count) retail courses complete")
        let luigiBOL = try BOL.parse(luigiRoot.children.first { $0.name.hasSuffix("_course.bol") }!.data!)
        let restored = MKDDObjectFiles.missing(for: Set(luigiBOL.gobj.map(\.objectID)), present: [], index: objectIndex).map { $0.path[1] }
        check(["wanwan1.bmd", "mariotree1.bmd", "skyship1.bmd"].allSatisfy(restored.contains), "emptied Luigi Circuit gets its objects back: \(restored.prefix(6))")

        // Scale Track: every retail course at 2x and 0.5x, model triangles, collision and course
        // data all scale about the origin, together.
        var scaledOK = 0, scaleTotal = 0
        for slot in MKDDSlots.slots {
            for factor: Float in [2, 0.5] {
                let (root, _) = try SZS.open(try disc.readFile(node: nodes[slot.archives[0].name]!))
                func file(_ suffix: String) -> Data { root.children.first { $0.name.hasSuffix(suffix) }!.data! }
                let model0 = try J3DModel.parse(file("_course.bmd")), bco0 = try BCO.parse(file("_course.bco")), bol0 = try BOL.parse(file("_course.bol"))
                scaleTotal += 1
                do { _ = try TrackScaler.scale(archive: root, by: factor, objects: true) } catch { print("     \(slot.archive) x\(factor): \(error.localizedDescription)"); continue }
                let model1 = try J3DModel.parse(file("_course.bmd")), bco1 = try BCO.parse(file("_course.bco")), bol1 = try BOL.parse(file("_course.bol"))
                func close(_ a: Vec3, _ b: Vec3) -> Bool { (a * factor - b).length <= max(2, a.length * factor * 0.002) }
                let modelOK = model0.triangles.count == model1.triangles.count && zip(model0.triangles, model1.triangles).allSatisfy { close($0.v.0.position, $1.v.0.position) }
                // The writer orders triangles by height, so compare them sorted.
                func centres(_ d: KCLDocument, _ k: Float) -> [Vec3] { d.triangles.map { ($0.v0 + $0.v1 + $0.v2) * (k / 3) }.sorted { ($0.x, $0.y, $0.z) < ($1.x, $1.y, $1.z) } }
                let bcoOK = bco0.triangles.count == bco1.triangles.count && zip(centres(bco0, factor), centres(bco1, 1)).allSatisfy { ($0 - $1).length <= max(2, $0.length * 0.002) }
                let bolOK = zip(bol0.enpt, bol1.enpt).allSatisfy { close($0.position, $1.position) } && zip(bol0.ktpt, bol1.ktpt).allSatisfy { close($0.position, $1.position) }
                if modelOK && bcoOK && bolOK { scaledOK += 1 } else { print("     \(slot.archive) x\(factor): model \(modelOK) bco \(bcoOK) bol \(bolOK)") }
            }
        }
        check(scaledOK == scaleTotal, "Scale Track: \(scaledOK)/\(scaleTotal) retail course scalings line up")

        // Create Shadow Map: every retail course model loads, bakes and writes back readable; and
        // on a flat ground grid with a tower, the ground behind the tower (from the sun) darkens
        // while the open ground stays as it was.
        var shadowOK = 0
        var quick = ShadowMap.Options(); quick.samples = 2
        for slot in MKDDSlots.slots {
            let (root, _) = try SZS.open(try disc.readFile(node: nodes[slot.archives[0].name]!))
            let bmd = root.children.first { $0.name.hasSuffix("_course.bmd") }!.data!
            if let m = try? MKDDShadow.load(bmd), let out = try? MKDDShadow.write(MKDDShadow.bake(m, options: quick, shadowColor: (0x4C, 0x4C, 0x56))),
               let back = try? J3DModel.parse(out), let plain = try? J3DModel.parse(MKDDShadow.write(m)),
               back.triangles.count == plain.triangles.count,
               // Only zero-area triangles may go (the writer drops them).
               back.triangles.count >= m.triangles.filter({ Vec3.cross($0.v.1.position - $0.v.0.position, $0.v.2.position - $0.v.0.position).length >= 1e-6 }).count - 2 { shadowOK += 1 } else { print("     \(slot.archive): shadow round trip failed") }
        }
        check(shadowOK == MKDDSlots.slots.count, "Create Shadow Map: \(shadowOK)/\(MKDDSlots.slots.count) retail course models bake and read back")
        var grid = MKDDTrackBuilder.Model()
        grid.materials = [J3DWriter.Material(name: "g", texture: nil)]
        func quadTris(_ a: Vec3, _ b: Vec3, _ c: Vec3, _ d: Vec3) {
            func v(_ p: Vec3) -> J3DWriter.Vertex { J3DWriter.Vertex(position: p, color: [200, 200, 200, 255], uv: Vec2()) }
            grid.triangles += [J3DWriter.Triangle(v: (v(a), v(b), v(c)), material: 0), J3DWriter.Triangle(v: (v(a), v(c), v(d)), material: 0)]
        }
        for gx in -10..<10 { for gz in -10..<10 {
            let x = Float(gx) * 200, z = Float(gz) * 200
            quadTris(Vec3(x: x, y: 0, z: z), Vec3(x: x, y: 0, z: z + 200), Vec3(x: x + 200, y: 0, z: z + 200), Vec3(x: x + 200, y: 0, z: z))
        } }
        let (s0, h) = (Float(150), Float(1200))
        for (a, b) in [((-s0, -s0), (s0, -s0)), ((s0, -s0), (s0, s0)), ((s0, s0), (-s0, s0)), ((-s0, s0), (-s0, -s0))] {
            quadTris(Vec3(x: a.0, y: 0, z: a.1), Vec3(x: a.0, y: h, z: a.1), Vec3(x: b.0, y: h, z: b.1), Vec3(x: b.0, y: 0, z: b.1))
        }
        quadTris(Vec3(x: -s0, y: h, z: -s0), Vec3(x: -s0, y: h, z: s0), Vec3(x: s0, y: h, z: s0), Vec3(x: s0, y: h, z: -s0))
        var sunX = ShadowMap.Options(); sunX.azimuth = 0; sunX.elevation = 45; sunX.softness = 0; sunX.shadeSlopes = false
        let bakedGrid = MKDDShadow.bake(grid, options: sunX, shadowColor: (0, 0, 0))
        func shadeAt(_ x: Float, _ z: Float) -> Int {
            bakedGrid.triangles.first { $0.v.0.position.y == 0 && $0.v.1.position.y == 0 && abs($0.v.0.position.x - x) < 1 && abs($0.v.0.position.z - z) < 1 }.map { Int($0.v.0.color[0]) } ?? -1
        }
        // Sun from +X at 45 degrees: a 1200-tall tower shadows x in -150...-1350.
        check(shadeAt(-800, 0) < 40 && shadeAt(800, 0) == 200 && shadeAt(-800, 1200) == 200,
              "baked tower shadow: behind \(shadeAt(-800, 0)), in front \(shadeAt(800, 0)), beside \(shadeAt(-800, 1200))")

        // A generated course: ring road (radius 6000-8000) inside a grass disc.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mkddcheck-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let img = NSImage(size: NSSize(width: 64, height: 64)); img.lockFocus()
        NSColor.darkGray.setFill(); NSRect(x: 0, y: 0, width: 64, height: 64).fill(); NSColor.white.setFill(); NSRect(x: 30, y: 0, width: 4, height: 64).fill()
        img.unlockFocus()
        try NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("asphalt.png"))
        try "newmtl road_asphalt\nmap_Kd asphalt.png\nnewmtl grass\nKd 0.2 0.7 0.2\n".write(to: dir.appendingPathComponent("track.mtl"), atomically: true, encoding: .utf8)
        var obj = "mtllib track.mtl\n", v = 0
        let seg = 48
        func ring(_ r0: Float, _ r1: Float, _ mat: String) {
            obj += "usemtl \(mat)\n"
            for i in 0..<seg {
                let a0 = Float(i) / Float(seg) * 2 * .pi, a1 = Float(i + 1) / Float(seg) * 2 * .pi
                for (r, a) in [(r0, a0), (r1, a0), (r1, a1), (r0, a1)] { obj += "v \(r * cos(a)) 0 \(r * sin(a))\n" }
                obj += "vt 0 \(Float(i)) \nvt 1 \(Float(i))\nvt 1 \(Float(i + 1))\nvt 0 \(Float(i + 1))\n"
                obj += "f \(v + 1)/\(v + 1) \(v + 2)/\(v + 2) \(v + 3)/\(v + 3) \(v + 4)/\(v + 4)\n"
                v += 4
            }
        }
        ring(6000, 8000, "road_asphalt"); ring(3000, 6000, "grass"); ring(8000, 11000, "grass")
        try obj.write(to: dir.appendingPathComponent("track.obj"), atomically: true, encoding: .utf8)

        let slot = MKDDSlots.slots.first { $0.archive == "Luigi2" }!
        let dol = try MKDDSlots.dol(fromDisc: url)
        let rect = MKDDSlots.minimap(for: slot, dol: dol, region: MKDDSlots.region(gameID: disc.gameID)!)
        // A battle stage from the same model: 8 starts on the floor, ready for the battle verifier.
        let arena = MKDDSlots.slots.first { $0.battle }!
        let battleOut = try MKDDTrackBuilder.newCourse(slot: arena, courseModel: dir.appendingPathComponent("track.obj"), skyModel: nil, scale: 1, minimap: nil, musicID: arena.musicID)
        let (arenaRoot, _) = try SZS.open(battleOut.archives[0].data)
        let arenaBOL = try BOL.parse(arenaRoot.children.first { $0.name.hasSuffix("_course.bol") }!.data!)
        check(arenaBOL.ktpt.count == 8 && arenaBOL.ktpt.allSatisfy { abs($0.position.y - 10) < 0.01 } && BOL.problems(arenaBOL).isEmpty
              && ModVerifier.verify(.mkddCourse, root: arenaRoot).passed,
              "new \(arena.title) battle stage: 8 grounded starts, Check Laps clean, verifier passes")
        let out = try MKDDTrackBuilder.newCourse(slot: slot, courseModel: dir.appendingPathComponent("track.obj"), skyModel: nil, scale: 1, minimap: rect, musicID: 0x24)
        out.report.forEach { print("     \($0)") }
        check(out.archives.map(\.name) == ["Luigi2.arc"], "archives \(out.archives.map(\.name)) (one; Hot Swap installs it over the others)")
        for a in slot.archives {
            let (r, _) = try SZS.open(try HotSwapTargets.renamedCourse(out.archives[0].data, root: a.root, stem: slot.fileStem))
            check(r.name == a.root && r.children.allSatisfy { $0.name.hasPrefix("luigi_") }, "Hot Swap installs it as \(a.name) rooted \(r.name)")
        }
        for (name, data) in out.archives {
            let (root, compressed) = try SZS.open(data)
            check(root.isRARC && !compressed && root.name == ["Luigi2.arc": "luigi2", "Luigi2L.arc": "luigi2l", "Luigi.arc": "luigi", "LuigiL.arc": "luigil"][name], "\(name): uncompressed RARC rooted \(root.name)")
            let names = Set(root.children.map(\.name))
            check(names == ["luigi_course.bmd", "luigi_course.bco", "luigi_course.bol", "luigi_map.bti"], "\(name): files \(names.sorted())")
            let model = try J3DModel.parse(root.children.first { $0.name == "luigi_course.bmd" }!.data!)
            check(model.triangles.count == seg * 3 * 2 && model.textures.count == 1, "\(name): model \(model.triangles.count) triangles, \(model.textures.count) texture")
            let bco = try BCO.parse(root.children.first { $0.name == "luigi_course.bco" }!.data!)
            let road = bco.triangles.filter { $0.attribute == 0x0100 }.count, grass = bco.triangles.filter { $0.attribute == 0x0300 }.count
            check(bco.triangles.count == seg * 6 && road == seg * 2 && grass == seg * 4, "\(name): collision \(bco.triangles.count) triangles, road \(road), grass \(grass)")
            let bol = try BOL.parse(root.children.first { $0.name == "luigi_course.bol" }!.data!)
            let start = bol.ktpt.first?.position
            let r = start.map { ($0.x * $0.x + $0.z * $0.z).squareRoot() } ?? 0
            check(bol.ktpt.count == 1 && r >= 6000 && r <= 8000, "\(name): start point on the road (r = \(Int(r)))")
            check(bol.came.first?.startFlag == 1 && bol.came.last?.type == 8 && bol.came.last?.bol == MKWiiToMKDD.paradeCameraRecord, "\(name): intro camera first, retail parade camera last")
            let map = root.children.first { $0.name == "luigi_map.bti" }!.data!
            let pixels = TextureCodec.decode(data: map, offset: Int(map.be32(0x1C)), width: Int(map.be16(2)), height: Int(map.be16(4)), format: .ia4)
            check(pixels.map { p in stride(from: 3, to: p.count, by: 4).filter { p[$0] > 0 }.count > 500 } ?? false, "\(name): minimap has the road drawn")
            let v = ModVerifier.verify(.mkddCourse, root: root)
            let missing = v.checks.filter { $0.required && !$0.passed }.map(\.label)
            check(Set(missing) == ["Enemy route", "Checkpoints"], "\(name): only the course data's route/checkpoints are left to fill in (\(missing))")

            // Fill in a route and a checkpoint loop the way the course-data editor would, save, re-verify.
            for k in 0..<8 {
                let a = Float(k) / 8 * 2 * .pi
                bol.enpt.append(ENPTEntry(position: Vec3(x: 7000 * cos(a), y: 0, z: 7000 * sin(a)), radius: 800))
                bol.ckpt.append(CKPTEntry(left: Vec2(x: 6000 * cos(a), y: 6000 * sin(a)), right: Vec2(x: 8000 * cos(a), y: 8000 * sin(a)), respawnIndex: 0, lapCounterType: k == 0 ? 0 : -1))
            }
            bol.enph = [PathLinkEntry(startIndex: 0, pointCount: 8, previousGroups: [0, 255, 255, 255, 255, 255], nextGroups: [0, 255, 255, 255, 255, 255])]
            bol.ckph = [PathLinkEntry(startIndex: 0, pointCount: 8, previousGroups: [0, 255, 255, 255, 255, 255], nextGroups: [0, 255, 255, 255, 255, 255])]
            bol.jgpt = [JGPTEntry(position: start ?? Vec3())]
            root.children.first { $0.name == "luigi_course.bol" }!.data = BOL.serialize(bol, source: bol.bolSource!)
            let v2 = ModVerifier.verify(.mkddCourse, root: root)
            check(v2.passed, "\(name): with a route and checkpoints it passes the verifier \(failed(v2))")
            if name == "Luigi2.arc" {
                let wii = try? MKDDPort.port(RARC.serialize(root), name: name)
                check(wii != nil, "the Double Dash -> Wii port accepts the built course")
            }
        }
        if failures > 0 { exit(1) }
    }
}
