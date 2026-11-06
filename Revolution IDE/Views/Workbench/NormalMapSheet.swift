import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The image a normal-map sheet works on, and how to add/apply the result: a BRRES texture
/// (`brres`) or an image file on disk (`file`).
struct NormalMapTarget {
    let name: String
    let rgba: [UInt8]
    let width: Int
    let height: Int
    /// Other images that could be the normal map to apply, by name.
    let candidates: [String]
    let loadCandidate: (String) -> (rgba: [UInt8], width: Int, height: Int)?
    /// Whether "Add" encodes a GX texture (so a format is chosen) rather than writing a PNG.
    let choosesFormat: Bool
    let addLabel: String
    let applyLabel: String
    /// Each returns an error message, or nil once done.
    let add: (_ normals: [UInt8], _ format: GXTextureFormat) -> String?
    let apply: (_ baked: [UInt8]) -> String?

    @MainActor static func brres(box: BRRESDocumentBox, resource: BRRESResource, onEdit: @escaping (String) -> Void) -> NormalMapTarget? {
        guard let v = TEX0View(resource), let rgba = v.decodeRGBA(palette: box.palette(for: resource)) else { return nil }
        return NormalMapTarget(
            name: resource.name, rgba: rgba, width: v.width, height: v.height,
            candidates: box.doc.resources.filter { $0.magic == "TEX0" && $0.id != resource.id }.map(\.name),
            loadCandidate: { name in
                guard let r = box.doc.resources.first(where: { $0.magic == "TEX0" && $0.name == name }), let v = TEX0View(r),
                      let rgba = v.decodeRGBA(palette: box.palette(for: r)) else { return nil }
                return (rgba, v.width, v.height)
            },
            choosesFormat: true, addLabel: "Add to BRRES", applyLabel: "Apply to Texture",
            add: { normals, format in
                var name = resource.name + "_n", k = 2
                while box.doc.resources.contains(where: { $0.name == name }) { name = resource.name + "_n\(k)"; k += 1 }
                var encoded = Data()
                for level in NormalMap.mipChain(normals, width: v.width, height: v.height, count: v.mipCount) {
                    guard let e = TextureCodec.encode(rgba: level.rgba, width: level.width, height: level.height, format: format) else { return "Couldn't encode the normal map." }
                    encoded.append(e)
                }
                guard let data = TEX0View.building(name: name, encoded: encoded, width: v.width, height: v.height, format: format, mipCount: v.mipCount) else {
                    return "Couldn't build the normal map texture."
                }
                box.doc.resources.append(BRRESResource(name: name, folderName: "Textures(NW4R)", data: data))
                box.isDirty = true
                box.objectWillChange.send()
                onEdit("Add Normal Map")
                return nil
            },
            apply: { baked in
                guard let data = TEX0View.rebuilding(resource, withRGBA: baked) else { return "Couldn't re-encode the texture in its format." }
                resource.data = data
                box.isDirty = true
                box.objectWillChange.send()
                onEdit("Apply Normal Map")
                return nil
            })
    }

