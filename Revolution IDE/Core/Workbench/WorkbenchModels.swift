import Foundation
import Combine
import AppKit
import simd

/// What kind of editor a tab hosts. `.szs` archives and NSMBW levels both open as a tab by
/// default now, same as every other file, "Open in New Window" is still available via
/// right-click for whoever wants a dedicated-window layout (see `SZSWindowSession`/
/// `NSMBWWindowSession` and their `*WindowView`s, and `WorkbenchState.openArchiveAsTab` vs
/// `openArchiveInNewWindow`).
enum EditorPayload {
    case kmp(KMPDocumentBox)
    case brres(BRRESDocumentBox)
    case bmg(BMGDocumentBox)
    case tpl(TPLDocumentBox)
    case kcl(KCLDocumentBox)
    case szs(SZSDocumentBox)
    case nsmbwLevel(NSMBWDocumentBox)
    case brstm(BRSTMDocumentBox)
    case brlyt(BRLYTDocumentBox)
    case brlan(BRLANDocumentBox)
    case brsar(BRSARDocumentBox)
    case j3d(J3DDocumentBox)
    case j3dAnimation(J3DAnimationDocumentBox)
    case code(CodeDocumentBox)
    case raw(RawDocumentBox)
    case obj(OBJDocumentBox)
    case mtl(MTLDocumentBox)
    case uiDesign(UIDesignBox)
    case nodeGraph(NodeGraphBox)
    case image(ImageDocumentBox)
    case fields(BinaryFieldsBox)
    case effect(EffectDocumentBox)
    /// Placeholder shown while `WorkbenchState.resolvePayload` parses this file's bytes on a
    /// background thread, see `EditorTab.finishLoading`. Never produced by `resolvePayload`
    /// itself, only ever set as a tab's initial payload before that call resolves.
    case loading
}

/// Thin ObservableObject wrappers around the plain (nonisolated) format model classes, so SwiftUI
/// views can bind to them directly with @ObservedObject.
@MainActor final class SZSDocumentBox: ObservableObject {
    @Published var root: U8Node
    @Published var isDirty = false
    var wasCompressed: Bool
    /// Set when this box was parsed just to open one entry from a closed archive on disk (no tab or
    /// window shows the archive itself), so saving that entry writes the archive straight back here.
    var fileURL: URL?
    init(root: U8Node, wasCompressed: Bool) { self.root = root; self.wasCompressed = wasCompressed }
}

/// One `.szs`/`.arc` archive open in its own dedicated window. Kept in
/// `WorkbenchState.szsWindowSessions`, keyed by `id`, so the `WindowGroup(for: UUID.self)` in
/// `RevolutionIDEApp` can look it up regardless of which window it's actually shown in.
@MainActor final class SZSWindowSession: ObservableObject, Identifiable {
    let id = UUID()
    @Published var box: SZSDocumentBox
    @Published var title: String
    var source: EditorTab.Source
    init(box: SZSDocumentBox, title: String, source: EditorTab.Source) {
        self.box = box; self.title = title; self.source = source
    }
}

/// One New Super Mario Bros. Wii level (a level archive is detected by its contents, a `course`
/// folder with `courseN.bin` files, not its extension, since it's the same U8 container
/// `.szs`/`.arc` already use). Opens as a tab by default like everything else; see
/// `NSMBWWindowSession` for the dedicated-window path. See `NSMBWLevel.swift`.
@MainActor final class NSMBWDocumentBox: ObservableObject {
    @Published var doc: NSMBWLevelDocument
    @Published var isDirty = false
    @Published var selectedAreaIndex = 0
    /// The U8 tree this level was parsed from, and whether that container was LZ77-compressed --
    /// kept so saving can write the edited areas back into it (and back into whichever archive
    /// format it came from) without re-deriving the U8 container from scratch. Not `@Published`:
    /// nothing in the UI observes these directly, only `doc`/`isDirty`.
    var root: U8Node
    var wasCompressed: Bool
    init(doc: NSMBWLevelDocument, root: U8Node, wasCompressed: Bool) {
        self.doc = doc; self.root = root; self.wasCompressed = wasCompressed
    }
}

