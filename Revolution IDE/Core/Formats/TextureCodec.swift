import Foundation

/// Decodes/encodes the tiled GX texture formats used throughout Wii graphics data (TEX0 in
/// BRRES, and identically in every other GX-based format). Every format below packs texels into
/// small rectangular "tiles" read in raster order across the whole image, the specific tile
/// size/layout differs per format but the outer tiling loop is shared.
nonisolated enum GXTextureFormat: UInt32, Hashable {
    case i4 = 0
    case i8 = 1
    case ia4 = 2
    case ia8 = 3
    case rgb565 = 4
    case rgb5a3 = 5
    case rgba32 = 6
    case ci4 = 8
    case ci8 = 9
    case ci14x2 = 10
    case cmpr = 14

    var tileWidth: Int {
        switch self {
        case .i4, .ia4, .cmpr, .rgba32: return 8
        default: return self == .i8 ? 8 : 4
        }
    }
    var tileHeight: Int {
        switch self {
        case .i4, .cmpr, .rgba32: return 8
        case .i8, .ia4: return 4
        default: return 4
        }
    }
}

/// The three pixel encodings GX supports for a texture's *palette* (TLUT) entries, distinct
/// from `GXTextureFormat`'s raw-value numbering. Every palette entry is 2 bytes regardless of
/// which of these three is in use.
nonisolated enum GXPaletteFormat: UInt32 {
    case ia8 = 0
    case rgb565 = 1
    case rgb5a3 = 2
}

