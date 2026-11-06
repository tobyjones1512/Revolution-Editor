// End-to-end check over the Mario Kart Wii sample course in
//   On-Device Documents > Roms > Wii > MKWii > Test > Examples
// (a retail Luigi Circuit course_model.brres, course.kmp and course.kcl, as loose files).
//
// Covers the real-file Create Map path, keeping only the road, as someone building a minimap
// would, and then holds the generated model to the same render invariants MDL0WriterCheck
// applies to the writer, so a map model is checked as a thing the game has to draw and not just
// as a file that parses.
//
//   swiftc -O -o /tmp/examplescheck \
//     "Revolution IDE/Core/BinaryIO.swift" \
//     "Revolution IDE/Core/Formats/"{Yaz0,U8Archive,SZS,BRRES,BRRESIndexGroup,BRRESTypes,TextureCodec,MathTypes,MDL0,OBJImporter,MDL0Writer,MapModelBuilder,KMP,KCL}.swift \
//     Tests/ExamplesCheck/main.swift
//   /tmp/examplescheck "/path/to/Test/Examples"

import Foundation
var failures = 0
func check(_ c: Bool, _ m: String) { if c { print("ok   \(m)") } else { print("FAIL \(m)"); failures += 1 } }
func hex(_ v: Int) -> String { "0x" + String(v, radix: 16) }

let dir = URL(fileURLWithPath: CommandLine.arguments[1])

// ---------- The other two Examples files, whose menu items moved into the MKWii submenu ----------
let kmp = try KMPDocument.parse(try Data(contentsOf: dir.appendingPathComponent("course.kmp")))
check(!kmp.ktpt.isEmpty, "course.kmp parses with \(kmp.ktpt.count) start position(s)")
check(!kmp.enpt.isEmpty, "course.kmp has \(kmp.enpt.count) enemy route point(s)")
check(!kmp.ckpt.isEmpty, "course.kmp has \(kmp.ckpt.count) checkpoint(s)")
let kcl = try KCLDocument.parse(try Data(contentsOf: dir.appendingPathComponent("course.kcl")))
check(kcl.triangles.count > 1000, "course.kcl parses with \(kcl.triangles.count) collision triangles")

// ---------- Create Map, the way someone actually uses it: keep the road, drop the scenery ----------
let course = try Data(contentsOf: dir.appendingPathComponent("course_model.brres"))
guard let options = MapModelBuilder.options(inBRRES: course) else { print("FAIL no options"); exit(1) }
guard let road = options.first(where: { $0.textureName == "mainROAD_all_mip" }) else {
    print("FAIL no road texture in the list"); exit(1)
}
let map = try MapModelBuilder.build(fromBRRES: course, keeping: [road.id], modelName: "map")
// Only a size *direction* is asserted, not a ratio: MDL0Writer emits unindexed geometry (one
// stored position per display-list vertex) where retail shares vertices between triangles, so
// the exact ratio reflects that difference rather than anything this feature guarantees.
check(map.count < course.count,
      "map is smaller than the course it came from: \(map.count) vs \(course.count) bytes "
      + "(1/\(course.count / max(map.count, 1)))")

let doc = try BRRESDocument.parse(map)
check(Int(map.be32(8)) == map.count, "map BRRES header file size == actual")
check(Int(map.be16(0x0E)) == 1 + doc.resources.count, "map BRRES section count is root + resources")
guard let res = doc.resources.first(where: { $0.magic == "MDL0" }),
      let model = MDL0Parser.parse(res, rawFile: doc.rawData) else {
    print("FAIL generated map model is not parseable"); exit(1)
}
let tris = model.meshes.reduce(0) { $0 + $1.vertices.count / 3 }
check(tris == road.triangleCount, "map holds exactly the road's \(road.triangleCount) triangles (got \(tris))")
// Retail's own map_model.brres carries no texture at all (nTex=0, no UVs, no TEX0), just an
// untextured material with a flat colour. Match that rather than shipping a white TEX0.
check(model.meshes.allSatisfy { $0.textureName == nil }, "road mesh is untextured, matching retail")
check(!doc.resources.contains { $0.magic == "TEX0" }, "no TEX0 resource, matching retail")

// The road's own shape must survive: compare bounds against the source mesh it came from.
guard let srcDoc = try? BRRESDocument.parse(course),
      let srcRes = srcDoc.resources.first(where: { $0.magic == "MDL0" }),
      let srcModel = MDL0Parser.parse(srcRes, rawFile: srcDoc.rawData),
      let srcRoad = srcModel.meshes.first(where: { $0.textureName == "mainROAD_all_mip" }) else {
    print("FAIL could not re-read the source road mesh"); exit(1)
}
func bounds(_ verts: [Vec3]) -> (Vec3, Vec3) {
    var lo = Vec3(x: .infinity, y: .infinity, z: .infinity), hi = Vec3(x: -.infinity, y: -.infinity, z: -.infinity)
    for v in verts {
        lo = Vec3(x: min(lo.x, v.x), y: min(lo.y, v.y), z: min(lo.z, v.z))
        hi = Vec3(x: max(hi.x, v.x), y: max(hi.y, v.y), z: max(hi.z, v.z))
    }
    return (lo, hi)
}
let (sLo, sHi) = bounds(srcRoad.vertices.map(\.position))
let (mLo, mHi) = bounds(model.meshes.flatMap { $0.vertices.map(\.position) })
let close = abs(sLo.x - mLo.x) < 0.01 && abs(sLo.y - mLo.y) < 0.01 && abs(sLo.z - mLo.z) < 0.01
         && abs(sHi.x - mHi.x) < 0.01 && abs(sHi.y - mHi.y) < 0.01 && abs(sHi.z - mHi.z) < 0.01
