import SwiftUI
import AppKit
import UserNotifications
import Combine

/// Revolution Editor's primary experience is the Workbench, an Xcode-like IDE for Wii modding
/// assets (.szs/.kmp/.brres). The original disc-scrubbing tool (open/scrub/extract a Wii ISO,
/// partition management, ...) is fully preserved, just moved into its own secondary window,
/// opened from the Workbench toolbar/Welcome screen or File > Open Wii Disc Image.
@main struct RevolutionIDEApp: App {
    @StateObject private var workbench: WorkbenchState
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    /// The workbench of the frontmost window (File > New Window opens independent ones); menu
    /// commands act on it, falling back to the first window's.
    @FocusedObject private var focusedWorkbench: WorkbenchState?
    private var active: WorkbenchState { focusedWorkbench ?? workbench }

    init() {
        #if DEBUG
        DocsScreenshots.runIfRequested()
        #endif
        #if DEBUG
        // Cheap, and it guards the one piece of file-writing logic here that is impossible to
        // eyeball: the BRRES name-lookup tree every model/texture the game loads depends on.
        BRRESIndexGroup.selfCheck()
        #endif
        _workbench = StateObject(wrappedValue: WorkbenchState())
        SkyboxLibrary.shared.refresh()
    }

    var body: some Scene {
        Window("Set Up Revolution Editor", id: "setup") {
            SetupWizardView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        // Declared first so it is the window a launch opens; the Workbench opens from it.
        Window("Welcome to Revolution Editor", id: "welcome") {
            WelcomeView(workbench: workbench)
                .whatsNewSheet()
                // Finder opens at launch land here before any Workbench window exists; the Welcome window then reveals it.
                .onAppear { appDelegate.workbench = workbench; WorkbenchRegistry.shared.add(workbench) }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.presented)

        WindowGroup(id: "workbench") {
            WorkbenchView()
                .environmentObject(workbench)
                .focusedSceneObject(workbench)
                .frame(minWidth: 900, minHeight: 560)
                .background(LaunchGate(appDelegate: appDelegate))
                .whatsNewSheet(delay: .seconds(2), onlyIfVisible: true)
                .onAppear { appDelegate.workbench = workbench; WorkbenchRegistry.shared.add(workbench) }
        }
        .commands {
            CommandGroup(before: .windowList) { WelcomeMenuButton() }
            CommandGroup(replacing: .appInfo) {
                Button("About Revolution Editor") { active.showAboutSheet = true }
                WhatsNewMenuButton()
                Divider()
                Link("Join the Discord", destination: URL(string: "https://discord.gg/nXFSaFZbHf")!)
            }
            CommandGroup(replacing: .newItem) {
                NewWindowButton()
                Menu("New") { NewFileMenuItems(workbench: active) }
                Menu("Open") {
                    Button("File...") { openFile() }
                        .shortcut(.openFile)
                    Button("Folder...") { openFolder() }
                        .shortcut(.openFolder)
                    Button("Wii/GCN Disc Image...") { openDisc() }
                    Menu("Open Recent") {
                        if active.recentFileURLs.isEmpty {
                            Text("No Recent Files")
                        } else {
                            ForEach(active.recentFileURLs, id: \.self) { url in
                                Button(url.lastPathComponent) { active.openFile(url: url) }
                            }
                            Divider()
                            Button("Clear Menu") { active.clearRecentFiles() }
                        }
                    }
                }
                Divider()
                Button("Save") { active.saveSelected() }
                    .shortcut(.save)
                Button("Save As...") { active.saveSelectedAs() }
                    .shortcut(.saveAs)
                Divider()
                TextureGalleryMenuItem()
            }
            CommandGroup(after: .undoRedo) {
                Button("Redo (Alternate)") {
                    NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
                }
                .shortcut(.redoAlternate)
            }
            CommandMenu("Convert") { ConvertMenuItems(workbench: active) }
            CommandGroup(replacing: .help) { HelpMenuButton(); CrashLogsMenuButton() }
        }

        WindowGroup(id: "extraWorkbench", for: UUID.self) { _ in
            ExtraWorkbenchWindow()
        }

        Window("What's New", id: "whatsNew") {
            WhatsNewView()
        }
        .windowResizability(.contentSize)

        Window("To-Do", id: "todo") {
            TodoView()
        }

        Window("Review Crash Logs", id: "crashLogs") {
            CrashLogReviewView()
        }

        Window("Revolution Editor Help", id: "help") {
            HelpView()
        }
        .windowResizability(.contentSize)

        Window("Texture Gallery", id: "textureGallery") {
            TextureGalleryView()
                .frame(minWidth: 760, minHeight: 520)
        }

        WindowGroup(id: "discScrubber") {
            DiscScrubberWindowView()
                .frame(minWidth: 720, minHeight: 480)
        }

        WindowGroup(id: "szsWindow", for: UUID.self) { $id in
            SZSWindowContainerView(id: id)
                .environmentObject(WorkbenchRegistry.shared.owner(of: id) ?? workbench)
                .frame(minWidth: 700, minHeight: 420)
        }

        WindowGroup(id: "nsmbwWindow", for: UUID.self) { $id in
            NSMBWWindowContainerView(id: id)
                .environmentObject(WorkbenchRegistry.shared.owner(of: id) ?? workbench)
                .frame(minWidth: 800, minHeight: 500)
        }

        WindowGroup(id: "trackPreviewWindow", for: UUID.self) { $id in
            TrackPreviewWindowContainerView(id: id)
                .environmentObject(WorkbenchRegistry.shared.owner(of: id) ?? workbench)
                .frame(minWidth: 900, minHeight: 650)
        }

        Settings {
            SettingsView()
        }
    }

    private func openFile() {
        let target = active
        PanelPresenter.openFile(configure: { $0.allowsOtherFileTypes = true }) { url in
            guard let url else { return }
            target.openFile(url: url)
        }
    }

    private func openFolder() {
        let target = active
        PanelPresenter.openFile(configure: { $0.canChooseDirectories = true; $0.canChooseFiles = false }) { url in
            guard let url else { return }
            target.openFolder(url: url)
        }
    }

    private func openDisc() {
        let target = active
        PanelPresenter.openFile(configure: { $0.allowsOtherFileTypes = true }) { url in
            guard let url else { return }
            target.openDiscAsProject(url: url)
        }
    }
}

/// File > New Window: another, independent Workbench (its own project, tabs and console).
private struct NewWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("New Window") { openWindow(id: "extraWorkbench", value: UUID()) }
            .shortcut(.newWindow)
    }
}