/// The same NSMBW level as `NSMBWDocumentBox`, opened in its own dedicated window instead of a
/// tab (the explicit "Open in New Window" path, see `WorkbenchState.openArchiveInNewWindow`).
@MainActor final class NSMBWWindowSession: ObservableObject, Identifiable {
    let id = UUID()
    @Published var box: NSMBWDocumentBox
    @Published var title: String
    var source: EditorTab.Source
    init(box: NSMBWDocumentBox, title: String, source: EditorTab.Source) {
        self.box = box; self.title = title; self.source = source
    }
}

/// A "Preview Track" (`TrackPreviewView`) shown in its own dedicated window instead of a sheet --
/// lets it carry real window chrome (a title bar, its own menu-bar-adjacent toolbar) and be sized/
/// moved/kept open independently of the Workbench window, the same reasoning `NSMBWWindowSession`/
/// `SZSWindowSession` already apply to their own dedicated-window cases.
@MainActor final class TrackPreviewWindowSession: ObservableObject, Identifiable {
    let id = UUID()
    let request: TrackPreviewRequest
    init(request: TrackPreviewRequest) { self.request = request }
}

@MainActor final class KMPDocumentBox: ObservableObject {
    @Published var doc: KMPDocument
    @Published var isDirty = false
    @Published var selection: KMPSelection?
    init(doc: KMPDocument) { self.doc = doc }
}

@MainActor final class BRRESDocumentBox: ObservableObject {
    @Published var doc: BRRESDocument
    @Published var isDirty = false
    @Published var selectedResourceID: BRRESResource.ID?
    /// The file this was opened from, when there is one. Mario Kart Wii requires the MDL0 inside
    /// e.g. `course_model.brres` to be named `course`, so importing an `.obj` needs to know what
    /// container it is landing in (see `OBJToBRRES.requiredModelNames`).
    let fileName: String?
    init(doc: BRRESDocument, fileName: String? = nil) { self.doc = doc; self.fileName = fileName }

    /// TEX0 textures using an indexed format (CI4/CI8) store no color data of their own, their
    /// pixels are indices into a sibling PLT0 resource, which Nintendo's own tools (and every
    /// BRRES this app has seen) name identically to the texture it belongs to.
    func palette(for resource: BRRESResource) -> [(UInt8, UInt8, UInt8, UInt8)]? {
        guard let plt0 = doc.resources.first(where: { $0.magic == "PLT0" && $0.name == resource.name }) else { return nil }
        return PLT0View(plt0)?.entries
    }
}

@MainActor final class BMGDocumentBox: ObservableObject {
    @Published var doc: BMGDocument
    @Published var isDirty = false
    init(doc: BMGDocument) { self.doc = doc }
}

/// TPL is view/export-only for now (no re-encoder), so `serialize()` just hands back the bytes
/// it was parsed from unchanged, `isDirty` never becomes true since nothing here mutates it.
@MainActor final class TPLDocumentBox: ObservableObject {
    @Published var doc: TPLDocument
    @Published var selectedIndex: Int?
    let rawData: Data
    init(doc: TPLDocument, rawData: Data) { self.doc = doc; self.rawData = rawData }
}

