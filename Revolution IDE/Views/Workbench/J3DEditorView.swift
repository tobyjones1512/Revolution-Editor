import SwiftUI

/// View-only GameCube J3D model (`.bmd`/`.bdl`): the Wii-converted mesh preview plus its TEX1
/// textures, shown with the same texture list a `.tpl`/`.bti` gets.
struct J3DEditorView: View {
    @ObservedObject var box: J3DDocumentBox
    @State private var showTextures = false
    @State private var selectedMeshIndex = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $showTextures) {
                Text("Model").tag(false)
                Text("Textures (\(box.model.textures.count))").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize().padding(8)
            Divider()
            if showTextures {
                TPLEditorView(box: box.textures)
            } else {
                model
            }
        }
    }

    /// Laid out like the BRRES model viewer (a scroll view round a fixed-height preview), which is
    /// known to behave in the Workbench: a preview that fills the pane pushed the sidebar and tabs
    /// out of view once a big model had loaded.
    private var model: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            if let metrics = box.metrics {
                TrackBudgetView(doubleDash: metrics, fileName: "")
            }
            if let preview = box.preview {
                SceneKitMeshPreviewView(model: preview, textureLookup: box.textureLookup, selectedMeshIndex: $selectedMeshIndex)
                    .frame(minHeight: 360, maxHeight: 420)
                    .border(Color.gray.opacity(0.3))
            } else {
                Text("Couldn't build a preview for this model.").foregroundStyle(.secondary)
            }
            Text("\(box.model.triangles.count) triangles, \(box.model.materials.count) materials, \(box.model.textures.count) textures, \(box.model.joints.count) joints. Previewed through the Wii (MDL0) conversion, so TEV effects beyond the first texture are approximated. View-only.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        }
    }
}

/// View-only GameCube J3D animation (`.btk` texture SRT / `.bca` joint): per-target tracks,
/// sampled at a scrubbable frame that plays live; a `.btk` also shows each animated texture moving.
struct J3DAnimationView: View {
    let box: J3DAnimationDocumentBox
    private var animation: J3DAnimation.Animation { box.animation }
    @State private var frame: Float = 0
    @State private var playing = true
    /// Mirror loop modes play backwards on alternate passes.
    @State private var reversed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(animation.kind.rawValue). \(animation.targets.count) \(animation.kind == .joint ? "joints" : "texture matrices"), \(animation.duration) frames, \(animation.loopName)")
                .font(.headline)
            HStack {
                Button {
                    if !playing, frame >= Float(max(animation.duration, 1)) { frame = 0; reversed = false }
                    playing.toggle()
                } label: { Image(systemName: playing ? "pause.fill" : "play.fill") }
                    .help(playing ? "Pause" : "Play")
                Text("Frame \(Int(frame))").monospacedDigit().frame(width: 90, alignment: .leading)
                Slider(value: $frame, in: 0...Float(max(animation.duration, 1)), step: 1)
            }
            if animation.kind == .textureSRT {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(animation.targets.indices, id: \.self) { i in
                            VStack(spacing: 4) {
                                BTKTilePreview(target: animation.targets[i], image: image(for: animation.targets[i]), frame: frame)
                                    .frame(width: 128, height: 128)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                Text(label(animation.targets[i])).font(.caption2).lineLimit(1).frame(width: 128)
                            }
                        }
                    }
                }
                .frame(height: 156)
                if box.model == nil {
                    Text("No model (.bmd/.bdl) found beside this file, so a test pattern stands in for the textures.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Table(animation.targets.indices.map { Row(id: $0, target: animation.targets[$0]) }) {
                TableColumn("Target") { Text(label($0.target)) }
                TableColumn("Scale") { Text(sample($0.target.scale)).monospacedDigit() }
                TableColumn("Rotation (°)") { Text(sample($0.target.rotation)).monospacedDigit() }
                TableColumn("Translation") { Text(sample($0.target.translation)).monospacedDigit() }
                TableColumn("Keys") { Text(keyCounts($0.target)).monospacedDigit() }
            }
        }
        .padding()
        .task(id: playing) {
            guard playing else { return }
            let clock = ContinuousClock()
            var last = clock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                let now = clock.now
                advance(by: Float((now - last) / .seconds(1)) * 60)  // J3D animations run at 60 frames a second
                last = now
            }
        }
    }

    private func advance(by frames: Float) {
        let end = Float(max(animation.duration, 1))
        var f = frame + (reversed ? -frames : frames)
        switch animation.loopMode {
        case 3, 4: // mirror
            if f >= end { f = end - (f - end); reversed = true }
            if f <= 0 { f = animation.loopMode == 4 ? -f : 0; reversed = false; if animation.loopMode == 3 { playing = false } }
        case 2: f = f.truncatingRemainder(dividingBy: end)
        default: // once
            if f >= end { f = end; playing = false }
        }
        frame = min(max(f, 0), end)
    }

    /// The texture this target's material maps through its matrix, from the model beside it.
    private func image(for t: J3DAnimation.Target) -> NSImage? {
        guard let material = box.model?.materials.first(where: { $0.name == t.name }) else { return nil }
        let slot = t.texMatrix.flatMap { material.textures.indices.contains($0) ? material.textures[$0] : nil }
        guard let index = slot ?? material.textures.compactMap({ $0 }).first, box.textureImages.indices.contains(index) else { return nil }
        return box.textureImages[index]
    }

    private struct Row: Identifiable { let id: Int; let target: J3DAnimation.Target }

    private func label(_ t: J3DAnimation.Target) -> String {
        t.texMatrix.map { "\(t.name) [mtx \($0)]" } ?? t.name
    }

    private func sample(_ tracks: [J3DAnimation.Track]) -> String {
        tracks.map { String(format: "%.3f", $0.value(at: frame)) }.joined(separator: ", ")
    }

    private func keyCounts(_ t: J3DAnimation.Target) -> String {
        (t.scale + t.rotation + t.translation).map { "\($0.keys.count)" }.joined(separator: "/")
    }
}