check(close, "map geometry occupies the same space as the source road: \(sLo)..\(sHi) vs \(mLo)..\(mHi)")

// ---------- The generated map must satisfy every render invariant the writer is held to ----------
func indexWidth(_ s: UInt32) -> Int { s == 2 ? 1 : (s == 3 ? 2 : 0) }
func bytesPerVertex(cpLo: UInt32, cpHi: UInt32) -> Int {
    var n = Int(cpLo & 1)
    for i in 0..<8 { n += Int((cpLo >> (1 + UInt32(i))) & 1) }
    for s in [UInt32(9), 11, 13, 15] { n += indexWidth((cpLo >> s) & 3) }
    for i in 0..<8 { n += indexWidth((cpHi >> (UInt32(i) * 2)) & 3) }
    return n
}
func walk(_ d: Data, start: Int, size: Int, bpv: Int) -> Int? {
    var p = start, drawn = 0; let end = start + size
    while p < end {
        switch d.u8(p) {
        case 0: p += 1
        case 0x08: p += 6
        case 0x10: p += 5 + (Int(d.be16(p + 1)) + 1) * 4
        case 0x61: p += 5
        case let op where op >= 0x80 && op <= 0xB8:
            let c = Int(d.be16(p + 1)); drawn += c; p += 3 + c * bpv
        default: return nil
        }
    }
    return p == end ? drawn : nil
}
let m = res.data
check(Int(m.be32(4)) == m.count, "map MDL0 declared size == actual")
let meshOfs = Int(m.readInt32BE(at: 0x10 + 10 * 4))
let meshes = BRRESIndexGroup.parse(m, groupStart: meshOfs, names: (doc.rawData, res.fileOffset))
check(!meshes.isEmpty, "map MDL0 has meshes")
for mesh in meshes {
    let o = mesh.dataOffset
    let cpLo = m.be32(o + 0x0C), cpHi = m.be32(o + 0x10)
    let bpv = bytesPerVertex(cpLo: cpLo, cpHi: cpHi)
    check(m.be32(o + 0x18) == 0xE0 && m.be32(o + 0x1C) == 0x80, "\(mesh.name): setup DL descriptor 0xE0/0x80")
    check(m.be32(o + 0x24) == m.be32(o + 0x28), "\(mesh.name): main DL size == size2")
    check(m.be32(o + 0x34) == 0, "\(mesh.name): field 0x34 is zero")
    let bits = m.be32(o + 0x30)
    check(((cpLo >> 9) & 3 != 0) == ((bits >> 9) & 1 == 1)
          && ((cpLo >> 11) & 3 != 0) == ((bits >> 10) & 1 == 1)
          && ((cpLo >> 13) & 3 != 0) == ((bits >> 11) & 1 == 1)
          && ((cpHi & 3) != 0) == ((bits >> 13) & 1 == 1),
          "\(mesh.name): 0x30 presence bits mirror the vertex descriptor")
    let drawn = walk(m, start: o + 0x24 + Int(m.readInt32BE(at: o + 0x2C)), size: Int(m.be32(o + 0x24)), bpv: bpv)
    check(drawn == Int(m.be32(o + 0x40)),
          "\(mesh.name): display list decodes cleanly, draws \(m.be32(o + 0x40)) vertices (got \(drawn.map(String.init) ?? "desync"))")
}
check(BRRESIndexGroup.parse(m, groupStart: Int(m.readInt32BE(at: 0x10)), names: (doc.rawData, res.fileOffset)).map(\.name) == ["NodeTree", "DrawOpa"],
      "map MDL0 has exactly the two retail map render-tree lists (NodeTree, DrawOpa)")
check(m.readInt32BE(at: 0x10 + 3 * 4) == 0, "map MDL0 declares no Normals section, matching retail")
for mesh in meshes {
    let o = mesh.dataOffset
    let noNormals = m.be16(o + 0x4A) == 0xFFFF
        && m.be32(o + 0x0C) == ((3 << 9) | (2 << 13))
        && m.be32(o + 0x30) == (1 << 9) | (1 << 11)
    check(noNormals, "\(mesh.name): descriptor is pos INDEX16 + colour0 INDEX8 only (3 bytes/vertex, no normal)")
}

// ---------- It must survive being packed into a course archive and read back ----------
let root = U8Node(name: "archive", isDirectory: true)
let entry = U8Node(name: "map_model.brres", isDirectory: false, data: map)
entry.parent = root
root.children.append(entry)
let szs = SZS.save(root: root, compressed: true)
let (reopened, wasCompressed) = try SZS.open(szs)
check(wasCompressed, "packs as a Yaz0-compressed .szs")
guard let back = reopened.find(path: ["map_model.brres"])?.data else { print("FAIL entry lost"); exit(1) }
check(back == map, "map_model.brres survives the archive round trip byte-for-byte")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
