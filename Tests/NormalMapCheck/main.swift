// Normal map check.
// - Retail: every encodable TEX0 in a few retail course models, re-encoded from its own pixels via
//   `TEX0View.rebuilding`, must come out the same size as the original, i.e. the whole mip
//   chain the header declares is written, and its top level must decode back to (near) the
//   original pixels.
// - A synthetic raised bump: normals must tilt away from its peak (x right, green up), and
//   baking with light from the right must brighten the bump's right side and darken its left,
//   while a flat normal map leaves the texture untouched.
//
//   find "Revolution IDE/Core" -name '*.swift' ! -path '*/Workbench/*' ! -name AppState.swift \
//     ! -name SyntaxHighlighter.swift | tr '\n' '\0' | xargs -0 swiftc -O -parse-as-library -o /tmp/normalcheck \
//     "Revolution IDE/Core/Workbench/BaseGameLibrary.swift" Tests/NormalMapCheck/main.swift
//   /tmp/normalcheck [mkwii.iso] [common-key]

import Foundation

@main enum NormalMapCheck {
    static func main() throws {
        var failures = 0
        func check(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failures += 1 } }

        // MARK: Synthetic bump
        let w = 64, h = 64
        var img = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let d = Float((x - 32) * (x - 32) + (y - 32) * (y - 32)).squareRoot()
            let v = UInt8(clamping: Int(max(0, 1 - d / 20) * 255))
            img[(y * w + x) * 4] = v; img[(y * w + x) * 4 + 1] = v; img[(y * w + x) * 4 + 2] = v
        } }
        let n = NormalMap.generate(rgba: img, width: w, height: h, options: .init(strength: 4, blur: 0, invert: false))
        func px(_ a: [UInt8], _ x: Int, _ y: Int, _ c: Int) -> Int { Int(a[(y * w + x) * 4 + c]) }
        check(px(n, 20, 32, 0) < 118 && px(n, 44, 32, 0) > 138, "normals tilt away from the peak along x (left \(px(n, 20, 32, 0)), right \(px(n, 44, 32, 0)))")
        check(px(n, 32, 20, 1) > 138 && px(n, 32, 44, 1) < 118, "green points up the image above the peak (above \(px(n, 32, 20, 1)), below \(px(n, 32, 44, 1)))")
        check(abs(px(n, 2, 2, 0) - 128) <= 1 && abs(px(n, 2, 2, 1) - 128) <= 1 && px(n, 2, 2, 2) == 255, "flat area is (128, 128, 255)")
        let grey = [UInt8](repeating: 160, count: w * h * 4).enumerated().map { $0.offset % 4 == 3 ? 255 : $0.element }
        let lit = NormalMap.bake(texture: grey, width: w, height: h, normals: n, normalWidth: w, normalHeight: h,
                                 light: .init(azimuth: 0, elevation: 30, intensity: 1, ambient: 0.3))
        check(px(lit, 44, 32, 0) > 170 && px(lit, 20, 32, 0) < 150, "light from the right brightens the right slope (\(px(lit, 44, 32, 0))) and darkens the left (\(px(lit, 20, 32, 0)))")
        check(abs(px(lit, 2, 2, 0) - 160) <= 1, "flat area keeps its colour (\(px(lit, 2, 2, 0)))")
        let flat: [UInt8] = Array(repeating: [128, 128, 255, 255] as [UInt8], count: 16).flatMap { $0 }
        let unchanged = NormalMap.bake(texture: img, width: w, height: h, normals: flat, normalWidth: 4, normalHeight: 4, light: .init())
        check(zip(unchanged, img).allSatisfy { abs(Int($0) - Int($1)) <= 1 }, "a flat normal map (any size) changes nothing")

        // MARK: Retail mip chains
        let args = CommandLine.arguments
        let roms = "\(ProcessInfo.processInfo.environment["ROMS_DIR"] ?? "Roms")/"
        let disc = try WiiDisc(url: URL(fileURLWithPath: args.count > 1 ? args[1] : roms + "Wii/MKWii/Mario Kart Wii (USA) (En,Fr,Es).iso"),
                               commonKey: [UInt8](try Data(contentsOf: URL(fileURLWithPath: args.count > 2 ? args[2] : roms + "Wii/Keys/common-key"))), koreanKey: nil)
        var nodes: [String: DiscNode] = [:]
        func walk(_ x: DiscNode) { if x.isDirectory { x.children.forEach(walk) } else { nodes[x.name] = x } }
        walk(disc.root)
        var checked = 0, mipmapped = 0, sizeWrong: [String] = [], pixelWrong: [String] = []
        for course in ["beginner_course.szs", "farm_course.szs", "castle_course.szs", "rainbow_course.szs"] {
            let (root, _) = try SZS.open(try disc.readFile(node: nodes[course]!))
            let doc = try BRRESDocument.parse(root.children.first { $0.name == "course_model.brres" }!.data!)
            for r in doc.resources where r.magic == "TEX0" {
                guard let v = TEX0View(r), let rgba = v.decodeRGBA(), let rebuilt = TEX0View.rebuilding(r, withRGBA: rgba) else { continue }
                checked += 1
                if v.mipCount > 1 { mipmapped += 1 }
                if rebuilt.count != r.data.count { sizeWrong.append("\(course)/\(r.name) \(v.format) mips \(v.mipCount): \(rebuilt.count) vs \(r.data.count)") }
                let back = BRRESResource(name: r.name, folderName: r.folderName, data: rebuilt, fileOffset: 0)
                if let again = TEX0View(back)?.decodeRGBA() {
                    // Alpha must agree (CMPR's 1-bit alpha included); colour is compared on
                    // visible texels only, as a mean. CMPR is lossy per 4x4 block by design.
                    var alphaWrong = 0, err = 0, n = 0
                    for i in stride(from: 0, to: min(again.count, rgba.count), by: 4) {
                        if (again[i + 3] < 128) != (rgba[i + 3] < 128) { alphaWrong += 1 }
                        guard rgba[i + 3] >= 128 else { continue }
                        for c in 0..<3 { err += abs(Int(again[i + c]) - Int(rgba[i + c])) }
                        n += 3
                    }
                    let mean = Double(err) / Double(max(n, 1))
                    if alphaWrong > 0 || mean > (v.format == .cmpr ? 6 : 2) {
                        pixelWrong.append("\(r.name) \(v.format) alpha mismatches \(alphaWrong), mean colour error \(String(format: "%.1f", mean))")
                    }
                }
            }
        }
        check(checked > 50 && mipmapped > 10, "retail sample: \(checked) textures, \(mipmapped) mipmapped")
        check(sizeWrong.isEmpty, "every re-encoded texture is the original's size (whole mip chain): \(sizeWrong.prefix(5))")
        check(pixelWrong.isEmpty, "every re-encoded top level decodes back to its pixels: \(pixelWrong.prefix(5))")
        if failures > 0 { exit(1) }
    }
}