/// The Convert menu: every conversion for the file selected in the Project Navigator (or the open tab's).
private struct ConvertMenuItems: View {
    @ObservedObject var workbench: WorkbenchState
    var body: some View {
        if let target = workbench.convertTarget, !target.conversions.isEmpty || target.archiveURL != nil {
            Section(target.name) {
                ForEach(Array(target.conversions.enumerated()), id: \.offset) { _, c in
                    Button(c.title) { workbench.runConversion(c, suggestedName: target.name) }
                }
                if let url = target.archiveURL, let current = WiimmArchive.Format(rawValue: url.pathExtension.lowercased()) {
                    ForEach(WiimmArchive.Format.allCases.filter { $0 != current }) { format in
                        Button("Convert to \(format.title)") { workbench.convertArchive(at: url, to: format) }
                            .help("Writes this archive in another format beside it. .wbz/.wlz need your Mario Kart Wii disc linked in Settings > Games.")
                    }
                }
            }
        } else {
            Text("Select a file to convert in the Project Navigator")
        }
    }
}

/// Window > Welcome to Revolution Editor brings the startup window back.
private struct WelcomeMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Welcome to Revolution Editor") { openWindow(id: "welcome") }
            .shortcut(.welcome)
        Button("To-Do") { openWindow(id: "todo") }
        #if DEBUG
        Button("Run Setup Wizard (Debug)") { openWindow(id: "setup") }
        #endif
    }
}

/// SwiftUI opens the Workbench at launch whatever the scene order says, so the first Workbench window
/// hides itself and brings up Welcome instead; Welcome's close button / opening a project reveals it.
/// Skipped when Finder launched the app with files to open.
private struct LaunchGate: View {
    let appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        GateView(skip: appDelegate.launchedWithFiles) { WindowRouter.openWorkbench = { openWindow(id: "workbench") }; openWindow(id: "welcome") }
    }

    private struct GateView: NSViewRepresentable {
        static var done = false
        let skip: Bool
        let showWelcome: () -> Void
        final class V: NSView {
            var skip = false
            var showWelcome: () -> Void = {}
            override func viewDidMoveToWindow() {
                guard let window, !GateView.done else { return }
                GateView.done = true
                guard !skip else { return }
                window.alphaValue = 0
                DispatchQueue.main.async { [showWelcome] in
                    showWelcome()
                    window.orderOut(nil)
                    window.alphaValue = 1
                }
            }
        }
        func makeNSView(context: Context) -> V { let v = V(); v.skip = skip; v.showWelcome = showWelcome; return v }
        func updateNSView(_ nsView: V, context: Context) {}
    }
}

