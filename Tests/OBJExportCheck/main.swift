// OBJ export check: Luigi Circuit's course model exports to an .obj whose faces, texture
// coordinates and materials are consistent, with an .mtl and PNGs beside it.
//
//   find "Revolution IDE/Core" -name '*.swift' ! -path '*/Workbench/*' ! -path '*/Homebrew/*' \
//     ! -path '*/Editor/*' ! -name AppState.swift | tr '\n' '\0' | xargs -0 swiftc -O -parse-as-library \
//     -o /tmp/objcheck "Revolution IDE/Core/Workbench/BaseGameLibrary.swift" Tests/OBJExportCheck/main.swift
//   /tmp/objcheck [mkwii.iso] [common-key]

import Foundation

@main enum OBJExportCheck {
    static func main() throws {
        let args = CommandLine.arguments
        let roms = "\(ProcessInfo.processInfo.environment["ROMS_DIR"] ?? "Roms")/"
        let iso = args.count > 1 ? args[1] : roms + "Wii/MKWii/Mario Kart Wii (USA) (En,Fr,Es).iso"
        let key = args.count > 2 ? args[2] : roms + "Wii/Keys/common-key"
        let disc = try WiiDisc(url: URL(fileURLWithPath: iso), commonKey: [UInt8](try Data(contentsOf: URL(fileURLWithPath: key))), koreanKey: nil)
        func find(_ n: DiscNode) -> DiscNode? { n.isDirectory ? n.children.lazy.compactMap(find).first : (n.name == "beginner_course.szs" ? n : nil) }
        guard let node = find(disc.root) else { print("FAIL no course"); exit(1) }
        let (root, _) = try SZS.open(try disc.readFile(node: node))
        guard let brres = root.children.first(where: { $0.name == "course_model.brres" })?.data else { print("FAIL no model"); exit(1) }
        let doc = try BRRESDocument.parse(brres)
        let r = doc.resources.first { $0.magic == "MDL0" }!
        let model = MDL0Parser.parse(r, rawFile: doc.rawData)!
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("objcheck-\(getpid())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("course.obj")
        try OBJExporter.write(model, textures: MDL0SceneKit.textureImages(in: doc), to: url)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        let v = lines.filter { $0.hasPrefix("v ") }.count, vt = lines.filter { $0.hasPrefix("vt ") }.count, f = lines.filter { $0.hasPrefix("f ") }
        let tris = model.meshes.reduce(0) { $0 + $1.vertices.count / 3 }
        var bad = 0
        for face in f { for c in face.dropFirst(2).split(separator: " ") { let p = c.split(separator: "/", omittingEmptySubsequences: false); if Int(p[0])! > v || (p.count > 1 && !p[1].isEmpty && Int(p[1])! > vt) { bad += 1 } } }
        let pngs = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".png") }.count
        let mtl = try String(contentsOfFile: dir.appendingPathComponent("course.mtl").path, encoding: .utf8)
        print("faces \(f.count) of \(tris) triangles, \(v) vertices, \(vt) uvs, \(pngs) pngs, \(mtl.split(separator: "\n").filter { $0.hasPrefix("newmtl") }.count) materials, \(bad) bad indices")
        try? FileManager.default.removeItem(at: dir)
        if f.count != tris || bad > 0 || pngs == 0 { print("FAIL"); exit(1) }
        print("ok")
    }
}
