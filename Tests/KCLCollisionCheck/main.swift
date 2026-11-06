// KCL collision check: reads a course.kcl exactly the way Mario Kart Wii does (Kinoko's decomp-
// matched KColData: searchBlock + the sphere/edge prism test) and compares, for points just above
// every floor triangle, the prisms the octree hands back against a brute-force test of every
// prism. A floor the octree leaves out is one a kart sinks into. Also reports the section layout
// Wiimm's tools require and how far each floor's stored normal is from its real triangle normal.
//
//   find "Revolution IDE/Core" -name '*.swift' ! -path '*/Workbench/*' ! -name AppState.swift \
//     ! -name SyntaxHighlighter.swift -print0 | xargs -0 swiftc -O -parse-as-library -o /tmp/kclcheck \
//     "Revolution IDE/Core/Workbench/BaseGameLibrary.swift" Tests/KCLCollisionCheck/*.swift
//   /tmp/kclcheck file.kcl|file.szs ...      (no arguments: retail courses from the disc)

import Foundation
import simd

struct GameKCL {
    struct Prism { var height: Float; var pos: Int; var fnrm: Int; var e1: Int; var e2: Int; var e3: Int; var attr: UInt16 }
    let data: Data
    var pos: [SIMD3<Float>] = [], nrm: [SIMD3<Float>] = [], prisms: [Prism] = []
    let blockOffset: Int, areaMin: SIMD3<Float>, masks: (UInt32, UInt32, UInt32), shift: UInt32, xShift: UInt32, xyShift: UInt32
    let thickness: Float, sphereRadius: Float
    let layoutOK: Bool

    init(_ d: Data) {
        data = d
        func f(_ o: Int) -> Float { Float(bitPattern: d.be32(o)) }
        func v(_ o: Int) -> SIMD3<Float> { SIMD3(f(o), f(o + 4), f(o + 8)) }
        let po = Int(d.be32(0)), no = Int(d.be32(4)), pr = Int(d.be32(8)), bo = Int(d.be32(12))
        blockOffset = bo
        thickness = f(0x10); areaMin = v(0x14)
        masks = (d.be32(0x20), d.be32(0x24), d.be32(0x28)); shift = d.be32(0x2C); xShift = d.be32(0x30); xyShift = d.be32(0x34)
        sphereRadius = po > 0x38 ? f(0x38) : 250
        // Wiimm's rule (IsValidKCL): each section a whole number of elements, sections in order.
        layoutOK = (no - po) % 12 == 0 && (pr + 0x10 - no) % 12 == 0 && (bo - pr - 0x10) % 16 == 0 && po < no && no < pr + 0x10 && pr < bo
        for i in 0..<((no - po) / 12) { pos.append(v(po + i * 12)) }
        // As the game: normals run up to the first real prism, prisms are 1-indexed from `pr`.
        for i in 0..<((pr + 0x10 - no) / 12) { nrm.append(v(no + i * 12)) }
        for i in 0..<((bo - pr) / 16) {
            let b = pr + i * 16
            prisms.append(Prism(height: f(b), pos: Int(d.be16(b + 4)), fnrm: Int(d.be16(b + 6)), e1: Int(d.be16(b + 8)),
                                e2: Int(d.be16(b + 10)), e3: Int(d.be16(b + 12)), attr: d.be16(b + 14)))
        }
    }

