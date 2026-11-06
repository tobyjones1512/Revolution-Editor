import Foundation
import AppKit
import Combine

/// Which files inside a Hot Swap project the user has explicitly opted in to swapping onto the
/// base disc (Project Navigator -> right-click a file -> "Mark for Hot Swap"). Hot Swap doesn't
/// overlay the whole project folder anymore, a real mod project routinely also holds source
/// assets (`.obj`/`.mtl`/`.skp`, work-in-progress files) that were never meant to land on a real
/// disc, so swapping in *everything* by default was surprising and hard to reason about. Marks are
/// stored per project (keyed by the project root's path) in `UserDefaults` rather than written
/// into the project folder itself, matching `RunInEmulatorView`'s own `hotSwapBaseISO` bookmark.
/// `nonisolated` so both the (`@MainActor`) Project Navigator's right-click action and
/// `EmulatorLauncher.filesToSwap`'s `nonisolated` file walk can call straight in.
nonisolated enum HotSwapMarks {
    private static func key(forProject projectURL: URL) -> String {
        "HotSwapMarks.\(projectURL.path)"
    }

    /// Disc-relative paths (no leading slash), matching `EmulatorLauncher.filesToSwap`'s own
    /// path format.
    static func marked(forProject projectURL: URL) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key(forProject: projectURL)) ?? [])
    }

    static func isMarked(_ relativePath: String, forProject projectURL: URL) -> Bool {
        marked(forProject: projectURL).contains(relativePath)
    }

    static func setMarked(_ marked: Bool, relativePath: String, forProject projectURL: URL) {
        var set = Self.marked(forProject: projectURL)
        if marked { set.insert(relativePath) } else { set.remove(relativePath) }
        UserDefaults.standard.set(Array(set), forKey: key(forProject: projectURL))
    }
}

/// Runs a disc image / WAD / extracted-disc folder through the user's own installed Wii/GameCube
/// emulator, with the console output streamed back into the app.
///
/// This deliberately does not reimplement an emulator, a real one (CPU/GPU/audio emulation, a
/// Bluetooth HID stack for pairing real Wii Remotes, ...) represents decades of engineering this
/// app cannot responsibly fake. Instead it shells out to Dolphin (https://dolphin-emu.org, GPLv2+)
/// if it's installed, the same way double-clicking a disc image with Dolphin set as its handler
/// would. That's also why this is named/labelled plainly wherever it's shown in the UI: using
/// Dolphin's code/behavior without saying so would violate the license it's under.
@MainActor final class EmulatorLauncher: ObservableObject {
    /// Shared instance for UI that just needs to display/edit the Dolphin path (e.g. Settings)
    /// without participating in a particular Run session's console output.
    static let shared = EmulatorLauncher()

    @Published var isRunning = false
    /// Problems found in the marked files when Play was pressed; the UI lists them before booting.
    @Published var hotSwapPreflight: HotSwapPreflightReport?
    @Published var checkingHotSwap = false
    /// A Dolphin this app opened through Launch Services (no pipe, so `isRunning` stays false for it).
    @Published private(set) var launchedApp: NSRunningApplication?
    private var terminationObserver: NSObjectProtocol?
    /// Whether a Dolphin this app started is still alive.
    var isActive: Bool { isRunning || launchedApp != nil }
    @Published var logLines: [String] = []
    @Published var lastExitCode: Int32?
    @Published var capturedConsoleOutput = false

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    private static let bundleIDKey = "EmulatorLauncher.dolphinBundleID"
    private static let manualPathKey = "EmulatorLauncher.dolphinManualPath"
    private static let preferRealHardwareKey = "EmulatorLauncher.preferRealHardware"
    private static let knownBundleIDs = ["org.DolphinEmu.dolphin-emu", "com.dolphin-emu.dolphin"]

    // Settings > Emulator: each becomes a Dolphin command-line option at launch. Unset = Dolphin's own setting.
    static let backendKey = "EmulatorLauncher.backend"            // "" or Metal / Vulkan / OGL / Software Renderer
    static let resolutionKey = "EmulatorLauncher.resolution"      // -1 default, else EFB scale (1 = native)
    static let fullscreenKey = "EmulatorLauncher.fullscreen"      // "default" / "on" / "off"
    static let speedKey = "EmulatorLauncher.speed"                // -1 default, 0 unlimited, else 1.0 = 100%
    static let dualCoreKey = "EmulatorLauncher.dualCore"          // tri-state
    static let overclockKey = "EmulatorLauncher.overclock"        // -1 default, else CPU clock multiplier
    static let pauseOnFocusLossKey = "EmulatorLauncher.pauseOnFocusLoss"   // tri-state
    static let muteKey = "EmulatorLauncher.mute"
    static let extraArgumentsKey = "EmulatorLauncher.extraArguments"

