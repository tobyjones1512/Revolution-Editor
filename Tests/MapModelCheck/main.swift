// Self-check for MapModelBuilder ("Create Map"), run against real Mario Kart Wii course archives.
//
//   swiftc -O -o /tmp/mapcheck \
//     "Revolution IDE/Core/BinaryIO.swift" \
//     "Revolution IDE/Core/Formats/"{Yaz0,U8Archive,SZS,BRRES,BRRESIndexGroup,BRRESTypes,TextureCodec,MathTypes,MDL0,OBJImporter,MDL0Writer,MapModelBuilder}.swift \
//     Tests/MapModelCheck/main.swift
//   /tmp/mapcheck "/path/to/beginner_course.szs"
//
// Exits non-zero on the first broken invariant.

import Foundation
var failures = 0
func check(_ c: Bool, _ m: String) { if c { print("ok   \(m)") } else { print("FAIL \(m)"); failures += 1 } }

// Takes either a course archive or a loose .brres, so both of the paths the Create Map menu
// offers, an entry inside a .szs, and a real file in the project, are exercised by the
// same checks.
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let raw = try Data(contentsOf: input)
let course: Data
if raw.count >= 4, raw.asciiString(at: 0, length: 4) == "bres" {
    course = raw
} else {
    let (root, _) = try SZS.open(raw)
    guard let found = root.find(path: ["course_model.brres"])?.data else {
        print("FAIL \(input.lastPathComponent) has no course_model.brres"); exit(1)
    }
    course = found
}
print("source: \(input.lastPathComponent) (\(course.count) bytes of BRRES)")

guard let options = MapModelBuilder.options(inBRRES: course) else {
    print("FAIL no options"); exit(1)
}
print("options: " + options.map { "\($0.displayName)[\($0.meshCount)m/\($0.triangleCount)t]" }.joined(separator: " "))
check(!options.isEmpty, "source model offers textures to pick")

// Keep a subset, the first and third, as a user switching off scenery would.
let keep = Set([options[0].id, options[min(2, options.count - 1)].id])
let expectedTris = options.filter { keep.contains($0.id) }.reduce(0) { $0 + $1.triangleCount }
let data = try MapModelBuilder.build(fromBRRES: course, keeping: keep, modelName: "map")

let doc = try BRRESDocument.parse(data)
// Retail's own map_model.brres carries no TEX0 at all (confirmed against the disc: nTex=0, no
// UVs, no TextureLinks), just an untextured material with a flat colour. Match that.
check(doc.resources.count == 1, "map has exactly a model, no texture (got \(doc.resources.count))")
check(!doc.resources.contains { $0.magic == "TEX0" }, "no TEX0 resource, matching retail")

guard let mdl = doc.resources.first(where: { $0.magic == "MDL0" }),
      let model = MDL0Parser.parse(mdl, rawFile: doc.rawData) else {
    print("FAIL map model is not parseable"); exit(1)
}
let tris = model.meshes.reduce(0) { $0 + $1.vertices.count / 3 }
check(tris == expectedTris, "kept exactly the selected triangles: \(tris) == \(expectedTris)")
check(model.meshes.allSatisfy { $0.textureName == nil }, "every mesh is untextured, matching retail")
check(mdl.name == "map", "model resource is named 'map', as MKWii expects")

// Missing posLD/posRU is a documented crash cause, the minimap HUD looks these up by name and the game panics
// (g3d_resnode_ac.h ResNode::ref) if they're not there. Read the Bones dict directly since
// MDL0Parser doesn't expose bones.
func sectionOffset(_ d: Data, _ i: Int) -> Int { Int(d.readInt32BE(at: 0x10 + i * 4)) }
let boneNames = BRRESIndexGroup.parse(mdl.data, groupStart: sectionOffset(mdl.data, 1), names: (doc.rawData, mdl.fileOffset)).map(\.name)
check(boneNames == ["map", "posLD", "posRU"], "bones are map, posLD, posRU in that order, matching retail (got \(boneNames))")

// Retail map render trees carry exactly NodeTree + DrawOpa, never a DrawXlu draw list
// (confirmed across all 52 course archives, every one rt=2).
let renderTreeNames = BRRESIndexGroup.parse(mdl.data, groupStart: sectionOffset(mdl.data, 0), names: (doc.rawData, mdl.fileOffset)).map(\.name)
check(renderTreeNames == ["NodeTree", "DrawOpa"], "render tree is NodeTree + DrawOpa, matching retail (got \(renderTreeNames))")

// Retail map materials are all untextured with zero texgen (texGens=0; confirmed across all 52).
if let material = BRRESIndexGroup.parse(mdl.data, groupStart: sectionOffset(mdl.data, 8), names: (doc.rawData, mdl.fileOffset)).first {
    let d = mdl.data
    let texgens = d.u8(material.dataOffset + 0x14)
    check(texgens == 0, "map material declares 0 texgen, matching retail (got \(texgens))")
} else { check(false, "map has a material section") }

