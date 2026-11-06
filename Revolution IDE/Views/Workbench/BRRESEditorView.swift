import SwiftUI
import UniformTypeIdentifiers
import Combine

struct BRRESEditorView: View {
    @EnvironmentObject var workbench: WorkbenchState
    @ObservedObject var box: BRRESDocumentBox
    @State private var renamingResource: BRRESResource?
    @State private var renameText: String = ""
    @State private var deletingResource: BRRESResource?
    @State private var addErrorMessage: String?
    @State private var newTextureCandidate: NewTextureCandidate?
    @State private var animating: BRRESResource?
    @State private var shadowModel: BRRESResource?
    /// Undo/redo + history list, same `EditHistory` pattern `KMPEditorView` uses.
    @StateObject private var history: EditHistory

    init(box: BRRESDocumentBox) {
        self.box = box
        _history = StateObject(wrappedValue: EditHistory(initial: box.doc.serialize()))
    }

    private func pushHistory(_ label: String) {
        history.push(box.doc.serialize(), label: label)
    }

    private func restoreFromHistory(_ data: Data) {
        guard let doc = try? BRRESDocument.parse(data) else { return }
        box.doc = doc
        box.selectedResourceID = nil
        box.isDirty = true
    }

    private var grouped: [(folder: String, items: [BRRESResource])] {
        var order: [String] = []
        var byFolder: [String: [BRRESResource]] = [:]
        for r in box.doc.resources {
            if byFolder[r.folderName] == nil { order.append(r.folderName) }
            byFolder[r.folderName, default: []].append(r)
        }
        return order.map { ($0, byFolder[$0] ?? []) }
    }

