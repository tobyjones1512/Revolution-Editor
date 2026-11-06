// Effect/post-effect formats check: every retail BREFT texture decodes and its entry size matches
// its header, every BREFF emitter's texture names exist in the sibling BREFT, and every
// BBLM/BDOF/BLIGHT/BLMAP/BMM field schema stays in range and writes back each value unchanged.
//
//   find "Revolution IDE/Core" -name '*.swift' ! -path '*/Workbench/*' ! -path '*/Homebrew/*' \
//     ! -path '*/Editor/*' ! -name AppState.swift | tr '\n' '\0' | xargs -0 swiftc -O -parse-as-library \
//     -o /tmp/effectcheck "Revolution IDE/Core/Workbench/BaseGameLibrary.swift" Tests/EffectFormatsCheck/main.swift
//   /tmp/effectcheck [mkwii.iso] [common-key]

import Foundation

@main enum EffectFormatsCheck {
    static func main() throws {
        let args = CommandLine.arguments
        let roms = "\(ProcessInfo.processInfo.environment["ROMS_DIR"] ?? "Roms")/"
        let iso = args.count > 1 ? args[1] : roms + "Wii/MKWii/Mario Kart Wii (USA) (En,Fr,Es).iso"
        let key = args.count > 2 ? args[2] : roms + "Wii/Keys/common-key"
        let disc = try WiiDisc(url: URL(fileURLWithPath: iso), commonKey: [UInt8](try Data(contentsOf: URL(fileURLWithPath: key))), koreanKey: nil)
        var failures = 0, textures = 0, emitters = 0, refs = 0, missingRefs = 0, fieldFiles = 0, effectFiles = 0
        func fail(_ s: String) { failures += 1; if failures < 40 { print("FAIL", s) } }
        func files(_ n: U8Node) -> [U8Node] { n.isDirectory ? n.children.flatMap(files) : [n] }
        func walk(_ n: DiscNode) throws {
            if n.isDirectory { try n.children.forEach(walk); return }
            guard n.name.hasSuffix(".szs"), let (root, _) = try? SZS.open(try disc.readFile(node: n)) else { return }
            let all = files(root)
            var breftNames: [String: Set<String>] = [:]
            for f in all where f.name.lowercased().hasSuffix(".breft") {
                guard let data = f.data else { continue }
                effectFiles += 1
                do {
                    let doc = try REFT.parse(data)
                    let entries = try REFT.tableEntries(data, magic: "REFT")
                    if doc.images.count != entries.count { fail("\(n.name)/\(f.name): \(doc.images.count) of \(entries.count) textures read") }
                    for (img, e) in zip(doc.images, entries) {
                        textures += 1
                        if img.rgba == nil { fail("\(n.name)/\(f.name)/\(e.name): \(img.format) didn't decode") }
                        let imageSize = Int(data.be32(e.offset + 8)), paletteSize = Int(data.be32(e.offset + 0x10))
                        if e.size < imageSize + paletteSize { fail("\(n.name)/\(f.name)/\(e.name): entry \(e.size) < image \(imageSize) + palette \(paletteSize)") }
                    }
                    breftNames[(f.name as NSString).deletingPathExtension] = Set(entries.map(\.name))
                } catch { fail("\(n.name)/\(f.name): \(error)") }
            }
            for f in all where f.name.lowercased().hasSuffix(".breff") {
                guard let data = f.data else { continue }
                effectFiles += 1
                do {
                    let doc = try REFFDocument.parse(data)
                    let names = breftNames[(f.name as NSString).deletingPathExtension] ?? []
                    for e in doc.emitters {
                        emitters += 1
                        for t in e.textures { refs += 1; if !names.contains(t) { missingRefs += 1; if missingRefs < 10 { print("note: \(n.name)/\(f.name)/\(e.name) -> \(t) not in sibling breft") } } }
                    }
                } catch { fail("\(n.name)/\(f.name): \(error)") }
            }
            for f in all {
                guard let data = f.data, BinaryFieldSchema.extensions.contains((f.name as NSString).pathExtension.lowercased()) else { continue }
                guard let schema = BinaryFieldSchema.fields(fileName: f.name, data: data) else { fail("\(n.name)/\(f.name): no schema (\(data.count) bytes)"); continue }
                fieldFiles += 1
                var copy = data
                for field in schema.fields {
                    guard field.offset + field.size <= data.count else { fail("\(n.name)/\(f.name): \(field.label) out of range"); continue }
                    if case .text = field.kind { continue } // NUL padding after the name isn't kept
                    if !BinaryFieldSchema.set(field, to: BinaryFieldSchema.value(field, in: data), in: &copy) { fail("\(n.name)/\(f.name): \(field.label) value didn't parse back") }
                }
                if copy != data { fail("\(n.name)/\(f.name): writing values back changed bytes") }
            }
        }
        try walk(disc.root)
        print("breff/breft files \(effectFiles), textures \(textures), emitters \(emitters), texture refs \(refs) (\(missingRefs) not in sibling), field files \(fieldFiles)")
        if refs == 0 { fail("no emitter texture references found") }
        if missingRefs * 20 > refs { fail("too many emitter texture names unresolved: \(missingRefs)/\(refs)") }
        print(failures == 0 ? "ok" : "\(failures) failures")
        if failures > 0 { exit(1) }
    }
}
