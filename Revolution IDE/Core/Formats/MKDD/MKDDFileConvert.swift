import Foundation

/// Single-file conversion between Mario Kart Wii and Double Dash formats (KCL <-> BCO, KMP <-> BOL),
/// using the same mapping as the whole-archive ports. Without a model there is no ground to lift
/// collision onto and no minimap to place the track in, so these only scale.
nonisolated enum MKDDFileConvert {
    static func kclToBCO(_ kcl: KCLDocument, scale s: Float = MKWiiToMKDD.defaultScale, choices: [UInt16: UInt16?] = [:]) -> Data {
        BCO.build(MKWiiToMKDD.collision(kcl, place: MKWiiToMKDD.Placement(scale: s), choices: choices).triangles)
    }

    static func bcoToKCL(_ data: Data, scale s: Float = MKDDPort.defaultScale, wallStrip: UInt16 = MKDDPort.defaultWallStripFlag) throws -> KCLDocument {
        let bco = try MKDDCollision.parse(data)
        let v = bco.vertices.map { $0 * s }
        let floors = bco.triangles.map { (v[$0.indices.0], v[$0.indices.1], v[$0.indices.2]) }
        let doc = KCLDocument()
        doc.triangles = MKDDPort.collision(bco, floors: floors, scale: s, wallStrip: wallStrip).kcl
        return doc
    }

    static func kmpToBOL(_ kmp: KMPDocument, scale s: Float = MKWiiToMKDD.defaultScale) throws -> KMPDocument {
        guard let start = kmp.ktpt.first else { throw WSError.badStructure("The KMP has no start point.") }
        let bol = BOL.newDocument()
        let startPos = start.position * s
        bol.stgi.lapCount = kmp.stgi.lapCount
        bol.stgi.polePosition = kmp.stgi.polePosition
        bol.ktpt = [KTPTEntry(position: startPos, rotation: start.rotation, playerIndex: -1)]
        bol.enpt = kmp.enpt.map { ENPTEntry(position: $0.position * s, radius: $0.radius * s) }
        bol.enph = kmp.enph.map { PathLinkEntry(startIndex: $0.startIndex, pointCount: $0.pointCount, previousGroups: $0.previousGroups, nextGroups: $0.nextGroups) }
        bol.ckph = kmp.ckph.map { PathLinkEntry(startIndex: $0.startIndex, pointCount: $0.pointCount, previousGroups: $0.previousGroups, nextGroups: $0.nextGroups) }
        bol.ckpt = kmp.ckpt.map { c in
            var rec = Data(count: 0x1C) // checkpoint heights default to the start line's
            rec.replaceSubrange(4..<8, with: withUnsafeBytes(of: startPos.y.bitPattern.bigEndian) { Data($0) })
            rec.replaceSubrange(0x10..<0x14, with: withUnsafeBytes(of: startPos.y.bitPattern.bigEndian) { Data($0) })
            return CKPTEntry(left: Vec2(x: c.left.x * s, y: c.left.y * s), right: Vec2(x: c.right.x * s, y: c.right.y * s), respawnIndex: 0, lapCounterType: c.lapCounterType, bol: rec)
        }
        _ = BOL.repairCheckpointBranches(bol) + BOL.repairCheckpointQuads(bol) + BOL.repairEnemyRouteLinks(bol)
        bol.jgpt = kmp.jgpt.enumerated().map { JGPTEntry(position: $0.element.position * s, rotation: $0.element.rotation, respawnID: UInt16($0.offset)) }
        bol.gobj = kmp.gobj.filter { $0.objectID == 0x0065 || $0.objectID == 0x0076 }.map { GOBJEntry(objectID: 1, position: $0.position * s, rotation: $0.rotation) }
        MKWiiToMKDD.addIntroCameras(from: kmp, to: bol, place: .init(scale: s), start: startPos, yawDegrees: start.rotation.y)
        bol.came.append(MKWiiToMKDD.paradeCamera())
        bol.openingCameraIndex = 0
        return bol
    }

    static func bolToKMP(_ data: Data, scale s: Float = MKDDPort.defaultScale) throws -> KMPDocument {
        let bol = try MKDDCourse.parse(data)
        var report: [String] = []
        return MKDDPort.kmpDocument(from: bol, fullCourse: try? BOL.parse(data), scale: s, kclDoc: KCLDocument(), floorForMap: [], hasItemBoxFiles: true, report: &report)
    }

    static func brresToBMD(_ data: Data, scale s: Float = MKWiiToMKDD.defaultScale) throws -> Data {
        var report: [String] = []
        let m = try MKWiiToMKDD.model(data, modelName: "course", place: .init(scale: s), report: &report)
        let (textures, _) = GCTextures.optimize(m.textures, budget: GCTextures.courseBudget)
        return try J3DWriter.bmd(triangles: m.triangles, materials: m.materials, textures: textures)
    }

    static func bmdToBRRES(_ data: Data, scale s: Float = MKDDPort.defaultScale) throws -> Data {
        try J3DToWii.brres(from: J3DModel.parse(data), modelName: "course", scale: s)
    }

    // MARK: Texture animations (BTK <-> SRT0)
    //
    // A 2D texture matrix uses scale S/T, translation S/T and the Q rotation (as noclip's J3D
    // renderer reads them). Ported BMDs use J3D's basic mode (turning about the BTK centre); MDL0s
    // use Maya mode, whose S translation runs the other way and whose scale pivots elsewhere, so
    // translations are remapped. The materials keep their names: they must match the model the
    // animation is used with.

    static func btkToSRT0BRRES(_ data: Data, name: String) throws -> Data {
        let btk = try J3DAnimation.parse(data)
        guard btk.kind == .textureSRT else { throw WSError.badStructure("Only texture animations (BTK) convert to SRT0.") }
        guard let r = srt0(from: btk, name: name, target: { name, m in (name, m) }) else { throw WSError.badStructure("The BTK animates no texture matrices.") }
        let brres = BRRESDocument()
        brres.resources = [r]
        return brres.serialize()
    }

    /// A J3D basic-mode translation track (pivoting about `center`) as the Maya-mode track giving
    /// the same matrix, or back. Each axis's offset depends only on its own translation; it's
    /// affine in it, so constant scale and rotation remap the keys exactly, and animated ones are
    /// sampled every frame.
    static func translation(_ t: J3DAnimation.Track, axis: Int, scale: [J3DAnimation.Track], rotation: J3DAnimation.Track,
                            center c: [Float], toMaya: Bool) -> J3DAnimation.Track {
        func map(_ f: Float) -> (a: Float, b: Float) {
            let sS = scale[0].value(at: f), sT = scale[1].value(at: f), r = rotation.value(at: f) * .pi / 180
            let cosR = cos(r), sinR = sin(r)
            let basicZ = axis == 0 ? c[0] - (sS * cosR * c[0] - sS * sinR * c[1]) : c[1] - (sT * sinR * c[0] + sT * cosR * c[1])
            if toMaya { // basic offset z = t + basicZ; Maya t from z
                if axis == 0 { let s = sS == 0 ? 1 : sS; return ((-0.5 * cosR - 0.5 * sinR + 0.5) - basicZ / s, -1 / s) }
                let s = sT == 0 ? 1 : sT
                return ((basicZ - 1) / s + 0.5 * cosR - 0.5 * sinR + 0.5, 1 / s)
            }
            // Maya offset z = a + b t; basic t = z - basicZ
            if axis == 0 { return (sS * (-0.5 * cosR - 0.5 * sinR + 0.5) - basicZ, -sS) }
            return (sT * (-0.5 * cosR + 0.5 * sinR - 0.5) + 1 - basicZ, sT)
        }
        if scale.prefix(2).allSatisfy(\.isConstant), rotation.isConstant {
            let (a, b) = map(0)
            return .init(keys: t.keys.map { .init(time: $0.time, value: a + b * $0.value, tangentIn: b * $0.tangentIn, tangentOut: b * $0.tangentOut) })
        }
        let times = (scale.prefix(2) + [rotation, t]).flatMap(\.keys).map(\.time)
        let first = times.min() ?? 0, last = max(first, times.max() ?? 0)
        func v(_ f: Float) -> Float { let (a, b) = map(f); return a + b * t.value(at: f) }
        return .init(keys: stride(from: first, through: last, by: 1).map { f in
            let d = (v(f + 0.5) - v(f - 0.5)); return .init(time: f, value: v(f), tangentIn: d, tangentOut: d)
        })
    }

    /// A BTK as an SRT0 resource. `target` maps each animated (J3D material, texture matrix) to the
    /// MDL0 material and texture slot it moves, or nil to leave it out.
    static func srt0(from btk: J3DAnimation.Animation, name: String, target: (String, Int) -> (name: String, slot: Int)?) -> BRRESResource? {
        let doc = SRT0Document()
        doc.name = name
        doc.frameDuration = btk.duration
        doc.wrapMode = btk.loopMode >= 2 ? 1 : 0
        func channel(_ t: J3DAnimation.Track) -> SRT0Channel {
            if t.isConstant || t.keys.allSatisfy({ $0.value == t.keys[0].value && $0.tangentOut == 0 }) { return .fixed(t.keys.first?.value ?? 0) }
            let span = t.keys[t.keys.count - 1].time - t.keys[0].time
            var frames = t.keys.map { SRT0KeyFrame(frame: $0.time, value: $0.value, tangent: $0.tangentOut) }
            // SRT0 keys have one tangent; a BTK key with different in/out tangents is sampled every frame instead.
            if t.keys.contains(where: { $0.tangentIn != $0.tangentOut }), span >= 1, span < 20000 {
                frames = stride(from: t.keys[0].time, through: t.keys[t.keys.count - 1].time, by: 1).map { f in
                    SRT0KeyFrame(frame: f, value: t.value(at: f), tangent: (t.value(at: f + 0.5) - t.value(at: f - 0.5)) / 1)
                }
            }
            doc.tracks.append(SRT0Track(step: span > 0 ? 1 / span : 0, keyframes: frames))
            return .track(doc.tracks.count - 1)
        }
        for t in btk.targets {
            guard let to = target(t.name, t.texMatrix ?? 0) else { continue }
            let set = SRT0TargetSet(scaleU: channel(t.scale[0]), scaleV: channel(t.scale[1]), rotate: channel(t.rotation[2]),
                                    transU: channel(translation(t.translation[0], axis: 0, scale: t.scale, rotation: t.rotation[2], center: t.center, toMaya: true)),
                                    transV: channel(translation(t.translation[1], axis: 1, scale: t.scale, rotation: t.rotation[2], center: t.center, toMaya: true)))
            var flags: UInt32 = 1 // enabled; every channel written, constants flagged fixed
            for (bit, c) in [(5, set.scaleU), (6, set.scaleV!), (7, set.rotate), (8, set.transU), (9, set.transV)] { if case .fixed = c { flags |= 1 << UInt32(bit) } }
            let entry = SRT0MatrixEntry(flags: flags, isIndirect: false, slotIndex: min(7, to.slot), targets: set)
            if let i = doc.materials.firstIndex(where: { $0.name == to.name }) {
                guard !doc.materials[i].matrices.contains(where: { $0.slotIndex == entry.slotIndex }) else { continue }
                doc.materials[i].matrices.append(entry)
            } else {
                doc.materials.append(SRT0MaterialEntry(name: to.name, matrices: [entry]))
            }
        }
        guard !doc.materials.isEmpty else { return nil }
        let built = doc.build()
        return BRRESResource(name: name, folderName: "AnmTexSrt(NW4R)", data: built.data, stringReferences: built.strings)
    }

    static func brresToBTK(_ data: Data) throws -> Data {
        let brres = try BRRESDocument.parse(data)
        guard let r = brres.resources.first(where: { $0.magic == "SRT0" }), let srt = SRT0Document.parse(r, rawFile: brres.rawData) else {
            throw WSError.badStructure("This BRRES has no readable SRT0 texture animation.")
        }
        guard let btk = btk(from: srt, target: { name, slot in (name, slot) }) else { throw WSError.badStructure("The SRT0 animates no texture matrices.") }
        return try J3DAnimation.serializeBTK(btk)
    }

    /// An SRT0's texture-matrix animations as a BTK. `target` maps each animated (material, texture
    /// slot) to the J3D material name and texture-matrix index it drives, or nil to leave it out.
    static func btk(from srt: SRT0Document, target: (String, Int) -> (name: String, texMatrix: Int)?) -> J3DAnimation.Animation? {
        func track(_ c: SRT0Channel?, _ fallback: Float) -> J3DAnimation.Track {
            switch c {
            case .track(let i)?:
                return .init(keys: srt.tracks[i].keyframes.map { .init(time: $0.frame, value: $0.value, tangentIn: $0.tangent, tangentOut: $0.tangent) })
            case .fixed(let v)?: return .init(keys: [.init(time: 0, value: v, tangentIn: 0, tangentOut: 0)])
            case nil: return .init(keys: [.init(time: 0, value: fallback, tangentIn: 0, tangentOut: 0)])
            }
        }
        var targets: [J3DAnimation.Target] = []
        for m in srt.materials {
            for e in m.matrices where !e.isIndirect {
                guard let to = target(m.name, e.slotIndex) else { continue }
                let t = e.targets
                let scale = [track(t.scaleU, 1), track(t.scaleV ?? t.scaleU, 1), track(nil, 1)], rotate = track(t.rotate, 0)
                let center: [Float] = [0.5, 0.5, 0.5] // as J3DWriter's texture matrices
                targets.append(.init(name: to.name, texMatrix: to.texMatrix, center: center, scale: scale,
                                     rotation: [track(nil, 0), track(nil, 0), rotate],
                                     translation: [translation(track(t.transU, 0), axis: 0, scale: scale, rotation: rotate, center: center, toMaya: false),
                                                   translation(track(t.transV, 0), axis: 1, scale: scale, rotation: rotate, center: center, toMaya: false), track(nil, 0)]))
            }
        }
        guard !targets.isEmpty else { return nil }
        let duration = srt.frameDuration > 0 ? srt.frameDuration : Int(srt.maxFrame.rounded(.up))
        // Every retail course/sky BTK loops (mode 2).
        return .init(kind: .textureSRT, duration: duration, loopMode: srt.wrapMode == 1 ? 2 : 0, targets: targets)
    }
}
