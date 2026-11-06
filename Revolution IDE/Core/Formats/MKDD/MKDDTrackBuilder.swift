import AppKit

/// Builds Mario Kart: Double Dash!! course archives: a course model, collision, course data,
/// minimap and (optionally) sky, packaged as the slot's main `.arc` (see `MKDDSlots`; Hot Swap
/// installs it over the slot's other archives too).
nonisolated enum MKDDTrackBuilder {
    /// Geometry and textures ready for `J3DWriter`.
    struct Model {
        var triangles: [J3DWriter.Triangle] = []
        var materials: [J3DWriter.Material] = []
        var textures: [GCTextures.Source] = []
        /// Each material's Double Dash surface type, for collision.
        var surfaces: [UInt16] = []
        /// Texture animations (BTK), driving `animated` materials by name.
        var animations: [J3DAnimation.Animation] = []
    }

    struct Output {
        var archives: [(name: String, data: Data)]
        var report: [String]
    }

    /// Retail ceilings (see `GCTextures`): the busiest retail course has 15,317 triangles.
    static let retailMaxTriangles = 15_317

    // MARK: Surfaces

    /// A Double Dash surface flag (type << 8 | variant) guessed from a material's name, like the
    /// KCL import does for Mario Kart Wii. Editable afterwards in the collision editor.
    static func surface(forMaterial name: String) -> UInt16 {
        let n = name.lowercased()
        func has(_ words: String...) -> Bool { words.contains { n.contains($0) } }
        if has("boost", "dash") { return 0x0800 }
        if has("ramp", "jump") { return 0x0700 }
        if has("wall", "fence", "rail", "barrier") { return 0x0200 }
        if has("water", "lava", "void", "fall", "death", "kill") { return 0x0A00 }
        if has("ice", "snow") { return 0x0400 }
        if has("sand", "dirt", "mud", "gravel") { return 0x0C00 }
        if has("grass", "offroad", "off_road") { return 0x0300 }
        return 0x0100 // road
    }

    // MARK: From a model file

    /// A course or sky model from an `.obj`/`.dae` (its `.mtl` textures included).
    static func model(fromFile url: URL, scale: Float = 1) throws -> Model {
        let (text, objURL) = try ModelFile.objSource(url)
        let tris = OBJImporter.parse(text)
        guard !tris.isEmpty else { throw WSError.badStructure("\(url.lastPathComponent) has no triangles.") }
        let mtl = OBJImporter.loadMTLMaterials(objText: text, objURL: objURL)
        let folder = objURL.deletingLastPathComponent()
        var model = Model()
        var materialIndex: [String: Int] = [:], textureIndex: [String: Int] = [:]
        func material(_ name: String?) -> Int {
            let key = name ?? "material"
            if let i = materialIndex[key] { return i }
            var tex: Int?
            if let path = mtl[key]?.diffuseTexturePath {
                if let t = textureIndex[path] { tex = t } else if let image = NSImage(contentsOf: folder.appendingPathComponent(path)),
                    let rep = image.representations.first, rep.pixelsWide > 0,
                    let rgba = ImageUtil.rgba(from: image, width: rep.pixelsWide, height: rep.pixelsHigh) {
                    textureIndex[path] = model.textures.count
                    tex = model.textures.count
                    model.textures.append(GCTextures.Source(name: sanitized((path as NSString).deletingPathExtension), rgba: rgba, width: rep.pixelsWide, height: rep.pixelsHigh))
                }
            }
            let hasAlpha = tex.map { t in stride(from: 3, to: model.textures[t].rgba.count, by: 4).contains { model.textures[t].rgba[$0] < 128 } } ?? false
            model.materials.append(J3DWriter.Material(name: sanitized(key), texture: tex, cull: 0, transparency: hasAlpha ? .alphaTest : .opaque))
            model.surfaces.append(surface(forMaterial: key))
            materialIndex[key] = model.materials.count - 1
            return model.materials.count - 1
        }
        // OBJ diffuse colour (no texture) becomes the vertex colour, as Double Dash shades untextured surfaces.
        for t in tris {
            let m = material(t.materialName)
            let kd = mtl[t.materialName ?? ""]?.diffuseColor ?? (1, 1, 1)
            let color: [UInt8] = model.materials[m].texture == nil
                ? [UInt8(clamping: Int(kd.r * 255)), UInt8(clamping: Int(kd.g * 255)), UInt8(clamping: Int(kd.b * 255)), 255] : [255, 255, 255, 255]
            // OBJ's V runs up the image, GX's down.
            func v(_ p: Vec3, _ uv: Vec2?) -> J3DWriter.Vertex {
                J3DWriter.Vertex(position: p * scale, color: color, uv: uv.map { Vec2(x: $0.x, y: 1 - $0.y) } ?? Vec2())
            }
            model.triangles.append(J3DWriter.Triangle(v: (v(t.v0, t.uv0), v(t.v1, t.uv1), v(t.v2, t.uv2)), material: m))
        }
        return model
    }

    // MARK: Packaging

    /// Writes the slot's archives from a finished course: model, optional sky, collision
    /// triangles (with Double Dash flags), course data and the minimap rectangle to draw into
    /// (the slot's own, from its `main.dol`, when known).
    static func package(slot: MKDDSlots.Slot, course: Model, sky: Model?, collision: [KCLTriangle], bol: KMPDocument,
                        minimap: MKDDSlots.Minimap?) throws -> Output {
        var report: [String] = []
        let stem = slot.fileStem
        let (courseTextures, texReport) = GCTextures.optimize(course.textures, budget: GCTextures.courseBudget)
        report += texReport
        let courseBMD = try J3DWriter.bmd(triangles: course.triangles, materials: course.materials, textures: courseTextures)
        report.append("Course model: \(course.triangles.count) triangles, \(course.materials.count) materials, \(courseBMD.count / 1024) KB.")
        if course.triangles.count > retailMaxTriangles {
            report.append("Warning: more triangles than any retail Double Dash course (\(retailMaxTriangles)), expect slowdown, especially in split-screen.")
        }
        var files: [(String, Data)] = [("\(stem)_course.bmd", courseBMD)]
        // Retail names: <stem>_course.btk, _course_02.btk, _course_03.btk; one <stem>_sky.btk.
        func animationFiles(_ anims: [J3DAnimation.Animation], names: [String], what: String) throws {
            for (a, name) in zip(anims, names) { files.append((name, try J3DAnimation.serializeBTK(a))) }
            if anims.count > names.count { report.append("\(what): \(anims.count - names.count) texture animation(s) left out (retail courses use at most \(names.count)).") }
        }
        try animationFiles(course.animations, names: ["\(stem)_course.btk", "\(stem)_course_02.btk", "\(stem)_course_03.btk"], what: "Course model")
        if !course.animations.isEmpty { report.append("Course model: \(min(3, course.animations.count)) texture animation(s), \(course.materials.filter(\.animated).count) animated material(s).") }
        if let sky {
            let (skyTextures, skyReport) = GCTextures.optimize(sky.textures, budget: GCTextures.skyBudget, maxSize: 512)
            report += skyReport.map { "Sky " + $0 }
            files.append(("\(stem)_sky.bmd", try J3DWriter.bmd(triangles: sky.triangles, materials: sky.materials, textures: skyTextures, jointName: "VRcorn")))
            try animationFiles(sky.animations, names: ["\(stem)_sky.btk"], what: "Sky")
        }
        guard !collision.isEmpty else { throw WSError.badStructure("The course has no collision.") }
        files.append(("\(stem)_course.bco", BCO.build(collision)))
        guard let bolSource = bol.bolSource else { throw WSError.badStructure("The course data isn't a Double Dash course file.") }
        // mkdd-track-editor's checks for what makes the game freeze or crash.
        for problem in BOL.problems(bol) { report.append("Course data: " + problem) }
        files.append(("\(stem)_course.bol", BOL.serialize(bol, source: bolSource)))

        // Minimap: the driveable surface in the slot's own rectangle.
        let mapTris = collision.filter { MKDDMinimap.onMap(bcoFlag: $0.attribute) }.map { ($0.v0, $0.v1, $0.v2) }
        let rect = minimap ?? MKDDMinimap.fit(mapTris)
        if minimap == nil { report.append("Minimap: drawn to fit the course, the slot's rectangle wasn't read from a disc, so the markers on it may not line up in-game.") }
        else if !mapTris.isEmpty {
            let xs = mapTris.flatMap { [$0.0.x, $0.1.x, $0.2.x] }, zs = mapTris.flatMap { [$0.0.z, $0.1.z, $0.2.z] }
            let lo = (min(rect.corner1.x, rect.corner2.x), min(rect.corner1.y, rect.corner2.y)), hi = (max(rect.corner1.x, rect.corner2.x), max(rect.corner1.y, rect.corner2.y))
            if xs.min()! < lo.0 || xs.max()! > hi.0 || zs.min()! < lo.1 || zs.max()! > hi.1 {
                report.append("Minimap: parts of the course fall outside \(slot.title)'s map area (X \(Int(lo.0))...\(Int(hi.0)), Z \(Int(lo.1))...\(Int(hi.1))) and won't show on it. Scale or move the course to fit, or pick a slot with a larger area.")
            }
        }
        let mapRGBA = MKDDMinimap.render(triangles: mapTris, minimap: rect)
        let mapTexture = J3DWriter.Texture(name: "\(stem)_map", format: .ia4, width: MKDDMinimap.width, height: MKDDMinimap.height,
                                           encoded: TextureCodec.encode(rgba: mapRGBA, width: MKDDMinimap.width, height: MKDDMinimap.height, format: .ia4) ?? Data(),
                                           wrapS: 0, wrapT: 0, hasAlpha: true)
        files.append(("\(stem)_map.bti", J3DWriter.bti(mapTexture)))

        func archive(root rootName: String) -> Data {
            let root = U8Node(name: rootName, isDirectory: true)
            root.isRARC = true
            for (name, data) in files {
                let node = U8Node(name: name, isDirectory: false, data: data)
                node.parent = root
                root.children.append(node)
            }
            return RARC.serialize(root)
        }
        // One archive, the slot's main one: Hot Swap installs it over every archive the slot loads
        // (multiplayer, Luigi Circuit's 50cc), renamed for each (`HotSwapTargets.renamedCourse`).
        let main = slot.archives[0]
        let archives = [(main.name, archive(root: main.root))]
        report.append("Wrote \(main.name) (\(archives[0].1.count / 1024) KB) for \(slot.title)" + (slot.archives.count > 1 ? "; Hot Swap also installs it as \(slot.archives.dropFirst().map(\.name).joined(separator: ", "))." : "."))
        return Output(archives: archives, report: report)
    }

    /// A new course from model files: the course model doubles as its collision (surfaces from
    /// material names), with a start point on the road and an otherwise empty course file to
    /// fill in in the course-data editor.
    static func newCourse(slot: MKDDSlots.Slot, courseModel: URL, skyModel: URL?, scale: Float, minimap: MKDDSlots.Minimap?, musicID: UInt8) throws -> Output {
        let course = try model(fromFile: courseModel, scale: scale)
        let sky = try skyModel.map { try model(fromFile: $0, scale: scale) }
        // Collision: every triangle whose material isn't cut-out foliage-like transparency.
        let collision = course.triangles.compactMap { t -> KCLTriangle? in
            guard course.materials[t.material].transparency != .translucent else { return nil }
            return KCLTriangle(v0: t.v.0.position, v1: t.v.1.position, v2: t.v.2.position, attribute: course.surfaces[t.material])
        }
        let road = collision.filter { $0.attribute >> 8 == 0x01 }
        if slot.battle {
            // A battle stage: retail's 8 per-player starts, ring centred on the arena's floor and
            // sized to it, each start dropped onto the nearest floor.
            let bol = BOL.battleTemplate(musicID: musicID)
            let floor = road.isEmpty ? collision : road
            let pts = floor.flatMap { [$0.v0, $0.v1, $0.v2] }
            if let minX = pts.map(\.x).min(), let maxX = pts.map(\.x).max(), let minZ = pts.map(\.z).min(), let maxZ = pts.map(\.z).max() {
                let cx = (minX + maxX) / 2, cz = (minZ + maxZ) / 2, k = min(1, 0.35 * min(maxX - minX, maxZ - minZ) / 3000)
                for i in bol.ktpt.indices {
                    let p = bol.ktpt[i].position
                    let x = cx + p.x * k, z = cz + p.z * k
                    func flat(_ t: KCLTriangle) -> Float { let c = (t.v0 + t.v1 + t.v2) * (1 / 3); return (c.x - x) * (c.x - x) + (c.z - z) * (c.z - z) }
                    let nearest = floor.min { flat($0) < flat($1) }
                    let y = nearest.map { ($0.v0.y + $0.v1.y + $0.v2.y) / 3 } ?? 0
                    bol.ktpt[i].position = Vec3(x: x, y: y + 10, z: z)
                }
            }
            bol.came.append(MKWiiToMKDD.paradeCamera())
            var out = try package(slot: slot, course: course, sky: sky, collision: collision, bol: bol, minimap: minimap)
            out.report.insert("Next: open \(slot.archive).arc, check the 8 start points in \(slot.fileStem)_course.bol, add item boxes and use Make Testable; check surfaces in the collision editor.", at: 0)
            return out
        }
        let bol = BOL.newDocument(musicID: musicID)
        // Start on the road triangle nearest the road's middle, facing +Z.
        if let pick = road.isEmpty ? collision.first : {
            let c = road.reduce(Vec3()) { $0 + ($1.v0 + $1.v1 + $1.v2) * (1 / 3) } * (1 / Float(road.count))
            return road.min { ($0.v0 - c).length < ($1.v0 - c).length }
        }() {
            let p = (pick.v0 + pick.v1 + pick.v2) * (1 / 3)
            bol.ktpt = [KTPTEntry(position: Vec3(x: p.x, y: p.y + 10, z: p.z), rotation: Vec3(), playerIndex: -1)]
            // An intro shot, and the parade camera every retail course ends its list with.
            MKWiiToMKDD.addIntroCamera(to: bol, start: bol.ktpt[0].position, yawDegrees: 0, scale: 1)
        }
        bol.came.append(MKWiiToMKDD.paradeCamera())
        var out = try package(slot: slot, course: course, sky: sky, collision: collision, bol: bol, minimap: minimap)
        out.report.insert("Next: open \(slot.archive).arc, edit \(slot.fileStem)_course.bol (enemy route, checkpoints, respawn points, cameras, item boxes) and use Make Testable; check surfaces in the collision editor.", at: 0)
        return out
    }

    private static func sanitized(_ s: String) -> String {
        let c = String(s.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
        return c.isEmpty ? "material" : c
    }
}
