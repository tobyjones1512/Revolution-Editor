import SwiftUI
import UniformTypeIdentifiers
import Combine
import ImageIO

/// "Animate..." on a BRRES texture: build a flipbook (PAT0) that swaps this texture for a series
/// of frames on every material that draws it. Frames are other textures already in the BRRES or
/// images imported now (encoded at this texture's size and format, so they swap in cleanly).
struct AnimateTextureSheet: View {
    @ObservedObject var box: BRRESDocumentBox
    let resource: BRRESResource
    let onEdit: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    /// A frame: an existing TEX0 by name, or an imported image waiting to be encoded.
    struct Frame: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var image: NSImage?
        static func == (a: Frame, b: Frame) -> Bool { a.id == b.id }
    }
    /// A material that samples this texture, and the slot it samples it in.
    struct Target: Hashable { let model: String; let material: String; let slot: Int }

    @State private var frames: [Frame] = []
    @State private var frameLength = 4
    @State private var loops = true
    @State private var targets: [Target] = []
    @State private var chosen: Set<Target> = []
    @State private var preview = 0
    @State private var playing = true
    @State private var error: String?
    private let timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    private var base: TEX0View? { TEX0View(resource) }
    private var otherTextures: [BRRESResource] { box.doc.resources.filter { $0.magic == "TEX0" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Animate \(resource.name)").font(.headline)
            HStack(alignment: .top, spacing: 16) {
                framesList.frame(width: 300)
                VStack(alignment: .leading, spacing: 10) {
                    previewView
                    Stepper("Each frame shows for \(frameLength) game frame\(frameLength == 1 ? "" : "s") (\(String(format: "%.2f", Double(frameLength) / 60)) s)", value: $frameLength, in: 1...600)
                    Toggle("Loop", isOn: $loops)
                    Text("Total \(frames.count * frameLength) frames at 60 per second.").font(.caption).foregroundStyle(.secondary)
                    targetsList
                }
                .frame(width: 300)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Text("Adds a texture pattern animation (PAT0) named after each model, which the game plays automatically, plus any imported frames as textures.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Create Animation") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(frames.count < 2 || chosen.isEmpty)
            }
        }
        .padding()
        .frame(width: 660)
        .onAppear(perform: setUp)
        .onReceive(timer) { _ in if playing, !frames.isEmpty { preview = (preview + 1) % max(1, frames.count * frameLength) } }
    }

    // MARK: Frames

    private var framesList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Frames").font(.caption.bold())
            List {
                ForEach(Array(frames.enumerated()), id: \.element.id) { i, f in
                    HStack {
                        Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22)
                        thumbnail(f).frame(width: 28, height: 28)
                        Text(f.name).lineLimit(1)
                        if f.image != nil { Text("new").font(.caption2).foregroundStyle(.orange) }
                        Spacer()
                    }
                    .contextMenu {
                        Button("Move Up") { frames.swapAt(i, i - 1) }.disabled(i == 0)
                        Button("Move Down") { frames.swapAt(i, i + 1) }.disabled(i == frames.count - 1)
                        Divider()
                        Button("Duplicate") { frames.insert(Frame(name: f.name, image: f.image), at: i + 1) }
                        Button("Remove", role: .destructive) { frames.remove(at: i) }.disabled(frames.count <= 1)
                    }
                }
                .onMove { frames.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { if frames.count > $0.count { frames.remove(atOffsets: $0) } }
            }
            .frame(height: 260)
            .border(Color.gray.opacity(0.3))
            HStack {
                Menu("Add Texture") {
                    ForEach(otherTextures) { r in Button(r.name) { frames.append(Frame(name: r.name)) } }
                }
                .fixedSize()
                Button("Import Images or GIF...") { importImages() }
            }
            Text("Drag to reorder, or right-click a frame to move, duplicate, or remove it. A GIF imports as all its frames.").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func image(for f: Frame) -> NSImage? {
        if let image = f.image { return image }
        guard let r = box.doc.resources.first(where: { $0.magic == "TEX0" && $0.name == f.name }), let v = TEX0View(r),
              let rgba = v.decodeRGBA(palette: box.palette(for: r)) else { return nil }
        return ImageUtil.nsImage(fromRGBA: rgba, width: v.width, height: v.height)
    }

    @ViewBuilder private func thumbnail(_ f: Frame) -> some View {
        if let img = image(for: f) { Image(nsImage: img).resizable().interpolation(.none).aspectRatio(contentMode: .fit) }
        else { Image(systemName: "photo").foregroundStyle(.secondary) }
    }

    private var previewView: some View {
        VStack(alignment: .leading, spacing: 4) {
            let index = frames.isEmpty ? 0 : min(frames.count - 1, preview / max(1, frameLength))
            Group {
                if frames.indices.contains(index), let img = image(for: frames[index]) {
                    Image(nsImage: img).resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                } else { Color.secondary.opacity(0.1) }
            }
            .frame(width: 180, height: 180)
            .border(Color.gray.opacity(0.3))
            HStack {
                Button { playing.toggle() } label: { Image(systemName: playing ? "pause.fill" : "play.fill") }
                Text(frames.isEmpty ? "" : "Frame \(index + 1) of \(frames.count)").font(.caption.monospacedDigit())
            }
        }
    }

    private var targetsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Animate on").font(.caption.bold())
            if targets.isEmpty {
                Text("No material in this BRRES draws \(resource.name), so there is nothing to animate.").font(.caption).foregroundStyle(.orange)
            }
            ForEach(targets, id: \.self) { t in
                Toggle("\(t.material) (\(t.model), sampler \(t.slot))", isOn: Binding(get: { chosen.contains(t) }, set: { if $0 { chosen.insert(t) } else { chosen.remove(t) } }))
                    .font(.caption)
            }
        }
    }

    // MARK: Actions

    private func setUp() {
        frames = [Frame(name: resource.name)]
        var found: [Target] = []
        for r in box.doc.resources where r.magic == "MDL0" {
            guard let model = MDL0Parser.parse(r, rawFile: box.doc.rawData) else { continue }
            for mesh in model.meshes {
                guard let material = mesh.materialName else { continue }
                for (slot, name) in mesh.textureNames.enumerated() where name == resource.name {
                    let t = Target(model: r.name, material: material, slot: slot)
                    if !found.contains(t) { found.append(t) }
                }
            }
        }
        targets = found
        chosen = Set(found)
    }

    private func importImages() {
        PanelPresenter.openFiles(configure: { $0.allowedContentTypes = [.png, .jpeg, .tiff, .bmp, .gif] }) { urls in
            for url in urls {
                let name = url.deletingPathExtension().lastPathComponent
                // An animated GIF becomes one frame per GIF frame (ImageIO hands them back fully
                // composited), timed from its first frame's delay.
                if let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 1 {
                    let count = CGImageSourceGetCount(src)
                    for i in 0..<count {
                        guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
                        frames.append(Frame(name: "\(name)_\(i + 1)", image: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))))
                    }
                    let gif = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                    if let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] ?? gif?[kCGImagePropertyGIFDelayTime]) as? Double, delay > 0 {
                        frameLength = max(1, Int((delay * 60).rounded()))
                    }
                    continue
                }
                guard let img = NSImage(contentsOf: url) else { continue }
                frames.append(Frame(name: name, image: img))
            }
        }
    }

    private func create() {
        guard let base else { error = "This texture can't be read."; return }
        var added: [BRRESResource] = []
        var names = Set(box.doc.resources.map(\.name))
        // Imported frames become textures matching the animated one, so the material's sampler
        // settings suit every frame.
        var frameNames: [String] = []
        for f in frames {
            guard let img = f.image else { frameNames.append(f.name); continue }
            var name = f.name, k = 2
            while names.contains(name) { name = "\(f.name)_\(k)"; k += 1 }
            guard let rgba = ImageUtil.rgba(from: img, width: base.width, height: base.height) else { error = "Couldn't read \(f.name)."; return }
            var encoded = Data()
            for level in NormalMap.mipChain(rgba, width: base.width, height: base.height, count: base.mipCount) {
                guard let e = TextureCodec.encode(rgba: level.rgba, width: level.width, height: level.height, format: base.format) else {
                    error = "Couldn't encode \(f.name) as \(base.format)."; return
                }
                encoded.append(e)
            }
            guard let data = TEX0View.building(name: name, encoded: encoded, width: base.width, height: base.height, format: base.format, mipCount: base.mipCount) else {
                error = "Couldn't build \(f.name)."; return
            }
            names.insert(name)
            frameNames.append(name)
            added.append(BRRESResource(name: name, folderName: "Textures(NW4R)", data: data))
        }
        // One PAT0 per model, named after it (the game plays a model's same-named animations),
        // merged into any it already has.
        for model in Set(chosen.map(\.model)) {
            var anim = PAT0Animation(name: model, frameCount: frames.count * frameLength, loops: loops, materials: [], textureNames: [])
            let existing = box.doc.resources.first { $0.magic == "PAT0" && $0.name == model }
            if let existing, let old = PAT0Animation.parse(existing, rawFile: box.doc.rawData) {
                anim = old
                anim.frameCount = Self.lcm(old.frameCount, frames.count * frameLength)
                anim.loops = old.loops || loops
            }
            func textureIndex(_ n: String) -> Int {
                if let i = anim.textureNames.firstIndex(of: n) { return i }
                anim.textureNames.append(n)
                return anim.textureNames.count - 1
            }
            for t in chosen where t.model == model {
                let keys = frameNames.enumerated().map { PAT0Animation.Key(frame: Float($0.offset * frameLength), texture: textureIndex($0.element)) }
                var material = anim.materials.first { $0.name == t.material } ?? PAT0Animation.Material(name: t.material, samplers: [])
                material.samplers.removeAll { $0.slot == t.slot }
                material.samplers.append((t.slot, keys))
                material.samplers.sort { $0.slot < $1.slot }
                if let i = anim.materials.firstIndex(where: { $0.name == t.material }) { anim.materials[i] = material } else { anim.materials.append(material) }
            }
            let built = anim.build()
            let pat0 = BRRESResource(name: model, folderName: "AnmTexPat(NW4R)", data: built.data, stringReferences: built.strings)
            if let existing { box.doc.resources.removeAll { $0.id == existing.id } }
            added.append(pat0)
        }
        box.doc.resources.append(contentsOf: added)
        // Re-read so every resource (and its names, now in the pool) is what a save will write.
        guard let reparsed = try? BRRESDocument.parse(box.doc.serialize()) else {
            box.doc.resources.removeAll { r in added.contains { $0 === r } }
            error = "The animation didn't survive being re-read, so it wasn't added. Please report this."
            return
        }
        box.doc = reparsed
        box.selectedResourceID = reparsed.resources.last { $0.magic == "PAT0" }?.id
        box.isDirty = true
        onEdit("Animate Texture")
        dismiss()
    }

    /// Least common multiple, so two loops of different lengths both still loop cleanly; falls
    /// back to the longer length if that would overflow PAT0's 16-bit frame count.
    static func lcm(_ a: Int, _ b: Int) -> Int {
        func gcd(_ x: Int, _ y: Int) -> Int { y == 0 ? x : gcd(y, x % y) }
        guard a > 0, b > 0 else { return max(a, b, 1) }
        let l = a / gcd(a, b) * b
        return l <= 0xFFFF ? l : max(a, b)
    }
}
