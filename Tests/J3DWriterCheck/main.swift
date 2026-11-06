// J3D writer check, against a retail Mario Kart: Double Dash!! disc:
// - every retail course and sky model, read with `J3DModel` and rewritten with `J3DWriter`, reads
//   back with the same triangles (positions, vertex colours, UVs), materials' textures and
//   transparency, and textures (pixels);
// - the written file has retail's structure: the same section order, 32-byte alignment, header,
//   one joint/draw matrix/no envelopes, the same vertex formats' kinds, 0x14C material records
//   and table order, and name hashes computed the way retail's are ("world_root" = 0x6A6F);
// - `J3DToWii` (the Double Dash -> Wii port) accepts the written model.
//
//   find "Revolution IDE/Core" -name '*.swift' ! -path '*/Workbench/*' ! -name AppState.swift \
//     ! -name SyntaxHighlighter.swift | tr '\n' '\0' | xargs -0 swiftc -O -parse-as-library -o /tmp/j3dcheck \
//     "Revolution IDE/Core/Workbench/BaseGameLibrary.swift" Tests/J3DWriterCheck/*.swift
//   /tmp/j3dcheck [mkdd.iso]

import Foundation

@main enum J3DWriterCheck {
    /// Writer input from a parsed model: each material's first texturing stage's texture.
    static func input(_ m: J3DModel.Model) -> ([J3DWriter.Triangle], [J3DWriter.Material], [J3DWriter.Texture]) {
        let textures = m.textures.map { t -> J3DWriter.Texture in
            let rgba = t.decoded() ?? []
            let encoded = t.encoded ?? TextureCodec.encode(rgba: rgba, width: t.width, height: t.height, format: .rgba32) ?? Data()
            return J3DWriter.Texture(name: t.name, format: t.encoded == nil ? .rgba32 : t.format, width: t.width, height: t.height, encoded: encoded,
                                     wrapS: t.wrapS, wrapT: t.wrapT, hasAlpha: rgba.enumerated().contains { $0.offset % 4 == 3 && $0.element < 255 })
        }
        func texturing(_ mat: J3DModel.Material) -> (texture: Int, coord: Int)? {
            guard let s = mat.stages.first(where: { $0.texMap != 0xFF }), s.texMap < 8, let t = mat.textures[Int(s.texMap)] else { return nil }
            let gen = Int(s.texCoord) < mat.texGens.count ? Int(mat.texGens[Int(s.texCoord)].source) - 4 : 0
            return (t, max(0, min(7, gen)))
        }
        let materials = m.materials.map { mat -> J3DWriter.Material in
            let transparency: J3DWriter.Transparency = mat.blend.0 == 1 ? .translucent : (mat.alphaTest.0 != 7 || mat.alphaTest.3 != 7 ? .alphaTest : .opaque)
            return J3DWriter.Material(name: mat.name, texture: texturing(mat)?.texture, cull: min(mat.cull, 2), transparency: transparency)
        }
        let triangles = m.triangles.map { t -> J3DWriter.Triangle in
            let coord = texturing(m.materials[t.material])?.coord ?? 0
            func v(_ x: J3DModel.Vertex) -> J3DWriter.Vertex { J3DWriter.Vertex(position: x.position, color: [x.color.0, x.color.1, x.color.2, x.color.3], uv: x.uv[coord]) }
            return J3DWriter.Triangle(v: (v(t.v.0), v(t.v.1), v(t.v.2)), material: t.material)
        }
        return (triangles, materials, textures)
    }