    /// An image file: Add writes `<name>_n.png` beside it, Apply rewrites the file itself in its
    /// own format.
    static func file(_ url: URL, onChange: @escaping (URL) -> Void = { _ in }) -> NormalMapTarget? {
        guard let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data), let image = NSImage(data: data),
              let rgba = ImageUtil.rgba(from: image, width: rep.pixelsWide, height: rep.pixelsHigh) else { return nil }
        let folder = url.deletingLastPathComponent(), base = url.deletingPathExtension().lastPathComponent
        let siblings = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0 != url && WorkbenchState.imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return NormalMapTarget(
            name: url.lastPathComponent, rgba: rgba, width: rep.pixelsWide, height: rep.pixelsHigh,
            candidates: siblings.map(\.lastPathComponent),
            loadCandidate: { name in
                let u = folder.appendingPathComponent(name)
                guard let d = try? Data(contentsOf: u), let r = NSBitmapImageRep(data: d), let img = NSImage(data: d),
                      let px = ImageUtil.rgba(from: img, width: r.pixelsWide, height: r.pixelsHigh) else { return nil }
                return (px, r.pixelsWide, r.pixelsHigh)
            },
            choosesFormat: false, addLabel: "Save Beside Image", applyLabel: "Apply to Image",
            add: { normals, _ in
                var out = folder.appendingPathComponent(base + "_n.png"), k = 2
                while FileManager.default.fileExists(atPath: out.path) { out = folder.appendingPathComponent(base + "_n\(k).png"); k += 1 }
                guard let png = encode(normals, rep.pixelsWide, rep.pixelsHigh, as: "png") else { return "Couldn't encode the normal map." }
                do { try png.write(to: out, options: .atomic) } catch { return error.localizedDescription }
                onChange(out)
                return nil
            },
            apply: { baked in
                guard let encoded = encode(baked, rep.pixelsWide, rep.pixelsHigh, as: url.pathExtension.lowercased()) else { return "Couldn't encode the image." }
                do { try encoded.write(to: url, options: .atomic) } catch { return error.localizedDescription }
                onChange(url)
                return nil
            })
    }

    /// The right-click shortcuts: add/apply a normal map generated with the sheet's defaults, no UI.
    /// Returns an error message, or nil once done.
    @MainActor func run(_ mode: NormalMapSheet.Mode) -> String? {
        let normals = NormalMap.generate(rgba: rgba, width: width, height: height, options: NormalMap.Options())
        guard !normals.isEmpty else { return "Couldn't make a normal map from \(name)." }
        switch mode {
        case .create: return add(normals, .rgb565)
        case .apply: return apply(NormalMap.bake(texture: rgba, width: width, height: height, normals: normals, normalWidth: width, normalHeight: height, light: NormalMap.Light()))
        }
    }

    private static func encode(_ rgba: [UInt8], _ w: Int, _ h: Int, as ext: String) -> Data? {
        guard let image = ImageUtil.nsImage(fromRGBA: rgba, width: w, height: h), let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        let type: NSBitmapImageRep.FileType = switch ext {
        case "jpg", "jpeg": .jpeg
        case "tif", "tiff": .tiff
        case "bmp": .bmp
        case "gif": .gif
        default: .png
        }
        return rep.representation(using: type, properties: type == .jpeg ? [.compressionFactor: 0.95] : [:])
    }
}

/// A texture's "Normal Map..." button: create a normal map from an image, and apply a normal
/// map's relief to it (baked in with a chosen light, see `NormalMap` for why it's baked).
struct NormalMapSheet: View {
    let target: NormalMapTarget
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable { case create = "Add Normal Map", apply = "Apply Normal Map" }
    enum Source: Hashable { case generated, other(String), file }

    @State private var mode: Mode
    @State private var options = NormalMap.Options()
    @State private var light = NormalMap.Light()
    @State private var source: Source = .generated
    @State private var fileNormals: (rgba: [UInt8], width: Int, height: Int)?
    @State private var fileName: String?
    @State private var newFormat: GXTextureFormat = .rgb565
    @State private var error: String?

    init(target: NormalMapTarget, mode: Mode = .create) {
        self.target = target
        _mode = State(initialValue: mode)
    }

    private var generated: [UInt8]? {
        NormalMap.generate(rgba: target.rgba, width: target.width, height: target.height, options: options)
    }

    /// The normal map `apply` uses, at its own size.
    private var normals: (rgba: [UInt8], width: Int, height: Int)? {
        switch source {
        case .generated: return generated.map { ($0, target.width, target.height) }
        case .other(let name): return target.loadCandidate(name)
        case .file: return fileNormals
        }
    }

