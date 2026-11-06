// GX display-list check: walks every MDL0 shape's two display lists (vertex setup + draw) the
// way the GPU's command processor does, every opcode must be valid, every primitive's vertices
// exactly the size the shape's vertex descriptor says, and checks the 32-byte alignment and
// padding GXCallDisplayList needs (the GPU fetches lists in 32-byte blocks: a misaligned start or
// a size that isn't a multiple of 32 makes it execute the neighbouring bytes as commands --
// Dolphin's "FIFO: Unknown Opcode", a hang on a real console). Retail files must pass.
//
//   find "Revolution IDE/Core" -name '*.swift' ! -path '*/Workbench/*' ! -name AppState.swift \
//     ! -name SyntaxHighlighter.swift -print0 | xargs -0 swiftc -O -parse-as-library -o /tmp/gxcheck \
//     "Revolution IDE/Core/Workbench/BaseGameLibrary.swift" Tests/GXDisplayListCheck/*.swift
//   /tmp/gxcheck file.szs|file.brres ...     (no arguments: retail courses from the disc)

import Foundation

struct DLProblem: CustomStringConvertible { var what: String; var description: String { what } }

/// Bytes per vertex for each VCD attribute, from the shape's CP 0x50/0x60 (VCD) and 0x70 (VAT0).
func vertexSize(vcdLo: UInt32, vcdHi: UInt32, vat: (UInt32, UInt32, UInt32)) -> Int? {
    var size = 0
    // VCD_LO bits: 0 PNMTXIDX, 1-8 TEXnMTXIDX (1 bit each, direct u8), 9-10 POS, 11-12 NRM, 13-14 CLR0, 15-16 CLR1.
    for b in 0...8 where vcdLo & (1 << b) != 0 { size += 1 }
    func compSize(_ fmt: UInt32) -> Int { [1, 1, 2, 2, 4][Int(min(fmt, 4))] }
    func attr(_ type: UInt32, direct: Int) -> Int? {
        switch type { case 0: return 0; case 1: return direct; case 2: return 1; default: return 2 }
    }
    let (a, b, c) = vat
    // VAT A: pos cnt bit0, fmt 1-3; nrm cnt 9, fmt 10-12; clr0 cnt 13, fmt 14-16; clr1 cnt 17, fmt 18-20; tex0 cnt 21, fmt 22-24.
    let posDirect = (a & 1 == 0 ? 2 : 3) * compSize((a >> 1) & 7)
    let nrmDirect = 3 * compSize((a >> 10) & 7) * ((a >> 9) & 1 == 1 ? 3 : 1)
    func clrDirect(_ f: UInt32) -> Int { [2, 3, 4, 2, 3, 4][Int(min(f, 5))] }
    guard let p = attr((vcdLo >> 9) & 3, direct: posDirect), let n = attr((vcdLo >> 11) & 3, direct: nrmDirect),
          let c0 = attr((vcdLo >> 13) & 3, direct: clrDirect((a >> 14) & 7)), let c1 = attr((vcdLo >> 15) & 3, direct: clrDirect((a >> 18) & 7)) else { return nil }
    size += p + n + c0 + c1
    // Texcoords: VCD_HI 2 bits each. Formats: tex0 in A 22-24, tex1 B 1-3, tex2 B 10-12, tex3 B 19-21, tex4 B 28-30, tex5 C 1-3, tex6 C 10-12, tex7 C 19-21.
    let texFmt: [UInt32] = [(a >> 22) & 7, (b >> 1) & 7, (b >> 10) & 7, (b >> 19) & 7, (b >> 28) & 7, (c >> 1) & 7, (c >> 10) & 7, (c >> 19) & 7]
    let texCnt: [UInt32] = [(a >> 21) & 1, b & 1, (b >> 9) & 1, (b >> 18) & 1, (b >> 27) & 1, c & 1, (c >> 9) & 1, (c >> 18) & 1]
    for t in 0..<8 {
        guard let s = attr((vcdHi >> (UInt32(t) * 2)) & 3, direct: (texCnt[t] == 1 ? 2 : 1) * compSize(texFmt[t])) else { return nil }
        size += s
    }
    return size
}

