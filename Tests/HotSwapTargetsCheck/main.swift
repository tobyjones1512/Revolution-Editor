// Hot Swap target check, against the retail Mario Kart Wii and Double Dash discs:
// - every Mario Kart Wii target names files that exist on the disc (tracks and arenas with their
//   _d copies, every vehicle/character pairing with its _2/_4 copies, menu models);
// - every Double Dash course target's archives exist, and every racer/kart target's files exist
//   inside MRAM.arc;
// - staging a project: a plain mark keeps its name, a track target installs both names, a Double
//   Dash course is renamed for its slot (root folder + file prefix), and racer/kart files are
//   patched into a copy of MRAM.arc;
// - the NSMBW level list (Reggie-Next) has 147 unique levels.
//
//   find "Revolution IDE/Core" -name '*.swift' ! -path '*/Workbench/*' ! -name AppState.swift \
//     ! -name SyntaxHighlighter.swift | tr '\n' '\0' | xargs -0 swiftc -O -parse-as-library -o /tmp/hotswapcheck \
//     "Revolution IDE/Core/Workbench/"{BaseGameLibrary,HotSwapTargets,GameCubeHotSwap,HotSwapAutoFix}.swift Tests/HotSwapTargetsCheck/main.swift
//   /tmp/hotswapcheck [mkwii.iso] [common-key] [mkdd.iso]

import Foundation

@main enum HotSwapTargetsCheck {
    static func main() throws {
        var failures = 0
        func check(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failures += 1 } }
        func targets(_ game: HotSwapTargets.Game) -> [HotSwapTargets.Target] {
            var out: [HotSwapTargets.Target] = []
            func walk(_ n: HotSwapTargets.Node) { switch n { case .group(_, let c): c.forEach(walk); case .target(let t): out.append(t) } }
            HotSwapTargets.menu(for: game).forEach(walk)
            return out
        }
        let args = CommandLine.arguments, roms = "\(ProcessInfo.processInfo.environment["ROMS_DIR"] ?? "Roms")/"
        let wii = try WiiDisc(url: URL(fileURLWithPath: args.count > 1 ? args[1] : roms + "Wii/MKWii/Mario Kart Wii (USA) (En,Fr,Es).iso"),
                              commonKey: [UInt8](try Data(contentsOf: URL(fileURLWithPath: args.count > 2 ? args[2] : roms + "Wii/Keys/common-key"))), koreanKey: nil)
        var wiiNames = Set<String>()
        func walk(_ n: DiscNode) { if n.isDirectory { n.children.forEach(walk) } else { wiiNames.insert(n.name) } }
        walk(wii.root)
        let mkw = targets(.marioKartWii)
        let missing = mkw.flatMap { t in HotSwapTargets.discFiles(t).filter { !wiiNames.contains($0) }.map { "\(t.path.joined(separator: " > ")): \($0)" } }
        check(missing.isEmpty, "Mario Kart Wii: \(Set(mkw.map(\.id)).count) targets, every file on the disc \(missing.prefix(5))")
        let groups = HotSwapTargets.menu(for: .marioKartWii).map { n -> String in if case .group(let t, _) = n { return t }; return "" }
        check(groups == ["Tracks", "Battle Maps", "Racers", "Karts"], "Mario Kart Wii menu: \(groups)")
        check(mkw.filter { $0.id.hasPrefix("mkwii.track.") }.count == 32 && mkw.filter { $0.id.hasPrefix("mkwii.battle.") }.count == 10, "32 tracks in 8 cups, 10 battle arenas")
        let luigi = HotSwapTargets.target(id: "mkwii.track.beginner_course")
        check(luigi?.path == ["Tracks", "Mushroom Cup", "Luigi Circuit"] && HotSwapTargets.discFiles(luigi!) == ["beginner_course.szs", "beginner_course_d.szs"], "Tracks > Mushroom Cup > Luigi Circuit = beginner_course.szs + _d")

