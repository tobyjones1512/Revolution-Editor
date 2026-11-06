import Foundation

/// What the Hot Swap checks can repair by themselves ("Auto Correct"), and in plain words how to
/// fix everything else. Each fix works on a track's archive tree, the same files the game loads.
nonisolated enum HotSwapAutoFix: Hashable {
    case itemBoxModel, skyModel, minimapModel
    case renameModel(file: String, to: String)
    case openingCamera, speedFactor, lensFlare, addStart, respawnIDs, addRespawn, checkpointRespawns
    case pathLinks, routeReferences, routeSmoothing, deleteBadObjects, deleteRoutelessObjects
    case battleArena
    case doubleDashMakeTestable

    /// The button's words.
    var title: String {
        switch self {
        case .itemBoxModel: "Copy itembox.brres from your disc"
        case .skyModel: "Use Luigi Circuit's sky from your disc"
        case .minimapModel: "Build a minimap from the road"
        case .renameModel(_, let to): "Rename the model to \"\(to)\""
        case .openingCamera: "Start the intro on camera 1"
        case .speedFactor: "Set normal speed"
        case .lensFlare: "Fix the flare colour"
        case .addStart: "Add a start point"
        case .respawnIDs: "Renumber respawn points"
        case .addRespawn: "Add a respawn point at the start"
        case .checkpointRespawns: "Point them at respawn point 1"
        case .pathLinks: "Repair the path links"
        case .routeReferences: "Clear the broken route links"
        case .routeSmoothing: "Turn smoothing off on those routes"
        case .deleteBadObjects: "Delete those objects"
        case .deleteRoutelessObjects: "Delete those objects"
        case .battleArena: "Fill in the battle arena setup"
        case .doubleDashMakeTestable: "Run Make Testable"
        }
    }

    // MARK: Matching checks to fixes

    /// The fix (if any) and how-to for a failed `ModVerifier` check on a Mario Kart Wii track.
    static func forWiiCheck(_ c: ModVerifier.Check, root: U8Node, battle: Bool) -> (fix: HotSwapAutoFix?, howTo: String) {
        let missing = c.detail.hasPrefix("Missing")
        switch c.label {
        case "Collision (course.kcl)":
            return (nil, missing ? "Make one with File > New > Mario Kart Wii > Collision (KCL) from Model, name it course.kcl and put it in the track." : "Rebuild it from your model with File > New > Mario Kart Wii > Collision (KCL) from Model.")
        case "Course map (course.kmp)":
            return (nil, "Make one with File > New > Mario Kart Wii > Course Data (KMP), name it course.kmp, then open it and use Make Testable.")
        case "3D model (course_model.brres)", "Background model (vrcorn_model.brres)", "Minimap model (map_model.brres)":
            let file = c.label.components(separatedBy: "(").last!.dropLast()
            let required = OBJToBRRES.requiredModelNames[String(file)] ?? "course"
            if !missing, c.detail.contains("no model named"), let data = root.children.first(where: { $0.name == file })?.data,
               let doc = try? BRRESDocument.parse(data), doc.resources.contains(where: { $0.magic == "MDL0" }) {
                return (.renameModel(file: String(file), to: required), "The game looks the model up by the name \"\(required)\". Rename it in the BRRES editor, or let Auto Correct do it.")
            }
            if missing, file == "vrcorn_model.brres" { return (.skyModel, "Every track needs a sky. Make your own with File > New > Mario Kart Wii > Skybox, or use a retail one.") }
            if missing, file == "map_model.brres" {
                return (root.children.contains { $0.name == "course_model.brres" } ? .minimapModel : nil,
                        "Every track needs a minimap. Right-click course_model.brres and choose Mario Kart Wii > Minimap Editor to pick what's on it.")
            }
            return (nil, "Make it from your model with Make .brres, named \(file).")
        case "Item box model (itembox.brres)":
            return (.itemBoxModel, "Every retail track carries the item box model. Copy it from any retail track, or let Auto Correct take it from your disc.")
        case "Opening camera": return (.openingCamera, "Pick a real camera as the opening camera in Stage Info, or let Auto Correct use the first one.")
        case "Speed factor": return (.speedFactor, "Set the speed factor to 0 (normal speed) in Stage Info.")
        case "Lens flare colour": return (.lensFlare, "Set the flare colour again in Stage Info.")
        case "Start position (KTPT)": return (.addStart, "Add a Start Point (KTPT) on the start line in the KMP editor. Auto Correct puts one at the first enemy point for you to move.")
        case "Respawn IDs (JGPT)": return (.respawnIDs, "Open and save course.kmp in the KMP editor, or let Auto Correct renumber them 0, 1, 2...")
        case "Respawn points (JGPT)": return (.addRespawn, "Add respawn points with Tools > Respawn Point per Checkpoint in the KMP editor. Auto Correct adds one at the start.")
        case "Checkpoint respawn points": return (.checkpointRespawns, "Set each checkpoint's respawn point in the KMP editor, or run Respawn Point per Checkpoint.")
        case "Checkpoints & laps": return (nil, "Open course.kmp and press Check Laps: it shows which checkpoints are wrong. Draw them across the whole road, in driving order, with the finish line first.")
        case "Enemy paths (ENPH)", "Item paths (ITPH)", "Checkpoint groups (CKPH)":
            return (.pathLinks, "Each path must link to the next one and back. Make Testable in the KMP editor repairs this, or let Auto Correct do it.")
        case "Route references (POTI)": return (.routeReferences, "Set those objects', areas' and cameras' Route to a route that exists, or let Auto Correct clear the broken links.")
        case "Route smoothing": return (.routeSmoothing, "Add a third point to those routes, or turn Smooth motion off on them.")
        case "Object IDs (GOBJ)": return (.deleteBadObjects, "Change those objects' type to a real Mario Kart Wii object in the KMP editor, or delete them.")
        case "Object routes (GOBJ)": return (.deleteRoutelessObjects, "Give those objects a Route in the KMP editor (make one with + > New Route), or delete them.")
        case "Cannon trigger/point match": return (nil, "Add a Cannon Point (CNPT) for each cannon ID your collision uses, or change the collision's cannon IDs in the KCL editor.")
        default:
            if battle { return (.battleArena, "Use Make Testable in the KMP editor: it fills in the 12 starts, 4 battle respawns and respawn points an arena needs.") }
            return (nil, c.detail)
        }
    }

    /// The same for a Double Dash course.
    static func forDoubleDashCheck(_ c: ModVerifier.Check) -> (fix: HotSwapAutoFix?, howTo: String) {
        switch c.label {
        case "Start point", "Checkpoints":
            return (.doubleDashMakeTestable, "Open the course's .bol and use Make Testable, or let Auto Correct run it: it adds a start and a first checkpoint for you to move.")
        case "Enemy route": return (nil, "Draw the CPU route with the pen tool in the course data editor (+ > New Enemy Path).")
        case "Start points": return (nil, "A battle arena needs 8 start points, one per player. Make one with File > New > Mario Kart: Double Dash!! > Battle Arena Course Data.")
        case "Course slot": return (nil, "Right-click the archive and choose Mark for Hot Swap > Mario Kart: Double Dash!! to pick the slot it replaces; the files are renamed for it.")
        default:
            if c.label.contains("(") { return (nil, "Add the missing file, or rebuild the track with File > New > Mario Kart: Double Dash!! > Track from Model.") }
            return (nil, c.detail)
        }
    }

    // MARK: Applying

    /// Applies `fix` to a track's archive tree and says what it did.
    /// `keys` are the Wii common and Korean keys, for fixes that copy from the base game.
    static func apply(_ fix: HotSwapAutoFix, to root: U8Node, keys: (common: [UInt8]?, korean: [UInt8]?)) throws -> String {
        func file(_ name: String) -> U8Node? { root.children.first { !$0.isDirectory && $0.name.lowercased() == name.lowercased() } }
        func baseGame(_ name: String) throws -> Data {
            let index = try BaseGameLibrary.shared.index(commonKey: keys.common, koreanKey: keys.korean)
            guard let data = BaseGameLibrary.shared.brres(named: name, in: index) else { throw WSError.badStructure("\(name).brres isn't on the linked disc.") }
            return data
        }
        switch fix {
        case .itemBoxModel:
            root.setFile(at: ["itembox.brres"], data: try baseGame("itembox"))
            return "Copied itembox.brres from your disc."
        case .skyModel:
            root.setFile(at: ["vrcorn_model.brres"], data: try baseGame("vrcorn_model"))
            return "Added a retail sky (vrcorn_model.brres)."
        case .minimapModel:
            guard let course = file("course_model.brres")?.data, let options = MapModelBuilder.options(inBRRES: course) else { throw WSError.badStructure("course_model.brres couldn't be read.") }
            // The road, by texture name; everything if nothing is named like one.
            let road = options.filter { o in ["road", "asphalt", "track", "load", "street", "path"].contains { (o.textureName ?? "").lowercased().contains($0) } }
            let kept = Set((road.isEmpty ? options : road).map(\.id))
            root.setFile(at: ["map_model.brres"], data: try MapModelBuilder.build(fromBRRES: course, keeping: kept, modelName: "map"))
            return road.isEmpty ? "Built map_model.brres from the whole course (no road textures found, refine it in the Minimap Editor)." : "Built map_model.brres from the road textures."
        case .renameModel(let name, let to):
            guard let node = file(name), let data = node.data else { throw WSError.badStructure("\(name) is missing.") }
            let doc = try BRRESDocument.parse(data)
            guard let model = doc.resources.first(where: { $0.magic == "MDL0" }) else { throw WSError.badStructure("\(name) has no model.") }
            model.name = to
            node.data = doc.serialize()
            return "Renamed the model in \(name) to \"\(to)\"."
        case .doubleDashMakeTestable:
            guard let node = root.children.first(where: { $0.name.lowercased().hasSuffix("_course.bol") }), let data = node.data else { throw WSError.badStructure("The course has no .bol.") }
            let doc = try BOL.parse(data)
            let fixes = BOL.makeTestable(doc)
            node.data = doc.serialize()
            return fixes.isEmpty ? "Make Testable had nothing to change." : fixes.joined(separator: " ")
        default:
            guard let node = file("course.kmp"), let data = node.data else { throw WSError.badStructure("The track has no course.kmp.") }
            let doc = try KMPDocument.parse(data)
            let said = applyKMP(fix, to: doc)
            node.data = doc.serialize()
            return said
        }
    }

    private static func applyKMP(_ fix: HotSwapAutoFix, to doc: KMPDocument) -> String {
        switch fix {
        case .openingCamera:
            doc.openingCameraIndex = doc.came.isEmpty ? 0xFF : 0
            return "The intro now starts on camera 1."
        case .speedFactor:
            doc.stgi.speedFactor = 0
            return "Speed set to normal."
        case .lensFlare:
            doc.stgi.flareColor.0 = 0
            return "Flare colour stored as retail stores it."
        case .addStart:
            doc.ktpt.append(KTPTEntry(position: doc.enpt.first?.position ?? doc.jgpt.first?.position ?? Vec3()))
            return "Added a start point, move it onto the start line."
        case .respawnIDs:
            for k in doc.jgpt.indices { doc.jgpt[k].respawnID = UInt16(k) }
            return "Respawn points numbered 0 to \(max(0, doc.jgpt.count - 1))."
        case .addRespawn:
            doc.jgpt.append(JGPTEntry(position: doc.ktpt.first?.position ?? Vec3(), rotation: doc.ktpt.first?.rotation ?? Vec3()))
            return "Added a respawn point at the start."
        case .checkpointRespawns:
            if doc.jgpt.isEmpty { doc.jgpt.append(JGPTEntry(position: doc.ktpt.first?.position ?? Vec3())) }
            for i in doc.ckpt.indices where !doc.jgpt.indices.contains(Int(doc.ckpt[i].respawnIndex)) { doc.ckpt[i].respawnIndex = 0 }
            return "Checkpoints with a missing respawn point now use respawn point 1."
        case .pathLinks:
            let battle = BattleArena.isBattle(doc)
            var said: [String] = []
            func clean(_ groups: inout [PathLinkEntry], _ count: Int) {
                for g in groups.indices {
                    groups[g].nextGroups = groups[g].nextGroups.map { $0 != 0xFF && Int($0) >= groups.count ? 0xFF : $0 }
                    groups[g].previousGroups = groups[g].previousGroups.map { $0 != 0xFF && Int($0) >= groups.count ? 0xFF : $0 }
                    let start = Int(groups[g].startIndex)
                    if start + Int(groups[g].pointCount) > count { groups[g].pointCount = UInt8(clamping: max(0, count - start)) }
                }
            }
            clean(&doc.enph, doc.enpt.count); clean(&doc.itph, doc.itpt.count); clean(&doc.ckph, doc.ckpt.count)
            if !battle { said += KMPDocument.fixPathLinks(&doc.enph, label: "Enemy") }
            said += KMPDocument.fixPathLinks(&doc.itph, label: "Item")
            if !battle, doc.itph.count > 1, case let n = KMPDocument.removeUnreachableGroups(groups: &doc.itph, points: &doc.itpt), n > 0 {
                said.append("Removed \(n) item path(s) nothing leads into.")
                said += KMPDocument.fixPathLinks(&doc.itph, label: "Item")
            }
            said += KMPDocument.fixPathLinks(&doc.ckph, label: "Checkpoint")
            return said.isEmpty ? "Path links repaired." : said.joined(separator: " ")
        case .routeReferences:
            for i in doc.gobj.indices where doc.gobj[i].routeID != 0xFFFF && Int(doc.gobj[i].routeID) >= doc.poti.count { doc.gobj[i].routeID = 0xFFFF }
            for i in doc.area.indices where doc.area[i].routeID != 0xFF && Int(doc.area[i].routeID) >= doc.poti.count { doc.area[i].routeID = 0xFF }
            for i in doc.came.indices where doc.came[i].routeID != 0xFF && Int(doc.came[i].routeID) >= doc.poti.count { doc.came[i].routeID = 0xFF }
            return "Cleared links to routes that don't exist."
        case .routeSmoothing:
            for r in doc.poti.indices where doc.poti[r].points.count <= 2 { doc.poti[r].isSmooth = false }
            return "Turned smoothing off on routes with 2 or fewer points."
        case .deleteBadObjects:
            let before = doc.gobj.count
            doc.gobj.removeAll { !isRetailObjectID($0.objectID) }
            return "Deleted \(before - doc.gobj.count) object(s) that aren't real Mario Kart Wii objects."
        case .deleteRoutelessObjects:
            let before = doc.gobj.count
            doc.gobj.removeAll { routeRequiredObjectIDs.contains($0.objectID) && ($0.routeID == 0xFFFF || !doc.poti.indices.contains(Int($0.routeID))) }
            return "Deleted \(before - doc.gobj.count) object(s) that need a route and had none."
        case .battleArena:
            let fixes = BattleArena.makeTestable(doc)
            return fixes.isEmpty ? "The arena setup was already complete." : fixes.joined(separator: " ")
        default:
            return ""
        }
    }
}

