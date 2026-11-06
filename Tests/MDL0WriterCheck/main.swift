// Structural self-check for MDL0Writer / BRRESDocument, run against a REAL Mario Kart Wii course
// archive rather than only against this app's own reader, a round trip through one codebase
// cannot catch a mistake the reader and writer share, and three of the bugs this file now guards
// against were invisible to exactly that kind of test.
//
//   swiftc -O -o /tmp/mdl0check \
//     "Revolution IDE/Core/BinaryIO.swift" \
//     "Revolution IDE/Core/Formats/"{Yaz0,U8Archive,SZS,BRRES,BRRESIndexGroup,BRRESTypes,TextureCodec,MathTypes,OBJImporter,MDL0Writer}.swift \
//     Tests/MDL0WriterCheck/main.swift
//   /tmp/mdl0check "/path/to/beginner_course.szs"
//
// Exits non-zero on the first broken invariant.

import Foundation

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { print("ok   \(msg)") } else { print("FAIL \(msg)"); failures += 1 }
}
func hex(_ v: Int) -> String { "0x" + String(v, radix: 16) }

func sectionOffset(_ d: Data, _ i: Int) -> Int { Int(d.readInt32BE(at: 0x10 + i * 4)) }
/// Where dictionary names are read from: they live in the BRRES's shared string pool, so for a
/// freshly built model this is set to a container holding it (see below).
nonisolated(unsafe) var nameSource: (wholeFile: Data, offset: Int)? = nil
func dict(_ d: Data, at offset: Int) -> [(name: String, dataOffset: Int)] {
    // A built model's name fields are only filled in once it's in a container: read the group
    // there (same bytes otherwise), with offsets back in the model's own terms.
    if let (whole, base) = nameSource {
        return BRRESIndexGroup.parse(whole, groupStart: base + offset).map { ($0.name, $0.dataOffset - base) }
    }
    return BRRESIndexGroup.parse(d, groupStart: offset).map { ($0.name, $0.dataOffset) }
}
/// Mesh header layout: two 12-byte {size, size2, offset} display-list
/// descriptors at 0x18 and 0x24, then the name/index/count block.
enum Mesh {
    static let setupSize = 0x18, setupSize2 = 0x1C, mainSize = 0x24, mainSize2 = 0x28, field34 = 0x34
}

// MARK: Reference values taken from the retail disc.

let retailPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "\(ProcessInfo.processInfo.environment["ROMS_DIR"] ?? "Roms")/Wii/MKWii/beginner_course.szs"
let (retailRoot, _) = try SZS.open(try Data(contentsOf: URL(fileURLWithPath: retailPath)))

var retailMeshes = 0
for model in ["course_model.brres", "vrcorn_model.brres", "map_model.brres"] {
    guard let raw = retailRoot.find(path: [model])?.data,
          let mdl = try? BRRESDocument.parse(raw).resources.first(where: { $0.magic == "MDL0" })?.data
    else { continue }
    check(Int(raw.be32(8)) == raw.count, "\(model): BRRES header file size == actual")
    check(Int(mdl.be32(4)) == mdl.count, "\(model): MDL0 declared size == resource length")
    for mesh in dict(mdl, at: sectionOffset(mdl, 10)) {
        let o = mesh.dataOffset
        retailMeshes += 1
        check(mdl.be32(o + Mesh.setupSize) == 0xE0 && mdl.be32(o + Mesh.setupSize2) == 0x80,
              "\(model) mesh \(retailMeshes): setup DL descriptor is the expected 0xE0/0x80")
        check(mdl.be32(o + Mesh.mainSize) == mdl.be32(o + Mesh.mainSize2),
              "\(model) mesh \(retailMeshes): main DL size == size2")
        check(mdl.be32(o + Mesh.field34) == 0, "\(model) mesh \(retailMeshes): field 0x34 is zero")
    }
}
check(retailMeshes >= 20, "read \(retailMeshes) retail meshes to compare against")

// MARK: What this app writes must satisfy the same invariants.

let tris = OBJImporter.parse("""
v 0 0 0
v 1 0 0
v 0 1 0
v 1 1 0
vt 0 0
vt 1 0
vt 0 1
vt 1 1
usemtl red
f 1/1 2/2 3/3
usemtl blue
f 2/2 4/4 3/3
""")
check(tris.count == 2, "OBJ parsed to 2 triangles (got \(tris.count))")

