// J3D display-list check: every SHP1 packet's primitive list in a .bmd must start 32-byte aligned,
// be a multiple of 32 bytes, and decode cleanly, only primitives whose vertices are exactly the
// size the shape's attribute table says, then zero padding. The GPU fetches lists in 32-byte
// blocks, so anything else executes stray bytes (a hang on a real GameCube). Retail must pass.
//
//   find "Revolution IDE/Core" -name '*.swift' ! -path '*/Workbench/*' ! -name AppState.swift \
//     ! -name SyntaxHighlighter.swift -print0 | xargs -0 swiftc -O -parse-as-library -o /tmp/j3dcheck \
//     "Revolution IDE/Core/Workbench/BaseGameLibrary.swift" Tests/J3DDisplayListCheck/*.swift
//   /tmp/j3dcheck file.bmd ...     (no arguments: retail Double Dash course models)

import Foundation

func checkBMD(_ d: Data, name: String) -> Int {
    var problems: [String] = []
    var sections: [String: Int] = [:]
    var o = 0x20
    while o + 8 <= d.count { let size = Int(d.be32(o + 4)); guard size > 0 else { break }; sections[d.asciiString(at: o, length: 4)] = o; o += size }
    guard let shp = sections["SHP1"] else { print("FAIL \(name): no SHP1"); return 1 }
    let shapeCount = Int(d.be16(shp + 8))
    let shapeInit = shp + Int(d.be32(shp + 0x0C)), remap = shp + Int(d.be32(shp + 0x10))
    let attribTable = shp + Int(d.be32(shp + 0x18)), primitiveData = shp + Int(d.be32(shp + 0x20))
    let packetTable = shp + Int(d.be32(shp + 0x28))
    var packets = 0
    for s in 0..<shapeCount {
        let entry = shapeInit + Int(d.be16(remap + s * 2)) * 0x28
        let packetCount = Int(d.be16(entry + 2)), firstPacket = Int(d.be16(entry + 8))
        var a = attribTable + Int(d.be16(entry + 4))
        var vsize = 0
        while a + 8 <= d.count, d.be32(a) != 0xFF {
            let type = d.be32(a + 4)
            vsize += type == 3 ? 2 : (type == 0 ? 0 : 1)
            a += 8
        }
        for p in 0..<packetCount {
            packets += 1
            let loc = packetTable + (firstPacket + p) * 8
            let size = Int(d.be32(loc)), start = primitiveData + Int(d.be32(loc + 4))
            let label = "shape \(s) packet \(p)"
            if start % 32 != 0 { problems.append("\(label): list at 0x\(String(start, radix: 16)) not 32-byte aligned") }
            if size % 32 != 0 { problems.append("\(label): size \(size) not a multiple of 32") }
            var q = start
            let end = start + size
            while q < end {
                let op = d.u8(q)
                if op == 0 { q += 1; continue }
                guard op & 0x80 != 0, op & 0xF8 != 0x88, q + 3 <= end else { problems.append("\(label)+\(q - start): bad opcode 0x\(String(op, radix: 16))"); break }
                q += 3 + Int(d.be16(q + 1)) * vsize
                if q > end { problems.append("\(label): primitive runs \(q - end) bytes past the list"); break }
            }
        }
    }
    for p in problems.prefix(6) { print("   ", p) }
    print(problems.isEmpty ? "ok   \(name): \(shapeCount) shapes, \(packets) packets" : "FAIL \(name): \(problems.count) problems")
    return problems.count
}

@main enum J3DDisplayListCheck {
    static func main() throws {
        var inputs: [(String, Data)] = CommandLine.arguments.dropFirst().map { ($0, try! Data(contentsOf: URL(fileURLWithPath: $0))) }
        if inputs.isEmpty {
            let disc = try GameCubeDisc(url: URL(fileURLWithPath: "\(ProcessInfo.processInfo.environment["ROMS_DIR"] ?? "Roms")/GCN/MKDD/Mario Kart - Double Dash!! (USA).iso"))
            func find(_ n: DiscNode, _ name: String) -> DiscNode? { n.name == name ? n : n.children.lazy.compactMap { find($0, name) }.first }
            for arc in ["Luigi.arc", "Yoshi.arc", "Peach.arc"] {
                let raw = try disc.readFile(node: find(disc.root, arc)!)
                let root = try RARC.parse(Yaz0.isYaz0(raw) ? Yaz0.decode(raw) : raw)
                func walk(_ n: U8Node) { for c in n.children { if c.isDirectory { walk(c) } else if c.name.hasSuffix(".bmd"), let x = c.data { inputs.append(("\(arc)/\(c.name)", x)) } } }
                walk(root)
            }
        }
        var bad = 0
        for (n, d) in inputs { bad += checkBMD(d, name: n) }
        if bad > 0 { exit(1) }
    }
}
