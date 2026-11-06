import Foundation
import simd

/// Normal maps for textures.
///
/// Creating one: the texture's brightness is treated as height, softened, and its slope (Sobel)
/// becomes a tangent-space normal, encoded the common way (RGB = normal x 0.5 + 0.5, green = up
/// the image, "OpenGL" convention) so it also works in Blender, Unity and the like.
///
/// Applying one: Mario Kart Wii's course shader is unlit, every retail course material has no
/// light set, its lighting is baked into vertex colours, and no retail material uses NW4R's
/// normal-map indirect mode, so a normal map can't be switched on in the material without
/// inventing GPU state no retail file confirms. Instead its shading is baked into the texture's
/// own pixels, lit from a chosen direction, exactly as the game's static lighting already is.
/// The result is an ordinary texture in its original format, so it runs on real hardware (and on
/// the GameCube, for a Double Dash port).
nonisolated enum NormalMap {
    struct Options: Equatable {
        /// How steep the bumps are.
        var strength: Float = 2
        /// Box-blur radius applied to the height first, in pixels (0 = sharp, noisy detail).
        var blur = 1
        /// Dark = high instead of light = high.
        var invert = false
    }

    /// A tangent-space normal map (RGBA8, alpha 255) the same size as `rgba`. Edges wrap, since
    /// track textures tile.
    static func generate(rgba: [UInt8], width w: Int, height h: Int, options o: Options) -> [UInt8] {
        guard w > 0, h > 0, rgba.count >= w * h * 4 else { return [] }
        var height = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let l = (0.299 * Float(rgba[i * 4]) + 0.587 * Float(rgba[i * 4 + 1]) + 0.114 * Float(rgba[i * 4 + 2])) / 255
            height[i] = o.invert ? 1 - l : l
        }
        if o.blur > 0 { height = boxBlur(height, w, h, radius: o.blur) }
        func at(_ x: Int, _ y: Int) -> Float { height[((y % h + h) % h) * w + (x % w + w) % w] }
        var out = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                // Sobel slopes; y runs down the image.
                let dx = (at(x + 1, y - 1) + 2 * at(x + 1, y) + at(x + 1, y + 1)) - (at(x - 1, y - 1) + 2 * at(x - 1, y) + at(x - 1, y + 1))
                let dy = (at(x - 1, y + 1) + 2 * at(x, y + 1) + at(x + 1, y + 1)) - (at(x - 1, y - 1) + 2 * at(x, y - 1) + at(x + 1, y - 1))
                // Green = up the image, so a slope rising downwards tilts the normal up.
                let n = simd_normalize(SIMD3(-dx * o.strength, dy * o.strength, 1))
                let i = (y * w + x) * 4
                out[i] = encode(n.x); out[i + 1] = encode(n.y); out[i + 2] = encode(n.z)
            }
        }
        return out
    }

    struct Light: Equatable {
        /// Direction the light comes from across the texture: 0 = from the right, 90 = from the
        /// top of the image.
        var azimuth: Float = 135
        /// Height above the surface: 90 = straight overhead (no relief shows).
        var elevation: Float = 40
        /// How strong the relief is.
        var intensity: Float = 1
        /// Light that reaches every pixel regardless of facing, keeps shadowed sides from black.
        var ambient: Float = 0.45
    }

    /// `texture` shaded by `normals` (resampled to the texture's size if they differ), normalised
    /// so a flat area keeps its original colour. Alpha is kept.
    static func bake(texture: [UInt8], width w: Int, height h: Int, normals: [UInt8], normalWidth nw: Int, normalHeight nh: Int, light: Light) -> [UInt8] {
        guard w > 0, h > 0, texture.count >= w * h * 4, nw > 0, nh > 0, normals.count >= nw * nh * 4 else { return texture }
        let n = (nw == w && nh == h) ? normals : resample(normals, from: (nw, nh), to: (w, h))
        let az = light.azimuth * .pi / 180, el = light.elevation * .pi / 180
        let l = SIMD3(cos(el) * cos(az), cos(el) * sin(az), sin(el))
        let flat = light.ambient + light.intensity * max(0, l.z)
        guard flat > 0 else { return texture }
        var out = texture
        for i in 0..<(w * h) {
            let v = simd_normalize(SIMD3(decode(n[i * 4]), decode(n[i * 4 + 1]), decode(n[i * 4 + 2])) + 1e-6)
            let shade = (light.ambient + light.intensity * max(0, simd_dot(v, l))) / flat
            for c in 0..<3 { out[i * 4 + c] = UInt8(clamping: Int((Float(texture[i * 4 + c]) * shade).rounded())) }
        }
        return out
    }

    /// Bilinear resample of an RGBA8 image (wrapping, as tiled textures do).
    static func resample(_ src: [UInt8], from: (Int, Int), to: (Int, Int)) -> [UInt8] {
        let (sw, sh) = from, (dw, dh) = to
        var out = [UInt8](repeating: 0, count: dw * dh * 4)
        for y in 0..<dh {
            let fy = (Float(y) + 0.5) * Float(sh) / Float(dh) - 0.5
            let y0 = Int(fy.rounded(.down)), ty = fy - Float(y0)
            for x in 0..<dw {
                let fx = (Float(x) + 0.5) * Float(sw) / Float(dw) - 0.5
                let x0 = Int(fx.rounded(.down)), tx = fx - Float(x0)
                for c in 0..<4 {
                    func p(_ xx: Int, _ yy: Int) -> Float { Float(src[(((yy % sh + sh) % sh) * sw + (xx % sw + sw) % sw) * 4 + c]) }
                    let top = p(x0, y0) * (1 - tx) + p(x0 + 1, y0) * tx
                    let bottom = p(x0, y0 + 1) * (1 - tx) + p(x0 + 1, y0 + 1) * tx
                    out[(y * dw + x) * 4 + c] = UInt8(clamping: Int((top * (1 - ty) + bottom * ty).rounded()))
                }
            }
        }
        return out
    }

    /// `count` mip levels starting from `rgba` itself, each half the last (2x2 average).
    static func mipChain(_ rgba: [UInt8], width: Int, height: Int, count: Int) -> [(rgba: [UInt8], width: Int, height: Int)] {
        var levels = [(rgba, width, height)]
        while levels.count < count {
            let (src, sw, sh) = levels.last!
            let dw = max(1, sw / 2), dh = max(1, sh / 2)
            var dst = [UInt8](repeating: 0, count: dw * dh * 4)
            for y in 0..<dh {
                for x in 0..<dw {
                    for c in 0..<4 {
                        var sum = 0
                        for (ox, oy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                            sum += Int(src[(min(sh - 1, y * 2 + oy) * sw + min(sw - 1, x * 2 + ox)) * 4 + c])
                        }
                        dst[(y * dw + x) * 4 + c] = UInt8((sum + 2) / 4)
                    }
                }
            }
            levels.append((dst, dw, dh))
        }
        return levels
    }

    private static func encode(_ v: Float) -> UInt8 { UInt8(clamping: Int(((v * 0.5 + 0.5) * 255).rounded())) }
    private static func decode(_ v: UInt8) -> Float { Float(v) / 255 * 2 - 1 }

    private static func boxBlur(_ src: [Float], _ w: Int, _ h: Int, radius r: Int) -> [Float] {
        var tmp = src, out = src
        let n = Float(2 * r + 1)
        for y in 0..<h {
            for x in 0..<w {
                var s: Float = 0
                for k in -r...r { s += src[y * w + ((x + k) % w + w) % w] }
                tmp[y * w + x] = s / n
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                var s: Float = 0
                for k in -r...r { s += tmp[(((y + k) % h + h) % h) * w + x] }
                out[y * w + x] = s / n
            }
        }
        return out
    }
}
