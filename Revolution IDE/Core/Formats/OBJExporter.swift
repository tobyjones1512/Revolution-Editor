import Foundation
import AppKit

/// A model as Wavefront `.obj` + `.mtl` (+ one PNG per texture it uses), from either game's
/// models: a BRRES MDL0 directly, a BMD/BDL through its Wii (MDL0) conversion.
/// One object and one material per mesh; vertex colours are not exported. V is flipped (OBJ's
/// V runs up, GX's down).
nonisolated enum OBJExporter {
    /// Writes `<url>` (the .obj), the .mtl beside it and the textures next to that.
    static func write(_ model: MDL0Model, textures: [String: DecodedTexture], to url: URL) throws {
        let stem = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        var obj = "# Exported by Revolution Editor\nmtllib \(stem).mtl\n"
        var mtl = ""
        var positions: [String: Int] = [:], uvs: [String: Int] = [:], normals: [String: Int] = [:]
        var pText = "", uvText = "", nText = ""
        func index(_ key: String, _ text: String, _ table: inout [String: Int], _ out: inout String) -> Int {
            if let i = table[key] { return i }
            table[key] = table.count + 1; out += text
            return table.count
        }
        var usedTextures = Set<String>(), materialNames = Set<String>()
        var faces = ""
        for (mi, mesh) in model.meshes.enumerated() where mesh.vertices.count >= 3 {
            var material = (mesh.materialName ?? mesh.name).replacingOccurrences(of: " ", with: "_")
            if material.isEmpty { material = "mesh" }
            let unique = materialNames.contains(material) ? "\(material)_\(mi)" : material
            materialNames.insert(unique)
            mtl += "newmtl \(unique)\nKd 1 1 1\n"
            if let t = mesh.textureName, textures[t] != nil {
                usedTextures.insert(t)
                mtl += "map_Kd \(fileName(t))\n"
                if textures[t]?.hasTransparency == true { mtl += "map_d \(fileName(t))\n" }
            }
            mtl += "\n"
            faces += "o \((mesh.name.isEmpty ? "mesh\(mi)" : mesh.name).replacingOccurrences(of: " ", with: "_"))\nusemtl \(unique)\n"
            var i = 0
            while i + 2 < mesh.vertices.count {
                var corners: [String] = []
                for v in mesh.vertices[i..<i + 3] {
                    let p = index("\(v.position.x),\(v.position.y),\(v.position.z)", "v \(v.position.x) \(v.position.y) \(v.position.z)\n", &positions, &pText)
                    var c = "\(p)"
                    if let uv = v.uv0 {
                        let t = index("\(uv.x),\(uv.y)", "vt \(uv.x) \(1 - uv.y)\n", &uvs, &uvText)
                        c += "/\(t)"
                    } else if v.normal != nil { c += "/" }
                    if let n = v.normal {
                        c += "/\(index("\(n.x),\(n.y),\(n.z)", "vn \(n.x) \(n.y) \(n.z)\n", &normals, &nText))"
                    }
                    corners.append(c)
                }
                faces += "f \(corners.joined(separator: " "))\n"
                i += 3
            }
        }
        obj += pText + uvText + nText + faces
        try obj.write(to: url, atomically: true, encoding: .utf8)
        try mtl.write(to: dir.appendingPathComponent(stem + ".mtl"), atomically: true, encoding: .utf8)
        for name in usedTextures {
            guard let image = textures[name]?.image, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
            try png.write(to: dir.appendingPathComponent(fileName(name)), options: .atomic)
        }
    }

    private static func fileName(_ texture: String) -> String {
        texture.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: " ", with: "_") + ".png"
    }
}

extension OBJExporter {
    /// A KCL's triangles as `.obj`, one `usemtl kcl_0x<flag>` group per surface type, so importing it
    /// back picks each surface's type up from the material name. Y-up, as the game has it. Each surface
    /// gets a material (`Kd` + a solid-colour PNG) in `color(flag)`, the colour the editor shows it in.
    static func writeKCL(_ triangles: [KCLTriangle], color: (UInt16) -> NSColor, to url: URL) throws {
        let stem = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        var verts: [String: Int] = [:], vText = "", groups: [UInt16: String] = [:]
        func index(_ v: Vec3) -> Int {
            let key = "\(v.x) \(v.y) \(v.z)"
            if let i = verts[key] { return i }
            verts[key] = verts.count + 1
            vText += "v \(v.x) \(v.y) \(v.z)\n"
            return verts.count
        }
        for t in triangles { groups[t.attribute, default: ""] += "f \(index(t.v0)) \(index(t.v1)) \(index(t.v2))\n" }
        var obj = "# Collision exported by Revolution Editor\nmtllib \(stem).mtl\n" + vText, mtl = ""
        for (flag, faces) in groups.sorted(by: { $0.key < $1.key }) {
            let name = "kcl_0x" + String(format: "%04x", flag)
            obj += "usemtl \(name)\n" + faces
            let c = color(flag).usingColorSpace(.sRGB) ?? .gray
            mtl += "newmtl \(name)\nKd \(c.redComponent) \(c.greenComponent) \(c.blueComponent)\nmap_Kd \(name).png\n\n"
            let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { r in c.setFill(); r.fill(); return true }
            if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try png.write(to: dir.appendingPathComponent(name + ".png"), options: .atomic)
            }
        }
        try obj.write(to: url, atomically: true, encoding: .utf8)
        try mtl.write(to: dir.appendingPathComponent(stem + ".mtl"), atomically: true, encoding: .utf8)
    }
}
