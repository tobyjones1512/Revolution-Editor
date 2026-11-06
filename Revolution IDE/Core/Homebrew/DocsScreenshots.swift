#if DEBUG
import SwiftUI
import AppKit

/// Developer tool (Debug builds only): `Revolution IDE --render-docs-screenshots <folder>` renders the
/// homebrew editors for the website's documentation, using the real views with demo content. It runs
/// before any window is created and everything is drawn in off-screen windows, so nothing appears on
/// the display and no app is brought to the front.
enum DocsScreenshots {
    static func runIfRequested() {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--render-docs-screenshots"), i + 1 < a.count else { return }
        MainActor.assumeIsolated {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            NSApp.appearance = NSAppearance(named: .aqua)   // light colours everywhere, whatever the Mac is set to
            do { try render(into: URL(fileURLWithPath: a[i + 1], isDirectory: true)) }
            catch { print("error: \(error)"); exit(1) }
            exit(0)
        }
    }

    @MainActor private static func spin(_ seconds: Double) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    /// Draws `view` in an off-screen window (no title bar unless `chrome`), waits for SwiftUI to
    /// lay out and load, and writes a PNG at 2x.
    @MainActor private static func shoot<V: View>(_ view: V, size: CGSize, name: String, to dir: URL, chrome: Bool = false, wait: Double = 1.2) {
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: chrome ? [.titled, .closable, .resizable, .fullSizeContentView] : [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentViewController = controller
        window.setContentSize(size)
        // Fully transparent and click-through, at the back: invisible, but "on screen" so that lazy
        // lists and text views (which skip drawing in occluded windows) fill in.
        window.setFrameOrigin(CGPoint(x: 0, y: 0))
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderBack(nil)
        spin(wait)
        guard let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        spin(0.8)
        content.layoutSubtreeIfNeeded()
        let target: NSView = chrome ? (content.superview ?? content) : content
        target.wantsLayer = true
        // Render the layer tree (TextKit 2 text and table rows live in layers, which cacheDisplay misses).
        let scale = 2.0
        let pw = Int(target.bounds.width * scale), ph = Int(target.bounds.height * scale)
        guard let layer = target.layer,
              let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return }
        ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
        ctx.translateBy(x: 0, y: CGFloat(ph))   // layers render upside down here
        ctx.scaleBy(x: scale, y: -scale)
        layer.render(in: ctx)
        guard let cg = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("\(name).png"))
            print("wrote \(name).png (\(pw)x\(ph))")
        }
        window.orderOut(nil)
        window.close()
    }

    /// A made-up oval track (no game assets) opened in the course-data editor.
    @MainActor private static func renderMKWii(into dir: URL) {
        let doc = KMPDocument()
        let n = 28, a: Float = 3700, b: Float = 2100, half: Float = 460
        func centre(_ i: Int) -> (x: Float, z: Float, dx: Float, dz: Float) {
            let t = Float(i) / Float(n) * 2 * .pi
            let tx = -a * sin(t), tz = b * cos(t), len = (tx * tx + tz * tz).squareRoot()
            return (a * cos(t), b * sin(t), tx / len, tz / len)
        }
        for i in 0..<n {
            let c = centre(i)
            doc.enpt.append(ENPTEntry(position: Vec3(x: c.x, y: 0, z: c.z), radius: 300))
            doc.ckpt.append(CKPTEntry(left: Vec2(x: c.x + c.dz * half * 1.3, y: c.z - c.dx * half * 1.3), right: Vec2(x: c.x - c.dz * half * 1.3, y: c.z + c.dx * half * 1.3),
                                      respawnIndex: UInt8(i * 4 / n), lapCounterType: i == 0 ? 0 : (i == n / 2 ? 1 : -1)))
        }
        for i in stride(from: 0, to: n, by: 2) {
            let c = centre(i)
            doc.itpt.append(ITPTEntry(position: Vec3(x: c.x, y: 0, z: c.z), radius: 260))
        }
        var enph = PathLinkEntry(); enph.startIndex = 0; enph.pointCount = UInt8(n); enph.previousGroups[0] = 0; enph.nextGroups[0] = 0
        doc.enph = [enph]
        var ckph = PathLinkEntry(); ckph.startIndex = 0; ckph.pointCount = UInt8(n); ckph.previousGroups[0] = 0; ckph.nextGroups[0] = 0
        doc.ckph = [ckph]
        var itph = PathLinkEntry(); itph.startIndex = 0; itph.pointCount = UInt8(doc.itpt.count); itph.previousGroups[0] = 0; itph.nextGroups[0] = 0
        doc.itph = [itph]
        let s = centre(0)
        doc.ktpt = [KTPTEntry(position: Vec3(x: s.x - 250, y: 10, z: s.z - 120), rotation: Vec3(x: 0, y: 0, z: 0), playerIndex: -1)]
        for k in 0..<4 { let c = centre(k * n / 4); doc.jgpt.append(JGPTEntry(position: Vec3(x: c.x, y: 50, z: c.z), rotation: Vec3(), respawnID: UInt16(k))) }
        for k in 0..<6 {
            let c = centre(3 + k * 4)
            var g = GOBJEntry(); g.objectID = 0x0065; g.position = Vec3(x: c.x + c.dz * 170 * (k % 2 == 0 ? 1 : -1), y: 50, z: c.z - c.dx * 170 * (k % 2 == 0 ? 1 : -1))
            doc.gobj.append(g)
        }
        let box = KMPDocumentBox(doc: doc)
        box.selection = .ktpt(0)
        let workbench = WorkbenchState(isPrimary: false)
        shoot(KMPEditorView(box: box, source: .file(dir.appendingPathComponent("course.kmp"))).environmentObject(workbench), size: CGSize(width: 1500, height: 900), name: "mkwii-course-data", to: dir, wait: 2)
    }

    @MainActor private static func render(into dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if CommandLine.arguments.contains("--mkwii-only") { renderMKWii(into: dir); return }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("docs-shots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // A demo game project: sprite, sound, a screen design and Swift logic.
        let project = try HomebrewTemplate.create(name: "Starfall", language: .gameSwift, in: tmp)
        let designURL = project.appendingPathComponent("ui/main.wiiui")
        var design = UIDocument(background: RGB(r: 0.05, g: 0.07, b: 0.12), widgets: [])
        var title = UIWidget.make(.label, name: "title", x: 40, y: 36); title.text = "Starfall"; title.fontSize = 48; title.width = 320; title.height = 60
        var best = UIWidget.make(.label, name: "best", x: 40, y: 104); best.text = "Best score: 12"; best.fontSize = 24; best.textColor = RGB(r: 0.7, g: 0.8, b: 1)
        var panel = UIWidget.make(.rectangle, name: "panel", x: 40, y: 170); panel.width = 360; panel.height = 230; panel.fill = RGB(r: 0.12, g: 0.15, b: 0.25)
        var play = UIWidget.make(.button, name: "play", x: 70, y: 200); play.text = "Play"; play.width = 300; play.height = 56
        var options = UIWidget.make(.button, name: "options", x: 70, y: 274); options.text = "Options"; options.width = 300; options.height = 56; options.fill = RGB(r: 0.25, g: 0.35, b: 0.6)
        var quit = UIWidget.make(.button, name: "quit", x: 70, y: 348); quit.text = "Quit"; quit.width = 300; quit.height = 38; quit.fill = RGB(r: 0.6, g: 0.25, b: 0.25); quit.fontSize = 24
        design.widgets = [panel, title, best, play, options, quit]
        try design.serialize().write(to: designURL)

        let designBox = UIDesignBox(doc: design, url: designURL)
        designBox.selection = "play"
        shoot(UIDesignerView(box: designBox), size: CGSize(width: 1180, height: 700), name: "ui-designer", to: dir)

        let graphURL = project.appendingPathComponent("logic/main.wiinodes")
        var graph = NodeGraph.sample()   // the click counter, pointed at this design's widgets
        for i in graph.nodes.indices {
            if graph.nodes[i].params["widget"] == "go" { graph.nodes[i].params["widget"] = "play" }
            if graph.nodes[i].params["widget"] == "status" { graph.nodes[i].params["widget"] = "best" }
            if graph.nodes[i].params["a"] == "Pressed " { graph.nodes[i].params["a"] = "Best score: " }
        }
        let graphBox = NodeGraphBox(graph: graph, url: graphURL)
        shoot(NodeEditorView(box: graphBox), size: CGSize(width: 1500, height: 480), name: "node-editor", to: dir)

        let workbench = WorkbenchState(isPrimary: false)
        workbench.openFolder(url: project)
        spin(1.5)
        // The sheet warns when devkitPro isn't installed; show it as it looks once it is.
        let fakeKit = tmp.appendingPathComponent("devkitpro")
        try FileManager.default.createDirectory(at: fakeKit.appendingPathComponent("devkitPPC/bin"), withIntermediateDirectories: true)
        let gcc = fakeKit.appendingPathComponent("devkitPPC/bin/powerpc-eabi-gcc")
        try "#!/bin/sh\n".write(to: gcc, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gcc.path)
        let savedPath = UserDefaults.standard.string(forKey: DevkitPro.pathKey)
        UserDefaults.standard.set(fakeKit.path, forKey: DevkitPro.pathKey)
        defer { if let savedPath { UserDefaults.standard.set(savedPath, forKey: DevkitPro.pathKey) } else { UserDefaults.standard.removeObject(forKey: DevkitPro.pathKey) } }
        shoot(NewHomebrewSheet().environmentObject(workbench), size: CGSize(width: 400, height: 190), name: "new-project", to: dir)


    }
}
#endif
