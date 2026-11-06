import Foundation

/// A CHR0 bone animation (version 5, Mario Kart Wii's), read as far as the 3D preview needs to
/// play it: per bone, each of scale/rotation/translation X/Y/Z as a constant, a keyframed track
/// (Hermite between keys) or a baked per-frame track. Layout per RiiStudio's
/// `librii/g3d/io/AnimChrIO` (header 0x2C: dictionary offset 0x10, frame count 0x20, wrap 0x24;
/// node: name offset, flags, then one value or track offset per stored attribute).
nonisolated struct CHR0Animation {
    enum Value {
        case constant(Float)
        /// (frame, value, slope)
        case keys([(Float, Float, Float)])
        /// One value per frame, 0...frameCount.
        case baked([Float])
    }

    struct Node {
        var name: String
        var flags: UInt32
        /// Scale X/Y/Z, rotation X/Y/Z (degrees), translation X/Y/Z; nil = not animated (the
        /// bone's own value, or identity where the flags say so).
        var values: [Value?]
    }

    var name: String
    var frameCount: Int
    var loops: Bool
    var nodes: [Node]

    static func parse(_ resource: BRRESResource, rawFile: Data) -> CHR0Animation? {
        let d = resource.data
        guard d.count >= 0x2C, d.asciiString(at: 0, length: 4) == "CHR0", d.be32(8) == 5 else { return nil }
        let names = (wholeFile: rawFile, offset: resource.fileOffset)
        let frameCount = Int(d.be16(0x20))
        let loops = d.be32(0x24) != 0
        let dict = Int(Int32(bitPattern: d.be32(0x10)))
        guard dict > 0, dict < d.count else { return nil }
        var nodes: [Node] = []
        for entry in BRRESIndexGroup.parse(d, groupStart: dict, names: names) {
            let start = entry.dataOffset
            guard start > 0, start + 8 <= d.count else { continue }
            let flags = d.be32(start + 4)
            var cursor = start + 8
            var values: [Value?] = []
            // Which attributes are stored, and how (RiiStudio's CHR0Flags).
            let identity: UInt32 = 1 << 1, rtZero: UInt32 = 1 << 2, sclOne: UInt32 = 1 << 3, iso: UInt32 = 1 << 4
            let rotZero: UInt32 = 1 << 5, transZero: UInt32 = 1 << 6
            let sclModel: UInt32 = 1 << 7, rotModel: UInt32 = 1 << 8, transModel: UInt32 = 1 << 9
            let omit: [UInt32] = [identity | sclOne | sclModel, identity | sclOne | iso | sclModel, identity | sclOne | iso | sclModel,
                                  identity | rtZero | rotZero | rotModel, identity | rtZero | rotZero | rotModel, identity | rtZero | rotZero | rotModel,
                                  identity | rtZero | transZero | transModel, identity | rtZero | transZero | transModel, identity | rtZero | transZero | transModel]
            let format = [Int((flags >> 25) & 3), Int((flags >> 27) & 7), Int((flags >> 30) & 3)]
            for attr in 0..<9 {
                guard flags & omit[attr] == 0 else { values.append(nil); continue }
                guard cursor + 4 <= d.count else { values.append(nil); continue }
                let fmt = flags & (1 << UInt32(13 + attr)) != 0 ? 0 : format[attr / 3]
                if fmt == 0 {
                    values.append(.constant(d.beFloat32(cursor)))
                } else {
                    let track = start + Int(Int32(bitPattern: d.be32(cursor)))
                    values.append(readTrack(d, track, format: fmt, rotation: attr / 3 == 1, frameCount: frameCount))
                }
                cursor += 4
            }
            // Isotropic scale stores X only.
            if flags & iso != 0, flags & (identity | sclOne | sclModel) == 0 { values[1] = values[0]; values[2] = values[0] }
            nodes.append(Node(name: entry.name, flags: flags, values: values))
        }
        return CHR0Animation(name: resource.name, frameCount: max(1, frameCount), loops: loops, nodes: nodes)
    }

    /// Formats 1-3: keyed (32/48/96-bit keys); for rotation 4-6 are baked (8/16/32-bit per frame).
    private static func readTrack(_ d: Data, _ o: Int, format: Int, rotation: Bool, frameCount: Int) -> Value? {
        guard o > 0 else { return nil }
        if rotation && format >= 4 {
            let n = frameCount + 1
            switch format {
            case 4, 5:
                guard o + 8 + n * (format == 4 ? 1 : 2) <= d.count else { return nil }
                let scale = d.beFloat32(o), offset = d.beFloat32(o + 4)
                return .baked((0..<n).map { i in Float(format == 4 ? Int(d.u8(o + 8 + i)) : Int(d.be16(o + 8 + i * 2))) * scale + offset })
            default:
                guard o + n * 4 <= d.count else { return nil }
                return .baked((0..<n).map { d.beFloat32(o + $0 * 4) })
            }
        }
        guard o + 8 <= d.count else { return nil }
        let count = Int(d.be16(o))
        var keys: [(Float, Float, Float)] = []
        switch format {
        case 1:
            guard o + 16 + count * 4 <= d.count else { return nil }
            let scale = d.beFloat32(o + 8), offset = d.beFloat32(o + 12)
            for i in 0..<count {
                let x = d.be32(o + 16 + i * 4)
                var slope = Int32(x & 0xFFF); if slope & 0x800 != 0 { slope |= ~0xFFF }
                keys.append((Float(x >> 24), Float((x >> 12) & 0xFFF) * scale + offset, Float(slope) / 32))
            }
        case 2:
            guard o + 16 + count * 6 <= d.count else { return nil }
            let scale = d.beFloat32(o + 8), offset = d.beFloat32(o + 12)
            for i in 0..<count {
                let k = o + 16 + i * 6
                keys.append((Float(Int16(bitPattern: d.be16(k))) / 32, Float(d.be16(k + 2)) * scale + offset, Float(Int16(bitPattern: d.be16(k + 4))) / 256))
            }
        default:
            guard o + 8 + count * 12 <= d.count else { return nil }
            for i in 0..<count {
                let k = o + 8 + i * 12
                keys.append((d.beFloat32(k), d.beFloat32(k + 4), d.beFloat32(k + 8)))
            }
        }
        return keys.isEmpty ? nil : .keys(keys)
    }

    /// The value at `frame`: Hermite between keys (NW4R's), linear between baked frames.
    static func sample(_ v: Value, at frame: Float) -> Float {
        switch v {
        case .constant(let c): return c
        case .baked(let values):
            let f = max(0, min(frame, Float(values.count - 1)))
            let i = Int(f), t = f - Float(i)
            return i + 1 < values.count ? values[i] + (values[i + 1] - values[i]) * t : values[i]
        case .keys(let keys):
            if frame <= keys[0].0 { return keys[0].1 }
            if frame >= keys[keys.count - 1].0 { return keys[keys.count - 1].1 }
            let i = keys.lastIndex { $0.0 <= frame }!
            let (f0, v0, s0) = keys[i], (f1, v1, s1) = keys[i + 1]
            let dt = f1 - f0
            guard dt > 0 else { return v1 }
            let t = (frame - f0) / dt, t2 = t * t, t3 = t2 * t
            return v0 * (2 * t3 - 3 * t2 + 1) + v1 * (-2 * t3 + 3 * t2) + s0 * dt * (t3 - 2 * t2 + t) + s1 * dt * (t3 - t2)
        }
    }
}
