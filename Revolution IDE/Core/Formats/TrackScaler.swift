import Foundation

/// Scales a whole Mario Kart Wii course about the world origin: the course/skybox/minimap
/// models (vertex positions + bones), the collision, and every KMP position and size, so they
/// all still line up afterwards, what `wszst`'s `--scale` does to MDL, KCL and KMP together.
///
/// Models are patched in place: each position buffer keeps its own on-disk format, and when a
/// fixed-point buffer's values would overflow it the buffer's fraction bits (and every mesh's
/// matching GX vertex-attribute-table entry) are lowered to make room.
nonisolated enum TrackScaler {
    /// Course files that hold world geometry. Object models (`kuribo.brres`, ...) are left alone:
    /// they're sized per object by the GOBJ scale instead.
    static func isTrackModel(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.hasSuffix(".brres") && (n.hasPrefix("course") || n.hasPrefix("vrcorn") || n.hasPrefix("map_model"))
    }

    /// A Double Dash course's world models (`luigi_course.bmd`, `luigi_sky.bmd`); its objects
    /// live in `objects/` and are sized by their course-data scale instead.
    static func isDoubleDashTrackModel(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.hasSuffix("_course.bmd") || n.hasSuffix("_sky.bmd")
    }

    /// Scales every course file in an archive's top level and returns the names changed. All or
    /// nothing: if any file can't be scaled, the archive is left untouched.
    static func scale(archive root: U8Node, by s: Float, objects: Bool) throws -> [String] {
        var scaled: [(U8Node, Data)] = []
        for node in root.children where !node.isDirectory {
            guard let data = node.data else { continue }
            let name = node.name.lowercased()
            if name.hasSuffix(".bol") {
                let doc = try BOL.parse(data)
                scale(kmp: doc, by: s, objects: objects)
                scaled.append((node, doc.serialize()))
            } else if name.hasSuffix(".bco") {
                let doc = try BCO.parse(data)
                scale(kcl: doc, by: s)
                scaled.append((node, doc.serialize()))
            } else if isDoubleDashTrackModel(name) {
                scaled.append((node, try scale(bmd: data, by: s)))
            } else if name.hasSuffix(".kmp") {
                let doc = try KMPDocument.parse(data)
                scale(kmp: doc, by: s, objects: objects)
                scaled.append((node, doc.serialize()))
            } else if name.hasSuffix(".kcl") {
                let doc = try KCLDocument.parse(data)
                scale(kcl: doc, by: s)
                scaled.append((node, doc.serialize()))
            } else if isTrackModel(name) {
                scaled.append((node, try scale(brres: data, by: s)))
            }
        }
        for (node, data) in scaled { node.data = data }
        return scaled.map(\.0.name)
    }

    // MARK: KMP

    static func scale(kmp d: KMPDocument, by s: Float, objects: Bool) {
        func v(_ p: inout Vec3) { p = Vec3(x: p.x * s, y: p.y * s, z: p.z * s) }
        // Route speeds are units/frame: scaling them keeps every camera/object's timing the same.
        func speed(_ u: inout UInt16) { u = UInt16(clamping: Int((Float(u) * s).rounded())) }
        for i in d.ktpt.indices { v(&d.ktpt[i].position) }
        for i in d.enpt.indices { v(&d.enpt[i].position); d.enpt[i].radius *= s }
        for i in d.itpt.indices { v(&d.itpt[i].position); d.itpt[i].radius *= s }
        for i in d.ckpt.indices {
            d.ckpt[i].left = Vec2(x: d.ckpt[i].left.x * s, y: d.ckpt[i].left.y * s)
            d.ckpt[i].right = Vec2(x: d.ckpt[i].right.x * s, y: d.ckpt[i].right.y * s)
        }
        for i in d.gobj.indices {
            v(&d.gobj[i].position)
            if objects { v(&d.gobj[i].scale) }
        }
        for r in d.poti.indices {
            for p in d.poti[r].points.indices { v(&d.poti[r].points[p].position); speed(&d.poti[r].points[p].setting1) }
        }
        for i in d.area.indices { v(&d.area[i].position); v(&d.area[i].scale) }
        for i in d.came.indices {
            v(&d.came[i].position); v(&d.came[i].viewPositionStart); v(&d.came[i].viewPositionEnd)
            speed(&d.came[i].viewVelocity)
        }
        for i in d.jgpt.indices { v(&d.jgpt[i].position) }
        for i in d.cnpt.indices { v(&d.cnpt[i].position) }
        for i in d.mspt.indices { v(&d.mspt[i].position) }
    }

    // MARK: KCL

    static func scale(kcl d: KCLDocument, by s: Float) {
        for i in d.triangles.indices {
            d.triangles[i].v0 = d.triangles[i].v0 * s
            d.triangles[i].v1 = d.triangles[i].v1 * s
            d.triangles[i].v2 = d.triangles[i].v2 * s
        }
    }

    // MARK: J3D (Double Dash)

    /// A `.bmd` with every vertex position, joint translation and bounding volume scaled in place.
    /// 16-bit positions give up fraction bits when the scaled values wouldn't fit (as for MDL0).
    static func scale(bmd input: Data, by s: Float) throws -> Data {
        var d = Data(input)
        var sections: [String: Int] = [:]
        var off = 0x20
        while off + 8 <= d.count {
            let size = Int(d.be32(off + 4))
            guard size >= 8 else { break }
            sections[d.asciiString(at: off, length: 4)] = off
            off += size
        }
        guard let vtx = sections["VTX1"] else { throw WSError.badStructure("Not a J3D model (no VTX1).") }
        func putFloat(_ v: Float, _ o: Int) { d.replaceSubrange(o..<(o + 4), with: be32(v.bitPattern)) }
        func scaleFloat(_ o: Int) { putFloat(d.beFloat32(o) * s, o) }

        // Positions: the VTX1 array for attribute 9.
        let formats = vtx + Int(d.be32(vtx + 8))
        let offsets = (0..<13).map { Int(d.be32(vtx + 0x0C + $0 * 4)) }
        var f = formats
        while f + 0x10 <= d.count, d.be32(f) != 0xFF {
            defer { f += 0x10 }
            guard d.be32(f) == 9, offsets[0] != 0 else { continue }
            let type = Int(d.be32(f + 8))
            let start = vtx + offsets[0]
            let end = offsets.dropFirst().filter { $0 > offsets[0] }.map { vtx + $0 }.min() ?? (vtx + Int(d.be32(vtx + 4)))
            switch type {
            case 4:
                var o = start
                while o + 4 <= end { scaleFloat(o); o += 4 }
            case 3:
                let values = stride(from: start, to: end - 1, by: 2).map { Float(Int16(bitPattern: d.be16($0))) }
                var frac = Int(d.u8(f + 12)), shift: Float = 1
                while frac > 0, (values.map { abs($0 * s / shift) }.max() ?? 0) > 32767 { frac -= 1; shift *= 2 }
                guard (values.map { abs($0 * s / shift) }.max() ?? 0) <= 32767 else {
                    throw WSError.badStructure("This model's 16-bit positions can't grow \(s)x. Scale it down, or by less.")
                }
                d[f + 12] = UInt8(frac)
                for (k, v) in values.enumerated() {
                    let o = start + k * 2
                    d.replaceSubrange(o..<(o + 2), with: be16(UInt16(bitPattern: Int16((v * s / shift).rounded()))))
                }
            default:
                throw WSError.badStructure("This model stores positions in a format that can't be scaled (type \(type)).")
            }
        }
        // Joints: translation, bounding radius and box.
        if let jnt = sections["JNT1"] {
            let entries = jnt + Int(d.be32(jnt + 0x0C))
            for j in 0..<Int(d.be16(jnt + 8)) {
                let e = entries + j * 0x40
                for o in stride(from: 0x18, through: 0x3C, by: 4) { scaleFloat(e + o) }
            }
        }
        // Shapes: bounding radius and box (what culling tests).
        if let shp = sections["SHP1"] {
            let entries = shp + Int(d.be32(shp + 0x0C))
            for k in 0..<Int(d.be16(shp + 8)) {
                let e = entries + k * 0x28
                for o in stride(from: 0x0C, through: 0x24, by: 4) { scaleFloat(e + o) }
            }
        }
        // Envelopes: the translation column of each inverse bind matrix.
        if let evp = sections["EVP1"], d.be32(evp + 0x18) != 0 {
            let matrices = evp + Int(d.be32(evp + 0x18))
            let count = (Int(d.be32(evp + 4)) - (matrices - evp)) / 48
            for m in 0..<count { for o in [12, 28, 44] { scaleFloat(matrices + m * 48 + o) } }
        }
        return d
    }

    private static func be16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
    private static func be32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }

    // MARK: BRRES / MDL0

    static func scale(brres data: Data, by s: Float) throws -> Data {
        let doc = try BRRESDocument.parse(data)
        for r in doc.resources where r.magic == "MDL0" {
            var d = r.data
            try scale(mdl0: &d, by: s, name: r.name)
            r.data = d
        }
        return doc.serialize()
    }

    /// ponytail: CHR0 bone animations in the same file aren't scaled, no retail course model
    /// animates bone translations, but a custom one that does would drift.
    static func scale(mdl0 d: inout Data, by s: Float, name: String) throws {
        guard d.count >= 0x90, d.asciiString(at: 0, length: 4) == "MDL0", d.be32(8) == 11 else {
            throw WSError.badStructure("\(name): only version 11 MDL0 models can be scaled.")
        }
        func secOfs(_ i: Int) -> Int { Int(Int32(bitPattern: d.be32(0x10 + i * 4))) }
        func mulF(_ at: Int) { d.setBEFloat32(d.beFloat32(at) * s, at: at) }

        // Model info bounding box (min @0x74, max @0x80).
        for k in 0..<6 { mulF(0x74 + k * 4) }

        // Bones: SRT translation, bounding box, and the translation column of both matrices.
        if secOfs(1) > 0 {
            for bone in BRRESIndexGroup.parse(d, groupStart: secOfs(1)) {
                let b = bone.dataOffset
                guard b >= 0, b + 0xD0 <= d.count else { continue }
                for k in 0..<3 { mulF(b + 0x38 + k * 4) }
                for k in 0..<6 { mulF(b + 0x44 + k * 4) }
                for row in 0..<3 { mulF(b + 0x70 + row * 16 + 12); mulF(b + 0xA0 + row * 16 + 12) }
            }
        }

        guard secOfs(2) > 0 else { return }
        let meshes = secOfs(10) > 0 ? BRRESIndexGroup.parse(d, groupStart: secOfs(10)).map(\.dataOffset) : []
        for (index, buffer) in BRRESIndexGroup.parse(d, groupStart: secOfs(2)).enumerated() {
            let b = buffer.dataOffset
            guard b >= 0, b + 0x38 <= d.count else { continue }
            let components = d.be32(b + 0x14) == 0 ? 2 : 3
            let type = d.be32(b + 0x18)
            let divisor = Int(d.u8(b + 0x1C))
            let count = Int(d.be16(b + 0x1E))
            let start = b + Int(Int32(bitPattern: d.be32(b + 0x08)))
            let n = count * components
            for k in 0..<6 { mulF(b + 0x20 + k * 4) } // min/max

            if type == 4 {
                for k in 0..<n where start + k * 4 + 4 <= d.count { mulF(start + k * 4) }
                continue
            }
            let size = type < 2 ? 1 : 2
            guard start >= 0, start + n * size <= d.count else { continue }
            let (lo, hi): (Int, Int) = switch type { case 0: (0, 255); case 1: (-128, 127); case 2: (0, 65535); default: (-32768, 32767) }
            func raw(_ k: Int) -> Int {
                let p = start + k * size
                switch type {
                case 0: return Int(d.u8(p))
                case 1: return Int(Int8(bitPattern: d.u8(p)))
                case 2: return Int(d.be16(p))
                default: return Int(d.beInt16(p))
                }
            }
            let values = (0..<n).map(raw)
            // Fewest fraction bits lost: drop one bit at a time until the scaled values fit.
            var newDivisor = divisor
            func fits(_ div: Int) -> Bool {
                let f = s * Float(1 << div) / Float(1 << divisor)
                return values.allSatisfy { let x = Int((Float($0) * f).rounded()); return x >= lo && x <= hi }
            }
            while newDivisor > 0, !fits(newDivisor) { newDivisor -= 1 }
            guard fits(newDivisor) else {
                // ponytail: no format widening (S16 -> F32 grows the MDL0, and a resized MDL0 can't
                // move without breaking its string-pool offsets), so the ceiling is the format's range.
                let peak = values.map { $0 < 0 ? Float($0) / Float(lo) : Float($0) / Float(hi) }.max() ?? 1
                let limit = Float(1 << divisor) / max(peak, 1e-9)
                throw WSError.badStructure("\(name): its vertex data is stored in a fixed-point format that can't hold the track \(s)x larger, the most it can be scaled up is about \(String(format: "%.2f", limit))x.")
            }
            let f = s * Float(1 << newDivisor) / Float(1 << divisor)
            for (k, value) in values.enumerated() {
                let x = Int((Float(value) * f).rounded()), p = start + k * size
                switch type {
                case 0: d.setU8(UInt8(x), at: p)
                case 1: d.setU8(UInt8(bitPattern: Int8(x)), at: p)
                case 2: d.setBE16(UInt16(x), at: p)
                default: d.setBE16(UInt16(bitPattern: Int16(x)), at: p)
                }
            }
            if newDivisor != divisor {
                d.setU8(UInt8(newDivisor), at: b + 0x1C)
                for m in meshes where m >= 0 && m + 0x4A <= d.count && Int(d.beInt16(m + 0x48)) == index {
                    setPositionFraction(&d, mesh: m, to: newDivisor)
                }
            }
        }
    }

    /// Rewrites the position fraction bits (VAT group A bits 4-8) in a mesh's vertex-setup
    /// display list, the value the GPU actually dequantizes with; the buffer header's copy is
    /// only a cache of it.
    private static func setPositionFraction(_ d: inout Data, mesh m: Int, to frac: Int) {
        let tag = m + 0x18
        let size = Int(d.be32(tag))
        var pos = tag + Int(Int32(bitPattern: d.be32(tag + 8)))
        let end = min(pos + size, d.count)
        while pos < end {
            let op = d.u8(pos); pos += 1
            switch op {
            case 0x00: continue
            case 0x08:
                guard pos + 5 <= d.count else { return }
                if (0x70...0x77).contains(d.u8(pos)) {
                    let v = d.be32(pos + 1)
                    d.setBE32((v & ~(0x1F << 4)) | (UInt32(frac & 0x1F) << 4), at: pos + 1)
                }
                pos += 5
            case 0x61: pos += 4
            case 0x10:
                guard pos + 4 <= d.count else { return }
                pos += 4 + (Int(d.be16(pos)) + 1) * 4
            default: return
            }
        }
    }
}
