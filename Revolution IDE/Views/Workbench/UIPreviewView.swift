import SwiftUI
import AppKit
import CoreImage

/// A UI archive to preview: every `.brlyt` layout inside it, drawn with the archive's own `.tpl`
/// textures (see `ProjectNavigatorView.beginPreviewUI`).
struct UIPreviewRequest: Identifiable {
    let id: String
    let sourceName: String
    let root: U8Node
}

/// Mario Kart Wii > Preview UI: shows each screen layout in a `.szs` UI archive the way the game
/// lays it out, pane hierarchy, anchors, rotation/scale, visibility and alpha, picture and
/// window panes with their material's texture, and text panes with their text.
///
/// Approximate by design: materials' TEV colour blending, texture coordinates, fonts and
/// animations (BRLAN) aren't reproduced, so tinted or animated elements show their raw texture.
struct UIPreviewView: View {
    let request: UIPreviewRequest
    @Environment(\.dismiss) private var dismiss
    @State private var layouts: [(path: String, doc: BRLYTDocument)] = []
    @State private var selected: String?
    @State private var textures: [String: CGImage] = [:]
    @State private var showBounds = false

    init(request: UIPreviewRequest) {
        self.request = request
        let (layouts, textures) = Self.load(request.root)
        _layouts = State(initialValue: layouts)
        _textures = State(initialValue: textures)
        _selected = State(initialValue: layouts.first?.path)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("UI Preview. \(request.sourceName)").font(.headline)
                Spacer()
                Toggle("Pane outlines", isOn: $showBounds).toggleStyle(.checkbox)
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            if layouts.isEmpty {
                Text("This archive has no .brlyt layouts to preview.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(layouts, id: \.path, selection: $selected) { item in
                        Text((item.path as NSString).lastPathComponent).font(.caption).tag(item.path)
                    }
                    .frame(minWidth: 200, maxWidth: 320)
                    if let layout = layouts.first(where: { $0.path == selected })?.doc {
                        canvas(layout)
                    } else {
                        Text("Choose a layout.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            Text("Approximate: colour tinting, fonts and animations aren't reproduced.")
                .font(.caption2).foregroundStyle(.secondary).padding(6)
        }
        .frame(minWidth: 900, minHeight: 620)
    }

    private static func load(_ root: U8Node) -> ([(path: String, doc: BRLYTDocument)], [String: CGImage]) {
        var found: [(path: String, doc: BRLYTDocument)] = []
        var tex: [String: CGImage] = [:]
        func walk(_ node: U8Node, _ path: String) {
            for c in node.children {
                let p = path.isEmpty ? c.name : path + "/" + c.name
                if c.isDirectory { walk(c, p); continue }
                guard let data = c.data else { continue }
                let lower = c.name.lowercased()
                if lower.hasSuffix(".brlyt"), let doc = try? BRLYTDocument.parse(data) { found.append((p, doc)) }
                if lower.hasSuffix(".tpl"), let tpl = try? TPLDocument.parse(data), let img = tpl.images.first, let rgba = img.rgba,
                   let ns = ImageUtil.nsImage(fromRGBA: rgba, width: img.width, height: img.height),
                   let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    tex[lower] = cg
                }
            }
        }
        walk(root, "")
        return (found.sorted { $0.path < $1.path }, tex)
    }

    private func canvas(_ layout: BRLYTDocument) -> some View {
        UILayoutCanvas(layout: layout, textures: textures, showBounds: showBounds)
    }
}

/// Draws one layout: pane hierarchy, anchors, rotation/scale, visibility, alpha, textured
/// picture/window panes and text panes.
struct UILayoutCanvas: View {
    let layout: BRLYTDocument
    let textures: [String: CGImage]
    var showBounds = false

