// Double Dash minimap check: for every retail race course, the slot's minimap rectangle and
// orientation are read from the disc's own main.dol, the course's collision is drawn into them
// with `MKDDMinimap`, and the result must line up with Nintendo's own `_map.bti`, the map's
// visible pixels and ours overlap (intersection over union) far better than any wrong
// orientation would (a symmetric track may tie with its opposite).
//
//   find "Revolution IDE/Core" -name '*.swift' ! -path '*/Workbench/*' ! -name AppState.swift \
//     ! -name SyntaxHighlighter.swift | tr '\n' '\0' | xargs -0 swiftc -O -parse-as-library -o /tmp/mapcheck \
//     "Revolution IDE/Core/Workbench/BaseGameLibrary.swift" Tests/MKDDMinimapCheck/main.swift
//   /tmp/mapcheck [mkdd.iso] [out-dir]

import AppKit

@main enum MKDDMinimapCheck {
    static func main() throws {
        let args = CommandLine.arguments
        let url = URL(fileURLWithPath: args.count > 1 ? args[1] : "\(ProcessInfo.processInfo.environment["ROMS_DIR"] ?? "Roms")/GCN/MKDD/Mario Kart - Double Dash!! (USA).iso")
        let disc = try GameCubeDisc(url: url)
        let dol = try MKDDSlots.dol(fromDisc: url)
        let region = MKDDSlots.region(gameID: disc.gameID)!
        var nodes: [String: DiscNode] = [:]
        func f(_ n: DiscNode) { if n.isDirectory { n.children.forEach(f) } else { nodes[n.name] = n } }
        f(disc.root)
        var failures = 0
        // Mushroom City's retail _map.bti is a placeholder (Japanese text, "Patapata course map").
        for slot in MKDDSlots.slots where !slot.battle && slot.archive != "Patapata" {
            let (root, _) = try SZS.open(try disc.readFile(node: nodes[slot.archive + ".arc"]!))
            let bco = try BCO.parse(root.children.first { $0.name.hasSuffix("_course.bco") }!.data!)
            let mapData = root.children.first { $0.name.hasSuffix("_map.bti") }!.data!
            let w = Int(mapData.be16(2)), h = Int(mapData.be16(4))
            guard let fmt = GXTextureFormat(rawValue: UInt32(mapData.u8(0))), let retail = TextureCodec.decode(data: mapData, offset: Int(mapData.be32(0x1C)), width: w, height: h, format: fmt),
                  let m = MKDDSlots.minimap(for: slot, dol: dol, region: region) else { print("FAIL \(slot.title): unreadable"); failures += 1; continue }
            let tris = bco.triangles.filter { MKDDMinimap.onMap(bcoFlag: $0.attribute) }.map { ($0.v0, $0.v1, $0.v2) }
            // Compare at our size; retail maps are 128x256 except Mushroom City's.
            func iou(_ orientation: Int) -> Double {
                var mm = m; mm.orientation = orientation
                let ours = MKDDMinimap.render(triangles: tris, minimap: mm, outline: 0)
                var inter = 0, union = 0
                for y in 0..<MKDDMinimap.height { for x in 0..<MKDDMinimap.width {
                    let rx = x * w / MKDDMinimap.width, ry = y * h / MKDDMinimap.height
                    // I4/I8 maps have no alpha: their intensity is the shape.
                    let channel = fmt == .i4 || fmt == .i8 ? 0 : 3
                    let a = retail[(ry * w + rx) * 4 + channel] > 0x40, b = ours[(y * MKDDMinimap.width + x) * 4 + 3] > 0
                    if a && b { inter += 1 }; if a || b { union += 1 }
                } }
                return union == 0 ? 0 : Double(inter) / Double(union)
            }
            let scores = (0..<4).map(iou)
            let best = scores.indices.max { scores[$0] < scores[$1] }!
            // A symmetric track (Baby Park's oval) ties between opposite orientations.
            let ok = scores[m.orientation] >= scores[best] - 0.01 && scores[m.orientation] > 0.4
            if !ok { failures += 1 }
            print(ok ? "ok  " : "FAIL", slot.title, "orientation \(m.orientation)", "IoU by orientation", scores.map { String(format: "%.2f", $0) }.joined(separator: " "))
            if args.count > 2 {
                let img = ImageUtil.nsImage(fromRGBA: MKDDMinimap.render(triangles: tris, minimap: m), width: 128, height: 256)!
                try NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]).appendingPathComponent("\(slot.archive)-ours.png"))
                let r = ImageUtil.nsImage(fromRGBA: retail, width: w, height: h)!
                try NSBitmapImageRep(data: r.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]).appendingPathComponent("\(slot.archive)-retail.png"))
            }
        }
        if failures > 0 { exit(1) }
    }
}
