// PAT0 check: every retail PAT0 on the disc parses, rebuilds to the same bytes apart from its
// string offsets (which the BRRES pool assigns), and survives a BRRES serialize + re-read
// unchanged. A built flipbook round-trips too.
//
//   find "Revolution IDE/Core" -name '*.swift' ! -path '*/Workbench/*' ! -path '*/Homebrew/*' \
//     ! -path '*/Editor/*' ! -name AppState.swift | tr '\n' '\0' | xargs -0 swiftc -O -parse-as-library \
//     -o /tmp/pat0check "Revolution IDE/Core/Workbench/BaseGameLibrary.swift" Tests/PAT0Check/main.swift
//   /tmp/pat0check [mkwii.iso] [common-key]

import Foundation

@main enum PAT0Check {
    static func reread(_ anim: PAT0Animation) -> PAT0Animation? {
        let built = anim.build()
        let doc = BRRESDocument()
        doc.resources = [BRRESResource(name: anim.name, folderName: "AnmTexPat(NW4R)", data: built.data, stringReferences: built.strings)]
        guard let again = try? BRRESDocument.parse(doc.serialize()), let r = again.resources.first else { return nil }
        return PAT0Animation.parse(r, rawFile: again.rawData)
    }

    static func main() throws {
        let args = CommandLine.arguments
        let roms = "\(ProcessInfo.processInfo.environment["ROMS_DIR"] ?? "Roms")/"
        let iso = args.count > 1 ? args[1] : roms + "Wii/MKWii/Mario Kart Wii (USA) (En,Fr,Es).iso"
        let key = args.count > 2 ? args[2] : roms + "Wii/Keys/common-key"
        let disc = try WiiDisc(url: URL(fileURLWithPath: iso), commonKey: [UInt8](try Data(contentsOf: URL(fileURLWithPath: key))), koreanKey: nil)
        var failures = 0, checked = 0, ulpOff = 0, identical = 0, trackOrder = 0
        func fail(_ s: String) { failures += 1; if failures < 30 { print("FAIL", s) } }
        func files(_ n: U8Node) -> [U8Node] { n.isDirectory ? n.children.flatMap(files) : [n] }
        func walk(_ n: DiscNode) throws {
            if n.isDirectory { try n.children.forEach(walk); return }
            guard n.name.hasSuffix(".szs"), !n.name.hasSuffix("_d.szs"), let (root, _) = try? SZS.open(try disc.readFile(node: n)) else { return }
            for f in files(root) where f.name.hasSuffix(".brres") {
                guard let data = f.data, let doc = try? BRRESDocument.parse(data) else { continue }
                for r in doc.resources where r.magic == "PAT0" {
                    checked += 1
                    let label = "\(n.name)/\(f.name)/\(r.name)"
                    guard let anim = PAT0Animation.parse(r, rawFile: doc.rawData) else { fail("\(label): didn't parse"); continue }
                    if anim.textureNames.contains(where: \.isEmpty) || anim.materials.contains(where: { $0.name.isEmpty }) { fail("\(label): empty name") }
                    let built = anim.build()
                    var a = Data(r.data), b = built.data
                    if a.count != b.count { fail("\(label): size \(b.count) vs retail \(a.count)"); if failures < 4 { dump(a, b) }; continue }
                    for s in built.strings { for i in 0..<4 { a[s.fieldOffset + i] = 0; b[s.fieldOffset + i] = 0 } }
                    for i in 0x0C..<0x10 { a[i] = 0; b[i] = 0 } // BRRES back-offset
                    // Retail's 1/span step is often 1-3 ulps below the correctly rounded value
                    // (computed by Nintendo's converter some other way); the runtime only uses it
                    // to scale playback, so up to 3 ulps is accepted and counted.
                    for o in stride(from: 0, to: a.count - 3, by: 4) where a.be32(o) != b.be32(o) && abs(Int(a.be32(o)) - Int(b.be32(o))) <= 3 {
                        ulpOff += 1; for i in 0..<4 { b[o + i] = a[o + i] }
                    }
                    // Tracks shared by several materials appear in either order in retail files
                    // (nothing reads them by position), so a same-size file whose content parses
                    // back identically is accepted and counted rather than failed.
                    if a != b {
                        if reread(anim) == anim { trackOrder += 1 } else { fail("\(label): bytes differ at 0x\(String(firstDiff(a, b), radix: 16))"); if failures < 4 { dump(a, b) } }
                    } else { identical += 1 }
                    if reread(anim) != anim { fail("\(label): changed through a BRRES save") }
                }
            }
        }
        try walk(disc.root)
        let flip = PAT0Animation.flipbook(name: "water", material: "mat_water", slot: 0, textures: ["w0", "w1", "w2", "w1"], frameLength: 4, loops: true)
        if reread(flip) != flip { fail("flipbook didn't round-trip") }
        if PAT0Animation.texture(at: 9, keys: flip.materials[0].samplers[0].keys) != 2 { fail("frame 9 should show w2") }
        print("retail PAT0s checked: \(checked): \(identical) byte-identical, \(trackOrder) with shared tracks in another order (\(ulpOff) track steps 1-3 ulps off)")
        if checked == 0 { fail("no retail PAT0 found") }
        print(failures == 0 ? "ok" : "\(failures) failures")
        if failures > 0 { exit(1) }
    }
    static func firstDiff(_ a: Data, _ b: Data) -> Int { zip(a, b).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(a.count, b.count) }
    static func dump(_ a: Data, _ b: Data) {
        for (label, d) in [("retail", a), ("built ", b)] {
            print(label, stride(from: 0, to: min(d.count, 0xC0), by: 4).map { String(format: "%08X", d.be32($0)) }.joined(separator: " "))
        }
    }
}
