import Foundation

/// NW4R texture-pattern animation (PAT0 v4): swaps which texture a material's sampler draws on a
/// frame schedule, flipbook water, flashing signs, scrolling screens. Layout from RiiStudio's
/// `AnimTexPatIO`; `Tests/PAT0Check` rebuilds every retail PAT0 on the disc and requires the same
/// bytes apart from string offsets.
nonisolated struct PAT0Animation: Equatable {
    struct Key: Equatable { var frame: Float; var texture: Int }
    struct Material: Equatable {
        var name: String
        /// One per enabled sampler, in slot order: the keys of its track (a single key at frame 0
        /// is stored as a constant).
        var samplers: [(slot: Int, keys: [Key])]
        static func == (a: Material, b: Material) -> Bool {
            a.name == b.name && a.samplers.count == b.samplers.count
                && zip(a.samplers, b.samplers).allSatisfy { $0.slot == $1.slot && $0.keys == $1.keys }
        }
    }
    var name: String
    var frameCount: Int
    var loops: Bool
    var materials: [Material]
    var textureNames: [String]

    private static let enabled: UInt32 = 1, constant: UInt32 = 2, textures: UInt32 = 4

    /// The texture index a sampler's keys select at `frame` (keys hold until the next one).
    static func texture(at frame: Float, keys: [Key]) -> Int? {
        keys.last { $0.frame <= frame }?.texture ?? keys.first?.texture
    }

    // MARK: Reading

    static func parse(_ resource: BRRESResource, rawFile: Data) -> PAT0Animation? {
        let d = resource.data
        guard d.count >= 0x3C, d.asciiString(at: 0, length: 4) == "PAT0", d.be32(8) == 4 else { return nil }
        func name(_ fieldAt: Int, anchor: Int) -> String {
            let o = Int(Int32(bitPattern: d.be32(fieldAt)))
            guard o != 0 else { return "" }
            let at = resource.fileOffset + anchor + o
            return at >= 0 && at < rawFile.count ? rawFile.asciiString(at: at, length: rawFile.count - at) : ""
        }
        let matDict = Int(d.be32(0x10)), texNames = Int(d.be32(0x14))
        let textureCount = Int(d.be16(0x34))
        var anim = PAT0Animation(name: name(0x28, anchor: 0), frameCount: Int(d.be16(0x30)), loops: d.be32(0x38) != 0, materials: [], textureNames: [])
        for i in 0..<textureCount where texNames + i * 4 + 4 <= d.count {
            anim.textureNames.append(name(texNames + i * 4, anchor: texNames))
        }
        for entry in BRRESIndexGroup.parse(d, groupStart: matDict, names: (rawFile, resource.fileOffset)) {
            let m = entry.dataOffset
            guard m + 8 <= d.count else { return nil }
            let flags = d.be32(m + 4)
            var p = m + 8
            var samplers: [(Int, [Key])] = []
            for slot in 0..<8 where flags & (enabled << (slot * 4)) != 0 {
                guard p + 4 <= d.count else { return nil }
                if flags & (constant << (slot * 4)) != 0 {
                    samplers.append((slot, [Key(frame: 0, texture: Int(d.be16(p)))]))
                } else {
                    let t = m + Int(Int32(bitPattern: d.be32(p)))
                    guard t >= 0, t + 8 <= d.count else { return nil }
                    let count = Int(d.be16(t))
                    guard t + 8 + count * 8 <= d.count else { return nil }
                    var keys: [Key] = []
                    for k in 0..<count {
                        let e = t + 8 + k * 8
                        keys.append(Key(frame: Float(bitPattern: d.be32(e)), texture: Int(d.be16(e + 4))))
                    }
                    samplers.append((slot, keys))
                }
                p += 4
            }
            anim.materials.append(Material(name: entry.name, samplers: samplers))
        }
        return anim
    }

    // MARK: Writing

    /// The PAT0's bytes, with every name left for the BRRES string pool (see
    /// `BRRESStringReference`): retail keeps all of them there.
    func build() -> (data: Data, strings: [BRRESStringReference]) {
        var d = Data(count: 0x3C)
        var strings: [BRRESStringReference] = []
        func u16(_ v: Int, at o: Int) { d[o] = UInt8(v >> 8 & 0xFF); d[o + 1] = UInt8(v & 0xFF) }
        func u32(_ v: UInt32, at o: Int) { for i in 0..<4 { d[o + i] = UInt8(v >> (24 - 8 * UInt32(i)) & 0xFF) } }
        func append32(_ v: UInt32) { d.append(contentsOf: [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
        func ref(_ fieldAt: Int, anchor: Int, _ text: String) { strings.append(BRRESStringReference(fieldOffset: fieldAt, anchorOffset: anchor, text: text)) }

        d.replaceSubrange(0..<4, with: "PAT0".utf8)
        u32(4, at: 8)
        ref(0x28, anchor: 0, name)
        u16(frameCount, at: 0x30)
        u16(materials.count, at: 0x32)
        u16(textureNames.count, at: 0x34)
        u32(loops ? 1 : 0, at: 0x38)

        // Material dictionary.
        let dict = d.count
        u32(UInt32(dict), at: 0x10)
        let tree = BRRESIndexGroup.buildTree(names: materials.map(\.name))
        append32(UInt32(8 + (materials.count + 1) * 16))
        append32(UInt32(materials.count))
        for node in tree {
            append32(UInt32(node.id) << 16)
            append32(UInt32(node.left) << 16 | UInt32(node.right))
            append32(0); append32(0)
        }
        // Materials, then their (non-constant) tracks, as RiiStudio lays them out.
        var materialAt: [Int] = []
        var cursor = d.count
        for m in materials { materialAt.append(cursor); cursor += 8 + 4 * m.samplers.count }
        // Identical tracks are stored once and shared, and written last-used-first, as retail does.
        var unique: [(keys: [Key], at: Int)] = []
        for m in materials {
            for s in m.samplers where (s.keys.count != 1 || s.keys[0].frame != 0) && !unique.contains(where: { $0.keys == s.keys }) {
                unique.append((s.keys, 0))
            }
        }
        unique.reverse()
        for i in unique.indices { unique[i].at = cursor; cursor += 8 + 8 * unique[i].keys.count }
        let trackAt: [[Int?]] = materials.map { m in
            m.samplers.map { s in unique.first { $0.keys == s.keys && (s.keys.count != 1 || s.keys[0].frame != 0) }?.at }
        }
        for (i, m) in materials.enumerated() {
            let node = dict + 8 + (i + 1) * 16
            ref(node + 8, anchor: dict, m.name)
            u32(UInt32(materialAt[i] - dict), at: node + 12)
            let start = d.count
            ref(start, anchor: start, m.name)
            append32(0)
            var flags: UInt32 = 0
            for (k, s) in m.samplers.enumerated() {
                let bits = Self.enabled | Self.textures | (trackAt[i][k] == nil ? Self.constant : 0)
                flags |= bits << (UInt32(s.slot) * 4)
            }
            append32(flags)
            for (k, s) in m.samplers.enumerated() {
                if let t = trackAt[i][k] { append32(UInt32(bitPattern: Int32(t - start))) }
                else { append32(UInt32(s.keys[0].texture) << 16) }
            }
        }
        for track in unique {
            append32(UInt32(track.keys.count) << 16)
            let span = (track.keys.last?.frame ?? 0) - (track.keys.first?.frame ?? 0)
            append32((span > 0 ? 1 / span : 0).bitPattern)
            for key in track.keys { append32(key.frame.bitPattern); append32(UInt32(key.texture) << 16) }
        }
        // Texture names, then the (empty) palette names and the runtime pointer slots.
        let texNames = d.count
        u32(UInt32(texNames), at: 0x14)
        for (i, t) in textureNames.enumerated() { append32(0); ref(texNames + i * 4, anchor: texNames, t) }
        u32(UInt32(d.count), at: 0x18)
        u32(UInt32(d.count), at: 0x1C)
        for _ in textureNames { append32(0) }
        u32(UInt32(d.count), at: 0x20)
        u32(UInt32(d.count), at: 0x04)
        return (d, strings)
    }

    /// A one-material flipbook: `textures` shown in turn, each for `frameLength` frames.
    static func flipbook(name: String, material: String, slot: Int, textures: [String], frameLength: Int, loops: Bool) -> PAT0Animation {
        var unique: [String] = []
        for t in textures where !unique.contains(t) { unique.append(t) }
        let keys = textures.enumerated().map { Key(frame: Float($0.offset * frameLength), texture: unique.firstIndex(of: $0.element)!) }
        return PAT0Animation(name: name, frameCount: max(1, textures.count * frameLength), loops: loops,
                             materials: [Material(name: material, samplers: [(slot, keys)])], textureNames: unique)
    }
}
