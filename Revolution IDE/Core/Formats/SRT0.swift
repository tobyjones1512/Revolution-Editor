import Foundation

/// AnmTexSrt(NW4R), a BRRES "SRT0" resource: per-material, per-texture (and per-indirect-texture)
/// keyframed UV scale/rotate/translate animation. Layout verified against `riidefi/RiiStudio`'s
/// actual binary reader (`librii/g3d/io/AnimIO.{hpp,cpp}`: `BinarySrt::read`, `SRT0Material::read`,
/// `SRT0Matrix::read`, `SRT0Track::read`, and the `TargetId`/`Flag`/`isFixed`/`isAttribIncluded`
/// definitions).
///
/// Deliberately reads only as far as this app's preview needs: the header's three leading offsets
/// (`ofsBrres`/`ofsMatDict`/`ofsUserData`) plus the material dictionary and its matrices/tracks --
/// it never parses `BinarySrtInfo` (name/sourcePath/frameDuration/materialCount/wrapMode), whose
/// exact byte layout isn't available from the reader source alone (only its call sites are). That's
/// safe to skip entirely: `ofsMatDict` is enough to jump straight to the material dictionary without
/// sequentially parsing through the info block, and this document derives its own frame range from
/// the tracks' real keyframe data instead of trusting a header field it never read.
nonisolated struct SRT0KeyFrame { var frame: Float; var value: Float; var tangent: Float }
nonisolated struct SRT0Track { var step: Float; var keyframes: [SRT0KeyFrame] }

/// One of a matrix's five channels: either a constant (`FLAG_*_FIXED` set, or excluded and
/// defaulted, see `SRT0Document.defaultTargetSet`) or a keyframed `SRT0Track` (by index into
/// `SRT0Document.tracks`).
nonisolated enum SRT0Channel { case fixed(Float); case track(Int) }

nonisolated struct SRT0TargetSet {
    var scaleU: SRT0Channel
    /// `nil` means "mirror `scaleU`" (`FLAG_SCL_ISOTROPIC`). MKWii materials commonly only ever
    /// scale U and V together, so this is the common case, not an edge case.
    var scaleV: SRT0Channel?
    var rotate: SRT0Channel
    var transU: SRT0Channel
    var transV: SRT0Channel
}

nonisolated struct SRT0MatrixEntry {
    /// The matrix's raw flag word, kept so `build` writes the same channel layout it read.
    var flags: UInt32 = 0
    var isIndirect: Bool
    var slotIndex: Int // which of the material's 8 texture (or 3 indirect) matrix slots
    var targets: SRT0TargetSet
}

nonisolated struct SRT0MaterialEntry {
    var name: String
    var matrices: [SRT0MatrixEntry]
}

