import Foundation

/// Fits a set of textures into what a Double Dash course can afford on the GameCube (24 MB of
/// main RAM, shared with everything else in the race).
///
/// Budgets measured from the retail courses: course-model textures total at most ~1.4 MB (Luigi
/// Circuit 1387 KB) and are mostly CMPR, up to 1024 px; sky models ~64 KB. Each texture is
/// resized to a power of two no larger than `maxSize`, encoded as CMPR (opaque or cut-out alpha
///, retail's choice for 259 of its 375 course textures) or RGB5A3 (smooth transparency), given
/// a mip chain like retail's, and the largest are halved until the set fits `budget`.
nonisolated enum GCTextures {
    struct Source {
        var name: String
        var rgba: [UInt8]
        var width: Int
        var height: Int
        var wrapS: UInt8 = 1
        var wrapT: UInt8 = 1
    }

    static let courseBudget = 1_300 * 1024
    static let skyBudget = 128 * 1024

    static func optimize(_ sources: [Source], budget: Int, maxSize: Int = 512) -> (textures: [J3DWriter.Texture], report: [String]) {
        var report: [String] = []
        // Working sizes, halved until the set fits.
        var sizes = sources.map { fitted($0.width, $0.height, maxSize) }
        func alphaKind(_ s: Source) -> (cutout: Bool, smooth: Bool) {
            var cut = false, smooth = false
            for i in stride(from: 3, to: s.rgba.count, by: 4) {
                let a = s.rgba[i]
                if a < 255 { cut = true; if a > 16 && a < 239 { smooth = true; break } }
            }
            return (cut, smooth)
        }
        let kinds = sources.map(alphaKind)
        func format(_ i: Int) -> GXTextureFormat { kinds[i].smooth ? .rgb5a3 : .cmpr }
        func bytes(_ i: Int) -> Int {
            let (w, h) = sizes[i]
            let perPixel: Double = format(i) == .cmpr ? 0.5 : 2
            return Int(Double(w * h) * perPixel * 4 / 3) // with mips
        }
        while sources.indices.reduce(0, { $0 + bytes($1) }) > budget,
              let largest = sources.indices.filter({ sizes[$0].0 > 8 || sizes[$0].1 > 8 }).max(by: { bytes($0) < bytes($1) }) {
            sizes[largest] = (max(8, sizes[largest].0 / 2), max(8, sizes[largest].1 / 2))
        }
        var out: [J3DWriter.Texture] = []
        for (i, s) in sources.enumerated() {
            let (w, h) = sizes[i]
            let rgba = (w == s.width && h == s.height) ? s.rgba : NormalMap.resample(s.rgba, from: (s.width, s.height), to: (w, h))
            // Mips down to 8px (CMPR's block), as retail's mipmapped course textures stop there.
            var levels = 1
            while levels < 6 && (w >> levels) >= 8 && (h >> levels) >= 8 { levels += 1 }
            var encoded = Data()
            for level in NormalMap.mipChain(rgba, width: w, height: h, count: levels) {
                encoded.append(TextureCodec.encode(rgba: level.rgba, width: level.width, height: level.height, format: format(i)) ?? Data())
            }
            if (w, h) != (s.width, s.height) { report.append("\(s.name): \(s.width)x\(s.height) -> \(w)x\(h)") }
            out.append(J3DWriter.Texture(name: s.name, format: format(i), width: w, height: h, encoded: encoded, mipCount: levels,
                                         wrapS: s.wrapS, wrapT: s.wrapT, hasAlpha: kinds[i].cutout))
        }
        let total = out.reduce(0) { $0 + $1.encoded.count }
        report.append("Textures: \(out.count), \(total / 1024) KB (budget \(budget / 1024) KB).")
        return (out, report)
    }

    /// The largest power of two (8...maxSize) not above each side.
    static func fitted(_ width: Int, _ height: Int, _ maxSize: Int) -> (Int, Int) {
        func fit(_ n: Int) -> Int { var s = 8; while s * 2 <= min(max(n, 8), maxSize) { s *= 2 }; return s }
        return (fit(width), fit(height))
    }
}