    private var baked: [UInt8]? {
        guard let n = normals else { return nil }
        return NormalMap.bake(texture: target.rgba, width: target.width, height: target.height, normals: n.rgba, normalWidth: n.width, normalHeight: n.height, light: light)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Normal Map: \(target.name)").font(.headline)
                Spacer()
                Picker("", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    if mode == .create || source == .generated { heightControls }
                    if mode == .apply { applyControls }
                    Spacer(minLength: 0)
                }
                .frame(width: 260)
                previews
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                if mode == .create {
                    Button("Export PNG...") { exportNormalMap() }.disabled(generated == nil)
                    if target.choosesFormat {
                        Picker("", selection: $newFormat) {
                            Text("RGB565").tag(GXTextureFormat.rgb565)
                            Text("RGBA32").tag(GXTextureFormat.rgba32)
                            Text("CMPR").tag(GXTextureFormat.cmpr)
                        }
                        .labelsHidden().fixedSize()
                        .help("Format for the added texture: RGB565 is half the size of RGBA32 with plenty of precision for normals; CMPR is smallest but blocky.")
                    }
                    Button(target.addLabel) { run({ target.add($0 ?? [], newFormat) })(generated) }
                        .disabled(generated == nil).keyboardShortcut(.defaultAction)
                        .help("Adds the normal map next to the image as a separate texture; the image itself is unchanged.")
                } else {
                    Button(target.applyLabel) { run({ target.apply($0 ?? []) })(baked) }
                        .disabled(baked == nil).keyboardShortcut(.defaultAction)
                        .help("Bakes the normal map's relief into the image's own pixels, replacing them.")
                }
            }
        }
        .padding()
        .frame(width: 760)
    }

    private var heightControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("From this texture's brightness").font(.caption.bold())
            slider("Strength", value: Binding(get: { Double(options.strength) }, set: { options.strength = Float($0) }), 0.25...12, "%.1f")
            slider("Smoothing", value: Binding(get: { Double(options.blur) }, set: { options.blur = Int($0.rounded()) }), 0...6, "%.0f px")
            Toggle("Dark areas are raised", isOn: $options.invert).font(.caption)
                .help("By default light = high (grout and cracks sink in). Turn on for textures where the dark parts stick out.")
        }
    }

    private var applyControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Normal map", selection: $source) {
                Text("Generated from this image").tag(Source.generated)
                ForEach(target.candidates, id: \.self) { Text($0).tag(Source.other($0)) }
                Text(fileName.map { "File: \($0)" } ?? "Image file...").tag(Source.file)
            }
            .font(.caption)
            .onChange(of: source) { _, s in if s == .file, fileNormals == nil { chooseFile() } }
            Text("Light").font(.caption.bold())
            slider("Direction", value: Binding(get: { Double(light.azimuth) }, set: { light.azimuth = Float($0) }), 0...360, "%.0f°")
            slider("Height", value: Binding(get: { Double(light.elevation) }, set: { light.elevation = Float($0) }), 5...85, "%.0f°")
            slider("Relief", value: Binding(get: { Double(light.intensity) }, set: { light.intensity = Float($0) }), 0...2, "%.2f")
            slider("Ambient", value: Binding(get: { Double(light.ambient) }, set: { light.ambient = Float($0) }), 0...1.5, "%.2f")
            Text("The relief is baked into the texture's pixels: Mario Kart Wii's course shader has no per-pixel lighting, so this is how it shows in-game (and on GameCube). Match the direction to the track's sun.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var previews: some View {
        HStack(alignment: .top, spacing: 10) {
            if mode == .create {
                preview("Image", target.rgba, target.width, target.height)
                preview("Normal map", generated, target.width, target.height)
            } else {
                preview("Before", target.rgba, target.width, target.height)
                preview("After", baked, target.width, target.height)
            }
        }
    }

    private func preview(_ title: String, _ rgba: [UInt8]?, _ w: Int, _ h: Int) -> some View {
        VStack(spacing: 4) {
            Group {
                if let rgba, let image = ImageUtil.nsImage(fromRGBA: rgba, width: w, height: h) {
                    Image(nsImage: image).resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
                } else {
                    Color.secondary.opacity(0.1)
                }
            }
            .frame(width: 220, height: 220)
            .border(Color.gray.opacity(0.3))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func slider(_ label: String, value: Binding<Double>, _ range: ClosedRange<Double>, _ format: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(String(format: format, value.wrappedValue)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range).controlSize(.small)
        }
    }

    // MARK: Actions

    private func chooseFile() {
        PanelPresenter.openFile(configure: { $0.allowedContentTypes = [.png, .jpeg, .tiff, .bmp] }) { url in
            guard let url, let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data), let image = NSImage(contentsOf: url),
                  let rgba = ImageUtil.rgba(from: image, width: rep.pixelsWide, height: rep.pixelsHigh) else {
                if fileNormals == nil { source = .generated }
                return
            }
            fileNormals = (rgba, rep.pixelsWide, rep.pixelsHigh)
            fileName = url.lastPathComponent
        }
    }

    private func exportNormalMap() {
        guard let g = generated, let image = ImageUtil.nsImage(fromRGBA: g, width: target.width, height: target.height),
              let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let base = (target.name as NSString).deletingPathExtension
        PanelPresenter.saveFile(configure: { $0.allowedContentTypes = [.png]; $0.nameFieldStringValue = base + "_n.png" }) { url in
            guard let url else { return }
            do { try png.write(to: url) } catch { self.error = error.localizedDescription }
        }
    }

    private func run(_ action: @escaping ([UInt8]?) -> String?) -> ([UInt8]?) -> Void {
        { input in
            guard input != nil else { return }
            if let message = action(input) { error = message } else { dismiss() }
        }
    }
}
