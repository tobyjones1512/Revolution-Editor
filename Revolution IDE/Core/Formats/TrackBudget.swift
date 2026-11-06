import Foundation

/// How heavy a track model is next to the retail ones. The reference numbers were measured from
/// every retail Mario Kart Wii course archive (all 32 race tracks + 5 battle arenas, `*_d.szs`
/// duplicates and prototype test courses excluded), see the measurement note in
/// `Tests/TrackBudgetCheck`. Above retail's own maximum the game isn't guaranteed to cope:
/// expect frame drops in split-screen first, then running out of memory.
nonisolated enum TrackBudget {
    enum Kind: String, CaseIterable, Identifiable {
        case course = "Course model", skybox = "Skybox", minimap = "Minimap"
        var id: String { rawValue }
        /// The MDL0 name the game looks each one up by.
        init?(modelName: String) {
            switch modelName { case "course": self = .course; case "vrcorn": self = .skybox; case "map": self = .minimap; default: return nil }
        }
    }

    enum Metric: String, CaseIterable { case triangles = "Triangles", vertices = "Vertices", meshes = "Meshes (draw calls)", textureKB = "Texture memory" }

    enum Game { case marioKartWii, doubleDash }

    /// Retail median and maximum per metric. Double Dash's were measured from every retail course
    /// archive's course and sky models (22 and 16; a Double Dash minimap is a texture, not a model).
    static func reference(_ kind: Kind, _ metric: Metric, game: Game = .marioKartWii) -> (median: Int, max: Int) {
        if game == .doubleDash {
            switch (kind, metric) {
            case (.course, .triangles): return (11_623, 15_317)
            case (.course, .vertices): return (8_058, 13_069)
            case (.course, .meshes): return (17, 22)
            case (.course, .textureKB): return (815, 1_387)
            case (.skybox, .triangles): return (144, 358)
            case (.skybox, .vertices): return (85, 226)
            case (.skybox, .meshes): return (1, 4)
            case (.skybox, .textureKB): return (64, 129)
            case (.minimap, _): return (0, 0)
            }
        }
        return switch (kind, metric) {
        case (.course, .triangles): (12_914, 23_683)
        case (.course, .vertices): (20_866, 41_423)
        case (.course, .meshes): (21, 31)
        case (.course, .textureKB): (1_271, 3_291)
        case (.skybox, .triangles): (116, 4_491)
        case (.skybox, .vertices): (180, 7_455)
        case (.skybox, .meshes): (1, 5)
        case (.skybox, .textureKB): (128, 384)
        case (.minimap, .triangles): (1_346, 6_862)
        case (.minimap, .vertices): (1_826, 8_592)
        case (.minimap, .meshes): (1, 7)
        case (.minimap, .textureKB): (0, 0)
        }
    }

    enum Rating: Int, Comparable {
        case typical, withinRetail, overRetail, farOver
        static func < (a: Rating, b: Rating) -> Bool { a.rawValue < b.rawValue }
        var label: String {
            switch self {
            case .typical: "Typical for a retail track"
            case .withinRetail: "Heavier than most, within retail"
            case .overRetail: "Heavier than any retail track"
            case .farOver: "Over twice the heaviest retail track"
            }
        }
    }

    static func rate(_ value: Int, _ kind: Kind, _ metric: Metric, game: Game = .marioKartWii) -> Rating {
        let r = reference(kind, metric, game: game)
        if value <= r.median { return .typical }
        if value <= r.max { return .withinRetail }
        return value <= max(r.max * 2, 1) ? .overRetail : .farOver
    }

    /// A Double Dash model's figures, measured the same way for the user's model and the retail
    /// references: triangles drawn, position-array entries, shapes (draw calls) and the texture
    /// section's size.
    static func j3dMetrics(_ d: Data) -> [Metric: Int]? {
        guard let model = try? J3DModel.parse(d) else { return nil }
        var sections: [String: Int] = [:]
        var off = 0x20
        while off + 8 <= d.count {
            let size = Int(d.be32(off + 4))
            guard size >= 8 else { break }
            sections[d.asciiString(at: off, length: 4)] = off
            off += size
        }
        var vertices = 0
        if let vtx = sections["VTX1"] {
            let formats = vtx + Int(d.be32(vtx + 8)), offsets = (0..<13).map { Int(d.be32(vtx + 0x0C + $0 * 4)) }
            var f = formats
            while f + 0x10 <= d.count, d.be32(f) != 0xFF {
                if d.be32(f) == 9, offsets[0] != 0 {
                    let type = Int(d.be32(f + 8)), comps = d.be32(f + 4) == 0 ? 2 : 3
                    let size = type <= 1 ? 1 : (type <= 3 ? 2 : 4)
                    let end = offsets.dropFirst().filter { $0 > offsets[0] }.min() ?? Int(d.be32(vtx + 4))
                    vertices = (end - offsets[0]) / (comps * size)
                }
                f += 0x10
            }
        }
        let shapes = sections["SHP1"].map { Int(d.be16($0 + 8)) } ?? 0
        let textureKB = sections["TEX1"].map { Int(d.be32($0 + 4)) / 1024 } ?? 0
        return [.triangles: model.triangles.count, .vertices: vertices, .meshes: shapes, .textureKB: textureKB]
    }
}