let groups = MDL0Writer.groups(from: tris) { name in
    MDL0Writer.MaterialSpec(name: name ?? "m", color: (1, 0, 0), textureName: name == "red" ? "tex_red" : nil)
}
check(groups.count == 2, "one group per usemtl")
guard let built = MDL0Writer.build(name: "course", groups: groups) else {
    print("FAIL MDL0Writer.build returned nil"); exit(1)
}
let mdl0 = built.data
check(!built.stringReferences.isEmpty, "the model reports the names it needs from the shared pool")
// Every dictionary name goes in the BRRES's string pool, length-prefixed, as in retail: NW4R's
// ResName lookups ("DrawOpa", "posLD", texture links) compare that length. Read names back
// through a container holding this model.
let probe = BRRESDocument()
probe.resources = [BRRESResource(name: "course", folderName: "3DModels(NW4R)", data: mdl0, stringReferences: built.stringReferences)]
let probeDoc = try BRRESDocument.parse(probe.serialize())
nameSource = (probeDoc.rawData, probeDoc.resources[0].fileOffset)

check(Int(mdl0.be32(4)) == mdl0.count,
      "MDL0 declared size \(hex(Int(mdl0.be32(4)))) == actual \(hex(mdl0.count)) (string table included)")
check(mdl0.be32(8) == 11, "MDL0 version is 11. Mario Kart Wii loads no other")

let sectionNames = ["RenderTree", "Bones", "Positions", "Normals", "Colors", "UVs", "FurVec",
                    "FurPos", "Materials", "Shaders", "Meshes", "TextureLinks", "PaletteLinks", "UserData"]
var spans: [(lo: Int, hi: Int, name: String)] = []
for i in 0..<14 where sectionOffset(mdl0, i) != 0 {
    let start = sectionOffset(mdl0, i)
    let entries = dict(mdl0, at: start)
    spans.append((start, start + 8 + (entries.count + 1) * 16, sectionNames[i]))
    for k in entries.indices {
        // The u32 before each name is its length, as NW4R's ResName requires.
        let entry = start + 8 + (k + 1) * 16
        let at = nameSource!.offset + start + Int(Int32(bitPattern: nameSource!.wholeFile.be32(nameSource!.offset + entry + 8)))
        check(at >= 4 && Int(nameSource!.wholeFile.be32(at - 4)) == entries[k].name.utf8.count,
              "\(sectionNames[i]) entry '\(entries[k].name)' is length-prefixed")
    }
    for e in entries {
        check(e.dataOffset > 0 && e.dataOffset < mdl0.count,
              "\(sectionNames[i]).\(e.name) -> \(hex(e.dataOffset)) is inside the file")
        check(!e.name.isEmpty && e.name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") },
              "\(sectionNames[i]) entry name '\(e.name)' is intact")
    }
}
// Under-reserving a dictionary lets it run over the next one, which then overwrites its entries.
for a in spans.indices {
    for b in (a + 1)..<spans.count {
        check(spans[a].hi <= spans[b].lo || spans[b].hi <= spans[a].lo,
              "\(spans[a].name) and \(spans[b].name) dictionaries do not overlap")
    }
}
check(dict(mdl0, at: sectionOffset(mdl0, 0)).map(\.name) == ["NodeTree", "DrawOpa", "DrawXlu"],
      "all three render-tree lists are present and named")
// Regression: every material this writer builds is opaque, so DrawXlu must stay empty. Duplicating
// every draw into it as well drew each mesh from two scene-graph slots, crashing with
// "g3d_resnode_ac.h ResNode::ref: Object not valid" in-game (never caught by any reader-based
// round trip, since a reader happily parses a well-formed-but-wrong duplicate list).
let drawXluOfs = dict(mdl0, at: sectionOffset(mdl0, 0)).first(where: { $0.name == "DrawXlu" })!.dataOffset
check(mdl0[mdl0.startIndex + drawXluOfs] == 1, "DrawXlu is empty, opcode 1 (end) as its first byte")
check(dict(mdl0, at: sectionOffset(mdl0, 11)).map(\.name) == ["tex_red"], "texture link written for tex_red")

// Regression: the shader/TEV block is its own display list, and NW4R asserts its pointer is
// 32-byte aligned before calling it, distinct from the material's own alignment, which was
// already guaranteed. A material's header+DL size is not itself a multiple of 32, so the shader
// that immediately follows needs its own padding or this crashes every custom course in-game.
for entry in dict(mdl0, at: sectionOffset(mdl0, 8)) {
    check(entry.dataOffset % 32 == 0, "material \(entry.name) starts 32-byte aligned")
    // The material's own display list (ofsDisplayLists @ 0x3C, GX-called directly) needs to
    // land 32-aligned too, distinct from the material struct's own start, which was already
    // guaranteed. The writer has to pad here first; missing that padding is what
    // actually crashed every custom course with the g3d_resmat_ac.h assertion.
    let dlOfs = Int(mdl0.readInt32BE(at: entry.dataOffset + 0x3C))
    check(dlOfs % 32 == 0, "material \(entry.name): own display list starts 32-byte aligned")
}
for entry in dict(mdl0, at: sectionOffset(mdl0, 9)) {
    check(entry.dataOffset % 32 == 0, "shader \(entry.name) starts 32-byte aligned")
}