/// Wraps a `.kcl` collision mesh; see `KCLEditorView` for the per-triangle attribute editing this
/// supports.
@MainActor final class KCLDocumentBox: ObservableObject {
    @Published var doc: KCLDocument
    @Published var isDirty = false
    /// A source model to run through the editor's material-review sheet as soon as it appears
    /// (set by `WorkbenchState.newKCLFromOBJ`).
    var pendingOBJURL: URL?
    /// Each imported material's texture (from the model's .mtl), keyed by `KCLTriangle.material`.
    @Published var materialTextures: [String: NSImage] = [:]
    /// Per-base-type reference textures, purely an editing aid (KCL itself carries no texture
    /// data, so this never gets written to the `.kcl` file) to help match a collision surface type
    /// to what the actual track looks like there. Keyed by base surface type (`attribute & 0x1F`)
    ///, this is the "default for the whole flag" texture. Session-only, not persisted, same as
    /// `KMPEditorView`'s course-model background.
    @Published var flagTextures: [UInt16: NSImage] = [:]
    @Published var flagTextureLabels: [UInt16: String] = [:]
    /// Per-*exact*-attribute texture overrides, keyed by the full 16-bit collision flag rather than
    /// just its base type, lets two triangles that share one base flag (e.g. two different "Road"
    /// variants) carry distinct reference textures and show up as separate rows in
    /// `KCLEditorView`'s surface-type list instead of being bundled into one. Only ever contains
    /// entries the user explicitly linked (from the per-triangle "Edit Triangle" panel), so unlike
    /// grouping every triangle by its full attribute (see `KCLEditorView.surfaceRows`'s doc comment
    /// for why that blew up to hundreds of rows/scene nodes on a real track), this stays bounded by
    /// how many overrides someone actually creates.
    @Published var flagTextureOverrides: [UInt16: NSImage] = [:]
    @Published var flagTextureOverrideLabels: [UInt16: String] = [:]
    init(doc: KCLDocument) { self.doc = doc }
}

/// A `.brlyt` UI layout, pane transforms are editable (patched in place into
/// `doc.rawData`, see `BRLYTDocument`'s doc comment), materials/textures/groups are reference-only.
@MainActor final class BRLYTDocumentBox: ObservableObject {
    @Published var doc: BRLYTDocument
    @Published var isDirty = false
    @Published var selectedPaneID: BRLYTPane.ID?
    init(doc: BRLYTDocument) { self.doc = doc }
}

/// A `.brlan` layout animation, view-only (see `BRLANDocument`'s doc comment for why).
@MainActor final class BRLANDocumentBox: ObservableObject {
    let doc: BRLANDocument
    let rawData: Data
    init(doc: BRLANDocument, rawData: Data) { self.doc = doc; self.rawData = rawData }
}

/// A fixed-layout binary file (`.bblm`/`.bdof`/`.blight`/`.blmap`/`.bmm`) edited field by field
/// in place, see `BinaryFieldSchema`. Saving writes `data` back unchanged apart from the edits.
@MainActor final class BinaryFieldsBox: ObservableObject {
    @Published var data: Data
    @Published var isDirty = false
    let title: String
    let summary: String
    let fields: [BinaryField]
    init?(fileName: String, data: Data) {
        let data = Data(data)
        guard let schema = BinaryFieldSchema.fields(fileName: fileName, data: data) else { return nil }
        self.data = data
        title = schema.title
        summary = schema.summary
        fields = schema.fields
    }
}

/// A `.breff` particle effect, view-only list of its emitters and the textures they draw.
@MainActor final class EffectDocumentBox: ObservableObject {
    let doc: REFFDocument
    let rawData: Data
    init(doc: REFFDocument, rawData: Data) { self.doc = doc; self.rawData = rawData }
}

/// A `.brsar` sound archive, view-only (see `BRSARDocument`'s doc comment for why).
@MainActor final class BRSARDocumentBox: ObservableObject {
    let doc: BRSARDocument
    let rawData: Data
    init(doc: BRSARDocument, rawData: Data) { self.doc = doc; self.rawData = rawData }
}

