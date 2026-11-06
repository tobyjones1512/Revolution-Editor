import AppKit
import simd
import UniformTypeIdentifiers

/// The 3D model files every model import accepts. A `.dae` (COLLADA) is turned into an `.obj` +
/// `.mtl` + textures in a temporary folder, so it goes through exactly the same OBJ pipeline
/// (`OBJImporter`, `OBJToBRRES`, KCL import, ...) as an `.obj` does.
nonisolated enum ModelFile {
    static let extensions = ["obj", "dae"]
    static var contentTypes: [UTType] { extensions.compactMap { UTType(filenameExtension: $0) } }
    static func isModel(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    /// The model's OBJ text, and the URL its `.mtl`/textures resolve against, the file itself for
    /// an `.obj`, a converted copy (same base name) for a `.dae`.
    static func objSource(_ url: URL) throws -> (text: String, url: URL) {
        if url.pathExtension.lowercased() == "dae" { return try DAEImporter.convertToOBJ(url) }
        return (try String(contentsOf: url, encoding: .utf8), url)
    }
}

/// A COLLADA 1.4/1.5 reader for static meshes, read straight from the XML (SceneKit's own loader
/// runs out of process and can't be relied on everywhere): `<triangles>`, `<polylist>` and
/// `<polygons>`, positions + first UV set, node `matrix`/`translate`/`rotate`/`scale` (and
/// `instance_node`), the file's up axis, and each material's diffuse colour or texture.
/// Skinning, morphs and animation are ignored, the bind pose is what's exported.
nonisolated enum DAEImporter {
    static func convertToOBJ(_ url: URL) throws -> (text: String, url: URL) {
        let data = try Data(contentsOf: url)
        let base = url.deletingPathExtension().lastPathComponent
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dae-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (obj, mtl) = try convert(data, name: url.lastPathComponent, base: base, modelFolder: url.deletingLastPathComponent(), textureFolder: folder)
        let objURL = folder.appendingPathComponent(base + ".obj")
        try obj.write(to: objURL, atomically: true, encoding: .utf8)
        try mtl.write(to: folder.appendingPathComponent(base + ".mtl"), atomically: true, encoding: .utf8)
        return (obj, objURL)
    }

    /// OBJ and MTL text for a COLLADA document; textures are copied into `textureFolder`.
    static func convert(_ data: Data, name: String, base: String, modelFolder: URL, textureFolder: URL) throws -> (obj: String, mtl: String) {
        // XPath and COLLADA's default namespace don't mix; the elements are unambiguous without it.
        var text = String(decoding: data, as: UTF8.self)
        text = text.replacingOccurrences(of: #"\sxmlns(:\w+)?="[^"]*""#, with: "", options: .regularExpression)
        let doc: XMLDocument
        do { doc = try XMLDocument(xmlString: text, options: []) } catch {
            throw WSError.badStructure("\(name) isn't a readable COLLADA (.dae) file: \(error.localizedDescription)")
        }
        guard let root = doc.rootElement(), root.name == "COLLADA" else { throw WSError.badStructure("\(name) isn't a COLLADA (.dae) file.") }
        var reader = Reader(doc: doc, modelFolder: modelFolder, textureFolder: textureFolder)
        reader.obj = "# Converted from \(name)\nmtllib \(base).mtl\n"

        let up = (try? doc.nodes(forXPath: "/COLLADA/asset/up_axis").first?.stringValue)??.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Y_UP"
        reader.upAxis = up == "Z_UP" ? simd_float4x4(rows: [SIMD4(1, 0, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, -1, 0, 0), SIMD4(0, 0, 0, 1)])
                      : up == "X_UP" ? simd_float4x4(rows: [SIMD4(0, -1, 0, 0), SIMD4(1, 0, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)])
                      : matrix_identity_float4x4

        let sceneURL = (try? doc.nodes(forXPath: "/COLLADA/scene/instance_visual_scene").first as? XMLElement)?.attribute(forName: "url")?.stringValue
        let scene = sceneURL.flatMap(reader.element) ?? (try? doc.nodes(forXPath: "//library_visual_scenes/visual_scene").first as? XMLElement) ?? nil
        if let scene {
            for node in scene.elements(forName: "node") { reader.visit(node, parent: matrix_identity_float4x4) }
        } else {
            // No scene: every geometry as-is.
            for g in (try? doc.nodes(forXPath: "//library_geometries/geometry")) ?? [] {
                if let g = g as? XMLElement { reader.emit(g, transform: matrix_identity_float4x4, bindings: [:]) }
            }
        }
        guard reader.vertexCount > 0 else { throw WSError.badStructure("\(name) has no mesh geometry.") }
        return (reader.obj, reader.mtl)
    }

    private struct Reader {
        let doc: XMLDocument
        let modelFolder: URL
        let textureFolder: URL
        var upAxis = matrix_identity_float4x4
        var obj = "", mtl = ""
        var vertexCount = 0, uvCount = 0
        var materialNames: [String: String] = [:] // material id -> OBJ name
        var usedNames = Set<String>()
        var byID: [String: XMLElement] = [:]

        init(doc: XMLDocument, modelFolder: URL, textureFolder: URL) {
            self.doc = doc; self.modelFolder = modelFolder; self.textureFolder = textureFolder
            for case let e as XMLElement in (try? doc.nodes(forXPath: "//*[@id]")) ?? [] {
                if let id = e.attribute(forName: "id")?.stringValue { byID[id] = e }
            }
        }

        func element(_ ref: String) -> XMLElement? { byID[ref.hasPrefix("#") ? String(ref.dropFirst()) : ref] }

        // MARK: Scene graph

        mutating func visit(_ node: XMLElement, parent: simd_float4x4) {
            var m = parent
            for child in node.children ?? [] {
                guard let e = child as? XMLElement else { continue }
                let f = floats(e.stringValue)
                switch e.name {
                case "matrix" where f.count == 16:
                    m *= simd_float4x4(rows: (0..<4).map { SIMD4(f[$0 * 4], f[$0 * 4 + 1], f[$0 * 4 + 2], f[$0 * 4 + 3]) })
                case "translate" where f.count == 3:
                    m *= simd_float4x4(rows: [SIMD4(1, 0, 0, f[0]), SIMD4(0, 1, 0, f[1]), SIMD4(0, 0, 1, f[2]), SIMD4(0, 0, 0, 1)])
                case "rotate" where f.count == 4:
                    m *= simd_float4x4(simd_quatf(angle: f[3] * .pi / 180, axis: simd_normalize(SIMD3(f[0], f[1], f[2]) + 1e-12)))
                case "scale" where f.count == 3:
                    m *= simd_float4x4(diagonal: SIMD4(f[0], f[1], f[2], 1))
                default: break
                }
            }
            for e in node.elements(forName: "instance_geometry") {
                guard let g = e.attribute(forName: "url")?.stringValue.flatMap(element) else { continue }
                var bindings: [String: String] = [:]
                for im in (try? e.nodes(forXPath: "bind_material/technique_common/instance_material")) ?? [] {
                    guard let im = im as? XMLElement, let symbol = im.attribute(forName: "symbol")?.stringValue,
                          let target = im.attribute(forName: "target")?.stringValue else { continue }
                    bindings[symbol] = target
                }
                emit(g, transform: m, bindings: bindings)
            }
            for e in node.elements(forName: "instance_node") {
                if let n = e.attribute(forName: "url")?.stringValue.flatMap(element) { visit(n, parent: m) }
            }
            for child in node.elements(forName: "node") { visit(child, parent: m) }
        }

        // MARK: Geometry

        mutating func emit(_ geometry: XMLElement, transform: simd_float4x4, bindings: [String: String]) {
            guard let mesh = geometry.elements(forName: "mesh").first else { return }
            let world = upAxis * transform
            var positionSource: XMLElement?
            if let v = mesh.elements(forName: "vertices").first,
               let input = v.elements(forName: "input").first(where: { $0.attribute(forName: "semantic")?.stringValue == "POSITION" }) {
                positionSource = input.attribute(forName: "source")?.stringValue.flatMap(element)
            }
            guard let positions = positionSource.map({ vectors($0) }), !positions.isEmpty else { return }
            for p in positions {
                let w = world * SIMD4(p.x, p.y, p.z, 1)
                obj += "v \(w.x) \(w.y) \(w.z)\n"
            }

            var uvSource: XMLElement?, uvs: [SIMD3<Float>] = []
            for kind in ["triangles", "polylist", "polygons"] {
                for prim in mesh.elements(forName: kind) {
                    let inputs = prim.elements(forName: "input")
                    let stride = (inputs.compactMap { Int($0.attribute(forName: "offset")?.stringValue ?? "") }.max() ?? 0) + 1
                    func offset(_ semantic: String) -> (Int, XMLElement?)? {
                        let candidates = inputs.filter { $0.attribute(forName: "semantic")?.stringValue == semantic }
                        guard let i = candidates.first(where: { ($0.attribute(forName: "set")?.stringValue ?? "0") == "0" }) ?? candidates.first else { return nil }
                        return (Int(i.attribute(forName: "offset")?.stringValue ?? "0") ?? 0, i.attribute(forName: "source")?.stringValue.flatMap(element))
                    }
                    guard let (vOfs, _) = offset("VERTEX") else { continue }
                    let tex = offset("TEXCOORD")
                    if let t = tex?.1, uvSource == nil {
                        uvSource = t
                        uvs = vectors(t)
                        for uv in uvs { obj += "vt \(uv.x) \(uv.y)\n" }
                    }
                    let useUV = tex?.1 != nil && tex!.1 === uvSource

                    let symbol = prim.attribute(forName: "material")?.stringValue
                    obj += "usemtl \(materialName(symbol.flatMap { bindings[$0] } ?? symbol))\n"

                    // Each polygon's corner count, and the flat index list.
                    var counts: [Int] = [], indices: [Int] = []
                    switch kind {
                    case "triangles":
                        indices = ints(prim.elements(forName: "p").first?.stringValue)
                        counts = Array(repeating: 3, count: indices.count / (3 * stride))
                    case "polylist":
                        counts = ints(prim.elements(forName: "vcount").first?.stringValue)
                        indices = ints(prim.elements(forName: "p").first?.stringValue)
                    default:
                        for p in prim.elements(forName: "p") {
                            let i = ints(p.stringValue)
                            counts.append(i.count / stride); indices += i
                        }
                    }
                    var cursor = 0
                    for n in counts {
                        guard n >= 3, (cursor + n) * stride <= indices.count else { break }
                        var face = "f"
                        for k in cursor..<(cursor + n) {
                            let v = indices[k * stride + vOfs]
                            guard positions.indices.contains(v) else { face = ""; break }
                            if useUV, let t = tex?.0, uvs.indices.contains(indices[k * stride + t]) {
                                face += " \(vertexCount + v + 1)/\(uvCount + indices[k * stride + t] + 1)"
                            } else {
                                face += " \(vertexCount + v + 1)"
                            }
                        }
                        if !face.isEmpty { obj += face + "\n" }
                        cursor += n
                    }
                }
            }
            vertexCount += positions.count
            uvCount += uvs.count
        }

        /// A `<source>`'s vectors (up to 3 components) via its accessor stride.
        func vectors(_ source: XMLElement) -> [SIMD3<Float>] {
            let values = floats(source.elements(forName: "float_array").first?.stringValue)
            let accessor = try? source.nodes(forXPath: "technique_common/accessor").first as? XMLElement
            let stride = max(1, Int(accessor?.attribute(forName: "stride")?.stringValue ?? "") ?? 3)
            let count = Int(accessor?.attribute(forName: "count")?.stringValue ?? "") ?? values.count / stride
            return (0..<min(count, values.count / stride)).map { i in
                SIMD3(values[i * stride], stride > 1 ? values[i * stride + 1] : 0, stride > 2 ? values[i * stride + 2] : 0)
            }
        }

        // MARK: Materials

        mutating func materialName(_ ref: String?) -> String {
            let key = ref ?? ""
            if let name = materialNames[key] { return name }
            let material = ref.flatMap(element)
            var name = (material?.attribute(forName: "name")?.stringValue ?? ref ?? "material")
                .trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "_")
            if name.isEmpty { name = "material" }
            var unique = name, k = 2
            while usedNames.contains(unique) { unique = "\(name)_\(k)"; k += 1 }
            usedNames.insert(unique)
            materialNames[key] = unique

            mtl += "newmtl \(unique)\n"
            let effect = (material?.elements(forName: "instance_effect").first?.attribute(forName: "url")?.stringValue).flatMap(element)
            let diffuse = (try? effect?.nodes(forXPath: "profile_COMMON/technique/*/diffuse").first as? XMLElement) ?? nil
            if let c = diffuse?.elements(forName: "color").first {
                let f = floats(c.stringValue)
                if f.count >= 3 { mtl += "Kd \(f[0]) \(f[1]) \(f[2])\n" }
            } else if let t = diffuse?.elements(forName: "texture").first?.attribute(forName: "texture")?.stringValue,
                      let effect, let source = imageURL(sampler: t, effect: effect) {
                let file = "\(unique)." + source.pathExtension
                if (try? FileManager.default.copyItem(at: source, to: textureFolder.appendingPathComponent(file))) != nil { mtl += "map_Kd \(file)\n" }
            }
            return unique
        }

        /// sampler2D -> surface -> image -> file (COLLADA 1.4), or straight to an image id, which
        /// many exporters write instead.
        func imageURL(sampler: String, effect: XMLElement) -> URL? {
            func param(_ sid: String) -> XMLElement? {
                (try? effect.nodes(forXPath: ".//newparam[@sid='\(sid)']").first as? XMLElement) ?? nil
            }
            var imageID = sampler
            if let s = param(sampler), let surfaceSID = (try? s.nodes(forXPath: "sampler2D/source").first?.stringValue) ?? nil {
                imageID = surfaceSID
                if let surface = param(surfaceSID), let id = (try? surface.nodes(forXPath: "surface/init_from").first?.stringValue) ?? nil { imageID = id }
            } else if let s = param(sampler), let id = (try? s.nodes(forXPath: "sampler2D/instance_image").first as? XMLElement)??.attribute(forName: "url")?.stringValue {
                imageID = id // COLLADA 1.5
            }
            guard let image = element(imageID) else { return nil }
            let path = ((try? image.nodes(forXPath: "init_from/ref").first?.stringValue) ?? nil) ?? image.elements(forName: "init_from").first?.stringValue
            guard var path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
            var url: URL
            if path.hasPrefix("file:"), let u = URL(string: path) { url = u } else {
                path = path.removingPercentEncoding ?? path
                url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : modelFolder.appendingPathComponent(path)
            }
            // Exporters often write an absolute path from the author's own machine; fall back to
            // the file name next to the model.
            if !FileManager.default.fileExists(atPath: url.path) { url = modelFolder.appendingPathComponent(url.lastPathComponent) }
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }

        func floats(_ s: String?) -> [Float] { (s ?? "").split(whereSeparator: \.isWhitespace).compactMap { Float($0) } }
        func ints(_ s: String?) -> [Int] { (s ?? "").split(whereSeparator: \.isWhitespace).compactMap { Int($0) } }
    }
}