/// Runs a display list like the command processor. `cp` collects CP register writes (so the
/// setup list's VCD/VAT can feed the draw list). Returns problems found.
func walk(_ d: Data, _ start: Int, _ size: Int, cp: inout [UInt8: UInt32], vtxSize: Int?, label: String) -> [DLProblem] {
    var out: [DLProblem] = []
    var p = start
    let end = start + size
    guard start >= 0, end <= d.count else { return [DLProblem(what: "\(label): list runs outside the file")] }
    while p < end {
        let op = d.u8(p)
        switch op {
        case 0x00: p += 1
        case 0x08: guard p + 6 <= end else { out.append(DLProblem(what: "\(label)+\(p - start): CP command cut off")); return out }
            cp[d.u8(p + 1)] = d.be32(p + 2); p += 6
        case 0x10: guard p + 5 <= end else { out.append(DLProblem(what: "\(label)+\(p - start): XF command cut off")); return out }
            let n = Int(d.be16(p + 1)) + 1; p += 5 + 4 * n
        case 0x20, 0x28, 0x30, 0x38: p += 5
        case 0x40: p += 9
        case 0x48: p += 1
        case 0x61: p += 5
        case 0x80...0xBF where op & 0x07 == 0 || true:
            guard op & 0xF8 != 0x88 else { out.append(DLProblem(what: "\(label)+\(p - start): invalid primitive 0x\(String(op, radix: 16))")); return out }
            guard p + 3 <= end else { out.append(DLProblem(what: "\(label)+\(p - start): primitive header cut off")); return out }
            let count = Int(d.be16(p + 1))
            guard let vs = vtxSize else { out.append(DLProblem(what: "\(label): primitive with unknown vertex size")); return out }
            p += 3 + count * vs
            if p > end { out.append(DLProblem(what: "\(label): primitive of \(count) x \(vs)-byte vertices runs \(p - end) bytes past the list end")); return out }
        default:
            out.append(DLProblem(what: "\(label)+\(p - start) (abs 0x\(String(p, radix: 16))): unknown opcode 0x\(String(format: "%02x", op))"))
            return out
        }
    }
    return out
}