/// A GameCube J3D model (`.bmd`/`.bdl`), view-only: previewed through the same Wii conversion
/// the track viewer uses (`J3DToWii`), with its TEX1 textures listed like a `.tpl`'s.
@MainActor final class J3DDocumentBox: ObservableObject {
    let model: J3DModel.Model
    let preview: MDL0Model?
    let textureLookup: [String: DecodedTexture]
    let textures: TPLDocumentBox
    let rawData: Data
    /// Track-budget figures, worked out once while the file opens: re-parsing the whole model on
    /// every redraw froze the window on a big course.
    let metrics: [TrackBudget.Metric: Int]?
    init(model: J3DModel.Model, preview: MDL0Model?, textureLookup: [String: DecodedTexture], textures: TPLDocument, rawData: Data, metrics: [TrackBudget.Metric: Int]?) {
        self.metrics = metrics
        self.model = model; self.preview = preview; self.textureLookup = textureLookup
        self.textures = TPLDocumentBox(doc: textures, rawData: Data()); self.rawData = rawData
    }
}

/// A GameCube J3D animation (`.btk`/`.bca`), view-only (see `J3DAnimation`).
@MainActor final class J3DAnimationDocumentBox: ObservableObject {
    let animation: J3DAnimation.Animation
    let rawData: Data
    /// The model a `.btk` animates (a `.bmd`/`.bdl` beside it), for the live preview's textures.
    var model: J3DModel.Model?
    /// `model`'s TEX1 textures, decoded, by index.
    var textureImages: [NSImage?] = []
    init(animation: J3DAnimation.Animation, rawData: Data) { self.animation = animation; self.rawData = rawData }
}

/// A `.brstm` streamed music track. Edits go straight into `doc`; anything that changes the audio
/// (samples, loop, length) calls `audioChanged()`, which re-encodes in the background so Save is
/// instant, and if Save comes first, `BRSTMDocument.serialize()` just encodes synchronously.
@MainActor final class BRSTMDocumentBox: ObservableObject {
    let doc: BRSTMDocument
    @Published var isDirty = false
    @Published private(set) var isEncoding = false
    /// Per-channel (min, max) peaks over `peakBuckets` equal slices of the full sample range --
    /// the waveform view draws from these instead of scanning millions of samples per frame.
    @Published private(set) var peaks: [[(Int16, Int16)]] = []
    static let peakBuckets = 4096
    private var encodeGeneration = 0

    /// Set when this is a plain audio file (MP3/WAV/AIFF...) opened for preview: the original is
    /// never overwritten, edits apply to the BRSTM exported from it (see `BRSTMEditorView`).
    let sourceAudioName: String?
    /// The file's own bytes, which Save writes back unchanged for a plain audio file.
    let rawData: Data

    init(doc: BRSTMDocument, rawData: Data, sourceAudioName: String? = nil) {
        self.doc = doc
        self.rawData = rawData
        self.sourceAudioName = sourceAudioName
        rebuildPeaks()
    }

    /// Anything that doesn't change the encoded audio (track volume/pan).
    func edited() {
        if sourceAudioName == nil { isDirty = true }
        objectWillChange.send()
    }

    func audioChanged(samplesChanged: Bool = false) {
        doc.encoded = nil
        if samplesChanged { rebuildPeaks() }
        edited()
        encodeGeneration += 1
        let generation = encodeGeneration
        let (samples, codec, looping, loopStart, total) = (doc.channelSamples, doc.codec, doc.looping, doc.loopStartSample, doc.totalSamples)
        isEncoding = true
        Task.detached(priority: .userInitiated) {
            // Debounce: dragging a loop marker fires this every frame.
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard await self.encodeGeneration == generation else { return }
            let result = BRSTMDocument.encode(samples, codec: codec, looping: looping, loopStart: loopStart, totalSamples: total)
            await MainActor.run {
                guard self.encodeGeneration == generation else { return }
                self.doc.encoded = result
                self.isEncoding = false
            }
        }
    }