/// Revolution Editor > What's New reopens this version's What's New.
private struct WhatsNewMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("What's New") { openWindow(id: "whatsNew") }
    }
}

/// Help > Revolution Editor Help opens the Help window.
private struct HelpMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Revolution Editor Help") { openWindow(id: "help") }
            .shortcut(.help)
    }
}

/// Help > Review Crash Logs opens the Dolphin log reader.
private struct CrashLogsMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Review Crash Logs") { openWindow(id: "crashLogs") }
    }
}

/// A Workbench window opened with File > New Window, owning its own state.
private struct ExtraWorkbenchWindow: View {
    @StateObject private var workbench = WorkbenchState(isPrimary: false)
    var body: some View {
        WorkbenchView()
            .environmentObject(workbench)
            .focusedSceneObject(workbench)
            .frame(minWidth: 900, minHeight: 560)
            .onAppear { WorkbenchRegistry.shared.add(workbench) }
            .onDisappear { WorkbenchRegistry.shared.remove(workbench) }
    }
}

/// Every open Workbench, so an archive/level/3D window finds the one that opened it.
@MainActor final class WorkbenchRegistry {
    static let shared = WorkbenchRegistry()
    private var all: [WorkbenchState] = []
    func add(_ w: WorkbenchState) { if !all.contains(where: { $0 === w }) { all.append(w) } }
    func remove(_ w: WorkbenchState) { all.removeAll { $0 === w } }
    /// The folder the first Workbench with a project has open.
    var currentProjectPath: String? { all.lazy.compactMap { $0.projectRoot?.url.path }.first }
    func owner(of id: UUID?) -> WorkbenchState? {
        guard let id else { return nil }
        return all.first { $0.szsWindowSessions[id] != nil || $0.nsmbwWindowSessions[id] != nil || $0.trackPreviewWindowSessions[id] != nil }
    }
}

/// Routes Finder "Open"/"Open With"/Dock drops into the Workbench. Implementing
/// `application(_:open:)` also stops SwiftUI spawning a fresh Workbench window per file. URLs
/// that arrive on a cold launch, before the Workbench window exists, are held until it appears.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        AppNotifications.requestAuthorization()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Show banners even while the app is frontmost.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }

    /// Clicking a notification that carries a link opens it.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if let s = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: s) { await MainActor.run { _ = NSWorkspace.shared.open(url) } }
    }

    private var pendingURLs: [URL] = []
    /// Set when Finder handed us files at launch, the Workbench should open rather than Welcome.
    var launchedWithFiles = false
    @MainActor var workbench: WorkbenchState? { didSet { flush(); watchWorkbench() } }

    private var watchers: Set<AnyCancellable> = []
    private let launched = Date()

    /// Whenever a project or file is opened (File > Open, Finder, a recent) make sure the Workbench window is on screen,
    /// even if it was closed or is still hidden behind Welcome.
    @MainActor private func watchWorkbench() {
        guard let workbench, watchers.isEmpty else { return }
        workbench.$tabs.map(\.count).removeDuplicates().dropFirst().sink { [weak self] _ in self?.ensureWorkbenchWindow() }.store(in: &watchers)
        workbench.$project.map { $0 == nil }.removeDuplicates().dropFirst().sink { [weak self] _ in self?.ensureWorkbenchWindow() }.store(in: &watchers)
    }

    @MainActor private func ensureWorkbenchWindow() {
        guard Date().timeIntervalSince(launched) > 2 else { return }
        if let window = NSApp.windows.first(where: { ($0.identifier?.rawValue ?? "").hasPrefix("workbench") }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.alphaValue = 1
            window.makeKeyAndOrderFront(nil)
        } else {
            WindowRouter.openWorkbench?()
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { ($0.identifier?.rawValue ?? "").hasPrefix("welcome") })?.close()
    }

    @MainActor func application(_ application: NSApplication, open urls: [URL]) {
        pendingURLs += urls
        launchedWithFiles = true
        flush()
    }

    @MainActor private func flush() {
        guard let workbench else { return }
        for url in pendingURLs {
            if url.hasDirectoryPath { workbench.openFolder(url: url) } else { workbench.openFile(url: url) }
        }
        pendingURLs.removeAll()
    }
}

/// Lets non-view code open the Workbench window (set by whichever window is on screen first).
@MainActor enum WindowRouter { static var openWorkbench: (() -> Void)? }

/// Wraps the original disc-scrubbing UI (unchanged) with its own AppState, so each Disc Scrubber
/// window opened from the Workbench is independent.
struct DiscScrubberWindowView: View {
    @StateObject private var appState = AppState()

    var body: some View {
        DiscScrubberView()
            .environmentObject(appState)
    }
}
