// GameCube J3D formats check, against every file on a retail Mario Kart: Double Dash!! disc
// (loose and inside every .arc):
// - every .bti decodes;
// - every .bmd parses, and its bind pose lands inside the bounding boxes SHP1 stores per shape,
//   in the space the shape's vertices are stored in, joint-local, so each box is moved by a
//   joint's world matrix (or not, for envelope shapes stored in model space) before comparing.
//   Models with a multi-matrix shape are skipped: one box can't cover vertices on several joints;
// - every .btk/.bca parses: key times rise within the duration, BCA tracks have 1 or `duration`
//   frames, values are finite, a .btk's materials exist in its model (same name, same archive) and
//   a .bca's joint count matches its model's.
//
//   find "Revolution IDE/Core" -name '*.swift' ! -path '*/Workbench/*' ! -name AppState.swift \
//     ! -name SyntaxHighlighter.swift | tr '\n' '\0' | xargs -0 swiftc -O -parse-as-library -o /tmp/j3dformats \
//     "Revolution IDE/Core/Workbench/BaseGameLibrary.swift" Tests/J3DFormatsCheck/*.swift
//   /tmp/j3dformats [mkdd.iso]

import Foundation
import simd

@main enum J3DFormatsCheck {
    static func main() throws {
        var failures = 0, counts: [String: Int] = [:], matched: [String: Int] = [:]
        func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; if failures < 40 { print("FAIL", what) } } }
        let iso = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "\(ProcessInfo.processInfo.environment["ROMS_DIR"] ?? "Roms")/GCN/MKDD/Mario Kart - Double Dash!! (USA).iso"
        let disc = try GameCubeDisc(url: URL(fileURLWithPath: iso))

        /// Every file of one folder (an archive's, or the disc's loose files).
        func group(_ files: [(path: String, data: Data)]) {
            func stem(_ p: String) -> String { ((p as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased() }
            let models = files.filter { $0.path.lowercased().hasSuffix(".bmd") || $0.path.lowercased().hasSuffix(".bdl") }
            for (path, data) in files {
                let ext = (path as NSString).pathExtension.lowercased()
                switch ext {
                case "bti":
                    counts["bti", default: 0] += 1
                    check((try? J3DModel.bti(data, name: path))?.decoded() != nil, "\(path): BTI doesn't decode")
                case "bmd", "bdl":
                    counts[ext, default: 0] += 1
                    guard let model = try? J3DModel.parse(data) else { check(false, "\(path): doesn't parse"); continue }
                    guard !shapeModes(data).contains(3) else { continue }
                    counts["bmd box-checked", default: 0] += 1
                    let boxes = shapeBounds(data).flatMap { b in [b] + model.joints.map { moved(b, $0) } }
                    let outside = model.triangles.flatMap { [$0.v.0, $0.v.1, $0.v.2] }.filter { v in !boxes.contains { inside(v.position, $0) } }
                    check(outside.isEmpty || boxes.isEmpty, "\(path): \(outside.count) bind-pose vertices outside every SHP1 shape box")
                case "btk", "bca":
                    counts[ext, default: 0] += 1
                    guard let anim = try? J3DAnimation.parse(data) else { check(false, "\(path): doesn't parse"); continue }
                    for t in anim.targets {
                        for track in t.scale + t.rotation + t.translation {
                            check(track.keys.allSatisfy { $0.value.isFinite && $0.tangentIn.isFinite && abs($0.value) < 1e7 }, "\(path) \(t.name): non-finite value")
                            check(zip(track.keys, track.keys.dropFirst()).allSatisfy { $0.time < $1.time } && (track.keys.last?.time ?? 0) <= Float(anim.duration) + 1,
                                  "\(path) \(t.name): key times \(track.keys.map(\.time)) vs duration \(anim.duration)")
                            if ext == "bca" { check(track.keys.count == 1 || track.keys.count >= anim.duration, "\(path) \(t.name): \(track.keys.count) frames of \(anim.duration)") }
                        }
                    }
                    // Its model: same name, else the archive's only model.
                    let model = models.first { stem($0.path) == stem(path) } ?? (models.count == 1 ? models[0] : nil)
                    guard let model else { continue }
                    if ext == "btk", let m = try? J3DModel.parse(model.data) {
                        let names = Set(m.materials.map(\.name))
                        let missing = anim.targets.map(\.name).filter { !names.contains($0) }
                        check(missing.isEmpty, "\(path): materials \(missing) not in \(model.path)")
                        matched["btk", default: 0] += 1
                    } else if ext == "bca", let jnt = section(model.data, "JNT1"), stem(model.path) == stem(path) {
                        check(Int(model.data.be16(jnt + 8)) == anim.targets.count, "\(path): \(anim.targets.count) joints, \(model.path) has \(model.data.be16(jnt + 8))")
                        matched["bca", default: 0] += 1
                    }
                default: break
                }
            }
        }

        var loose: [(String, Data)] = []
        func walk(_ n: DiscNode, _ p: String) {
            if n.isDirectory { n.children.forEach { walk($0, p + "/" + $0.name) }; return }
            guard let d = try? disc.readFile(node: n) else { return }
            loose.append((p, d))
            guard n.name.hasSuffix(".arc"), let (root, _) = try? SZS.open(d) else { return }
            var files: [(String, Data)] = []
            func walkArc(_ a: U8Node, _ q: String) { a.isDirectory ? a.children.forEach { walkArc($0, q + "/" + $0.name) } : a.data.map { files.append((q, $0)) } ?? () }
            walkArc(root, p)
            group(files)
        }
        walk(disc.root, "")
        group(loose)
        print("checked:", counts.sorted { $0.key < $1.key }, "cross-checked against their model:", matched)
        check((counts["bti"] ?? 0) > 500 && (counts["bmd"] ?? 0) > 500 && (counts["btk"] ?? 0) > 200 && (counts["bca"] ?? 0) > 1000, "too few files found")
        print(failures == 0 ? "PASS" : "\(failures) FAILURES")
        exit(failures == 0 ? 0 : 1)
    }

    static func section(_ d: Data, _ magic: String) -> Int? {
        var off = 0x20
        while off + 8 <= d.count, d.be32(off + 4) >= 8 {
            if d.asciiString(at: off, length: 4) == magic { return off }
            off += Int(d.be32(off + 4))
        }
        return nil
    }

    /// Each shape's matrix mode (0 single, 1/2 billboard, 3 multi-matrix).
    static func shapeModes(_ d: Data) -> [UInt8] {
        guard let shp = section(d, "SHP1") else { return [] }
        let entries = shp + Int(d.be32(shp + 0x0C))
        return (0..<Int(d.be16(shp + 8))).map { d.u8(entries + $0 * 0x28) }
    }

    /// Each shape's bounding box as SHP1 stores it (entry +0x10 min, +0x1C max), in its vertices' space.
    static func shapeBounds(_ d: Data) -> [(min: SIMD3<Float>, max: SIMD3<Float>)] {
        guard let shp = section(d, "SHP1") else { return [] }
        let entries = shp + Int(d.be32(shp + 0x0C))
        return (0..<Int(d.be16(shp + 8))).map { i in
            let e = entries + i * 0x28
            return (SIMD3(d.beFloat32(e + 0x10), d.beFloat32(e + 0x14), d.beFloat32(e + 0x18)), SIMD3(d.beFloat32(e + 0x1C), d.beFloat32(e + 0x20), d.beFloat32(e + 0x24)))
        }
    }
}

