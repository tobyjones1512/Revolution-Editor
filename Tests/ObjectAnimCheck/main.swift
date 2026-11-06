// Object animation check: every retail object BRRES with a CHR0 (bone) or SRT0 (texture) animation
// in a few courses and Common.szs parses into plausible values (finite, every animated bone exists
// in the model), and an offscreen render of an animated object at two times differs, the
// preview's objects really move. Writes the frames for a look.
//
//   $CLAUDE_JOB_DIR/tmp/runtest.sh ObjectAnimCheck. [out-dir]

import AppKit
import SceneKit

@main enum ObjectAnimCheck {
    @MainActor static func main() throws {
        let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
        let roms = "\(ProcessInfo.processInfo.environment["ROMS_DIR"] ?? "Roms")/"
        let disc = try WiiDisc(url: URL(fileURLWithPath: roms + "Wii/MKWii/Mario Kart Wii (USA) (En,Fr,Es).iso"),
                               commonKey: [UInt8](try Data(contentsOf: URL(fileURLWithPath: roms + "Wii/Keys/common-key"))), koreanKey: nil)
        var nodes: [String: DiscNode] = [:]
        func walk(_ n: DiscNode) { if n.isDirectory { n.children.forEach(walk) } else { nodes[n.name] = n } }
        walk(disc.root)
        var failures = 0
        func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL", what); failures += 1 } }

        var animated: [(String, BRRESDocument, MDL0Model)] = []
        var chrCount = 0, srtCount = 0, boneCount = 0
        for archive in ["Common.szs", "beginner_course.szs", "farm_course.szs", "castle_course.szs", "ridgehighway_course.szs", "shopping_course.szs"] {
            guard let node = nodes[archive] else { check(false, "no \(archive)"); continue }
            let (root, _) = try SZS.open(try disc.readFile(node: node))
            func visit(_ n: U8Node) {
                for c in n.children {
                    if c.isDirectory { visit(c); continue }
                    guard c.name.hasSuffix(".brres"), let data = c.data, let doc = try? BRRESDocument.parse(data) else { continue }
                    let stem = String(c.name.dropLast(6))
                    guard let mdl = doc.resources.first(where: { $0.magic == "MDL0" && $0.name == stem }) ?? doc.resources.first(where: { $0.magic == "MDL0" }),
                          let model = MDL0Parser.parse(mdl, rawFile: doc.rawData) else { continue }
                    var any = false
                    for r in doc.resources where r.magic == "CHR0" {
                        guard let a = CHR0Animation.parse(r, rawFile: doc.rawData) else { check(false, "\(archive)/\(c.name) \(r.name): CHR0 not parsed"); continue }
                        chrCount += 1; any = true
                        for node in a.nodes {
                            boneCount += 1
                            check(model.bones.contains { $0.name == node.name } || doc.resources.filter { $0.magic == "MDL0" }.count > 1,
                                  "\(c.name) \(r.name): bone \(node.name) not in \(model.name)")
                            for v in node.values.compactMap({ $0 }) {
                                for f in stride(from: Float(0), through: Float(a.frameCount), by: 0.5) {
                                    let x = CHR0Animation.sample(v, at: f)
                                    if !x.isFinite || abs(x) > 1e6 { check(false, "\(c.name) \(r.name) \(node.name): value \(x) at \(f)"); break }
                                }
                            }
                        }
                    }
                    for r in doc.resources where r.magic == "SRT0" {
                        guard SRT0Document.parse(r, rawFile: doc.rawData) != nil else { check(false, "\(c.name) \(r.name): SRT0 not parsed"); continue }
                        srtCount += 1; any = true
                    }
                    if any { animated.append((c.name, doc, model)) }
                }
            }
            visit(root)
        }
        print("\(animated.count) animated object files, \(chrCount) CHR0 (\(boneCount) bone tracks), \(srtCount) SRT0")
        check(chrCount > 10 && srtCount > 5, "found plenty of animations")

        // Render a few animated ones at two times.
        var moving = 0
        for (file, doc, model) in animated.filter { ProcessInfo.processInfo.environment["ONLY"].map($0.0.hasPrefix) ?? true }.prefix(40) {
            let scene = SCNScene()
            // Cloned, as the preview places each object.
            let obj = MDL0SceneKit.node(for: model, textures: MDL0SceneKit.textureImages(in: doc), animations: ProcessInfo.processInfo.environment["NOANIM"] == nil ? doc : nil).clone()
            // Placed like a KMP object: moved and turned.
            let placed = SCNNode()
            placed.position = SCNVector3(5000, 200, -3000); placed.eulerAngles = SCNVector3(0, CGFloat.pi / 2, 0)
            placed.addChildNode(obj)
            scene.rootNode.addChildNode(placed)
            var (lo, hi) = obj.boundingBox
            lo = obj.convertPosition(lo, to: nil); hi = obj.convertPosition(hi, to: nil)
            (lo, hi) = (SCNVector3(min(lo.x, hi.x), min(lo.y, hi.y), min(lo.z, hi.z)), SCNVector3(max(lo.x, hi.x), max(lo.y, hi.y), max(lo.z, hi.z)))
            let size = max(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z, 1)
            let cam = SCNNode(); cam.camera = SCNCamera(); cam.camera!.zFar = Double(size) * 20; cam.camera!.zNear = Double(size) / 1000
            let mid = SCNVector3((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2)
            cam.position = SCNVector3(mid.x + size * 0.9, mid.y + size * 0.6, mid.z + size * 1.4); cam.look(at: mid)
            scene.rootNode.addChildNode(cam)
            let light = SCNNode(); light.light = SCNLight(); light.light!.type = .ambient; light.light!.intensity = 1000; scene.rootNode.addChildNode(light)
            let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
            renderer.scene = scene; renderer.pointOfView = cam
            var shots: [Data] = []
            for t in [0.0, 0.75] {
                let img = renderer.snapshot(atTime: t, with: CGSize(width: 256, height: 256), antialiasingMode: .none)
                guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { continue }
                try png.write(to: out.appendingPathComponent("anim-\(file)-\(t).png"))
                shots.append(rep.bitmapData.map { Data(bytes: $0, count: rep.bytesPerPlane) } ?? Data())
            }
            if shots.count == 2, shots[0] != shots[1] { moving += 1 } else { print("still:", file) }
        }
        print("\(moving) of \(min(40, animated.count)) rendered objects move between t=0 and t=0.75s")
        check(moving > 0, "objects animate")
        print("frames written to", out.path)
        if failures > 0 { print(failures, "failures"); exit(1) } else { print("ok") }
    }
}
