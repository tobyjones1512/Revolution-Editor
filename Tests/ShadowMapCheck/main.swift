// Shadow map check: a box on a ground plane bakes a shadow on the far side of the box from the
// sun and none elsewhere; the shadowed model re-reads with both samplers and a second UV set; and
// a shadowed material's display list and TEV block are byte-identical to retail Luigi Circuit's
// a_MainRoad_m (colour texture + beginner_course_kage_04).
//
//   find "Revolution IDE/Core" -name '*.swift' ! -path '*/Workbench/*' ! -path '*/Homebrew/*' \
//     ! -path '*/Editor/*' ! -name AppState.swift | tr '\n' '\0' | xargs -0 swiftc -O -parse-as-library \
//     -o /tmp/shadowcheck "Revolution IDE/Core/Workbench/BaseGameLibrary.swift" Tests/ShadowMapCheck/main.swift
//   /tmp/shadowcheck [mkwii.iso] [common-key]

import Foundation
import simd

@main enum ShadowMapCheck {
    static var failures = 0
    static func check(_ ok: Bool, _ msg: String) { print(ok ? "ok  " : "FAIL", msg); if !ok { failures += 1 } }

    static func quad(_ a: Vec3, _ b: Vec3, _ c: Vec3, _ d: Vec3, _ m: String) -> [OBJImporter.Triangle] {
        [OBJImporter.Triangle(v0: a, v1: b, v2: c, uv0: Vec2(x: 0, y: 0), uv1: Vec2(x: 1, y: 0), uv2: Vec2(x: 1, y: 1), materialName: m),
         OBJImporter.Triangle(v0: a, v1: c, v2: d, uv0: Vec2(x: 0, y: 0), uv1: Vec2(x: 1, y: 1), uv2: Vec2(x: 0, y: 1), materialName: m)]
    }

