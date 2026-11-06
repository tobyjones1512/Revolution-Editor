import Foundation

/// User-chosen extra height added on top of the normal snap margin when snapping a Start Point
/// (KTPT) to the ground, backing the "Starting Point Y Padding" control in Settings. Defaults to 30
/// so a kart spawns well clear of the track surface, the snap itself already adds `KMPEditorView
/// .groundClearance` (10), so the default snap result is `ground + 40`. Only start points get this
/// extra margin; every other snapped point kind keeps just the base clearance.
nonisolated enum SnapToGroundPrefs {
    static let startPointYPaddingKey = "SnapToGroundPrefs.startPointYPadding"
    static let defaultStartPointYPadding = 30

    static var startPointYPadding: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: startPointYPaddingKey)
            return stored > 0 ? stored : defaultStartPointYPadding
        }
        set { UserDefaults.standard.set(max(0, newValue), forKey: startPointYPaddingKey) }
    }
}