        let ddURL = URL(fileURLWithPath: args.count > 3 ? args[3] : roms + "GCN/MKDD/Mario Kart - Double Dash!! (USA).iso")
        let dd = try GameCubeDisc(url: ddURL)
        var ddNodes: [String: DiscNode] = [:]
        func walkDD(_ n: DiscNode) { if n.isDirectory { n.children.forEach(walkDD) } else { ddNodes[n.name] = n } }
        walkDD(dd.root)
        let (mram, _) = try SZS.open(try dd.readFile(node: ddNodes["MRAM.arc"]!))
        func member(_ path: String) -> Bool {
            var node: U8Node? = mram
            for p in path.split(separator: "/") { node = node?.children.first { $0.name == String(p) } }
            return node.map { !$0.isDirectory } ?? false
        }
        var ddMissing: [String] = []
        let mkdd = targets(.marioKartDoubleDash)
        for t in mkdd {
            switch t.kind {
            case .mkddCourse: ddMissing += HotSwapTargets.discFiles(t).filter { ddNodes[$0] == nil }
            case .mramMembers(let m): ddMissing += m.filter { !member($0) }
            case .files(let f): ddMissing += f.filter { ddNodes[$0] == nil }
            }
        }
        check(ddMissing.isEmpty, "Double Dash: \(mkdd.count) targets, every archive/MRAM file exists \(ddMissing.prefix(5))")

        let nsmbw = targets(.nsmbw)
        check(nsmbw.count == 147 && Set(nsmbw.map(\.id)).count == 147, "NSMBW: \(nsmbw.count) levels")

