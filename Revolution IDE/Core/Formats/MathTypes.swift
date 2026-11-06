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
