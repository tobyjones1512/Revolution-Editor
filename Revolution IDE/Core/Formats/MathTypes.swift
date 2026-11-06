import Foundation

nonisolated struct Vec2: Equatable {
    var x: Float = 0
    var y: Float = 0

    init(x: Float = 0, y: Float = 0) { self.x = x; self.y = y }
    init(_ data: Data, at offset: Int) {
        x = data.beFloat32(offset)
        y = data.beFloat32(offset + 4)
    }
    func write(_ w: MutableDataWriter) { w.putFloat32(x); w.putFloat32(y) }
}

nonisolated struct Vec3: Equatable, Codable {
    var x: Float = 0
    var y: Float = 0
    var z: Float = 0

    init(x: Float = 0, y: Float = 0, z: Float = 0) { self.x = x; self.y = y; self.z = z }
    init(_ data: Data, at offset: Int) {
        x = data.beFloat32(offset)
        y = data.beFloat32(offset + 4)
        z = data.beFloat32(offset + 8)
    }
    func write(_ w: MutableDataWriter) { w.putFloat32(x); w.putFloat32(y); w.putFloat32(z) }

    static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
    static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
    static func * (a: Vec3, s: Float) -> Vec3 { Vec3(x: a.x * s, y: a.y * s, z: a.z * s) }

    var length: Float { (x * x + y * y + z * z).squareRoot() }

    func normalized() -> Vec3 {
        let l = length
        return l > 0 ? Vec3(x: x / l, y: y / l, z: z / l) : self
    }

    static func dot(_ a: Vec3, _ b: Vec3) -> Float { a.x * b.x + a.y * b.y + a.z * b.z }

    static func cross(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(x: a.y * b.z - a.z * b.y, y: a.z * b.x - a.x * b.z, z: a.x * b.y - a.y * b.x)
    }
}

extension BinaryFloatingPoint {
    /// `Int(self)` that can't trap: NaN is 0, infinities and out-of-range values clamp.
    var clampedInt: Int { isNaN ? 0 : Int(Swift.min(Swift.max(self, -1e15), 1e15)) }
}

/// The spatial-grid cell holding coordinate `v` for cells `cell` wide. NaN and absurd coordinates
/// land in a bounded cell instead of trapping, so cell spans can be subtracted safely.
func gridCell(_ v: Float, _ cell: Float) -> Int32 {
    Int32(clamping: Swift.min(Swift.max((v / cell).rounded(.down).clampedInt, -1_000_000), 1_000_000))
}

/// `Float(s)` for numbers read from imported text, with NaN and infinities (what "nan", "inf" and
/// "1e39" parse to) read as 0, so a bad value can't reach code that converts it to an integer.
func parseFloat<S: StringProtocol>(_ s: S) -> Float? { Float(s).map { $0.isFinite ? $0 : 0 } }
