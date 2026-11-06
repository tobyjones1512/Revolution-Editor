// Hardware-compatible build check: one course model (.obj) and its collision, built with both
// settings. The hardware model (RiiStudio-style triangle strips, mipmapped textures) must draw
// exactly the triangles the Dolphin one does, each with the same winding; its textures must carry
// RiiStudio's mip levels. Writes the course with the hardware model and collision into a copy of
// the given .szs, for the display-list, wszst, collision and Kinoko checks to take over.
//
//   find "Revolution IDE/Core" -name '*.swift' ! -path '*/Workbench/*' ! -name AppState.swift \
//     ! -name SyntaxHighlighter.swift -print0 | xargs -0 swiftc -O -parse-as-library -o /tmp/hwcheck \
//     "Revolution IDE/Core/Workbench/BaseGameLibrary.swift" Tests/HardwareBuildCheck/*.swift
//   /tmp/hwcheck course.szs course_model.obj out.szs     (map_model.obj beside it is rebuilt too)

import Foundation

@main enum HardwareBuildCheck {
    static func main() throws {
        let a = CommandLine.arguments
        var failures = 0
        func check(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failures += 1 } }
        let objURL = URL(fileURLWithPath: a[2])
        let text = try String(contentsOf: objURL, encoding: .utf8)

        func build(_ mode: BuildCompatibility) -> (OBJToBRRES.Result, Data)? {
            UserDefaults.standard.set(mode.rawValue, forKey: BuildCompatibility.defaultsKey)
            guard let r = OBJToBRRES.convert(objText: text, objURL: objURL, modelName: "course") else { return nil }
            let doc = BRRESDocument(); doc.resources = [r.model] + r.textures
            return (r, doc.serialize())
        }
        guard let (dolphin, dolphinFile) = build(.dolphin), let (hardware, hardwareFile) = build(.hardware) else { print("FAIL build"); exit(1) }

        // Triangles as drawn: positions, each rotated to start at its smallest corner (keeps winding).
        func drawn(_ file: Data) throws -> [[Float]] {
            let doc = try BRRESDocument.parse(file)
            let model = MDL0Parser.parse(doc.resources.first { $0.magic == "MDL0" }!, rawFile: doc.rawData)!
            var out: [[Float]] = []
            for mesh in model.meshes {
                for i in stride(from: 0, to: mesh.vertices.count - 2, by: 3) {
                    var t = (0..<3).map { [mesh.vertices[i + $0].position.x, mesh.vertices[i + $0].position.y, mesh.vertices[i + $0].position.z] }
                    // A strip's swap makes a zero-area join (a corner repeated): the GPU draws nothing.
                    if t[0] == t[1] || t[1] == t[2] || t[0] == t[2] { continue }
                    let k = t.indices.min { t[$0].lexicographicallyPrecedes(t[$1]) }!
                    t = Array(t[k...] + t[..<k])
                    out.append(t.flatMap { $0 })
                }
            }
            return out.sorted { $0.lexicographicallyPrecedes($1) }
        }
        let d = try drawn(dolphinFile), h = try drawn(hardwareFile)
        check(d == h, "hardware model draws the same \(d.count) triangles with the same winding (got \(h.count))")
        func drawListBytes(_ file: Data) throws -> Int {
            let doc = try BRRESDocument.parse(file)
            let m = doc.resources.first { $0.magic == "MDL0" }!.data
            let g = Int(m.be32(0x10 + 10 * 4))
            return (1...Int(m.be32(g + 4))).reduce(0) { sum, e in sum + Int(m.be32(g + Int(m.be32(g + 8 + e * 16 + 12)) + 0x24)) }
        }
        let dBytes = try drawListBytes(dolphinFile), hBytes = try drawListBytes(hardwareFile)
        check(hBytes <= dBytes, "strips make the draw lists no bigger (\(hBytes) vs \(dBytes) bytes)")
        for (t, tex) in zip(dolphin.textures, hardware.textures) {
            let w = Int(tex.data.be16(0x1C)), hgt = Int(tex.data.be16(0x1E)), mips = Int(tex.data.be32(0x24))
            var expected = 1
            while expected < 5 && (w >> expected) >= 32 && (hgt >> expected) >= 32 { expected += 1 }
            check(mips == expected && Int(t.data.be32(0x24)) == 1, "\(tex.name) \(w)x\(hgt): \(mips) mip levels (RiiStudio: \(expected))")
        }

        // The course, with the hardware model and collision.
        let (root, _) = try SZS.open(try Data(contentsOf: URL(fileURLWithPath: a[1])))
        root.children.first { $0.name == "course_model.brres" }!.data = hardwareFile
        // The minimap too, when its .obj sits beside the course model (as the app writes it).
        let mapURL = objURL.deletingLastPathComponent().appendingPathComponent("map_model.obj")
        if let mapText = try? String(contentsOf: mapURL, encoding: .utf8),
           let map = OBJToBRRES.convert(objText: mapText, objURL: mapURL, modelName: "map") {
            let doc = BRRESDocument(); doc.resources = [map.model]
            root.children.first { $0.name == "map_model.brres" }?.data = doc.serialize()
        }
        let flags = OBJImporter.assignFlagsByMaterial(OBJImporter.parse(text), materials: OBJImporter.loadMTLMaterials(objText: text, objURL: objURL))
        let kcl = KCLDocument()
        kcl.triangles = zip(OBJImporter.parse(text), flags).map { KCLTriangle.facingUp($0.v0, $0.v1, $0.v2, attribute: $1) }
        root.children.first { $0.name == "course.kcl" }!.data = kcl.serialize()
        try SZS.save(root: root, compressed: true).write(to: URL(fileURLWithPath: a[3]))
        UserDefaults.standard.removeObject(forKey: BuildCompatibility.defaultsKey)
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
