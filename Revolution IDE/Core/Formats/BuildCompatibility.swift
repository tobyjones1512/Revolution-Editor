import Foundation

/// How generated course models and collision are encoded (Settings > Games).
/// - `dolphin`: this app's own quick encoders, small files, built fast; what earlier versions made.
/// - `hardware`: the encoders the community's tools use, for courses that must run on a real Wii:
///   collision exactly as Wiimm's `wkclt` builds it (`KCLWiimm`), models with RiiStudio's
///   choices, triangle strips and mipmapped textures (`MDL0Writer`, `OBJToBRRES`).
nonisolated enum BuildCompatibility: String, CaseIterable {
    case dolphin, hardware
    static let defaultsKey = "buildCompatibility"
    static var current: BuildCompatibility {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(BuildCompatibility.init) ?? .hardware
    }
}