    static func main() throws {
        // Ground 4000 square, box 400 wide and 800 tall at the origin.
        func v(_ x: Float, _ y: Float, _ z: Float) -> Vec3 { Vec3(x: x, y: y, z: z) }
        let ground = quad(v(-2000, 0, -2000), v(-2000, 0, 2000), v(2000, 0, 2000), v(2000, 0, -2000), "ground")
        let h: Float = 800, s: Float = 200
        var box: [OBJImporter.Triangle] = []
        box += quad(v(-s, 0, -s), v(-s, h, -s), v(s, h, -s), v(s, 0, -s), "box")
        box += quad(v(-s, 0, s), v(s, 0, s), v(s, h, s), v(-s, h, s), "box")
        box += quad(v(-s, 0, -s), v(-s, 0, s), v(-s, h, s), v(-s, h, -s), "box")
        box += quad(v(s, 0, -s), v(s, h, -s), v(s, h, s), v(s, 0, s), "box")
        box += quad(v(-s, h, -s), v(-s, h, s), v(s, h, s), v(s, h, -s), "box")
        let doc = BRRESDocument()
        let gray = [UInt8](repeating: 200, count: 8 * 8 * 4)
        for t in ["ground", "box"] { doc.resources.append(BRRESResource(name: t, folderName: "Textures(NW4R)", data: TEX0View.building(name: t, rgba: gray, width: 8, height: 8, format: .cmpr)!)) }
        let groups = [MDL0Writer.Group(material: MDL0Writer.MaterialSpec(name: "ground", textureName: "ground"), triangles: ground),
                      MDL0Writer.Group(material: MDL0Writer.MaterialSpec(name: "box", textureName: "box"), triangles: box)]
        let plain = MDL0Writer.build(name: "course", groups: groups)!
        doc.resources.append(BRRESResource(name: "course", folderName: "3DModels(NW4R)", data: plain.data, stringReferences: plain.stringReferences))
        let parsed = try BRRESDocument.parse(doc.serialize())
        let model = parsed.resources.first { $0.magic == "MDL0" }!

        // Bake directly so world points can be looked up in the map.
        var opts = ShadowMap.Options()
        opts.azimuth = 0; opts.elevation = 45; opts.size = 256; opts.softness = 0; opts.shadeSlopes = false
        let tris = ground.map { ShadowMap.Triangle(a: SIMD3($0.v0.x, $0.v0.y, $0.v0.z), b: SIMD3($0.v1.x, $0.v1.y, $0.v1.z), c: SIMD3($0.v2.x, $0.v2.y, $0.v2.z)) }
        let casters = tris + box.map { ShadowMap.Triangle(a: SIMD3($0.v0.x, $0.v0.y, $0.v0.z), b: SIMD3($0.v1.x, $0.v1.y, $0.v1.z), c: SIMD3($0.v2.x, $0.v2.y, $0.v2.z)) }
        let layout = ShadowMap.atlas(tris, size: 256)!
        // Too many triangles for the map is a nil (an error message upstream), not a crash; and
        // zero-area triangles don't make the density search loop forever.
        let many = (0..<20_000).map { i -> ShadowMap.Triangle in let x = Float(i); return ShadowMap.Triangle(a: SIMD3(x, 0, 0), b: SIMD3(x + 1, 0, 0), c: SIMD3(x, 0, 1)) }
        check(ShadowMap.atlas(many, size: 256) == nil && ShadowMap.atlas(many, size: 1024) != nil, "20,000 triangles: no fit at 256, fit at 1024")
        let flatTris = [ShadowMap.Triangle](repeating: ShadowMap.Triangle(a: .zero, b: .zero, c: .zero), count: 10)
        check(ShadowMap.atlas(flatTris, size: 64) != nil, "zero-area triangles still lay out")
        check(layout.uvs.allSatisfy { $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1 }, "atlas UVs inside the map")
        let map = ShadowMap.bake(tris, atlas: layout, options: opts, casters: casters)
        func shade(_ x: Float, _ z: Float) -> Int {
            let p = SIMD2<Float>(x, z)
            for (i, t) in tris.enumerated() {
                let a = SIMD2(t.a.x, t.a.z), b = SIMD2(t.b.x, t.b.z), c = SIMD2(t.c.x, t.c.z)
                let den = (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y)
                let w0 = ((b.y - c.y) * (p.x - c.x) + (c.x - b.x) * (p.y - c.y)) / den
                let w1 = ((c.y - a.y) * (p.x - c.x) + (a.x - c.x) * (p.y - c.y)) / den
                let w2 = 1 - w0 - w1
                guard w0 >= 0, w1 >= 0, w2 >= 0 else { continue }
                let uv = layout.uvs[i * 3] * w0 + layout.uvs[i * 3 + 1] * w1 + layout.uvs[i * 3 + 2] * w2
                let px = min(255, Int(uv.x * 256)), py = min(255, Int(uv.y * 256))
                return Int(map[(py * 256 + px) * 4])
            }
            return -1
        }
        // Sun from +X at 45 degrees: an 800-tall box shadows x in -200...-1000 behind it.
        check(shade(-600, 0) < 40, "ground behind the box is in shadow (\(shade(-600, 0)))")
        check(shade(600, 0) > 240, "ground in front of the box is lit (\(shade(600, 0)))")
        check(shade(-600, 1200) > 240, "ground beside the shadow is lit (\(shade(-600, 1200)))")
        check(shade(-1400, 0) > 240, "ground past the shadow's end is lit (\(shade(-1400, 0)))")

        // Rebuild through the app's path and read it back.
        let shadowed = try ShadowMap.shadow(model, in: parsed, options: opts, shadowColor: (0x4C, 0x4C, 0x56), kageName: "course_kage")
        check(shadowed.receivers == 2, "both textured materials receive shadows")
        // The sheet's live preview: installed into a copy, drawn with the kage as a lightmap.
        let installed = ShadowMap.applying(shadowed, model: model, to: parsed)
        let preview = installed.flatMap { d in d.resources.first { $0.magic == "MDL0" }.flatMap { MDL0Parser.parse($0, rawFile: d.rawData) } }
        check(parsed.resources.contains { $0.magic == "MDL0" } && !parsed.resources.contains { $0.name == "course_kage" }, "preview leaves the original document alone")
        let node = preview.map { MDL0SceneKit.node(for: $0, textures: MDL0SceneKit.textureImages(in: installed!)) }
        let lightmapped = node?.childNodes { n, _ in n.geometry?.firstMaterial?.multiply.contents != nil }.count ?? 0
        check(lightmapped == 2, "preview draws the shadow map on both receivers (\(lightmapped))")
        parsed.resources.removeAll { $0.magic == "MDL0" }
        parsed.resources.append(BRRESResource(name: "course_kage", folderName: "Textures(NW4R)", data: shadowed.kage))
        parsed.resources.append(BRRESResource(name: "course", folderName: "3DModels(NW4R)", data: shadowed.model.data, stringReferences: shadowed.model.stringReferences))
        let shadowedFile = parsed.serialize()
        // SHADOW_OUT=path writes the shadowed BRRES, e.g. for Tests/GXDisplayListCheck.
        if let out = ProcessInfo.processInfo.environment["SHADOW_OUT"] { try shadowedFile.write(to: URL(fileURLWithPath: out)) }
        let again = try BRRESDocument.parse(shadowedFile)
        let r = again.resources.first { $0.magic == "MDL0" }!
        let reread = MDL0Parser.parse(r, rawFile: again.rawData)
        check(reread?.meshes.count == 2, "shadowed model re-reads")
        for m in reread?.meshes ?? [] {
            check(m.textureNames.count == 2 && m.textureNames[1] == "course_kage", "\(m.materialName ?? "?") samples [\(m.textureNames.joined(separator: ", "))]")
            check(m.vertices.allSatisfy { $0.uv1 != nil }, "\(m.materialName ?? "?") has its shadow UV set")
        }
        let d = r.data
        let meshDict = Int(d.be32(0x10 + 10 * 4))
        for e in BRRESIndexGroup.parse(d, groupStart: meshDict, names: (again.rawData, r.fileOffset)) {
            let m = e.dataOffset
            check(d.be32(m + 0x10) == 0xF && d.be32(m + 0x14) == 0x25 && d.be32(m + 0x30) == 0x6E00,
                  "\(e.name) declares two texcoords (cp \(String(d.be32(m + 0x10), radix: 16)) xf \(String(d.be32(m + 0x14), radix: 16)) attr \(String(d.be32(m + 0x30), radix: 16)))")
        }

        // Against retail.
        let args = CommandLine.arguments
        let roms = "\(ProcessInfo.processInfo.environment["ROMS_DIR"] ?? "Roms")/"
        let iso = args.count > 1 ? args[1] : roms + "Wii/MKWii/Mario Kart Wii (USA) (En,Fr,Es).iso"
        let key = args.count > 2 ? args[2] : roms + "Wii/Keys/common-key"
        let disc = try WiiDisc(url: URL(fileURLWithPath: iso), commonKey: [UInt8](try Data(contentsOf: URL(fileURLWithPath: key))), koreanKey: nil)
        func find(_ n: DiscNode) -> DiscNode? { n.name == "beginner_course.szs" ? n : n.children.lazy.compactMap(find).first }
        let (root, _) = try SZS.open(try disc.readFile(node: find(disc.root)!))
        let retailDoc = try BRRESDocument.parse(root.children.first { $0.name == "course_model.brres" }!.data!)
        let retail = retailDoc.resources.first { $0.magic == "MDL0" }!
        func material(_ res: BRRESResource, _ file: Data, _ name: String) -> Int? {
            BRRESIndexGroup.parse(res.data, groupStart: Int(res.data.be32(0x10 + 8 * 4)), names: (file, res.fileOffset)).first { $0.name == name }?.dataOffset
        }
        guard let rm = material(retail, retailDoc.rawData, "a_MainRoad_m"), let om = material(r, again.rawData, "ground") else { check(false, "materials found"); exit(1) }
        let rd = retail.data
        func bytes(_ x: Data, _ o: Int, _ n: Int) -> Data { x.subdata(in: (x.startIndex + o)..<(x.startIndex + o + n)) }
        check(bytes(rd, rm + 0x14, 4) == bytes(d, om + 0x14, 4), "genMode matches retail (2 texgens, 1 channel, 2 stages)")
        check(rd.be32(rm + 0x2C) == d.be32(om + 0x2C), "two samplers, as retail")
        let rdl = bytes(rd, rm + Int(rd.be32(rm + 0x3C)), 0x180), odl = bytes(d, om + Int(d.be32(om + 0x3C)), 0x180)
        check(rdl == odl, "material display list byte-identical to retail")
        if rdl != odl, let i = zip(rdl, odl).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset {
            print("  first difference at 0x\(String(i, radix: 16)): retail \(rdl[max(0, i - 8)..<min(0x180, i + 12)].map { String(format: "%02x", $0) }.joined()) built \(odl[max(0, i - 8)..<min(0x180, i + 12)].map { String(format: "%02x", $0) }.joined())")
        }
        let rt = rm + Int(Int32(bitPattern: rd.be32(rm + 0x28))), ot = om + Int(Int32(bitPattern: d.be32(om + 0x28)))
        check(bytes(rd, rt + 12, 12) == bytes(d, ot + 12, 12), "TEV header (stages, texcoord map) matches retail")
        check(bytes(rd, rt + 0x20, 0x1E0) == bytes(d, ot + 0x20, 0x1E0), "TEV display list byte-identical to retail")
        let rs = rm + Int(rd.be32(rm + 0x30)) + 0x34, os = om + Int(d.be32(om + 0x30)) + 0x34
        check(bytes(rd, rs + 4, 0x30) == bytes(d, os + 4, 0x30), "shadow sampler matches retail's")
        let srt = 0x40 + (4 + 8 * 12) + (4 + 8 * 32)
        check(d.be32(om + srt) == 0xFF, "texture matrices 0 and 1 enabled (retail 0xFF/0xFD)")
        // Shadowing real courses: retail winds clockwise, so with facing taken from the normals
        // (13% of texels non-black when that was ignored; 48% now, retail's own kage 60%)
        // (or the back-cull) most of Luigi Circuit is lit, not black; and Moo Moo Meadows' grass,
        // which samples its old lightmap first, keeps its colour texture.
        var realOpts = ShadowMap.Options()
        realOpts.size = 1024; realOpts.samples = 2
        let luigiShadow = try ShadowMap.shadow(retail, in: retailDoc, options: realOpts, shadowColor: (0x4C, 0x4C, 0x56), kageName: "course_kage")
        let lit = stride(from: 0, to: luigiShadow.map.count, by: 4).filter { luigiShadow.map[$0] > 40 }.count * 400 / luigiShadow.map.count
        check(lit > 35, "Luigi Circuit's shadow map is mostly not black (\(lit)% of texels)")
        func course(_ file: String) throws -> BRRESDocument {
            let (r, _) = try SZS.open(try disc.readFile(node: { func f(_ n: DiscNode) -> DiscNode? { n.name == file ? n : n.children.lazy.compactMap(f).first }; return f(disc.root)! }()))
            return try BRRESDocument.parse(r.children.first { $0.name == "course_model.brres" }!.data!)
        }
        let farm = try course("farm_course.szs")
        let farmShadow = try ShadowMap.shadow(farm.resources.first { $0.magic == "MDL0" && $0.name == "course" }!, in: farm, options: realOpts, shadowColor: (0x4C, 0x4C, 0x56), kageName: "course_kage")
        let farmDoc = ShadowMap.applying(farmShadow, model: farm.resources.first { $0.magic == "MDL0" && $0.name == "course" }!, to: farm)!
        let farmModel = MDL0Parser.parse(farmDoc.resources.first { $0.magic == "MDL0" && $0.name == "course" }!, rawFile: farmDoc.rawData)!
        let grass = farmModel.meshes.filter { $0.textureNames.first == "gard" }
        check(!grass.isEmpty && grass.allSatisfy { $0.textureNames == ["gard", "course_kage"] }, "Moo Moo Meadows' grass keeps its colour texture: \(grass.first?.textureNames ?? [])")
        print(failures == 0 ? "ok" : "\(failures) failures")
        if failures > 0 { exit(1) }
    }
}
