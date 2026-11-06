import Foundation

/// Double Dash minimap images (`<prefix>_map.bti`): the driveable surface seen from above, drawn
/// into the world rectangle and orientation the slot's `main.dol` gives it (`MKDDSlots.Minimap`) --
/// the same mapping mkdd-track-editor's minimap generator uses. Corner 1 is the image's top-left
/// (X right, Z down) before the image is turned by `orientation` quarter turns (1 = clockwise).
nonisolated enum MKDDMinimap {
    static let width = 128, height = 256

    /// Double Dash surface types (high byte of a .bco flag) that belong on the map: road, ice,
    /// boost pads/ramps, teleports, per mkdd-track-editor's defaults.
    static func onMap(bcoFlag: UInt16) -> Bool { [0x01, 0x04, 0x07, 0x08, 0x09, 0x0D, 0x37, 0x47, 0xB0].contains(bcoFlag >> 8) }

    /// RGBA8, `width` x `height`: white track, black outline, transparent elsewhere.
    static func render(triangles: [(Vec3, Vec3, Vec3)], minimap m: MKDDSlots.Minimap, outline: Int = 2) -> [UInt8] {
        let (cw, ch) = m.orientation % 2 == 0 ? (width, height) : (height, width)
        // Canvas coverage (before turning), supersampled 2x2 per pixel.
        var inside = [Bool](repeating: false, count: cw * ch)
        let dx = (m.corner2.x - m.corner1.x) / Float(cw), dz = (m.corner2.y - m.corner1.y) / Float(ch)
        guard dx != 0, dz != 0 else { return [UInt8](repeating: 0, count: width * height * 4) }
        for (a, b, c) in triangles {
            // Triangle bounds in canvas pixels.
            func px(_ v: Vec3) -> (Float, Float) { ((v.x - m.corner1.x) / dx, (v.z - m.corner1.y) / dz) }
            let pa = px(a), pb = px(b), pc = px(c)
            let x0 = max(0, Int(min(pa.0, pb.0, pc.0).rounded(.down))), x1 = min(cw - 1, Int(max(pa.0, pb.0, pc.0).rounded(.up)))
            let y0 = max(0, Int(min(pa.1, pb.1, pc.1).rounded(.down))), y1 = min(ch - 1, Int(max(pa.1, pb.1, pc.1).rounded(.up)))
            guard x0 <= x1, y0 <= y1 else { continue }
            let den = (pb.1 - pc.1) * (pa.0 - pc.0) + (pc.0 - pb.0) * (pa.1 - pc.1)
            guard abs(den) > 1e-9 else { continue }
            for y in y0...y1 {
                for x in x0...x1 where !inside[y * cw + x] {
                    // Any of the pixel's 4 sample points inside.
                    for (sx, sy) in [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)] as [(Float, Float)] {
                        let qx = Float(x) + sx, qy = Float(y) + sy
                        let u = ((pb.1 - pc.1) * (qx - pc.0) + (pc.0 - pb.0) * (qy - pc.1)) / den
                        let v = ((pc.1 - pa.1) * (qx - pc.0) + (pa.0 - pc.0) * (qy - pc.1)) / den
                        if u >= 0, v >= 0, u + v <= 1 { inside[y * cw + x] = true; break }
                    }
                }
            }
        }
        // Outline: within `outline` pixels of the track.
        var near = inside
        if outline > 0 {
            for y in 0..<ch {
                for x in 0..<cw where inside[y * cw + x] {
                    for oy in -outline...outline { for ox in -outline...outline where ox * ox + oy * oy <= outline * outline {
                        let nx = x + ox, ny = y + oy
                        if nx >= 0, ny >= 0, nx < cw, ny < ch { near[ny * cw + nx] = true }
                    } }
                }
            }
        }
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for fy in 0..<height {
            for fx in 0..<width {
                let (cx, cy): (Int, Int)
                switch m.orientation {
                case 1: (cx, cy) = (fy, ch - 1 - fx)
                case 2: (cx, cy) = (cw - 1 - fx, ch - 1 - fy)
                case 3: (cx, cy) = (cw - 1 - fy, fx)
                default: (cx, cy) = (fx, fy)
                }
                let i = (fy * width + fx) * 4, k = cy * cw + cx
                if inside[k] { out[i] = 255; out[i + 1] = 255; out[i + 2] = 255; out[i + 3] = 255 }
                else if near[k] { out[i + 3] = 255 }
            }
        }
        return out
    }

    /// A rectangle (with a margin) that fits the triangles in a 1:2 or 2:1 map, for a course
    /// whose slot rectangle isn't known.
    static func fit(_ triangles: [(Vec3, Vec3, Vec3)], orientation: Int = 0) -> MKDDSlots.Minimap {
        let xs = triangles.flatMap { [$0.0.x, $0.1.x, $0.2.x] }, zs = triangles.flatMap { [$0.0.z, $0.1.z, $0.2.z] }
        var lo = Vec2(x: xs.min() ?? -1000, y: zs.min() ?? -1000), hi = Vec2(x: xs.max() ?? 1000, y: zs.max() ?? 1000)
        let margin = max(hi.x - lo.x, hi.y - lo.y) * 0.05
        lo = Vec2(x: lo.x - margin, y: lo.y - margin); hi = Vec2(x: hi.x + margin, y: hi.y + margin)
        // Canvas aspect: X across 128 (or 256 when turned), Z down 256 (or 128).
        let aspect: Float = orientation % 2 == 0 ? 0.5 : 2 // width / height in world units
        let w = hi.x - lo.x, h = hi.y - lo.y
        if w / h < aspect {
            let grow = (h * aspect - w) / 2; lo.x -= grow; hi.x += grow
        } else {
            let grow = (w / aspect - h) / 2; lo.y -= grow; hi.y += grow
        }
        return MKDDSlots.Minimap(corner1: lo, corner2: hi, orientation: orientation)
    }
}
