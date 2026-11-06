// BTK writer check against every retail Double Dash .btk: parse, write, re-parse gives the same
// animation (names, matrices, centres, durations and every track sampled across its length), and
// the header matches the retail file's.
//
//   find "Revolution IDE/Core" -name '*.swift' ! -path '*/Workbench/*' ! -name AppState.swift \
//     ! -name SyntaxHighlighter.swift | tr '\n' '\0' | xargs -0 swiftc -O -parse-as-library -o /tmp/btkcheck \
//     "Revolution IDE/Core/Workbench/BaseGameLibrary.swift" Tests/BTKCheck/main.swift
//   /tmp/btkcheck [mkdd.iso]

import Foundation

@main enum BTKCheck {
    static func main() throws {
        var failures = 0, checked = 0, sameSize = 0
        func fail(_ s: String) { failures += 1; if failures < 20 { print("FAIL", s) } }
        let iso = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "\(ProcessInfo.processInfo.environment["ROMS_DIR"] ?? "Roms")/GCN/MKDD/Mario Kart - Double Dash!! (USA).iso"
        let disc = try GameCubeDisc(url: URL(fileURLWithPath: iso))
        func check(_ path: String, _ data: Data) {
            guard let a = try? J3DAnimation.parse(data), a.kind == .textureSRT else { return }
            checked += 1
            guard let out = try? J3DAnimation.serializeBTK(a), let b = try? J3DAnimation.parse(out) else { fail("\(path): write/re-parse failed"); return }
            if out.count == data.count { sameSize += 1 }
            if checked < 3 { print(path, "retail", data.count, "built", out.count)
                for (l, d) in [("retail", data), ("built ", out)] { print(l, stride(from: 0, to: min(d.count, 0x80), by: 4).map { String(format: "%08X", d.be32($0)) }.joined(separator: " ")) } }
            guard a.duration == b.duration, a.loopMode == b.loopMode, a.targets.count == b.targets.count else { fail("\(path): header differs"); return }
            for (x, y) in zip(a.targets, b.targets) {
                if x.name != y.name || x.texMatrix != y.texMatrix || x.center != y.center { fail("\(path): target \(x.name) metadata differs"); continue }
                for (tx, ty) in zip(x.scale + x.rotation + x.translation, y.scale + y.rotation + y.translation) {
                    for f in stride(from: Float(0), through: Float(a.duration), by: 1) where abs(tx.value(at: f) - ty.value(at: f)) > 0.1 + 1e-3 * abs(tx.value(at: f)) {
                        fail("\(path): \(x.name) at \(f): \(tx.value(at: f)) vs \(ty.value(at: f))"); break
                    }
                }
            }
        }
        var converted = 0
        /// BTK -> SRT0 BRRES -> back to BTK: the 2D channels (scale S/T, rotation Q, translation S/T) must survive.
        func roundTrip(_ path: String, _ data: Data) {
            guard let a = try? J3DAnimation.parse(data), a.kind == .textureSRT else { return }
            guard let brres = try? MKDDFileConvert.btkToSRT0BRRES(data, name: "t"), let back = try? J3DAnimation.parse(MKDDFileConvert.brresToBTK(brres)) else { fail("\(path): BTK <-> SRT0 failed"); return }
            converted += 1
            guard back.targets.count == a.targets.count else { fail("\(path): \(back.targets.count) targets back, \(a.targets.count) sent"); return }
            // Translations come back for a centre of 0.5 (SRT0 has none): compare the matrix offsets they give.
            func offset(_ t: J3DAnimation.Target, _ axis: Int, _ f: Float) -> Float {
                let sS = t.scale[0].value(at: f), sT = t.scale[1].value(at: f), r = t.rotation[2].value(at: f) * .pi / 180, c = t.center
                return t.translation[axis].value(at: f) + (axis == 0 ? c[0] - (sS * cos(r) * c[0] - sS * sin(r) * c[1]) : c[1] - (sT * sin(r) * c[0] + sT * cos(r) * c[1]))
            }
            for (x, y) in zip(a.targets, back.targets) {
                let pairs: [(String, (Float) -> Float, (Float) -> Float)] = [
                    ("scale S", { x.scale[0].value(at: $0) }, { y.scale[0].value(at: $0) }), ("scale T", { x.scale[1].value(at: $0) }, { y.scale[1].value(at: $0) }),
                    ("rotation", { x.rotation[2].value(at: $0) }, { y.rotation[2].value(at: $0) }),
                    ("offset S", { offset(x, 0, $0) }, { offset(y, 0, $0) }), ("offset T", { offset(x, 1, $0) }, { offset(y, 1, $0) })]
                for (what, tx, ty) in pairs {
                    for f in stride(from: Float(0), through: Float(a.duration), by: 1) where abs(tx(f) - ty(f)) > 0.1 + 1e-3 * abs(tx(f)) {
                        fail("\(path): \(x.name) \(what) at \(f): \(tx(f)) vs \(ty(f))"); break
                    }
                }
            }
        }
        func walk(_ n: DiscNode) {
            if n.isDirectory { n.children.forEach(walk); return }
            guard let d = try? disc.readFile(node: n) else { return }
            if n.name.hasSuffix(".btk") { check(n.name, d); roundTrip(n.name, d) }
            guard n.name.hasSuffix(".arc"), let (root, _) = try? SZS.open(d) else { return }
            func arc(_ a: U8Node) { if a.isDirectory { a.children.forEach(arc) } else if a.name.hasSuffix(".btk"), let x = a.data { check(n.name + "/" + a.name, x); roundTrip(n.name + "/" + a.name, x) } }
            arc(root)
        }
        walk(disc.root)
        print("retail BTKs checked: \(checked), \(sameSize) the same size, \(converted) converted to SRT0 and back")
        if checked == 0 { fail("no BTK found") }
        print(failures == 0 ? "ok" : "\(failures) failures")
        if failures > 0 { exit(1) }
    }
}
