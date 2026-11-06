// Create Render check: builds a retail course's textured scene (course model + skybox) the way
// the 3D preview does, applies a render preset through `TrackRender`, renders it offscreen and
// requires a real picture back, the requested size, not blank, with sky and lit ground, and
// the sky staying behind the track even from outside its dome, and that switching back to the editor look turns HDR/shadows off again. Writes the PNGs so they can
// be looked at.
//
//   find "Revolution IDE/Core" -name '*.swift' ! -path '*/Workbench/*' ! -name AppState.swift \
//     ! -name SyntaxHighlighter.swift | tr '\n' '\0' | xargs -0 swiftc -O -parse-as-library -o /tmp/rendercheck \
//     "Revolution IDE/Core/Workbench/BaseGameLibrary.swift" "Revolution IDE/Views/Workbench/TrackRenderPanel.swift" \
//     Tests/TrackRenderCheck/main.swift
//   /tmp/rendercheck [out-dir] [mkwii.iso] [common-key]

import AppKit
import SceneKit

@main enum TrackRenderCheck {
    @MainActor static func main() throws {
        let args = CommandLine.arguments
        let out = URL(fileURLWithPath: args.count > 1 ? args[1] : NSTemporaryDirectory())
        let roms = "\(ProcessInfo.processInfo.environment["ROMS_DIR"] ?? "Roms")/"
        let iso = args.count > 2 ? args[2] : roms + "Wii/MKWii/Mario Kart Wii (USA) (En,Fr,Es).iso"
        let key = args.count > 3 ? args[3] : roms + "Wii/Keys/common-key"
        let disc = try WiiDisc(url: URL(fileURLWithPath: iso), commonKey: [UInt8](try Data(contentsOf: URL(fileURLWithPath: key))), koreanKey: nil)
        var nodes: [String: DiscNode] = [:]
        func walk(_ n: DiscNode) { if n.isDirectory { n.children.forEach(walk) } else { nodes[n.name] = n } }
        walk(disc.root)
        var failures = 0
        func check(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failures += 1 } }
        // Moo Moo Meadows (lightmapped grass, small sky dome) and Luigi Circuit.
        for courseName in ["farm_course", "beginner_course"] {
        let (root, _) = try SZS.open(try disc.readFile(node: nodes[courseName + ".szs"]!))

        let scene = SCNScene()
        func model(_ file: String, _ name: String) -> MDL0Model? {
            guard let data = root.children.first(where: { $0.name == file })?.data, let doc = try? BRRESDocument.parse(data),
                  let r = doc.resources.first(where: { $0.magic == "MDL0" && $0.name == name }), let m = MDL0Parser.parse(r, rawFile: doc.rawData) else { return nil }
            scene.rootNode.addChildNode(MDL0SceneKit.node(for: m, textures: MDL0SceneKit.textureImages(in: doc)))
            return m
        }
        let course = model("course_model.brres", "course")!
        // The skybox in its own layer node, as the preview keeps it.
        let skyLayer = SCNNode()
        if let data = root.children.first(where: { $0.name == "vrcorn_model.brres" })?.data, let doc = try? BRRESDocument.parse(data),
           let r = doc.resources.first(where: { $0.magic == "MDL0" && $0.name == "vrcorn" }), let m = MDL0Parser.parse(r, rawFile: doc.rawData) {
            skyLayer.addChildNode(MDL0SceneKit.node(for: m, textures: MDL0SceneKit.textureImages(in: doc)))
        }
        scene.rootNode.addChildNode(skyLayer)
        let extent = max(course.boundsMax.x - course.boundsMin.x, course.boundsMax.z - course.boundsMin.z)
        // The preview's own camera + lights (frameCamera), named as Create Render expects. The
        // camera is deliberately outside Moo Moo Meadows' small sky dome: an aerial overview.
        let camNode = SCNNode(); camNode.camera = SCNCamera(); camNode.camera!.zFar = Double(extent) * 6; camNode.camera!.zNear = Double(extent) / 20000
        let center = SCNVector3((course.boundsMin.x + course.boundsMax.x) / 2, course.boundsMin.y, (course.boundsMin.z + course.boundsMax.z) / 2)
        camNode.position = SCNVector3(center.x, center.y + CGFloat(extent) * 0.35, center.z + CGFloat(extent) * 0.6)
        camNode.look(at: center)
        scene.rootNode.addChildNode(camNode)
        for (name, type) in [("sun", SCNLight.LightType.directional), ("ambient", .ambient)] {
            let n = SCNNode(); n.name = name; n.light = SCNLight(); n.light!.type = type; scene.rootNode.addChildNode(n)
        }

        for (preset_name, preset) in RenderSettings.presets {
            TrackRender.apply(preset, to: scene, extent: extent, sky: skyLayer)
            guard let image = TrackRender.render(scene: scene, width: 800, height: 450, supersample: true, guideFraction: 1),
                  let png = TrackRender.pngData(image), let rep = NSBitmapImageRep(data: png) else { check(false, "\(courseName) \(preset_name): no image"); continue }
            try png.write(to: out.appendingPathComponent("render-\(courseName)-\(preset_name).png"))
            check(rep.pixelsWide == 800 && rep.pixelsHigh == 450, "\(courseName) \(preset_name): 800x450 (got \(rep.pixelsWide)x\(rep.pixelsHigh))")
            // Distinct colours in a grid sample: a blank or flat frame has a handful at most.
            var colours = Set<UInt32>(), bright = 0
            for y in stride(from: 0, to: 450, by: 9) {
                for x in stride(from: 0, to: 800, by: 9) {
                    let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                    let r = UInt32(c.redComponent * 31), g = UInt32(c.greenComponent * 31), b = UInt32(c.blueComponent * 31)
                    colours.insert(r << 10 | g << 5 | b)
                    if c.brightnessComponent > 0.15 { bright += 1 }
                }
            }
            check(colours.count > 50, "\(courseName) \(preset_name): detailed picture (\(colours.count) distinct colours sampled)")
            check(bright > 1000, "\(courseName) \(preset_name): lit, not black (\(bright) bright samples)")
        }
        TrackRender.apply(nil, to: scene, extent: extent, sky: skyLayer)
        check(camNode.camera?.wantsHDR == false && scene.rootNode.childNode(withName: "sun", recursively: false)?.light?.castsShadow == false
              && scene.rootNode.childNode(withName: "fill", recursively: false) == nil && skyLayer.constraints?.isEmpty != false,
              "\(courseName): editor look restored (no HDR, shadows, fill light or sky-follow)")
        }
        print("renders written to", out.path)
        if failures > 0 { exit(1) }
    }
}