    /// Puts the document back to a snapshot (a whole `.brstm` file) for undo/redo.
    func restore(_ data: Data) {
        guard let parsed = try? BRSTMDocument.parse(data) else { return }
        encodeGeneration += 1 // drop any encode still running for the state being replaced
        isEncoding = false
        doc.codec = parsed.codec; doc.looping = parsed.looping; doc.sampleRate = parsed.sampleRate
        doc.loopStartSample = parsed.loopStartSample; doc.totalSamples = parsed.totalSamples
        doc.tracks = parsed.tracks; doc.adpcmParams = parsed.adpcmParams
        doc.channelSamples = parsed.channelSamples; doc.encoded = parsed.encoded
        rebuildPeaks()
        edited()
    }

    private func rebuildPeaks() {
        let n = Self.peakBuckets
        peaks = doc.channelSamples.map { samples in
            guard !samples.isEmpty else { return [] }
            return (0..<n).map { b in
                let lo = samples.count * b / n, hi = max(lo + 1, samples.count * (b + 1) / n)
                var mn = Int16.max, mx = Int16.min
                for s in samples[lo..<min(hi, samples.count)] { mn = min(mn, s); mx = max(mx, s) }
                return (mn, mx)
            }
        }
    }
}

/// A recognized source/text file (see `CodeLanguage`), edited via `CodeEditorView` with real
/// text editing plus this app's lightweight syntax highlighting, as opposed to `.raw`, which is
/// the read-only hex-dump fallback for unrecognized/binary data.
@MainActor final class CodeDocumentBox: ObservableObject {
    @Published var text: String
    @Published var isDirty = false
    let language: CodeLanguage
    init(text: String, language: CodeLanguage) { self.text = text; self.language = language }
}

@MainActor final class RawDocumentBox: ObservableObject {
    @Published var data: Data
    @Published var isDirty = false
    init(data: Data) { self.data = data }
}

/// A plain Wavefront `.obj` reference mesh, view-only (this app doesn't write .obj), same stance
/// as `.tpl`/`.brstm`/`.brlan`/`.brsar`. Parsed once into an `MDL0Model` (real vertex/triangle
/// data, no textures, `OBJImporter` doesn't read them) so `OBJEditorView` can reuse the exact
/// same real-geometry SceneKit preview the BRRES model viewer uses, rather than a second renderer.
@MainActor final class OBJDocumentBox: ObservableObject {
    let model: MDL0Model?
    let triangleCount: Int
    let rawData: Data
    /// Each material's `map_Kd` image (or a `Kd` colour swatch) from the companion .mtl, keyed by
    /// material name, which is also each mesh's `textureName`.
    let textureLookup: [String: DecodedTexture]
    let missingTextures: [String]