for mesh in dict(mdl0, at: sectionOffset(mdl0, 10)) {
    let o = mesh.dataOffset
    check(mdl0.be32(o + Mesh.setupSize) == 0xE0 && mdl0.be32(o + Mesh.setupSize2) == 0x80,
          "\(mesh.name): setup DL descriptor matches retail's 0xE0/0x80")
    check(mdl0.be32(o + Mesh.mainSize) == mdl0.be32(o + Mesh.mainSize2), "\(mesh.name): main DL size == size2")
    check(mdl0.be32(o + Mesh.field34) == 0, "\(mesh.name): field 0x34 is zero, as in retail")
}

// MARK: The vertex descriptor must describe exactly what the display list contains.
//
// This is the invariant that a load-but-draw-nothing model violates: CP register 0x50 tells the
// GPU the byte width of every vertex, so if it disagrees with the bytes the primitive actually
// carries, each vertex after the first is decoded from the middle of its predecessor.

/// GX attribute status: 0 GX_NONE, 1 GX_DIRECT, 2 GX_INDEX8, 3 GX_INDEX16.
func indexWidth(_ status: UInt32) -> Int {
    switch status { case 2: return 1; case 3: return 2; default: return 0 }
}
func bytesPerVertex(cpLo: UInt32, cpHi: UInt32) -> Int {
    var n = Int(cpLo & 1)                                    // position/normal matrix index
    for i in 0..<8 { n += Int((cpLo >> (1 + UInt32(i))) & 1) } // texture matrix indices
    for shift in [UInt32(9), 11, 13, 15] { n += indexWidth((cpLo >> shift) & 3) }
    for i in 0..<8 { n += indexWidth((cpHi >> (UInt32(i) * 2)) & 3) }
    return n
}
/// Walks a GX command stream, returning the vertices drawn, or nil if a command doesn't decode --
/// which is itself the failure, since it means the stream desynchronised.
func walkDisplayList(_ d: Data, start: Int, size: Int, bpv: Int) -> Int? {
    var p = start, drawn = 0
    let end = start + size
    while p < end {
        switch d.u8(p) {
        case 0: p += 1                                       // NOP padding
        case 0x08: p += 6                                    // CP register write
        case 0x10: p += 5 + (Int(d.be16(p + 1)) + 1) * 4     // XF register write
        case 0x61: p += 5                                    // BP register write
        case let op where op >= 0x80 && op <= 0xB8:          // primitive
            let count = Int(d.be16(p + 1))
            drawn += count
            p += 3 + count * bpv
        default: return nil
        }
    }
    return p == end ? drawn : nil
}

for mesh in dict(mdl0, at: sectionOffset(mdl0, 10)) {
    let o = mesh.dataOffset
    let cpLo = mdl0.be32(o + 0x0C), cpHi = mdl0.be32(o + 0x10)
    let bpv = bytesPerVertex(cpLo: cpLo, cpHi: cpHi)
    let expectedBPV = (cpHi != 0) ? 7 : 5   // pos + normal 16-bit + colour0 INDEX8 (+ texcoord0 16-bit)
    check(bpv == expectedBPV,
          "\(mesh.name): descriptor \(hex(Int(cpLo)))/\(hex(Int(cpHi))) implies \(bpv) bytes/vertex, list writes \(expectedBPV)")
    check((cpLo >> 9) & 3 == 3 && (cpLo >> 11) & 3 == 3,
          "\(mesh.name): position and normal are GX_INDEX16, matching the 16-bit indices written")
    check((cpLo >> 13) & 3 == 2 && (cpLo >> 15) & 3 == 0,
          "\(mesh.name): colour0 is GX_INDEX8 and colour1 is absent, matching the 8-bit colour index written")
    check(sectionOffset(mdl0, 4) != 0, "a Colors section exists to back the colour0 attribute")
    check(dict(mdl0, at: sectionOffset(mdl0, 4)).count == groups.count,
          "the Colors section holds one shared white buffer per mesh")

    // XF 0x1008 counts the attributes the descriptor supplies, not the channels the material computes.
    let xf = mdl0.be32(o + 0x14)
    check(xf & 3 == 1, "\(mesh.name): XF vertex spec declares one colour attribute")
    check((xf >> 2) & 3 == 1, "\(mesh.name): XF vertex spec declares one normal")
    check((xf >> 4) & 0xF == (cpHi != 0 ? 1 : 0), "\(mesh.name): XF texcoord count matches the descriptor")

    let setup = walkDisplayList(mdl0, start: o + 0x18 + Int(mdl0.readInt32BE(at: o + 0x20)),
                                size: Int(mdl0.be32(o + Mesh.setupSize)), bpv: bpv)
    check(setup == 0, "\(mesh.name): setup display list decodes cleanly and draws nothing")
    let drawn = walkDisplayList(mdl0, start: o + 0x24 + Int(mdl0.readInt32BE(at: o + 0x2C)),
                                size: Int(mdl0.be32(o + Mesh.mainSize)), bpv: bpv)
    check(drawn == Int(mdl0.be32(o + 0x40)),
          "\(mesh.name): main display list decodes cleanly and draws \(mdl0.be32(o + 0x40)) vertices (got \(drawn.map(String.init) ?? "desync"))")
}

