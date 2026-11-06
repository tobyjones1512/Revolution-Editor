import Foundation
import simd

/// Mario Kart Wii track (`.szs`) -> Mario Kart: Double Dash!! course (`Course/<Slot>.arc`), the
/// reverse of `MKDDPort`.
///
/// - Model and sky: every mesh of `course`/`vrcorn`, textured with its material's colour
///   texture. A lightmapped material's shadow map (`kage`, see `MDL0SceneKit`) is sampled at each
///   vertex and multiplied into its vertex colour, as is Mario Kart Wii's x2 shader scale --
///   Double Dash shades texture x vertex colour. Textures are fitted to the GameCube's budget
///   (`GCTextures`: CMPR/RGB5A3, power-of-two, mipmapped, halved until ~1.3 MB).
/// - Collision: Double Dash collision is all flat, every retail triangle, walls included, is a
///   floor (checked on the disc: no surface type is more than 2% steep); its walls are flat strips
///   along the track's edge. So Wii floors keep their surface (`bcoFlag`), triggers are dropped,
///   and the ground behind each Wii wall's foot becomes wall (`collision`).
/// - Course data: start, enemy route (widths are world units in both games), checkpoints (on the
///   ground), respawn points and item boxes; plus an intro camera on its own route and the
///   parade camera every retail course ends its camera list with (byte-identical on all of them).
///   Objects other than item boxes, areas and the Wii's own cameras don't exist in Double Dash
///   and are listed in the report.
nonisolated enum MKWiiToMKDD {
    /// Double Dash Mario Circuit is ~1/1.32 the size of its Wii remake as ported (see `MKDDPort`).
    static let defaultScale: Float = 1 / MKDDPort.defaultScale

    /// Mario Kart Wii KCL flag -> Double Dash surface (type << 8), or nil for a non-solid trigger
    /// or a wall (see `wallFlag`). Types per Kinoko's `KCollisionTypes.hh`.
    static func bcoFlag(forKCL attribute: UInt16) -> UInt16? {
        switch attribute & 0x1F {
        case 0x00, 0x0B, 0x13, 0x15, 0x16, 0x17, 0x1D: return 0x0100 // road-like
        case 0x01: return 0x1100  // slippery sand -> beach sand
        case 0x02: return 0x0C00  // weak off-road
        case 0x03: return 0x0300  // off-road
        case 0x04: return 0x1300  // heavy off-road
        case 0x05: return 0x0400  // ice
        case 0x06: return 0x0800  // boost panel
        case 0x07, 0x08: return 0x0700 // boost ramp / jump pad -> ramp boost
        case 0x0A, 0x10: return 0x0A00 // solid fall / fall boundary -> dead zone
        default: return nil       // walls, item-only road (0x09) and non-solid triggers (0x11, 0x12, 0x18, 0x1A, 0x1B)
        }
    }

    /// Key for "trickable surfaces" (KCL bit 0x2000) in `collision`'s `choices`: Double Dash has no tricks.
    static let trickableKey: UInt16 = 0x2000
    /// Key for wall-flagged triangles facing up like a floor in `collision`'s `choices`: often a
    /// mis-flagged floor, so the user picks what they become (nil keeps them walls, retail
    /// tracks have thousands, mostly wall tops, which match Double Dash's own flat wall strips).
    static let upwardWallKey: UInt16 = 0x4000

    /// A wall-flagged triangle lying flat enough to drive on, facing up.
    static func isUpwardWall(_ t: KCLTriangle) -> Bool {
        guard wallFlag(forKCL: t.attribute) != nil else { return false }
        let n = Vec3.cross(t.v1 - t.v0, t.v2 - t.v0)
        return n.length > 0 && n.y >= 0.3 * n.length
    }

    /// KCL base types the port can't match exactly, with what it picks by default (nil: left out).
    /// Exact matches (road, the off-roads, ice, boost panel, boost ramp, solid fall, walls) and
    /// non-solid triggers (route recalculation, sound and effect triggers, item-state modifier),
    /// which have nothing to be in Double Dash, aren't listed.
    static let unmatchedDefaults: [UInt16: UInt16?] = [
        0x01: 0x1100, 0x08: 0x0700, 0x09: nil, 0x0B: 0x0100, 0x0E: nil, 0x10: 0x0A00, 0x11: nil,
        0x13: 0x0100, 0x15: 0x0100, 0x16: 0x0100, 0x19: nil, 0x1D: 0x0100, 0x1E: 0x0200,
    ]

    /// The unmatched types (and `trickableKey`) this KCL uses, with triangle counts, what to ask
    /// the user about before converting.
    static func unmatchedTypes(in kcl: KCLDocument) -> [(key: UInt16, count: Int)] {
        var counts: [UInt16: Int] = [:]
        for t in kcl.triangles {
            if unmatchedDefaults.keys.contains(t.attribute & 0x1F) { counts[t.attribute & 0x1F, default: 0] += 1 }
            if t.attribute & 0x2000 != 0, bcoFlag(forKCL: t.attribute) != nil { counts[trickableKey, default: 0] += 1 }
            if isUpwardWall(t) { counts[upwardWallKey, default: 0] += 1 }
        }
        return counts.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// Mario Kart Wii wall flag -> Double Dash wall (type << 8): kart walls stay walls, a player-only
    /// wall becomes the kart-only wall. Item-only (0x0E) and low-speed "weak" (0x19) walls don't stop
    /// karts, so they're dropped.
    static func wallFlag(forKCL attribute: UInt16) -> UInt16? {
        switch attribute & 0x1F {
        case 0x0C, 0x0D, 0x0F, 0x1C, 0x1E, 0x1F: return 0x0200
        case 0x14: return 0x1200
        default: return nil
        }
    }

    /// The parade ("para") camera, byte for byte as every retail course has it, last in its list.
    static let paradeCameraRecord = Data(J3DWriter.hexBytes("""
    C4 57 1C 69 45 CC 8D 81 45 43 BB D9 00 00 00 00 27 10 00 00 27 10 00 00 43 20 00 00 40 A0 00 00 00 00 00 00 C1 A0 00 00
    C1 A0 00 00 43 E1 00 00 00 08 00 55 07 08 00 00 00 00 00 00 FF FF 00 01 00 23 FF FF 70 61 72 61
    """))

    static func paradeCamera() -> CAMEEntry {
        let r = paradeCameraRecord
        func v(_ o: Int) -> Vec3 { Vec3(x: r.beFloat32(o), y: r.beFloat32(o + 4), z: r.beFloat32(o + 8)) }
        return CAMEEntry(type: 8, next: 0xFF, routeID: 0xFF, pointVelocity: 1, startFlag: 0, position: v(0), rotation: Vec3(),
                         zoomStart: 85, zoomEnd: 35, viewPositionStart: v(0x24), viewPositionEnd: v(0x18), time: 1800, bol: r)
    }

    /// An intro shot: a start camera (type 5, route-following like retail's) gliding from behind
    /// and above the start towards it, looking along the start line.
    static func addIntroCamera(to doc: KMPDocument, start: Vec3, yawDegrees: Float, scale s: Float) {
        let yaw = yawDegrees * .pi / 180
        let forward = Vec3(x: sin(yaw), y: 0, z: cos(yaw))
        func at(_ back: Float, _ up: Float) -> Vec3 { start + forward * (-back * s) + Vec3(x: 0, y: up * s, z: 0) }
        let route = POTIRoute(points: [RoutePoint(position: at(5000, 2500)), RoutePoint(position: at(1500, 1200))])
        doc.poti.append(route)
        doc.came.insert(CAMEEntry(type: 5, next: 0xFF, routeID: UInt8(doc.poti.count - 1), pointVelocity: 20, startFlag: 1,
                                  position: at(5000, 2500), rotation: Vec3(), zoomStart: 50, zoomEnd: 45,
                                  viewPositionStart: start, viewPositionEnd: start + forward * (3000 * s), time: 240), at: 0)
    }

    /// The Wii course's own opening pan, shot by shot, as Double Dash intro cameras: each camera on
    /// its (placed) route, looking from its View Start to View End, for its Duration, chained the
    /// way the Wii's were. Speed is set so the route is covered in the shot's time. A course with
    /// no opening pan gets `addIntroCamera`'s generic shot.
    static func addIntroCameras(from kmp: KMPDocument, to bol: KMPDocument, place: Placement, start: Vec3, yawDegrees: Float) {
        let chain = KMPCameraSequence.chain(in: kmp)
        guard !chain.isEmpty else { addIntroCamera(to: bol, start: start, yawDegrees: yawDegrees, scale: place.scale); return }
        for (n, i) in chain.enumerated() {
            let c = kmp.came[i]
            var points = kmp.poti.indices.contains(Int(c.routeID)) ? kmp.poti[Int(c.routeID)].points.map { place.apply($0.position) } : []
            if points.count < 2 { let p = place.apply(c.position); points = [p, p + Vec3(x: 1, y: 0, z: 0)] }
            var length: Float = 0
            for k in 1..<points.count { length += (points[k] - points[k - 1]).length }
            let time = max(1, c.time)
            bol.poti.append(POTIRoute(points: points.map { RoutePoint(position: $0) }))
            bol.came.append(CAMEEntry(type: 5, next: n == chain.count - 1 ? 0xFF : UInt8(bol.came.count + 1), routeID: UInt8(bol.poti.count - 1),
                                      pointVelocity: UInt16(clamping: max(1, Int((length / time).rounded(.up)))), startFlag: n == 0 ? 1 : 0,
                                      position: points[0], rotation: Vec3(), zoomStart: c.zoomStart, zoomEnd: c.zoomEnd,
                                      viewPositionStart: place.apply(c.viewPositionStart), viewPositionEnd: place.apply(c.viewPositionEnd), time: time))
        }
    }

    // MARK: Port

    /// Where the course goes: scaled, turned about the vertical axis by `yaw` quarter turns, then moved.
    struct Placement {
        var scale: Float
        var quarterTurns = 0
        var offset = Vec3()
        func apply(_ p: Vec3) -> Vec3 {
            var x = p.x * scale, z = p.z * scale
            for _ in 0..<quarterTurns { (x, z) = (z, -x) } // +90 degrees yaw each
            return Vec3(x: x + offset.x, y: p.y * scale + offset.y, z: z + offset.z)
        }
        var yawDegrees: Float { Float(quarterTurns) * 90 }
    }

    /// Centres the course's floor on the slot's minimap area, turned whichever way fits it better
    /// (neither changes how it plays), and, with `fitScale`, scales it to fill the area.
    static func placement(floor: [Vec3], minimap: MKDDSlots.Minimap?, scale: Float, fitScale: Bool) -> (Placement, fit: Float?) {
        guard let m = minimap, !floor.isEmpty else { return (Placement(scale: scale), nil) }
        let rw = abs(m.corner2.x - m.corner1.x), rh = abs(m.corner2.y - m.corner1.y)
        let xs = floor.map(\.x), zs = floor.map(\.z)
        let w = (xs.max()! - xs.min()!) * scale, h = (zs.max()! - zs.min()!) * scale
        let fit0 = min(rw / max(w, 1), rh / max(h, 1)), fit90 = min(rw / max(h, 1), rh / max(w, 1))
        var place = Placement(scale: scale, quarterTurns: fit90 > fit0 * 1.05 ? 1 : 0)
        var fit = max(fit0, fit90)
        if fitScale { place.scale = scale * fit * 0.95; fit = 1 / 0.95 }
        let moved = floor.map { place.apply($0) }
        let cx = (moved.map(\.x).max()! + moved.map(\.x).min()!) / 2, cz = (moved.map(\.z).max()! + moved.map(\.z).min()!) / 2
        place.offset = Vec3(x: (m.corner1.x + m.corner2.x) / 2 - cx, y: 0, z: (m.corner1.y + m.corner2.y) / 2 - cz)
        return (place, fit)
    }

    static func port(_ szs: Data, name: String, slot: MKDDSlots.Slot, scale requested: Float = defaultScale, minimap: MKDDSlots.Minimap?, fitScale: Bool = false, choices: [UInt16: UInt16?] = [:]) throws -> MKDDTrackBuilder.Output {
        let (root, _) = try SZS.open(szs)
        func file(_ n: String) -> Data? { root.children.first { !$0.isDirectory && $0.name == n }?.data }
        guard let courseData = file("course_model.brres") else { throw WSError.badStructure("\(name) has no course_model.brres, is it a Mario Kart Wii track?") }
        guard let kclData = file("course.kcl") else { throw WSError.badStructure("\(name) has no course.kcl.") }
        guard let kmpData = file("course.kmp") else { throw WSError.badStructure("\(name) has no course.kmp.") }
        var report: [String] = []
        let kcl = try KCLDocument.parse(kclData)
        let floorPoints = kcl.triangles.filter { bcoFlag(forKCL: $0.attribute) != nil }.flatMap { [$0.v0, $0.v1, $0.v2] }
        let (place, fit) = placement(floor: floorPoints, minimap: minimap, scale: requested, fitScale: fitScale)
        let s = place.scale
        if place.quarterTurns != 0 || place.offset != Vec3() {
            report.append(String(format: "Placed in %@'s minimap area: moved by (%.0f, %.0f)%@.", slot.title, place.offset.x, place.offset.z, place.quarterTurns != 0 ? ", turned 90 degrees" : ""))
        }
        if fitScale { report.append(String(format: "Scaled %.2fx to fill the minimap area.", s)) }

        let course = try model(courseData, modelName: "course", place: place, report: &report)
        let sky = file("vrcorn_model.brres").flatMap { try? model($0, modelName: "vrcorn", place: Placement(scale: s, quarterTurns: place.quarterTurns), report: &report) }
        if sky == nil { report.append("No usable vrcorn_model.brres, the course has no sky.") }

        // MARK: Collision
        let (collisionTris, floors, dropped) = collision(kcl, place: place, choices: choices)
        let wallCount = collisionTris.count - floors.count
        report.append("Collision: \(floors.count) floor triangles, \(wallCount) wall triangles\(dropped > 0 ? ", \(dropped) trigger triangles dropped (no Double Dash equivalent)" : "").")

        // MARK: Course data
        let kmp = try KMPDocument.parse(kmpData)
        // Heights from the ported collision itself (already placed).
        let placedKCL = KCLDocument()
        placedKCL.triangles = floors.map { KCLTriangle(v0: $0.v0, v1: $0.v1, v2: $0.v2, attribute: 0) }
        let ground = DriverPath.GroundQuery(placedKCL)
        func groundY(_ x: Float, _ z: Float, near y: Float) -> Float { ground.height(x: x, z: z, near: y) ?? y }
        func turned(_ r: Vec3) -> Vec3 { Vec3(x: r.x, y: r.y + place.yawDegrees, z: r.z) }
        func flat(_ v: Vec2) -> Vec2 { let p = place.apply(Vec3(x: v.x, y: 0, z: v.y)); return Vec2(x: p.x, y: p.z) }
        let bol = BOL.newDocument(musicID: slot.musicID)
        bol.stgi.lapCount = kmp.stgi.lapCount
        bol.stgi.polePosition = kmp.stgi.polePosition
        guard let start = kmp.ktpt.first else { throw WSError.badStructure("\(name)'s course.kmp has no start point.") }
        let startPos = place.apply(start.position)
        bol.ktpt = [KTPTEntry(position: startPos, rotation: turned(start.rotation), playerIndex: -1)]
        bol.enpt = kmp.enpt.map { ENPTEntry(position: place.apply($0.position), radius: $0.radius * s) }
        bol.enph = kmp.enph.map { PathLinkEntry(startIndex: $0.startIndex, pointCount: $0.pointCount, previousGroups: $0.previousGroups, nextGroups: $0.nextGroups) }
        bol.ckph = kmp.ckph.map { PathLinkEntry(startIndex: $0.startIndex, pointCount: $0.pointCount, previousGroups: $0.previousGroups, nextGroups: $0.nextGroups) }
        bol.ckpt = kmp.ckpt.map { c in
            let l = flat(c.left), r = flat(c.right)
            // Double Dash checkpoints are 3D: each end on the ground.
            var rec = Data(count: 0x1C)
            let near = startPos.y
            rec.replaceSubrange(4..<8, with: withUnsafeBytes(of: groundY(l.x, l.y, near: near).bitPattern.bigEndian) { Data($0) })
            rec.replaceSubrange(0x10..<0x14, with: withUnsafeBytes(of: groundY(r.x, r.y, near: near).bitPattern.bigEndian) { Data($0) })
            return CKPTEntry(left: l, right: r, respawnIndex: 0, lapCounterType: c.lapCounterType, bol: rec)
        }
        // Mario Kart Wii tolerates a fan of checkpoints round a hairpin; Double Dash froze on it.
        let quadFixes = BOL.repairCheckpointBranches(bol) + BOL.repairCheckpointQuads(bol) + BOL.repairEnemyRouteLinks(bol)
        if !quadFixes.isEmpty { report.append("Checkpoints: \(quadFixes.count) change(s) so the checkpoints and enemy route are as Double Dash needs them, " + quadFixes.joined(separator: " ")) }
        bol.jgpt = kmp.jgpt.enumerated().map { JGPTEntry(position: place.apply($0.element.position), rotation: turned($0.element.rotation), respawnID: UInt16($0.offset)) }
        let boxes = kmp.gobj.filter { $0.objectID == 0x0065 || $0.objectID == 0x0076 }
        bol.gobj = boxes.map { GOBJEntry(objectID: 1, position: place.apply($0.position), rotation: turned($0.rotation)) }
        addIntroCameras(from: kmp, to: bol, place: place, start: startPos, yawDegrees: start.rotation.y + place.yawDegrees)
        let replay = ReplayTransfer.wiiToDD(kmp, into: bol, place: place)
        bol.came.append(paradeCamera())
        bol.openingCameraIndex = 0
        let otherObjects = Dictionary(grouping: kmp.gobj.filter { $0.objectID != 0x0065 && $0.objectID != 0x0076 }, by: \.objectID)
        report.append("Course data: start, \(bol.enpt.count) enemy points, \(bol.ckpt.count) checkpoints, \(bol.jgpt.count) respawn points, \(boxes.count) item boxes, an intro camera, \(replay.cameras) replay cameras in \(replay.areas) areas and the parade camera.")
        if !otherObjects.isEmpty {
            report.append("Not ported (no Double Dash equivalent): " + otherObjects.map { "\(gobjDisplayName($0.key)) x\($0.value.count)" }.sorted().joined(separator: ", ")
                          + ".")
        }

        var out = try MKDDTrackBuilder.package(slot: slot, course: course, sky: sky, collision: collisionTris, bol: bol, minimap: minimap)
        out.report = report + out.report
        if let fit, fit < 1 {
            out.report.append(String(format: "The track is bigger than %@'s minimap area; to fit it, port at about %.2fx (or turn on Scale to Fit).", slot.title, s * fit * 0.95))
        }
        return out
    }

    // MARK: Model

    static func model(_ brres: Data, modelName: String, place: Placement, report: inout [String]) throws -> MKDDTrackBuilder.Model {
        let doc = try BRRESDocument.parse(brres)
        guard let r = doc.resources.first(where: { $0.magic == "MDL0" && $0.name == modelName }) ?? doc.resources.first(where: { $0.magic == "MDL0" }),
              let mdl0 = MDL0Parser.parse(r, rawFile: doc.rawData) else { throw WSError.badStructure("No readable \(modelName) model.") }
        // Decoded textures by name.
        var rgba: [String: (pixels: [UInt8], width: Int, height: Int)] = [:]
        for t in doc.resources where t.magic == "TEX0" {
            let palette = doc.resources.first { $0.magic == "PLT0" && $0.name == t.name }.flatMap { PLT0View($0)?.entries }
            if let v = TEX0View(t), let p = v.decodeRGBA(palette: palette) { rgba[t.name] = (p, v.width, v.height) }
        }
        func grey(_ name: String) -> Bool {
            guard let t = rgba[name] else { return false }
            var spread = 0
            for i in stride(from: 0, to: t.pixels.count, by: 4) { spread += Int(max(t.pixels[i], t.pixels[i + 1], t.pixels[i + 2]) - min(t.pixels[i], t.pixels[i + 1], t.pixels[i + 2])) }
            return spread < 3 * max(1, t.pixels.count / 4)
        }
        var model = MKDDTrackBuilder.Model()
        // Texture animations: the (material, texture slot) pairs an SRT0 moves.
        let srts = doc.resources.filter { $0.magic == "SRT0" }.compactMap { SRT0Document.parse($0, rawFile: doc.rawData) }
        let animatedSlots = Set(srts.flatMap { srt in srt.materials.flatMap { m in m.matrices.filter { !$0.isIndirect }.map { "\(m.name)#\($0.slotIndex)" } } })
        var animatedMaterials: [String: (index: Int, slot: Int)] = [:]
        var textureIndex: [String: Int] = [:]
        var materialIndex: [String: Int] = [:]
        var baked = 0
        for mesh in model0Meshes(mdl0) {
            let slots = mesh.textureNames.isEmpty ? mesh.textureName.map { [$0] } ?? [] : mesh.textureNames
            let mat = mesh.material
            // A slot drawn from a UV set (not environment- or projection-mapped).
            func mapped(_ slot: Int) -> Bool { mat.map { $0.texCoordSource.indices.contains(slot) ? $0.texCoordSource[slot] != nil : true } ?? true }
            let colorSlot = slots.indices.first { rgba[slots[$0]] != nil && !grey(slots[$0]) && mapped($0) }
                ?? slots.indices.first { rgba[slots[$0]] != nil && mapped($0) } ?? slots.firstIndex { rgba[$0] != nil }
            let lightSlot = colorSlot.flatMap { c in slots.indices.first { $0 != c && grey(slots[$0]) && mapped($0) } }
            let hasUV1 = mesh.vertices.allSatisfy { $0.uv1 != nil }
            // An animated texture keeps its own material, named as on the Wii, for the animation to find.
            let animatedName = colorSlot.flatMap { c in mesh.materialName.flatMap { animatedSlots.contains("\($0)#\(c)") ? $0 : nil } }
            // The slot's UV set, through its texture matrix (Maya mode, as the Wii's course models use;
            // RiiStudio's computeMayaTexMtx). An animated slot's BTK carries its whole SRT, so it isn't baked.
            func uv(_ v: MDL0Vertex, _ slot: Int) -> Vec2? {
                let set = mat.flatMap { $0.texCoordSource.indices.contains(slot) ? $0.texCoordSource[slot] : nil } ?? (slot >= 1 ? 1 : 0)
                guard let t = set == 1 && hasUV1 ? v.uv1 : v.uv0 else { return nil }
                guard !(slot == colorSlot && animatedName != nil), let srt = mat.flatMap({ $0.texSRT.indices.contains(slot) ? $0.texSRT[slot] : nil }) else { return t }
                let r = srt.rotationDegrees * .pi / 180, sn = sin(r), cs = cos(r), sx = srt.scale.x, sy = srt.scale.y
                return Vec2(x: sx * cs * t.x + sx * sn * t.y + sx * (-0.5 * sn - 0.5 * cs + 0.5 - srt.translation.x),
                            y: -sy * sn * t.x + sy * cs * t.y + sy * (0.5 * sn - 0.5 * cs - 0.5 + srt.translation.y) + 1)
            }
            var tex: Int?
            if let c = colorSlot {
                let name = slots[c]
                let wrap = mat.flatMap { $0.wraps.indices.contains(c) ? $0.wraps[c] : nil } ?? (s: 1, t: 1)
                let key = "\(name)/\(wrap.s)\(wrap.t)"
                if let i = textureIndex[key] { tex = i } else if let t = rgba[name] {
                    textureIndex[key] = model.textures.count; tex = model.textures.count
                    let unique = model.textures.contains { $0.name == name } ? "\(name)_\(wrap.s)\(wrap.t)" : name
                    model.textures.append(GCTextures.Source(name: unique, rgba: t.pixels, width: t.width, height: t.height, wrapS: wrap.s, wrapT: wrap.t))
                }
            }
            // Transparency as the Wii material draws it (its translucent pass, its alpha test); a
            // texture's alpha alone doesn't say, 25 retail materials with alpha in their texture
            // draw opaque, and soft-edged foliage is alpha-tested, not blended.
            var transparency: J3DWriter.Transparency = .opaque
            if let mat { transparency = mat.blends ? .translucent : (mat.alphaTest ? .alphaTest : .opaque) } else if let tex {
                let p = model.textures[tex].rgba
                var cut = false, smooth = false
                for i in stride(from: 3, to: p.count, by: 4) where p[i] < 255 { cut = true; if p[i] > 16 && p[i] < 239 { smooth = true; break } }
                transparency = smooth ? .translucent : (cut ? .alphaTest : .opaque)
            }
            let key = animatedName.map { "anim/\($0)" } ?? "\(tex.map(String.init) ?? "-")/\(transparency)"
            let material: Int
            if let m = materialIndex[key] { material = m } else {
                material = model.materials.count
                materialIndex[key] = material
                model.materials.append(J3DWriter.Material(name: animatedName ?? tex.map { model.textures[$0].name } ?? "untextured", texture: tex, cull: 0,
                                                          transparency: transparency, animated: animatedName != nil && tex != nil))
                model.surfaces.append(0x0100)
                if let animatedName, tex != nil, let c = colorSlot { animatedMaterials[animatedName] = (material, c) }
            }
            let lightmap = lightSlot.flatMap { rgba[slots[$0]] }
            if lightmap != nil { baked += 1 }
            func vertex(_ v: MDL0Vertex) -> J3DWriter.Vertex {
                var c = v.color ?? SIMD4(0.5, 0.5, 0.5, 1)
                // Wii course shader: texture x vertex colour x 2.
                c = SIMD4(min(1, c.x * 2), min(1, c.y * 2), min(1, c.z * 2), c.w)
                if let lm = lightmap, let l = lightSlot, let t = uv(v, l) {
                    let shade = sample(lm, t)
                    c = SIMD4(c.x * shade, c.y * shade, c.z * shade, c.w)
                }
                let color = [c.x, c.y, c.z, c.w].map { UInt8(clamping: Int(($0 * 255).rounded())) }
                return J3DWriter.Vertex(position: place.apply(v.position), color: color, uv: colorSlot.flatMap { uv(v, $0) } ?? Vec2())
            }
            var i = 0
            while i + 2 < mesh.vertices.count {
                model.triangles.append(J3DWriter.Triangle(v: (vertex(mesh.vertices[i]), vertex(mesh.vertices[i + 1]), vertex(mesh.vertices[i + 2])), material: material))
                i += 3
            }
        }
        if baked > 0 { report.append("\(modelName): baked \(baked) mesh(es)' shadow maps into their vertex colours.") }
        // Each SRT0 as a BTK on the materials it moves (texture matrix 0, the only one a ported material has).
        model.animations = srts.compactMap { srt in
            MKDDFileConvert.btk(from: srt) { name, slot in animatedMaterials[name].flatMap { $0.slot == slot ? (name, 0) : nil } }
        }
        let skipped = srts.count - model.animations.count
        if skipped > 0 { report.append("\(modelName): \(skipped) texture animation(s) only move shadow maps or unused textures, so they aren't ported.") }
        return model
    }

    private static func model0Meshes(_ m: MDL0Model) -> [MDL0Mesh] { m.meshes }

    /// A lightmap's brightness (0-1) at a texture coordinate, wrapping.
    private static func sample(_ t: (pixels: [UInt8], width: Int, height: Int), _ uv: Vec2) -> Float {
        let x = Int((uv.x - uv.x.rounded(.down)) * Float(t.width)) % t.width
        let y = Int((uv.y - uv.y.rounded(.down)) * Float(t.height)) % t.height
        return Float(t.pixels[(max(0, y) * t.width + max(0, x)) * 4]) / 255
    }

    // MARK: Collision

    /// How far a wall reaches back from its face, retail wall strips are ~250-350 units across.
    static let wallDepth: Float = 300

    /// A Mario Kart Wii KCL as Double Dash collision, placed. Retail Double Dash collision is flat
    /// and tiles the ground without overlaps, walls included (flat strips beside the road; checked
    /// on the disc). So Wii floors keep their surface (`bcoFlag`) and flat Wii walls stay walls;
    /// along the foot of each upright Wii wall, the floor behind it, up to `wallDepth`, or to the
    /// wall's other face where there's road beyond, is cut out and made wall, and a flat wall
    /// strip goes behind it wherever that left floor uncovered. `floors` is what can be driven on.
    /// A ramp, boost or trickable surface is never cut into wall: a railing beside a trick ramp
    /// turned the ramp itself into wall.
    /// `choices` overrides the surface for KCL types with no direct Double Dash equivalent (see
    /// `unmatchedTypes`): KCL base type (or `trickableKey`) -> Double Dash surface, nil to leave
    /// those triangles out (for `trickableKey`, nil keeps each triangle's own surface).
    static func collision(_ kcl: KCLDocument, place: Placement, choices: [UInt16: UInt16?] = [:]) -> (triangles: [KCLTriangle], floors: [KCLTriangle], dropped: Int) {
        var floors: [KCLTriangle] = [], walls: [KCLTriangle] = [], upright: [(v: [Vec3], n: Vec3, flag: UInt16)] = []
        var keepFloor: [Bool] = []
        var dropped = 0
        for t in kcl.triangles {
            let a = place.apply(t.v0), b = place.apply(t.v1), c = place.apply(t.v2)
            let n = Vec3.cross(b - a, c - a)
            guard n.length > 0 else { continue }
            let steep = abs(n.y) < 0.3 * n.length
            let trickable = t.attribute & 0x2000 != 0
            var target = choices.keys.contains(t.attribute & 0x1F) ? choices[t.attribute & 0x1F]! : (wallFlag(forKCL: t.attribute) ?? bcoFlag(forKCL: t.attribute))
            if trickable, target != nil, let pick = choices[trickableKey], let pick { target = pick }
            if let pick = choices[upwardWallKey] ?? nil, isUpwardWall(t) { target = pick }
            guard let target else { dropped += 1; continue }
            if [0x02, 0x12].contains(target >> 8) {
                if steep { upright.append(([a, b, c], n, target)) } else if n.y > 0 { walls.append(KCLTriangle(v0: a, v1: b, v2: c, attribute: target)) }
            } else if !steep {
                floors.append(.facingUp(a, b, c, attribute: target))
                keepFloor.append(trickable || [0x07, 0x08, 0x09, 0x0D, 0x37, 0x47].contains(target >> 8))
            }
        }
        let groundDoc = KCLDocument()
        groundDoc.triangles = floors.map { KCLTriangle(v0: $0.v0, v1: $0.v1, v2: $0.v2, attribute: 0) }
        let ground = DriverPath.GroundQuery(groundDoc)

        // Wall feet: each upright wall's footprint, at the height of the floor in front of it
        // (KCL wall normals face the side karts hit them from).
        struct Foot { var p: Vec3, q: Vec3, normal: Vec3, depth: Float, flag: UInt16 }
        var feet: [Foot] = [], seen = Set<[Int32]>()
        for w in upright {
            let normal = Vec3(x: w.n.x, y: 0, z: w.n.z) * (1 / hypot(w.n.x, w.n.z))
            let along = Vec3(x: -normal.z, y: 0, z: normal.x)
            let v = w.v.sorted { Vec3.dot($0, along) < Vec3.dot($1, along) }
            guard Vec3.dot(v[2] - v[0], along) > 1 else { continue }
            let low = w.v.map(\.y).min()!, high = w.v.map(\.y).max()!
            func foot(_ e: Vec3, inward: Float) -> Vec3? {
                let s = e + normal * 20 + along * inward
                guard let y = ground.height(x: s.x, z: s.z, near: low), y > low - 150, y < high + 50 else { return nil }
                return Vec3(x: e.x, y: y, z: e.z)
            }
            guard let p = foot(v[0], inward: 20), let q = foot(v[2], inward: -20) else { continue }
            // A quad's two triangles share a footprint.
            guard seen.insert([p.x, p.z, q.x, q.z].map { Int32($0.rounded()) }).inserted else { continue }
            feet.append(Foot(p: p, q: q, normal: normal, depth: wallDepth, flag: w.flag))
        }
        func along(_ f: Foot) -> Vec3 { Vec3(x: -f.normal.z, y: 0, z: f.normal.x) }
        // One foot per straight run of wall, not per Wii triangle: a foot takes in any other on
        // its line (within 10 units and 10 degrees) that touches or overlaps it.
        var alive = [Bool](repeating: true, count: feet.count), byEnd: [SIMD2<Int32>: [Int]] = [:]
        func endKey(_ v: Vec3) -> SIMD2<Int32> { SIMD2(Int32((v.x / 100).rounded(.down)), Int32((v.z / 100).rounded(.down))) }
        for (i, f) in feet.enumerated() { for e in [f.p, f.q] { byEnd[endKey(e), default: []].append(i) } }
        for i in feet.indices where alive[i] {
            var grew = true
            while grew {
                grew = false
                let f = feet[i], a = along(f), length = Vec3.dot(f.q - f.p, a)
                var near = Set<Int>()
                for e in [f.p, f.q] { let k = endKey(e); for dx in -1...1 { for dz in -1...1 { near.formUnion(byEnd[k &+ SIMD2(Int32(dx), Int32(dz))] ?? []) } } }
                for j in near.sorted() where j != i && alive[j] {
                    let g = feet[j]
                    guard Vec3.dot(f.normal, g.normal) > 0.985, g.flag == f.flag,
                          abs(Vec3.dot(g.p - f.p, f.normal)) < 10, abs(Vec3.dot(g.q - f.p, f.normal)) < 10 else { continue }
                    let s0 = Vec3.dot(g.p - f.p, a), s1 = Vec3.dot(g.q - f.p, a)
                    guard min(s0, s1) <= length + 10, max(s0, s1) >= -10 else { continue }
                    let ends = [(0, f.p), (length, f.q), (s0, g.p), (s1, g.q)]
                    let lo = ends.min { $0.0 < $1.0 }!, hi = ends.max { $0.0 < $1.0 }!
                    func onLine(_ e: (Float, Vec3)) -> Vec3 { let v = f.p + a * e.0; return Vec3(x: v.x, y: e.1.y, z: v.z) }
                    feet[i].p = onLine(lo); feet[i].q = onLine(hi)
                    alive[j] = false; grew = true
                    for e in [feet[i].p, feet[i].q] { byEnd[endKey(e), default: []].append(i) }
                    break
                }
            }
        }
        feet = feet.indices.filter { alive[$0] }.map { feet[$0] }
        // Ends on different levels of a short wall would make a steep strip: level it.
        for i in feet.indices where abs(feet[i].q.y - feet[i].p.y) > Vec3.dot(feet[i].q - feet[i].p, along(feet[i])) {
            feet[i].p.y = (feet[i].p.y + feet[i].q.y) / 2; feet[i].q.y = feet[i].p.y
        }
        // A barrier with road on both sides reaches only to its other face.
        // ponytail: O(feet^2), a few thousand feet per retail track; bucket by XZ if it ever shows up in a profile.
        for i in feet.indices {
            for j in feet.indices where Vec3.dot(feet[i].normal, feet[j].normal) < -0.5 {
                let m = (feet[j].p + feet[j].q) * 0.5, d = m - feet[i].p
                let depth = -Vec3.dot(d, feet[i].normal), side = Vec3.dot(d, along(feet[i]))
                guard depth > 0, depth < feet[i].depth, side >= 0, side <= Vec3.dot(feet[i].q - feet[i].p, along(feet[i])), abs(m.y - feet[i].p.y) < 150 else { continue }
                feet[i].depth = max(depth, 50)
            }
        }

        // Floor behind each foot becomes wall.
        let cell: Float = 1000
        func cellKey(_ x: Float, _ z: Float) -> SIMD2<Int32> { SIMD2(gridCell(x, cell), gridCell(z, cell)) }
        func corners(_ f: Foot) -> [Vec3] { [f.p, f.q, f.q - f.normal * f.depth, f.p - f.normal * f.depth] }
        var footCells: [SIMD2<Int32>: [Int]] = [:]
        for (i, f) in feet.enumerated() {
            let c = corners(f), k0 = cellKey(c.map(\.x).min()!, c.map(\.z).min()!), k1 = cellKey(c.map(\.x).max()!, c.map(\.z).max()!)
            guard k1.x - k0.x < 256, k1.y - k0.y < 256 else { continue }
            for x in k0.x...k1.x { for z in k0.y...k1.y { footCells[SIMD2(x, z), default: []].append(i) } }
        }
        var drivable: [KCLTriangle] = []
        for (t, keep) in zip(floors, keepFloor) {
            if keep { drivable.append(t); continue }
            let k0 = cellKey(min(t.v0.x, t.v1.x, t.v2.x), min(t.v0.z, t.v1.z, t.v2.z)), k1 = cellKey(max(t.v0.x, t.v1.x, t.v2.x), max(t.v0.z, t.v1.z, t.v2.z))
            var near = Set<Int>()
            if (k1.x - k0.x + 1) * (k1.y - k0.y + 1) <= 4096 { for x in k0.x...k1.x { for z in k0.y...k1.y { near.formUnion(footCells[SIMD2(x, z)] ?? []) } } }
            var pieces = [t]
            for i in near.sorted() {
                let f = feet[i], a = along(f), length = Vec3.dot(f.q - f.p, a)
                let box = corners(f), lo = min(f.p.y, f.q.y) - 150, hi = max(f.p.y, f.q.y) + 150
                func hit(_ t: KCLTriangle) -> Bool { max(t.v0.y, t.v1.y, t.v2.y) > lo && min(t.v0.y, t.v1.y, t.v2.y) < hi && overlaps(t, box) }
                var outside = pieces.filter { !hit($0) }
                // One cut, along the wall's line; a piece behind it is wall if its middle is within
                // the wall's span and depth. The back edge and ends aren't cut: each cut multiplies
                // triangles, and cutting the back edge too doubles retail-sized files (where floor
                // continues past the wall's depth, the strip below overlaps it, off the track).
                let cut = pieces.filter(hit).map { split($0, at: f.p, normal: f.normal) }
                outside += cut.flatMap(\.above)
                for piece in cut.flatMap(\.below) {
                    let c = (piece.v0 + piece.v1 + piece.v2) * (1 / 3), s = Vec3.dot(c - f.p, a)
                    let y = f.p.y + (f.q.y - f.p.y) * min(1, max(0, s / max(length, 1)))
                    if s >= 0, s <= length, -Vec3.dot(c - f.p, f.normal) <= f.depth, abs(c.y - y) < 150 {
                        walls.append(KCLTriangle(v0: piece.v0, v1: piece.v1, v2: piece.v2, attribute: f.flag))
                    } else { outside.append(piece) }
                }
                pieces = outside
            }
            drivable += pieces
        }

        // Strips wherever the floor behind a wall didn't become wall.
        let cutDoc = KCLDocument()
        cutDoc.triangles = walls.map { KCLTriangle(v0: $0.v0, v1: $0.v1, v2: $0.v2, attribute: 0) }
        let cutWalls = DriverPath.GroundQuery(cutDoc)
        for f in feet {
            let samples = [0.1, 0.5, 0.9].map { f.p + (f.q - f.p) * Float($0) - f.normal * (f.depth / 2) }
            guard samples.contains(where: { s in cutWalls.height(x: s.x, z: s.z, near: s.y).map { abs($0 - s.y) >= 150 } ?? true }) else { continue }
            let c = corners(f)
            walls.append(.facingUp(c[0], c[1], c[2], attribute: f.flag))
            walls.append(.facingUp(c[0], c[2], c[3], attribute: f.flag))
        }
        return (drivable + walls, drivable, dropped)
    }

    /// Whether `t` and a convex quad overlap in XZ (separating axes; touching doesn't count).
    private static func overlaps(_ t: KCLTriangle, _ quad: [Vec3]) -> Bool {
        let tri = [t.v0, t.v1, t.v2]
        for poly in [tri, quad] {
            for i in poly.indices {
                let e = poly[(i + 1) % poly.count] - poly[i], axis = (x: -e.z, z: e.x)
                func span(_ p: [Vec3]) -> (Float, Float) { let d = p.map { $0.x * axis.x + $0.z * axis.z }; return (d.min()!, d.max()!) }
                let (a0, a1) = span(tri), (b0, b1) = span(quad), slack = 0.01 * hypot(axis.x, axis.z)
                if a1 <= b0 + slack || b1 <= a0 + slack { return false }
            }
        }
        return true
    }

    /// `t` cut by the upright plane through `o` with XZ normal `n`: the pieces behind it
    /// (dot(x - o, n) <= 0) and in front, each a fan of the clipped polygon, so winding is kept.
    /// Edges are cut in a fixed vertex order so neighbours sharing an edge get the same new vertex.
    /// A cut that would leave only a sliver on one side leaves `t` whole on the other.
    static func split(_ t: KCLTriangle, at o: Vec3, normal n: Vec3) -> (below: [KCLTriangle], above: [KCLTriangle]) {
        let v = [t.v0, t.v1, t.v2]
        let d = v.map { ($0.x - o.x) * n.x + ($0.z - o.z) * n.z }
        if d.allSatisfy({ $0 <= 0.01 }) { return ([t], []) }
        if d.allSatisfy({ $0 >= -0.01 }) { return ([], [t]) }
        var below: [Vec3] = [], above: [Vec3] = []
        for i in 0..<3 {
            let j = (i + 1) % 3
            if d[i] <= 0 { below.append(v[i]) }
            if d[i] >= 0 { above.append(v[i]) }
            if (d[i] < 0 && d[j] > 0) || (d[i] > 0 && d[j] < 0) {
                let (a, b, da, db) = (v[i].x, v[i].z) < (v[j].x, v[j].z) ? (v[i], v[j], d[i], d[j]) : (v[j], v[i], d[j], d[i])
                let x = a + (b - a) * (da / (da - db))
                below.append(x); above.append(x)
            }
        }
        func fan(_ p: [Vec3]) -> [KCLTriangle] {
            p.count < 3 ? [] : (1..<p.count - 1).compactMap { k in
                let tri = KCLTriangle(v0: p[0], v1: p[k], v2: p[k + 1], attribute: t.attribute, bcoCamera: t.bcoCamera, bcoSettings: t.bcoSettings)
                return Vec3.cross(tri.v1 - tri.v0, tri.v2 - tri.v0).length > 20 ? tri : nil // no needles (their normals are noise)
            }
        }
        let (b, a) = (fan(below), fan(above))
        // No slivers: a cut that would leave less than ~10x10 units on one side doesn't happen.
        func area(_ p: [KCLTriangle]) -> Float { p.reduce(0) { $0 + Vec3.cross($1.v1 - $1.v0, $1.v2 - $1.v0).length / 2 } }
        if area(b) < 100 { return ([], [t]) }
        if area(a) < 100 { return ([t], []) }
        return (b, a)
    }
}
