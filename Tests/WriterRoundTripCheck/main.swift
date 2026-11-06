// Round-trips every KMP, BMG and KCL on a retail Mario Kart Wii disc through this app's own
// parse + serialize and reports what doesn't survive. KMP and BMG must come back byte-identical;
// KCL rebuilds its octree by design, so it's compared by what the game reads (header scalars and
// every triangle's corners + flag).
//
//   swiftc -O -o /tmp/roundtrip \
//     "Revolution IDE/Core/"{BinaryIO,DiscModel,WiiDisc,Crypto,ClusterCrypto,KeyManager,FSTBuilder,GameCubeDisc}.swift \
//     "Revolution IDE/Core/Formats/"{Yaz0,U8Archive,SZS,MathTypes,KMP,KCL,KCLWiimm,BMG,BuildCompatibility,GOBJNames}.swift \
//     "Revolution IDE/Core/Formats/MKDD/"{RARC,BOL,BCO,BOLObjectNames}.swift \
//     Tests/WriterRoundTripCheck/main.swift
//   /tmp/roundtrip <iso> <common-key>

import Foundation

let iso = URL(fileURLWithPath: CommandLine.arguments[1])
let key = [UInt8](try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
let disc = try WiiDisc(url: iso, commonKey: key, koreanKey: nil)

var archives: [DiscNode] = []
func walk(_ n: DiscNode) {
    if n.isDirectory { n.children.forEach(walk); return }
    if n.name.hasSuffix(".szs") || n.name.hasSuffix(".arc") || n.name.hasSuffix(".bmg") { archives.append(n) }
}
walk(disc.root)

var stats: [String: (ok: Int, bad: Int)] = [:]
var shown: [String: Int] = [:]
func record(_ kind: String, _ ok: Bool, _ what: @autoclosure () -> String) {
    stats[kind, default: (0, 0)].ok += ok ? 1 : 0
    stats[kind, default: (0, 0)].bad += ok ? 0 : 1
    if !ok, shown[kind, default: 0] < 20 { shown[kind, default: 0] += 1; print("DIFF \(kind): \(what())") }
}
func firstDiff(_ a: Data, _ b: Data) -> String {
    let n = min(a.count, b.count)
    for i in 0..<n where a[a.startIndex + i] != b[b.startIndex + i] {
        return "at 0x\(String(i, radix: 16)) (sizes \(a.count)/\(b.count))"
    }
    return "sizes \(a.count)/\(b.count)"
}

func check(name: String, data: Data) {
    let ext = (name as NSString).pathExtension.lowercased()
    switch ext {
    case "kmp":
        if data.count > 10, data.be16(8) != 15 { return } // prototype KMPs the game never loads
        guard let doc = try? KMPDocument.parse(data) else { record("KMP parse", false, name); return }
        let out = doc.serialize()
        record("KMP", out == data, "\(name) \(firstDiff(data, out))")
    case "bmg":
        guard let doc = try? BMGDocument.parse(data) else { record("BMG parse", false, name); return }
        let out = doc.serialize()
        record("BMG", out == data, "\(name) \(firstDiff(data, out))")
        // Force the rebuild path (no preserved source) and make sure it still parses to the same content.
        let fresh = BMGDocument(); fresh.encoding = doc.encoding; fresh.messages = doc.messages
        let again = try? BMGDocument.parse(fresh.serialize())
        let same = again.map { a in a.messages.count == doc.messages.count &&
            zip(a.messages, doc.messages).allSatisfy { $0.units == $1.units && $0.messageID == $1.messageID && $0.attribute == $1.attribute } } ?? false
        record("BMG content", same, name)
    case "kcl":
        guard let doc = try? KCLDocument.parse(data) else { record("KCL parse", false, name); return }
        // Zero-area triangles (retail has a few) collide with nothing and aren't written back.
        doc.triangles.removeAll { Vec3.cross($0.v1 - $0.v0, $0.v2 - $0.v0).length <= 0.0001 }
        // The hardware (wkclt-exact) encoder stores a prism under 1 unit high, its first corner
        // that close to the opposite edge, with height 0, as wkclt does: it can't be read back.
        if BuildCompatibility.current == .hardware {
            doc.triangles.removeAll { t in
                let edge = t.v2 - t.v1
                return Vec3.cross(t.v0 - t.v1, edge).length / max(edge.length, 1e-9) < 1
            }
        }
        let out = doc.serialize()
        guard let back = try? KCLDocument.parse(out) else { record("KCL", false, "\(name) output unparseable"); return }
        func close(_ a: Vec3, _ b: Vec3) -> Bool { abs(a.x - b.x) < 0.5 && abs(a.y - b.y) < 0.5 && abs(a.z - b.z) < 0.5 }
        func dist(_ a: Vec3, _ b: Vec3) -> Float { max(abs(a.x - b.x), abs(a.y - b.y), abs(a.z - b.z)) }
        var worst: Float = 0, worstAt = 0, flips = 0
        for (i, (o, n)) in zip(doc.triangles, back.triangles).enumerated() {
            let e = max(dist(o.v0, n.v0), dist(o.v1, n.v1), dist(o.v2, n.v2))
            if dist(o.v1, n.v2) < 0.5 && dist(o.v2, n.v1) < 0.5 && e >= 0.5 { flips += 1 }
            if e > worst { worst = e; worstAt = i }
        }
        if worst >= 0.5, shown["KCLerr", default: 0] < 30 {
            shown["KCLerr", default: 0] += 1
            print("  \(name): worst vertex error \(worst) at tri \(worstAt) \(doc.triangles[worstAt]) -> \(back.triangles[worstAt]); winding flips \(flips)")
        }
        let sameTris = back.triangles.count == doc.triangles.count && zip(back.triangles, doc.triangles).allSatisfy {
            $0.attribute == $1.attribute && close($0.v0, $1.v0) &&
            ((close($0.v1, $1.v1) && close($0.v2, $1.v2)) || (close($0.v1, $1.v2) && close($0.v2, $1.v1)))
        }
        if !sameTris, shown["KCL", default: 0] < 3,
           let i = Array(zip(back.triangles, doc.triangles)).firstIndex(where: { !($0.attribute == $1.attribute && close($0.v0, $1.v0)) }) {
            print("  first differing triangle \(i): \(doc.triangles[i]) -> \(back.triangles[i])")
        }
        record("KCL", sameTris && back.prismThickness == doc.prismThickness && back.sphereRadius == doc.sphereRadius,
               "\(name) tris \(doc.triangles.count)->\(back.triangles.count) thick \(doc.prismThickness)->\(back.prismThickness) radius \(doc.sphereRadius)->\(back.sphereRadius)")
    default: break
    }
}

for node in archives {
    guard let data = try? disc.readFile(node: node) else { continue }
    if node.name.hasSuffix(".bmg") { check(name: node.name, data: data); continue }
    guard let (root, _) = try? SZS.open(data) else { continue }
    func visit(_ n: U8Node, _ path: String) {
        if n.isDirectory { n.children.forEach { visit($0, path + "/" + n.name) }; return }
        if let d = n.data { check(name: "\(node.name)\(path)/\(n.name)", data: d) }
    }
    visit(root, "")
}
for (k, v) in stats.sorted(by: { $0.key < $1.key }) { print("\(k): \(v.ok) ok, \(v.bad) differ") }
exit(stats.values.contains { $0.bad > 0 } ? 1 : 0)
