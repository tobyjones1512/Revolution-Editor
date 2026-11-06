import Foundation

/// Wiimm's compact track formats, `.wbz` (bzip2) and `.wlz` (LZMA), and plain `.szs` (Yaz0) --
/// all three hold the same U8 archive. Ported from Wiimm's SZS Tools (`lib-szs.c`,
/// `lib-bzip2.c`, `lib-lzma.c`):
///
/// File: magic "WBZa"/"WLZa", the first 8 bytes of the payload, the payload size (u32 BE), then
/// a bzip2 stream (WBZ) or an LZMA-alone stream (WLZ: 5 property bytes, 8 bytes 0xFF, raw LZMA).
/// The payload is a "WU8" archive: a U8 archive XOR-coded against Nintendo's own object files so
/// the tracks can't be used without the game --
///  1. base key = XOR of the four bytes of the archive size.
///  2. Files in `wu8ReferenceFiles` are XORed with base ^ the retail copy of that file (repeating);
///     each such file also folds `ref[n/2] ^ ref[n/3] ^ ref[n/4]` into a second key (starting at
///     base). If none are present, `itembox.brres` is folded in instead.
///  3. Every other file is XORed with that second key.
///  4. The node table + names (0x20 ..< 0x20 + fst size) are XORed with base; magic "U8" <-> "WU8a".
/// Decoding runs 1, 4, 2, 3.
nonisolated enum WiimmArchive {
    enum Format: String, CaseIterable, Identifiable {
        case szs, wbz, wlz
        var id: String { rawValue }
        var title: String { "." + rawValue }
    }

    enum CodecError: LocalizedError {
        case badHeader, compression(String), missingReference(String)
        var errorDescription: String? {
            switch self {
            case .badHeader: return "Not a valid .szs, .wbz or .wlz file."
            case .compression(let why): return why
            case .missingReference(let path): return "Can't code this archive: the Mario Kart Wii file \(path) wasn't found on the linked base game disc. (.wbz/.wlz tracks are coded against the retail object files, link your disc in Settings > Games.)"
            }
        }
    }

    /// A retail object file by its path in a course archive (`itembox.brres`, `effect/coin/rk_coin.breff`).
    typealias References = (String) throws -> Data?

    static func format(of data: Data) -> Format? {
        guard data.count >= 4 else { return nil }
        switch data.asciiString(at: 0, length: 4) {
        case "WBZa": return .wbz
        case "WLZa": return .wlz
        default: return Yaz0.isYaz0(data) ? .szs : nil
        }
    }

    /// Any of the three -> the raw U8 archive.
    static func decode(_ data: Data, references: References) throws -> Data {
        switch format(of: data) {
        case .szs: return try Yaz0.decode(data)
        case .wbz, .wlz:
            guard data.count > 0x10 else { throw CodecError.badHeader }
            let size = Int(data.be32(0x0C))
            let body = data.subdata(in: (data.startIndex + 0x10)..<data.endIndex)
            var payload = format(of: data) == .wbz ? try BZip2.decompress(body, size: size) : try LZMA.decompressAlone(body, size: size)
            if payload.count >= 4, payload.be32(0) == wu8Magic { try code(&payload, encode: false, references: references) }
            return payload
        case nil: throw CodecError.badHeader
        }
    }

    /// Raw U8 archive -> the given format.
    static func encode(_ u8: Data, as format: Format, references: References) throws -> Data {
        if format == .szs { return Yaz0.encode(u8) }
        var payload = u8
        try code(&payload, encode: true, references: references)
        let body = format == .wbz
            ? try BZip2.compress(payload, level: min(9, payload.count / 100_000 + 1))
            : try LZMA.compressAlone(payload, preset: 6)
        var out = Data((format == .wbz ? "WBZa" : "WLZa").utf8)
        out.append(payload.prefix(8))
        out.append(contentsOf: withUnsafeBytes(of: UInt32(payload.count).bigEndian, Array.init))
        out.append(body)
        return out
    }

    // MARK: WU8

    static let u8Magic: UInt32 = 0x55AA_382D
    static let wu8Magic: UInt32 = 0x5755_3861 // "WU8a"

    static func code(_ d: inout Data, encode: Bool, references: References) throws {
        guard d.count >= 0x20, d.be32(0) == (encode ? u8Magic : wu8Magic) else { throw CodecError.badHeader }
        let size = UInt32(d.count)
        let base = UInt8(size & 0xFF) ^ UInt8(size >> 8 & 0xFF) ^ UInt8(size >> 16 & 0xFF) ^ UInt8(size >> 24)
        let nodeOffset = Int(d.be32(4)), fstSize = Int(d.be32(8))
        guard nodeOffset + fstSize <= d.count else { throw CodecError.badHeader }

        func xorTable() { d.withUnsafeMutableBytes { p in for i in nodeOffset..<(nodeOffset + fstSize) { p[i] ^= base } } }
        if !encode { xorTable() }

        // Walk the U8 node table: 12-byte nodes (type, 24-bit name offset, data offset / parent,
        // size / next); names follow the nodes. Paths skip the root, and a leading "./".
        let count = Int(d.be32(nodeOffset + 8))
        let names = nodeOffset + count * 12
        guard count > 0, names <= d.count else { throw CodecError.badHeader }
        var files: [(path: String, offset: Int, size: Int)] = []
        var dirs: [(end: Int, path: String)] = []
        for i in 1..<count {
            while let last = dirs.last, i >= last.end { dirs.removeLast() }
            let n = nodeOffset + i * 12
            var nameEnd = names + Int(d.be32(n) & 0xFF_FFFF)
            let nameStart = nameEnd
            while nameEnd < d.count, d[d.startIndex + nameEnd] != 0 { nameEnd += 1 }
            let name = String(decoding: d[(d.startIndex + nameStart)..<(d.startIndex + nameEnd)], as: UTF8.self)
            let path = ((dirs.last.map { $0.path + "/" } ?? "") + name)
            if d[d.startIndex + n] == 1 { dirs.append((Int(d.be32(n + 8)), path)) }
            else { files.append((path.hasPrefix("./") ? String(path.dropFirst(2)) : path, Int(d.be32(n + 4)), Int(d.be32(n + 8)))) }
        }

        var conv = base
        func load(_ path: String) throws -> Data {
            guard let ref = try references(path), !ref.isEmpty else { throw CodecError.missingReference(path) }
            let n = ref.count
            conv ^= ref[ref.startIndex + n / 2] ^ ref[ref.startIndex + n / 3] ^ ref[ref.startIndex + n / 4]
            return ref
        }
        var coded = Set<Int>()
        for (i, f) in files.enumerated() where wu8ReferenceFiles.contains(f.path) {
            let ref = try load(f.path)
            coded.insert(i)
            guard f.offset + f.size <= d.count else { throw CodecError.badHeader }
            d.withUnsafeMutableBytes { p in
                ref.withUnsafeBytes { r in
                    for k in 0..<f.size { p[f.offset + k] ^= base ^ r[k % r.count] }
                }
            }
        }
        if coded.isEmpty { _ = try load("itembox.brres") }
        for (i, f) in files.enumerated() where !coded.contains(i) && f.offset + f.size <= d.count {
            d.withUnsafeMutableBytes { p in for k in f.offset..<(f.offset + f.size) { p[k] ^= conv } }
        }

        if encode { xorTable() }
        d.withUnsafeMutableBytes { p in
            let m = (encode ? wu8Magic : u8Magic).bigEndian
            withUnsafeBytes(of: m) { for k in 0..<4 { p[k] = $0[k] } }
        }
    }

    /// Wiimm's "auto-add" library: where each reference file is taken from, the first of these
    /// retail archives (in this order, `<name>.szs` then `<name>_d.szs`) that contains it.
    static let referenceArchiveOrder = [
        "beginner_course", "farm_course", "kinoko_course", "factory_course", "castle_course", "shopping_course",
        "boardcross_course", "truck_course", "senior_course", "water_course", "treehouse_course", "volcano_course",
        "desert_course", "ridgehighway_course", "koopa_course", "rainbow_course", "old_peach_gc", "old_falls_ds",
        "old_obake_sfc", "old_mario_64", "old_sherbet_64", "old_heyho_gba", "old_town_ds", "old_waluigi_gc",
        "old_desert_ds", "old_koopa_gba", "old_donkey_64", "old_mario_gc", "old_mario_sfc", "old_garden_ds",
        "old_donkey_gc", "old_koopa_64", "block_battle", "venice_battle", "skate_battle", "casino_battle",
        "sand_battle", "old_battle4_sfc", "old_battle3_gba", "old_matenro_64", "old_CookieLand_gc", "old_House_ds",
        "winningrun_demo", "loser_demo", "ending_demo", "old_mario_gc_b", "ring_mission",
    ]
}