    var body: some View {
        GeometryReader { geo in
            let w = CGFloat(max(layout.layoutWidth, 1)), h = CGFloat(max(layout.layoutHeight, 1))
            let scale = min(geo.size.width / w, geo.size.height / h) * 0.95
            Canvas { ctx, size in
                // Screen area, then layout space: origin at the centre, +Y up.
                let screen = CGRect(x: (size.width - w * scale) / 2, y: (size.height - h * scale) / 2, width: w * scale, height: h * scale)
                ctx.fill(Path(screen), with: .color(Color(white: 0.08)))
                ctx.clip(to: Path(screen))
                var base = ctx
                base.translateBy(x: size.width / 2, y: size.height / 2)
                base.scaleBy(x: scale, y: -scale)
                for pane in layout.rootPanes { draw(pane, in: base, alpha: 1) }
            }
        }
        .background(Color.black)
    }
    /// Draws `pane` and its children. `ctx` is in the parent's space; `alpha` is inherited.
    private func draw(_ pane: BRLYTPane, in parent: GraphicsContext, alpha: Double) {
        guard pane.visible else { return }
        var ctx = parent
        ctx.translateBy(x: CGFloat(pane.translation.x), y: CGFloat(pane.translation.y))
        ctx.rotate(by: .degrees(Double(pane.rotation.z)))
        ctx.scaleBy(x: CGFloat(pane.scale.x), y: CGFloat(pane.scale.y))
        let own = alpha * Double(pane.alpha) / 255
        let w = CGFloat(pane.width), h = CGFloat(pane.height)
        let col = CGFloat(pane.origin % 3), row = CGFloat(pane.origin / 3)
        // Left edge: 0, -w/2, -w for left/centre/right; top edge (y up): 0, h/2, h for top/centre/bottom.
        let rect = CGRect(x: -w * col / 2, y: h * row / 2 - h, width: w, height: h)

        switch pane.kind {
        case "wnd1":
            // A window's textures are its frame pieces; its middle is filled with the content's
            // corner colours.
            if let f = pane.windowFill {
                ctx.fill(Path(rect), with: .color(Color(red: Double(f.0) / 255, green: Double(f.1) / 255, blue: Double(f.2) / 255,
                                                          opacity: own * Double(f.3) / 255)))
            }
        case "pic1":
            if let image = texture(for: pane) {
                var imageCtx = ctx
                imageCtx.opacity = own * Double(pane.vertexAlpha) / 255
                // The context is +Y up, so flip the image back upright inside its rect.
                imageCtx.translateBy(x: rect.minX, y: rect.maxY)
                imageCtx.scaleBy(x: 1, y: -1)
                let target = CGRect(x: 0, y: 0, width: rect.width, height: rect.height)
                let (s0, t0, s1, t1) = pane.texCoordBounds.map { (CGFloat($0.0), CGFloat($0.1), CGFloat($0.2), CGFloat($0.3)) } ?? (0, 0, 1, 1)
                let iw = CGFloat(image.width), ih = CGFloat(image.height)
                if s0 >= 0, t0 >= 0, s1 <= 1, t1 <= 1, s1 > s0, t1 > t0 {
                    // Part of the texture (or all of it): crop, then stretch over the pane.
                    let crop = CGRect(x: s0 * iw, y: t0 * ih, width: (s1 - s0) * iw, height: (t1 - t0) * ih).integral
                    if let part = image.cropping(to: crop) { imageCtx.draw(Image(decorative: part, scale: 1), in: target) }
                } else if s1 > s0, t1 > t0 {
                    // Repeats: tile it (s1 - s0) times across and (t1 - t0) times down.
                    imageCtx.scaleBy(x: rect.width / ((s1 - s0) * iw), y: rect.height / ((t1 - t0) * ih))
                    let tiled = CGRect(x: 0, y: 0, width: (s1 - s0) * iw, height: (t1 - t0) * ih)
                    imageCtx.fill(Path(tiled), with: .tiledImage(Image(decorative: image, scale: 1), origin: CGPoint(x: -s0 * iw, y: -t0 * ih)))
                } else {
                    imageCtx.draw(Image(decorative: image, scale: 1), in: target)
                }
            }
        case "txt1":
            if let text = pane.text, !text.isEmpty {
                var textCtx = ctx
                textCtx.opacity = own * Double(pane.textColor.3) / 255
                textCtx.scaleBy(x: 1, y: -1)
                var c = pane.textColor
                if let m = pane.materialIndex, layout.materials.indices.contains(m) {
                    let w = layout.materials[m].whiteColor
                    c = (UInt8(Int(c.0) * Int(w.0) / 255), UInt8(Int(c.1) * Int(w.1) / 255), UInt8(Int(c.2) * Int(w.2) / 255), c.3)
                }
                let label = Text(text).font(.system(size: CGFloat(max(pane.fontSize.y, 4))))
                    .foregroundColor(Color(red: Double(c.0) / 255, green: Double(c.1) / 255, blue: Double(c.2) / 255))
                let tc = CGFloat(pane.textPosition % 3), tr = CGFloat(pane.textPosition / 3)
                let flipped = CGRect(x: rect.minX, y: -rect.maxY, width: rect.width, height: rect.height)
                let point = CGPoint(x: flipped.minX + flipped.width * tc / 2, y: flipped.minY + flipped.height * tr / 2)
                // The system font is wider than the game's, so shrink a line that would overflow its box.
                let resolved = textCtx.resolve(label)
                let natural = resolved.measure(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
                let fit = rect.width > 0 && natural.width > rect.width ? rect.width / natural.width : 1
                textCtx.translateBy(x: point.x, y: point.y)
                textCtx.scaleBy(x: fit, y: fit)
                textCtx.draw(resolved, at: .zero, anchor: UnitPoint(x: tc / 2, y: tr / 2))
            }
        default: break
        }
        if showBounds, w > 0, h > 0 {
            ctx.stroke(Path(rect), with: .color(pane.kind == "txt1" ? .yellow : .cyan.opacity(0.6)), lineWidth: 1 / max(abs(CGFloat(pane.scale.x)), 0.01))
        }
        let childAlpha = pane.influencesChildAlpha ? own : alpha
        for child in pane.children { draw(child, in: ctx, alpha: childAlpha) }
    }

    /// The pane's texture with its material's tint applied: each channel maps 0...1 onto
    /// black...white, like the game's default UI TEV setup.
    private func texture(for pane: BRLYTPane) -> CGImage? {
        guard let m = pane.materialIndex, layout.materials.indices.contains(m),
              let t = layout.materials[m].textureIndices.first, layout.textureFilenames.indices.contains(t),
              let image = textures[layout.textureFilenames[t].lowercased()] else { return nil }
        let mat = layout.materials[m]
        let (b, w) = (mat.blackColor, mat.whiteColor)
        guard b.0 != 0 || b.1 != 0 || b.2 != 0 || b.3 != 0 || w.0 != 255 || w.1 != 255 || w.2 != 255 || w.3 != 255 else { return image }
        let key = "\(layout.textureFilenames[t])|\(b)|\(w)" as NSString
        if let cached = Self.tintCache.object(forKey: key) { return (cached as! CGImage) }
        func f(_ v: UInt8) -> CGFloat { CGFloat(v) / 255 }
        let filter = CIFilter(name: "CIColorMatrix")!
        filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: f(w.0) - f(b.0), y: 0, z: 0, w: 0), forKey: "inputRVector")
        filter.setValue(CIVector(x: 0, y: f(w.1) - f(b.1), z: 0, w: 0), forKey: "inputGVector")
        filter.setValue(CIVector(x: 0, y: 0, z: f(w.2) - f(b.2), w: 0), forKey: "inputBVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: f(w.3) - f(b.3)), forKey: "inputAVector")
        filter.setValue(CIVector(x: f(b.0), y: f(b.1), z: f(b.2), w: f(b.3)), forKey: "inputBiasVector")
        guard let output = filter.outputImage, let tinted = Self.ciContext.createCGImage(output, from: CGRect(x: 0, y: 0, width: image.width, height: image.height)) else { return image }
        Self.tintCache.setObject(tinted, forKey: key)
        return tinted
    }

    private static let ciContext = CIContext()
    private static let tintCache = NSCache<NSString, AnyObject>()
}