/// A box's corners through `m`, boxed again.
func moved(_ b: (min: SIMD3<Float>, max: SIMD3<Float>), _ m: simd_float4x4) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
    var lo = SIMD3<Float>(repeating: .infinity), hi = -lo
    for c in 0..<8 {
        let p = SIMD3<Float>(c & 1 == 0 ? b.min.x : b.max.x, c & 2 == 0 ? b.min.y : b.max.y, c & 4 == 0 ? b.min.z : b.max.z)
        let q = m * SIMD4<Float>(p, 1)
        lo = simd_min(lo, SIMD3(q.x, q.y, q.z)); hi = simd_max(hi, SIMD3(q.x, q.y, q.z))
    }
    return (lo, hi)
}

/// Inside a box, give or take rounding (1 unit + 1%).
func inside(_ v: Vec3, _ b: (min: SIMD3<Float>, max: SIMD3<Float>)) -> Bool {
    let p = SIMD3<Float>(v.x, v.y, v.z)
    let span: SIMD3<Float> = abs(b.min) + abs(b.max)
    let slack: SIMD3<Float> = span * 0.01 + 1
    return all(p .>= b.min - slack) && all(p .<= b.max + slack)
}

extension Vec3 { subscript(i: Int) -> Float { i == 0 ? x : (i == 1 ? y : z) } }