nonisolated extension KMPDocument {
    /// Makes path groups link up: an unlinked set becomes one loop in order, every "next" gets
    /// its matching "previous" (and back), and a dead end loops back to itself. Says what changed.
    @discardableResult
    static func fixPathLinks(_ groups: inout [PathLinkEntry], label: String) -> [String] {
        var fixes: [String] = []
        guard !groups.isEmpty else { return fixes }
        if groups.count == 1 {
            guard groups[0].nextGroups.allSatisfy({ $0 == 0xFF }) else { return fixes }
            groups[0].nextGroups[0] = 0
            groups[0].previousGroups[0] = 0
            return ["\(label) Path 1 had no \"next\" path, linked it back to itself (both ends) so a lap can complete."]
        }
        let allUnlinked = groups.indices.allSatisfy { i in
            groups[i].nextGroups.allSatisfy({ $0 == 0xFF }) && groups[i].previousGroups.allSatisfy({ $0 == 0xFF })
        }
        if allUnlinked {
            for i in groups.indices {
                groups[i].nextGroups[0] = UInt8((i + 1) % groups.count)
                groups[i].previousGroups[0] = UInt8((i + groups.count - 1) % groups.count)
            }
            fixes.append("\(label) Path groups were not linked together, connected them into a single loop in array order.")
        }
        for i in groups.indices {
            for j in groups[i].nextGroups where j != 0xFF && Int(j) < groups.count && j != UInt8(i) {
                guard !groups[Int(j)].previousGroups.contains(UInt8(i)),
                      let slot = groups[Int(j)].previousGroups.firstIndex(of: 0xFF) else { continue }
                groups[Int(j)].previousGroups[slot] = UInt8(i)
            }
            for j in groups[i].previousGroups where j != 0xFF && Int(j) < groups.count && j != UInt8(i) {
                guard !groups[Int(j)].nextGroups.contains(UInt8(i)),
                      let slot = groups[Int(j)].nextGroups.firstIndex(of: 0xFF) else { continue }
                groups[Int(j)].nextGroups[slot] = UInt8(i)
            }
        }
        for i in groups.indices where groups[i].nextGroups.allSatisfy({ $0 == 0xFF }) {
            groups[i].nextGroups[0] = UInt8(i)
            if !groups[i].previousGroups.contains(UInt8(i)), let slot = groups[i].previousGroups.firstIndex(of: 0xFF) {
                groups[i].previousGroups[slot] = UInt8(i)
            }
            fixes.append("\(label) Path \(i + 1) had no \"next\" path, linked it back to itself (both ends) so a lap can complete.")
        }
        return fixes
    }
}
