import SceneKit
import AppKit

/// Turns an already-parsed `MDL0Model` (see `MDL0Parser`) into a real, textured `SCNNode` tree for
/// `TrackPreviewView`'s 3D scene, the one place in this app that needs actual GPU-renderable
/// geometry rather than the flat top-down silhouette `KMPEditorView.drawCourseModelSilhouette`
/// draws for in-editor reference.
///
/// Deliberately thin: `MDL0Parser` already resolves each mesh down to a flat triangle list (no
/// index buffer, matching how `MapModelBuilder`/`OBJImporter` already consume it) plus its real
/// first-sampler texture name, so this only has to hand that straight to `SCNGeometry` and look
/// the texture name up in an already-decoded image table.
nonisolated enum MDL0SceneKit {
    /// One built mesh node per `MDL0Mesh`, parented under a single root, kept as separate nodes
    /// (rather than one merged geometry) so a mesh with no resolved texture can fall back to a
    /// flat material without affecting its neighbours, same as `drawCourseModelSilhouette`'s
    /// per-mesh material coloring.
    ///
    /// Meshes hang off a node per bone (bind pose, billboarding), so a rigid mesh, whose vertices
    /// are relative to its bone, lands where the game draws it. With `animations` (the model's
    /// BRRES), its CHR0 plays on those bones and its SRT0/PAT0 on the materials' textures.
    static func node(for model: MDL0Model, textures: [String: DecodedTexture], animations: BRRESDocument? = nil) -> SCNNode {
        let root = SCNNode()
        root.name = model.name
        let boneNodes = model.bones.map { bone -> SCNNode in
            let n = SCNNode()
            n.name = bone.name
            n.simdTransform = MDL0Bone.matrix(scale: bone.scale, rotation: bone.rotation, translation: bone.translation)
            if bone.billboard != 0 {
                let c = SCNBillboardConstraint()
                c.freeAxes = bone.billboard >= 5 ? .Y : .all
                n.constraints = [c]
            }
            return n
        }
        for (i, bone) in model.bones.enumerated() {
            (bone.parent.map { boneNodes[$0] } ?? root).addChildNode(boneNodes[i])
        }
        var srtTargets: [(SCNMaterial, String, Int)] = []
        for mesh in model.meshes {
            // A lightmapped material lists a greyscale shadow map (`kage`) and the surface's own
            // colour texture: draw the colour one, multiplied by the lightmap, each on its own UV
            // set (sampler n reads UV set n when the mesh has one), the first sampler alone
            // painted Moo Moo Meadows' grass as a grey shadow map.
            let slots = mesh.textureNames.isEmpty ? mesh.textureName.map { [$0] } ?? [] : mesh.textureNames
            let decoded = slots.map { textures[$0] }
            let colorSlot = decoded.firstIndex { $0 != nil && $0!.isGrayscale == false } ?? decoded.firstIndex { $0 != nil }
            let lightmapSlot = colorSlot.flatMap { c in decoded.indices.first { $0 != c && decoded[$0]?.isGrayscale == true } }
            let texture = colorSlot.flatMap { decoded[$0] }
            let hasUV1 = mesh.vertices.allSatisfy { $0.uv1 != nil }
            func channel(_ slot: Int) -> Int { slot >= 1 && hasUV1 ? 1 : 0 }
            // Vertex colours modulate the texture the way the game's course shader does (x2).
            guard let geometry = geometry(for: mesh, colorScale: texture == nil ? 1 : 2) else { continue }
            let material = SCNMaterial()
            if let texture {
                material.diffuse.contents = texture.image
                // Game materials repeat their textures (UVs routinely run far past 0-1); SceneKit's
                // default is clamp, which smeared each edge texel across whole surfaces.
                material.diffuse.wrapS = .repeat
                material.diffuse.wrapT = .repeat
                // Mipmapped + anisotropic: distant and glancing road stays sharp instead of shimmering.
                material.diffuse.mipFilter = .linear
                material.diffuse.maxAnisotropy = 16
                material.diffuse.mappingChannel = colorSlot.map(channel) ?? 0
                if let lightmapSlot, let lightmap = decoded[lightmapSlot] {
                    material.multiply.contents = lightmap.image
                    material.multiply.mappingChannel = channel(lightmapSlot)
                    material.multiply.wrapS = .repeat
                    material.multiply.wrapT = .repeat
                    material.multiply.mipFilter = .linear
                }
            } else {
                // No texture resolved (untextured material, like a real map_model, or a texture
                // this app's simplified single-sampler `MDL0Parser` couldn't match), a plain grey
                // still reads as "surface exists" rather than leaving a hole in the track.
                material.diffuse.contents = NSColor.lightGray
            }
            material.isDoubleSided = true
            let fades = mesh.vertices.contains { ($0.color?.w ?? 1) < 0.99 }
            material.applyTransparency(texture, vertexFades: fades)
            geometry.materials = [material]
            if let name = mesh.materialName, texture != nil, let colorSlot { srtTargets.append((material, name, colorSlot)) }
            let node = SCNNode(geometry: geometry)
            // Blended surfaces (decals, overlays) draw after the solid ones, as in-game.
            if material.isTranslucent { node.renderingOrder = 100 }
            let bone = mesh.matrixId >= 0 ? model.bones.firstIndex { $0.matrixId == mesh.matrixId } : nil
            (bone.map { boneNodes[$0] } ?? root).addChildNode(node)
            if bone == nil, !boneNodes.isEmpty, mesh.vertices.contains(where: { !$0.weights.isEmpty }) {
                node.skinner = skinner(for: mesh, geometry: geometry, bones: boneNodes, root: root)
            }
        }
        if let doc = animations {
            playCHR0(doc, model: model, boneNodes: boneNodes)
            playSRT0(doc, model: model, targets: srtTargets)
            playPAT0(doc, model: model, targets: srtTargets, textures: textures, on: root)
        }
        return root
    }

    /// Texture swapping (flipbooks) on the drawn (colour) texture of each animated material.
    /// ponytail: only the colour slot swaps; a PAT0 on a lightmap slot isn't previewed.
    private static func playPAT0(_ doc: BRRESDocument, model: MDL0Model, targets: [(SCNMaterial, String, Int)],
                                 textures: [String: DecodedTexture], on root: SCNNode) {
        guard let r = pick("PAT0", in: doc, for: model), let pat = PAT0Animation.parse(r, rawFile: doc.rawData) else { return }
        // Per material, the image to show on each game frame.
        var tracks: [(SCNMaterial, [NSImage?])] = []
        for (material, name, slot) in targets {
            guard let keys = pat.materials.first(where: { $0.name == name })?.samplers.first(where: { $0.slot == slot })?.keys else { continue }
            let images = (0..<max(1, pat.frameCount)).map { f in
                PAT0Animation.texture(at: Float(f), keys: keys).flatMap { pat.textureNames.indices.contains($0) ? textures[pat.textureNames[$0]]?.image : nil }
            }
            if let first = images[0] { material.diffuse.contents = first }
            tracks.append((material, images))
        }
        guard pat.frameCount > 1, !tracks.isEmpty else { return }
        nonisolated(unsafe) let swaps = tracks
        let step = SCNAction.customAction(duration: Double(pat.frameCount) / 60) { _, t in
            for (material, images) in swaps {
                guard let image = images[min(images.count - 1, Int(t * 60))], material.diffuse.contents as AnyObject? !== image else { continue }
                material.diffuse.contents = image
            }
        }
        root.runAction(pat.loops ? .repeatForever(step) : step, forKey: "pat0")
    }

    /// Envelope skinning: up to four bone weights a vertex (unweighted vertices ride the first bone),
    /// bound to the bones' bind pose relative to the model's root.
    private static func skinner(for mesh: MDL0Mesh, geometry: SCNGeometry, bones: [SCNNode], root: SCNNode) -> SCNSkinner {
        var indices: [UInt16] = [], weights: [Float] = []
        for v in mesh.vertices {
            let w = v.weights.sorted { $0.weight > $1.weight }.prefix(4)
            let total = max(w.reduce(0) { $0 + $1.weight }, 1e-6)
            for k in 0..<4 {
                indices.append(k < w.count ? UInt16(w[w.startIndex + k].bone) : 0)
                weights.append(k < w.count ? w[w.startIndex + k].weight / total : (k == 0 && w.isEmpty ? 1 : 0))
            }
        }
        let n = mesh.vertices.count
        let indexSource = SCNGeometrySource(data: indices.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: .boneIndices, vectorCount: n,
                                            usesFloatComponents: false, componentsPerVector: 4, bytesPerComponent: 2, dataOffset: 0, dataStride: 8)
        let weightSource = SCNGeometrySource(data: weights.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: .boneWeights, vectorCount: n,
                                             usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
        let inverseBind = bones.map { NSValue(scnMatrix4: SCNMatrix4Invert(root.convertTransform(SCNMatrix4Identity, from: $0))) }
        let s = SCNSkinner(baseGeometry: geometry, bones: bones, boneInverseBindTransforms: inverseBind, boneWeights: weightSource, boneIndices: indexSource)
        s.skeleton = root
        return s
    }

    /// The model's own animation (named after it), else its idle ("wait"), else the first of that kind.
    private static func pick(_ magic: String, in doc: BRRESDocument, for model: MDL0Model) -> BRRESResource? {
        let all = doc.resources.filter { $0.magic == magic }
        return all.first { $0.name == model.name } ?? all.first { $0.name == "wait" } ?? all.first
    }

    private static func loop(_ keyPath: String, _ values: [NSValue], frames: Int) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: keyPath)
        a.values = values
        a.duration = Double(frames) / 60
        a.repeatCount = .infinity
        a.calculationMode = .linear
        return a
    }

    /// Bakes each animated bone's matrix per frame (60 fps, as the game steps it).
    private static func playCHR0(_ doc: BRRESDocument, model: MDL0Model, boneNodes: [SCNNode]) {
        guard let r = pick("CHR0", in: doc, for: model), let anim = CHR0Animation.parse(r, rawFile: doc.rawData), anim.frameCount > 1 else { return }
        for node in anim.nodes {
            guard let b = model.bones.firstIndex(where: { $0.name == node.name }), node.values.contains(where: { $0 != nil }) else { continue }
            let bone = model.bones[b]
            let bind = [bone.scale.x, bone.scale.y, bone.scale.z, bone.rotation.x, bone.rotation.y, bone.rotation.z,
                        bone.translation.x, bone.translation.y, bone.translation.z]
            // An attribute the animation doesn't store is the identity its flags name, else the bone's own.
            let identity = node.flags & 0b10 != 0
            let unity = [identity || node.flags & (1 << 3) != 0, identity || node.flags & (1 << 2 | 1 << 5) != 0,
                         identity || node.flags & (1 << 2 | 1 << 6) != 0]
            let values = (0...anim.frameCount).map { f -> NSValue in
                let v = (0..<9).map { a in node.values[a].map { CHR0Animation.sample($0, at: Float(f)) } ?? (unity[a / 3] ? (a < 3 ? 1 : 0) : bind[a]) }
                let m = MDL0Bone.matrix(scale: Vec3(x: v[0], y: v[1], z: v[2]), rotation: Vec3(x: v[3], y: v[4], z: v[5]),
                                   translation: Vec3(x: v[6], y: v[7], z: v[8]))
                return NSValue(scnMatrix4: SCNMatrix4(m))
            }
            boneNodes[b].addAnimation(loop("transform", values, frames: anim.frameCount), forKey: "chr0")
        }
    }

    /// Texture scrolling/rotation on the drawn (colour) texture of each animated material.
    private static func playSRT0(_ doc: BRRESDocument, model: MDL0Model, targets: [(SCNMaterial, String, Int)]) {
        guard let r = pick("SRT0", in: doc, for: model), let srt = SRT0Document.parse(r, rawFile: doc.rawData) else { return }
        let frames = min(max(1, srt.maxFrame.rounded(.up).clampedInt), 100_000)
        for (material, name, slot) in targets {
            guard let t = srt.materials.first(where: { $0.name == name })?.matrices.first(where: { !$0.isIndirect && $0.slotIndex == slot })?.targets else { continue }
            func m(_ f: Float) -> SCNMatrix4 {
                let su = srt.value(of: t.scaleU, at: f), sv = t.scaleV.map { srt.value(of: $0, at: f) } ?? su
                let rot = srt.value(of: t.rotate, at: f) * .pi / 180
                let tu = srt.value(of: t.transU, at: f), tv = srt.value(of: t.transV, at: f)
                // ponytail: Maya-style texture SRT approximated as rotate, scale, then shift (-u, +v)
                //, the scroll direction and speed match; the rotation/scale pivot may not.
                var x = simd_float4x4(1)
                x = simd_float4x4(simd_quatf(angle: rot, axis: [0, 0, 1])) * x
                x = simd_float4x4(diagonal: [su, sv, 1, 1]) * x
                x.columns.3 = [-tu * su, tv * sv, 0, 1]
                return SCNMatrix4(x)
            }
            material.diffuse.contentsTransform = m(0)
            guard frames > 1 else { continue }
            material.diffuse.addAnimation(loop("contentsTransform", (0...frames).map { NSValue(scnMatrix4: m(Float($0))) }, frames: frames), forKey: "srt0")
        }
    }

    /// `mesh.vertices` is already a flat triangle list (three per face, no shared-index buffer --
    /// see `MapModelBuilder.triangles(from:)`'s doc comment), so the element below is just
    /// "0, 1, 2, ..." rather than anything deduplicated.
    private static func geometry(for mesh: MDL0Mesh, colorScale: Float) -> SCNGeometry? {
        guard mesh.vertices.count >= 3 else { return nil }
        let positions = mesh.vertices.map { SCNVector3($0.position.x, $0.position.y, $0.position.z) }
        let indices: [Int32] = Array(0..<Int32(positions.count))
        var sources = [SCNGeometrySource(vertices: positions)]

        if mesh.vertices.allSatisfy({ $0.normal != nil }) {
            sources.append(SCNGeometrySource(normals: mesh.vertices.map { SCNVector3($0.normal!.x, $0.normal!.y, $0.normal!.z) }))
        } else {
            sources.append(SCNGeometrySource(normals: flatNormals(positions)))
        }

        if mesh.vertices.allSatisfy({ $0.uv0 != nil }) {
            // Passed straight through: SceneKit's V runs down the image exactly like GX's
            // (checked by rendering a two-colour texture offscreen), so no flip.
            let uvs = mesh.vertices.map { CGPoint(x: CGFloat($0.uv0!.x), y: CGFloat($0.uv0!.y)) }
            sources.append(SCNGeometrySource(textureCoordinates: uvs))
            if mesh.vertices.allSatisfy({ $0.uv1 != nil }) {
                sources.append(SCNGeometrySource(textureCoordinates: mesh.vertices.map { CGPoint(x: CGFloat($0.uv1!.x), y: CGFloat($0.uv1!.y)) }))
            }
        }
        if mesh.vertices.allSatisfy({ $0.color != nil }) {
            var floats: [Float] = []
            floats.reserveCapacity(mesh.vertices.count * 4)
            for v in mesh.vertices {
                let c = v.color!
                floats += [min(1, c.x * colorScale), min(1, c.y * colorScale), min(1, c.z * colorScale), c.w]
            }
            let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
            sources.append(SCNGeometrySource(data: data, semantic: .color, vectorCount: mesh.vertices.count, usesFloatComponents: true,
                                             componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: 16))
        }

        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        return SCNGeometry(sources: sources, elements: [element])
    }

    /// One flat face normal per vertex, for the rare mesh with no normals of its own (a `mapStyle`
    /// map model, per `MDL0Writer`'s doc comment, not expected from course/vrcorn/object models,
    /// but cheap insurance against a black, unlit mesh if one ever lacks them).
    private static func flatNormals(_ positions: [SCNVector3]) -> [SCNVector3] {
        var out: [SCNVector3] = []
        out.reserveCapacity(positions.count)
        var i = 0
        while i + 2 < positions.count {
            let a = positions[i], b = positions[i + 1], c = positions[i + 2]
            let u = SCNVector3(b.x - a.x, b.y - a.y, b.z - a.z)
            let v = SCNVector3(c.x - a.x, c.y - a.y, c.z - a.z)
            var n = SCNVector3(u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x)
            let len = (n.x * n.x + n.y * n.y + n.z * n.z).squareRoot()
            if len > 0.0001 { n = SCNVector3(n.x / len, n.y / len, n.z / len) }
            out.append(contentsOf: [n, n, n])
            i += 3
        }
        return out
    }

    /// Every TEX0 in a BRRES, decoded once up front and keyed by name, the same
    /// decode-then-`ImageUtil.nsImage` path `KMPEditorView.backgroundTextureImages` and
    /// `BRRESEditorView` already use, just collected into a lookup table instead of a flat list.
    /// Written against the plain `BRRESDocument` rather than the `@MainActor` `BRRESDocumentBox`
    /// (whose `palette(for:)` this mirrors) so texture decoding can run off the main thread.
    static func textureImages(in doc: BRRESDocument) -> [String: DecodedTexture] {
        var out: [String: DecodedTexture] = [:]
        for r in doc.resources where r.magic == "TEX0" {
            let palette = doc.resources.first(where: { $0.magic == "PLT0" && $0.name == r.name }).flatMap { PLT0View($0)?.entries }
            guard let v = TEX0View(r), let rgba = v.decodeRGBA(palette: palette),
                  let decoded = ImageUtil.decodedTexture(fromRGBA: rgba, width: v.width, height: v.height) else { continue }
            out[r.name] = decoded
        }
        return out
    }
}