/// One texture matrix at `frame`: the texture tiled across a square the way the game's UVs would
/// sample it once scaled, rotated about the matrix centre and translated.
private struct BTKTilePreview: View {
    let target: J3DAnimation.Target
    let image: NSImage?
    let frame: Float

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.gray.opacity(0.2)))
            let uvToTex = matrix()
            // The square's UV range in texture space decides which tiles to draw.
            let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)].map { $0.applying(uvToTex) }
            let x0 = max(-64, Int(floor(corners.map(\.x).min()!))), x1 = min(64, Int(ceil(corners.map(\.x).max()!)))
            let y0 = max(-64, Int(floor(corners.map(\.y).min()!))), y1 = min(64, Int(ceil(corners.map(\.y).max()!)))
            var c = ctx
            c.concatenate(CGAffineTransform(scaleX: size.width, y: size.height))
            c.concatenate(uvToTex.inverted())
            let tile = c.resolve(Image(nsImage: image ?? Self.testPattern))
            for x in x0..<x1 { for y in y0..<y1 { c.draw(tile, in: CGRect(x: x, y: y, width: 1, height: 1)) } }
        }
    }

    private func value(_ tracks: [J3DAnimation.Track], _ i: Int, default d: Float) -> CGFloat {
        CGFloat(tracks.indices.contains(i) ? tracks[i].value(at: frame) : d)
    }

    /// UV -> texture coordinate: scale and rotate about the centre, then translate. Translation is
    /// wrapped to one tile since the texture repeats, so a long scroll stays in the drawn range.
    private func matrix() -> CGAffineTransform {
        let cx = CGFloat(target.center[0]), cy = CGFloat(target.center[1])
        func nonZero(_ v: CGFloat) -> CGFloat { abs(v) < 0.001 ? 0.001 : v }
        let sx = nonZero(value(target.scale, 0, default: 1)), sy = nonZero(value(target.scale, 1, default: 1))
        let angle = value(target.rotation, 2, default: 0) * .pi / 180
        var tx = value(target.translation, 0, default: 0), ty = value(target.translation, 1, default: 0)
        tx -= floor(tx); ty -= floor(ty)
        return CGAffineTransform(translationX: -cx, y: -cy)
            .concatenating(CGAffineTransform(scaleX: sx, y: sy))
            .concatenating(CGAffineTransform(rotationAngle: angle))
            .concatenating(CGAffineTransform(translationX: cx + tx, y: cy + ty))
    }

    /// A checkerboard with one red corner, so scrolling, scaling and rotation all show.
    private static let testPattern = NSImage(size: NSSize(width: 64, height: 64), flipped: true) { rect in
        for x in 0..<4 { for y in 0..<4 {
            ((x + y).isMultiple(of: 2) ? NSColor.white : NSColor.darkGray).setFill()
            NSRect(x: x * 16, y: y * 16, width: 16, height: 16).fill()
        } }
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: 16, height: 16).fill()
        return true
    }
}
