import Foundation
// Structural dump of a J3D .bmd, section by section, for comparing writer output with retail.
nonisolated enum BMDDump {
    static func hex(_ d: Data, _ o: Int, _ n: Int) -> String { (o..<min(o + n, d.count)).map { String(format: "%02X", d.u8($0)) }.joined(separator: " ") }
    static func dump(_ d: Data, verbose: Bool = true) -> String {
        var out: [String] = []
        func p(_ s: String) { out.append(s) }
        p("header \(d.asciiString(at: 0, length: 8)) size \(d.be32(8)) (file \(d.count)) sections \(d.be32(12)) tag \(d.asciiString(at: 16, length: 4)) rest \(hex(d, 20, 12))")
        var sec: [String: Int] = [:]
        var o = 0x20
        var order: [String] = []
        while o + 8 <= d.count { let s = Int(d.be32(o + 4)); if s < 8 { break }; let name = d.asciiString(at: o, length: 4); sec[name] = o; order.append("\(name)@\(String(o, radix: 16)) size \(String(s, radix: 16)) align32 \(o % 32 == 0)"); o += s }
        p("sections: " + order.joined(separator: ", "))
        if let i = sec["INF1"] {
            p("INF1 flags \(String(d.be16(i + 8), radix: 16)) pad \(String(d.be16(i + 10), radix: 16)) packets \(d.be32(i + 12)) vertices \(d.be32(i + 16)) hierOfs \(String(d.be32(i + 20), radix: 16))")
            var n = i + Int(d.be32(i + 20)); var nodes: [String] = []
            while n + 4 <= d.count { let t = d.be16(n), x = d.be16(n + 2); nodes.append(String(format: "%X:%d", t, x)); n += 4; if t == 0 { break } }
            p("  hierarchy (\(nodes.count)): " + (nodes.count > 40 ? nodes.prefix(24).joined(separator: " ") + " ... " + nodes.suffix(8).joined(separator: " ") : nodes.joined(separator: " ")))
            p("  after hierarchy to section end: \(hex(d, n, (i + Int(d.be32(i + 4))) - n))")
        }
        if let v = sec["VTX1"] {
            p("VTX1 fmtOfs \(String(d.be32(v + 8), radix: 16)) dataOfs [\((0..<13).map { String(d.be32(v + 12 + $0 * 4), radix: 16) }.joined(separator: " "))]")
            var f = v + Int(d.be32(v + 8))
            while f + 16 <= d.count { p("  fmt attr \(d.be32(f)) comps \(d.be32(f + 4)) type \(d.be32(f + 8)) frac \(d.u8(f + 12)) pad \(hex(d, f + 13, 3))"); if d.be32(f) == 0xFF { break }; f += 16 }
        }
        for name in ["EVP1", "DRW1"] { if let s = sec[name] { p("\(name) " + hex(d, s + 8, min(Int(d.be32(s + 4)) - 8, 64))) } }
        if let j = sec["JNT1"] {
            let count = Int(d.be16(j + 8))
            p("JNT1 count \(count) pad \(String(d.be16(j + 10), radix: 16)) entries \(String(d.be32(j + 12), radix: 16)) remap \(String(d.be32(j + 16), radix: 16)) names \(String(d.be32(j + 20), radix: 16))")
            p("  joint0 " + hex(d, j + Int(d.be32(j + 12)), 0x40))
            p("  remap+names " + hex(d, j + Int(d.be32(j + 16)), Int(d.be32(j + 4)) - Int(d.be32(j + 16))))
        }
        if let s = sec["SHP1"] {
            let count = Int(d.be16(s + 8))
            let offs = (0..<8).map { Int(d.be32(s + 12 + $0 * 4)) }
            p("SHP1 count \(count) pad \(String(d.be16(s + 10), radix: 16)) offsets [\(offs.map { String($0, radix: 16) }.joined(separator: " "))] size \(String(d.be32(s + 4), radix: 16))")
            for k in 0..<min(count, verbose ? 3 : 1) { p("  shape\(k) " + hex(d, s + offs[0] + k * 0x28, 0x28)) }
            p("  remap " + hex(d, s + offs[1], min(16, count * 2)))
            p("  attrs " + hex(d, s + offs[3], 48))
            p("  matrixTable " + hex(d, s + offs[4], 16))
            p("  matrixData " + hex(d, s + offs[6], 24))
            p("  packets " + hex(d, s + offs[7], 24))
            p("  prim[0] " + hex(d, s + offs[5], 40))
        }
        if let m = sec["MAT3"] {
            let count = Int(d.be16(m + 8))
            let offs = (0..<30).map { Int(d.be32(m + 12 + $0 * 4)) }
            p("MAT3 count \(count) pad \(String(d.be16(m + 10), radix: 16)) size \(String(d.be32(m + 4), radix: 16))")
            let names = ["MaterialData", "IndexData", "NameTable", "Indirect", "CullMode", "MatColor", "ChanCount", "ChanData", "Ambient", "Light", "TexGenCount", "TexCoord", "TexCoord2", "TexMatrix", "TexMatrix2", "TexNo", "TevOrder", "TevColor", "TevKColor", "TevStageCount", "TevStage", "SwapMode", "SwapTable", "Fog", "AlphaComp", "Blend", "ZMode", "ZCompLoc", "Dither", "NBTScale"]
            let end = Int(d.be32(m + 4))
            for k in 0..<30 {
                let next = (k + 1..<30).map { offs[$0] }.first { $0 != 0 } ?? end
                let size = offs[k] == 0 ? 0 : next - offs[k]
                let show = ["MaterialData", "IndexData", "NameTable", "TexMatrix", "TevStage", "TevOrder", "TexCoord", "TexNo"].contains(names[k]) ? min(size, 48) : min(size, 0x140)
                p("  [\(k)] \(names[k]) @\(String(offs[k], radix: 16)) size \(String(size, radix: 16)): \(offs[k] == 0 ? "-" : hex(d, m + offs[k], show))")
            }
            p("  material0 entry: " + hex(d, m + offs[0], 0x14C))
        }
        if let t = sec["TEX1"] {
            p("TEX1 count \(d.be16(t + 8)) pad \(String(d.be16(t + 10), radix: 16)) headers \(String(d.be32(t + 12), radix: 16)) names \(String(d.be32(t + 16), radix: 16)) size \(String(d.be32(t + 4), radix: 16))")
            p("  tex0 " + hex(d, t + Int(d.be32(t + 12)), 0x20))
        }
        return out.joined(separator: "\n")
    }
}
