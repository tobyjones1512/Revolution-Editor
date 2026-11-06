import Foundation

/// Checks whether an opened `.szs`/`.arc` archive has what a specific kind of mod needs to
/// actually load in-game, not just "does this file exist" but "does it parse with this app's
/// own real format readers," which also catches a present-but-corrupt/truncated file. Deliberately
/// scoped to the mod types this app's own editors already understand well (Mario Kart Wii course,
/// NSMBW level) rather than every entry in `SZSInfoPopoverView`'s informational catalog, most of
/// which this app can't itself parse to verify.
nonisolated enum ModVerifier {
    struct Check: Identifiable {
        let id = UUID()
        let label: String
        let required: Bool
        let passed: Bool
        let detail: String
    }

    struct Result {
        let modName: String
        let checks: [Check]
        var passed: Bool { checks.allSatisfy { $0.passed || !$0.required } }
    }

    enum ModType: String, CaseIterable, Identifiable {
        case mkwiiCourse = "Mario Kart Wii: Custom Track"
        case mkwiiBattle = "Mario Kart Wii: Custom Battle Arena"
        case mkddCourse = "Mario Kart: Double Dash!!: Custom Course"
        case nsmbwLevel = "New Super Mario Bros. Wii: Custom Level"
        var id: String { rawValue }
    }

    static func verify(_ type: ModType, root: U8Node) -> Result {
        switch type {
        case .mkwiiCourse: return verifyMKWiiCourse(root)
        case .mkwiiBattle: return verifyMKWiiCourse(root, battle: true)
        case .mkddCourse: return verifyMKDDCourse(root)
        case .nsmbwLevel: return verifyNSMBWLevel(root)
        }
    }

    /// Every model file a course needs, and the name the game insists the MDL0 inside it has --
    /// Mario Kart Wii looks models up by that name, not by filename, so a mismatch is a crash even
    /// though the file is present and perfectly valid.
    private static let requiredModels: [(file: String, modelName: String, label: String)] = [
        ("course_model.brres", "course", "3D model (course_model.brres)"),
        ("vrcorn_model.brres", "vrcorn", "Background model (vrcorn_model.brres)"),
        ("map_model.brres", "map", "Minimap model (map_model.brres)"),
    ]

    private static func verifyMKWiiCourse(_ root: U8Node, battle: Bool = false) -> Result {
        var checks = [
            requireAndParse(root, name: "course.kcl", label: "Collision (course.kcl)") { try KCLDocument.parse($0) },
            requireAndParse(root, name: "course.kmp", label: "Course map (course.kmp)") { try KMPDocument.parse($0) },
        ]
        // All three of these are load-bearing: the game crashes on a course archive missing any of
        // them, background and minimap included (they are not decoration it can skip).
        for model in requiredModels {
            checks.append(requireAndParse(root, name: model.file, label: model.label) { data in
                let doc = try BRRESDocument.parse(data)
                guard doc.resources.contains(where: { $0.folderName.hasPrefix("3DModels") && $0.name == model.modelName }) else {
                    throw WSError.badStructure("no model named \"\(model.modelName)\" inside it, the game looks it up by that exact name, so rename the MDL0")
                }
                return doc
            })
        }
        // Every retail track and arena bundles the item box model (44 of 44; only the demo and
        // test courses don't), whether or not it places item boxes.
        checks.append(requireAndParse(root, name: "itembox.brres", label: "Item box model (itembox.brres)") { try BRRESDocument.parse($0) })
        checks.append(contentsOf: kmpChecks(root, battle: battle))
        checks.append(contentsOf: cannonChecks(root))
        if battle, let data = root.children.first(where: { !$0.isDirectory && $0.name == "course.kmp" })?.data,
           let doc = try? KMPDocument.parse(data) {
            checks.append(contentsOf: BattleArena.checks(doc))
        }
        return Result(modName: (battle ? ModType.mkwiiBattle : ModType.mkwiiCourse).rawValue, checks: checks)
    }

    /// Per the wiki's "Cannon mismatch" crash cause: a KCL "Cannon Trigger" face (base type 17)
    /// carries the cannon's ID in its variant bits (5-7), and that ID has to have a matching CNPT
    /// entry in the KMP for the game to know where/how far to launch the player, a trigger with
    /// no matching point, or a CNPT nothing in the collision ever triggers, are both silent crashes.
    private static func cannonChecks(_ root: U8Node) -> [Check] {
        guard let kclData = root.children.first(where: { !$0.isDirectory && $0.name == "course.kcl" })?.data,
              let kclDoc = try? KCLDocument.parse(kclData),
              let kmpData = root.children.first(where: { !$0.isDirectory && $0.name == "course.kmp" })?.data,
              let kmpDoc = try? KMPDocument.parse(kmpData) else { return [] }
        let kclCannonIDs = Set(kclDoc.triangles.compactMap { t -> Int? in
            guard (t.attribute & 0x1F) == 17 else { return nil }
            return Int((t.attribute >> 5) & 0x7)
        })
        let kmpCannonIDs = Set(kmpDoc.cnpt.map { Int($0.cannonID) })
        guard !kclCannonIDs.isEmpty || !kmpCannonIDs.isEmpty else { return [] }
        let missingInKMP = kclCannonIDs.subtracting(kmpCannonIDs)
        let missingInKCL = kmpCannonIDs.subtracting(kclCannonIDs)
        // Only a trigger with no point is a problem: retail ships unused points (Rainbow Road has
        // three, its collision fires only #2; N64 DK's Jungle Parkway uses one of two).
        let ok = missingInKMP.isEmpty
        var detail = "\(kclCannonIDs.count) cannon trigger(s) in the collision, \(kmpDoc.cnpt.count) cannon point(s) in the KMP, every trigger matched."
        if !ok {
            detail = "Collision has cannon trigger(s) \(missingInKMP.sorted()) with no matching Cannon Point (CNPT) in the KMP."
        }
        if !missingInKCL.isEmpty {
            detail += " Cannon Point(s) \(missingInKCL.sorted()) aren't fired by any trigger (harmless, retail tracks have unused ones too)."
        }
        return [Check(label: "Cannon trigger/point match", required: true, passed: ok, detail: detail)]
    }

    /// Settings inside a valid-but-wrong `course.kmp` that stop a track working: an opening camera
    /// index pointing past the end of the camera list (the intro reads off the end of the array),
    /// and a speed factor that isn't either "unset" or a sensible multiplier.
    private static func kmpChecks(_ root: U8Node, battle: Bool = false) -> [Check] {
        guard let data = root.children.first(where: { !$0.isDirectory && $0.name == "course.kmp" })?.data,
              let doc = try? KMPDocument.parse(data) else { return [] }
        var checks: [Check] = []
        let cameraOK = doc.came.isEmpty || Int(doc.openingCameraIndex) < doc.came.count
        checks.append(Check(label: "Opening camera", required: true, passed: cameraOK,
                            detail: cameraOK
                                ? (doc.came.isEmpty ? "No cameras defined." : "Points at camera \(doc.openingCameraIndex) of \(doc.came.count).")
                                : "The opening pan is set to camera \(doc.openingCameraIndex) but there are only \(doc.came.count). Set it to a real camera."))
        let speed = Float(bitPattern: UInt32(doc.stgi.speedFactor) << 16)
        let speedOK = doc.stgi.speedFactor == 0 || (speed >= 0.1 && speed <= 10)
        checks.append(Check(label: "Speed factor", required: true, passed: speedOK,
                            detail: speedOK
                                ? (doc.stgi.speedFactor == 0 ? "Unset (normal speed)." : "\(speed)x.")
                                : "Stage info's speed factor decodes to \(speed)x. It is the top half of a float, so use 0 for normal speed or 0x3F80 for 1.0."))
        let flare = doc.stgi.flareColor
        checks.append(Check(label: "Lens flare colour", required: false, passed: flare.0 == 0,
                            detail: flare.0 == 0 ? "Stored like every retail track."
                                : "The flare colour's first byte is \(flare.0), but it's 0 on every retail track (the colour is stored A,R,G,B; opacity is the separate transparency value). Set the colour again in Stage Info to fix it."))
        if doc.stgi.speedFactor != 0 {
            checks.append(Check(label: "Speed modifier", required: false, passed: false,
                                detail: "Every retail track uses normal speed. The speed modifier is believed to need CTGP / LE-CODE, on an unmodified game, test with it at 1 if anything goes wrong."))
        }
        let hasStart = !doc.ktpt.isEmpty
        if !battle { // a battle arena's per-player starts are checked by `BattleArena.checks`
            checks.append(Check(label: "Start position (KTPT)", required: true, passed: hasStart,
                                detail: hasStart ? "\(doc.ktpt.count) start point(s)." : "No start point, racers have nowhere to spawn."))
        }
        // Every retail course numbers its respawn points 0, 1, 2... and checkpoints find them by
        // that number, so a point whose ID isn't its index is one a respawn can't find.
        let badRespawnIDs = doc.jgpt.indices.filter { Int(doc.jgpt[$0].respawnID) != $0 }
        checks.append(Check(label: "Respawn IDs (JGPT)", required: true, passed: badRespawnIDs.isEmpty,
                            detail: badRespawnIDs.isEmpty
                                ? "Every respawn point's ID matches its position."
                                : "Respawn point(s) \(badRespawnIDs.map(String.init).joined(separator: ", ")) have ID \(badRespawnIDs.map { String(doc.jgpt[$0].respawnID) }.joined(separator: ", ")), a Lakitu respawn at a checkpoint using them finds no point. Open and save course.kmp in the KMP editor to renumber them."))
        let badRespawnRefs = doc.ckpt.indices.filter { !doc.jgpt.indices.contains(Int(doc.ckpt[$0].respawnIndex)) }
        if !badRespawnRefs.isEmpty {
            checks.append(Check(label: "Checkpoint respawn points", required: true, passed: false,
                                detail: "Checkpoint(s) \(badRespawnRefs.map(String.init).joined(separator: ", ")) use a respawn point that doesn't exist."))
        }
        if !doc.ckpt.isEmpty {
            let laps = CheckpointVerifier.verify(doc)
            let errors = laps.issues.filter { $0.severity == .error }
            checks.append(Check(label: "Checkpoints & laps", required: true, passed: errors.isEmpty,
                                detail: errors.isEmpty
                                    ? (laps.loopsDriven > 0 ? "Drove the CPU route \(laps.loopsDriven) lap(s): every lap counted." : "Checkpoint layout is valid.")
                                    : errors.map(\.message).joined(separator: " ") + " (Open course.kmp and use Check Laps for details.)"))
        }
        let hasRespawn = !doc.jgpt.isEmpty
        checks.append(Check(label: "Respawn points (JGPT)", required: true, passed: hasRespawn,
                            detail: hasRespawn ? "\(doc.jgpt.count) respawn point(s)." : "No respawn points, falling off the track has nowhere to return to."))
        // Path-group linking problems that stop a CPU route or lap from actually working. Each
        // group (ENPH/ITPH/CKPH) has a Start/Count over its point array, and up to 6 "previous"
        // and 6 "next" group references. Per the wiki: the "Last" and "Next" of each group "must
        // match each other", if A lists B as next, B lists A back as previous, a group whose
        // next is entirely 0xFF is a dead end, and index references in any of these fields that
        // point past the real arrays read garbage or crash mid-race, not at load.
        for (label, groups, pointCount) in [("Enemy paths (ENPH)", doc.enph, doc.enpt.count),
                                            ("Item paths (ITPH)", doc.itph, doc.itpt.count),
                                            ("Checkpoint groups (CKPH)", doc.ckph, doc.ckpt.count)] {
            guard !groups.isEmpty else { continue }
            var issues: [String] = []
            let unlinked = groups.indices.filter { groups[$0].nextGroups.allSatisfy { $0 == 0xFF } }
            if !unlinked.isEmpty { issues.append("group(s) \(unlinked.map(String.init).joined(separator: ", ")) have no \"next\" group (dead end)") }
            // A battle arena's CPU network doesn't pair its links the way a race route does --
            // no retail arena's enemy groups list each other back, so only ranges are checked.
            let racePairing = !(battle && label.hasPrefix("Enemy"))
            if !racePairing { issues.removeAll { $0.contains("no \"next\" group") } }
            // Every retail race track's item and checkpoint groups have a previous group (enemy
            // paths don't: old_garden_ds has one). An item group with none crashed a user's track
            // with a null read the moment the first item box was hit.
            if !battle, !label.hasPrefix("Enemy") {
                let orphans = groups.indices.filter { groups[$0].previousGroups.allSatisfy { $0 == 0xFF } }
                if !orphans.isEmpty { issues.append("group(s) \(orphans.map(String.init).joined(separator: ", ")) have no \"previous\" group (nothing leads into them, the game reads a null link and crashes; Make Testable removes unreachable item paths)") }
            }
            for (i, g) in groups.enumerated() {
                if Int(g.startIndex) + Int(g.pointCount) > pointCount {
                    issues.append("group \(i) claims points \(g.startIndex)...\(Int(g.startIndex) + Int(g.pointCount) - 1) but only \(pointCount) point(s) exist")
                }
                for j in g.nextGroups where j != 0xFF && Int(j) >= groups.count {
                    issues.append("group \(i) points at non-existent next group \(j)")
                }
                for j in g.previousGroups where j != 0xFF && Int(j) >= groups.count {
                    issues.append("group \(i) points at non-existent previous group \(j)")
                }
                for j in g.nextGroups where racePairing && j != 0xFF && Int(j) < groups.count && !groups[Int(j)].previousGroups.contains(UInt8(i)) {
                    issues.append("group \(i) lists group \(j) as next but \(j) doesn't list \(i) back (\"Last and Next must match\")")
                }
                for j in g.previousGroups where racePairing && j != 0xFF && Int(j) < groups.count && !groups[Int(j)].nextGroups.contains(UInt8(i)) {
                    issues.append("group \(i) lists group \(j) as previous but \(j) doesn't list \(i) back")
                }
            }
            let ok = issues.isEmpty
            checks.append(Check(label: label, required: true, passed: ok,
                                detail: ok
                                    ? "\(groups.count) group(s), all linked."
                                    : "\(issues.joined(separator: "; "))."))
        }
        // GOBJ/AREA/CAME each reference a POTI route by index, with 0xFFFF/0xFF meaning "no route".
        // The game does not bounds-check that index against the actual route count, it indexes
        // straight into the route array, so a stale or out-of-range routeID (e.g. left over after
        // deleting a route) reads garbage and crashes with a near-null write partway through a lap,
        // not at load time. This is one of the most common real-world "track loads fine but crashes
        // mid-race" causes.
        var badRoutes: [String] = []
        for (i, e) in doc.gobj.enumerated() where e.routeID != 0xFFFF && Int(e.routeID) >= doc.poti.count {
            badRoutes.append("GOBJ \(i) (object \(e.objectID)) -> route \(e.routeID)")
        }
        for (i, e) in doc.area.enumerated() where e.routeID != 0xFF && Int(e.routeID) >= doc.poti.count {
            badRoutes.append("AREA \(i) -> route \(e.routeID)")
        }
        for (i, e) in doc.came.enumerated() where e.routeID != 0xFF && Int(e.routeID) >= doc.poti.count {
            badRoutes.append("CAME \(i) -> route \(e.routeID)")
        }
        checks.append(Check(label: "Route references (POTI)", required: true, passed: badRoutes.isEmpty,
                            detail: badRoutes.isEmpty
                                ? "\(doc.poti.count) route(s), all references in range."
                                : "Points at a route that doesn't exist (only \(doc.poti.count) route(s) defined): \(badRoutes.joined(separator: ", ")). Fix the route index or add the missing route."))
        // Per the wiki: "A route with two or less points has smooth/curved setting enabled" is a
        // known crash cause, smoothing needs at least 3 points to interpolate between.
        let tooShortSmooth = doc.poti.indices.filter { doc.poti[$0].points.count <= 2 && doc.poti[$0].isSmooth }
        checks.append(Check(label: "Route smoothing", required: true, passed: tooShortSmooth.isEmpty,
                            detail: tooShortSmooth.isEmpty
                                ? "No route has smoothing enabled with too few points."
                                : "Route(s) \(tooShortSmooth.map(String.init).joined(separator: ", ")) have Smooth motion enabled with 2 or fewer points."))
        let badObjects = doc.gobj.indices.filter { !isRetailObjectID(doc.gobj[$0].objectID) }
        checks.append(Check(label: "Object IDs (GOBJ)", required: true, passed: badObjects.isEmpty,
                            detail: badObjects.isEmpty
                                ? "Every object is a real Mario Kart Wii object."
                                : "Object(s) \(badObjects.map { "\($0) (ID 0x\(String(doc.gobj[$0].objectID, radix: 16)))" }.joined(separator: ", ")) aren't real objects. The game builds them from garbage and crashes when a kart gets close, often well into the race. Change their Object ID or delete them."))
        // Objects that move along a route (every retail placement gives them one) crash or break
        // without one, e.g. the Sherbet Land penguin (0xD8) walking nowhere.
        let routeless = doc.gobj.indices.filter { i in
            routeRequiredObjectIDs.contains(doc.gobj[i].objectID)
                && (doc.gobj[i].routeID == 0xFFFF || !doc.poti.indices.contains(Int(doc.gobj[i].routeID)))
        }
        checks.append(Check(label: "Object routes (GOBJ)", required: true, passed: routeless.isEmpty,
                            detail: routeless.isEmpty
                                ? "Every object that moves along a route has one."
                                : "Object(s) \(routeless.map { "\($0) (\(gobjDisplayName(doc.gobj[$0].objectID)))" }.joined(separator: ", ")) need a route to follow, every retail placement has one. Give them a Route, or delete them."))
        let unusedByRetail = doc.gobj.indices.filter { isRetailObjectID(doc.gobj[$0].objectID) && !retailUsedObjectIDs.contains(doc.gobj[$0].objectID) }
        checks.append(Check(label: "Objects Nintendo never uses", required: false, passed: unusedByRetail.isEmpty,
                            detail: unusedByRetail.isEmpty
                                ? "Every object appears on at least one retail course."
                                : "Object(s) \(unusedByRetail.map { "\($0) (\(gobjDisplayName(doc.gobj[$0].objectID)))" }.joined(separator: ", ")) aren't placed on any retail course, they may not work in-game."))
        let shortRoutes = doc.poti.indices.filter { doc.poti[$0].points.count < 2 }
        // Informational: retail Coconut Mall ships two 1-point routes, so this alone doesn't crash --
        // it only matters if something is meant to move along one.
        checks.append(Check(label: "Route length (POTI)", required: false, passed: shortRoutes.isEmpty,
                            detail: shortRoutes.isEmpty
                                ? "Every route has at least 2 points."
                                : "Route(s) \(shortRoutes.map(String.init).joined(separator: ", ")) have fewer than 2 points, anything set to move along them won't. Add a point if something uses them."))
        // Per the wiki: "You have too many objects" (GOBJ) crashes around ~200, though some slots
        // (e.g. SNES Ghost Valley 2) tolerate more, kept informational rather than required since
        // the real ceiling depends on the track slot.
        checks.append(Check(label: "Object count (GOBJ)", required: false, passed: doc.gobj.count <= 200,
                            detail: doc.gobj.count <= 200
                                ? "\(doc.gobj.count) object(s)."
                                : "\(doc.gobj.count) objects, above the ~200 that crash most track slots (some, like SNES Ghost Valley 2, tolerate more)."))
        return checks
    }

    /// A Double Dash course archive (`Course/<Name>.arc`): root folder and file names matching a
    /// real slot, every file parsing, and course data that can be raced. Requirements measured on
    /// the retail disc: every race course has one start point, an enemy route, checkpoint groups
    /// and cameras; battle arenas have 8 per-player starts.
    private static func verifyMKDDCourse(_ root: U8Node) -> Result {
        var checks: [Check] = []
        let files = root.children.filter { !$0.isDirectory }
        let stems = Set(files.compactMap { f -> String? in
            guard let r = f.name.range(of: "_course.bmd") ?? f.name.range(of: "_course.bol") else { return nil }
            return String(f.name[..<r.lowerBound])
        })
        let slot = MKDDSlots.slot(forRoot: root.name)
        checks.append(Check(label: "Course slot", required: true, passed: slot != nil && stems.count == 1 && stems.first == slot?.fileStem,
                            detail: slot.map { s in stems.first == s.fileStem
                                ? "\(s.title) (\(s.archive).arc / \(s.archive)L.arc), files named \(s.fileStem)_..."
                                : "Root folder says \(s.title), whose files are named \(s.fileStem)_..., but these are named \(stems.sorted().joined(separator: ", "))_..." }
                                ?? "Root folder \"\(root.name)\" isn't a Double Dash course slot (e.g. luigi2 / luigi2l for Luigi Circuit)."))
        let stem = stems.first ?? slot?.fileStem ?? ""
        func file(_ suffix: String) -> String { "\(stem)\(suffix)" }
        checks.append(requireAndParse(root, name: file("_course.bmd"), label: "Course model (\(file("_course.bmd")))") { try J3DModel.parse($0) })
        checks.append(requireAndParse(root, name: file("_course.bco"), label: "Collision (\(file("_course.bco")))") { try BCO.parse($0) })
        checks.append(requireAndParse(root, name: file("_course.bol"), label: "Course data (\(file("_course.bol")))") { try BOL.parse($0) })
        checks.append(requireAndParse(root, name: file("_map.bti"), label: "Minimap (\(file("_map.bti")))") { data -> Data in
            guard data.count >= 0x20, GXTextureFormat(rawValue: UInt32(data.u8(0))) != nil else { throw WSError.badStructure("not a texture") }
            return data
        })
        if let sky = files.first(where: { $0.name == file("_sky.bmd") })?.data {
            checks.append(Check(label: "Sky (\(file("_sky.bmd")))", required: true, passed: (try? J3DModel.parse(sky)) != nil, detail: "Optional; present and readable."))
        }
        if let data = files.first(where: { $0.name == file("_course.bol") })?.data, let doc = try? BOL.parse(data) {
            let battle = slot?.battle ?? false
            if battle {
                checks.append(Check(label: "Start points", required: true, passed: doc.ktpt.count == 8,
                                    detail: "\(doc.ktpt.count) start point(s); every retail battle arena has 8, one per player."))
            } else {
                checks.append(Check(label: "Start point", required: true, passed: !doc.ktpt.isEmpty,
                                    detail: doc.ktpt.isEmpty ? "None, karts have nowhere to start." : "\(doc.ktpt.count) start point(s)."))
                checks.append(Check(label: "Enemy route", required: true, passed: doc.enpt.count >= 2,
                                    detail: doc.enpt.count >= 2 ? "\(doc.enpt.count) point(s) in \(doc.enph.count) group(s)." : "CPU racers need an enemy route (retail courses have 10-129 points)."))
                checks.append(Check(label: "Checkpoints", required: true, passed: !doc.ckpt.isEmpty,
                                    detail: doc.ckpt.isEmpty ? "None, laps can't count." : "\(doc.ckpt.count) checkpoint(s) in \(doc.ckph.count) group(s)."))
            }
            checks.append(Check(label: "Cameras", required: false, passed: !doc.came.isEmpty,
                                detail: doc.came.isEmpty ? "No cameras. Every retail course has intro and replay cameras (4-35); without them the intro has nothing to show." : "\(doc.came.count) camera(s)."))
        }
        return Result(modName: ModType.mkddCourse.rawValue, checks: checks)
    }

    /// Reuses `NSMBWLevelDocument.parse` itself (the same real reader `NSMBWLevelView` opens a
    /// level with) rather than re-checking file names by hand, it already throws a specific
    /// `WSError` for "no course folder" / "no readable areas", which is exactly what this needs.
    private static func verifyNSMBWLevel(_ root: U8Node) -> Result {
        do {
            let doc = try NSMBWLevelDocument.parse(root: root)
            let areas = doc.areas.map { "Area \($0.areaNumber)" }.joined(separator: ", ")
            return Result(modName: ModType.nsmbwLevel.rawValue, checks: [
                Check(label: "Level data (course/courseN.bin)", required: true, passed: true,
                      detail: "Found and parsed \(doc.areas.count) area(s): \(areas)."),
            ])
        } catch {
            return Result(modName: ModType.nsmbwLevel.rawValue, checks: [
                Check(label: "Level data (course/courseN.bin)", required: true, passed: false,
                      detail: error.localizedDescription),
            ])
        }
    }

    private static func requireAndParse<T>(_ root: U8Node, name: String, label: String, parse: (Data) throws -> T) -> Check {
        guard let node = root.children.first(where: { !$0.isDirectory && $0.name == name }) else {
            return Check(label: label, required: true, passed: false, detail: "Missing \"\(name)\" at the archive's top level.")
        }
        guard let data = node.data, !data.isEmpty else {
            return Check(label: label, required: true, passed: false, detail: "\"\(name)\" is present but empty.")
        }
        do {
            _ = try parse(data)
            return Check(label: label, required: true, passed: true, detail: "Present and parses correctly.")
        } catch {
            return Check(label: label, required: true, passed: false, detail: "Present but failed to parse: \(error.localizedDescription)")
        }
    }

}
