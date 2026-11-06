import Foundation

/// Reads GameCube J3D animations: `.btk` ("J3D1btk1", TTK1, per-material texture-matrix
/// scale/rotation/translation keyframes, e.g. scrolling water) and `.bca` ("J3D1bca1", ANF1 --
/// per-joint scale/rotation/translation with one value per frame, e.g. driver animations).
/// Layouts follow the J3D format as the community documents it (noclip's J3DLoader) and were
/// checked against every .btk/.bca on a retail Double Dash disc (`Tests/J3DAnimationCheck`).
///
/// View-only: nothing here writes these files back.
nonisolated enum J3DAnimation {
    struct Key { var time: Float; var value: Float; var tangentIn: Float; var tangentOut: Float }

    /// One animated component. A single key is a constant; BCA has one key per frame.
    struct Track {
        var keys: [Key]
        var isConstant: Bool { keys.count <= 1 }

        /// Hermite between keyframes (linear when the tangents are zero, as BCA's are).
        func value(at frame: Float) -> Float {
            guard let first = keys.first else { return 0 }
            guard frame > first.time else { return first.value }
            guard let i = keys.firstIndex(where: { $0.time > frame }) else { return keys[keys.count - 1].value }
            let a = keys[i - 1], b = keys[i]
            let span = b.time - a.time, t = (frame - a.time) / span
            let t2 = t * t, t3 = t2 * t
            return (2 * t3 - 3 * t2 + 1) * a.value + (t3 - 2 * t2 + t) * a.tangentOut * span
                 + (-2 * t3 + 3 * t2) * b.value + (t3 - t2) * b.tangentIn * span
        }
    }

    /// A material's texture matrix (BTK) or a joint (BCA); each array is X/Y/Z (U/V/W for BTK).
    /// Rotations are in degrees.
    struct Target {
        var name: String
        var texMatrix: Int?
        /// BTK texture-matrix centre (S, T, Q): rotation and scale turn about it.
        var center: [Float] = [0.5, 0.5, 0.5]
        var scale: [Track]
        var rotation: [Track]
        var translation: [Track]
    }

    struct Animation {
        enum Kind: String { case textureSRT = "BTK", joint = "BCA" }
        var kind: Kind
        var duration: Int
        /// 0 once, 1 once + reset, 2 loop, 3 mirror once, 4 mirror loop.
        var loopMode: UInt8
        var targets: [Target]
        /// BTK rotation scale: stored values are degrees / (2^exp * 180 / 0x7FFF).
        var rotationExponent: UInt8 = 0

        var loopName: String {
            let names = ["Once", "Once (reset)", "Loop", "Mirror once", "Mirror loop"]
            return Int(loopMode) < names.count ? names[Int(loopMode)] : "Mode \(loopMode)"
        }
    }

    static func parse(_ data: Data) throws -> Animation {
        let d = Data(data)
        guard d.count >= 0x40, d.asciiString(at: 0, length: 4) == "J3D1" else {
            throw WSError.badStructure("Not a J3D animation (missing 'J3D1' magic).")
        }
        let s = 0x20 // the first (only) section
        func off(_ o: Int) -> Int { s + Int(d.be32(s + o)) }
        func f32(_ table: Int, _ i: Int) -> Float { table + i * 4 + 4 <= d.count ? d.beFloat32(table + i * 4) : 0 }
        func s16(_ table: Int, _ i: Int) -> Float { table + i * 2 + 2 <= d.count ? Float(Int16(bitPattern: d.be16(table + i * 2))) : 0 }

        switch d.asciiString(at: s, length: 4) {
        case "TTK1":
            let degrees = Float(1 << min(15, Int(d.u8(s + 9)))) * 180 / 0x7FFF
            let count = Int(d.be16(s + 0x0C)) / 3
            let anims = off(0x14), names = off(0x1C), mtx = off(0x20)
            let sTable = off(0x28), rTable = off(0x2C), tTable = off(0x30)
            /// count, first index, tangent mode (0: in == out, 1: separate out). A rotation key's
            /// time is plain frames; only its value and tangents are scaled to degrees.
            func track(_ o: Int, _ raw: (Int) -> Float, scale: Float = 1) -> Track {
                let n = Int(d.be16(o)), first = Int(d.be16(o + 2))
                guard n > 1 else { return Track(keys: [Key(time: 0, value: raw(first) * scale, tangentIn: 0, tangentOut: 0)]) }
                let stride = d.be16(o + 4) == 0 ? 3 : 4
                return Track(keys: (0..<n).map { k in
                    let i = first + k * stride
                    return Key(time: raw(i), value: raw(i + 1) * scale, tangentIn: raw(i + 2) * scale, tangentOut: raw(i + stride - 1) * scale)
                })
            }
            let targets = (0..<count).map { m -> Target in
                let base = anims + m * 0x36
                func axis(_ o: Int, _ raw: (Int) -> Float, scale: Float = 1) -> [Track] {
                    (0..<3).map { track(base + $0 * 0x12 + o, raw, scale: scale) }
                }
                let c = off(0x24) + m * 12
                return Target(name: nameTable(d, names, m) ?? "Material \(m)", texMatrix: Int(d.u8(mtx + m)),
                              center: c + 12 <= d.count ? [d.beFloat32(c), d.beFloat32(c + 4), d.beFloat32(c + 8)] : [0.5, 0.5, 0.5],
                              scale: axis(0) { f32(sTable, $0) }, rotation: axis(6, { s16(rTable, $0) }, scale: degrees),
                              translation: axis(0x0C) { f32(tTable, $0) })
            }
            return Animation(kind: .textureSRT, duration: Int(d.be16(s + 0x0A)), loopMode: d.u8(s + 8), targets: targets, rotationExponent: d.u8(s + 9))

        case "ANF1":
            let degrees: Float = 180 / 0x7FFF
            let joints = off(0x14), sTable = off(0x18), rTable = off(0x1C), tTable = off(0x20)
            let targets = (0..<Int(d.be16(s + 0x0C))).map { j -> Target in
                let base = joints + j * 36
                func axis(_ o: Int, _ value: @escaping (Int) -> Float) -> [Track] {
                    (0..<3).map { a in
                        let e = base + a * 12 + o, n = Int(d.be16(e)), first = Int(d.be16(e + 2))
                        return Track(keys: (0..<max(1, n)).map { Key(time: Float($0), value: value(first + $0), tangentIn: 0, tangentOut: 0) })
                    }
                }
                return Target(name: "Joint \(j)", texMatrix: nil, scale: axis(0) { f32(sTable, $0) },
                              rotation: axis(4) { s16(rTable, $0) * degrees }, translation: axis(8) { f32(tTable, $0) })
            }
            return Animation(kind: .joint, duration: Int(d.be16(s + 0x0A)), loopMode: d.u8(s + 8), targets: targets)

        default:
            throw WSError.badStructure("Unsupported J3D animation section '\(d.asciiString(at: s, length: 4))' (BTK/TTK1 and BCA/ANF1 are supported).")
        }
    }

    /// Entry `i` of a JUT name table (u16 count, pad, then u16 hash + u16 offset per name).
    static func nameTable(_ d: Data, _ table: Int, _ i: Int) -> String? {
        guard table + 4 <= d.count, i < Int(d.be16(table)) else { return nil }
        var e = table + Int(d.be16(table + 4 + i * 4 + 2))
        let start = e
        while e < d.count, d.u8(e) != 0 { e += 1 }
        return String(decoding: d[start..<e], as: UTF8.self)
    }

    // MARK: Writing (BTK)

    private static func be16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
    private static func be32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }

    /// A `.btk` ("J3D1btk1", TTK1) from a texture-SRT animation. Layout per `parse`/noclip's loader.
    /// Tracks are stored back to back (no value sharing between tracks); a track whose in and out
    /// tangents agree uses the 3-value key form.
    static func serializeBTK(_ a: Animation) throws -> Data {
        guard a.kind == .textureSRT else { throw WSError.badStructure("Only texture animations (BTK) can be written.") }
        // Smallest exponent whose 16-bit range holds every rotation value and tangent.
        let peak = a.targets.flatMap(\.rotation).flatMap(\.keys).flatMap { [abs($0.value), abs($0.tangentIn), abs($0.tangentOut)] }.max() ?? 0
        var exp = Int(a.rotationExponent)
        while exp < 15, peak > Float(32767) * Float(1 << exp) * 180 / 0x7FFF { exp += 1 }
        let degrees = Float(1 << exp) * 180 / 0x7FFF

        var sTable = Data(), rTable = Data(), tTable = Data(), tracks = Data()
        var sCount = 0, rCount = 0, tCount = 0
        func s16(_ v: Float) -> Data { be16(UInt16(bitPattern: Int16(max(-32768, min(32767, v.rounded()))))) }
        func track(_ t: Track, table: inout Data, count: inout Int, isRotation: Bool, isTime: Bool = false) {
            func put(_ v: Float, time: Bool) {
                if isRotation { table.append(s16(time ? v : v / degrees)); count += 1 } else { table.append(be32(v.bitPattern)); count += 1 }
            }
            let keys = t.keys.isEmpty ? [Key(time: 0, value: 0, tangentIn: 0, tangentOut: 0)] : t.keys
            tracks.append(be16(UInt16(keys.count))); tracks.append(be16(UInt16(count)))
            if keys.count == 1 { tracks.append(be16(0)); put(keys[0].value, time: false); return }
            let same = keys.allSatisfy { $0.tangentIn == $0.tangentOut }
            tracks.append(be16(same ? 0 : 1))
            for k in keys {
                put(k.time, time: true); put(k.value, time: false); put(k.tangentIn, time: false)
                if !same { put(k.tangentOut, time: false) }
            }
        }
        for t in a.targets {
            for axis in 0..<3 {
                track(t.scale[axis], table: &sTable, count: &sCount, isRotation: false)
                track(t.rotation[axis], table: &rTable, count: &rCount, isRotation: true)
                track(t.translation[axis], table: &tTable, count: &tCount, isRotation: false)
            }
        }

        var body = Data(count: 0x58)
        func align4() { while body.count % 4 != 0 { body.append(0) } }
        func at(_ o: Int, _ v: UInt32) { body.replaceSubrange(o..<o + 4, with: be32(v)) }
        func here() -> UInt32 { UInt32(body.count + 8) } // offsets are from the chunk start; the magic and size precede `body`
        body[0] = a.loopMode; body[1] = UInt8(exp)
        body.replaceSubrange(2..<4, with: be16(UInt16(a.duration)))
        body.replaceSubrange(4..<6, with: be16(UInt16(a.targets.count * 3)))
        body.replaceSubrange(6..<8, with: be16(UInt16(sCount)))
        body.replaceSubrange(8..<10, with: be16(UInt16(rCount)))
        body.replaceSubrange(10..<12, with: be16(UInt16(tCount)))
        func section(_ field: Int, _ data: Data) { at(field - 8, here()); body.append(data); align4() }
        section(0x14, tracks)
        section(0x18, Data((0..<a.targets.count).flatMap { be16(UInt16($0)) }))
        section(0x1C, J3DWriter.nameTable(a.targets.map(\.name)))
        section(0x20, Data(a.targets.enumerated().map { UInt8($0.element.texMatrix ?? $0.offset) }))
        section(0x24, Data(a.targets.flatMap { $0.center.prefix(3).flatMap { be32($0.bitPattern) } }))
        section(0x28, sTable); section(0x2C, rTable); section(0x30, tTable)
        let chunk = J3DWriter.section("TTK1", body)
        var out = Data("J3D1btk1".utf8)
        out.append(be32(UInt32(0x20 + chunk.count))); out.append(be32(1))
        out.append(Data("SVR1".utf8)); out.append(Data(repeating: 0xFF, count: 12))
        out.append(chunk)
        return out
    }
}
