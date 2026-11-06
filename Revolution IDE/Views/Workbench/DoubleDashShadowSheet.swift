import SwiftUI
import SceneKit

/// Mario Kart: Double Dash!! > Create Shadow Map...: the Double Dash counterpart of the Wii sheet,
/// with the same sun controls and live preview, baking into the course model's vertex colours
/// as retail Double Dash does (see `MKDDShadow`).
struct DoubleDashShadowRequest: Identifiable {
    let id = UUID()
    /// What the user right-clicked, for the title.
    let name: String
    let bmd: Data
    /// Writes the shadowed model back where it came from.
    let save: (Data) throws -> Void
}

struct DoubleDashShadowSheet: View {
    let request: DoubleDashShadowRequest
    @Environment(\.dismiss) private var dismiss
    @State private var options = ShadowSunControls.lastOptions
    @State private var shadowColor = ShadowSunControls.retailShadowColor
    @State private var model: MKDDTrackBuilder.Model?
    @State private var scene = ShadowPreviewScene.make()
    @State private var previewing = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create Shadow Map: \(request.name)").font(.headline)
            HStack(alignment: .top, spacing: 16) {
                ShadowSunControls(options: $options, shadowColor: $shadowColor)
                    .frame(width: 280)
                ZStack(alignment: .topTrailing) {
                    ShadowPreviewScene.view(scene)
                    if previewing || model == nil { ProgressView().controlSize(.small).padding(6) }
                }
                .frame(width: 420, height: 300)
                .border(Color.gray.opacity(0.3))
                .help("Live preview: the track with these settings' shadows. Drag to orbit, scroll to zoom.")
            }
            Text("Double Dash shades its tracks through vertex colours, so the shadows are baked into them: every triangle casts, and each corner is darkened by how much sun reaches it, so a shadow is as sharp as the model is detailed. The model is rebuilt to do this (texture x vertex colour, like the course builder), so special material effects are reset. Undo by keeping a copy, or re-port the course.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(working ? "Baking..." : "Create Shadow Map") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || model == nil)
            }
        }
        .padding()
        .frame(width: 760)
        .task {
            let bmd = request.bmd
            let loaded = await Task.detached(priority: .userInitiated) { Result { try MKDDShadow.load(bmd) } }.value
            switch loaded {
            case .success(let m): model = m
            case .failure(let e): error = "This model couldn't be read: \(e.localizedDescription)"
            }
        }
        .onChange(of: options) { _, new in ShadowSunControls.remember(new) }
        .task(id: PreviewKey(options: options, color: shadowColor, loaded: model != nil)) { await preview() }
    }

    private struct PreviewKey: Equatable { var options: ShadowMap.Options; var color: Color; var loaded: Bool }

    private func preview() async {
        guard let model else { return }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        var quick = options
        quick.samples = min(quick.samples, 4)
        let color = ShadowSunControls.rgb(shadowColor)
        previewing = true
        let node = await Task.detached(priority: .userInitiated) { () -> SCNNode? in
            // Through the same reader and preview path the J3D editor uses, so what shows is what's written.
            guard let bmd = try? MKDDShadow.write(MKDDShadow.bake(model, options: quick, shadowColor: color)),
                  let j3d = try? J3DModel.parse(bmd),
                  let doc = (try? J3DToWii.brres(from: j3d, modelName: "course", scale: 1)).flatMap({ try? BRRESDocument.parse($0) }),
                  let r = doc.resources.first(where: { $0.magic == "MDL0" }),
                  let mdl0 = MDL0Parser.parse(r, rawFile: doc.rawData) else { return nil }
            return MDL0SceneKit.node(for: mdl0, textures: MDL0SceneKit.textureImages(in: doc))
        }.value
        guard !Task.isCancelled else { return }
        previewing = false
        if let node { ShadowPreviewScene.show(node, in: scene) }
    }

    private func create() {
        guard let model else { return }
        working = true
        error = nil
        let (o, color, save) = (options, ShadowSunControls.rgb(shadowColor), request.save)
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { Result { try MKDDShadow.write(MKDDShadow.bake(model, options: o, shadowColor: color)) } }.value
            working = false
            do {
                try save(try outcome.get())
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
