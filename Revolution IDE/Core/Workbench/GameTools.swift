import Foundation

/// The games this app has format tools specific to.
///
/// Most of what the Workbench does is generic Wii/NW4R work that applies to any disc. BRRES
/// models, TEX0 textures, U8/SZS archives, BMG message tables. A few things only mean anything
/// inside one game: KMP and KCL are Mario Kart Wii's own course-data and collision formats, and a
/// map model is a Mario Kart Wii minimap. Those are grouped into a per-game submenu rather than
/// sitting loose alongside the generic items, so someone modding a different game isn't reading
/// past commands that could never apply to their files.
///
/// Each game can be switched off in Settings > Games, which hides its submenu entirely.
nonisolated enum GameTools: String, CaseIterable, Identifiable, Sendable {
    case marioKartWii
    case marioKartDoubleDash
    case nsmbw

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .marioKartWii: return "Mario Kart Wii"
        case .marioKartDoubleDash: return "Mario Kart: Double Dash!!"
        case .nsmbw: return "New Super Mario Bros. Wii"
        }
    }

    /// What this game's submenu covers, shown under its Settings toggle.
    var summary: String {
        switch self {
        case .marioKartWii:
            return "KMP course data, KCL collision meshes, building a minimap model from a course, and the 3D Track Preview."
        case .marioKartDoubleDash:
            return "Porting course archives (Course/*.arc) to Mario Kart Wii tracks, and Hot Swap for testing modified files in Dolphin."
        case .nsmbw:
            return "Opening a level archive's course data straight into the level editor."
        }
    }

    /// Defaults on. These tools already existed loose in the menus before they were grouped, so
    /// starting switched off would read as them having been removed.
    var defaultsKey: String { "gameTools.\(rawValue).enabled" }

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }
}
