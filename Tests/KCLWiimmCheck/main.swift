// KCLWiimm vs the real wkclt: the same triangles (retail beginner_course's collision, and any
// .obj given) go through Wiimm's `wkclt encode` (default MEDIUM settings, as Blender MKW Utilities
// calls it) and through `KCLWiimm.build`; the octree parameters, the kept triangles, every
// prism's data and every octree leaf list must match. wkclt adds one signature vertex to the
// front of its vertex list (its encoder stamp); vertex indices are compared allowing for it.
//
//   build wkclt from Wiimm's SZS tools, then:
//   find "Revolution IDE/Core" -name '*.swift' ! -path '*/Workbench/*' ! -name AppState.swift \
//     ! -name SyntaxHighlighter.swift -print0 | xargs -0 swiftc -O -parse-as-library -o /tmp/kclwiimm \
//     "Revolution IDE/Core/Workbench/BaseGameLibrary.swift" Tests/KCLWiimmCheck/*.swift
//   WKCLT=/path/to/wkclt /tmp/kclwiimm [model.obj ...]

import Foundation

struct Parsed {
    var header: [UInt32]
    var vertices: [[UInt32]], normals: [[UInt32]]
    var prisms: [(len: UInt32, idx: [UInt16], flag: UInt16)]
    var octree: Data
}

func parse(_ d: Data) -> Parsed {
    let po = Int(d.be32(0)), no = Int(d.be32(4)), pr = Int(d.be32(8)) + 0x10, bo = Int(d.be32(12))
    func v3(_ o: Int) -> [UInt32] { [d.be32(o), d.be32(o + 4), d.be32(o + 8)] }
    return Parsed(header: (0..<15).map { d.be32($0 * 4) },
                  vertices: stride(from: po, to: no, by: 12).map(v3), normals: stride(from: no, to: pr, by: 12).map(v3),
                  prisms: stride(from: pr, to: bo, by: 16).map { o in (d.be32(o), (0..<5).map { k in d.be16(o + 4 + k * 2) }, d.be16(o + 14)) },
                  octree: d.subdata(at: bo, length: d.count - bo))
}