        // Staging a project.
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("HotSwapCheck-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("track".utf8).write(to: project.appendingPathComponent("My Track.szs"))
        try Data("plain".utf8).write(to: project.appendingPathComponent("Common.szs"))
        try dd.readFile(node: ddNodes["Mario.arc"]!).write(to: project.appendingPathComponent("My DD Track.arc"))
        let newDriver = Data("custom driver".utf8)
        try newDriver.write(to: project.appendingPathComponent("hero.bmd"))
        HotSwapTargetMarks.set(luigi, for: "My Track.szs", project: project)
        HotSwapTargetMarks.set(HotSwapTargets.target(id: "mkdd.course.Luigi2"), for: "My DD Track.arc", project: project)
        HotSwapTargetMarks.set(HotSwapTargets.target(id: "mkdd.driver.mario"), for: "hero.bmd", project: project)
        let wiiStage = try HotSwapTargets.stage(modRoot: project, files: ["My Track.szs", "Common.szs"], baseISO: URL(fileURLWithPath: roms + "Wii/MKWii/Mario Kart Wii (USA) (En,Fr,Es).iso"))
        check(wiiStage.files == ["Common.szs", "beginner_course.szs", "beginner_course_d.szs"]
              && (try? Data(contentsOf: wiiStage.root.appendingPathComponent("beginner_course_d.szs"))) == Data("track".utf8),
              "Wii staging: \(wiiStage.files)")
        let ddStage = try HotSwapTargets.stage(modRoot: project, files: ["My DD Track.arc", "hero.bmd"], baseISO: ddURL)
        check(ddStage.files == ["Luigi.arc", "Luigi2.arc", "Luigi2L.arc", "LuigiL.arc", "MRAM.arc"], "Double Dash staging: \(ddStage.files)")
        let (renamed, _) = try SZS.open(try Data(contentsOf: ddStage.root.appendingPathComponent("Luigi2L.arc")))
        let names = renamed.children.filter { !$0.isDirectory }.map(\.name)
        check(renamed.name == "luigi2l" && names.allSatisfy { $0.hasPrefix("luigi_") } && names.contains("luigi_course.bol")
              && (try? BOL.parse(renamed.children.first { $0.name == "luigi_course.bol" }!.data!)) != nil,
              "Mario Circuit renamed for Luigi Circuit's multiplayer slot: root \(renamed.name), \(names.sorted())")
        let (patched, _) = try SZS.open(try Data(contentsOf: ddStage.root.appendingPathComponent("MRAM.arc")))
        let drv = patched.children.first { $0.name == "driver" }?.children.first { $0.name == "mario" }
        check(drv?.children.first { $0.name == "driver.bmd" }?.data == newDriver && drv?.children.first { $0.name == "driver_200.bmd" }?.data == newDriver
              && patched.children.first { $0.name == "driver" }?.children.first { $0.name == "luigi" }?.children.first { $0.name == "driver.bmd" }?.data != newDriver,
              "MRAM.arc patched: Mario's driver models replaced, Luigi's untouched")

        // A folder marked for Hot Swap is packed into an archive: retail Luigi Circuit unpacked
        // into "My Folder Track", targeted at Luigi Circuit, must stage as a .szs holding exactly
        // the same files; a Double Dash course folder packs as RARC and is renamed for its slot.
        func unpack(_ node: U8Node, to dir: URL) throws {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for c in node.children {
                if c.isDirectory { try unpack(c, to: dir.appendingPathComponent(c.name)) } else { try c.data!.write(to: dir.appendingPathComponent(c.name)) }
            }
        }
        func files(_ n: U8Node, _ prefix: String = "") -> [String: Data] {
            var out: [String: Data] = [:]
            for c in n.children { if c.isDirectory { out.merge(files(c, prefix + c.name + "/")) { a, _ in a } } else { out[prefix + c.name] = c.data } }
            return out
        }
        func find(_ n: DiscNode, _ name: String) -> DiscNode? { n.name == name ? n : n.children.lazy.compactMap { find($0, name) }.first }
        let (retailLuigi, _) = try SZS.open(try wii.readFile(node: find(wii.root, "beginner_course.szs")!))
        try unpack(retailLuigi, to: project.appendingPathComponent("My Folder Track"))
        HotSwapTargetMarks.set(luigi, for: "My Folder Track", project: project)
        let folderStage = try HotSwapTargets.stage(modRoot: project, files: ["My Folder Track"], baseISO: URL(fileURLWithPath: roms + "Wii/MKWii/Mario Kart Wii (USA) (En,Fr,Es).iso"))
        let staged = try Data(contentsOf: folderStage.root.appendingPathComponent("beginner_course.szs"))
        let (repacked, compressed) = try SZS.open(staged)
        check(folderStage.files == ["beginner_course.szs", "beginner_course_d.szs"] && compressed && files(repacked) == files(retailLuigi),
              "folder staged as Luigi Circuit: \(folderStage.files), \(files(repacked).count) of \(files(retailLuigi).count) files identical")
        HotSwapTargetMarks.set(nil, for: "My Folder Track", project: project)
        let plainFolder = try HotSwapTargets.stage(modRoot: project, files: ["My Folder Track"], baseISO: URL(fileURLWithPath: roms + "Wii/MKWii/Mario Kart Wii (USA) (En,Fr,Es).iso"))
        check(plainFolder.files == ["My Folder Track.szs"], "unmarked-target folder keeps its name: \(plainFolder.files)")
        let (ddCourse, _) = try SZS.open(try dd.readFile(node: ddNodes["Mario.arc"]!))
        try unpack(ddCourse, to: project.appendingPathComponent("My DD Folder"))
        HotSwapTargetMarks.set(HotSwapTargets.target(id: "mkdd.course.Luigi2"), for: "My DD Folder", project: project)
        let ddFolder = try HotSwapTargets.stage(modRoot: project, files: ["My DD Folder"], baseISO: ddURL)
        let (ddPacked, _) = try SZS.open(try Data(contentsOf: ddFolder.root.appendingPathComponent("Luigi2.arc")))
        check(ddPacked.isRARC && ddPacked.children.contains { $0.name == "luigi_course.bol" }, "Double Dash folder packed as RARC and renamed: \(ddPacked.children.map(\.name).sorted().prefix(4))")
        // Preflight: retail tracks and arenas, marked onto their own slots, raise no errors except
        // the two retail quirks the (deliberately strict) rules flag: DS Peach Gardens' enemy
        // group 4 has no back-links, GBA Bowser Castle 3's camera 21 is on route 251. An arena on
        // a race slot, an unmarked oddly named track and a GameCube base disc are each caught.
        var noisy: [String] = [], suggested: [String: Int] = [:]
        for t in mkw where t.id.hasPrefix("mkwii.track.") || t.id.hasPrefix("mkwii.battle.") {
            let file = HotSwapTargets.discFiles(t)[0]
            try wii.readFile(node: find(wii.root, file)!).write(to: project.appendingPathComponent(file))
            HotSwapTargetMarks.set(t, for: file, project: project)
            let found = HotSwapPreflight.check(modRoot: project, files: [file], gameID: "RMCE01")
            noisy += found.filter { $0.level == .error }.map { "\(file): \($0.title)" }
            for f in found where f.level == .suggestion { suggested[f.title, default: 0] += 1 }
            if file == "beginner_course.szs" || file == "block_battle.szs" { continue }
            try FileManager.default.removeItem(at: project.appendingPathComponent(file))
        }
        check(noisy.sorted() == ["old_garden_ds.szs: Enemy paths (ENPH)", "old_koopa_gba.szs: Route references (POTI)"], "preflight: only the two known retail quirks are errors \(noisy)")
        print("     retail suggestions: \(suggested)")
        HotSwapTargetMarks.set(luigi, for: "block_battle.szs", project: project)
        let wrongSlot = HotSwapPreflight.check(modRoot: project, files: ["block_battle.szs"], gameID: "RMCE01")
        check(wrongSlot.contains { $0.level == .error && $0.title == "Battle arena on a race track" }, "preflight: arena on a race slot is an error")
        HotSwapTargetMarks.set(nil, for: "block_battle.szs", project: project)
        try FileManager.default.moveItem(at: project.appendingPathComponent("block_battle.szs"), to: project.appendingPathComponent("My Arena.szs"))
        check(HotSwapPreflight.check(modRoot: project, files: ["My Arena.szs"], gameID: "RMCE01").contains { $0.title == "Replaces nothing" }, "preflight: unmarked track with no disc name warns")
        check(HotSwapPreflight.check(modRoot: project, files: ["beginner_course.szs"], gameID: "GM4E01").contains { $0.title == "Wrong base disc" }, "preflight: wrong base disc is an error")
        // Auto Correct: retail Luigi Circuit broken in fixable ways (no item box model, model
        // misnamed, item paths unlinked, a fake object, a route link to nowhere; a bad intro camera
        // and respawn IDs too, which the KMP writer already corrects on save) reports each as an
        // error with a fix, and after the fixes it checks clean.
        let keyPath = args.count > 2 ? args[2] : roms + "Wii/Keys/common-key"
        let keys = (common: Optional([UInt8](try Data(contentsOf: URL(fileURLWithPath: keyPath)))), korean: [UInt8]?.none)
        BaseGameLibrary.link(URL(fileURLWithPath: args.count > 1 ? args[1] : roms + "Wii/MKWii/Mario Kart Wii (USA) (En,Fr,Es).iso"))
        let (broken, _) = try SZS.open(try wii.readFile(node: find(wii.root, "beginner_course.szs")!))
        broken.children.removeAll { $0.name == "itembox.brres" }
        let cm = broken.children.first { $0.name == "course_model.brres" }!
        let cmDoc = try BRRESDocument.parse(cm.data!)
        cmDoc.resources.first { $0.magic == "MDL0" }!.name = "track"
        cm.data = cmDoc.serialize()
        let kmpNode = broken.children.first { $0.name == "course.kmp" }!
        let kmp = try KMPDocument.parse(kmpNode.data!)
        kmp.openingCameraIndex = 200
        for k in kmp.jgpt.indices { kmp.jgpt[k].respawnID = 7 }
        for g in kmp.itph.indices { kmp.itph[g].previousGroups = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF] }
        kmp.gobj.append(GOBJEntry(objectID: 0x7FF0))
        kmp.gobj[0].routeID = 99
        kmpNode.data = kmp.serialize()
        try SZS.save(root: broken, compressed: true).write(to: project.appendingPathComponent("Broken.szs"))
        HotSwapTargetMarks.set(luigi, for: "Broken.szs", project: project)
        let before = HotSwapPreflight.check(modRoot: project, files: ["Broken.szs"], gameID: "RMCE01").filter { $0.level == .error }
        print("     errors before: \(before.map { "\($0.title)\($0.fix == nil ? "" : " [fix]")" })")
        check(before.count == 5 && before.allSatisfy { $0.fix != nil && !$0.howTo.isEmpty }, "Auto Correct: \(before.count) errors, every one with a fix and how-to")
        let said = try HotSwapPreflight.applyFixes(before.compactMap(\.fix), to: "Broken.szs", modRoot: project, keys: keys)
        let after = HotSwapPreflight.check(modRoot: project, files: ["Broken.szs"], gameID: "RMCE01").filter { $0.level == .error }
        check(after.isEmpty, "Auto Correct: no errors left after \(said.count) fixes \(after.map(\.title))")
        try? FileManager.default.removeItem(at: project)
        if failures > 0 { exit(1) }
    }
}
