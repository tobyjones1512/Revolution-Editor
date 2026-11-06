import SwiftUI
import SceneKit

/// "Create Shadow Map..." on a BRRES model: bake the sun's shadows across the model into a
/// shadow map ("kage") texture and give each chosen material retail's shadow pass (see
/// `ShadowMap`), as modders otherwise do by hand in Blender and BrawlBox.
struct ShadowMapSheet: View {
    @ObservedObject var box: BRRESDocumentBox
    let model: BRRESResource
    let onEdit: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var options = ShadowSunControls.lastOptions
    @State private var shadowColor = ShadowSunControls.retailShadowColor
    @State private var materials: [String] = []
    @State private var receivers: Set<String> = []
    @State private var result: ShadowMap.Shadowed?
    @State private var baking = false
    @State private var error: String?
    /// The model as it would look shadowed, rebaked (small and fast) whenever a setting changes.
    @State private var scene = ShadowPreviewScene.make()
    @State private var previewing = false

    private var kageName: String { model.name + "_kage" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create Shadow Map: \(model.name)").font(.headline)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    ShadowSunControls(options: $options, shadowColor: $shadowColor)
                    Picker("Map size", selection: $options.size) {
                        Text("512").tag(512); Text("1024").tag(1024); Text("2048").tag(2048)
                    }
                    .font(.caption)
                    .help("Bigger is sharper but takes more memory (CMPR: 128 KB, 512 KB or 2 MB).")
                    Text("Receive shadows").font(.caption.bold())
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(materials, id: \.self) { m in
                                Toggle(m, isOn: Binding(get: { receivers.contains(m) }, set: { if $0 { receivers.insert(m) } else { receivers.remove(m) } }))
                                    .font(.caption)
                            }
                        }
                    }
                    .frame(height: 110)
                }
                .frame(width: 280)
                VStack(spacing: 6) {
                    ZStack(alignment: .topTrailing) {
                        ShadowPreviewScene.view(scene)
                        if previewing { ProgressView().controlSize(.small).padding(6) }
                    }
                    .frame(width: 420, height: 300)
                    .border(Color.gray.opacity(0.3))
                    .help("Live preview: the model with these settings' shadows. Drag to orbit, scroll to zoom. It's baked small for speed; the real map is sharper.")
                    HStack(alignment: .top) {
                        Group {
                            if let result, let image = ImageUtil.nsImage(fromRGBA: result.map, width: options.size, height: options.size) {
                                Image(nsImage: image).resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
                            } else if baking {
                                ProgressView()
                            } else {
                                Text("Bake to see the full map.").font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            }
                        }
                        .frame(width: 110, height: 110)
                        .background(Color.secondary.opacity(0.1))
                        .border(Color.gray.opacity(0.3))
                        Button("Bake Full Map") { bake(apply: false) }.disabled(baking || receivers.isEmpty)
                        Spacer()
                    }
                }
            }
            Text("Every triangle casts shadows; the chosen textured materials get a second UV set and the shadow map as a second pass, using retail's own shader. The model is rebuilt to do this, so per-material tweaks this app doesn't model (custom TEV setups) are reset to the standard course shader. Undo restores the original.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Create Shadow Map") { bake(apply: true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(baking || receivers.isEmpty)
            }
        }
        .padding()
        .frame(width: 760)
        .onAppear {
            let textured = MDL0Parser.parse(model, rawFile: box.doc.rawData)?.meshes.filter { $0.textureName != nil }.compactMap(\.materialName) ?? []
            var seen = Set<String>()
            materials = textured.filter { seen.insert($0).inserted }
            receivers = Set(materials)
        }
        .onChange(of: options) { _, new in
            result = nil
            ShadowSunControls.remember(new)
        }
        .task(id: PreviewKey(options: options, receivers: receivers, color: shadowColor)) { await preview() }
    }

    private struct PreviewKey: Equatable { var options: ShadowMap.Options; var receivers: Set<String>; var color: Color }

    private var rgbShadowColor: (UInt8, UInt8, UInt8) { ShadowSunControls.rgb(shadowColor) }

    /// Debounced: rebakes at 256 with few rays once the sliders settle, then swaps the model in
    /// the scene (the camera stays where the user left it).
    private func preview() async {
        guard !materials.isEmpty, !receivers.isEmpty else { return }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        var quick = options
        quick.samples = min(quick.samples, 4)
        let doc = box.doc, model = model, receivers = receivers, kageName = kageName, color = rgbShadowColor
        previewing = true
        let node = await Task.detached(priority: .userInitiated) { () -> SCNNode? in
            // The smallest map the receivers fit in: big tracks need 1024 or more.
            let s = [256, 512, 1024, 2048].lazy.compactMap { size -> ShadowMap.Shadowed? in
                var o = quick
                o.size = size
                return try? ShadowMap.shadow(model, in: doc, options: o, shadowColor: color, kageName: kageName, receivers: receivers)
            }.first
            guard let s,
                  let shadowed = ShadowMap.applying(s, model: model, to: doc),
                  let r = shadowed.resources.first(where: { $0.magic == "MDL0" && $0.name == model.name }),
                  let parsed = MDL0Parser.parse(r, rawFile: shadowed.rawData) else { return nil }
            return MDL0SceneKit.node(for: parsed, textures: MDL0SceneKit.textureImages(in: shadowed))
        }.value
        guard !Task.isCancelled else { return }
        previewing = false
        guard let node else { return }
        ShadowPreviewScene.show(node, in: scene)
    }

    private func bake(apply: Bool) {
        let doc = box.doc, model = model, options = options, receivers = receivers, kageName = kageName, color = rgbShadowColor
        baking = true
        error = nil
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<ShadowMap.Shadowed, Error> in
                Result { try ShadowMap.shadow(model, in: doc, options: options, shadowColor: color, kageName: kageName, receivers: receivers) }
            }.value
            baking = false
            switch outcome {
            case .failure(let e): error = e.localizedDescription
            case .success(let s):
                result = s
                if apply { install(s) }
            }
        }
    }

    private func install(_ s: ShadowMap.Shadowed) {
        guard let reparsed = ShadowMap.applying(s, model: model, to: box.doc) else {
            error = "The shadowed model didn't survive being re-read, so nothing was changed. Please report this."
            return
        }
        box.doc = reparsed
        box.selectedResourceID = reparsed.resources.first { $0.magic == "MDL0" && $0.name == model.name }?.id
        box.isDirty = true
        onEdit("Create Shadow Map")
        dismiss()
    }
}

