import AppKit

/// Presents NSOpenPanel/NSSavePanel asynchronously via `begin(completionHandler:)` rather than
/// the blocking `runModal()`.
///
/// `runModal()` called synchronously from inside a SwiftUI `Button` action (especially a toolbar
/// item's action) is unreliable on recent macOS/SwiftUI: the panel can silently fail to present,
/// or open and immediately close, because it nests a new modal run loop mid view-update-cycle.
/// `begin(completionHandler:)` sidesteps that entirely and is the officially recommended API.
enum PanelPresenter {
    static func openFile(configure: (NSOpenPanel) -> Void = { _ in }, completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        configure(panel)
        panel.begin { response in
            completion(response == .OK ? panel.url : nil)
        }
    }

    static func openFiles(configure: (NSOpenPanel) -> Void = { _ in }, completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        configure(panel)
        panel.begin { response in
            completion(response == .OK ? panel.urls : [])
        }
    }

    static func saveFile(configure: (NSSavePanel) -> Void = { _ in }, completion: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        configure(panel)
        panel.begin { response in
            completion(response == .OK ? panel.url : nil)
        }
    }
}