func checkMDL0(_ r: BRRESResource, fileOffset: Int, name: String) -> (shapes: Int, problems: [DLProblem]) {
    let d = r.data
    var problems: [DLProblem] = []
    guard d.count > 0x50, d.be32(8) == 11 else { return (0, []) }
    // Section 10 (index 10 of 14 at 0x10) = Objects (shapes).
    let shapesGroup = Int(Int32(bitPattern: d.be32(0x10 + 10 * 4)))
    guard shapesGroup > 0 else { return (0, []) }
    let count = Int(d.be32(shapesGroup + 4))
    var shapes = 0
    for e in 1...max(1, count) where count > 0 {
        let entry = shapesGroup + 8 + e * 16
        let ofs = Int(Int32(bitPattern: d.be32(entry + 12)))
        let s = shapesGroup + ofs
        guard s > 0, s + 0x68 <= d.count else { continue }
        shapes += 1
        func tag(_ t: Int) -> (start: Int, size: Int, used: Int) {
            (t + Int(Int32(bitPattern: d.be32(t + 8))), Int(d.be32(t)), Int(d.be32(t + 4)))
        }
        let setup = tag(s + 0x18), draw = tag(s + 0x24)
        if ProcessInfo.processInfo.environment["TAGS"] != nil, e <= 3 {
            print("   setup bytes:", (0..<setup.size).map { String(format: "%02x", d.u8(setup.start + $0)) }.joined())
            print("   \(name) shape \(e - 1): setup size \(setup.size) used \(setup.used) start%32=\((fileOffset + setup.start) % 32); draw size \(draw.size) used \(draw.used) start%32=\((fileOffset + draw.start) % 32); hdr", (0..<0x68).map { String(format: "%02x", d.u8(s + $0)) }.joined())
        }
        let label = "\(name) shape \(e - 1)"
        for (kind, t) in [("setup", setup), ("draw", draw)] {
            let abs = fileOffset + t.start
            if abs % 32 != 0 { problems.append(DLProblem(what: "\(label) \(kind) list starts at file offset 0x\(String(abs, radix: 16)), not 32-byte aligned")) }
            if t.size % 32 != 0 { problems.append(DLProblem(what: "\(label) \(kind) list buffer size \(t.size) not a multiple of 32")) }
            if t.used > t.size { problems.append(DLProblem(what: "\(label) \(kind) list command size \(t.used) > buffer \(t.size)")) }
        }
        // The game patches the setup list before drawing (NW4R, per RiiStudio's PolygonIO): two
        // 5-byte commands at 0x00 and the vertex-array base/stride CP writes after the VAT block
        // at 0x20, so those bytes must be free (zero), and the list must still run cleanly with
        // the patch applied. A list with commands in those slots gets them overwritten.
        if setup.size >= 0x40 {
            if (0..<10).contains(where: { d.u8(setup.start + $0) != 0 }) { problems.append(DLProblem(what: "\(label) setup: bytes 0x00-0x09 aren't free for the game's runtime patch")) }
            if d.u8(setup.start + 0x20) != 0x08 || d.u8(setup.start + 0x21) != 0x70 { problems.append(DLProblem(what: "\(label) setup: VAT block isn't at 0x20")) }
            var patched = d
            for i in 0..<10 { patched[setup.start + i] = [0x61, 0x00, 0x00, 0x00, 0x00][i % 5] }
            // Array pointers: CP 0xA0+n / 0xB0+n (6 bytes each) from 0x32, as the runtime writes them.
            var at = setup.start + 0x32
            for n in 0..<4 where at + 12 <= setup.start + setup.used {
                for (j, b) in ([0x08, 0xA0 + n, 0x01, 0x23, 0x45, 0x60, 0x08, 0xB0 + n, 0, 0, 0, 0x0C] as [Int]).enumerated() { patched[at + j] = UInt8(b) }
                at += 12
            }
            var pcp: [UInt8: UInt32] = [:]
            problems += walk(patched, setup.start, setup.size, cp: &pcp, vtxSize: nil, label: label + " setup (as patched at runtime)")
        }
        var cp: [UInt8: UInt32] = [:]
        problems += walk(d, setup.start, setup.size, cp: &cp, vtxSize: nil, label: label + " setup")
        let vs = vertexSize(vcdLo: cp[0x50] ?? 0, vcdHi: cp[0x60] ?? 0, vat: (cp[0x70] ?? 0, cp[0x80] ?? 0, cp[0x90] ?? 0))
        // Cross-check the VCD the list loads against the shape header's own copy (0x30 flags).
        problems += walk(d, draw.start, draw.size, cp: &cp, vtxSize: vs, label: label + " draw")
    }
    // Materials (section 8): four lists the game calls separately, pixel (32 bytes), TEV
    // colours (128), indirect (64), tex-coord gens (32 per 1-2 gens...), per RiiStudio's MatIO.
    func entries(_ section: Int) -> [Int] {
        let g = Int(Int32(bitPattern: d.be32(0x10 + section * 4)))
        guard g > 0, g + 8 <= d.count else { return [] }
        let n = Int(d.be32(g + 4))
        return (0..<n).map { g + Int(Int32(bitPattern: d.be32(g + 8 + ($0 + 1) * 16 + 12))) }
    }
    let texGenSizes = [0, 32, 64, 64, 96, 96, 128, 128, 160]
    for (i, m) in entries(8).enumerated() where m > 0 && m + 0x40 <= d.count {
        let label = "\(name) material \(i)"
        var at = m + Int(Int32(bitPattern: d.be32(m + 0x3C)))
        let gens = Int(d.u8(m + 0x14))
        for (part, size) in [("pixel", 32), ("tev colour", 128), ("indirect", 64), ("texgen", gens < 9 ? texGenSizes[gens] : 0)] {
            if (fileOffset + at) % 32 != 0 { problems.append(DLProblem(what: "\(label) \(part) list not 32-byte aligned (0x\(String(fileOffset + at, radix: 16)))")) }
            var cp: [UInt8: UInt32] = [:]
            problems += walk(d, at, size, cp: &cp, vtxSize: nil, label: "\(label) \(part)")
            at += size == 0 ? 0 : [32, 128, 64].contains(size) && part != "texgen" ? size : size
        }
    }
    // Shaders (section 9): one TEV list at +32, sized by stage count (RiiStudio's shaderDlSizes).
    let tevSizes = [160, 160, 192, 192, 256, 256, 288, 288, 352, 352, 384, 384, 448, 448, 480, 480]
    for (i, sh) in Set(entries(9)).sorted().enumerated() where sh > 0 && sh + 32 <= d.count {
        let stages = Int(d.u8(sh + 12))
        guard stages < 16 else { problems.append(DLProblem(what: "\(name) shader \(i): \(stages) stages")); continue }
        if (fileOffset + sh + 32) % 32 != 0 { problems.append(DLProblem(what: "\(name) shader \(i) list not 32-byte aligned")) }
        var cp: [UInt8: UInt32] = [:]
        problems += walk(d, sh + 32, tevSizes[stages], cp: &cp, vtxSize: nil, label: "\(name) shader \(i) (\(stages) stages)")
    }
    return (shapes, problems)
}