    /// `objURL` locates the `mtllib` file(s) and their textures; nil (an .obj inside an archive)
    /// shows the plain mesh.
    init(text: String, rawData: Data, objURL: URL? = nil) {
        let triangles = OBJImporter.parse(text)
        triangleCount = triangles.count
        self.rawData = rawData
        let materials = objURL.map { OBJImporter.loadMTLMaterials(objText: text, objURL: $0) } ?? [:]
        let folder = objURL?.deletingLastPathComponent()
        var lookup: [String: DecodedTexture] = [:], missing: [String] = []
        for (name, m) in materials {
            if let path = m.diffuseTexturePath, let folder {
                let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path)
                if let image = NSImage(contentsOf: url) {
                    // A PNG with an alpha channel isn't necessarily see-through: look at its texels.
                    let w = min(1024, max(1, Int(image.size.width))), h = min(1024, max(1, Int(image.size.height)))
                    let scan = ImageUtil.rgba(from: image, width: w, height: h).flatMap { ImageUtil.decodedTexture(fromRGBA: $0, width: w, height: h) }
                    lookup[name] = DecodedTexture(image: image, hasTransparency: scan?.hasTransparency ?? false, isCutout: scan?.isCutout ?? false)
                    continue
                }
                missing.append(path)
            }
            if let c = m.diffuseColor { lookup[name] = DecodedTexture(image: ImageUtil.solidColor(r: c.r, g: c.g, b: c.b), hasTransparency: false) }
        }
        textureLookup = lookup
        missingTextures = missing
        // One mesh per material, with flat face normals so the shape reads under lighting.
        var order: [String] = [], byMaterial: [String: [MDL0Vertex]] = [:]
        for t in triangles {
            let key = t.materialName ?? ""
            if byMaterial[key] == nil { order.append(key) }
            let a = SIMD3(t.v1.x - t.v0.x, t.v1.y - t.v0.y, t.v1.z - t.v0.z), b = SIMD3(t.v2.x - t.v0.x, t.v2.y - t.v0.y, t.v2.z - t.v0.z)
            let c = simd_cross(a, b), len = simd_length(c)
            let n = len > 0 ? Vec3(x: c.x / len, y: c.y / len, z: c.z / len) : Vec3(x: 0, y: 1, z: 0)
            let image = materials[key]?.diffuseTexturePath != nil
            for (p, uv) in [(t.v0, t.uv0), (t.v1, t.uv1), (t.v2, t.uv2)] {
                // OBJ's V runs up the image, SceneKit's down; a colour-only material samples its swatch.
                let flipped = image ? uv.map { Vec2(x: $0.x, y: 1 - $0.y) } : Vec2(x: 0.5, y: 0.5)
                byMaterial[key, default: []].append(MDL0Vertex(position: p, normal: n, uv0: lookup[key] != nil ? flipped : nil))
            }
        }
        let meshes = order.map { MDL0Mesh(name: $0.isEmpty ? "OBJ" : $0, vertices: byMaterial[$0]!, textureName: lookup[$0] != nil ? $0 : nil) }
        model = meshes.isEmpty ? nil : MDL0Model(name: "OBJ", meshes: meshes)
    }
}

@MainActor final class MTLDocumentBox: ObservableObject {
    let text: String
    let rawData: Data
    let url: URL?
    @Published var isDirty = false
    
    init(text: String, rawData: Data, url: URL?) {
        self.text = text
        self.rawData = rawData
        self.url = url
    }
}

/// A plain image file (PNG/JPEG/GIF/TIFF/BMP/...) opened directly, view-only (this app doesn't
/// re-encode arbitrary images), same stance as `.obj`/`.tpl`/`.brstm`.
@MainActor final class ImageDocumentBox: ObservableObject {
    let image: NSImage?
    let rawData: Data
    init(rawData: Data) {
        self.image = NSImage(data: rawData)
        self.rawData = rawData
    }
}

/// One open editor tab in the Workbench window.
@MainActor final class EditorTab: ObservableObject, Identifiable {
    let id = UUID()
    @Published var title: String
    var payload: EditorPayload

    /// Where this tab's bytes ultimately live: a real file on disk, or an entry inside a
    /// currently-open SZS archive window (so "Save" here writes back into that archive's
    /// in-memory tree and marks it dirty, rather than touching disk directly).
    enum Source {
        case file(URL)
        case szsEntry(archive: SZSDocumentBox, node: U8Node)
        /// This file's bytes live inside an opened Wii disc image (the disc-as-project case) --
        /// saving writes back into the disc file in place via the same engine the Disc Scrubber
        /// window uses (`FileOperations.replace`), including FST/relocation handling.
        case discEntry(discURL: URL, disc: any DiscImageReader, node: DiscNode)
    }
    var source: Source

    /// Forwards whichever document box `payload` wraps' own `objectWillChange` into this tab's --
    /// `isDirty` (and everything else the tab strip shows) reads through that nested box, and a
    /// nested object's `@Published` changes don't cascade through an outer `ObservableObject` on
    /// their own (the same reactivity gap fixed for `SZSWindowView`/`NSMBWWindowView`). Without
    /// this, the tab strip's dirty dot would only update by coincidence.
    private var boxChangeToken: AnyCancellable?

    init(title: String, payload: EditorPayload, source: Source) {
        self.title = title
        self.payload = payload
        self.source = source
        boxChangeToken = Self.boxPublisher(for: payload).sink { [weak self] in self?.objectWillChange.send() }
    }