    /// The Dolphin options Settings > Emulator asks for, as command-line arguments.
    static func userArguments() -> [String] {
        let d = UserDefaults.standard
        var a: [String] = []
        func tri(_ key: String, _ config: String) {
            switch d.string(forKey: key) { case "on": a += ["-C", "\(config)=True"]; case "off": a += ["-C", "\(config)=False"]; default: break }
        }
        if let b = d.string(forKey: backendKey), !b.isEmpty { a += ["-v", b] }
        if d.object(forKey: resolutionKey) != nil, d.integer(forKey: resolutionKey) > 0 { a += ["-C", "GFX.Settings.EFBScale=\(d.integer(forKey: resolutionKey))"] }
        tri(fullscreenKey, "Main.Display.Fullscreen")
        if d.object(forKey: speedKey) != nil, d.double(forKey: speedKey) >= 0 { a += ["-C", "Main.Core.EmulationSpeed=\(d.double(forKey: speedKey))"] }
        tri(dualCoreKey, "Main.Core.CPUThread")
        if d.object(forKey: overclockKey) != nil, d.double(forKey: overclockKey) > 0 { a += ["-C", "Main.Core.OverclockEnable=True", "-C", "Main.Core.Overclock=\(d.double(forKey: overclockKey))"] }
        tri(pauseOnFocusLossKey, "Main.General.PauseOnFocusLost")
        if d.bool(forKey: muteKey) { a += ["-C", "Main.DSP.Volume=0"] }
        a += (d.string(forKey: extraArgumentsKey) ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        return a
    }

    /// Settings > Games toggle, checked at every launch (see `applyDumpTexturesSettingIfNeeded`).
    static let dumpTexturesKey = "EmulatorLauncher.dumpTextures"

    /// When on, always opens Dolphin the same way double-clicking a disc image would (Launch
    /// Services) instead of running its CLI binary directly as a subprocess of this app. Real
    /// Wii Remote pairing needs Bluetooth, which macOS gates per "responsible process", that
    /// attribution differs for a raw `Process()`-spawned binary vs. one Launch Services opened,
    /// so a subprocess launch can silently lose Bluetooth access that a normal launch has. This
    /// trades away the in-app console log (Launch Services doesn't hand back a pipe to read) for
    /// real hardware working, so it's opt-in rather than the default.
    @Published var preferRealHardware = UserDefaults.standard.bool(forKey: preferRealHardwareKey) {
        didSet { UserDefaults.standard.set(preferRealHardware, forKey: Self.preferRealHardwareKey) }
    }

    /// The installed Dolphin.app, auto-detected via Launch Services or a manually-chosen path
    /// remembered from a previous "Locate Dolphin..." pick.
    var dolphinAppURL: URL? {
        if let manual = UserDefaults.standard.string(forKey: Self.manualPathKey) {
            let url = URL(fileURLWithPath: manual)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        for id in Self.knownBundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        for path in ["/Applications/Dolphin.app", "\(NSHomeDirectory())/Applications/Dolphin.app"] {
            if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    func rememberManuallyChosen(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: Self.manualPathKey)
        objectWillChange.send()
    }

    private func log(_ s: String) {
        logLines.append(s)
        if logLines.count > 5000 { logLines.removeFirst(logLines.count - 5000) }
    }

    /// Launches `path` (an ISO/WBFS/WAD/GCM, or a folder laid out like an extracted disc --
    /// Dolphin can boot straight from one, no repacking needed) in Dolphin. Tries to capture live
    /// console output by running Dolphin's own CLI binary directly with piped stdout/stderr; falls
    /// back to launching Dolphin.app through Launch Services instead (see `openWithLaunchServices`)
    /// if the app's sandbox refuses that direct exec, or if `preferRealHardware` is on, real
    /// emulation either way, just without the in-app log in the Launch Services case.
    func run(path: URL) { launch(arguments: ["-b", "-e", path.path], name: path.lastPathComponent) }

    /// Boots the Homebrew Channel from Dolphin's Wii NAND, which then lists the apps on the synced SD
    /// card. The channel has to be installed there already (as a WAD); the caller checks.
    func runHomebrewChannel() {
        launch(arguments: ["-b", "-n", HomebrewPackage.channelTitleID ?? "000100014c554c5a"], name: "the Homebrew Channel")
    }

    /// The project a Hot Swap is starting for, so its outcome posts a notification once known.
    private var hotSwapName: String?

    /// Logs `failure` (if any) and, when a Hot Swap was starting, notifies how it went.
    private func hotSwapFinished(_ failure: String? = nil) {
        if let failure { log(failure) }
        guard let name = hotSwapName else { return }
        hotSwapName = nil
        AppNotifications.hotSwap(project: name, failure: failure)
    }

    /// Pressing Play while a Dolphin this app started is still open force-quits it and boots
    /// again, so the new build / marked files are what's running.
    private var relaunching = false

    private func launch(arguments: [String], name: String) {
        guard !relaunching else { return }
        guard isActive else { startLaunch(arguments: arguments, name: name); return }
        let (oldProcess, oldApp) = (process, launchedApp)
        relaunching = true
        forceStop()
        Task {
            // Up to 2s for the old one to actually exit before starting the new one.
            for _ in 0..<40 where (oldProcess?.isRunning ?? false) || !(oldApp?.isTerminated ?? true) {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            isRunning = false
            launchedApp = nil
            relaunching = false
            startLaunch(arguments: arguments, name: name)
            log("Restarted Dolphin with the latest changes.")
        }
    }

    private func startLaunch(arguments: [String], name: String) {
        let arguments = arguments + Self.userArguments()
        guard let dolphinAppURL else {
            hotSwapFinished("Dolphin isn't installed (or hasn't been located yet).")
            return
        }
        logLines.removeAll()
        lastExitCode = nil
        capturedConsoleOutput = false
        Self.applyDumpTexturesSettingIfNeeded()

        if preferRealHardware {
            openWithLaunchServices(arguments: arguments, name: name, dolphinAppURL: dolphinAppURL)
            return
        }

        let cliBinary = dolphinAppURL.appendingPathComponent("Contents/MacOS/Dolphin")
        guard FileManager.default.isExecutableFile(atPath: cliBinary.path) else {
            openWithLaunchServices(arguments: arguments, name: name, dolphinAppURL: dolphinAppURL)
            return
        }

        let task = Process()
        task.executableURL = cliBinary
        task.arguments = arguments
        let outPipe = Pipe(), errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.appendConsole(s) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.appendConsole(s) }
        }
        task.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                // A relaunch may already have replaced this process; leave the new one's state alone.
                guard let self, self.process === proc else { return }
                self.isRunning = false
                self.lastExitCode = proc.terminationStatus
                self.log("Dolphin exited (status \(proc.terminationStatus)).")
                self.process = nil
                self.stdoutPipe = nil
                self.stderrPipe = nil
            }
        }

        do {
            try task.run()
            process = task
            stdoutPipe = outPipe
            stderrPipe = errPipe
            isRunning = true
            capturedConsoleOutput = true
            log("Launched Dolphin (\(dolphinAppURL.lastPathComponent)) with \(name).")
            hotSwapFinished()
        } catch {
            log("Couldn't capture Dolphin's console directly (\(error.localizedDescription)); opening it normally instead.")
            openWithLaunchServices(arguments: arguments, name: name, dolphinAppURL: dolphinAppURL)
        }
    }