// The same walk must succeed on retail geometry, or the decoder above is the thing that is wrong.
for model in ["course_model.brres", "vrcorn_model.brres", "map_model.brres"] {
    guard let raw = retailRoot.find(path: [model])?.data,
          let mdl = try? BRRESDocument.parse(raw).resources.first(where: { $0.magic == "MDL0" })?.data
    else { continue }
    for mesh in dict(mdl, at: sectionOffset(mdl, 10)).prefix(4) {
        let o = mesh.dataOffset
        let bpv = bytesPerVertex(cpLo: mdl.be32(o + 0x0C), cpHi: mdl.be32(o + 0x10))
        let drawn = walkDisplayList(mdl, start: o + 0x24 + Int(mdl.readInt32BE(at: o + 0x2C)),
                                    size: Int(mdl.be32(o + Mesh.mainSize)), bpv: bpv)
        check(drawn == Int(mdl.be32(o + 0x40)),
              "\(model) mesh @\(hex(o)): retail list decodes at \(bpv) bytes/vertex")
    }
}

// MARK: The presence bitfield at 0x30 must agree with the vertex descriptor.
//
// Both state the same fact. When they disagree the runtime and this app's own MDL0Parser compute
// different per-vertex layouts, and the parser gives up entirely, which is what made a model
// built here preview as bare texture cards instead of geometry.

for mesh in dict(mdl0, at: sectionOffset(mdl0, 10)) {
    let o = mesh.dataOffset
    let cpLo = mdl0.be32(o + 0x0C), cpHi = mdl0.be32(o + 0x10)
    let bits = mdl0.be32(o + 0x30)
    for (statusShift, presenceBit, label) in [(UInt32(9), 9, "position"), (11, 10, "normal"),
                                              (13, 11, "colour0"), (15, 12, "colour1")] {
        let declared = (cpLo >> statusShift) & 3 != 0
        check(declared == ((bits >> UInt32(presenceBit)) & 1 == 1),
              "\(mesh.name): 0x30 \(label) bit agrees with the descriptor")
    }
    for i in 0..<8 {
        let declared = (cpHi >> UInt32(i * 2)) & 3 != 0
        check(declared == ((bits >> UInt32(13 + i)) & 1 == 1),
              "\(mesh.name): 0x30 texcoord\(i) bit agrees with the descriptor")
    }
}

// Retail states the same fact the same way, if this fails, the bit mapping above is wrong.
for model in ["course_model.brres", "vrcorn_model.brres", "map_model.brres"] {
    guard let raw = retailRoot.find(path: [model])?.data,
          let mdl = try? BRRESDocument.parse(raw).resources.first(where: { $0.magic == "MDL0" })?.data
    else { continue }
    for mesh in dict(mdl, at: sectionOffset(mdl, 10)).prefix(4) {
        let o = mesh.dataOffset
        let cpLo = mdl.be32(o + 0x0C), bits = mdl.be32(o + 0x30)
        check(((cpLo >> 9) & 3 != 0) == ((bits >> 9) & 1 == 1)
              && ((cpLo >> 11) & 3 != 0) == ((bits >> 10) & 1 == 1)
              && ((cpLo >> 13) & 3 != 0) == ((bits >> 11) & 1 == 1),
              "\(model) mesh @\(hex(o)): retail 0x30 mirrors its own descriptor")
    }
}

