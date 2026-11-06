import Foundation

/// A Mario Kart Wii skybox: `vrcorn_model.brres`, whose MDL0 the game finds by the name "vrcorn".
nonisolated enum Skybox {
    /// Retail sky domes are 100,000-400,000 units across, centred on the course (most ~390,000).
    static let radius: Float = 195_000

    /// From an `.obj` (its own .mtl/textures), or from an image wrapped all the way round a
    /// sphere, an equirectangular (2:1) panorama lines up exactly, top of the image overhead.
    static func brres(from url: URL) throws -> Data {
        let isOBJ = ModelFile.isModel(url)
        var objURL = url
        var text: String
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        if isOBJ {
            (text, objURL) = try ModelFile.objSource(url)
        } else {
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            let image = "sky." + url.pathExtension
            try FileManager.default.copyItem(at: url, to: temp.appendingPathComponent(image))
            try "newmtl sky\nmap_Kd \(image)\n".write(to: temp.appendingPathComponent("sky.mtl"), atomically: true, encoding: .utf8)
            objURL = temp.appendingPathComponent("sky.obj")
            text = sphereOBJ()
        }
        guard let r = OBJToBRRES.convert(objText: text, objURL: objURL, modelName: "vrcorn") else {
            throw WSError.badStructure(isOBJ ? "Couldn't build a skybox from that model, it has no triangles, or one material covers more than \(MDL0Writer.maxVerticesPerMesh / 3) triangles."
                                             : "Couldn't build a skybox from that image.")
        }
        if !isOBJ, !r.missingTextures.isEmpty { throw WSError.badStructure("Couldn't read that image.") }
        let doc = BRRESDocument()
        doc.resources.append(contentsOf: r.textures)
        doc.resources.append(r.model)
        return doc.serialize()
    }

    /// A UV sphere seen from inside: u runs clockwise from above (so the image isn't mirrored),
    /// v from the bottom pole (0) to the top (1).
    static func sphereOBJ(segments: Int = 48, rings: Int = 24) -> String {
        var s = "mtllib sky.mtl\nusemtl sky\n"
        for i in 0...rings {
            let lat = Float.pi / 2 - Float.pi * Float(i) / Float(rings)
            for j in 0...segments {
                let lon = 2 * Float.pi * Float(j) / Float(segments)
                s += "v \(radius * cos(lat) * sin(lon)) \(radius * sin(lat)) \(-radius * cos(lat) * cos(lon))\n"
                s += "vt \(Float(j) / Float(segments)) \(1 - Float(i) / Float(rings))\n"
            }
        }
        let row = segments + 1
        for i in 0..<rings {
            for j in 0..<segments {
                let a = i * row + j + 1, b = a + 1, c = a + row, d = c + 1
                if i != 0 { s += "f \(a)/\(a) \(c)/\(c) \(b)/\(b)\n" }
                if i != rings - 1 { s += "f \(b)/\(b) \(c)/\(c) \(d)/\(d)\n" }
            }
        }
        return s
    }
}