// MARK: - System compression libraries (libbz2 / liblzma ship with macOS)

private nonisolated func systemSymbol<T>(_ library: String, _ name: String, as: T.Type) throws -> T {
    guard let handle = dlopen(library, RTLD_NOW), let sym = dlsym(handle, name) else {
        throw WiimmArchive.CodecError.compression("Couldn't load \(name) from \(library).")
    }
    return unsafeBitCast(sym, to: T.self)
}

nonisolated enum BZip2 {
    private static let lib = "/usr/lib/libbz2.1.0.dylib"
    private typealias Compress = @convention(c) (UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<CChar>?, UInt32, Int32, Int32, Int32) -> Int32
    private typealias Decompress = @convention(c) (UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<CChar>?, UInt32, Int32, Int32) -> Int32

    static func compress(_ data: Data, level: Int) throws -> Data {
        let fn = try systemSymbol(lib, "BZ2_bzBuffToBuffCompress", as: Compress.self)
        var src = data
        var out = Data(count: data.count + data.count / 100 + 600)
        var outLen = UInt32(out.count)
        let status = out.withUnsafeMutableBytes { o in
            src.withUnsafeMutableBytes { s in
                fn(o.baseAddress?.assumingMemoryBound(to: CChar.self), &outLen, s.baseAddress?.assumingMemoryBound(to: CChar.self), UInt32(s.count), Int32(max(1, level)), 0, 0)
            }
        }
        guard status == 0 else { throw WiimmArchive.CodecError.compression("bzip2 compression failed (\(status)).") }
        return out.prefix(Int(outLen))
    }

    static func decompress(_ data: Data, size: Int) throws -> Data {
        let fn = try systemSymbol(lib, "BZ2_bzBuffToBuffDecompress", as: Decompress.self)
        var src = data
        var out = Data(count: size)
        var outLen = UInt32(size)
        let status = out.withUnsafeMutableBytes { o in
            src.withUnsafeMutableBytes { s in
                fn(o.baseAddress?.assumingMemoryBound(to: CChar.self), &outLen, s.baseAddress?.assumingMemoryBound(to: CChar.self), UInt32(s.count), 0, 0)
            }
        }
        guard status == 0 else { throw WiimmArchive.CodecError.compression("bzip2 data is damaged (\(status)).") }
        return out.prefix(Int(outLen))
    }
}

