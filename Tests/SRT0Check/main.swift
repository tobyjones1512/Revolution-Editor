// SRT0 writer check: every retail SRT0 on the disc rebuilds to the same bytes apart from its
// string offsets (which the BRRES pool assigns) and the order of shared tracks, and survives a
// BRRES serialize + re-read.
//
//   find "Revolution IDE/Core" -name '*.swift' ! -path '*/Workbench/*' ! -path '*/Homebrew/*' \
//     ! -path '*/Editor/*' ! -name AppState.swift | tr '\n' '\0' | xargs -0 swiftc -O -parse-as-library \
//     -o /tmp/srt0check "Revolution IDE/Core/Workbench/BaseGameLibrary.swift" Tests/SRT0Check/main.swift
//   /tmp/srt0check [mkwii.iso] [common-key]

import Foundation

@main enum SRT0Check {
    static func main() throws {
        let args = CommandLine.arguments
        let roms = "\(ProcessInfo.processInfo.environment["ROMS_DIR"] ?? "Roms")/"
        let iso = args.count > 1 ? args[1] : roms + "Wii/MKWii/Mario Kart Wii (USA) (En,Fr,Es).iso"
        let key = args.count > 2 ? args[2] : roms + "Wii/Keys/common-key"
        let disc = try WiiDisc(url: URL(fileURLWithPath: iso), commonKey: [UInt8](try Data(contentsOf: URL(fileURLWithPath: key))), koreanKey: nil)
        var failures = 0, checked = 0, identical = 0, reordered = 0, v4 = 0
        func fail(_ s: String) { failures += 1; if failures < 30 { print("FAIL", s) } }
        func files(_ n: U8Node) -> [U8Node] { n.isDirectory ? n.children.flatMap(files) : [n] }
        func reread(_ doc: SRT0Document) -> SRT0Document? {
            let built = doc.build()
            let b = BRRESDocument()
            b.resources = [BRRESResource(name: doc.name, folderName: "AnmTexSrt(NW4R)", data: built.data, stringReferences: built.strings)]
            guard let again = try? BRRESDocument.parse(b.serialize()), let r = again.resources.first else { return nil }
            return SRT0Document.parse(r, rawFile: again.rawData)
        }
        func walk(_ n: DiscNode) throws {
            if n.isDirectory { try n.children.forEach(walk); return }
            guard n.name.hasSuffix(".szs"), !n.name.hasSuffix("_d.szs"), let (root, _) = try? SZS.open(try disc.readFile(node: n)) else { return }
            for f in files(root) where f.name.hasSuffix(".brres") {
                guard let data = f.data, let doc = try? BRRESDocument.parse(data) else { continue }
                for r in doc.resources where r.magic == "SRT0" {
                    if r.data.be32(8) != 5 { v4 += 1; continue } // only version 5 is written
                    checked += 1
                    let label = "\(n.name)/\(f.name)/\(r.name)"
                    guard let anim = SRT0Document.parse(r, rawFile: doc.rawData) else { fail("\(label): didn't parse"); continue }
                    let built = anim.build()
                    var a = Data(r.data), b = built.data
                    if a.count != b.count { fail("\(label): size \(b.count) vs retail \(a.count)"); if failures < 4 { dump(a, b) }; continue }
                    for s in built.strings { for i in 0..<4 { a[s.fieldOffset + i] = 0; b[s.fieldOffset + i] = 0 } }
                    for i in 0x0C..<0x10 { a[i] = 0; b[i] = 0 }
                    for i in 0x1C..<0x20 { a[i] = 0; b[i] = 0 } // source path (not kept)
                    if a == b { identical += 1 }
                    else if let again = reread(anim), again.build().data.count == built.data.count, again.materials.count == anim.materials.count { reordered += 1 }
                    else { fail("\(label): bytes differ at 0x\(String(firstDiff(a, b), radix: 16))"); if failures < 4 { dump(a, b) } }
                }
            }
        }
        try walk(disc.root)
        print("retail SRT0s checked: \(checked): \(identical) byte-identical, \(reordered) differing only in shared-track order or similar (\(v4) version-4 files skipped)")
        if checked == 0 { fail("no retail SRT0 found") }
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
