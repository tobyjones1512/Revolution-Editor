import Foundation

/// Turns a Double Dash J3D model into a Mario Kart Wii MDL0 (in a BRRES), keeping as much of each
/// material's look as Mario Kart Wii's one-stage course shader (texture x vertex colour x 2) can:
///
/// - Texture and UVs: the texture the first texturing TEV stage samples, with that stage's own
///   texture-coordinate set run through its J3D texture matrix, and the texture's wrap modes.
/// - Colour: most Double Dash materials are exactly texture x vertex colour, which maps straight
///   across (vertex colours halved for the x2). Anything else, intensity textures tinted by
///   constant colours (water), multi-stage blends, konst-coloured overlays, is evaluated on the
///   CPU for every texel and saved as a new texture for that material, with vertex colours
///   applied on top when the material used them.
/// - Alpha test, blending (drawn in the translucent pass, no depth writes) and culling as J3D sets them.
nonisolated enum J3DToWii {
    /// `animations` (BTKs, each with the SRT0 name to give it) become SRT0s on the MDL0 materials
    /// whose primary texture they move; those materials keep their UVs unbaked for it.
    static func brres(from model: J3DModel.Model, modelName: String, scale s: Float,
                      animations: [(name: String, btk: J3DAnimation.Animation)] = []) throws -> Data {
        let animatedTargets = Set(animations.flatMap { $0.btk.targets.map { "\($0.name)#\($0.texMatrix ?? 0)" } })
        var textureResources: [BRRESResource] = []
        var usedNames = Set<String>()
        var originalTextureName: [Int: String] = [:]
        func uniqueName(_ base: String) -> String {
            var name = base.isEmpty ? "tex" : base
            while usedNames.contains(name) { name += "_" }
            usedNames.insert(name)
            return name
        }
        func add(_ name: String, _ tex0: Data?) -> String? {
            guard let tex0 else { return nil }
            textureResources.append(BRRESResource(name: name, folderName: "Textures(NW4R)", data: tex0))
            return name
        }
        func original(_ index: Int) -> String? {
            if let existing = originalTextureName[index] { return existing }
            let t = model.textures[index]
            let name = uniqueName(t.name)
            let tex0: Data?
            if let encoded = t.encoded {
                tex0 = TEX0View.building(name: name, encoded: encoded, width: t.width, height: t.height, format: t.format)
            } else if let rgba = t.rgba {
                tex0 = TEX0View.building(name: name, rgba: rgba, width: t.width, height: t.height, format: .rgb5a3)
            } else { tex0 = nil }
            let result = add(name, tex0)
            originalTextureName[index] = result
            return result
        }
        var averageColor: [Int: SIMD4<Float>] = [:]
        func average(_ index: Int) -> SIMD4<Float> {
            if let a = averageColor[index] { return a }
            var sum = SIMD4<Float>(repeating: 0)
            if let px = model.textures[index].decoded(), !px.isEmpty {
                for i in stride(from: 0, to: px.count, by: 4) { sum += SIMD4(Float(px[i]), Float(px[i + 1]), Float(px[i + 2]), Float(px[i + 3])) }
                sum /= Float(px.count / 4) * 255
            } else { sum = SIMD4(repeating: 1) }
            averageColor[index] = sum
            return sum
        }

        // Resolve each material once.
        struct Resolved {
            var spec: MDL0Writer.MaterialSpec
            var uvSet: Int?
            var uvMatrix: (SIMD3<Float>, SIMD3<Float>)?
            var usesRaster: Bool
            var textured: Bool
            /// Untextured: the material's own colour, from its TEV with the vertex colour as white.
            var tint: (UInt8, UInt8, UInt8, UInt8) = (255, 255, 255, 255)
            /// Later stages that multiply in another texture on its own UVs (lightmaps, shadow
            /// maps): sampled at each vertex and multiplied into the vertex colour instead.
            var modulators: [(texture: Int, uvSet: Int, matrix: (SIMD3<Float>, SIMD3<Float>)?, alpha: Bool)] = []
            /// The J3D texture matrix an animation moves, if any.
            var animatedMatrix: Int?
        }
        let resolved: [Resolved] = model.materials.enumerated().map { m, mat in
            var spec = MDL0Writer.MaterialSpec(name: mat.name.isEmpty ? "material\(m)" : mat.name)
            spec.cull = mat.cull <= 2 ? mat.cull : 0
            spec.alphaTest = mat.alphaTest
            if mat.blend.0 == 1 || mat.mode == 4 {
                spec.blend = mat.blend.0 == 1 ? (mat.blend.1, mat.blend.2) : (4, 5)
                spec.depthWrite = mat.zMode.2 != 0 && mat.blend.0 != 1
            } else {
                spec.depthWrite = mat.zMode.2 != 0
            }
            let stage = mat.stages.first { $0.texMap != 0xFF && $0.texMap < 8 && mat.textures[Int($0.texMap)] != nil }
            let usesRaster = mat.stages.contains { st in
                st.channel != 0xFF && ([st.color.a, st.color.b, st.color.c, st.color.d].contains { $0 == 0xA || $0 == 0xB }
                                       || [st.alpha.a, st.alpha.b, st.alpha.c, st.alpha.d].contains(5))
            }
            guard let stage, let texIndex = mat.textures[Int(stage.texMap)], model.textures.indices.contains(texIndex) else {
                var r = Resolved(spec: spec, uvSet: nil, uvMatrix: nil, usesRaster: usesRaster, textured: false)
                if let c = bake(mat, primary: nil, stage: nil, textures: model.textures, average: average), c.count == 4 { r.tint = (c[0], c[1], c[2], c[3]) }
                return r
            }
            let tex = model.textures[texIndex]
            spec.wrap = (UInt32(min(2, tex.wrapS)), UInt32(min(2, tex.wrapT)))
            let (uvSet, matrix) = coordinates(mat, stage.texCoord)
            // Multiply-by-texture stages after the base one (a = d = 0, b/c = that texture and
            // the previous result) become per-vertex modulation.
            var modulators: [(texture: Int, uvSet: Int, matrix: (SIMD3<Float>, SIMD3<Float>)?, alpha: Bool)] = []
            var white = Set<Int>()
            let primaryIndex = mat.stages.firstIndex { $0.texMap == stage.texMap && $0.texCoord == stage.texCoord } ?? 0
            for (i, st) in mat.stages.enumerated() where i > primaryIndex && st.texMap < 8 {
                guard let t = mat.textures[Int(st.texMap)], model.textures.indices.contains(t), !(t == texIndex && st.texCoord == stage.texCoord) else { continue }
                let c = st.color, a = st.alpha
                guard c.a == 0xF, c.d == 0xF, [c.b, c.c].sorted() == [0, 8], c.op == 0, c.bias == 0 else { continue }
                let (set, mtx) = coordinates(mat, st.texCoord)
                guard let set else { continue }
                white.insert(i)
                modulators.append((t, set, mtx, a.a == 7 && a.d == 7 && [a.b, a.c].sorted() == [0, 4]))
            }
            if var baked = bake(mat, primary: texIndex, stage: stage, textures: model.textures, average: average, whiteStages: white) {
                if !spec.translucent && !spec.alphaTested { for i in stride(from: 3, to: baked.count, by: 4) { baked[i] = 255 } }
                // Unchanged by the TEV (plain texture x vertex colour): keep the original data.
                let opaque = !spec.translucent && !spec.alphaTested
                if let px = tex.decoded(), px.count == baked.count,
                   zip(px, baked).enumerated().allSatisfy({ (opaque && $0.offset % 4 == 3) || abs(Int($0.element.0) - Int($0.element.1)) <= 3 }) {
                    spec.textureName = original(texIndex)
                } else {
                    let name = uniqueName("\(tex.name)_\(spec.name)")
                    let hasAlpha = stride(from: 3, to: baked.count, by: 4).contains { baked[$0] < 250 }
                    spec.textureName = add(name, TEX0View.building(name: name, rgba: baked, width: tex.width, height: tex.height, format: hasAlpha ? .rgb5a3 : .cmpr))
                }
            }
            var r = Resolved(spec: spec, uvSet: uvSet, uvMatrix: matrix, usesRaster: usesRaster, textured: spec.textureName != nil)
            r.modulators = modulators
            if let g = mat.texGens.indices.contains(Int(stage.texCoord)) ? mat.texGens[Int(stage.texCoord)] : nil,
               g.matrix >= 30, g.matrix < 60, animatedTargets.contains("\(mat.name)#\((g.matrix - 30) / 3)") {
                r.uvMatrix = nil // the SRT0 drives it
                r.animatedMatrix = Int(g.matrix - 30) / 3
            }
            return r
        }

        /// A texel (0-1), bilinear, honouring the texture's wrap modes.
        var decodedCache: [Int: [UInt8]] = [:]
        func sample(_ index: Int, _ uv: Vec2) -> SIMD4<Float> {
            let t = model.textures[index]
            if decodedCache[index] == nil { decodedCache[index] = t.decoded() ?? [] }
            let px = decodedCache[index]!
            guard px.count == t.width * t.height * 4, t.width > 0, t.height > 0 else { return SIMD4(repeating: 1) }
            func wrap(_ i: Int, _ n: Int, _ mode: UInt8) -> Int {
                switch mode {
                case 0: return max(0, min(n - 1, i))
                case 2: let m = ((i % (2 * n)) + 2 * n) % (2 * n); return m < n ? m : 2 * n - 1 - m
                default: return ((i % n) + n) % n
                }
            }
            let x = uv.x * Float(t.width) - 0.5, y = uv.y * Float(t.height) - 0.5
            let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down)), fx = x - Float(x0), fy = y - Float(y0)
            func at(_ i: Int, _ j: Int) -> SIMD4<Float> {
                let o = (wrap(j, t.height, t.wrapT) * t.width + wrap(i, t.width, t.wrapS)) * 4
                return SIMD4(Float(px[o]), Float(px[o + 1]), Float(px[o + 2]), Float(px[o + 3])) / 255
            }
            let top = at(x0, y0) * (1 - fx) + at(x0 + 1, y0) * fx, bottom = at(x0, y0 + 1) * (1 - fx) + at(x0 + 1, y0 + 1) * fx
            return top * (1 - fy) + bottom * fy
        }

        // Triangles per material: UVs (GX, converted to the writer's V-up), vertex colours.
        var byMaterial: [Int: (tris: [OBJImporter.Triangle], colors: [MDL0Writer.RGBA])] = [:]
        var order: [Int] = []
        for t in model.triangles {
            let m = model.materials.indices.contains(t.material) ? t.material : 0
            let r = resolved[m], mat = model.materials[m]
            if byMaterial[m] == nil { order.append(m) }
            func uv(_ v: J3DModel.Vertex) -> Vec2? {
                guard r.textured else { return nil }
                var p = (r.uvSet.flatMap { v.uv[$0] }) ?? Vec2()
                if let (row0, row1) = r.uvMatrix {
                    p = Vec2(x: row0.x * p.x + row0.y * p.y + row0.z, y: row1.x * p.x + row1.y * p.y + row1.z)
                }
                return Vec2(x: p.x, y: 1 - p.y) // MDL0Writer flips V back to GX
            }
            // Alpha only matters to blended or alpha-tested materials; elsewhere it stays opaque
            // (a lightmap's intensity-as-alpha would otherwise leak into the framebuffer).
            let usesAlpha = r.spec.translucent || r.spec.alphaTested
            func color(_ v: J3DModel.Vertex) -> MDL0Writer.RGBA {
                let c = mat.colorChannel.fromVertex ? v.color : mat.matColor
                let a = !usesAlpha ? 255 : (mat.alphaChannel.fromVertex ? v.color.3 : mat.matColor.3)
                if !r.textured {
                    // Untextured: the writer's shader outputs the vertex colour as-is.
                    func mul(_ x: UInt8, _ y: UInt8) -> UInt8 { UInt8((UInt16(x) * UInt16(y) + 127) / 255) }
                    return r.usesRaster ? (mul(c.0, r.tint.0), mul(c.1, r.tint.1), mul(c.2, r.tint.2), mul(a, r.tint.3)) : r.tint
                }
                var rgba: SIMD4<Float> = r.usesRaster ? SIMD4(Float(c.0), Float(c.1), Float(c.2), Float(a)) / 255 : SIMD4(1, 1, 1, 1)
                for mod in r.modulators {
                    var p = v.uv[mod.uvSet] ?? Vec2()
                    if let (row0, row1) = mod.matrix { p = Vec2(x: row0.x * p.x + row0.y * p.y + row0.z, y: row1.x * p.x + row1.y * p.y + row1.z) }
                    let s = sample(mod.texture, p)
                    rgba = SIMD4(rgba.x * s.x, rgba.y * s.y, rgba.z * s.z, mod.alpha ? rgba.w * s.w : rgba.w)
                }
                func half(_ f: Float) -> UInt8 { UInt8(max(0, min(255, (f * 127.5).rounded()))) } // x2 in-game
                return (half(rgba.x), half(rgba.y), half(rgba.z), usesAlpha ? UInt8(max(0, min(255, (rgba.w * 255).rounded()))) : 255)
            }
            let (a, b, c) = t.v
            func sp(_ p: Vec3) -> Vec3 { Vec3(x: p.x * s, y: p.y * s, z: p.z * s) }
            byMaterial[m, default: ([], [])].tris.append(OBJImporter.Triangle(v0: sp(a.position), v1: sp(b.position), v2: sp(c.position),
                                                                               uv0: uv(a), uv1: uv(b), uv2: uv(c), materialName: nil))
            byMaterial[m]!.colors += [color(a), color(b), color(c)]
        }
        // One MDL0 mesh indexes at most 65535 vertices, split larger materials.
        let perMesh = MDL0Writer.maxVerticesPerMesh / 3
        var groups: [MDL0Writer.Group] = []
        var animatedSplits: [String: [String]] = [:] // J3D material -> its MDL0 material names
        for m in order {
            let (tris, colors) = byMaterial[m]!
            for (k, i) in stride(from: 0, to: tris.count, by: perMesh).enumerated() {
                var spec = resolved[m].spec
                spec.name += k == 0 ? "" : "_\(k)"
                let end = min(i + perMesh, tris.count)
                groups.append(MDL0Writer.Group(material: spec, triangles: Array(tris[i..<end]), vertexColors: Array(colors[(i * 3)..<(end * 3)])))
                if resolved[m].animatedMatrix != nil && resolved[m].textured { animatedSplits[model.materials[m].name, default: []].append(spec.name) }
            }
        }
        guard let mdl0 = MDL0Writer.build(name: modelName, groups: groups) else { throw WSError.badStructure("Couldn't build the \(modelName) model.") }
        let doc = BRRESDocument()
        doc.resources.append(BRRESResource(name: modelName, folderName: "3DModels(NW4R)", data: mdl0.data, stringReferences: mdl0.stringReferences))
        doc.resources.append(contentsOf: textureResources)
        for (name, btk) in animations {
            // Each target lands on texture slot 0 (the one texture an MDL0 material here has) of
            // every MDL0 material split from its J3D material.
            var btk = btk
            btk.targets = btk.targets.flatMap { t -> [J3DAnimation.Target] in
                guard let m = model.materials.firstIndex(where: { $0.name == t.name }), resolved[m].animatedMatrix == (t.texMatrix ?? 0) else { return [] }
                return (animatedSplits[t.name] ?? []).map { var c = t; c.name = $0; return c }
            }
            if let r = MKDDFileConvert.srt0(from: btk, name: name, target: { n, _ in (n, 0) }) { doc.resources.append(r) }
        }
        return doc.serialize()
    }

    /// A texgen's UV set (TEX0-7 sources only) and its texture matrix, if it has one.
    static func coordinates(_ m: J3DModel.Material, _ texCoord: UInt8) -> (Int?, (SIMD3<Float>, SIMD3<Float>)?) {
        guard Int(texCoord) < m.texGens.count else { return (0, nil) }
        let g = m.texGens[Int(texCoord)]
        let set = (4...11).contains(g.source) ? Int(g.source) - 4 : nil
        if g.matrix >= 30, g.matrix < 60, (g.matrix - 30) % 3 == 0, let tm = m.texMatrices[Int(g.matrix - 30) / 3], tm.info & 0x3F == 0 {
            return (set, texMatrix(tm))
        }
        return (set, nil)
    }

    /// J3D basic / Maya texture SRT as the two rows of a 2D affine UV transform.
    static func texMatrix(_ t: J3DModel.TexMatrix) -> (SIMD3<Float>, SIMD3<Float>) {
        let sinR = sin(t.rotation), cosR = cos(t.rotation)
        let (sS, sT, tS, tT) = (t.scale.x, t.scale.y, t.translation.x, t.translation.y)
        if t.info & 0x80 != 0 { // Maya
            return (SIMD3(sS * cosR, sT * -sinR, sS * ((-0.5 * cosR) - (0.5 * sinR - 0.5) - tS)),
                    SIMD3(sS * sinR, sT * cosR, sT * ((-0.5 * cosR) + (0.5 * sinR - 0.5) + tT) + 1))
        }
        let (cS, cT) = (t.center.x, t.center.y)
        let r00 = sS * cosR, r01 = sS * -sinR, r10 = sT * sinR, r11 = sT * cosR
        return (SIMD3(r00, r01, tS + cS - (r00 * cS + r01 * cT)), SIMD3(r10, r11, tT + cT - (r10 * cS + r11 * cT)))
    }

    // MARK: TEV evaluation

    /// Runs the material's TEV stages for every texel of its primary texture. Other textures
    /// contribute their average colour; the rasterised colour counts as white (vertex colours are
    /// multiplied back in by the Wii shader when the material used them).
    /// With no primary texture, the result is the material's single constant colour (one texel).
    static func bake(_ m: J3DModel.Material, primary: Int?, stage primaryStage: J3DModel.Stage?,
                     textures: [J3DModel.Texture], average: (Int) -> SIMD4<Float>, whiteStages: Set<Int> = []) -> [UInt8]? {
        guard let pixels = primary.map({ textures[$0].decoded() }) ?? [255, 255, 255, 255] else { return nil }
        let prevInit = SIMD4<Float>(m.tevColors[3].0, m.tevColors[3].1, m.tevColors[3].2, m.tevColors[3].3)
        let regs: [SIMD4<Float>] = (0...2).map { SIMD4(m.tevColors[$0].0, m.tevColors[$0].1, m.tevColors[$0].2, m.tevColors[$0].3) }
        let k: [SIMD4<Float>] = m.kColors.map { SIMD4($0.0, $0.1, $0.2, $0.3) }
        let fractions: [Float] = [1, 7.0 / 8, 3.0 / 4, 5.0 / 8, 1.0 / 2, 3.0 / 8, 1.0 / 4, 1.0 / 8]
        func konstColor(_ sel: UInt8) -> SIMD3<Float> {
            switch sel {
            case 0...7: return SIMD3(repeating: fractions[Int(sel)])
            case 0x0C...0x0F: let c = k[Int(sel - 0x0C)]; return SIMD3(c.x, c.y, c.z)
            case 0x10...0x1F: let c = k[Int(sel & 3)]; return SIMD3(repeating: c[Int((sel - 0x10) / 4)])
            default: return SIMD3(repeating: 1)
            }
        }
        func konstAlpha(_ sel: UInt8) -> Float {
            switch sel {
            case 0...7: return fractions[Int(sel)]
            case 0x10...0x1F: return k[Int(sel & 3)][Int((sel - 0x10) / 4)]
            default: return 1
            }
        }
        let stageTex: [SIMD4<Float>?] = m.stages.map { st in
            guard st.texMap < 8, let t = m.textures[Int(st.texMap)], textures.indices.contains(t) else { return nil }
            return t == primary && st.texCoord == primaryStage?.texCoord ? nil : average(t)
        }
        let isPrimary: [Bool] = m.stages.map { st in
            guard st.texMap < 8, let t = m.textures[Int(st.texMap)] else { return false }
            return t == primary && st.texCoord == primaryStage?.texCoord
        }
        var out = [UInt8](repeating: 0, count: pixels.count)
        for p in stride(from: 0, to: pixels.count, by: 4) {
            let texel = SIMD4<Float>(Float(pixels[p]), Float(pixels[p + 1]), Float(pixels[p + 2]), Float(pixels[p + 3])) / 255
            var reg = [prevInit] + regs // PREV, C0, C1, C2
            for (i, st) in m.stages.enumerated() {
                let tex = isPrimary[i] ? texel : (whiteStages.contains(i) ? SIMD4(repeating: 1) : (stageTex[i] ?? SIMD4(repeating: 1)))
                let ras: SIMD4<Float> = st.channel == 0xFF ? .zero : SIMD4(repeating: 1)
                let kc = konstColor(st.kColorSel), ka = konstAlpha(st.kAlphaSel)
                func cin(_ v: UInt8) -> SIMD3<Float> {
                    switch v {
                    case 0: return SIMD3(reg[0].x, reg[0].y, reg[0].z)
                    case 1: return SIMD3(repeating: reg[0].w)
                    case 2, 4, 6: let r = reg[Int(v) / 2]; return SIMD3(r.x, r.y, r.z)
                    case 3, 5, 7: return SIMD3(repeating: reg[Int(v) / 2].w)
                    case 8: return SIMD3(tex.x, tex.y, tex.z)
                    case 9: return SIMD3(repeating: tex.w)
                    case 0xA: return SIMD3(ras.x, ras.y, ras.z)
                    case 0xB: return SIMD3(repeating: ras.w)
                    case 0xC: return SIMD3(repeating: 1)
                    case 0xD: return SIMD3(repeating: 0.5)
                    case 0xE: return kc
                    default: return .zero
                    }
                }
                func ain(_ v: UInt8) -> Float {
                    switch v {
                    case 0...3: return reg[Int(v)].w
                    case 4: return tex.w
                    case 5: return ras.w
                    case 6: return ka
                    default: return 0
                    }
                }
                func finish<T: SIMD>(_ d: T, _ lerp: T, _ op: UInt8, _ bias: UInt8, _ scale: UInt8) -> T where T.Scalar == Float {
                    var v = op & 1 == 0 ? d + lerp : d - lerp
                    let b: Float = bias == 1 ? 0.5 : (bias == 2 ? -0.5 : 0)
                    v += T(repeating: b)
                    let sc: Float = [1, 2, 4, 0.5][Int(min(3, scale))]
                    return v * T(repeating: sc)
                }
                let c = st.color, a = st.alpha
                let ca = cin(c.a), cb = cin(c.b), cc = cin(c.c)
                var color = finish(cin(c.d), ca * (SIMD3(repeating: 1) - cc) + cb * cc, c.op, c.bias, c.scale)
                let aa = ain(a.a), ab = ain(a.b), ac = ain(a.c)
                var alpha = finish(SIMD2(repeating: ain(a.d)), SIMD2(repeating: aa * (1 - ac) + ab * ac), a.op, a.bias, a.scale).x
                color = color.clamped(lowerBound: SIMD3(repeating: 0), upperBound: SIMD3(repeating: 1))
                alpha = max(0, min(1, alpha))
                reg[Int(min(3, c.reg))] = SIMD4(color.x, color.y, color.z, reg[Int(min(3, c.reg))].w)
                reg[Int(min(3, a.reg))].w = alpha
            }
            let result = reg[Int(min(3, m.stages.last?.color.reg ?? 0))]
            let alpha = reg[Int(min(3, m.stages.last?.alpha.reg ?? 0))].w
            // The Wii shader doubles the texture (x vertex colour 0x80 or the halved original).
            out[p] = UInt8(max(0, min(255, (result.x * 255).rounded())))
            out[p + 1] = UInt8(max(0, min(255, (result.y * 255).rounded())))
            out[p + 2] = UInt8(max(0, min(255, (result.z * 255).rounded())))
            out[p + 3] = UInt8(max(0, min(255, (alpha * 255).rounded())))
        }
        return out
    }
}