nonisolated enum LZMA {
    private static let lib = "/usr/lib/liblzma.5.dylib"
    /// liblzma's public `lzma_stream` (ABI-stable since 5.0).
    private struct Stream {
        var nextIn: UnsafePointer<UInt8>? = nil, availIn = 0, totalIn: UInt64 = 0
        var nextOut: UnsafeMutablePointer<UInt8>? = nil, availOut = 0, totalOut: UInt64 = 0
        var allocator: UnsafeRawPointer? = nil, internalState: UnsafeRawPointer? = nil
        var r1: UnsafeRawPointer? = nil, r2: UnsafeRawPointer? = nil, r3: UnsafeRawPointer? = nil, r4: UnsafeRawPointer? = nil
        var seekPos: UInt64 = 0, r6: UInt64 = 0, r7 = 0, r8 = 0, e1: Int32 = 0, e2: Int32 = 0
    }
    private typealias AloneEncoder = @convention(c) (UnsafeMutableRawPointer, UnsafeRawPointer) -> Int32
    private typealias AloneDecoder = @convention(c) (UnsafeMutableRawPointer, UInt64) -> Int32
    private typealias Preset = @convention(c) (UnsafeMutableRawPointer, UInt32) -> UInt8
    private typealias Code = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
    private typealias End = @convention(c) (UnsafeMutableRawPointer) -> Void

    static func compressAlone(_ data: Data, preset: UInt32) throws -> Data {
        let options = UnsafeMutableRawPointer.allocate(byteCount: 512, alignment: 16)
        defer { options.deallocate() }
        options.initializeMemory(as: UInt8.self, repeating: 0, count: 512)
        guard try systemSymbol(lib, "lzma_lzma_preset", as: Preset.self)(options, preset) == 0 else { throw WiimmArchive.CodecError.compression("Bad LZMA preset.") }
        return try run(data, capacity: data.count + data.count / 2 + 1024) { try systemSymbol(lib, "lzma_alone_encoder", as: AloneEncoder.self)($0, options) }
    }

    static func decompressAlone(_ data: Data, size: Int) throws -> Data {
        try run(data, capacity: size) { try systemSymbol(lib, "lzma_alone_decoder", as: AloneDecoder.self)($0, UInt64.max) }
    }

    private static func run(_ data: Data, capacity: Int, setup: (UnsafeMutableRawPointer) throws -> Int32) throws -> Data {
        let code = try systemSymbol(lib, "lzma_code", as: Code.self), end = try systemSymbol(lib, "lzma_end", as: End.self)
        let stream = UnsafeMutablePointer<Stream>.allocate(capacity: 1)
        stream.initialize(to: Stream())
        defer { end(stream); stream.deallocate() }
        guard try setup(stream) == 0 else { throw WiimmArchive.CodecError.compression("Couldn't start LZMA.") }
        var out = Data(count: max(capacity, 64))
        let status: Int32 = data.withUnsafeBytes { s in
            out.withUnsafeMutableBytes { o in
                stream.pointee.nextIn = s.baseAddress?.assumingMemoryBound(to: UInt8.self)
                stream.pointee.availIn = s.count
                stream.pointee.nextOut = o.baseAddress?.assumingMemoryBound(to: UInt8.self)
                stream.pointee.availOut = o.count
                return code(stream, 3) // LZMA_FINISH
            }
        }
        // LZMA_STREAM_END = 1; a size-known decode may stop at LZMA_OK with all output written.
        guard status == 1 || (status == 0 && stream.pointee.availOut == 0) else { throw WiimmArchive.CodecError.compression("LZMA coding failed (\(status)).") }
        return out.prefix(Int(stream.pointee.totalOut))
    }
}
