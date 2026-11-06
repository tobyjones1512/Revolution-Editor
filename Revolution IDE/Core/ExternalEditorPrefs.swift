import AppKit

/// Optional user-chosen external apps for "Open in External Editor" actions on textures/models.
/// Stored as plain UserDefaults paths (matching `EmulatorLauncher`'s manual-Dolphin-path pattern)
/// rather than security-scoped bookmarks: these are installed applications the user points at
/// once, not sandboxed user documents whose *contents* need to be re-read across launches.
nonisolated enum ExternalEditorPrefs {
    static let imageEditorPathKey = "ExternalEditorPrefs.imageEditorPath"
    static let modelEditorPathKey = "ExternalEditorPrefs.modelEditorPath"
    static let codeEditorPathKey = "ExternalEditorPrefs.codeEditorPath"

    static var imageEditorURL: URL? { url(forKey: imageEditorPathKey) }
    static var modelEditorURL: URL? { url(forKey: modelEditorPathKey) }
    /// VS Code, Nova, Sublime Text, BBEdit..., opens source files and project folders.
    static var codeEditorURL: URL? { url(forKey: codeEditorPathKey) }

    /// Opens a file or folder in the chosen code editor; false when none is set.
    @discardableResult static func openInCodeEditor(_ target: URL) -> Bool {
        guard let app = codeEditorURL else { return false }
        NSWorkspace.shared.open([target], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    private static func url(forKey key: String) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: key), !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}