@main enum KCLWiimmCheck {
    static func main() throws {
        guard let wkclt = ProcessInfo.processInfo.environment["WKCLT"] else { print("set WKCLT to wkclt's path"); exit(2) }
        var failures = 0
        func check(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failures += 1 } }
        var cases: [(String, [KCLTriangle])] = []
        // Retail collision, decoded.
        let roms = "\(ProcessInfo.processInfo.environment["ROMS_DIR"] ?? "Roms")/"
        let disc = try WiiDisc(url: URL(fileURLWithPath: roms + "Wii/MKWii/Mario Kart Wii (USA) (En,Fr,Es).iso"),
                               commonKey: [UInt8](try Data(contentsOf: URL(fileURLWithPath: roms + "Wii/Keys/common-key"))), koreanKey: nil)
        func find(_ n: DiscNode, _ name: String) -> DiscNode? { n.name == name ? n : n.children.lazy.compactMap { find($0, name) }.first }
        for course in ["beginner_course.szs", "castle_course.szs"] {
            let (root, _) = try SZS.open(try disc.readFile(node: find(disc.root, course)!))
            cases.append((course, try KCLDocument.parse(root.children.first { $0.name == "course.kcl" }!.data!).triangles))
        }
        for path in CommandLine.arguments.dropFirst() {
            let tris = OBJImporter.parse(try String(contentsOfFile: path, encoding: .utf8)).map {
                KCLTriangle.facingUp($0.v0, $0.v1, $0.v2, attribute: 0)
            }
            cases.append(((path as NSString).lastPathComponent, tris))
        }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        for (name, tris) in cases {
            // The same floats to both: %.9g round-trips a Float exactly.
            var obj = "", byFlag: [UInt16: [Int]] = [:]
            for (i, t) in tris.enumerated() {
                for v in [t.v0, t.v1, t.v2] { obj += String(format: "v %.9g %.9g %.9g\n", v.x, v.y, v.z) }
                byFlag[t.attribute, default: []].append(i)
            }
            // wkclt keeps file order within a material; write one material run per flag, and feed
            // our encoder the same order.
            var order: [Int] = []
            for flag in byFlag.keys.sorted() {
                obj += String(format: "g m_F%04X\n", flag) // wkclt reads flags from group names
                for i in byFlag[flag]! { obj += "f \(i * 3 + 1) \(i * 3 + 2) \(i * 3 + 3)\n"; order.append(i) }
            }
            let objURL = tmp.appendingPathComponent("kclwiimm.obj"), kclURL = tmp.appendingPathComponent("kclwiimm.kcl")
            try obj.write(to: objURL, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: wkclt)
            p.arguments = ["encode", objURL.path, "--dest", kclURL.path, "-o", "-q", "--kcl=MEDIUM"] // as Blender MKW Utilities calls it
            try p.run(); p.waitUntilExit()
            let ref = parse(try Data(contentsOf: kclURL))
            // The doubles wkclt reads from that text.
            func dbl(_ v: Vec3) -> SIMD3<Double> { SIMD3((0..<3).map { Double(String(format: "%.9g", [v.x, v.y, v.z][$0]))! }) }
            let built = KCLWiimm.build(order.map { (dbl(tris[$0].v0), dbl(tris[$0].v1), dbl(tris[$0].v2), tris[$0].attribute) })
            let ours = parse(built.data)
            print("== \(name): \(tris.count) triangles, wkclt kept \(ref.prisms.count), ours \(ours.prisms.count) (dropped \(built.dropped))")
            check(ref.header[4...14] == ours.header[4...14], "\(name): octree parameters match \(Array(ours.header[4...14]).map { String($0, radix: 16) })")
            check(ref.prisms.count == ours.prisms.count, "\(name): same triangles kept")
            check(ref.vertices.count == ours.vertices.count + 1 && Array(ref.vertices.dropFirst()) == ours.vertices, "\(name): same vertices (wkclt's plus its signature)")
            if ProcessInfo.processInfo.environment["DEBUG"] != nil, ref.vertices.count == ours.vertices.count + 1 {
                for (k, (r, o)) in zip(ref.vertices.dropFirst(), ours.vertices).enumerated() where r != o {
                    print("  vertex \(k):", r.map { Float(bitPattern: $0) }, "vs", o.map { Float(bitPattern: $0) }); break
                }
            }
            check(ref.normals == ours.normals, "\(name): same normals, bit for bit (\(ref.normals.count) vs \(ours.normals.count))")
            let prismsMatch = zip(ref.prisms, ours.prisms).allSatisfy { r, o in r.len == o.len && r.flag == o.flag && r.idx[0] == o.idx[0] + 1 && Array(r.idx[1...]) == Array(o.idx[1...]) }
            check(prismsMatch, "\(name): every prism matches (height, vertex, normals, flag)")
            if !prismsMatch, ProcessInfo.processInfo.environment["DEBUG"] != nil {
                var shown = 0
                for (k, (r, o)) in zip(ref.prisms, ours.prisms).enumerated() where shown < 4 {
                    let rn = r.idx[1...].map { ref.normals[Int($0)] }, on = o.idx[1...].map { ours.normals[Int($0)] }
                    if r.len != o.len || rn != on || r.flag != o.flag {
                        shown += 1
                        print("  prism \(k): len \(String(r.len, radix: 16)) vs \(String(o.len, radix: 16)); flag \(r.flag) vs \(o.flag)")
                        for (a, b) in zip(rn, on) where a != b { print("    nrm", a.map { String($0, radix: 16) }, "vs", b.map { String($0, radix: 16) }, a.map { Float(bitPattern: $0) }, b.map { Float(bitPattern: $0) }) }
                    }
                }
            }
            // Leaf by leaf: the same triangles, except that KCLWiimm deliberately leaves out
            // zero-area triangles (two corners the same), which wkclt still lists, in the game such
            // a prism has all-zero normals and "collides" with nothing to push against.
            let degenerate = Set(ours.prisms.indices.filter { ours.prisms[$0].len == 0 }.map { UInt16($0 + 1) })
            func leaves(_ o: Data, roots: Int) -> [[UInt16]] {
                var out: [[UInt16]] = []
                func list(_ at: Int) -> [UInt16] { var r: [UInt16] = []; var q = at + 2; while q + 2 <= o.count, o.be16(q) != 0 { r.append(o.be16(q)); q += 2 }; return r }
                func walk(_ group: Int, _ count: Int) {
                    for i in 0..<count {
                        let v = o.be32(group + i * 4)
                        if v & 0x8000_0000 != 0 { out.append(list(group + Int(v & 0x7FFF_FFFF))) } else { walk(group + Int(v), 8) }
                    }
                }
                walk(0, roots)
                return out
            }
            let nRoots = { (h: [UInt32]) -> Int in
                // Root count = 2^(nbits x+y+z); z bits come from the mask width minus the cube shift.
                let rel = (0..<3).map { 32 - (h[8 + $0] == 0 ? 0 : UInt32(h[8 + $0]).nonzeroBitCount) }
                let shift = Int(h[11])
                return rel.reduce(1) { $0 << max(0, $1 - shift) }
            }(ours.header)
            let refLeaves = leaves(ref.octree, roots: nRoots).map { $0.filter { !degenerate.contains($0) } }
            let ourLeaves = leaves(ours.octree, roots: nRoots)
            check(refLeaves == ourLeaves, "\(name): every octree leaf lists the same triangles (\(ourLeaves.count) leaves)")
            check(ref.octree.count == ours.octree.count || !degenerate.isEmpty, "\(name): octree the same size as wkclt's (\(ref.octree.count) vs \(ours.octree.count) bytes)")
            if ref.octree != ours.octree, ProcessInfo.processInfo.environment["DEBUG"] != nil {
                let first = zip(ref.octree, ours.octree).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(ref.octree.count, ours.octree.count)
                let a = max(0, (first & ~3) - 16)
                print("  first difference at octree byte 0x\(String(first, radix: 16))")
                print("   wkclt:", ref.octree.subdata(at: a, length: min(48, ref.octree.count - a)).map { String(format: "%02x", $0) }.joined())
                print("   ours: ", ours.octree.subdata(at: a, length: min(48, ours.octree.count - a)).map { String(format: "%02x", $0) }.joined())
                // The leaf-list pools: after the last node entry (the lowest list offset).
                func pool(_ o: Data) -> [UInt16] {
                    var lowest = o.count
                    var i = 0
                    while i + 4 <= lowest { let v = o.be32(i); if v & 0x8000_0000 != 0 { lowest = min(lowest, i + Int(v & 0x7FFF_FFFF) + 2) }; i += 4 }
                    return stride(from: lowest, to: o.count - 1, by: 2).map { o.be16($0) }
                }
                let rp = pool(ref.octree), op = pool(ours.octree)
                let k = zip(rp, op).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(rp.count, op.count)
                print("   pools: \(rp.count) vs \(op.count) entries, first difference at \(k)")
                print("   wkclt:", rp[max(0, k - 12)..<min(rp.count, k + 20)].map(String.init).joined(separator: " "))
                print("   ours: ", op[max(0, k - 12)..<min(op.count, k + 20)].map(String.init).joined(separator: " "))
            }
        }
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