extension SCNMaterial {
    private static let translucentName = "translucent"
    /// Set by `applyTransparency`, `blendMode` can't tell, as SceneKit's default is already `.alpha`.
    var isTranslucent: Bool { name == Self.translucentName }

    /// Settings > Appearance > Transparent surfaces.
    enum TransparencyMode: String, CaseIterable, Identifiable {
        case automatic, blend, cutout, opaque
        var id: String { rawValue }
        var title: String {
            switch self {
            case .automatic: "Automatic"
            case .blend: "Blend everything"
            case .cutout: "Cut out everything"
            case .opaque: "Ignore transparency"
            }
        }
        static let key = "transparencyMode"
        static var current: TransparencyMode { UserDefaults.standard.string(forKey: key).flatMap(TransparencyMode.init) ?? .automatic }
    }

    /// Automatic: hard-edged cut-outs (fences, foliage) discard their clear texels and keep writing
    /// depth, so they sort correctly; see-through surfaces (glass, glows, fades) blend
    /// without writing depth, back faces first, and draw after the solid ones. The other modes force
    /// one treatment for every transparent material.
    func applyTransparency(_ texture: DecodedTexture?, vertexFades: Bool) {
        guard texture?.hasTransparency == true || vertexFades else { return }
        let cutout: Bool
        switch TransparencyMode.current {
        case .opaque: return
        case .automatic: cutout = texture?.isCutout == true && !vertexFades
        case .blend: cutout = false
        case .cutout: cutout = true
        }
        if cutout {
            shaderModifiers = [.fragment: "if (_output.color.a < 0.5) { discard_fragment(); }"]
        } else {
            name = Self.translucentName
            blendMode = .alpha
            writesToDepthBuffer = false
            transparencyMode = .dualLayer
        }
    }
}