    private func appendConsole(_ s: String) {
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            log(String(line))
        }
    }

    /// Launches Dolphin.app itself (through Launch Services, so it gets the same process identity
    ///, and Bluetooth/TCC standing, as double-clicking it would) and hands it `-b -e <path>`
    /// as launch-time arguments, the same flags the direct-subprocess path uses. Deliberately
    /// *not* `NSWorkspace.open([path], withApplicationAt:...)`, which asks Launch Services to open
    /// `path` as a *document*, that requires Dolphin's Info.plist to have declared the file's
    /// type as one it accepts, which it doesn't for plain disc images/WADs/extracted-disc folders,
    /// so that call fails outright ("cannot open the specified document") for exactly the files
    /// this method needs to hand it. Passing the path as a CLI argument instead sidesteps that
    /// document-type check entirely.
    private func openWithLaunchServices(arguments: [String], name: String, dolphinAppURL: URL) {
        Task { @MainActor in
            await quitRunningDolphinIfNeeded(dolphinAppURL: dolphinAppURL)

            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            config.arguments = arguments
            // Defaults to false, which is exactly the failure mode this whole method exists to
            // avoid: without it, Launch Services can still just activate whatever Dolphin process
            // it considers "the" instance (including one that only *just* finished quitting, in
            // the brief window before Launch Services' own bookkeeping catches up) instead of
            // spawning the fresh process that actually receives `arguments`. Dolphin comes to
            // the front with nothing booted. This forces a new process every time,
            // regardless of that race.
            config.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: dolphinAppURL, configuration: config) { [weak self] app, error in
                Task { @MainActor in
                    if let error {
                        self?.hotSwapFinished("Couldn't open Dolphin: \(error.localizedDescription)")
                    } else {
                        self?.log("Opened \(name) in Dolphin (\(dolphinAppURL.lastPathComponent)).")
                        self?.hotSwapFinished()
                        self?.track(app)
                    }
                }
            }
        }
    }

    /// `-b -e <path>` as launch arguments only reaches a *freshly started* Dolphin process --
    /// Launch Services just activates an already-running instance's existing window instead of
    /// delivering new arguments to it, so a Dolphin left open idle (from a previous run, or the
    /// user having it open already) silently swallows the game path: Dolphin comes to the front,
    /// nothing boots. Quitting any running instance first guarantees the launch right after is the
    /// fresh one that actually receives the game.
    private func quitRunningDolphinIfNeeded(dolphinAppURL: URL) async {
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL == dolphinAppURL || ($0.bundleIdentifier.map(Self.knownBundleIDs.contains) ?? false)
        }
        guard !running.isEmpty else { return }
        log("Quitting the already-running Dolphin so it launches fresh with this game...")
        for app in running { app.terminate() }
        for _ in 0..<40 where !running.allSatisfy(\.isTerminated) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Turns on Dolphin's own texture dumping (Graphics > Advanced > "Dump Textures") before a
    /// launch, when Settings > Games has asked for it. Dolphin only reads this from its config
    /// file, not a CLI flag, so this patches the global `GFX.ini`'s `[Settings]` section directly
    ///, the same file the in-app checkbox would edit, rather than requiring the user go set it
    /// there by hand every time. Textures land in `Dolphin/Dump/Textures/<GameID>/` once a game
    /// with a texture actually draws.
    private static func applyDumpTexturesSettingIfNeeded() {
        guard UserDefaults.standard.bool(forKey: dumpTexturesKey) else { return }
        let fm = FileManager.default
        let dolphinUserDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Dolphin", isDirectory: true)
        guard fm.fileExists(atPath: dolphinUserDir.path) else { return }
        let gfxIni = dolphinUserDir.appendingPathComponent("Config/GFX.ini")
        try? fm.createDirectory(at: gfxIni.deletingLastPathComponent(), withIntermediateDirectories: true)

        var lines = (try? String(contentsOf: gfxIni, encoding: .utf8))?
            .components(separatedBy: "\n") ?? []
        guard let settingsHeader = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[Settings]" }) else {
            lines.append(contentsOf: ["[Settings]", "DumpTextures = True"])
            try? lines.joined(separator: "\n").write(to: gfxIni, atomically: true, encoding: .utf8)
            return
        }
        // Replace an existing DumpTextures line within [Settings] (up to the next section header
        // or EOF), or add one if this file has never set it.
        let sectionEnd = lines[(settingsHeader + 1)...].firstIndex(where: { $0.hasPrefix("[") }) ?? lines.count
        if let existing = lines[(settingsHeader + 1)..<sectionEnd].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("DumpTextures")
        }) {
            lines[existing] = "DumpTextures = True"
        } else {
            lines.insert("DumpTextures = True", at: settingsHeader + 1)
        }
        try? lines.joined(separator: "\n").write(to: gfxIni, atomically: true, encoding: .utf8)
    }

    func stop() {
        process?.terminate()
    }

    /// Ends the Dolphin this app started immediately, without waiting for it to quit cleanly.
    func forceStop() {
        if let p = process, p.isRunning { kill(p.processIdentifier, SIGKILL) }
        launchedApp?.forceTerminate()
        log("Force-stopped Dolphin.")
    }

    private func track(_ app: NSRunningApplication?) {
        launchedApp = app
        guard terminationObserver == nil else { return }
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let ended = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { if let self, ended == self.launchedApp { self.launchedApp = nil } }
        }
    }

    // MARK: Hot Swap (Riivolution-style per-file redirection)

    /// Boots `baseISO` with every file the user has explicitly marked (Project Navigator ->
    /// right-click a file -> "Mark for Hot Swap", see `HotSwapMarks`) swapped in live,
    /// Riivolution-style, so a mod project can stay a loose folder instead of a full rebuilt ISO.
    /// This doesn't reimplement Riivolution or touch the disc image at all, it leans entirely on
    /// a real mechanism already built into Dolphin itself: a small JSON "game mod descriptor"
    /// (`base-file` + a Riivolution `<wiidisc>` XML) that Dolphin recognizes and applies at boot,
    /// the same as if the user had picked the patch in Dolphin's own Riivolution GUI. The format
    /// follows Dolphin's source (`DiscIO/{RiivolutionParser,RiivolutionPatcher,
    /// GameModDescriptor}.{h,cpp}` and the `.json` handling in `Core/Boot/Boot.cpp`).
    /// Play with Hot Swap: checks the marked files first (`HotSwapPreflight`) and boots straight
    /// away when nothing is found, else leaves the findings in `hotSwapPreflight` for the user.
    func requestHotSwap(baseISO: URL, modRoot: URL) {
        guard !checkingHotSwap else { return }
        let files = Self.filesToSwap(modRoot: modRoot)
        guard !files.isEmpty, HotSwapPreflight.enabled else { runHotSwap(baseISO: baseISO, modRoot: modRoot); return }
        checkingHotSwap = true
        Task {
            let findings = await Task.detached(priority: .userInitiated) {
                HotSwapPreflight.check(modRoot: modRoot, files: files, gameID: Self.readGameID(from: baseISO))
            }.value
            checkingHotSwap = false
            if findings.isEmpty { runHotSwap(baseISO: baseISO, modRoot: modRoot) }
            else { hotSwapPreflight = HotSwapPreflightReport(baseISO: baseISO, modRoot: modRoot, findings: findings) }
        }
    }

    /// Auto Correct: applies `findings`' fixes to the marked files they're about (saved in place),
    /// then checks again, booting straight away if nothing is left, else showing what remains.
    func autoCorrect(_ findings: [HotSwapPreflight.Finding], in report: HotSwapPreflightReport) {
        let fixes = findings.compactMap { f in f.fix.map { (f.relative, $0) } }
        guard !fixes.isEmpty, !checkingHotSwap else { return }
        let (modRoot, baseISO) = (report.modRoot, report.baseISO)
        hotSwapPreflight = nil
        checkingHotSwap = true
        if let iso = BaseGameLibrary.linkedISO { KeyManager.shared.autoLoad(nextTo: iso) }
        let keys = (common: KeyManager.shared.commonKey, korean: KeyManager.shared.koreanKey)
        Task {
            let (said, findings) = await Task.detached(priority: .userInitiated) { () -> ([String], [HotSwapPreflight.Finding]) in
                var said: [String] = []
                for relative in Array(Set(fixes.map(\.0))).sorted() {
                    let mine = fixes.filter { $0.0 == relative }.map(\.1)
                    do { said += try HotSwapPreflight.applyFixes(mine, to: relative, modRoot: modRoot, keys: keys) }
                    catch { said.append("Couldn't correct \((relative as NSString).lastPathComponent): \(error.localizedDescription)") }
                }
                let files = Self.filesToSwap(modRoot: modRoot)
                return (said, HotSwapPreflight.check(modRoot: modRoot, files: files, gameID: Self.readGameID(from: baseISO)))
            }.value
            checkingHotSwap = false
            said.forEach { log("Auto Correct: " + $0) }
            if findings.isEmpty { runHotSwap(baseISO: baseISO, modRoot: modRoot) }
            else { hotSwapPreflight = HotSwapPreflightReport(baseISO: baseISO, modRoot: modRoot, findings: findings, corrected: said) }
        }
    }

    func runHotSwap(baseISO: URL, modRoot: URL) {
        guard !checkingHotSwap else { return }
        let files = Self.filesToSwap(modRoot: modRoot)
        guard !files.isEmpty else {
            hotSwapName = modRoot.lastPathComponent
            hotSwapFinished("Nothing is marked for Hot Swap in \(modRoot.lastPathComponent), right-click a file in the Project Navigator and choose \"Mark for Hot Swap\" first.")
            return
        }
        guard let gameID = Self.readGameID(from: baseISO) else {
            hotSwapName = modRoot.lastPathComponent
            hotSwapFinished("Couldn't read a game ID from \(baseISO.lastPathComponent), is it a valid Wii/GCN disc image?")
            return
        }
        hotSwapName = modRoot.lastPathComponent
        // Every marked file under the disc name(s) it replaces, its own name, or its chosen
        // target's (see `HotSwapTargets`).
        // Off the main thread: marked folders are packed and compressed here, and a GameCube disc
        // is copied and patched.
        checkingHotSwap = true
        Task {
            let staging = await Task.detached(priority: .userInitiated) {
                Result { try HotSwapTargets.stage(modRoot: modRoot, files: files, baseISO: baseISO) }
            }.value
            checkingHotSwap = false
            switch staging {
            case .failure(let error): hotSwapFinished("Couldn't prepare the Hot Swap files: \(error.localizedDescription)")
            case .success(let result):
                result.notes.forEach { log($0) }
                guard !result.files.isEmpty else { hotSwapFinished("Nothing to swap."); return }
                if GameCubeHotSwap.isGameCubeDisc(baseISO) {
                    await runGameCubeHotSwap(baseISO: baseISO, modRoot: result.root, files: result.files, gameID: gameID)
                } else {
                    bootRiivolution(baseISO: baseISO, modRoot: modRoot, stagedRoot: result.root, staged: result.files, marked: files.count, gameID: gameID)
                }
            }
        }
    }

    private func bootRiivolution(baseISO: URL, modRoot: URL, stagedRoot: URL, staged: [String], marked: Int, gameID: String) {
        do {
            let descriptorURL = try Self.writeHotSwapDescriptor(gameID: gameID, baseISO: baseISO, modRoot: stagedRoot, files: staged)
            log("""
            Hot-swapping \(marked) marked file(s) from \(modRoot.lastPathComponent) onto \(baseISO.lastPathComponent) \
            (game \(gameID)) via a generated Riivolution patch (Dolphin applies this itself at boot; the ISO on \
            disk is never touched).
            """)
            run(path: descriptorURL)
        } catch {
            hotSwapFinished("Couldn't prepare the hot-swap patch: \(error.localizedDescription)")
        }
    }

    /// GameCube (Double Dash) Hot Swap: Riivolution is Wii-only, so the marked files are written into
    /// a patched clone of the base disc (see `GameCubeHotSwap`) and Dolphin boots that. Same
    /// matching as Wii Hot Swap, a marked file replaces the disc file with the same name.
    private func runGameCubeHotSwap(baseISO: URL, modRoot: URL, files: [String], gameID: String) async {
        checkingHotSwap = true
        defer { checkingHotSwap = false }
        do {
            let appSupport = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let output = appSupport.appendingPathComponent("Revolution IDE/HotSwap", isDirectory: true)
                .appendingPathComponent(modRoot.lastPathComponent, isDirectory: true)
                .appendingPathComponent("\(gameID) Hot Swap.iso")
            let result = try await Task.detached(priority: .userInitiated) {
                try GameCubeHotSwap.buildPatchedDisc(base: baseISO, modRoot: modRoot, files: files, output: output)
            }.value
            guard !result.replaced.isEmpty else {
                hotSwapFinished("None of the marked files match a file on \(baseISO.lastPathComponent) (Hot Swap replaces the disc file with the same name): \(result.unmatched.joined(separator: ", ")).")
                return
            }
            log("""
            Hot-swapping \(result.replaced.count) file(s) from \(modRoot.lastPathComponent) onto \(baseISO.lastPathComponent) (game \(gameID)) \
            via a patched copy of the disc; the original is never touched. For a real Wii, the same copy runs in Nintendont: \(output.path)
            """)
            if !result.unmatched.isEmpty { log("No file with the same name on the disc, skipped: \(result.unmatched.joined(separator: ", ")).") }
            run(path: output)
        } catch {
            hotSwapFinished("Couldn't prepare the Hot Swap disc: \(error.localizedDescription)")
        }
    }

    /// The disc-relative paths that will actually be swapped in: every file under `modRoot` the
    /// user has marked via `HotSwapMarks`, intersected with what's still really there (a mark for
    /// a since-deleted/renamed file is silently dropped rather than erroring). Sorted for a stable,
    /// readable listing; used both to build the generated patch and by the UI to preview it before
    /// Dolphin boots.
    nonisolated static func filesToSwap(modRoot: URL) -> [String] {
        let marks = HotSwapMarks.marked(forProject: modRoot)
        guard !marks.isEmpty else { return [] }
        // Marked folders too: they're packed into an archive when staged (`HotSwapFolderPack`).
        let folders = marks.filter { m in
            var dir: ObjCBool = false
            return FileManager.default.fileExists(atPath: modRoot.appendingPathComponent(m).path, isDirectory: &dir) && dir.boolValue
        }
        return (allFiles(under: modRoot).filter { marks.contains($0) } + folders).sorted()
    }

    /// Every file under `modRoot`, as disc-relative paths (no leading slash), what a user can
    /// mark, and what `filesToSwap` filters down to just the marked subset of. Symlinks aren't
    /// followed, matching how a real disc filesystem (which has no symlinks) would end up.
    private nonisolated static func allFiles(under modRoot: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: modRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else { return [] }

        let rootPath = modRoot.standardizedFileURL.path
        var out: [String] = []
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard !isDirectory else { continue }
            var relative = url.standardizedFileURL.path
            guard relative.hasPrefix(rootPath) else { continue }
            relative.removeFirst(rootPath.count)
            if relative.hasPrefix("/") { relative.removeFirst() }
            out.append(relative)
        }
        return out.sorted()
    }

    /// The Wii disc game ID (e.g. "RMCE01") lives unencrypted at the very start of every disc
    /// image, no keys needed, unlike everything else this app reads from a Wii disc.
    nonisolated static func readGameID(from iso: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: iso) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 6), data.count == 6 else { return nil }
        let id = String(decoding: data, as: UTF8.self)
        guard id.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else { return nil }
        return id
    }

    /// Writes a Riivolution `<wiidisc>` patch, one `<file>` rule per marked file, into the mod
    /// project folder itself, plus the `dolphin-game-mod-descriptor` JSON that points Dolphin at it
    /// under Application Support. Both are small and cheap to regenerate on every launch, so
    /// there's no staleness to worry about.
    ///
    /// The XML deliberately lives *in the project root*, and each `<file external="...">` is the
    /// marked file's path relative to that root. A Riivolution `external` value is never a host
    /// path: `FileDataLoaderHostFS::MakeAbsoluteFromRelative` in `RiivolutionPatcher.cpp` resolves
    /// it against Dolphin's SD-card root when it starts with "/" and against the patch root
    /// otherwise, and refuses to climb above that root with "..". So an absolute `/Users/...` path
    /// (what this used to emit, for both `external` and the descriptor's `root`) resolved to
    /// `<sd root>/Users/...`, which doesn't exist, `GetFileContents` returned empty and the patch
    /// silently swapped in nothing, which is exactly the bug this layout fixes. The patch root
    /// defaults to the directory holding the XML, so putting the XML beside the project's files is
    /// what makes a plain relative `external` land on the real file, wherever under the project it
    /// happens to live.
    ///
    /// Each `<file disc="...">` is the marked file's bare filename, deliberately with no folder
    /// path, matching how a mod file is expected to work here (replace the real disc file with
    /// the same name, wherever it actually lives on the disc, regardless of where the user's own
    /// project happens to keep it). Re-verified against `RiivolutionPatcher.cpp`'s
    /// `ApplyFilePatchToFST` after this broke in practice: a `disc` value is only treated as an
    /// *exact path* (`FindFileNodeInFST`, walked component-by-component) when it starts with "/";
    /// otherwise (and not literally "main.dol") it falls to `FindFilenameNodeInFST`, which compares
    /// a bare FST leaf's filename against the *entire* `disc` string, so a `disc` value with any
    /// "/" in it (a full relative path, without a leading slash, e.g. what this used to generate
    /// for a nested project file, or a wrongly-guessed exact path that doesn't match the disc's
    /// real layout) never equals any real filename and silently matches nothing. A bare filename
    /// with no "/" at all is the only form that reliably finds the real file regardless of the mod
    /// project's own folder layout. The tradeoff, two different disc folders sharing a filename
    /// would collide, doesn't come up for the loose top-level files (course archives, textures,
    /// ...) Hot Swap actually targets, which have distinct names across a real MKWii disc.
    ///
    /// The `<patch>` element has to be wrapped in an `<options>/<section>/<option>/<choice>` that
    /// selects it (here, an option defaulted "on"), `Disc::GeneratePatches` in
    /// `RiivolutionParser.cpp` only ever includes patches reached through a *selected* choice's
    /// `<patch id>` reference; a bare top-level `<patch>` with no options section pointing at it is
    /// parsed fine but silently dropped before boot, so nothing gets swapped in. (Earlier versions
    /// of this file got this wrong; `GeneratePatches` shows why.)
    private static func writeHotSwapDescriptor(gameID: String, baseISO: URL, modRoot: URL, files: [String]) throws -> URL {
        let appSupport = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true)
        let dir = appSupport.appendingPathComponent("Revolution IDE/HotSwap", isDirectory: true)
            .appendingPathComponent(modRoot.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // No `create` attribute: `FindFilenameNodeInFST` (which a filename-only `disc` value
        // always goes through) never creates anything regardless of it, only the exact-path
        // branch (a leading "/") does. A marked file that doesn't match any real disc filename
        // is silently a no-op, matching "replace an existing game file" rather than "add a new
        // one", the only thing Hot Swap actually does.
        let fileElements = files.map { relativePath in
            "    <file external=\"\(xmlEscape(relativePath))\" disc=\"\(xmlEscape((relativePath as NSString).lastPathComponent))\"/>"
        }.joined(separator: "\n")

        // Hidden so it stays out of the Project Navigator and out of `allFiles`' own
        // `.skipsHiddenFiles` walk (i.e. it can never end up marked for swapping itself).
        let xmlURL = modRoot.appendingPathComponent(".revolution-hotswap.xml")
        let xml = hotSwapXML(gameID: gameID, fileElements: fileElements)
        try xml.write(to: xmlURL, atomically: true, encoding: .utf8)

        let descriptor: [String: Any] = [
            "type": "dolphin-game-mod-descriptor",
            "version": 1,
            "base-file": baseISO.path,
            "display-name": "\(modRoot.lastPathComponent) (Hot Swap)",
            // No "root": that field is the emulated *SD card* root, not the patch root (see
            // `GenerateRiivolutionPatchesFromGameModDescriptor`, which passes it as
            // `FileDataLoaderHostFS`'s `sd_root`), so pointing it at the project did nothing for a
            // relative `external`. Omitted, the patch root stays the XML's own directory, which is
            // now the project root.
            "riivolution": ["patches": [["xml": xmlURL.path, "options": []]]],
        ]
        installIntoDolphinRiivolutionFolder(gameID: gameID, modRoot: modRoot, files: files)

        let jsonURL = dir.appendingPathComponent("descriptor.json")
        let jsonData = try JSONSerialization.data(withJSONObject: descriptor, options: [.prettyPrinted])
        try jsonData.write(to: jsonURL, options: .atomic)
        return jsonURL
    }

    private static func hotSwapXML(gameID: String, fileElements: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <wiidisc version="1">
          <id game="\(xmlEscape(gameID))"/>
          <options>
            <section name="Revolution Editor">
              <option name="Hot Swap" default="1">
                <choice name="Enabled">
                  <patch id="revolution-ide-hotswap"/>
                </choice>
              </option>
            </section>
          </options>
          <patch id="revolution-ide-hotswap">
        \(fileElements)
          </patch>
        </wiidisc>
        """
    }

    /// Dolphin's own Riivolution browser (Tools -> "Start with Riivolution Patches") only lists
    /// XMLs it finds in `<Dolphin user dir>/Load/Riivolution`, and it never learns about the
    /// descriptor `runHotSwap` generates. So booting the ISO straight from Dolphin's game list --
    /// which is what most people do, ignores this app's patch entirely and uses whatever is
    /// sitting in that folder instead.
    ///
    /// That folder used to receive a *copy* of each marked file. A copy is a second source of
    /// truth: it went two days stale without a word, and the game kept quietly loading the old
    /// build while its author rebuilt and re-tested against it. So the marked files are installed
    /// as **symlinks** into the live project instead. There is then only ever one copy of the
    /// data, and a manual boot cannot serve anything but the current build.
    ///
    /// `external` stays a bare filename resolved against the XML's own directory, the same
    /// resolution the in-project XML relies on, so this adds no new assumption about Dolphin's
    /// path handling. Silently does nothing when Dolphin has never been run (no user directory).
    private static func installIntoDolphinRiivolutionFolder(gameID: String, modRoot: URL, files: [String]) {
        let fm = FileManager.default
        let dolphinUserDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Dolphin", isDirectory: true)
        guard fm.fileExists(atPath: dolphinUserDir.path) else { return }
        let dir = dolphinUserDir.appendingPathComponent("Load/Riivolution", isDirectory: true)
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return }

        // Drop links this app left behind on an earlier run, only ever symlinks pointing back
        // into this project, never a real file someone else put here.
        let projectPath = modRoot.standardizedFileURL.path
        for entry in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            guard let target = try? fm.destinationOfSymbolicLink(atPath: entry.path) else { continue }
            if target.hasPrefix(projectPath + "/") { try? fm.removeItem(at: entry) }
        }
        // The pre-symlink versions of this app wrote a copy plus a shared-name XML here; both are
        // this app's own regenerable output, and leaving them would keep shadowing the live files.
        let legacyXML = dir.appendingPathComponent("revolution-hotswap.xml")
        if let contents = try? String(contentsOf: legacyXML, encoding: .utf8),
           contents.contains("revolution-ide-hotswap") {
            try? fm.removeItem(at: legacyXML)
        }

        var linked: [String] = []
        for relativePath in files {
            let filename = (relativePath as NSString).lastPathComponent
            let source = modRoot.appendingPathComponent(relativePath)
            let link = dir.appendingPathComponent(filename)
            if fm.fileExists(atPath: link.path) || (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil {
                // A stale copy of this very export from an older build of this app.
                try? fm.removeItem(at: link)
            }
            guard (try? fm.createSymbolicLink(at: link, withDestinationURL: source)) != nil else { continue }
            linked.append("    <file external=\"\(xmlEscape(filename))\" disc=\"\(xmlEscape(filename))\"/>")
        }
        guard !linked.isEmpty else { return }

        // Namespaced per project so two projects' patches can coexist in Dolphin's list.
        let xmlURL = dir.appendingPathComponent("\(modRoot.lastPathComponent)-hotswap.xml")
        try? hotSwapXML(gameID: gameID, fileElements: linked.joined(separator: "\n"))
            .write(to: xmlURL, atomically: true, encoding: .utf8)
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Opens Dolphin's own settings UI (real controller/Wii Remote configuration, including
    /// Bluetooth pairing for real hardware), this app doesn't reimplement that UI, it just
    /// brings Dolphin itself forward so the user can use its actual settings.
    func openDolphinSettings() {
        guard let dolphinAppURL else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: dolphinAppURL, configuration: config)
    }
}

struct HotSwapPreflightReport: Identifiable {
    let id = UUID()
    let baseISO: URL
    let modRoot: URL
    let findings: [HotSwapPreflight.Finding]
    /// What the last Auto Correct changed, shown at the top of the sheet.
    var corrected: [String] = []
}