nonisolated final class SRT0Document {
    var materials: [SRT0MaterialEntry] = []
    var tracks: [SRT0Track] = []
    var name = ""
    var frameDuration = 0
    /// 0 clamp, 1 repeat.
    var wrapMode: UInt32 = 1

    /// The animation's own frame range, derived from the real keyframe data (see this file's top
    /// doc comment on why, this app never reads the header's own `frameDuration` field). 0 when
    /// every channel is a fixed constant (no tracks at all).
    var maxFrame: Float {
        tracks.flatMap(\.keyframes).map(\.frame).max() ?? 0
    }

    /// A channel's resolved value at `frame`, simple linear interpolation between the two nearest
    /// keyframes (clamped at the ends), not a full cubic-Hermite evaluation using each keyframe's
    /// `tangent`. A preview scrub only needs to look visually close to the game's own curve, not be
    /// bit-exact with it.
    func value(of channel: SRT0Channel, at frame: Float) -> Float {
        switch channel {
        case .fixed(let v): return v
        case .track(let i):
            guard tracks.indices.contains(i) else { return 0 }
            return Self.interpolate(tracks[i], at: frame)
        }
    }

    private static func interpolate(_ track: SRT0Track, at frame: Float) -> Float {
        let kf = track.keyframes
        guard !kf.isEmpty else { return 0 }
        if frame <= kf[0].frame { return kf[0].value }
        if frame >= kf[kf.count - 1].frame { return kf[kf.count - 1].value }
        for i in 0..<(kf.count - 1) where frame >= kf[i].frame && frame <= kf[i + 1].frame {
            let a = kf[i], b = kf[i + 1]
            guard b.frame > a.frame else { return a.value }
            let t = (frame - a.frame) / (b.frame - a.frame)
            return a.value + (b.value - a.value) * t
        }
        return kf[0].value
    }

    // MARK: Flags (`AnimIO.hpp`'s `Flag` enum, exact bit values)

    private static let flagEnabled: UInt32 = 1 << 0
    private static let flagSclOne: UInt32 = 1 << 1
    private static let flagRotZero: UInt32 = 1 << 2
    private static let flagTransZero: UInt32 = 1 << 3
    private static let flagSclIsotropic: UInt32 = 1 << 4
    private static let flagSclUFixed: UInt32 = 1 << 5
    private static let flagSclVFixed: UInt32 = 1 << 6
    private static let flagRotFixed: UInt32 = 1 << 7
    private static let flagTransUFixed: UInt32 = 1 << 8
    private static let flagTransVFixed: UInt32 = 1 << 9

    /// `rawFile`/`resource.fileOffset` are needed for the same reason `MDL0Parser.parse` takes them
    /// (see its doc comment): every dictionary inside a BRRES sub-resource names into the *whole
    /// file's* shared string pool, not the resource's own local bytes, confirmed here the same
    /// way, not assumed: reading the material dictionary's names against `resource.data` alone
    /// parsed real retail SRT0s (`beginner_course.szs`'s `course_model.brres`) with every material
    /// entry present but its name empty, and reading against `rawFile` at `resource.fileOffset`
    /// fixed it.
    static func parse(_ resource: BRRESResource, rawFile: Data) -> SRT0Document? {
        let d = resource.data
        guard d.count >= 0x18, d.asciiString(at: 0, length: 4) == "SRT0" else { return nil }
        let ofsMatDict = Int(Int32(bitPattern: d.be32(0x10)))
        guard ofsMatDict > 0, ofsMatDict < d.count else { return nil }

        let names = (wholeFile: rawFile, offset: resource.fileOffset)
        let entries = BRRESIndexGroup.parse(d, groupStart: ofsMatDict, names: names)
        guard !entries.isEmpty else { return nil }

        let doc = SRT0Document()
        doc.name = resource.name
        doc.frameDuration = Int(d.be16(0x20))
        doc.wrapMode = d.be32(0x28)
        for entry in entries {
            guard let material = parseMaterial(d, start: entry.dataOffset, name: entry.name, doc: doc) else { continue }
            doc.materials.append(material)
        }
        guard !doc.materials.isEmpty else { return nil }
        return doc
    }

    /// `SRT0Material::read`: `enabled_texsrts`/`enabled_indsrts` are bitmasks over 8 texture and 3
    /// indirect matrix slots; the file stores one packed S32 offset (relative to `start`) per *set*
    /// bit only, in slot order, texture slots first then indirect, not a fixed 11-slot array.
    private static func parseMaterial(_ d: Data, start: Int, name: String, doc: SRT0Document) -> SRT0MaterialEntry? {
        guard start + 12 <= d.count else { return nil }
        let enabledTex = d.be32(start + 4)
        let enabledInd = d.be32(start + 8)
        var cursor = start + 12
        var matrices: [SRT0MatrixEntry] = []

        func readSlots(_ mask: UInt32, count: Int, isIndirect: Bool) {
            for slot in 0..<count where (mask & (1 << UInt32(slot))) != 0 {
                guard cursor + 4 <= d.count else { return }
                let ofs = Int(Int32(bitPattern: d.be32(cursor)))
                let at = start + ofs
                cursor += 4
                if let matrix = parseMatrix(d, at: at, isIndirect: isIndirect, slot: slot, doc: doc) {
                    matrices.append(matrix)
                }
            }
        }
        readSlots(enabledTex, count: 8, isIndirect: false)
        readSlots(enabledInd, count: 3, isIndirect: true)

        guard !matrices.isEmpty else { return nil }
        return SRT0MaterialEntry(name: name, matrices: matrices)
    }

    /// `SRT0Matrix::read`: if bit 0 (`FLAG_ENABLED`) of the matrix's own flags is unset, the whole
    /// matrix is identity and nothing further is read for it at all (the real reader's per-target
    /// loop gates on this same bit every iteration). Otherwise each of ScaleU/ScaleV/Rotate/
    /// TransU/TransV is either excluded (a fixed default), a constant `f32`, or a self-relative
    /// offset (relative to *that field's own file position*, per `SRT0Target::read`) to a track.
    private static func parseMatrix(_ d: Data, at: Int, isIndirect: Bool, slot: Int, doc: SRT0Document) -> SRT0MatrixEntry? {
        guard at >= 0, at + 4 <= d.count else { return nil }
        let flags = d.be32(at)
        let defaults = SRT0TargetSet(scaleU: .fixed(1), scaleV: nil, rotate: .fixed(0), transU: .fixed(0), transV: .fixed(0))
        guard flags & flagEnabled != 0 else {
            return SRT0MatrixEntry(flags: flags, isIndirect: isIndirect, slotIndex: slot, targets: defaults)
        }

        var cursor = at + 4
        func readChannel(fixedFlag: UInt32) -> SRT0Channel? {
            guard cursor + 4 <= d.count else { return nil }
            if flags & fixedFlag != 0 {
                let v = d.beFloat32(cursor); cursor += 4
                return .fixed(v)
            }
            let fieldPos = cursor
            let ofs = Int(Int32(bitPattern: d.be32(cursor))); cursor += 4
            guard let index = trackIndex(d, at: fieldPos + ofs, doc: doc) else { return nil }
            return .track(index)
        }

        var scaleU: SRT0Channel = .fixed(1)
        if flags & flagSclOne == 0 {
            guard let c = readChannel(fixedFlag: flagSclUFixed) else { return nil }
            scaleU = c
        }
        var scaleV: SRT0Channel?
        if flags & flagSclIsotropic == 0 {
            guard let c = readChannel(fixedFlag: flagSclVFixed) else { return nil }
            scaleV = c
        }
        var rotate: SRT0Channel = .fixed(0)
        if flags & flagRotZero == 0 {
            guard let c = readChannel(fixedFlag: flagRotFixed) else { return nil }
            rotate = c
        }
        var transU: SRT0Channel = .fixed(0)
        var transV: SRT0Channel = .fixed(0)
        if flags & flagTransZero == 0 {
            guard let cu = readChannel(fixedFlag: flagTransUFixed) else { return nil }
            transU = cu
            guard let cv = readChannel(fixedFlag: flagTransVFixed) else { return nil }
            transV = cv
        }

        return SRT0MatrixEntry(flags: flags, isIndirect: isIndirect, slotIndex: slot,
                               targets: SRT0TargetSet(scaleU: scaleU, scaleV: scaleV, rotate: rotate, transU: transU, transV: transV))
    }

    /// `SRT0Track::read`: u16 keyframe count, 2 reserved bytes, f32 step, then that many keyframes
    /// of 3 `f32`s each (frame, value, tangent), 12 bytes per keyframe. The real format de-
    /// duplicates tracks referenced from more than one place; this read-only preview doesn't need
    /// that, so a shared track is simply parsed (and appended) again each time it's referenced.
    private static func trackIndex(_ d: Data, at: Int, doc: SRT0Document) -> Int? {
        guard at >= 0, at + 8 <= d.count else { return nil }
        let numFrames = Int(d.be16(at))
        guard numFrames >= 0, numFrames < 100_000 else { return nil }
        let step = d.beFloat32(at + 4)
        var keyframes: [SRT0KeyFrame] = []
        keyframes.reserveCapacity(numFrames)
        var cursor = at + 8
        for _ in 0..<numFrames {
            guard cursor + 12 <= d.count else { break }
            keyframes.append(SRT0KeyFrame(frame: d.beFloat32(cursor), value: d.beFloat32(cursor + 4), tangent: d.beFloat32(cursor + 8)))
            cursor += 12
        }
        doc.tracks.append(SRT0Track(step: step, keyframes: keyframes))
        return doc.tracks.count - 1
    }

    // MARK: Writing

    /// The SRT0's bytes (layout per RiiStudio's `BinarySrt::write`), names left for the BRRES
    /// string pool (see `BRRESStringReference`). Identical tracks are stored once.
    func build() -> (data: Data, strings: [BRRESStringReference]) {
        var d = Data(count: 0x2C)
        var strings: [BRRESStringReference] = []
        func put32(_ v: UInt32, at o: Int) { for i in 0..<4 { d[o + i] = UInt8(v >> (24 - 8 * UInt32(i)) & 0xFF) } }
        func append32(_ v: UInt32) { d.append(contentsOf: [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
        func ref(_ at: Int, anchor: Int, _ text: String) { strings.append(BRRESStringReference(fieldOffset: at, anchorOffset: anchor, text: text)) }

        d.replaceSubrange(0..<4, with: "SRT0".utf8)
        put32(5, at: 8)
        ref(0x18, anchor: 0, name)
        d[0x20] = UInt8(frameDuration >> 8 & 0xFF); d[0x21] = UInt8(frameDuration & 0xFF)
        d[0x22] = UInt8(materials.count >> 8 & 0xFF); d[0x23] = UInt8(materials.count & 0xFF)
        put32(wrapMode, at: 0x28)

        // Shared tracks: map each track to the first identical one.
        var unique: [Int] = []
        let canonical: [Int] = tracks.indices.map { i in
            if let u = unique.first(where: { tracks[$0].step == tracks[i].step && tracks[$0].keyframes.map({ [$0.frame, $0.value, $0.tangent] }) == tracks[i].keyframes.map({ [$0.frame, $0.value, $0.tangent] }) }) { return u }
            unique.append(i); return i
        }

        func order(_ m: SRT0MaterialEntry) -> [SRT0MatrixEntry] {
            m.matrices.sorted { ($0.isIndirect ? 1 : 0, $0.slotIndex) < ($1.isIndirect ? 1 : 0, $1.slotIndex) }
        }
        func channels(_ e: SRT0MatrixEntry) -> [SRT0Channel] {
            guard e.flags & Self.flagEnabled != 0 else { return [] }
            var c: [SRT0Channel] = []
            if e.flags & Self.flagSclOne == 0 { c.append(e.targets.scaleU) }
            if e.flags & Self.flagSclIsotropic == 0 { c.append(e.targets.scaleV ?? e.targets.scaleU) }
            if e.flags & Self.flagRotZero == 0 { c.append(e.targets.rotate) }
            if e.flags & Self.flagTransZero == 0 { c += [e.targets.transU, e.targets.transV] }
            return c
        }
        func matrixSize(_ e: SRT0MatrixEntry) -> Int { 4 + 4 * channels(e).count }
        func materialSize(_ m: SRT0MaterialEntry) -> Int { 12 + order(m).reduce(0) { $0 + 4 + matrixSize($1) } }

        let dict = d.count
        let tree = BRRESIndexGroup.buildTree(names: materials.map(\.name))
        append32(UInt32(8 + (materials.count + 1) * 16))
        append32(UInt32(materials.count))
        for node in tree {
            append32(UInt32(node.id) << 16)
            append32(UInt32(node.left) << 16 | UInt32(node.right))
            append32(0); append32(0)
        }
        put32(UInt32(dict), at: 0x10)
        var materialAt: [Int] = [], cursor = d.count
        for m in materials { materialAt.append(cursor); cursor += materialSize(m) }
        var trackAt: [Int: Int] = [:]
        for u in unique { trackAt[u] = cursor; cursor += 8 + 12 * tracks[u].keyframes.count }

        for (i, m) in materials.enumerated() {
            let node = dict + 8 + (i + 1) * 16
            ref(node + 8, anchor: dict, m.name)
            put32(UInt32(materialAt[i] - dict), at: node + 12)
            let start = d.count
            ref(start, anchor: start, m.name)
            append32(0)
            let ms = order(m)
            func mask(_ ind: Bool) -> UInt32 { ms.filter { $0.isIndirect == ind }.reduce(0) { $0 | 1 << UInt32($1.slotIndex) } }
            append32(mask(false)); append32(mask(true))
            var at = start + 12 + ms.count * 4
            for e in ms { append32(UInt32(at - start)); at += matrixSize(e) }
            for e in ms {
                append32(e.flags)
                for c in channels(e) {
                    switch c {
                    case .fixed(let v): append32(v.bitPattern)
                    case .track(let t): append32(UInt32(bitPattern: Int32(trackAt[canonical[t]]! - d.count)))
                    }
                }
            }
        }
        for u in unique {
            let t = tracks[u]
            d.append(contentsOf: [UInt8(t.keyframes.count >> 8 & 0xFF), UInt8(t.keyframes.count & 0xFF), 0, 0])
            append32(t.step.bitPattern)
            for k in t.keyframes { append32(k.frame.bitPattern); append32(k.value.bitPattern); append32(k.tangent.bitPattern) }
        }
        put32(UInt32(d.count), at: 4)
        return (d, strings)
    }
}