func checkBRRES(_ data: Data, name: String) throws -> Int {
    let doc = try BRRESDocument.parse(data)
    var bad = 0, shapes = 0
    for r in doc.resources where r.magic == "MDL0" {
        let fileOffset = r.fileOffset
        let (n, problems) = checkMDL0(r, fileOffset: fileOffset, name: "\(name):\(r.name)")
        shapes += n
        for p in problems.prefix(8) { print("   ", p) }
        if problems.count > 8 { print("    ... \(problems.count - 8) more") }
        bad += problems.count
    }
    print(bad == 0 ? "ok   \(name): \(shapes) shapes" : "FAIL \(name): \(bad) problems in \(shapes) shapes")
    return bad
}

@main enum GXDisplayListCheck {
    static func main() throws {
        var inputs: [(String, Data)] = []
        for path in CommandLine.arguments.dropFirst() {
            let d = try Data(contentsOf: URL(fileURLWithPath: path))
            if path.hasSuffix(".szs") {
                let (root, _) = try SZS.open(d)
                func walkNode(_ n: U8Node) { if n.isDirectory { n.children.forEach(walkNode) } else if n.name.hasSuffix(".brres"), let x = n.data { inputs.append(("\((path as NSString).lastPathComponent)/\(n.name)", x)) } }
                walkNode(root)
            } else { inputs.append((path, d)) }
        }
        if inputs.isEmpty {
            let roms = "\(ProcessInfo.processInfo.environment["ROMS_DIR"] ?? "Roms")/"
            let disc = try WiiDisc(url: URL(fileURLWithPath: roms + "Wii/MKWii/Mario Kart Wii (USA) (En,Fr,Es).iso"),
                                   commonKey: [UInt8](try Data(contentsOf: URL(fileURLWithPath: roms + "Wii/Keys/common-key"))), koreanKey: nil)
            var nodes: [DiscNode] = []
            func walk(_ n: DiscNode) { if n.isDirectory { n.children.forEach(walk) } else if n.name.hasSuffix("_course.szs") { nodes.append(n) } }
            walk(disc.root)
            for n in nodes.sorted(by: { $0.name < $1.name }).prefix(3) {
                let (root, _) = try SZS.open(try disc.readFile(node: n))
                for c in root.children where c.name.hasSuffix(".brres") { inputs.append(("\(n.name)/\(c.name)", c.data!)) }
            }
        }
        var bad = 0
        for (name, d) in inputs { bad += (try? checkBRRES(d, name: name)) ?? 1 }
        if bad > 0 { exit(1) }
    }
}