nonisolated enum TextureCodec {
    /// Decodes one raw 16-bit palette (TLUT) entry to RGBA8, per `GXPaletteFormat`.
    static func decodePaletteEntry(_ v: UInt16, format: GXPaletteFormat) -> (UInt8, UInt8, UInt8, UInt8) {
        switch format {
        case .ia8:
            let a = UInt8((v >> 8) & 0xFF), i = UInt8(v & 0xFF)
            return (i, i, i, a)
        case .rgb565:
            return rgb565ToRGBA(v)
        case .rgb5a3:
            return rgb5a3ToRGBA(v)
        }
    }

    /// Decodes to tightly-packed RGBA8 (row-major, top-to-bottom), or `nil` if the region is
    /// short of data / the format needs a palette that wasn't supplied.
    static func decode(data: Data, offset: Int, width: Int, height: Int, format: GXTextureFormat,
                        palette: [(UInt8, UInt8, UInt8, UInt8)]? = nil) -> [UInt8]? {
        // GX textures top out at 1024x1024; a bigger header is corrupt, and would allocate gigabytes.
        guard width > 0, height > 0, width <= 4096, height <= 4096 else { return nil }
        var out = [UInt8](repeating: 0, count: width * height * 4)

        func put(_ x: Int, _ y: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) {
            guard x < width, y < height else { return }
            let idx = (y * width + x) * 4
            out[idx] = r; out[idx + 1] = g; out[idx + 2] = b; out[idx + 3] = a
        }

        switch format {
        case .i4:
            try_(width, height, 8, 8, tileBytes: 32) { tx, ty, bytePos in
                var bytePos = bytePos
                for row in 0..<8 {
                    for col in stride(from: 0, to: 8, by: 2) {
                        guard let byte = data.byteAt(offset + bytePos) else { return }
                        let hi = byte >> 4, lo = byte & 0xF
                        let iHi = hi &* 17, iLo = lo &* 17
                        put(tx + col, ty + row, iHi, iHi, iHi, 255)
                        put(tx + col + 1, ty + row, iLo, iLo, iLo, 255)
                        bytePos += 1
                    }
                }
            }
        case .i8:
            try_(width, height, 8, 4, tileBytes: 32) { tx, ty, bytePos in
                var bytePos = bytePos
                for row in 0..<4 { for col in 0..<8 {
                    guard let v = data.byteAt(offset + bytePos) else { return }
                    put(tx + col, ty + row, v, v, v, 255); bytePos += 1
                } }
            }
        case .ia4:
            try_(width, height, 8, 4, tileBytes: 32) { tx, ty, bytePos in
                var bytePos = bytePos
                for row in 0..<4 { for col in 0..<8 {
                    guard let byte = data.byteAt(offset + bytePos) else { return }
                    let a = (byte >> 4) &* 17, i = (byte & 0xF) &* 17
                    put(tx + col, ty + row, i, i, i, a); bytePos += 1
                } }
            }
        case .ia8:
            try_(width, height, 4, 4, tileBytes: 32) { tx, ty, bytePos in
                var bytePos = bytePos
                for row in 0..<4 { for col in 0..<4 {
                    guard let a = data.byteAt(offset + bytePos), let i = data.byteAt(offset + bytePos + 1) else { return }
                    put(tx + col, ty + row, i, i, i, a); bytePos += 2
                } }
            }
        case .rgb565:
            try_(width, height, 4, 4, tileBytes: 32) { tx, ty, bytePos in
                var bytePos = bytePos
                for row in 0..<4 { for col in 0..<4 {
                    guard let v = data.be16At(offset + bytePos) else { return }
                    let r5 = UInt8((v >> 11) & 0x1F), g6 = UInt8((v >> 5) & 0x3F), b5 = UInt8(v & 0x1F)
                    put(tx + col, ty + row, expand5(r5), expand6(g6), expand5(b5), 255)
                    bytePos += 2
                } }
            }
        case .rgb5a3:
            try_(width, height, 4, 4, tileBytes: 32) { tx, ty, bytePos in
                var bytePos = bytePos
                for row in 0..<4 { for col in 0..<4 {
                    guard let v = data.be16At(offset + bytePos) else { return }
                    let c = rgb5a3ToRGBA(v)
                    put(tx + col, ty + row, c.0, c.1, c.2, c.3)
                    bytePos += 2
                } }
            }
        case .rgba32:
            try_(width, height, 4, 4, tileBytes: 64) { tx, ty, bytePos in
                var p = bytePos
                var pix = [[UInt8]](repeating: [0, 0, 0, 0], count: 16)
                for i in 0..<16 {
                    guard let a = data.byteAt(offset + p), let r = data.byteAt(offset + p + 1) else { return }
                    pix[i][3] = a; pix[i][0] = r; p += 2
                }
                for i in 0..<16 {
                    guard let g = data.byteAt(offset + p), let b = data.byteAt(offset + p + 1) else { return }
                    pix[i][1] = g; pix[i][2] = b; p += 2
                }
                for row in 0..<4 { for col in 0..<4 {
                    let i = row * 4 + col
                    put(tx + col, ty + row, pix[i][0], pix[i][1], pix[i][2], pix[i][3])
                } }
            }
        case .cmpr:
            try_(width, height, 8, 8, tileBytes: 32) { tx, ty, bytePos in
                var p = bytePos
                for sub in 0..<4 {
                    let subX = tx + (sub % 2) * 4
                    let subY = ty + (sub / 2) * 4
                    guard let block = data.subdataOpt(at: offset + p, length: 8) else { return }
                    decodeDXT1Block(block, into: &out, imageWidth: width, imageHeight: height, originX: subX, originY: subY)
                    p += 8
                }
            }
        case .ci4:
            guard let palette else { return nil }
            try_(width, height, 8, 8, tileBytes: 32) { tx, ty, bytePos in
                var bytePos = bytePos
                for row in 0..<8 {
                    for col in stride(from: 0, to: 8, by: 2) {
                        guard let byte = data.byteAt(offset + bytePos) else { return }
                        let hi = Int(byte >> 4), lo = Int(byte & 0xF)
                        if hi < palette.count { let c = palette[hi]; put(tx + col, ty + row, c.0, c.1, c.2, c.3) }
                        if lo < palette.count { let c = palette[lo]; put(tx + col + 1, ty + row, c.0, c.1, c.2, c.3) }
                        bytePos += 1
                    }
                }
            }
        case .ci8:
            guard let palette else { return nil }
            try_(width, height, 8, 4, tileBytes: 32) { tx, ty, bytePos in
                var bytePos = bytePos
                for row in 0..<4 { for col in 0..<8 {
                    guard let idx = data.byteAt(offset + bytePos) else { return }
                    if Int(idx) < palette.count { let c = palette[Int(idx)]; put(tx + col, ty + row, c.0, c.1, c.2, c.3) }
                    bytePos += 1
                } }
            }
        case .ci14x2:
            return nil // rare; not supported
        }
        return out
    }

    private static func try_(_ width: Int, _ height: Int, _ tw: Int, _ th: Int, tileBytes: Int, _ block: (Int, Int, Int) -> Void) {
        var bytePos = 0
        let tilesX = (width + tw - 1) / tw
        let tilesY = (height + th - 1) / th
        for ty in 0..<tilesY {
            for tx in 0..<tilesX {
                block(tx * tw, ty * th, bytePos)
                bytePos += tileBytes
            }
        }
    }

    private static func decodeDXT1Block(_ block: Data, into out: inout [UInt8], imageWidth: Int, imageHeight: Int, originX: Int, originY: Int) {
        guard let c0raw = block.be16At(0), let c1raw = block.be16At(2) else { return }
        let c0 = rgb565ToRGBA(c0raw), c1 = rgb565ToRGBA(c1raw)
        var palette: [(UInt8, UInt8, UInt8, UInt8)] = [c0, c1]
        if c0raw > c1raw {
            palette.append(lerp(c0, c1, 1, 3)); palette.append(lerp(c0, c1, 2, 3))
        } else {
            palette.append(lerp(c0, c1, 1, 2)); palette.append((0, 0, 0, 0))
        }
        guard block.count >= 8 else { return }
        let indexBytes = [UInt8](block.subdata(in: 4..<8))
        for row in 0..<4 {
            let rowByte = indexBytes[row]
            for col in 0..<4 {
                let shift = (3 - col) * 2
                let idx = Int((rowByte >> shift) & 0x3)
                let c = palette[idx]
                let x = originX + col, y = originY + row
                guard x < imageWidth, y < imageHeight else { continue }
                let o = (y * imageWidth + x) * 4
                out[o] = c.0; out[o + 1] = c.1; out[o + 2] = c.2; out[o + 3] = c.3
            }
        }
    }

    private static func rgb565ToRGBA(_ v: UInt16) -> (UInt8, UInt8, UInt8, UInt8) {
        (expand5(UInt8((v >> 11) & 0x1F)), expand6(UInt8((v >> 5) & 0x3F)), expand5(UInt8(v & 0x1F)), 255)
    }
    private static func rgb5a3ToRGBA(_ v: UInt16) -> (UInt8, UInt8, UInt8, UInt8) {
        if v & 0x8000 != 0 {
            let r5 = UInt8((v >> 10) & 0x1F), g5 = UInt8((v >> 5) & 0x1F), b5 = UInt8(v & 0x1F)
            return (expand5(r5), expand5(g5), expand5(b5), 255)
        } else {
            let a3 = UInt8((v >> 12) & 0x7), r4 = UInt8((v >> 8) & 0xF), g4 = UInt8((v >> 4) & 0xF), b4 = UInt8(v & 0xF)
            return (expand4(r4), expand4(g4), expand4(b4), expand3(a3))
        }
    }
    private static func lerp(_ a: (UInt8, UInt8, UInt8, UInt8), _ b: (UInt8, UInt8, UInt8, UInt8), _ num: Int, _ den: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        func l(_ x: UInt8, _ y: UInt8) -> UInt8 { UInt8((Int(x) * (den - num) + Int(y) * num) / den) }
        return (l(a.0, b.0), l(a.1, b.1), l(a.2, b.2), 255)
    }

    private static func expand3(_ v: UInt8) -> UInt8 { (v << 5) | (v << 2) | (v >> 1) }
    private static func expand4(_ v: UInt8) -> UInt8 { (v << 4) | v }
    private static func expand5(_ v: UInt8) -> UInt8 { (v << 3) | (v >> 2) }
    private static func expand6(_ v: UInt8) -> UInt8 { (v << 2) | (v >> 4) }

    // MARK: Encoding (for texture replace)

    /// Encodes tightly-packed RGBA8 pixels into one of the simpler, widely-supported formats.
    /// CMPR uses a fast (non-exhaustive) per-block min/max endpoint choice, good enough for
    /// modding purposes, not a competitive compressor.
    static func encode(rgba: [UInt8], width: Int, height: Int, format: GXTextureFormat) -> Data? {
        switch format {
        case .rgba32: return encodeRGBA32(rgba, width, height)
        case .rgb565: return encodeSimple(rgba, width, height, tw: 4, th: 4) { r, g, b, _ in
            let v = (UInt16(r >> 3) << 11) | (UInt16(g >> 2) << 5) | UInt16(b >> 3)
            return [UInt8(v >> 8), UInt8(v & 0xFF)]
        }
        case .rgb5a3: return encodeSimple(rgba, width, height, tw: 4, th: 4) { r, g, b, a in
            if a >= 0xE0 {
                let v: UInt16 = 0x8000 | (UInt16(r >> 3) << 10) | (UInt16(g >> 3) << 5) | UInt16(b >> 3)
                // Opaque texels can also be stored in 4-bit mode with alpha 7, retail files do
                //, and when that reproduces the colour more exactly, use it.
                if a == 0xFF {
                    let v4 = (UInt16(7) << 12) | (UInt16(r >> 4) << 8) | (UInt16(g >> 4) << 4) | UInt16(b >> 4)
                    func err(_ x: UInt16) -> Int {
                        let c = rgb5a3ToRGBA(x)
                        return abs(Int(c.0) - Int(r)) + abs(Int(c.1) - Int(g)) + abs(Int(c.2) - Int(b))
                    }
                    if err(v4) < err(v) { return [UInt8(v4 >> 8), UInt8(v4 & 0xFF)] }
                }
                return [UInt8(v >> 8), UInt8(v & 0xFF)]
            } else {
                let v = (UInt16(a >> 5) << 12) | (UInt16(r >> 4) << 8) | (UInt16(g >> 4) << 4) | UInt16(b >> 4)
                return [UInt8(v >> 8), UInt8(v & 0xFF)]
            }
        }
        case .i8: return encodeSimple(rgba, width, height, tw: 8, th: 4) { r, g, b, _ in
            [UInt8((Int(r) + Int(g) + Int(b)) / 3)]
        }
        case .i4: return encodeNibble(rgba, width, height) { r, g, b, _ in UInt8((Int(r) + Int(g) + Int(b)) / 3) >> 4 }
        case .ia8: return encodeSimple(rgba, width, height, tw: 4, th: 4) { r, g, b, a in
            [a, UInt8((Int(r) + Int(g) + Int(b)) / 3)]
        }
        case .ia4: return encodeNibblePair(rgba, width, height)
        case .cmpr: return encodeCMPR(rgba, width, height)
        default: return nil
        }
    }

    private static func encodeRGBA32(_ rgba: [UInt8], _ width: Int, _ height: Int) -> Data {
        let w = MutableDataWriter()
        forEachTile(width, height, 4, 4) { tx, ty in
            var ar: [UInt8] = []; var gb: [UInt8] = []
            for row in 0..<4 { for col in 0..<4 {
                let (r, g, b, a) = sample(rgba, width, height, tx + col, ty + row)
                ar.append(a); ar.append(r); gb.append(g); gb.append(b)
            } }
            w.putData(Data(ar)); w.putData(Data(gb))
        }
        return w.data
    }

    private static func encodeSimple(_ rgba: [UInt8], _ width: Int, _ height: Int, tw: Int, th: Int,
                                      _ f: (UInt8, UInt8, UInt8, UInt8) -> [UInt8]) -> Data {
        let w = MutableDataWriter()
        forEachTile(width, height, tw, th) { tx, ty in
            for row in 0..<th { for col in 0..<tw {
                let (r, g, b, a) = sample(rgba, width, height, tx + col, ty + row)
                w.putData(Data(f(r, g, b, a)))
            } }
        }
        return w.data
    }

    private static func encodeNibble(_ rgba: [UInt8], _ width: Int, _ height: Int, _ f: (UInt8, UInt8, UInt8, UInt8) -> UInt8) -> Data {
        let w = MutableDataWriter()
        forEachTile(width, height, 8, 8) { tx, ty in
            for row in 0..<8 {
                for col in stride(from: 0, to: 8, by: 2) {
                    let p0 = sample(rgba, width, height, tx + col, ty + row)
                    let p1 = sample(rgba, width, height, tx + col + 1, ty + row)
                    let hi = f(p0.0, p0.1, p0.2, p0.3), lo = f(p1.0, p1.1, p1.2, p1.3)
                    w.putU8((hi << 4) | (lo & 0xF))
                }
            }
        }
        return w.data
    }

    private static func encodeNibblePair(_ rgba: [UInt8], _ width: Int, _ height: Int) -> Data {
        let w = MutableDataWriter()
        forEachTile(width, height, 8, 4) { tx, ty in
            for row in 0..<4 { for col in 0..<8 {
                let (r, g, b, a) = sample(rgba, width, height, tx + col, ty + row)
                let i = UInt8((Int(r) + Int(g) + Int(b)) / 3) >> 4
                w.putU8(((a >> 4) << 4) | (i & 0xF))
            } }
        }
        return w.data
    }

    /// DXT1 blocks the way the decoder (and the GPU) reads them: a block with any transparent
    /// texel uses 3-colour mode (first endpoint <= second; index 3 = transparent), every other
    /// block 4-colour mode (first > second). Endpoints come from the visible texels only.
    /// Writing transparent texels as index 3 of a 4-colour block (as this did) made cut-out
    /// textures, flowers, fences, opaque where they should be holes.
    private static func encodeCMPR(_ rgba: [UInt8], _ width: Int, _ height: Int) -> Data {
        let w = MutableDataWriter()
        forEachTile(width, height, 8, 8) { tx, ty in
            for sub in 0..<4 {
                let subX = tx + (sub % 2) * 4, subY = ty + (sub / 2) * 4
                var texels: [(UInt8, UInt8, UInt8, UInt8)] = []
                for row in 0..<4 { for col in 0..<4 { texels.append(sample(rgba, width, height, subX + col, subY + row)) } }
                let visible = texels.filter { $0.3 >= 0x80 }
                let transparent = visible.count < 16
                var minR: UInt8 = 255, minG: UInt8 = 255, minB: UInt8 = 255
                var maxR: UInt8 = 0, maxG: UInt8 = 0, maxB: UInt8 = 0
                for (r, g, b, _) in visible {
                    minR = min(minR, r); minG = min(minG, g); minB = min(minB, b)
                    maxR = max(maxR, r); maxG = max(maxG, g); maxB = max(maxB, b)
                }
                if visible.isEmpty { (minR, minG, minB, maxR, maxG, maxB) = (0, 0, 0, 0, 0, 0) }
                let hi = rgbaToRGB565(maxR, maxG, maxB), lo = rgbaToRGB565(minR, minG, minB)
                var c0 = max(hi, lo), c1 = min(hi, lo)
                if transparent {
                    swap(&c0, &c1) // c0 <= c1: 3-colour + transparent
                } else if c0 == c1 {
                    // A flat block: equal endpoints read as 3-colour mode, which is still exact here.
                }
                w.putU16(c0)
                w.putU16(c1)
                let e0 = rgb565ToRGBA(c0), e1 = rgb565ToRGBA(c1)
                let palette: [(UInt8, UInt8, UInt8, UInt8)] = c0 > c1
                    ? [e0, e1, lerp(e0, e1, 1, 3), lerp(e0, e1, 2, 3)]
                    : [e0, e1, lerp(e0, e1, 1, 2)]
                for row in 0..<4 {
                    var byte: UInt8 = 0
                    for col in 0..<4 {
                        let (r, g, b, a) = texels[row * 4 + col]
                        var idx: UInt8 = 3
                        if !(transparent && a < 0x80) {
                            var best = Int.max
                            for (k, c) in palette.enumerated() {
                                let dr = Int(r) - Int(c.0), dg = Int(g) - Int(c.1), db = Int(b) - Int(c.2)
                                let d = dr * dr + dg * dg + db * db
                                if d < best { best = d; idx = UInt8(k) }
                            }
                        }
                        byte = (byte << 2) | idx
                    }
                    w.putU8(byte)
                }
            }
        }
        return w.data
    }

    private static func rgbaToRGB565(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> UInt16 {
        (UInt16(r >> 3) << 11) | (UInt16(g >> 2) << 5) | UInt16(b >> 3)
    }

    private static func sample(_ rgba: [UInt8], _ width: Int, _ height: Int, _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        guard x < width, y < height else { return (0, 0, 0, 0) }
        let i = (y * width + x) * 4
        return (rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3])
    }

    private static func forEachTile(_ width: Int, _ height: Int, _ tw: Int, _ th: Int, _ block: (Int, Int) -> Void) {
        let tilesX = (width + tw - 1) / tw
        let tilesY = (height + th - 1) / th
        for ty in 0..<tilesY { for tx in 0..<tilesX { block(tx * tw, ty * th) } }
    }
}

private nonisolated extension Data {
    func byteAt(_ offset: Int) -> UInt8? {
        guard offset >= 0, offset < count else { return nil }
        return self[startIndex + offset]
    }
    func be16At(_ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return be16(offset)
    }
    func subdataOpt(at offset: Int, length: Int) -> Data? {
        guard offset >= 0, length >= 0, offset + length <= count else { return nil }
        return subdata(at: offset, length: length)
    }
}
