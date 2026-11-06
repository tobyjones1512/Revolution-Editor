import AppKit

/// Turns an `.obj` (plus its companion `.mtl`, if it has one) into the resources a real `.brres`
/// is made of: one MDL0 with a mesh/material per `usemtl` group, and one TEX0 per distinct
/// `map_Kd` image those materials reference.
///
/// Shared by every OBJ import path in the app (new `.brres` from an `.obj`, "Make .brres" on a
/// project file, and adding an `.obj` to an already-open `.brres`) so all three produce the same
/// bytes.
nonisolated enum OBJToBRRES {
    /// Mario Kart Wii loads a course's model by looking for an MDL0 with a specific name inside a
    /// specific file, the model's own filename is irrelevant to it. An `.obj` called anything at
    /// all therefore has to be renamed on the way in, or the game simply won't find it.
    static let requiredModelNames: [String: String] = [
        "course_model.brres": "course",
        "vrcorn_model.brres": "vrcorn",
        "map_model.brres": "map",
    ]

    /// The MDL0 name to use when this model is destined for `brresFileName`, falling back to a
    /// cleaned-up version of `fallback` (MDL0 names go through a byte-comparing dictionary, so
    /// spaces and other loose characters are stripped rather than trusted).
    static func modelName(forBRRESNamed brresFileName: String?, fallback: String) -> String {
        if let brresFileName, let required = requiredModelNames[brresFileName.lowercased()] { return required }
        let cleaned = String(fallback.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
        return cleaned.isEmpty ? "model" : cleaned
    }

    /// Textures are re-encoded to CMPR and capped to this many pixels per side. A 1024x1024 RGBA8
    /// texture is 4 MB; the Wii only has 24 MB of main memory for the *entire* game, so a handful
    /// of full-size source images is enough to run a course out of memory before it ever draws.
    /// The same image as a 512-pixel CMPR texture is 128 KB.
    static let maxTextureSize = 512

    struct Result {
        var model: BRRESResource
        var textures: [BRRESResource]
        var triangleCount: Int
        /// Materials that named a `map_Kd` image which couldn't be found or read, worth telling
        /// the user about, since the model still builds, just untextured in those spots.
        var missingTextures: [String]
    }

    static func convert(objText: String, objURL: URL, modelName: String) -> Result? {
        let triangles = OBJImporter.parse(objText)
        guard !triangles.isEmpty else { return nil }
        // A minimap needs posLD/posRU marker bones and retail's untextured map material; an
        // ordinary model named "map" has neither and crashes or never draws.
        if modelName == requiredModelNames["map_model.brres"] {
            guard let mdl0 = try? MapModelBuilder.model(triangles: triangles, modelName: modelName) else { return nil }
            return Result(model: BRRESResource(name: modelName, folderName: "3DModels(NW4R)",
                                               data: mdl0.data, stringReferences: mdl0.stringReferences),
                          textures: [], triangleCount: triangles.count, missingTextures: [])
        }
        let mtlMaterials = OBJImporter.loadMTLMaterials(objText: objText, objURL: objURL)
        let folder = objURL.deletingLastPathComponent()

        var textureResources: [BRRESResource] = []
        var textureNameForPath: [String: String] = [:]
        var missing: [String] = []

        /// Loads (once) the image a material's `map_Kd` points at, and returns the TEX0 resource
        /// name it was stored under.
        func textureName(forMaterial name: String) -> String? {
            guard let path = mtlMaterials[name]?.diffuseTexturePath else { return nil }
            if let existing = textureNameForPath[path] { return existing }
            let imageURL = folder.appendingPathComponent(path)
            guard let image = NSImage(contentsOf: imageURL),
                  let rep = NSBitmapImageRep(data: (try? Data(contentsOf: imageURL)) ?? Data()) else {
                missing.append(path)
                return nil
            }
            let (width, height) = fittedSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            guard let rgba = ImageUtil.rgba(from: image, width: width, height: height),
                  let tex0 = texture(name: textureResourceName(for: imageURL), rgba: rgba, width: width, height: height) else {
                missing.append(path)
                return nil
            }
            let resourceName = textureResourceName(for: imageURL)
            textureResources.append(BRRESResource(name: resourceName, folderName: "Textures(NW4R)", data: tex0))
            textureNameForPath[path] = resourceName
            return resourceName
        }

        let groups = MDL0Writer.groups(from: triangles) { materialName in
            guard let materialName else { return MDL0Writer.MaterialSpec(name: "material") }
            var spec = MDL0Writer.MaterialSpec(
                name: sanitized(materialName),
                color: mtlMaterials[materialName]?.diffuseColor ?? (1, 1, 1),
                textureName: textureName(forMaterial: materialName))
            spec.mipmapped = spec.textureName != nil && BuildCompatibility.current == .hardware
            return spec
        }
        guard groups.allSatisfy({ $0.triangles.count * 3 <= MDL0Writer.maxVerticesPerMesh }) else { return nil }
        guard let mdl0 = MDL0Writer.build(name: modelName, groups: groups) else { return nil }

        return Result(model: BRRESResource(name: modelName, folderName: "3DModels(NW4R)",
                                          data: mdl0.data, stringReferences: mdl0.stringReferences),
                      textures: textureResources,
                      triangleCount: triangles.count,
                      missingTextures: missing)
    }

    /// A CMPR texture; with the hardware-compatible setting, mipmapped the way RiiStudio's importer
    /// does it, levels down to 32 pixels, at most 5 in all (sizes here are already powers of two).
    static func texture(name: String, rgba: [UInt8], width: Int, height: Int) -> Data? {
        var levels = 1
        if BuildCompatibility.current == .hardware {
            while levels < 5 && (width >> levels) >= 32 && (height >> levels) >= 32 { levels += 1 }
        }
        var encoded = Data()
        for level in NormalMap.mipChain(rgba, width: width, height: height, count: levels) {
            guard let e = TextureCodec.encode(rgba: level.rgba, width: level.width, height: level.height, format: .cmpr) else { return nil }
            encoded.append(e)
        }
        return TEX0View.building(name: name, encoded: encoded, width: width, height: height, format: .cmpr, mipCount: levels)
    }

    /// The largest power-of-two size that fits both the source image and `maxTextureSize`. GX
    /// wants power-of-two dimensions for repeating (tiled) textures, and CMPR works in 8x8 blocks,
    /// so this avoids both problems at once.
    static func fittedSize(width: Int, height: Int) -> (Int, Int) {
        func fit(_ n: Int) -> Int {
            var size = 8
            while size * 2 <= min(max(n, 8), maxTextureSize) { size *= 2 }
            return size
        }
        return (fit(width), fit(height))
    }

    private static func textureResourceName(for imageURL: URL) -> String {
        sanitized(imageURL.deletingPathExtension().lastPathComponent)
    }

    private static func sanitized(_ name: String) -> String {
        let cleaned = String(name.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
        return cleaned.isEmpty ? "unnamed" : cleaned
    }
}