    private var selected: BRRESResource? {
        box.doc.resources.first { $0.id == box.selectedResourceID }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: Binding(get: { box.selectedResourceID }, set: { box.selectedResourceID = $0 })) {
                    ForEach(grouped, id: \.folder) { group in
                        Section(group.folder) {
                            ForEach(group.items) { item in
                                HStack {
                                    thumbnail(for: item)
                                    Text(item.name)
                                }
                                .tag(item.id)
                                .contextMenu {
                                    if item.magic == "TEX0" {
                                        Button("Animate...") { animating = item }
                                            .help("Turn this texture into an animated (flipbook) texture.")
                                        Button("Add Normal") { openNormal(item, .create) }
                                        Button("Apply Normal") { openNormal(item, .apply) }
                                        Divider()
                                    }
                                    if item.magic == "MDL0" {
                                        Button("Create Shadow Map...") { shadowModel = item }
                                            .help("Bake sunlight shadows across this model into a shadow map texture and give its materials a second, shadow pass, as retail courses have.")
                                        Divider()
                                    }
                                    Button("Rename...") { renameText = item.name; renamingResource = item }
                                    Button("Extract Raw...") { extractRaw(item) }
                                    Button("Replace Raw From File...") { replaceRaw(item) }
                                    Divider()
                                    Button("Delete", role: .destructive) { deletingResource = item }
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .help("A BRRES is a container bundling a track/character/item's 3D model(s), textures, and animations into one file, this list shows every resource packed inside it, grouped by type.")
                Divider()
                HStack(spacing: 12) {
                    Menu {
                        Button("New Texture from Image...") { chooseNewTexture() }
                        Button("Add File... (.obj / .mtl / raw resource)") { addFile() }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Add a texture encoded fresh from an image, an .obj mesh (converted to a real MDL0 model, uses its companion .mtl's diffuse colour if it has one, instead of always flat white), or a file that's already a properly-framed BRRES sub-resource (e.g. one extracted from another .brres)")
                    Button { if let selected { deletingResource = selected } } label: { Image(systemName: "minus") }
                        .buttonStyle(.borderless)
                        .disabled(selected == nil)
                    Spacer()
                    HistoryControlsView(history: history, onRestore: restoreFromHistory)
                }
                .padding(6)
            }
            .frame(minWidth: 220, idealWidth: 260)

            Group {
                if let selected {
                    detail(for: selected)
                } else {
                    Text("Select a resource").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 400)
        }
        .alert("Rename", isPresented: Binding(get: { renamingResource != nil }, set: { if !$0 { renamingResource = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let renamingResource, !trimmed.isEmpty {
                    renamingResource.name = trimmed
                    box.isDirty = true
                    box.objectWillChange.send()
                    pushHistory("Rename Resource")
                }
                renamingResource = nil
            }
            Button("Cancel", role: .cancel) { renamingResource = nil }
        }
        .alert(
            deletingResource.map { "Delete “\($0.name)”?" } ?? "",
            isPresented: Binding(get: { deletingResource != nil }, set: { if !$0 { deletingResource = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let deletingResource {
                    box.doc.resources.removeAll { $0.id == deletingResource.id }
                    if box.selectedResourceID == deletingResource.id { box.selectedResourceID = nil }
                    box.isDirty = true
                    box.objectWillChange.send()
                    pushHistory("Delete Resource")
                }
                deletingResource = nil
            }
            Button("Cancel", role: .cancel) { deletingResource = nil }
        } message: {
            Text("This resource will be removed from the archive. This can't be undone once saved.")
        }
        .alert("Couldn't Add File", isPresented: Binding(get: { addErrorMessage != nil }, set: { if !$0 { addErrorMessage = nil } })) {
            Button("OK", role: .cancel) { addErrorMessage = nil }
        } message: {
            Text(addErrorMessage ?? "")
        }
        .sheet(item: $animating) { r in AnimateTextureSheet(box: box, resource: r, onEdit: pushHistory) }
        .sheet(item: $shadowModel) { r in ShadowMapSheet(box: box, model: r, onEdit: pushHistory) }
        .sheet(isPresented: Binding(get: { newTextureCandidate != nil }, set: { if !$0 { newTextureCandidate = nil } })) {
            if let candidate = newTextureCandidate {
                NewTextureSheet(candidate: candidate) { name, format in
                    addNewTexture(name: name, image: candidate.image, width: candidate.width, height: candidate.height, format: format)
                    newTextureCandidate = nil
                }
            }
        }
    }

    private func openNormal(_ r: BRRESResource, _ mode: NormalMapSheet.Mode) {
        guard let target = NormalMapTarget.brres(box: box, resource: r, onEdit: pushHistory) else {
            addErrorMessage = "\(r.name)'s format can't be decoded, so it can't be used for a normal map."
            return
        }
        addErrorMessage = target.run(mode)
    }

    private func icon(for r: BRRESResource) -> String {
        switch r.magic {
        case "TEX0": return "photo"
        case "MDL0": return "cube.transparent"
        case "PLT0": return "swatchpalette"
        case "CHR0", "SRT0", "PAT0", "CLR0": return "play.rectangle"
        default: return "doc"
        }
    }

    /// A small decoded preview for TEX0 rows instead of always showing the same generic "photo"
    /// glyph, a real course's Textures(NW4R) folder often holds 50-100+ entries that were
    /// otherwise only distinguishable by name, which made picking the right one by eye (e.g. to
    /// match a KCL flag or MDL0 material) needlessly slow. Falls back to the plain icon for
    /// anything that doesn't decode (unsupported format, or any non-texture resource).
    @ViewBuilder
    private func thumbnail(for r: BRRESResource) -> some View {
        if r.magic == "TEX0", let v = TEX0View(r), let rgba = v.decodeRGBA(palette: box.palette(for: r)),
           let img = ImageUtil.nsImage(fromRGBA: rgba, width: v.width, height: v.height) {
            Image(nsImage: img).resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
                .background(Color.secondary.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            Image(systemName: icon(for: r)).frame(width: 16)
        }
    }

    /// NW4R's conventional per-kind folder name, keyed by a resource's own 4-byte magic, the
    /// same names this app already sees when parsing a real BRRES (see `BRRESDocument.parse`),
    /// so a resource added here lands in the folder a real Nintendo tool (or RiiStudio) would
    /// expect, and `serialize()` writes it back out correctly grouped.
    private static let folderNameForMagic: [String: String] = [
        "MDL0": "3DModels(NW4R)", "TEX0": "Textures(NW4R)", "PLT0": "Palettes(NW4R)",
        "CHR0": "AnmChr(NW4R)", "SRT0": "AnmTexSrt(NW4R)", "PAT0": "AnmTexPat(NW4R)",
        "CLR0": "AnmClr(NW4R)", "SHP0": "AnmShp(NW4R)", "SCN0": "AnmScn(NW4R)", "VIS0": "AnmVis(NW4R)",
    ]

    /// Adds a resource either from an `.obj` mesh (converted into a real MDL0 via `MDL0Writer` --
    /// see its doc comment for exactly what that means and its limits) or from an existing,
    /// already-framed BRRES sub-resource file, this app has no from-scratch TEX0 encoder, so a
    /// non-`.obj` addition still needs to already be properly framed (e.g. one raw-extracted from
    /// another `.brres` via "Extract Raw..." here, or from an external tool).
    private func addFile() {
        PanelPresenter.openFile { url in
            guard let url, let data = try? Data(contentsOf: url) else { return }
            if ModelFile.isModel(url) {
                guard let (text, sourceURL) = try? ModelFile.objSource(url) else {
                    addErrorMessage = "Couldn't read \(url.lastPathComponent) as a model."
                    return
                }
                _ = data
                let objFileName = url.deletingPathExtension().lastPathComponent
                let modelName: String
                
                if objFileName.hasSuffix("_model") {
                    // For files like "course_model.obj", use "course" as model name
                    modelName = String(objFileName.dropLast(6)) // Remove "_model"
                } else {
                    // For files like "my_track.obj", use "my_track" as model name
                    modelName = objFileName
                }
                
                guard let result = OBJToBRRES.convert(objText: text, objURL: sourceURL, modelName: modelName) else {
                    addErrorMessage = "Couldn't build a model from \(url.lastPathComponent), it has no triangles, or one of its materials covers more than \(MDL0Writer.maxVerticesPerMesh / 3) triangles (the most a single MDL0 mesh can hold)."
                    return
                }
                if !result.missingTextures.isEmpty {
                    workbench.log("Couldn't load \(result.missingTextures.count) texture image(s) referenced by the .mtl: \(result.missingTextures.joined(separator: ", ")).")
                }
                // Textures an equally-named resource already covers aren't duplicated.
                let existingNames = Set(box.doc.resources.map(\.name))
                let newTextures = result.textures.filter { !existingNames.contains($0.name) }
                box.doc.resources.append(contentsOf: newTextures)
                box.doc.resources.append(result.model)
                let appendedCount = newTextures.count + 1

                // Re-parsing after serializing isn't just bookkeeping, it's the only way to get
                // the freshly-added model's real post-round-trip identity for `selectedResourceID`.
                // If it fails, the bytes we just built don't survive this app's own parser, so
                // leaving them appended in `box.doc` (and reporting success via isDirty/history)
                // would silently hand the user a document that might not survive a real Save/reopen
                // either, roll the append back instead and say so.
                let serialized = box.doc.serialize()
                guard let newDoc = try? BRRESDocument.parse(serialized) else {
                    box.doc.resources.removeLast(appendedCount)
                    addErrorMessage = "Built a model from \(url.lastPathComponent), but it didn't survive being re-read afterward, not added. This shouldn't happen; please report it."
                    return
                }
                box.doc = newDoc
                if let parsedModel = newDoc.resources.first(where: { $0.name == modelName && $0.folderName.hasPrefix("3DModels") }) {
                    box.selectedResourceID = parsedModel.id
                }
                box.isDirty = true
                box.objectWillChange.send()
                pushHistory("Add Model")
                return
            }
            if url.pathExtension.lowercased() == "mtl" {
                guard let text = String(data: data, encoding: .utf8) else {
                    addErrorMessage = "Couldn't read \(url.lastPathComponent) as text."
                    return
                }
                var addedCount = 0
                var seenPaths = Set<String>()
                // Same encoding the .obj path uses (see `OBJToBRRES`): CMPR, capped in size.
                // A full-resolution RGBA8 texture is 4 MB and will exhaust the console's memory.
                for material in OBJImporter.parseMTL(text).values {
                    guard let path = material.diffuseTexturePath, seenPaths.insert(path).inserted else { continue }
                    let imageURL = url.deletingLastPathComponent().appendingPathComponent(path)
                    guard let imageData = try? Data(contentsOf: imageURL), let rep = NSBitmapImageRep(data: imageData),
                          let image = NSImage(contentsOf: imageURL) else { continue }
                    let (width, height) = OBJToBRRES.fittedSize(width: rep.pixelsWide, height: rep.pixelsHigh)
                    let textureName = imageURL.deletingPathExtension().lastPathComponent
                    guard let rgba = ImageUtil.rgba(from: image, width: width, height: height),
                          let tex0Data = TEX0View.building(name: textureName, rgba: rgba, width: width, height: height, format: .cmpr)
                    else { continue }
                    box.doc.resources.append(BRRESResource(name: textureName, folderName: "Textures(NW4R)", data: tex0Data))
                    addedCount += 1
                }


                if addedCount > 0 {
                    box.isDirty = true
                    box.objectWillChange.send()
                    box.selectedResourceID = box.doc.resources.last?.id
                    pushHistory("Add Textures from MTL")
                } else {
                    addErrorMessage = "No loadable diffuse textures (map_Kd) found in \(url.lastPathComponent)."
                }
                return
            }
            guard data.count >= 8 else {
                addErrorMessage = "\(url.lastPathComponent) is too small to be a valid BRRES sub-resource."
                return
            }
            let magic = data.asciiString(at: 0, length: 4)
            guard let folderName = Self.folderNameForMagic[magic] else {
                addErrorMessage = """
                \(url.lastPathComponent) doesn't start with a recognized resource magic (got \
                "\(magic)"). This adds an already-framed BRRES sub-resource (e.g. one extracted \
                from another .brres via "Extract Raw..."), or an .obj/.mtl, not an arbitrary file.
                """
                return
            }
            let name = url.deletingPathExtension().lastPathComponent
            box.doc.resources.append(BRRESResource(name: name, folderName: folderName, data: data))
            box.isDirty = true
            box.objectWillChange.send()
            box.selectedResourceID = box.doc.resources.last?.id
            pushHistory("Add Resource")
        }
    }

    /// Opens an image file and stages it in `newTextureCandidate` so `NewTextureSheet` can offer a
    /// GX format + name before actually encoding, unlike `replaceFromImage` (which reuses an
    /// *existing* TEX0's own dimensions/format), a brand-new texture has neither yet.
    private func chooseNewTexture() {
        PanelPresenter.openFile(configure: { $0.allowedContentTypes = [.png, .jpeg, .tiff, .bmp, .gif] }) { url in
            guard let url, let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data),
                  let img = NSImage(contentsOf: url) else {
                if url != nil { addErrorMessage = "Couldn't load that file as an image." }
                return
            }
            newTextureCandidate = NewTextureCandidate(
                name: url.deletingPathExtension().lastPathComponent, image: img,
                width: rep.pixelsWide, height: rep.pixelsHigh)
        }
    }

    private func addNewTexture(name: String, image: NSImage, width: Int, height: Int, format: GXTextureFormat) {
        guard let rgba = ImageUtil.rgba(from: image, width: width, height: height) else {
            addErrorMessage = "Couldn't convert that image to RGBA pixels."
            return
        }
        guard let data = TEX0View.building(name: name, rgba: rgba, width: width, height: height, format: format) else {
            addErrorMessage = "Couldn't encode a \(width)x\(height) texture in that format."
            return
        }
        box.doc.resources.append(BRRESResource(name: name, folderName: "Textures(NW4R)", data: data))
        box.isDirty = true
        box.objectWillChange.send()
        box.selectedResourceID = box.doc.resources.last?.id
        pushHistory("Add Texture")
    }

    private func extractRaw(_ resource: BRRESResource) {
        PanelPresenter.saveFile(configure: { $0.nameFieldStringValue = resource.name }) { url in
            guard let url else { return }
            try? resource.data.write(to: url, options: .atomic)
        }
    }

    private func replaceRaw(_ resource: BRRESResource) {
        PanelPresenter.openFile { url in
            guard let url, let data = try? Data(contentsOf: url) else { return }
            resource.data = data
            box.isDirty = true
            box.objectWillChange.send()
            pushHistory("Replace Raw")
        }
    }

    @ViewBuilder
    private func detail(for resource: BRRESResource) -> some View {
        switch resource.magic {
        case "TEX0":
            TextureDetailView(box: box, resource: resource, onEdit: { pushHistory("Replace Texture") })
        case "MDL0":
            MDL0DetailView(box: box, resource: resource, onEdit: { pushHistory("Edit UV Map") })
        case "SRT0":
            SRT0DetailView(box: box, resource: resource)
        case "PAT0":
            PAT0DetailView(box: box, resource: resource, onEdit: { pushHistory("Edit Texture Pattern") })
        default:
            VStack(alignment: .leading, spacing: 8) {
                Text(resource.name).font(.title3.bold())
                Text("\(resource.magic) resource. \(ByteCountFormatter.string(fromByteCount: Int64(resource.data.count), countStyle: .file))")
                    .foregroundStyle(.secondary)
                Text("No dedicated editor for this resource type yet; it round-trips byte-for-byte unedited.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// A staged image awaiting format/name confirmation before `NewTextureSheet` actually encodes it
///, see `BRRESEditorView.chooseNewTexture`.
private struct NewTextureCandidate: Identifiable {
    let id = UUID()
    let name: String
    let image: NSImage
    let width: Int
    let height: Int
}

/// Lets the user pick a GX texture format and confirm a name before encoding a brand-new TEX0
/// from `candidate.image`, unlike replacing an existing texture (which has to keep that
/// texture's own format/size), a new one has neither yet, so this is the one place that choice
/// needs making.
private struct NewTextureSheet: View {
    let candidate: NewTextureCandidate
    let onAdd: (String, GXTextureFormat) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var format: GXTextureFormat = .cmpr

    init(candidate: NewTextureCandidate, onAdd: @escaping (String, GXTextureFormat) -> Void) {
        self.candidate = candidate
        self.onAdd = onAdd
        _name = State(initialValue: candidate.name)
    }

    /// Only the formats `TextureCodec.encode` actually supports (see its doc comment), no CI4/
    /// CI8/CI14x2, since building a fresh palette isn't implemented and real MKWii course data
    /// never uses those formats anyway (confirmed against a full real-disc scan).
    private static let formats: [(GXTextureFormat, String, String)] = [
        (.cmpr, "CMPR", "Compressed, smallest size, good for most photographic textures"),
        (.rgb5a3, "RGB5A3", "16-bit colour with optional alpha, good general-purpose default"),
        (.rgba32, "RGBA32", "Full 32-bit colour, largest size, best quality"),
        (.ia8, "IA8", "8-bit greyscale + 8-bit alpha"),
        (.i8, "I8", "8-bit greyscale, no alpha"),
        (.i4, "I4", "4-bit greyscale, smallest size, no alpha"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Texture").font(.headline)
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: candidate.image).resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                    .frame(width: 96, height: 96)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Name").font(.caption).foregroundStyle(.secondary)
                        TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                    }
                    Text("\(candidate.width)\u{d7}\(candidate.height)").font(.caption).foregroundStyle(.secondary)
                    Picker("Format", selection: $format) {
                        ForEach(Self.formats, id: \.0) { fmt, label, _ in Text(label).tag(fmt) }
                    }
                    .labelsHidden()
                    Text(Self.formats.first { $0.0 == format }?.2 ?? "")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    onAdd(trimmed.isEmpty ? candidate.name : trimmed, format)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 380)
    }
}

private struct TextureDetailView: View {
    @ObservedObject var box: BRRESDocumentBox
    let resource: BRRESResource
    let onEdit: () -> Void

    @State private var showNormalMap = false

    private var view: TEX0View? { TEX0View(resource) }
    private var nsImage: NSImage? {
        guard let v = view, let rgba = v.decodeRGBA(palette: box.palette(for: resource)) else { return nil }
        return ImageUtil.nsImage(fromRGBA: rgba, width: v.width, height: v.height)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(resource.name).font(.title3.bold())
                if let v = view {
                    Text("\(v.width)x\(v.height). \(String(describing: v.format))").foregroundStyle(.secondary).font(.caption)
                }
                if let nsImage {
                    Image(nsImage: nsImage)
                        .resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 512, maxHeight: 512)
                        .background(checkerboard)
                        .border(Color.gray.opacity(0.3))
                } else {
                    Text("Couldn't decode this texture format for preview.").foregroundStyle(.secondary)
                }
                HStack {
                    Button("Export PNG...") { exportPNG() }.disabled(nsImage == nil)
                    Button("Replace from Image...") { replaceFromImage() }.disabled(view == nil)
                    Button("Normal Map...") { showNormalMap = true }.disabled(nsImage == nil)
                        .help("Add a normal map made from this texture, or apply a normal map's relief to it. Also on the right-click menu.")
                    if let editorURL = ExternalEditorPrefs.imageEditorURL {
                        Button("Open in \(editorURL.deletingPathExtension().lastPathComponent)...") { openInExternalEditor(editorURL) }
                            .disabled(nsImage == nil)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .sheet(isPresented: $showNormalMap) {
            if let target = NormalMapTarget.brres(box: box, resource: resource, onEdit: { _ in onEdit() }) { NormalMapSheet(target: target) }
        }
    }

    private var checkerboard: some View {
        Canvas { context, size in
            let s: CGFloat = 8
            var y: CGFloat = 0
            var row = 0
            while y < size.height {
                var x: CGFloat = 0
                var col = 0
                while x < size.width {
                    if (row + col) % 2 == 0 {
                        context.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(.gray.opacity(0.2)))
                    }
                    x += s; col += 1
                }
                y += s; row += 1
            }
        }
    }

    private func exportPNG() {
        guard let nsImage else { return }
        PanelPresenter.saveFile(configure: { $0.nameFieldStringValue = resource.name + ".png" }) { url in
            guard let url, let tiff = nsImage.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: url)
        }
    }

    private func replaceFromImage() {
        guard let v = view else { return }
        PanelPresenter.openFile(configure: { $0.allowedContentTypes = [.png, .jpeg, .tiff, .bmp] }) { url in
            guard let url, let img = NSImage(contentsOf: url) else { return }
            guard let rgba = ImageUtil.rgba(from: img, width: v.width, height: v.height) else { return }
            guard let newData = TEX0View.rebuilding(resource, withRGBA: rgba) else { return }
            resource.data = newData
            box.isDirty = true
            box.objectWillChange.send()
            onEdit()
        }
    }

    /// Exports this texture to a temp PNG and hands it to the app configured in Settings >
    /// External Editors. Editing there is out-of-band, there's no watch-and-reimport, so use
    /// "Replace from Image..." afterward to bring changes back in.
    private func openInExternalEditor(_ editorURL: URL) {
        guard let nsImage, let tiff = nsImage.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(resource.name + ".png")
        do {
            try png.write(to: tmp)
            NSWorkspace.shared.open([tmp], withApplicationAt: editorURL, configuration: NSWorkspace.OpenConfiguration())
        } catch {
            // Non-fatal: the export failed, nothing to open.
        }
    }
}

private struct MDL0DetailView: View {
    @ObservedObject var box: BRRESDocumentBox
    let resource: BRRESResource
    let onEdit: () -> Void

    /// Shared between the 3D preview (click a mesh to select it) and the UV editor below (which
    /// mesh's UVs are shown), clicking a polygon in the 3D view is a faster way to find the right
    /// mesh to edit than hunting for it by name in the UV editor's own picker.
    @State private var selectedMeshIndex = 0
    @State private var isUVMapExpanded = true

    private var model: MDL0Model? { MDL0Parser.parse(resource, rawFile: box.doc.rawData) }
    private var summary: MDL0Summary { MDL0Summary.scan(resource) }

    /// This model's real per-mesh textures, resolved via `MDL0Mesh.textureName` (RenderTree draw
    /// call -> material -> first TEV sampler, see `MDL0.swift`'s `parseMeshTextureLinks`), keyed
    /// by TEX0 name so `SceneKitMeshPreviewView` can look up the right one per mesh.
    private var meshTextureLookup: [String: DecodedTexture] {
        guard let model else { return [:] }
        let names = Set(model.meshes.compactMap(\.textureName))
        guard !names.isEmpty else { return [:] }
        var out: [String: DecodedTexture] = [:]
        for r in box.doc.resources where r.magic == "TEX0" && names.contains(r.name) {
            guard let v = TEX0View(r), let rgba = v.decodeRGBA(palette: box.palette(for: r)) else { continue }
            out[r.name] = ImageUtil.decodedTexture(fromRGBA: rgba, width: v.width, height: v.height)
        }
        return out
    }

    /// Fallback for when mesh geometry couldn't be parsed (see below): best-effort, since without
    /// real mesh data there are no draw calls to resolve a mesh -> material -> texture link
    /// through, so this instead shows every texture whose name appears anywhere in the model's
    /// discovered name groups, falling back to the first texture in the file if none hit.
    private var fallbackTextureImages: [NSImage] {
        let names = Set(summary.groups.flatMap(\.names))
        let candidates = box.doc.resources.filter { $0.magic == "TEX0" && names.contains($0.name) }
        let pool = candidates.isEmpty ? box.doc.resources.filter { $0.magic == "TEX0" } : candidates
        return pool.compactMap { r -> NSImage? in
            guard let v = TEX0View(r), let rgba = v.decodeRGBA(palette: box.palette(for: r)) else { return nil }
            return ImageUtil.nsImage(fromRGBA: rgba, width: v.width, height: v.height)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(resource.name).font(.title3.bold())
                Text("MDL0 model. \(ByteCountFormatter.string(fromByteCount: Int64(resource.data.count), countStyle: .file))")
                    .foregroundStyle(.secondary).font(.caption)

                if let model {
                    TrackBudgetView(model: model, resource: resource, textureBytes: box.doc.resources.filter { $0.magic == "TEX0" }.reduce(0) { $0 + $1.data.count })
                    SceneKitMeshPreviewView(model: model, textureLookup: meshTextureLookup, selectedMeshIndex: Binding(
                        get: { selectedMeshIndex },
                        set: { selectedMeshIndex = $0; isUVMapExpanded = true }
                    ))
                        .frame(minHeight: 360, maxHeight: 420)
                        .border(Color.gray.opacity(0.3))
                    let triCount = model.meshes.reduce(0) { $0 + $1.vertices.count / 3 }
                    Text("Real mesh preview: \(model.meshes.count) mesh(es), \(triCount) triangles (drag to orbit, scroll/pinch to zoom, click a mesh to select it below). Bone/skinning transforms aren't applied, so rigged characters may look slightly off in their bind pose; static geometry (most course/prop models) renders correctly. Each mesh's texture is resolved through its actual material (RenderTree draw call -> material -> first TEV sampler), not guessed by name, though only that first sampler is shown, so multi-texture TEV blending isn't reproduced.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    SceneKitPreviewView(images: fallbackTextureImages)
                        .frame(minHeight: 360, maxHeight: 420)
                        .border(Color.gray.opacity(0.3))
                    Text("Structural preview: showing this model's textures on cards in 3D space (drag to orbit, pinch to zoom). This MDL0 uses a version or vertex encoding this app's mesh extractor doesn't recognise, so it fell back to this placeholder rather than risk rendering incorrect geometry.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                if let model {
                    DisclosureGroup("Edit UV Map", isExpanded: $isUVMapExpanded) {
                        UVMapEditorView(box: box, resource: resource, model: model, textureLookup: meshTextureLookup,
                                        selectedMeshIndex: $selectedMeshIndex, onEdit: onEdit)
                    }
                    .font(.subheadline.bold())
                }

                DisclosureGroup("Discovered structure (best-effort name scan)") {
                    List {
                        ForEach(Array(summary.groups.enumerated()), id: \.offset) { _, group in
                            Section("Group @ 0x\(String(group.offset, radix: 16)) (\(group.names.count))") {
                                ForEach(group.names, id: \.self) { Text($0).font(.caption) }
                            }
                        }
                    }
                    .listStyle(.inset)
                    .frame(minHeight: 160)
                }
                .font(.subheadline.bold())
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// Drag-to-edit UV layout for one mesh, over its actual resolved texture, `MDL0Parser.uvBuffer`/
/// `writeUVBuffer` (see their doc comments) patch the real on-disk buffer in place, byte-for-byte,
/// the same "known-safe fixed-width field patch" pattern `Data.setU8`/`setBE16` already document as
/// this app's accepted approach elsewhere. Verified against a real retail `course_model.brres`
/// (22 UV buffers, read -> write-unchanged -> re-read round-tripped exactly, and a synthetic +0.1
/// edit read back correctly) before wiring this UI up to it.
private struct UVMapEditorView: View {
    @ObservedObject var box: BRRESDocumentBox
    let resource: BRRESResource
    let model: MDL0Model
    let textureLookup: [String: DecodedTexture]
    /// Shared with the 3D preview above (`MDL0DetailView.selectedMeshIndex`), selecting a mesh
    /// there jumps this editor straight to its UVs.
    @Binding var selectedMeshIndex: Int
    let onEdit: () -> Void

    private var mesh: MDL0Mesh? { model.meshes.indices.contains(selectedMeshIndex) ? model.meshes[selectedMeshIndex] : nil }

    /// Re-resolved from `box.doc` (not cached) on every access, so it always reflects the buffer's
    /// current on-disk state, including this view's own just-applied edits, which is what lets a
    /// drag see its own previous delta rather than fighting a stale snapshot.
    private var uvRef: MDL0Parser.UVBufferRef? {
        guard let mesh, let live = box.doc.resources.first(where: { $0.id == resource.id }) else { return nil }
        return MDL0Parser.uvBuffer(forMeshNamed: mesh.name, in: live, rawFile: box.doc.rawData)
    }

    private var textureImage: NSImage? {
        guard let mesh, let name = mesh.textureName else { return nil }
        return textureLookup[name]?.image
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Mesh", selection: $selectedMeshIndex) {
                ForEach(Array(model.meshes.enumerated()), id: \.offset) { i, m in
                    Text(m.name.isEmpty ? "Mesh \(i)" : m.name).tag(i)
                }
            }
            .frame(maxWidth: 260)

            if let uvRef, !uvRef.entries.isEmpty {
                let bounds = Self.bounds(of: uvRef.entries)
                Text("\(uvRef.entries.count) UV point(s), U \(String(format: "%.2f...%.2f", bounds.minU, bounds.maxU)) / V \(String(format: "%.2f...%.2f", bounds.minV, bounds.maxV)), drag a point to move it. This patches the mesh's real UV buffer in place; any other mesh sharing that buffer changes too, the same as editing it in a modelling tool would.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                GeometryReader { geo in
                    let side = min(geo.size.width, geo.size.height)
                    // UVs are routinely outside 0...1 (a tiled road/grass texture repeats many
                    // times over), so this fits the *actual* range of the mesh's own points into
                    // the canvas, not a fixed 0...1 mapping, which put every point of a tiled
                    // mesh's UVs off-screen entirely (the reported "no points to move" bug: they
                    // were there, just positioned outside the visible square).
                    ZStack(alignment: .topLeading) {
                        if let textureImage {
                            Image(nsImage: textureImage).resizable().interpolation(.none).frame(width: side, height: side)
                        } else {
                            Rectangle().fill(Color.secondary.opacity(0.15)).frame(width: side, height: side)
                        }
                        ForEach(Array(uvRef.entries.enumerated()), id: \.offset) { i, uv in
                            let p = Self.screenPoint(for: uv, bounds: bounds, side: side)
                            Circle()
                                .fill(Color.yellow)
                                .frame(width: 8, height: 8)
                                .position(x: p.x, y: p.y)
                                .gesture(DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        let uv = Self.uvPoint(forScreen: value.location, bounds: bounds, side: side)
                                        movePoint(i, to: uv, ref: uvRef)
                                    }
                                    .onEnded { _ in onEdit() }
                                )
                        }
                    }
                    .frame(width: side, height: side)
                }
                .frame(height: 260)
                .border(Color.gray.opacity(0.3))
            } else {
                Text("No readable UV channel for this mesh.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private struct UVBounds { var minU: Float; var maxU: Float; var minV: Float; var maxV: Float }

    /// The real span of this mesh's own UV points, padded 10% on every side so a point sitting
    /// exactly on the min/max edge isn't drawn half-clipped at the canvas border.
    private static func bounds(of entries: [Vec2]) -> UVBounds {
        var minU = entries[0].x, maxU = entries[0].x, minV = entries[0].y, maxV = entries[0].y
        for e in entries {
            minU = min(minU, e.x); maxU = max(maxU, e.x)
            minV = min(minV, e.y); maxV = max(maxV, e.y)
        }
        let padU = max((maxU - minU) * 0.1, 0.05), padV = max((maxV - minV) * 0.1, 0.05)
        return UVBounds(minU: minU - padU, maxU: maxU + padU, minV: minV - padV, maxV: maxV + padV)
    }

    private static func screenPoint(for uv: Vec2, bounds: UVBounds, side: CGFloat) -> CGPoint {
        let spanU = max(bounds.maxU - bounds.minU, 0.0001), spanV = max(bounds.maxV - bounds.minV, 0.0001)
        return CGPoint(x: CGFloat((uv.x - bounds.minU) / spanU) * side, y: CGFloat((uv.y - bounds.minV) / spanV) * side)
    }

    private static func uvPoint(forScreen point: CGPoint, bounds: UVBounds, side: CGFloat) -> Vec2 {
        let spanU = bounds.maxU - bounds.minU, spanV = bounds.maxV - bounds.minV
        let u = bounds.minU + Float(point.x / side) * spanU
        let v = bounds.minV + Float(point.y / side) * spanV
        return Vec2(x: u, y: v)
    }

    private func movePoint(_ index: Int, to uv: Vec2, ref: MDL0Parser.UVBufferRef) {
        guard let resIndex = box.doc.resources.firstIndex(where: { $0.id == resource.id }), ref.entries.indices.contains(index) else { return }
        var newValues = ref.entries
        newValues[index] = uv
        var data = box.doc.resources[resIndex].data
        MDL0Parser.writeUVBuffer(ref, newValues: newValues, into: &data)
        box.doc.resources[resIndex].data = data
        box.isDirty = true
        box.objectWillChange.send()
    }
}

/// AnmTexSrt(NW4R) preview: a frame scrubber per material, showing the resolved Scale/Rotate/
/// Translate numerically and, when a sibling MDL0 in this same BRRES links that material to a real
/// texture, a live visual approximation of the UV transform applied to it, see `SRT0.swift`'s top
/// doc comment for exactly how much of the real format this reads, and `SRT0Document.value(of:at:)`
/// for why the interpolation (and so this preview) is an approximation, not bit-exact with the game.
private struct SRT0DetailView: View {
    @ObservedObject var box: BRRESDocumentBox
    let resource: BRRESResource

    @State private var frame: Float = 0
    @State private var selectedMaterialIndex = 0
    /// A user-picked texture to preview the animation against, when no texture auto-resolves (or
    /// the auto-resolved one just isn't the one worth looking at), keyed by material index so
    /// switching materials doesn't leave a stale override from a different one applied.
    @State private var textureOverride: [Int: String] = [:]

    private var doc: SRT0Document? { SRT0Document.parse(resource, rawFile: box.doc.rawData) }

    /// Material name -> its first texture's name, from whichever MDL0 in this same BRRES actually
    /// uses that material. SRT0 doesn't carry texture names of its own, only material names, the
    /// same indirection `MDL0Mesh.textureName` already resolves for the 3D preview.
    private var materialTextures: [String: String] {
        var out: [String: String] = [:]
        for r in box.doc.resources where r.magic == "MDL0" {
            for m in MDL0Parser.materials(in: r, rawFile: box.doc.rawData) where out[m.name] == nil {
                if let first = m.textureNames.first { out[m.name] = first }
            }
        }
        return out
    }

    private var textureImages: [String: NSImage] {
        var out: [String: NSImage] = [:]
        for r in box.doc.resources where r.magic == "TEX0" {
            guard let v = TEX0View(r), let rgba = v.decodeRGBA(palette: box.palette(for: r)),
                  let img = ImageUtil.nsImage(fromRGBA: rgba, width: v.width, height: v.height) else { continue }
            out[r.name] = img
        }
        return out
    }

    var body: some View {
        if let doc, !doc.materials.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(resource.name).font(.title3.bold())
                Text("AnmTexSrt (NW4R): animates a material's texture coordinates (scale/rotate/translate) over time. This preview linearly interpolates between keyframes as an approximation of the game's own curve, not a bit-exact reproduction.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                Picker("Material", selection: $selectedMaterialIndex) {
                    ForEach(Array(doc.materials.enumerated()), id: \.offset) { i, m in
                        Text(m.name).tag(i)
                    }
                }
                .frame(maxWidth: 260)
                .onChange(of: selectedMaterialIndex) { frame = 0 }

                if doc.materials.indices.contains(selectedMaterialIndex) {
                    let material = doc.materials[selectedMaterialIndex]
                    HStack {
                        Text("Frame").font(.caption)
                        Slider(value: $frame, in: 0...max(doc.maxFrame, 1))
                        Text("\(Int(frame)) / \(Int(doc.maxFrame))").font(.caption.monospacedDigit()).frame(width: 60)
                    }

                    if let matrix = material.matrices.first {
                        let scaleU = doc.value(of: matrix.targets.scaleU, at: frame)
                        let scaleV = matrix.targets.scaleV.map { doc.value(of: $0, at: frame) } ?? scaleU
                        let rotate = doc.value(of: matrix.targets.rotate, at: frame)
                        let transU = doc.value(of: matrix.targets.transU, at: frame)
                        let transV = doc.value(of: matrix.targets.transV, at: frame)

                        Text(String(format: "Scale %.3f, %.3f   Rotate %.1f\u{00B0}   Translate %.3f, %.3f", scaleU, scaleV, rotate, transU, transV))
                            .font(.caption.monospaced()).foregroundStyle(.secondary)

                        let resolvedName = textureOverride[selectedMaterialIndex] ?? materialTextures[material.name]
                        HStack {
                            Text("Preview texture").font(.caption).foregroundStyle(.secondary)
                            Picker("", selection: Binding(
                                get: { resolvedName ?? "" },
                                set: { textureOverride[selectedMaterialIndex] = $0 }
                            )) {
                                if resolvedName == nil { Text("None").tag("") }
                                ForEach(textureImages.keys.sorted(), id: \.self) { name in
                                    Text(name).tag(name)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 220)
                        }
                        if materialTextures[material.name] == nil {
                            Text("No texture auto-resolved for material \"\(material.name)\" in this BRRES, pick one above to preview the animation on it anyway.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }

                        if let name = resolvedName, let image = textureImages[name] {
                            GeometryReader { geo in
                                let side = min(geo.size.width, geo.size.height)
                                Image(nsImage: image)
                                    .resizable().interpolation(.none)
                                    .frame(width: side, height: side)
                                    .scaleEffect(x: CGFloat(scaleU), y: CGFloat(scaleV))
                                    .rotationEffect(.degrees(Double(rotate)))
                                    .offset(x: CGFloat(-transU) * side, y: CGFloat(transV) * side)
                                    .frame(width: geo.size.width, height: geo.size.height)
                                    .clipped()
                                    .background(Color.secondary.opacity(0.1))
                            }
                            .frame(height: 220)
                        } else {
                            Text("This BRRES has no textures to preview with.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(resource.name).font(.title3.bold())
                Text("AnmTexSrt(NW4R) resource. \(ByteCountFormatter.string(fromByteCount: Int64(resource.data.count), countStyle: .file))")
                    .foregroundStyle(.secondary)
                Text("Couldn't find any readable material/matrix/track data in this SRT0; it round-trips byte-for-byte unedited.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// Triangle/vertex/mesh/texture counts next to what retail tracks use (see `TrackBudget`).
struct TrackBudgetView: View {
    let values: [TrackBudget.Metric: Int]
    let defaultKind: TrackBudget.Kind
    var game: TrackBudget.Game = .marioKartWii
    @State private var kind: TrackBudget.Kind?

    /// A Wii MDL0's figures.
    init(model: MDL0Model, resource: BRRESResource, textureBytes: Int) {
        values = [.triangles: model.meshes.reduce(0) { $0 + $1.vertices.count / 3 },
                  // The model's own vertex count (info block), what the GPU actually transforms.
                  .vertices: resource.data.count >= 0x60 ? Int(resource.data.be32(0x5C)) : model.meshes.reduce(0) { $0 + $1.vertices.count },
                  .meshes: model.meshes.count, .textureKB: textureBytes / 1024]
        defaultKind = TrackBudget.Kind(modelName: resource.name) ?? .course
    }

    /// A Double Dash model's (see `TrackBudget.j3dMetrics`).
    init(doubleDash values: [TrackBudget.Metric: Int], fileName: String) {
        self.values = values
        defaultKind = fileName.lowercased().contains("_sky") ? .skybox : .course
        game = .doubleDash
    }

    private var effectiveKind: TrackBudget.Kind { kind ?? defaultKind }
    private var kinds: [TrackBudget.Kind] { game == .doubleDash ? [.course, .skybox] : TrackBudget.Kind.allCases }
    private func value(_ metric: TrackBudget.Metric) -> Int { values[metric] ?? 0 }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Track Budget").font(.headline)
                    Spacer()
                    Picker("Compare as", selection: Binding(get: { effectiveKind }, set: { kind = $0 })) {
                        ForEach(kinds) { Text($0.rawValue).tag($0) }
                    }
                    .fixedSize()
                    .help("Which kind of retail model to compare against. Picked from the model's name (course, vrcorn, map) when it's one the game looks for.")
                }
                ForEach(TrackBudget.Metric.allCases, id: \.self) { metric in
                    let ref = TrackBudget.reference(effectiveKind, metric, game: game)
                    if ref.max > 0 { row(metric, value: value(metric), ref: ref) }
                }
                let worst = TrackBudget.Metric.allCases.filter { TrackBudget.reference(effectiveKind, $0, game: game).max > 0 }
                    .map { TrackBudget.rate(value($0), effectiveKind, $0, game: game) }.max() ?? .typical
                Text(advice(worst))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(4)
        }
    }

    private func row(_ metric: TrackBudget.Metric, value: Int, ref: (median: Int, max: Int)) -> some View {
        let rating = TrackBudget.rate(value, effectiveKind, metric, game: game)
        let color: Color = switch rating { case .typical: .green; case .withinRetail: .teal; case .overRetail: .orange; case .farOver: .red }
        let scaleMax = Double(max(ref.max * 2, value, 1))
        let unit = metric == .textureKB ? " KB" : ""
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(metric.rawValue).font(.caption.bold())
                Spacer()
                Text("\(value.formatted())\(unit)").font(.caption.monospacedDigit().bold()).foregroundStyle(color)
                Text("retail median \(ref.median.formatted()), max \(ref.max.formatted())\(unit)").font(.caption2).foregroundStyle(.secondary)
            }
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(color).frame(width: max(3, w * min(1, Double(value) / scaleMax)))
                    // Ticks at the retail median and maximum.
                    Rectangle().fill(Color.primary.opacity(0.5)).frame(width: 1).offset(x: w * Double(ref.median) / scaleMax)
                    Rectangle().fill(Color.primary).frame(width: 2).offset(x: w * Double(ref.max) / scaleMax)
                }
            }
            .frame(height: 6)
            .help("\(rating.label). Thin tick: the median retail \(effectiveKind.rawValue.lowercased()); thick tick: the heaviest retail one.")
        }
    }

    private func advice(_ worst: TrackBudget.Rating) -> String {
        switch worst {
        case .typical, .withinRetail:
            return "Within what Nintendo's own tracks use (measured from all 37 retail race and battle courses), so it should run like one."
        case .overRetail:
            return "Heavier than any retail track. It may still run, but expect frame drops in 2-4 player split-screen. Merge meshes that share a material, decimate distant or hidden geometry, and shrink textures that don't need full resolution."
        case .farOver:
            return "Over twice the heaviest retail track: very likely to lag and can run out of memory and crash. Reduce it before testing on real hardware, decimate, merge meshes by material, and downsize textures."
        }
    }
}

/// AnmTexPat(NW4R): which texture each material's sampler shows from which frame, with a
/// playable preview. Every edit rebuilds the PAT0 (`PAT0Animation.build`) and re-reads the BRRES.
private struct PAT0DetailView: View {
    @ObservedObject var box: BRRESDocumentBox
    let resource: BRRESResource
    let onEdit: () -> Void

    @State private var materialIndex = 0
    @State private var samplerIndex = 0
    @State private var scrub: Float = 0
    @State private var playing = true
    @State private var error: String?

    private var anim: PAT0Animation? { PAT0Animation.parse(resource, rawFile: box.doc.rawData) }
    private var textureNames: [String] { box.doc.resources.filter { $0.magic == "TEX0" }.map(\.name) }

    /// Decoded frames, so the playing preview doesn't decode a texture 60 times a second. Keyed by
    /// resource identity: an edit re-reads the BRRES into new resources.
    private final class FrameCache { var images: [ObjectIdentifier: NSImage] = [:] }
    @State private var frames = FrameCache()

    private func image(_ name: String) -> NSImage? {
        guard let r = box.doc.resources.first(where: { $0.magic == "TEX0" && $0.name == name }) else { return nil }
        if let cached = frames.images[ObjectIdentifier(r)] { return cached }
        guard let v = TEX0View(r), let rgba = v.decodeRGBA(palette: box.palette(for: r)),
              let img = ImageUtil.nsImage(fromRGBA: rgba, width: v.width, height: v.height) else { return nil }
        frames.images[ObjectIdentifier(r)] = img
        return img
    }

    var body: some View {
        if let anim {
            VStack(alignment: .leading, spacing: 12) {
                Text(resource.name).font(.title3.bold())
                Text("AnmTexPat (NW4R): swaps which texture a material draws on a frame schedule (flipbook water, flashing signs, screens). The game plays a model's same-named animation automatically.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    Stepper("Length: \(anim.frameCount) frames (\(String(format: "%.2f", Double(anim.frameCount) / 60)) s)",
                            value: Binding(get: { anim.frameCount }, set: { v in edit { $0.frameCount = v } }), in: 1...0xFFFF)
                    Toggle("Loop", isOn: Binding(get: { anim.loops }, set: { v in edit { $0.loops = v } }))
                }
                if anim.materials.isEmpty {
                    Text("This animation targets no materials.").foregroundStyle(.secondary)
                } else {
                    let m = min(materialIndex, anim.materials.count - 1)
                    let material = anim.materials[m]
                    HStack {
                        Picker("Material", selection: $materialIndex) {
                            ForEach(Array(anim.materials.enumerated()), id: \.offset) { Text($0.element.name).tag($0.offset) }
                        }
                        .frame(maxWidth: 260)
                        .onChange(of: materialIndex) { samplerIndex = 0 }
                        if material.samplers.count > 1 {
                            Picker("Sampler", selection: $samplerIndex) {
                                ForEach(Array(material.samplers.enumerated()), id: \.offset) { Text("\($0.element.slot)").tag($0.offset) }
                            }
                            .frame(maxWidth: 140)
                        }
                    }
                    if !material.samplers.isEmpty {
                        let s = min(samplerIndex, material.samplers.count - 1)
                        HStack(alignment: .top, spacing: 16) {
                            keyList(anim, m, s)
                            preview(anim, keys: material.samplers[s].keys)
                        }
                    }
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Text("\(resource.name) couldn't be read as a PAT0 v4 animation; it round-trips byte-for-byte unedited.")
                .foregroundStyle(.secondary).padding()
        }
    }

    private func keyList(_ anim: PAT0Animation, _ m: Int, _ s: Int) -> some View {
        let keys = anim.materials[m].samplers[s].keys
        return VStack(alignment: .leading, spacing: 6) {
            Text("Keys (each holds until the next)").font(.caption.bold())
            List {
                ForEach(Array(keys.enumerated()), id: \.offset) { k, key in
                    HStack {
                        Text("Frame").font(.caption)
                        TextField("", value: Binding(get: { Int(key.frame) }, set: { v in editKeys(m, s) { $0[k].frame = Float(max(0, v)) } }), format: .number)
                            .frame(width: 60)
                        Picker("", selection: Binding(get: { anim.textureNames.indices.contains(key.texture) ? anim.textureNames[key.texture] : "" },
                                                      set: { name in edit { a in
                                                          let t = a.textureNames.firstIndex(of: name) ?? { a.textureNames.append(name); return a.textureNames.count - 1 }()
                                                          a.materials[m].samplers[s].keys[k].texture = t
                                                      } })) {
                            ForEach(Array(Set(textureNames + anim.textureNames)).sorted(), id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        Button { editKeys(m, s) { $0.remove(at: k) } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).disabled(keys.count <= 1)
                    }
                }
            }
            .frame(width: 380, height: 240)
            .border(Color.gray.opacity(0.3))
            Button("Add Key") {
                editKeys(m, s) { k in
                    let last = k.last ?? PAT0Animation.Key(frame: 0, texture: 0)
                    k.append(PAT0Animation.Key(frame: min(Float(anim.frameCount - 1), last.frame + 1), texture: last.texture))
                }
            }
        }
    }

    private func preview(_ anim: PAT0Animation, keys: [PAT0Animation.Key]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TimelineView(.animation(paused: !playing)) { ctx in
                let frame = playing ? Float((ctx.date.timeIntervalSinceReferenceDate * 60).truncatingRemainder(dividingBy: Double(max(1, anim.frameCount)))) : scrub
                let t = PAT0Animation.texture(at: frame.rounded(.down), keys: keys)
                let name = t.flatMap { anim.textureNames.indices.contains($0) ? anim.textureNames[$0] : nil }
                VStack(alignment: .leading, spacing: 4) {
                    Group {
                        if let name, let img = image(name) { Image(nsImage: img).resizable().interpolation(.none).aspectRatio(contentMode: .fit) }
                        else { Color.secondary.opacity(0.1) }
                    }
                    .frame(width: 200, height: 200)
                    .border(Color.gray.opacity(0.3))
                    Text("Frame \(Int(frame)): \(name ?? "missing texture")").font(.caption.monospacedDigit())
                }
            }
            HStack {
                Button { playing.toggle() } label: { Image(systemName: playing ? "pause.fill" : "play.fill") }
                Slider(value: Binding(get: { scrub }, set: { scrub = $0; playing = false }), in: 0...Float(max(1, anim.frameCount - 1)))
            }
            .frame(width: 200)
        }
    }

    private func editKeys(_ m: Int, _ s: Int, _ change: @escaping (inout [PAT0Animation.Key]) -> Void) {
        edit { a in
            change(&a.materials[m].samplers[s].keys)
            a.materials[m].samplers[s].keys.sort { $0.frame < $1.frame }
        }
    }

    /// Rebuilds the PAT0 with `change` applied and re-reads the whole BRRES, so its names land in
    /// the string pool exactly as a save will write them.
    private func edit(_ change: (inout PAT0Animation) -> Void) {
        guard var a = anim, let index = box.doc.resources.firstIndex(where: { $0 === resource }) else { return }
        change(&a)
        let built = a.build()
        let old = box.doc.resources[index]
        box.doc.resources[index] = BRRESResource(name: old.name, folderName: old.folderName, data: built.data, stringReferences: built.strings)
        guard let reparsed = try? BRRESDocument.parse(box.doc.serialize()) else {
            box.doc.resources[index] = old
            error = "That edit didn't survive being re-read, so it wasn't made. Please report this."
            return
        }
        error = nil
        box.doc = reparsed
        box.selectedResourceID = reparsed.resources.first { $0.magic == "PAT0" && $0.name == old.name }?.id
        box.isDirty = true
        onEdit()
    }
}