    /// KColData::searchBlock, the leaf list for a point: byte offset of the u16 *before* the
    /// first index (the game pre-increments), or nil outside the octree.
    func searchBlock(_ p: SIMD3<Float>) -> Int? {
        let x = Int32(p.x - areaMin.x), y = Int32(p.y - areaMin.y), z = Int32(p.z - areaMin.z)
        if UInt32(bitPattern: x) & masks.0 != 0 || UInt32(bitPattern: y) & masks.1 != 0 || UInt32(bitPattern: z) & masks.2 != 0 { return nil }
        var s = shift
        var cur = blockOffset
        let ux = UInt32(bitPattern: x), uy = UInt32(bitPattern: y), uz = UInt32(bitPattern: z)
        var index = Int(4 * ((uz >> s) << xyShift | (uy >> s) << xShift | ux >> s))
        while true {
            guard cur + index + 4 <= data.count else { return nil }
            let off = data.be32(cur + index)
            if off & 0x8000_0000 != 0 { return cur + Int(off & 0x7FFF_FFFF) }
            s -= 1
            cur += Int(off)
            index = Int(4 * ((ux >> s) & 1 | ((uy >> s) & 1) << 1 | ((uz >> s) & 1) << 2))
        }
    }

    func list(_ p: SIMD3<Float>) -> [Int] {
        guard var o = searchBlock(p) else { return [] }
        var out: [Int] = []
        while true { o += 2; guard o + 2 <= data.count else { break }; let i = Int(data.be16(o)); if i == 0 { break }; out.append(i) }
        return out
    }

    /// KColData::checkCollision<Edge> for one prism: the push-out distance, or nil.
    func collide(_ pr: Prism, _ p: SIMD3<Float>, radius r: Float) -> Float? {
        guard pr.pos < pos.count, [pr.fnrm, pr.e1, pr.e2, pr.e3].allSatisfy({ $0 < nrm.count }) else { return nil }
        let rel = p - pos[pr.pos]
        let ca = simd_dot(rel, nrm[pr.e1]); if r <= ca { return nil }
        let ab = simd_dot(rel, nrm[pr.e2]); if r <= ab { return nil }
        let bc = simd_dot(rel, nrm[pr.e3]) - pr.height; if r <= bc { return nil }
        let plane = simd_dot(rel, nrm[pr.fnrm])
        let inPlane = r - plane
        if inPlane <= 0 || inPlane >= thickness + r { return nil }
        if ab <= 0, bc <= 0, ca <= 0 { return inPlane }
        return nil // edge/corner contacts: not needed to find a missing floor
    }

    /// The prism's three corners (KColData::computeBBox / GetVertex).
    func corners(_ pr: Prism) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)? {
        guard pr.pos < pos.count, [pr.fnrm, pr.e1, pr.e2, pr.e3].allSatisfy({ $0 < nrm.count }) else { return nil }
        func vertex(_ en: SIMD3<Float>) -> SIMD3<Float> {
            let c = simd_cross(nrm[pr.fnrm], en)
            return pos[pr.pos] + c * (pr.height / simd_dot(c, nrm[pr.e3]))
        }
        return (pos[pr.pos], vertex(nrm[pr.e1]), vertex(nrm[pr.e2]))
    }
}

func isFloor(_ attr: UInt16) -> Bool {
    // KCL_TYPE_FLOOR in Kinoko: everything but walls (0x0C-0x0F, 0x14, 0x19, 0x1C-0x1F) and
    // the non-solid triggers (0x10 fall, 0x11 cannon, 0x12, 0x18 sound, 0x1A effect, 0x1B item).
    ![0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x14, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F].contains(Int(attr & 0x1F))
}

struct Report { var floors = 0, samples = 0, missing = 0, outside = 0, worstTilt: Float = 0, nonUnit = 0 }

