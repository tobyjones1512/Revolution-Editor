import AppKit

/// A decoded texture plus whether it actually uses transparency, what `MDL0SceneKit` and
/// `SceneKitMeshPreviewView` need to configure a 3D material correctly (see
/// `ImageUtil.hasTransparency`), bundled together so nothing has to re-scan the raw RGBA a second
/// time just to find out.
nonisolated struct DecodedTexture {
    let image: NSImage
    let hasTransparency: Bool
    /// (Near-)grey throughout: a lightmap/shadow map rather than a colour texture.
    var isGrayscale = false
    /// Transparent only as a hard-edged cut-out (fences, foliage): at most ~2% of texels are partly see-through.
    var isCutout = false
}

nonisolated enum ImageUtil {
    static func nsImage(fromRGBA rgba: [UInt8], width: Int, height: Int) -> NSImage? {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        guard let cgImage = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            // Straight (non-premultiplied) alpha, `TextureCodec.decode` writes each texel's raw
            // R/G/B untouched by its own alpha (see its `put(_:_:_:_:_:_:)`), so tagging this
            // `.premultipliedLast` told CoreGraphics/SceneKit the data was something it wasn't:
            // any texel with partial alpha decoded to the wrong color, and a fully-transparent
            // texel with non-zero RGB (routine GX padding, not premultiplied-valid) rendered as
            // solid black instead of see-through, every 3D preview's actual "transparency shows
            // as black" bug, not a per-view rendering setting.
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    /// `nsImage(fromRGBA:width:height:)` plus `hasTransparency(rgba:)`, in one call, what every 3D
    /// preview's texture lookup actually wants, since both need the same decoded RGBA anyway.
    static func decodedTexture(fromRGBA rgba: [UInt8], width: Int, height: Int) -> DecodedTexture? {
        guard let image = nsImage(fromRGBA: rgba, width: width, height: height) else { return nil }
        // Average spread between a texel's channels: retail CMPR shadow maps (`kage`) come out
        // at ~1 from compression noise, every colour texture measured at 8 or more.
        var spread = 0, i = 0
        while i + 2 < rgba.count { spread += Int(max(rgba[i], rgba[i + 1], rgba[i + 2]) - min(rgba[i], rgba[i + 1], rgba[i + 2])); i += 4 }
        let grey = spread < 3 * max(1, rgba.count / 4)
        var partial = 0
        i = 3
        while i < rgba.count { if rgba[i] > 8 && rgba[i] < 247 { partial += 1 }; i += 4 }
        return DecodedTexture(image: image, hasTransparency: hasTransparency(rgba: rgba), isGrayscale: grey, isCutout: partial * 50 < rgba.count / 4)
    }

    /// Whether any texel actually uses partial/full transparency, callers building a 3D material
    /// (`MDL0SceneKit`, `SceneKitMeshPreviewView`) use this to only pay for alpha-blend depth-sort
    /// handling (disabled depth writes, double-sided) on textures that actually need it, rather
    /// than on every opaque texture in the model.
    static func hasTransparency(rgba: [UInt8]) -> Bool {
        var i = 3
        while i < rgba.count {
            if rgba[i] != 255 { return true }
            i += 4
        }
        return false
    }

    /// A small flat-color swatch image, used for a `.mtl` material that gives a diffuse color
    /// (`Kd`) but no actual texture map (`map_Kd`), so it can still show up as a "linked texture"
    /// (e.g. the KCL editor's per-flag reference texture) consistently with materials that do.
    static func solidColor(r: Float, g: Float, b: Float, size: Int = 16) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        image.unlockFocus()
        return image
    }

    /// RGBA8 bytes from an NSImage, resized to the given pixel dimensions (used before
    /// re-encoding a replacement texture, so it always matches the original's size), row-major,
    /// top-to-bottom, matching `TextureCodec.encode`'s expected input. `CGContext.draw(_:in:)`
    /// already places a source image's top row at the buffer's first row on its own; an extra
    /// flip here (a previous version of this function had one, via `translateBy`/`scaleBy`) undid
    /// that and silently handed every caller (texture "Replace from Image...", "Add New
    /// Texture...", and the OBJ-to-BRRES importers' texture embedding) an upside-down image --
    /// confirmed by round-tripping a real, distinctly-colored-per-corner texture through this
    /// function and back out through `TEX0View`/`TextureCodec`.
    static func rgba(from image: NSImage, width: Int, height: Int) -> [UInt8]? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                       space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        guard let cgImage = rep.cgImage else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        return [UInt8](UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: width * height * 4), count: width * height * 4))
    }
}
