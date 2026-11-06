// .dae import check: a hand-written Blender-style COLLADA file (Z_UP, a <polylist> quad, a texture
// through <library_images>, a node translation) must convert to the OBJ Blender itself would write
// for the same mesh: positions turned Y-up (x, z, -y) with the node transform applied, UVs
// unchanged (both formats are V-up), one usemtl, and the texture copied next to the .mtl.
//
//   swiftc -parse-as-library -o /tmp/daecheck "Revolution IDE/Core/Formats/DAEImporter.swift" \
//     "Revolution IDE/Core/Formats/OBJImporter.swift" "Revolution IDE/Core/Formats/MathTypes.swift" \
//     "Revolution IDE/Core/BinaryIO.swift" Tests/DAEImportCheck/main.swift && /tmp/daecheck

import AppKit

@main enum DAEImportCheck {
    static let dae = """
    <?xml version="1.0" encoding="utf-8"?>
    <COLLADA xmlns="http://www.collada.org/2005/11/COLLADASchema" version="1.4.1">
      <asset><unit name="meter" meter="1"/><up_axis>Z_UP</up_axis></asset>
      <library_images><image id="road_png" name="road_png"><init_from>road.png</init_from></image></library_images>
      <library_effects><effect id="Road-effect"><profile_COMMON>
        <newparam sid="road_png-surface"><surface type="2D"><init_from>road_png</init_from></surface></newparam>
        <newparam sid="road_png-sampler"><sampler2D><source>road_png-surface</source></sampler2D></newparam>
        <technique sid="common"><lambert><diffuse><texture texture="road_png-sampler" texcoord="UVMap"/></diffuse></lambert></technique>
      </profile_COMMON></effect></library_effects>
      <library_materials><material id="Road-material" name="Road"><instance_effect url="#Road-effect"/></material></library_materials>
      <library_geometries><geometry id="Plane-mesh" name="Plane"><mesh>
        <source id="Plane-mesh-positions"><float_array id="Plane-mesh-positions-array" count="12">0 0 0 100 0 0 100 200 0 0 200 50</float_array>
          <technique_common><accessor source="#Plane-mesh-positions-array" count="4" stride="3"><param name="X" type="float"/><param name="Y" type="float"/><param name="Z" type="float"/></accessor></technique_common></source>
        <source id="Plane-mesh-map-0"><float_array id="Plane-mesh-map-0-array" count="8">0 0 1 0 1 0.25 0 0.25</float_array>
          <technique_common><accessor source="#Plane-mesh-map-0-array" count="4" stride="2"><param name="S" type="float"/><param name="T" type="float"/></accessor></technique_common></source>
        <vertices id="Plane-mesh-vertices"><input semantic="POSITION" source="#Plane-mesh-positions"/></vertices>
        <polylist material="Road-material" count="1">
          <input semantic="VERTEX" source="#Plane-mesh-vertices" offset="0"/>
          <input semantic="TEXCOORD" source="#Plane-mesh-map-0" offset="1" set="0"/>
          <vcount>4 </vcount><p>0 0 1 1 2 2 3 3</p>
        </polylist>
      </mesh></geometry></library_geometries>
      <library_visual_scenes><visual_scene id="Scene" name="Scene">
        <node id="Plane" name="Plane" type="NODE"><matrix sid="transform">1 0 0 10 0 1 0 0 0 0 1 0 0 0 0 1</matrix>
          <instance_geometry url="#Plane-mesh" name="Plane"><bind_material><technique_common>
            <instance_material symbol="Road-material" target="#Road-material"><bind_vertex_input semantic="UVMap" input_semantic="TEXCOORD" input_set="0"/></instance_material>
          </technique_common></bind_material></instance_geometry></node>
      </visual_scene></library_visual_scenes>
      <scene><instance_visual_scene url="#Scene"/></scene>
    </COLLADA>
    """

    static func main() throws {
        // Any .dae paths given are converted too, as a smoke test on real exporter output.
        for path in CommandLine.arguments.dropFirst() {
            do {
                let (text, url) = try ModelFile.objSource(URL(fileURLWithPath: path))
                print("ok  ", URL(fileURLWithPath: path).lastPathComponent, OBJImporter.parse(text).count, "triangles,", OBJImporter.loadMTLMaterials(objText: text, objURL: url).count, "materials")
            } catch { print("FAIL", path, error) }
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("daecheck-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try dae.write(to: dir.appendingPathComponent("track.dae"), atomically: true, encoding: .utf8)
        let image = NSImage(size: NSSize(width: 4, height: 4)); image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); image.unlockFocus()
        try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("road.png"))

        let (text, objURL) = try ModelFile.objSource(dir.appendingPathComponent("track.dae"))
        let tris = OBJImporter.parse(text)
        let mtl = OBJImporter.loadMTLMaterials(objText: text, objURL: objURL)
        var failures = 0
        func check(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failures += 1 } }
        func near(_ a: Vec3, _ b: (Float, Float, Float)) -> Bool { abs(a.x - b.0) < 1e-3 && abs(a.y - b.1) < 1e-3 && abs(a.z - b.2) < 1e-3 }

        check(tris.count == 2, "quad -> 2 triangles (got \(tris.count))")
        let corners = tris.flatMap { [($0.v0, $0.uv0), ($0.v1, $0.uv1), ($0.v2, $0.uv2)] }
        // Z-up (x, y, z) + node translation x+10  ->  Y-up (x + 10, z, -y).
        let expected: [((Float, Float, Float), (Float, Float))] = [((10, 0, 0), (0, 0)), ((110, 0, 0), (1, 0)), ((110, 0, -200), (1, 0.25)), ((10, 50, -200), (0, 0.25))]
        for (p, uv) in expected {
            let hit = corners.first { near($0.0, p) }
            check(hit != nil, "vertex \(p) present (Y-up, transformed)")
            if let uv0 = hit?.1 { check(abs(uv0.x - uv.0) < 1e-4 && abs(uv0.y - uv.1) < 1e-4, "vertex \(p) UV \(uv) (got \(uv0.x), \(uv0.y))") }
        }
        check(tris.allSatisfy { $0.materialName == "Road" }, "material name Road (got \(Set(tris.compactMap(\.materialName))))")
        let tex = mtl["Road"]?.diffuseTexturePath
        check(tex != nil && FileManager.default.fileExists(atPath: objURL.deletingLastPathComponent().appendingPathComponent(tex!).path), "texture copied beside the .mtl (\(tex ?? "none"))")
        if failures > 0 { exit(1) }
    }
}