// MARK: Container round trip.

let doc = BRRESDocument()
doc.resources.append(BRRESResource(name: "course", folderName: "3DModels(NW4R)", data: mdl0,
                                   stringReferences: built.stringReferences))
guard let tex = TEX0View.building(name: "tex_red", rgba: [UInt8](repeating: 0xFF, count: 8 * 8 * 4),
                                  width: 8, height: 8, format: .cmpr) else {
    print("FAIL TEX0View.building returned nil"); exit(1)
}
doc.resources.append(BRRESResource(name: "tex_red", folderName: "Textures(NW4R)", data: tex))

let file = doc.serialize()
check(Int(file.be32(8)) == file.count, "BRRES header file size == actual")
check(file.be16(0x0C) == 0x10, "root offset field is 0x10")
check(Int(file.be16(0x0E)) == 1 + doc.resources.count, "section count is root + every resource")

let reparsed = try BRRESDocument.parse(file)
check(reparsed.resources.count == 2, "round trip keeps both resources (got \(reparsed.resources.count))")
guard let rt = reparsed.resources.first(where: { $0.magic == "MDL0" }) else {
    print("FAIL MDL0 missing after round trip"); exit(1)
}
check(rt.name == "course", "MDL0 keeps its name")
check(rt.data.count == mdl0.count, "MDL0 survives whole: \(rt.data.count) vs \(mdl0.count) bytes")
// The blob leaves its name offsets at zero and the container writes ofsBRRES, so what
// survives unchanged is everything the container does not fill in.
var expected = mdl0
expected.replaceSubrange(0x0C..<0x10, with: rt.data.subdata(at: 0x0C, length: 4))
for reference in built.stringReferences {
    let r = reference.fieldOffset..<(reference.fieldOffset + 4)
    expected.replaceSubrange(r, with: rt.data.subdata(at: reference.fieldOffset, length: 4))
}
check(rt.data == expected, "MDL0 bytes are unchanged apart from ofsBRRES and the name offsets")
check(built.stringReferences.allSatisfy { reference in
    let stored = Int(rt.data.readInt32BE(at: reference.fieldOffset))
    let at = rt.fileOffset + reference.anchorOffset + stored
    return at > 4 && at < file.count && file.readNullTerminatedString(at: at) == reference.text
}, "every name offset resolves to its own string in the file's pool")
check(built.stringReferences.allSatisfy { reference in
    rt.fileOffset + reference.anchorOffset + Int(rt.data.readInt32BE(at: reference.fieldOffset)) >= rt.fileOffset + rt.data.count
}, "those names live outside the resource, as they do in a retail file")
// Pool entries are length-prefixed: a retail reader takes the u32 at address-4 as the character
// count, so a name written without it would be read as whatever happened to precede it.
check(built.stringReferences.allSatisfy { reference in
    let at = rt.fileOffset + reference.anchorOffset + Int(rt.data.readInt32BE(at: reference.fieldOffset))
    return at >= 4 && Int(file.be32(at - 4)) == reference.text.utf8.count
}, "each pool entry is preceded by its own u32 length, as retail's are")
check(rt.fileOffset + Int(rt.data.readInt32BE(at: 0xC)) == 0,
      "ofsBRRES points from the MDL0 back to offset 0")
check(reparsed.resources.contains { $0.name == "tex_red" && $0.magic == "TEX0" }, "TEX0 survives")

// MARK: This app must be able to read back what it wrote.
//
// The preview falls back to a texture collage whenever MDL0Parser returns nil, so "the model
// previews as textures only" is this check failing.

if let parsed = MDL0Parser.parse(rt, rawFile: reparsed.rawData) {
    check(parsed.meshes.count == 2, "parser recovers both meshes (got \(parsed.meshes.count))")
    let totalVertices = parsed.meshes.reduce(0) { $0 + $1.vertices.count }
    check(totalVertices == 6, "parser recovers all 6 vertices (got \(totalVertices))")
    check(parsed.meshes.allSatisfy { $0.vertices.allSatisfy { $0.normal != nil } },
          "every recovered vertex has its normal")
    let textured = parsed.meshes.filter { $0.textureName == "tex_red" }
    check(textured.count == 1, "the textured mesh resolves back to tex_red")
    check(textured.first?.vertices.allSatisfy { $0.uv0 != nil } ?? false,
          "the textured mesh's vertices carry UVs, so the preview can texture it")
} else {
    print("FAIL MDL0Parser.parse returned nil, the preview would fall back to texture cards")
    failures += 1
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