    var isLoading: Bool { if case .loading = payload { return true } else { return false } }

    /// Swaps a `.loading` placeholder for the real payload once `WorkbenchState.resolvePayload`
    /// finishes parsing in the background, and re-wires `boxChangeToken` to the new payload's box
    ///, the initial `.loading` payload has no box of its own to forward from.
    func finishLoading(_ newPayload: EditorPayload) {
        objectWillChange.send()
        payload = newPayload
        boxChangeToken = Self.boxPublisher(for: newPayload).sink { [weak self] in self?.objectWillChange.send() }
    }

    private static func boxPublisher(for payload: EditorPayload) -> ObservableObjectPublisher {
        switch payload {
        case .kmp(let box): return box.objectWillChange
        case .brres(let box): return box.objectWillChange
        case .bmg(let box): return box.objectWillChange
        case .tpl(let box): return box.objectWillChange
        case .kcl(let box): return box.objectWillChange
        case .szs(let box): return box.objectWillChange
        case .nsmbwLevel(let box): return box.objectWillChange
        case .brstm(let box): return box.objectWillChange
        case .brlyt(let box): return box.objectWillChange
        case .brlan(let box): return box.objectWillChange
        case .brsar(let box): return box.objectWillChange
        case .j3d(let box): return box.objectWillChange
        case .j3dAnimation(let box): return box.objectWillChange
        case .code(let box): return box.objectWillChange
        case .raw(let box): return box.objectWillChange
        case .obj(let box): return box.objectWillChange
        case .mtl(let box): return box.objectWillChange
        case .uiDesign(let box): return box.objectWillChange
        case .nodeGraph(let box): return box.objectWillChange
        case .image(let box): return box.objectWillChange
        case .fields(let box): return box.objectWillChange
        case .effect(let box): return box.objectWillChange
        case .loading: return ObservableObjectPublisher()
        }
    }

    var isDirty: Bool {
        switch payload {
        case .kmp(let box): return box.isDirty
        case .brres(let box): return box.isDirty
        case .bmg(let box): return box.isDirty
        case .tpl: return false
        case .kcl(let box): return box.isDirty
        case .szs(let box): return box.isDirty
        case .nsmbwLevel(let box): return box.isDirty
        case .brstm(let box): return box.isDirty
        case .brlyt(let box): return box.isDirty
        case .brlan: return false
        case .brsar: return false
        case .j3d, .j3dAnimation: return false
        case .code(let box): return box.isDirty
        case .raw(let box): return box.isDirty
        case .obj: return false
        case .mtl(let box): return box.isDirty
        case .uiDesign(let box): return box.isDirty
        case .nodeGraph(let box): return box.isDirty
        case .image: return false
        case .fields(let box): return box.isDirty
        case .effect: return false
        case .loading: return false
        }
    }

    var iconName: String {
        switch payload {
        case .kmp: return "map"
        case .brres: return "cube.transparent"
        case .bmg: return "text.bubble"
        case .tpl: return "photo.stack"
        case .kcl: return "triangle"
        case .szs: return "shippingbox"
        case .nsmbwLevel: return "square.grid.3x3"
        case .brstm: return "waveform"
        case .brlyt: return "rectangle.3.group"
        case .brlan: return "play.rectangle"
        case .brsar: return "waveform.circle"
        case .j3d: return "cube.transparent"
        case .j3dAnimation: return "play.rectangle"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .raw: return "doc"
        case .obj: return "cube.transparent"
        case .mtl: return "paintpalette"
        case .uiDesign: return "rectangle.on.rectangle"
        case .nodeGraph: return "point.3.connected.trianglepath.dotted"
        case .image: return "photo"
        case .fields: return "slider.horizontal.3"
        case .effect: return "sparkles"
        case .loading: return "hourglass"
        }
    }
}
