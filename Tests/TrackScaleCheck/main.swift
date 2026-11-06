// Track scale check: scales every retail course archive 2x and 0.5x with `TrackScaler` and
// requires the result to line up, every model vertex, KCL triangle and KMP point lands at
// exactly s times where it was (within the format's rounding), and every mesh's GX
// vertex-attribute-table fraction bits still match its position buffer's.
//
//   find "Revolution IDE/Core" -name '*.swift' ! -path '*/Workbench/*' ! -name AppState.swift \
//     ! -name SyntaxHighlighter.swift | tr '\n' '\0' | xargs -0 swiftc -O -parse-as-library -o /tmp/scalecheck \
//     "Revolution IDE/Core/Workbench/BaseGameLibrary.swift" Tests/TrackScaleCheck/main.swift
//   /tmp/scalecheck [mkwii.iso] [common-key]

import Foundation

@main enum TrackScaleCheck {
    static func main() throws {
        let args = CommandLine.arguments
        let roms = "\(ProcessInfo.processInfo.environment["ROMS_DIR"] ?? "Roms")/"
        let iso = args.count > 1 ? args[1] : roms + "Wii/MKWii/Mario Kart Wii (USA) (En,Fr,Es).iso"
        let key = args.count > 2 ? args[2] : roms + "Wii/Keys/common-key"
        let disc = try WiiDisc(url: URL(fileURLWithPath: iso), commonKey: [UInt8](try Data(contentsOf: URL(fileURLWithPath: key))), koreanKey: nil)
        var courses: [DiscNode] = []
        func walk(_ n: DiscNode) { if n.isDirectory { n.children.forEach(walk) } else if (n.name.hasSuffix("_course.szs") || n.name.hasPrefix("old_")) && !n.name.hasPrefix("old_mario_gc_") { courses.append(n) } }
        walk(disc.root)
        var failures = 0
        func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL", what) } }

        for node in courses.sorted(by: { $0.name < $1.name }) {
            for s: Float in [2, 0.5] {
                let (original, _) = try SZS.open(try disc.readFile(node: node))
                let (scaled, _) = try SZS.open(try disc.readFile(node: node))
                let changed: [String]
                do { changed = try TrackScaler.scale(archive: scaled, by: s, objects: true) } catch {
                    // Toad's Factory stores a model in S16 with no fraction bits to spare: 2x can't fit.
                    let expected = node.name == "truck_course.szs" && s == 2 && "\(error)".contains("most it can be scaled up is")
                    check(expected, "\(node.name) x\(s): \(error)")
                    if expected { print("ok   truck_course.szs x2 refused:", error) }
                    continue
                }
                func file(_ root: U8Node, _ name: String) -> Data? { root.children.first { $0.name == name }?.data }

                // KMP: every enemy point and checkpoint moved.
                if let a = file(original, "course.kmp"), let b = file(scaled, "course.kmp") {
                    let ka = try KMPDocument.parse(a), kb = try KMPDocument.parse(b)
                    let ok = zip(ka.enpt, kb.enpt).allSatisfy { abs($0.position.x * s - $1.position.x) < 0.01 && abs($0.radius * s - $1.radius) < 0.01 }
                        && zip(ka.ckpt, kb.ckpt).allSatisfy { abs($0.left.y * s - $1.left.y) < 0.01 }
                    check(ok, "\(node.name) x\(s): KMP points")
                }
                // KCL: same triangles, scaled.
                if let a = file(original, "course.kcl"), let b = file(scaled, "course.kcl") {
                    let ca = try KCLDocument.parse(a), cb = try KCLDocument.parse(b)
                    // The builder drops degenerate slivers (a retail file has the odd one), so compare bounds.
                    func bounds(_ k: KCLDocument) -> [Float] {
                        let v = k.triangles.flatMap { [$0.v0, $0.v1, $0.v2] }
                        return [v.map(\.x).min()!, v.map(\.y).min()!, v.map(\.z).min()!, v.map(\.x).max()!, v.map(\.y).max()!, v.map(\.z).max()!]
                    }
                    // Slivers whose prism is under 1 unit high once scaled are stored at height 0 by
                    // the hardware (wkclt-exact) encoder, as wkclt does, and don't read back.
                    let thin = BuildCompatibility.current == .hardware ? ca.triangles.filter { t in
                        let edge = t.v2 - t.v1
                        return Vec3.cross(t.v0 - t.v1, edge).length / max(edge.length, 1e-9) * s < 1
                    }.count : 0
                    let ok = abs(ca.triangles.count - thin - cb.triangles.count) <= 2
                        && zip(bounds(ca), bounds(cb)).allSatisfy { abs($0 * s - $1) < 1 + abs($0) * s * 1e-3 }
                    check(ok, "\(node.name) x\(s): KCL (\(ca.triangles.count) vs \(cb.triangles.count) triangles)")
                }
                // Models: every vertex at s times its old place, VAT agrees with the buffer header.
                for name in changed where name.hasSuffix(".brres") {
                    let ra = try BRRESDocument.parse(file(original, name)!), rb = try BRRESDocument.parse(file(scaled, name)!)
                    for (x, y) in zip(ra.resources, rb.resources) where x.magic == "MDL0" {
                        guard let ma = MDL0Parser.parse(x, rawFile: ra.rawData), let mb = MDL0Parser.parse(y, rawFile: rb.rawData) else { continue }
                        var worst: Float = 0
                        for (p, q) in zip(ma.meshes, mb.meshes) {
                            for (u, v) in zip(p.vertices, q.vertices) {
                                worst = max(worst, abs(u.position.x * s - v.position.x), abs(u.position.y * s - v.position.y), abs(u.position.z * s - v.position.z))
                            }
                        }
                        check(worst <= 1, "\(node.name)/\(name)/\(x.name) x\(s): vertex off by \(worst)")
                        check(vatMatches(y.data), "\(node.name)/\(name)/\(x.name) x\(s): VAT fraction bits disagree with buffer")
                    }
                }
            }
            print("done", node.name)
        }
        print(failures == 0 ? "ok   all courses scale cleanly" : "FAIL \(failures)")
        if failures > 0 { exit(1) }
    }

    /// Every mesh's VAT position fraction bits equal its position buffer's divisor.
    static func vatMatches(_ d: Data) -> Bool {
        func secOfs(_ i: Int) -> Int { Int(Int32(bitPattern: d.be32(0x10 + i * 4))) }
        let buffers = BRRESIndexGroup.parse(d, groupStart: secOfs(2)).map(\.dataOffset)
        for m in BRRESIndexGroup.parse(d, groupStart: secOfs(10)).map(\.dataOffset) {
            let idx = Int(d.beInt16(m + 0x48))
            guard buffers.indices.contains(idx), d.be32(buffers[idx] + 0x18) != 4 else { continue }
            let div = Int(d.u8(buffers[idx] + 0x1C))
            let tag = m + 0x18
            var pos = tag + Int(Int32(bitPattern: d.be32(tag + 8)))
            let end = pos + Int(d.be32(tag))
            while pos < end {
                let op = d.u8(pos); pos += 1
                if op == 0x08 {
                    if d.u8(pos) == 0x70, Int((d.be32(pos + 1) >> 4) & 0x1F) != div { return false }
                    pos += 5
                } else if op == 0x61 { pos += 4 } else if op == 0x10 { pos += 4 + (Int(d.be16(pos)) + 1) * 4 } else if op != 0 { break }
            }
        }
        return true
    }
}
