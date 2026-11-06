// Byte-exactness check: every BRRES and SZS this app writes must be the file Nintendo's own tools
// would have written. Reads archives straight out of a retail Mario Kart Wii disc image, rebuilds
// each one through this app's writers, and requires the result to be identical.
//
// This is the only check that can catch a layout rule the reader and writer are both wrong about,
// because the reference is the disc rather than our own output.
//
//   swiftc -O -o /tmp/fidelity \
//     "Revolution IDE/Core/"{BinaryIO,DiscModel,WiiDisc,Crypto,ClusterCrypto,KeyManager,FSTBuilder}.swift \
//     "Revolution IDE/Core/Formats/"{Yaz0,U8Archive,SZS,BRRES,BRRESIndexGroup}.swift \
//     Tests/RetailFidelityCheck/main.swift
//   /tmp/fidelity <iso> <common-key> [sampleCount]
//
// Exits non-zero if anything fails to reproduce.

import Foundation

let iso = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "\(ProcessInfo.processInfo.environment["ROMS_DIR"] ?? "Roms")/Wii/MKWii/Mario Kart Wii (USA) (En,Fr,Es).iso")
let keyPath = CommandLine.arguments.count > 2
    ? CommandLine.arguments[2]
    : "\(ProcessInfo.processInfo.environment["ROMS_DIR"] ?? "Roms")/Wii/Keys/common-key"
let sampleCount = CommandLine.arguments.count > 3 ? (Int(CommandLine.arguments[3]) ?? 150) : 150

let disc = try WiiDisc(url: iso, commonKey: [UInt8](try Data(contentsOf: URL(fileURLWithPath: keyPath))), koreanKey: nil)
var candidates: [DiscNode] = []
func walk(_ n: DiscNode) {
    if n.isDirectory { n.children.forEach(walk); return }
    if n.name.hasSuffix(".szs") || n.name.hasSuffix(".arc") || n.name.hasSuffix(".brres") { candidates.append(n) }
}
walk(disc.root)
print("disc holds \(candidates.count) archive/model files")

var yaz0 = (ok: 0, bad: 0), u8 = (ok: 0, bad: 0), brres = (ok: 0, bad: 0), szs = (ok: 0, bad: 0)
var failures: [String] = []
func record(_ ok: Bool, _ counter: inout (ok: Int, bad: Int), _ what: String) {
    if ok { counter.ok += 1 } else { counter.bad += 1; failures.append(what) }
}

// Spread the sample across the whole disc rather than taking the first N, which would only ever
// cover one folder, the kart archives that exposed the trailing-flag-byte rule sort late.
let step = max(1, candidates.count / max(sampleCount, 1))
var index = 0
while index < candidates.count {
    let node = candidates[index]
    index += step
    guard let data = try? disc.readFile(node: node), data.count > 16 else { continue }

    if Yaz0.isYaz0(data), let raw = try? Yaz0.decode(data) {
        record(Yaz0.encode(raw) == data, &yaz0, "Yaz0 \(node.name)")
    }
    guard let (root, compressed) = try? SZS.open(data) else {
        if data.asciiString(at: 0, length: 4) == "bres", let doc = try? BRRESDocument.parse(data) {
            record(doc.serialize() == data, &brres, "BRRES \(node.name)")
        }
        continue
    }
    let decompressed = Yaz0.isYaz0(data) ? ((try? Yaz0.decode(data)) ?? data) : data
    record(U8Archive.serialize(root) == decompressed, &u8, "U8 \(node.name)")
    record(SZS.save(root: root, compressed: compressed) == data, &szs, "SZS \(node.name)")
    func visit(_ n: U8Node) {
        if n.isDirectory { n.children.forEach(visit); return }
        guard let d = n.data, d.count >= 4, d.asciiString(at: 0, length: 4) == "bres",
              let doc = try? BRRESDocument.parse(d) else { return }
        record(doc.serialize() == d, &brres, "BRRES \(node.name)/\(n.name)")
    }
    visit(root)
}

func line(_ label: String, _ c: (ok: Int, bad: Int)) -> String {
    "\(label): \(c.ok) identical, \(c.bad) differing"
}
print(line("Yaz0  re-encode   ", yaz0))
print(line("U8    re-serialize", u8))
print(line("BRRES re-serialize", brres))
print(line("whole .szs        ", szs))
if failures.isEmpty {
    print("\nALL BYTE-IDENTICAL")
} else {
    print("\n\(failures.count) FAILURE(S): \(failures.prefix(20).joined(separator: ", "))")
}
exit(failures.isEmpty ? 0 : 1)