/// The sun settings both Create Shadow Map sheets share (Mario Kart Wii's shadow map, Double
/// Dash's vertex-colour bake), remembered between uses.
struct ShadowSunControls: View {
    @Binding var options: ShadowMap.Options
    @Binding var shadowColor: Color

    private static let optionsKey = "shadowMap.lastOptions"
    static var lastOptions: ShadowMap.Options {
        UserDefaults.standard.data(forKey: optionsKey).flatMap { try? JSONDecoder().decode(ShadowMap.Options.self, from: $0) } ?? ShadowMap.Options()
    }
    static func remember(_ o: ShadowMap.Options) { UserDefaults.standard.set(try? JSONEncoder().encode(o), forKey: optionsKey) }
    static let retailShadowColor = Color(.sRGB, red: 0x4C / 255.0, green: 0x4C / 255.0, blue: 0x56 / 255.0)
    static func rgb(_ c: Color) -> (UInt8, UInt8, UInt8) {
        let ns = NSColor(c).usingColorSpace(.sRGB) ?? .gray
        func b(_ x: CGFloat) -> UInt8 { UInt8(max(0, min(255, (x * 255).rounded()))) }
        return (b(ns.redComponent), b(ns.greenComponent), b(ns.blueComponent))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sun").font(.caption.bold())
                Spacer()
                Button("Reset") { options = ShadowMap.Options() }
                    .controlSize(.small).disabled(options == ShadowMap.Options())
                    .help("Back to the default sun.")
            }
            slider("Direction", $options.azimuth, 0...360, "%.0f°")
            slider("Height", $options.elevation, 5...89, "%.0f°")
            slider("Softness", $options.softness, 0...6, "%.1f°")
            slider("Strength", $options.darkness, 0...1, "%.2f")
            Toggle("Shade slopes facing away from the sun", isOn: $options.shadeSlopes).font(.caption)
            ColorPicker("Shadow colour", selection: $shadowColor, supportsOpacity: false).font(.caption)
                .help("What full shadow fades the ground to. Retail Luigi Circuit uses a dark blue-grey (4C 4C 56).")
        }
    }

    private func slider(_ label: String, _ value: Binding<Float>, _ range: ClosedRange<Float>, _ format: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(String(format: format, value.wrappedValue)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range).controlSize(.small)
        }
    }
}

/// The live 3D preview both shadow sheets use: a scene with a model holder and a camera that
/// keeps where the user orbited to when the model is swapped for a rebaked one.
enum ShadowPreviewScene {
    static func make() -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = NSColor(white: 0.18, alpha: 1)
        let model = SCNNode()
        model.name = "model"
        let camera = SCNNode()
        camera.name = "camera"
        camera.camera = SCNCamera()
        scene.rootNode.addChildNode(model)
        scene.rootNode.addChildNode(camera)
        return scene
    }

    static func view(_ scene: SCNScene) -> some View {
        SceneView(scene: scene, pointOfView: scene.rootNode.childNode(withName: "camera", recursively: false), options: [.allowsCameraControl, .autoenablesDefaultLighting])
    }

    /// Swaps in `node`; the first time, centres it (what the orbit control turns round) and puts
    /// the camera above it to the south-east.
    static func show(_ node: SCNNode, in scene: SCNScene) {
        guard let container = scene.rootNode.childNode(withName: "model", recursively: false),
              let cam = scene.rootNode.childNode(withName: "camera", recursively: false) else { return }
        let fresh = container.childNodes.isEmpty
        container.childNodes.forEach { $0.removeFromParentNode() }
        container.addChildNode(node)
        guard fresh else { return }
        let (lo, hi) = node.boundingBox
        let center = SCNVector3((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2)
        let radius = max(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z, 1)
        container.position = SCNVector3(-center.x, -center.y, -center.z)
        cam.camera?.zFar = Double(radius) * 6
        cam.camera?.zNear = Double(radius) / 1000
        cam.position = SCNVector3(radius * 0.55, radius * 0.6, radius * 0.55)
        cam.look(at: SCNVector3(0, 0, 0))
    }
}
