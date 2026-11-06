import Foundation

/// Minimal Wavefront .obj reader used to build KCL collision meshes (and, via `MDL0Writer`, a
/// real BRRES model) from an externally-modeled track/object. Vertex positions, texture
/// coordinates, faces, and `usemtl` material names are read; normals and the referenced .mtl
/// file's own contents are still not read *here* (KCL computes its own face/edge normals per
/// triangle and has no use for texturing at all; a companion .mtl is read separately, see
/// `loadMTLMaterials`, since it's a different file). The material *name* is kept so each
/// triangle can be tagged with which material produced it, letting a KCL import assign each one
/// its own collision flag (instead of one flat flag for the whole mesh) and a BRRES import know
/// which real texture (if any, via the .mtl) each triangle should be textured with.
nonisolated enum OBJImporter {
    struct Triangle {
        var v0: Vec3
        var v1: Vec3
        var v2: Vec3
        /// Texture coordinates for each vertex, in standard OBJ convention (V increases upward)
        ///, nil for a vertex whose face didn't reference a `vt` index (either the .obj has no
        /// texture coordinates at all, or that particular vertex didn't specify one). A consumer
        /// that needs UVs for every vertex (e.g. `MDL0Writer`) treats a nil as (0, 0).
        var uv0: Vec2?
        var uv1: Vec2?
        var uv2: Vec2?
        /// The `usemtl` name active when this face was read, if any.
        var materialName: String?
    }

    static func parse(_ text: String) -> [Triangle] {
        var positions: [Vec3] = []
        var texcoords: [Vec2] = []
        var triangles: [Triangle] = []
        var currentMaterial: String?

        text.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return }
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard let tag = parts.first else { return }

            if tag == "v", parts.count >= 4,
               let x = parseFloat(parts[1]), let y = parseFloat(parts[2]), let z = parseFloat(parts[3]) {
                positions.append(Vec3(x: x, y: y, z: z))
            } else if tag == "vt", parts.count >= 3, let u = parseFloat(parts[1]), let v = parseFloat(parts[2]) {
                texcoords.append(Vec2(x: u, y: v))
            } else if tag == "usemtl", parts.count >= 2 {
                currentMaterial = parts.dropFirst().joined(separator: " ")
            } else if tag == "f", parts.count >= 4 {
                var faceIndices: [Int] = []
                var faceUVIndices: [Int?] = []
                for token in parts.dropFirst() {
                    let comps = token.split(separator: "/", omittingEmptySubsequences: false)
                    guard let vertexToken = comps.first.map(String.init), var index = Int(vertexToken) else { continue }
                    if index < 0 { index = positions.count + index + 1 } // OBJ allows relative (negative) indices
                    faceIndices.append(index - 1) // OBJ indices are 1-based
                    if comps.count >= 2, var vtIndex = Int(comps[1]) {
                        if vtIndex < 0 { vtIndex = texcoords.count + vtIndex + 1 }
                        faceUVIndices.append(vtIndex - 1)
                    } else {
                        faceUVIndices.append(nil)
                    }
                }
                guard faceIndices.count >= 3, faceIndices.allSatisfy({ positions.indices.contains($0) }) else { return }
                func uv(_ i: Int) -> Vec2? {
                    guard faceUVIndices.indices.contains(i), let idx = faceUVIndices[i], texcoords.indices.contains(idx) else { return nil }
                    return texcoords[idx]
                }
                // Ear-clip rather than fan-triangulate: a plain fan (vertex 0 to every other pair)
                // is only correct for a convex polygon. Real exports include large, non-convex
                // n-gons (a Blender terrain patch can be a several-thousand-vertex ring), and
                // fanning those produces huge sliver triangles that cut straight across the whole
                // polygon, which then blow up any spatial structure built from them (KCL's
                // octree included, since one sliver's bounding box can cover most of the level).
                for (i, j, k) in Self.triangulate(faceIndices.map { positions[$0] }) {
                    triangles.append(Triangle(v0: positions[faceIndices[i]], v1: positions[faceIndices[j]], v2: positions[faceIndices[k]],
                                               uv0: uv(i), uv1: uv(j), uv2: uv(k),
                                               materialName: currentMaterial))
                }
            }
        }
        return triangles
    }

    /// Ear-clips a (possibly non-convex, possibly non-planar) polygon into triangles, returning
    /// each as a triple of indices into `polygon`. Projects onto the polygon's Newell-method
    /// average normal so a slightly non-planar real-world face still triangulates sanely, then
    /// runs standard 2D ear-clipping (repeatedly cutting off a convex vertex that contains no
    /// other vertex) using a doubly-linked list over the original indices, so removing an ear
    /// never requires renumbering the rest.
    private static func triangulate(_ polygon: [Vec3]) -> [(Int, Int, Int)] {
        let n = polygon.count
        guard n >= 3 else { return [] }
        if n == 3 { return [(0, 1, 2)] }

        var normal = Vec3()
        for i in 0..<n {
            let a = polygon[i], b = polygon[(i + 1) % n]
            normal.x += (a.y - b.y) * (a.z + b.z)
            normal.y += (a.z - b.z) * (a.x + b.x)
            normal.z += (a.x - b.x) * (a.y + b.y)
        }
        guard normal.length > 1e-9 else { return [] } // degenerate (collinear or zero-area) polygon
        normal = normal.normalized()
        let helper = abs(normal.x) < 0.9 ? Vec3(x: 1) : Vec3(y: 1)
        let tangent = Vec3.cross(normal, helper).normalized()
        let bitangent = Vec3.cross(normal, tangent)
        let points = polygon.map { (Vec3.dot($0, tangent), Vec3.dot($0, bitangent)) }

        func cross2(_ a: (Float, Float), _ b: (Float, Float), _ c: (Float, Float)) -> Float {
            (b.0 - a.0) * (c.1 - a.1) - (b.1 - a.1) * (c.0 - a.0)
        }
        var signedArea: Float = 0
        for i in 0..<n { let a = points[i], b = points[(i + 1) % n]; signedArea += a.0 * b.1 - b.0 * a.1 }
        let ccw = signedArea >= 0

        var prevOf = (0..<n).map { ($0 + n - 1) % n }
        var nextOf = (0..<n).map { ($0 + 1) % n }
        func isReflex(_ v: Int) -> Bool {
            let cr = cross2(points[prevOf[v]], points[v], points[nextOf[v]])
            return ccw ? cr < 0 : cr > 0
        }
        var reflex = Set((0..<n).filter(isReflex))

        var triangles: [(Int, Int, Int)] = []
        triangles.reserveCapacity(n - 2)
        var remaining = n
        var cur = 0
        var sinceLastEar = 0
        while remaining > 3, sinceLastEar <= remaining {
            let p = prevOf[cur], nx = nextOf[cur]
            var isEar = !reflex.contains(cur)
            if isEar {
                let a = points[p], b = points[cur], c = points[nx]
                for idx in reflex where idx != p && idx != cur && idx != nx {
                    let d1 = cross2(points[idx], a, b), d2 = cross2(points[idx], b, c), d3 = cross2(points[idx], c, a)
                    let outside = (d1 < 0 || d2 < 0 || d3 < 0) && (d1 > 0 || d2 > 0 || d3 > 0)
                    if !outside { isEar = false; break }
                }
            }
            if isEar {
                triangles.append((p, cur, nx))
                nextOf[p] = nx
                prevOf[nx] = p
                remaining -= 1
                for v in [p, nx] {
                    let nowReflex = isReflex(v)
                    if nowReflex { reflex.insert(v) } else { reflex.remove(v) }
                }
                cur = nx
                sinceLastEar = 0
            } else {
                cur = nx
                sinceLastEar += 1 // no valid ear found this lap: self-intersecting input, stop rather than loop forever
            }
        }
        if remaining == 3 { triangles.append((cur, nextOf[cur], nextOf[nextOf[cur]])) }
        return triangles
    }

    /// Assigns each `usemtl` material a collision flag guessed from its name, or its texture's file
    /// name when the material name says nothing (see `guessFlag`). This used to hand out 0, 1, 2,
    /// ... in first-seen order, which silently made the second material slippery sand, the third
    /// off-road, the 11th solid-fall, the 13th a wall and the 17th a fall boundary. Triangles with
    /// no material get `defaultAttribute`.
    static func assignFlagsByMaterial(_ triangles: [Triangle], materials: [String: MTLMaterial] = [:], defaultAttribute: UInt16 = 0) -> [UInt16] {
        var flagForMaterial: [String: UInt16] = [:]
        return triangles.map { tri in
            guard let name = tri.materialName else { return defaultAttribute }
            if let existing = flagForMaterial[name] { return existing }
            let flag = guessFlag(materialName: name, textureName: materials[name]?.diffuseTexturePath)
            flagForMaterial[name] = flag
            return flag
        }
    }

    /// A KCL flag (base type | variant << 5) from a material's name, or, when that names no
    /// surface ("Material.001"), its texture's file name, falling back to plain road, the one
    /// surface that's always safe to drive on. An explicit "0x83" in a name is used as-is.
    static func guessFlag(materialName: String, textureName: String? = nil) -> UInt16 {
        let texture = textureName.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
        for name in [materialName, texture].compactMap({ $0 }) {
            if let flag = flag(fromName: name) { return flag }
        }
        return 0x0000
    }

    /// Words of a name: camelCase split, any non-alphanumeric a separator, lower-cased, with
    /// common two-word terms joined ("off road" -> "offroad").
    static func surfaceWords(_ name: String) -> [String] {
        var spaced = ""
        var previous: Character?
        for c in name {
            if let p = previous, p.isLowercase, c.isUppercase { spaced.append(" ") }
            spaced.append(c.isLetter || c.isNumber ? c : " ")
            previous = c
        }
        var text = " " + spaced.lowercased().split(separator: " ").joined(separator: " ") + " "
        for (a, b) in [(" off road ", " offroad "), (" half pipe ", " halfpipe "), (" jump pad ", " jumppad "), (" boost ramp ", " boostramp "),
                       (" item road ", " itemroad "), (" item wall ", " itemwall "), (" solid fall ", " solidfall "), (" moving water ", " movingwater "),
                       (" moving road ", " movingroad "), (" fall boundary ", " fall "), (" out of bounds ", " oob "), (" dash panel ", " boost "), (" boost pad ", " boost ")] {
            while text.contains(a) { text = text.replacingOccurrences(of: a, with: b) }
        }
        return text.split(separator: " ").map(String.init)
    }

    /// Base surface rules, most specific first: (words that must all appear, any of each
    /// alternative group, then base type).
    private static let surfaceRules: [([[String]], Int)] = [
        ([["invis", "invisible"]], 0x0D),
        ([["itemwall"]], 0x0E),
        ([["wall", "walls", "fence", "barrier", "rail", "railing", "cliff"]], 0x0C),
        ([["halfpipe"]], 0x13),
        ([["cannon"]], 0x11),
        ([["solidfall"]], 0x0A),
        ([["movingwater", "current", "stream"]], 0x0B),
        ([["movingroad", "conveyor", "escalator", "belt"]], 0x15),
        ([["weak"], ["offroad"]], 0x02),
        ([["heavy"], ["offroad"]], 0x04),
        ([["offroad"]], 0x03),
        ([["boostramp", "ramp", "trick"]], 0x07),
        ([["jumppad", "jump", "bounce", "bouncy"]], 0x08),
        ([["boost", "dash", "speed"]], 0x06),
        ([["itemroad"]], 0x09),
        ([["sticky"]], 0x16),
        ([["lava"]], 0x10),
        ([["fall", "void", "death", "kill", "abyss", "oob", "pit"]], 0x10),
        ([["ice", "icy"]], 0x05),
        ([["slippery", "slip"]], 0x01),
        ([["grass", "flowers", "flower", "bush", "hay"]], 0x03),
        ([["sand", "beach"]], 0x02),
        ([["dirt", "mud", "gravel", "soil", "earth"]], 0x02),
        ([["water", "river", "lake", "sea", "ocean"]], 0x10),
        ([["road", "asphalt", "tarmac", "track", "street", "path", "concrete", "brick", "stone", "floor", "ground",
           "wood", "wooden", "metal", "grate", "carpet", "glass", "snow"]], 0x00),
    ]

    /// The flag a name describes, or nil when it names no surface.
    static func flag(fromName name: String) -> UInt16? {
        // An explicit flag, as KCL tools name their materials ("0x83", "kcl_0x0003").
        if let r = name.range(of: #"0x[0-9a-fA-F]{1,4}"#, options: .regularExpression), let v = UInt16(name[r].dropFirst(2), radix: 16) { return v }
        let words = surfaceWords(name)
        guard let (_, base) = surfaceRules.first(where: { rule in rule.0.allSatisfy { group in group.contains { words.contains($0) } } }) else { return nil }
        // The variant: the documented one whose name shares the most of the remaining words
        // ("grass weak off road" -> weak off-road's "Grass, Darker GFX"); ties go to the first.
        // Only the generic surface words are set aside; descriptive ones ("grass", "wood",
        // "dirt", "lava") pick the variant.
        let generic: Set<String> = ["road", "offroad", "weak", "heavy", "wall", "walls", "fall", "boost", "ramp", "boostramp", "pad", "jumppad",
                                    "itemroad", "itemwall", "solidfall", "invis", "invisible", "halfpipe", "movingroad", "movingwater", "kcl", "flag", "material", "mat"]
        let rest = words.filter { !generic.contains($0) }
        var variant = 0
        if let names = kclVariants(forBase: base), !rest.isEmpty {
            var best = 0
            for (i, v) in names.enumerated() {
                let vw = surfaceWords(v).filter { !["with", "without", "gfx", "unused", "and", "as"].contains($0) }
                let score = rest.filter { w in w.count >= 3 && vw.contains { $0 == w || ($0.count >= 4 && w.count >= 4 && ($0.hasPrefix(w) || w.hasPrefix($0))) } }.count
                if score > best { best = score; variant = i }
            }
        }
        return UInt16(base) | UInt16(variant) << 5
    }

    /// The `mtllib` filename(s) an .obj references, in the order they appear, almost always just
    /// one, but the format allows several.
    static func mtlLibraryNames(in objText: String) -> [String] {
        var names: [String] = []
        objText.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("mtllib ") else { return }
            // A filename can contain spaces (`mtllib Test Model.mtl`, as SketchUp exports), so the
            // rest of the line is one name, splitting on spaces looked for "Test" and
            // "Model.mtl", found neither, and quietly left the model with no materials at all.
            // The format does allow several libraries on one line, but only ever space-separated,
            // which is ambiguous with a spaced filename; the single-name reading is the common
            // case by far, so fall back to the split only if the whole line isn't a real file.
            let whole = String(trimmed.dropFirst("mtllib ".count)).trimmingCharacters(in: .whitespaces)
            guard !whole.isEmpty else { return }
            names.append(whole)
            names.append(contentsOf: whole.split(separator: " ").map(String.init))
        }
        return names
    }

    /// One `usemtl` material's info as read from a Wavefront .mtl file, just the two properties
    /// this app has any use for. Everything else a real .mtl can carry (specular/shininess,
    /// transparency, bump/normal maps, illumination model, ...) isn't read.
    nonisolated struct MTLMaterial {
        var diffuseColor: (r: Float, g: Float, b: Float)?
        /// The path exactly as written after `map_Kd`, relative to the .mtl's own folder, the
        /// near-universal convention real .obj/.mtl exporters use. Resolving it to an actual file
        /// (and loading the image) is the caller's job, see `loadMTLMaterials`.
        var diffuseTexturePath: String?
    }

    /// Parses a .mtl file's text into one `MTLMaterial` per `newmtl` block.
    static func parseMTL(_ text: String) -> [String: MTLMaterial] {
        var out: [String: MTLMaterial] = [:]
        var currentName: String?
        text.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return }
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard let tag = parts.first else { return }
            if tag == "newmtl", parts.count >= 2 {
                let name = parts.dropFirst().joined(separator: " ")
                currentName = name
                out[name] = MTLMaterial()
            } else if tag == "Kd", parts.count >= 4, let name = currentName,
                      let r = parseFloat(parts[1]), let g = parseFloat(parts[2]), let b = parseFloat(parts[3]) {
                out[name]?.diffuseColor = (r, g, b)
            } else if tag.lowercased() == "map_kd", parts.count >= 2, let name = currentName {
                // Everything after the tag is the path, it can legitimately contain spaces (a
                // SketchUp export writes e.g. `map_Kd Test Model/road.png`), so taking only the
                // last token silently pointed every such material at a file that doesn't exist.
                // Real exporters may prefix the path with options this app has no use for
                // ("-o 0 0 0 filename.png"); drop each leading `-flag value...` run instead.
                var tokens = Array(parts.dropFirst())
                while let first = tokens.first, first.hasPrefix("-") {
                    tokens.removeFirst()
                    while let next = tokens.first, Float(next) != nil { tokens.removeFirst() }
                }
                let path = tokens.joined(separator: " ")
                if !path.isEmpty { out[name]?.diffuseTexturePath = path }
            }
        }
        return out
    }

    /// Convenience for the common case of having the .obj's own file URL: finds and parses
    /// whichever `mtllib` file(s) it references, sitting next to it on disk (the near-universal
    /// convention), silently returns nothing for a name that isn't actually found there, since
    /// plenty of real .obj exports have no companion .mtl at all, which isn't an error here.
    static func loadMTLMaterials(objText: String, objURL: URL) -> [String: MTLMaterial] {
        var out: [String: MTLMaterial] = [:]
        let dir = objURL.deletingLastPathComponent()
        for name in mtlLibraryNames(in: objText) {
            guard let mtlText = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) else { continue }
            out.merge(parseMTL(mtlText)) { _, new in new }
        }
        return out
    }
}