    static func main() throws {
        var failures = 0
        func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL", what); failures += 1 } }
        check(J3DWriter.hash("world_root") == 0x6A6F, "name hash: world_root = 0x6A6F (got \(String(J3DWriter.hash("world_root"), radix: 16)))")
        let iso = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "\(ProcessInfo.processInfo.environment["ROMS_DIR"] ?? "Roms")/GCN/MKDD/Mario Kart - Double Dash!! (USA).iso"
        let disc = try GameCubeDisc(url: URL(fileURLWithPath: iso))
        var arcs: [DiscNode] = []
        func walk(_ n: DiscNode) { if n.isDirectory { n.children.forEach(walk) } else if n.name.hasSuffix(".arc"), !n.name.hasSuffix("L.arc") { arcs.append(n) } }
        walk(disc.root)
        var models = 0, sample: Data?
        for arc in arcs where !["Award.arc", "Ending.arc"].contains(arc.name) {
            guard let (root, _) = try? SZS.open(try disc.readFile(node: arc)) else { continue }
            for file in root.children where file.name.hasSuffix("_course.bmd") || file.name.hasSuffix("_sky.bmd") {
                let original = try J3DModel.parse(file.data!)
                let (tris, mats, texs) = input(original)
                let written: Data
                do { written = try J3DWriter.bmd(triangles: tris, materials: mats, textures: texs) } catch { check(false, "\(arc.name)/\(file.name): \(error)"); continue }
                models += 1
                if sample == nil, file.name.hasSuffix("_sky.bmd") { sample = written }
                let back = try J3DModel.parse(written)
                let name = "\(arc.name)/\(file.name)"
                check(back.triangles.count == tris.count, "\(name): \(back.triangles.count) triangles back, wrote \(tris.count)")
                // Same triangles in the same order per material.
                var mismatch = 0
                let byMat = Dictionary(grouping: tris, by: \.material), backByMat = Dictionary(grouping: back.triangles, by: \.material)
                for (m, list) in byMat {
                    let b = backByMat[m] ?? []
                    if b.count != list.count { mismatch += 1; continue }
                    for (x, y) in zip(list, b) {
                        for (p, q) in [(x.v.0, y.v.0), (x.v.1, y.v.1), (x.v.2, y.v.2)] {
                            let uvOK = p.uv == nil || q.uv[0] == p.uv
                            if p.position != q.position || p.color != [q.color.0, q.color.1, q.color.2, q.color.3] || !uvOK { mismatch += 1 }
                        }
                    }
                }
                check(mismatch == 0, "\(name): \(mismatch) vertex mismatches after round trip")
                check(back.materials.count == mats.count, "\(name): \(back.materials.count) materials back, wrote \(mats.count)")
                for (i, (w, r)) in zip(mats, back.materials).enumerated() {
                    let tex = r.stages.first.flatMap { $0.texMap < 8 ? r.textures[Int($0.texMap)] : nil }
                    check(tex == w.texture, "\(name): material \(i) texture \(String(describing: tex)) vs \(String(describing: w.texture))")
                    check(r.name == w.name, "\(name): material \(i) name \(r.name) vs \(w.name)")
                    let tr: J3DWriter.Transparency = r.blend.0 == 1 ? .translucent : (r.alphaTest.0 != 7 ? .alphaTest : .opaque)
                    check(tr == w.transparency && r.cull == w.cull, "\(name): material \(i) transparency/cull")
                }
                check(back.textures.count == texs.count, "\(name): \(back.textures.count) textures back")
                for (a, b) in zip(original.textures, back.textures) where a.decoded() != b.decoded() { check(false, "\(name): texture \(a.name) pixels differ") }
                check((try? J3DToWii.brres(from: back, modelName: "course", scale: 1)) != nil, "\(name): J3DToWii accepts it")
                // Structure: sections in retail order, aligned.
                var o = 0x20, order: [String] = []
                while o + 8 <= written.count { order.append(written.asciiString(at: o, length: 4)); if o % 32 != 0 { check(false, "\(name): section at \(o) unaligned") }; o += Int(written.be32(o + 4)) }
                check(order == ["INF1", "VTX1", "EVP1", "DRW1", "JNT1", "SHP1", "MAT3", "TEX1"] && o == written.count && Int(written.be32(8)) == written.count, "\(name): sections \(order)")
            }
        }
        check(models >= 30, "rewrote \(models) retail models")
        if let sample { print(BMDDump.dump(sample)) }
        print(failures == 0 ? "ok   \(models) retail Double Dash models rewrite and read back identically" : "FAIL \(failures)")
        if failures > 0 { exit(1) }
    }
}
