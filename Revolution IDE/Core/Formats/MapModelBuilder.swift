import Foundation

/// Builds a Mario Kart Wii `map_model.brres`, the flat overhead silhouette drawn on the
/// minimap, out of an existing course model.
///
/// A map model is the course with almost everything thrown away: only the surfaces worth showing
/// on a minimap (the road, usually, not the scenery, walls or sky) and no real texturing, just a
/// flat fill. Picking those surfaces out by hand in a model editor is tedious, but in practice
/// they line up with which *texture* a mesh uses, so this selects by texture instead: every mesh
/// whose texture the user left switched on is kept, every other mesh is dropped, and all the
/// survivors are flattened to one plain white fill.
///
/// Retail's own `map_model.brres` carries no texture at all, no TEX0, no UVs, no TextureLinks,
/// not even Normals, just a Colors section and an untextured material (confirmed against the
/// disc's `beginner_course.szs`: `nTex=0`). This builder matches that: white comes from the
/// material's own flat TEV colour, the same untextured path `MDL0Writer` already uses for a
/// `.mtl` group with no `map_Kd`.
///
/// Geometry is re-emitted through `MDL0Writer` rather than spliced out of the source MDL0. That
/// keeps this free of any new assumptions about the format, it reuses the one writer whose
/// output is already checked against retail files (see `Tests/MDL0WriterCheck`).
nonisolated enum MapModelBuilder {
    /// One toggleable entry in the Create Map sheet.
    struct TextureOption: Identifiable, Hashable {
        /// `nil` for the meshes that carry no texture at all, they still need a switch, or
        /// there would be no way to include or exclude them.
        var textureName: String?
        var meshCount: Int
        var triangleCount: Int

        var id: String { textureName ?? "\u{0}untextured" }
        var displayName: String { textureName ?? "(no texture)" }
    }

    /// A single mesh can exceed what one MDL0 mesh can index, so oversized groups are split.
    /// `MDL0Writer` addresses vertices with 16-bit indices and refuses to build above that.
    private static var maxTrianglesPerMesh: Int { MDL0Writer.maxVerticesPerMesh / 3 }

    /// What the source model offers to switch on or off, in the order its meshes draw.
    /// Returns nil when the file has no MDL0 this app can read geometry out of.
    static func options(inBRRES data: Data) -> [TextureOption]? {
        guard let (_, meshes) = modelAndMeshes(in: data) else { return nil }
        var order: [String?] = []
        var meshCounts: [String: Int] = [:]
        var triangleCounts: [String: Int] = [:]
        for mesh in meshes {
            let key = TextureOption(textureName: mesh.textureName, meshCount: 0, triangleCount: 0).id
            if meshCounts[key] == nil { order.append(mesh.textureName) }
            meshCounts[key, default: 0] += 1
            triangleCounts[key, default: 0] += mesh.vertices.count / 3
        }
        return order.map { name in
            let key = TextureOption(textureName: name, meshCount: 0, triangleCount: 0).id
            return TextureOption(textureName: name, meshCount: meshCounts[key] ?? 0,
                                 triangleCount: triangleCounts[key] ?? 0)
        }
    }

    enum BuildError: LocalizedError {
        case noReadableModel
        case nothingSelected
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .noReadableModel:
                return "This .brres has no 3D model whose geometry this app can read, so there's nothing to build a map from."
            case .nothingSelected:
                return "No textures are switched on, so the map model would be empty. Leave at least one on."
            case .writeFailed:
                return "Couldn't build the map model's geometry."
            }
        }
    }

    /// The finished `map_model.brres` bytes: the kept meshes' geometry, flattened to one plain
    /// white, untextured fill, no TEX0, matching retail.
    ///
    /// Merged into as few groups (materials/meshes) as the geometry actually needs, rather than one
    /// group per source texture, every real retail `map_model.brres` (confirmed across the disc)
    /// is exactly one mesh/one material, however many textures the course model it was built from
    /// uses. A prior version of this kept one group per kept texture (since that's how the course
    /// model itself is organized), which produced a correctly-structured but many-mesh/many-material
    /// file unlike anything retail ships, a real, if unconfirmed-in-isolation, suspect for
    /// "the minimap doesn't appear in game" reports, since the game's minimap renderer may not be
    /// as tolerant of an unusual multi-material map model as the general course renderer is.
    static func build(fromBRRES data: Data, keeping selected: Set<String>, modelName: String) throws -> Data {
        try build(fromBRRES: data, shades: Dictionary(uniqueKeysWithValues: selected.map { ($0, UInt8(255)) }), modelName: modelName)
    }

    /// `shades` maps each kept texture option's id to its grey level on the minimap (255 = the
    /// normal white fill; lower = darker, like the shaded areas on retail Castle/Rainbow/Treehouse
    /// minimaps). Options missing from it are left out.
    static func build(fromBRRES data: Data, shades: [String: UInt8], modelName: String) throws -> Data {
        let (triangles, triangleShades) = try shadedTriangles(fromBRRES: data, shades: shades)
        return try build(triangles: triangles, shades: triangleShades, modelName: modelName)
    }

    /// Every option's triangles, keyed by `TextureOption.id`, what the minimap editor previews.
    static func trianglesByOption(inBRRES data: Data) -> [String: [OBJImporter.Triangle]] {
        guard let (_, meshes) = modelAndMeshes(in: data) else { return [:] }
        var out: [String: [OBJImporter.Triangle]] = [:]
        for mesh in meshes {
            out[TextureOption(textureName: mesh.textureName, meshCount: 0, triangleCount: 0).id, default: []]
                .append(contentsOf: triangles(from: mesh))
        }
        return out
    }

    /// The kept triangles and each one's shade.
    static func shadedTriangles(fromBRRES data: Data, shades: [String: UInt8]) throws -> ([OBJImporter.Triangle], [UInt8]) {
        guard let (_, meshes) = modelAndMeshes(in: data) else { throw BuildError.noReadableModel }
        var allTriangles: [OBJImporter.Triangle] = []
        var allShades: [UInt8] = []
        for mesh in meshes {
            let key = TextureOption(textureName: mesh.textureName, meshCount: 0, triangleCount: 0).id
            guard let shade = shades[key] else { continue }
            let tris = self.triangles(from: mesh)
            allTriangles.append(contentsOf: tris)
            allShades.append(contentsOf: repeatElement(shade, count: tris.count))
        }
        return (allTriangles, allShades)
    }

    /// The same minimap model from loose triangles, also what an `.obj` destined for
    /// `map_model.brres` goes through (see `OBJToBRRES.convert`), so both paths get the marker
    /// bones and retail map styling rather than an ordinary course-style model.
    static func build(triangles allTriangles: [OBJImporter.Triangle], shades: [UInt8]? = nil, modelName: String) throws -> Data {
        let mdl0 = try model(triangles: allTriangles, shades: shades, modelName: modelName)
        let doc = BRRESDocument()
        doc.resources.append(BRRESResource(name: modelName, folderName: "3DModels(NW4R)",
                                           data: mdl0.data, stringReferences: mdl0.stringReferences))
        return doc.serialize()
    }

    /// Just the map MDL0 (names left for the containing BRRES to resolve), for callers that put
    /// it into a document of their own.
    static func model(triangles allTriangles: [OBJImporter.Triangle], shades: [UInt8]? = nil, modelName: String) throws -> MDL0Writer.Built {
        guard !allTriangles.isEmpty else { throw BuildError.nothingSelected }

        var groups: [MDL0Writer.Group] = []
        for chunk in stride(from: 0, to: allTriangles.count, by: maxTrianglesPerMesh) {
            let slice = Array(allTriangles[chunk..<min(chunk + maxTrianglesPerMesh, allTriangles.count)])
            groups.append(MDL0Writer.Group(
                material: MDL0Writer.MaterialSpec(name: chunk == 0 ? modelName : "\(modelName)_\(chunk / maxTrianglesPerMesh)",
                                                  color: (1, 1, 1),
                                                  textureName: nil),
                triangles: slice,
                // All white is the plain single-entry fill retail's unshaded maps use.
                triangleShades: shades.flatMap { s in s.allSatisfy { $0 == 255 } ? nil : Array(s[chunk..<min(chunk + maxTrianglesPerMesh, s.count)]) }))
        }
        guard !groups.isEmpty else { throw BuildError.nothingSelected }
        guard let mdl0 = MDL0Writer.build(name: modelName, groups: groups, markerBones: markerBones(for: groups),
                                          mapStyle: true)
        else { throw BuildError.writeFailed }
        return mdl0
    }

    // MARK: Helpers

    /// `posLD`/`posRU`, the two corner-marker bones a map model's minimap HUD looks up by name
    /// to scale/position kart icons against the track's bounds (see `MDL0Writer.MarkerBone`'s doc
    /// comment). Retail hand-places these per track, padded out past the geometry's own bounds by
    /// an amount that isn't a fixed ratio (checked against `beginner_course.szs`'s own map model:
    /// 11-29% of extent on different edges), 20% on every edge is a reasonable, uniform stand-in
    /// that keeps the whole track comfortably inside the two markers, not an attempt to reproduce
    /// Nintendo's exact framing. Getting this somewhat wrong only affects minimap framing; the
    /// bones existing at all is what the game's load actually depends on.
    private static func markerBones(for groups: [MDL0Writer.Group]) -> [MDL0Writer.MarkerBone] {
        var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude
        var minZ = Float.greatestFiniteMagnitude, maxZ = -Float.greatestFiniteMagnitude
        for group in groups {
            for t in group.triangles {
                for p in [t.v0, t.v1, t.v2] {
                    minX = min(minX, p.x); maxX = max(maxX, p.x)
                    minZ = min(minZ, p.z); maxZ = max(maxZ, p.z)
                }
            }
        }
        guard minX.isFinite, maxX.isFinite, minZ.isFinite, maxZ.isFinite else { return [] }
        let padX = (maxX - minX) * 0.2, padZ = (maxZ - minZ) * 0.2
        // Z is inverted between world space and the minimap's on-screen "up", confirmed against
        // retail, where posLD sits at the world's *max* Z (padded further) and posRU at *min* Z.
        return [
            MDL0Writer.MarkerBone(name: "posLD", translation: Vec3(x: minX - padX, y: 0, z: maxZ + padZ)),
            MDL0Writer.MarkerBone(name: "posRU", translation: Vec3(x: maxX + padX, y: 0, z: minZ - padZ)),
        ]
    }

    private static func modelAndMeshes(in data: Data) -> (MDL0Model, [MDL0Mesh])? {
        guard let doc = try? BRRESDocument.parse(data) else { return nil }
        for resource in doc.resources where resource.magic == "MDL0" {
            guard let model = MDL0Parser.parse(resource, rawFile: doc.rawData) else { continue }
            let meshes = model.meshes.filter { $0.vertices.count >= 3 }
            guard !meshes.isEmpty else { continue }
            return (model, meshes)
        }
        return nil
    }

    /// `MDL0Parser` hands back a flat triangle list, so vertices come in threes.
    private static func triangles(from mesh: MDL0Mesh) -> [OBJImporter.Triangle] {
        var out: [OBJImporter.Triangle] = []
        out.reserveCapacity(mesh.vertices.count / 3)
        var i = 0
        while i + 2 < mesh.vertices.count {
            let a = mesh.vertices[i], b = mesh.vertices[i + 1], c = mesh.vertices[i + 2]
            out.append(OBJImporter.Triangle(v0: a.position, v1: b.position, v2: c.position,
                                            uv0: objUV(a.uv0), uv1: objUV(b.uv0), uv2: objUV(c.uv0),
                                            materialName: nil))
            i += 3
        }
        return out
    }

    /// `MDL0Parser` reports UVs as the file stores them (GX's V axis increases downward), while
    /// `MDL0Writer` takes them in OBJ convention and flips them itself, so they have to be
    /// flipped back on the way through, or a round trip would double-flip.
    private static func objUV(_ uv: Vec2?) -> Vec2? {
        guard let uv else { return nil }
        return Vec2(x: uv.x, y: 1 - uv.y)
    }

}