func check(_ name: String, _ data: Data) -> Report {
    let k = GameKCL(data)
    var rep = Report()
    var rng = SystemRandomNumberGenerator()
    for (i, pr) in k.prisms.enumerated() where i > 0 && isFloor(pr.attr) && pr.height > 0 {
        guard let (a, b, c) = k.corners(pr) else { continue }
        let n = k.nrm[pr.fnrm]
        if abs(simd_length(n) - 1) > 1e-3 { rep.nonUnit += 1 }
        guard n.y > 0.7 else { continue } // a floor you drive on
        // Slivers (area or a height under 1 unit) are left out of the octree on purpose by
        // Wiimm's encoder: too thin to collide with reliably.
        let e = [simd_length(b - a), simd_length(c - b), simd_length(a - c)]
        let area = simd_length(simd_cross(b - a, c - a)) / 2
        if area < 1 || e.contains(where: { $0 == 0 || 2 * area / $0 < 1 }) { continue }
        rep.floors += 1
        let real = simd_normalize(simd_cross(b - a, c - a))
        rep.worstTilt = max(rep.worstTilt, acos(min(1, abs(simd_dot(real, n)))) * 180 / .pi)
        for _ in 0..<6 {
            var u = Float.random(in: 0...1, using: &rng), v = Float.random(in: 0...1, using: &rng)
            if u + v > 1 { u = 1 - u; v = 1 - v }
            let onFloor = a + (b - a) * u + (c - a) * v
            let p = onFloor + n * 20 // a wheel sphere (r 50) resting 30 units into... touching the road
            let r: Float = 50
            guard k.collide(pr, p, radius: r) != nil else { continue } // sample hit an edge region
            rep.samples += 1
            let l = k.list(p)
            if k.searchBlock(p) == nil { rep.outside += 1; continue }
            if !l.contains(i) { rep.missing += 1 }
        }
    }
    print(String(format: "%@ %@: %d floors, %d samples, %d floor prisms missing from their leaf, %d outside the octree, worst normal tilt %.4f deg, %d non-unit normals",
                 k.layoutOK ? "layout ok " : "LAYOUT BAD", name, rep.floors, rep.samples, rep.missing, rep.outside, rep.worstTilt, rep.nonUnit))
    return rep
}

@main enum KCLCollisionCheck {
    static func main() throws {
        var inputs: [(String, Data)] = []
        for path in CommandLine.arguments.dropFirst() {
            let d = try Data(contentsOf: URL(fileURLWithPath: path))
            if path.hasSuffix(".szs") {
                let (root, _) = try SZS.open(d)
                if let k = root.children.first(where: { $0.name == "course.kcl" })?.data { inputs.append((path, k)) }
            } else { inputs.append((path, d)) }
        }
        if inputs.isEmpty {
            let roms = "\(ProcessInfo.processInfo.environment["ROMS_DIR"] ?? "Roms")/"
            let disc = try WiiDisc(url: URL(fileURLWithPath: roms + "Wii/MKWii/Mario Kart Wii (USA) (En,Fr,Es).iso"),
                                   commonKey: [UInt8](try Data(contentsOf: URL(fileURLWithPath: roms + "Wii/Keys/common-key"))), koreanKey: nil)
            var nodes: [DiscNode] = []
            func walk(_ n: DiscNode) { if n.isDirectory { n.children.forEach(walk) } else if n.name.hasSuffix("_course.szs") { nodes.append(n) } }
            walk(disc.root)
            for n in nodes.sorted(by: { $0.name < $1.name }).prefix(4) {
                let (root, _) = try SZS.open(try disc.readFile(node: n))
                inputs.append((n.name, root.children.first { $0.name == "course.kcl" }!.data!))
            }
        }
        var bad = 0
        for (name, d) in inputs {
            let r = check(name, d); if r.missing + r.outside > 0 || !GameKCL(d).layoutOK { bad += 1 }
            if ProcessInfo.processInfo.environment["FLAGS"] != nil { print("   flags:", flagHistogram(d).prefix(12).map { String(format: "%04X×%d", $0.0, $0.1) }.joined(separator: " ")) }
        }
        if bad > 0 { exit(1) }
    }
}

func flagHistogram(_ d: Data) -> [(UInt16, Int)] {
    var h: [UInt16: Int] = [:]
    for (i, p) in GameKCL(d).prisms.enumerated() where i > 0 { h[p.attr, default: 0] += 1 }
    return h.sorted { $0.value > $1.value }
}