// The fields that decide whether the minimap draws at all, checked against the retail map model
// in the same archive when there is one. A prior writer passed every check above yet drew nothing
// in-game: posLD/posRU had translation 0 (position only in their bounds), the model declared 1 view
// matrix while the markers used matrix 1 and 2, and chan0 was all zero (black, alpha 0, the
// untextured TEV outputs exactly that raster colour).
let md = mdl.data
func bone(_ i: Int) -> Int { BRRESIndexGroup.parse(md, groupStart: sectionOffset(md, 1))[i].dataOffset }
let info = 0x4C
check(md.readUInt32BE(at: info + 0x1C) == 3, "numViewMtx is 3 (map, posLD, posRU)")
check((0..<3).allSatisfy { md.readInt32BE(at: info + 0x44 + $0 * 4) == Int32($0) }, "matrix LUT is [0, 1, 2]")
for i in 1...2 {
    let b = bone(i)
    check(md.readFloatBE(at: b + 0x38) != 0 || md.readFloatBE(at: b + 0x40) != 0, "\(boneNames[i]) has a real SRT translation")
    check(md.readInt32BE(at: b + 0x10) == Int32(i), "\(boneNames[i]) uses matrix \(i)")
    check(bone(0) == b + Int(md.readInt32BE(at: b + 0x5C)), "\(boneNames[i]) parent is map")
}
check(bone(1) == bone(0) + Int(md.readInt32BE(at: bone(0) + 0x60)), "map's first child is posLD")
// Bones are read with float loads, which the Wii's CPU won't do from a misaligned address --
// a crash on hardware only (Dolphin ignores alignment). Every MDL0 entry must be word-aligned.
check((0..<3).allSatisfy { bone($0) % 4 == 0 }, "bones are word-aligned (at \((0..<3).map { String(bone($0), radix: 16) }))")
let ourMat = BRRESIndexGroup.parse(md, groupStart: sectionOffset(md, 8))[0].dataOffset
check(md.readUInt32BE(at: ourMat + 0x3F0) == 0x3F && md.readUInt32BE(at: ourMat + 0x3FC) == 0x701,
      "chan0 is flag 0x3F / control 0x701 (vertex colour)")
if let root = try? SZS.open(raw).0, let retail = root.find(path: ["map_model.brres"])?.data,
   let rdoc = try? BRRESDocument.parse(retail), let rmdl = rdoc.resources.first(where: { $0.magic == "MDL0" }) {
    let r = rmdl.data
    let rMat = BRRESIndexGroup.parse(r, groupStart: sectionOffset(r, 8))[0].dataOffset
    check(r.subdata(at: rMat + 0x3F0, length: 0x28) == md.subdata(at: ourMat + 0x3F0, length: 0x28),
          "chan block byte-identical to retail map_model")
    let rBones = BRRESIndexGroup.parse(r, groupStart: sectionOffset(r, 1)).map(\.dataOffset)
    for i in 0..<3 {
        for field in [0x10, 0x14, 0x5C, 0x60, 0x64, 0x68] {
            check(r.readInt32BE(at: rBones[i] + field) == md.readInt32BE(at: bone(i) + field),
                  "bone \(i) field 0x\(String(field, radix: 16)) matches retail")
        }
    }
}

// Dropping everything must be refused rather than producing an empty model.
do {
    _ = try MapModelBuilder.build(fromBRRES: course, keeping: [], modelName: "map")
    check(false, "empty selection is rejected")
} catch { check(true, "empty selection is rejected: \(error.localizedDescription)") }

// Keeping everything must preserve the whole course's triangle count.
let all = try MapModelBuilder.build(fromBRRES: course, keeping: Set(options.map(\.id)), modelName: "map")
if let m = try? BRRESDocument.parse(all), let r = m.resources.first(where: { $0.magic == "MDL0" }),
   let parsed = MDL0Parser.parse(r, rawFile: m.rawData) {
    let allTris = parsed.meshes.reduce(0) { $0 + $1.vertices.count / 3 }
    check(allTris == options.reduce(0) { $0 + $1.triangleCount }, "keeping all textures keeps all \(allTris) triangles")
} else { check(false, "all-textures map parses") }

// Shaded minimap (the Minimap Editor): the first texture white, every other one dark grey. Retail
// shades inside one mesh with real vertex colours (castle_course: 0x66/0x80/0xFF), so this reads
// the colour set and every vertex's colour index straight out of the file rather than trusting
// the parser.
let shades = Dictionary(uniqueKeysWithValues: options.enumerated().map { ($1.id, $0 == 0 ? UInt8(0xFF) : UInt8(0x66)) })
let shaded = try MapModelBuilder.build(fromBRRES: course, shades: shades, modelName: "map")
if let sdoc = try? BRRESDocument.parse(shaded), let smdl = sdoc.resources.first(where: { $0.magic == "MDL0" }) {
    let d = smdl.data
    let colourSets = BRRESIndexGroup.parse(d, groupStart: sectionOffset(d, 4)).map(\.dataOffset)
    let meshes = BRRESIndexGroup.parse(d, groupStart: sectionOffset(d, 10)).map(\.dataOffset)
    var whiteTris = 0, allInRange = true
    for (c, m) in zip(colourSets, meshes) {
        let count = Int(d.readUInt16BE(at: c + 0x1E))
        let values = (0..<count).map { d[d.startIndex + c + Int(d.readInt32BE(at: c + 8)) + $0 * 4] }
        check(values.allSatisfy { $0 == 0xFF || $0 == 0x66 } && count <= 2, "colour set holds only the chosen shades: \(values.map { String($0, radix: 16) })")
        let dl = m + 0x24 + Int(d.readInt32BE(at: m + 0x2C))
        check(d[d.startIndex + dl] == 0x90, "main display list starts with GX_TRIANGLES")
        let vertexCount = Int(d.readUInt16BE(at: dl + 1))
        for t in 0..<(vertexCount / 3) {
            let idx = (0..<3).map { d[d.startIndex + dl + 3 + (t * 3 + $0) * 3 + 2] }
            if idx.contains(where: { Int($0) >= count }) || Set(idx).count != 1 { allInRange = false }
            if count > 0, values[Int(idx[0])] == 0xFF { whiteTris += 1 }
        }
    }
    check(allInRange, "every vertex's colour index is in range, and each triangle is one shade")
    check(whiteTris == options[0].triangleCount, "the white texture's \(options[0].triangleCount) triangles are exactly the white ones (got \(whiteTris))")
} else { check(false, "shaded map parses") }

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
