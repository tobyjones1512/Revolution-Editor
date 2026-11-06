import SwiftUI
import SceneKit
import UniformTypeIdentifiers

/// The app's Settings window (Cmd+, / RevolutionIDE > Settings...). Consolidates things that
/// were previously only reachable piecemeal (keys via File > Load Keys in the Disc Scrubber
/// window only, Dolphin's path only from the Run sheet) into one place, and adds external-editor
/// preferences that didn't exist anywhere before.
struct SettingsView: View {
    private enum Pane: String, CaseIterable, Identifiable {
        case games = "Games", keys = "Keys", emulator = "Emulator", homebrew = "Homebrew"
        case codeEditor = "Code Editor", editing = "Editing", externalEditors = "External Editors"
        case appearance = "Appearance", controls = "Controls"
        var id: String { rawValue }
        var tint: Color {
            switch self {
            case .games: return .red
            case .keys: return .gray
            case .emulator: return .indigo
            case .homebrew: return .orange
            case .codeEditor: return .blue
            case .editing: return .teal
            case .externalEditors: return .green
            case .appearance: return .pink
            case .controls: return .mint
            }
        }
        var icon: String {
            switch self {
            case .games: return "flag.checkered"
            case .keys: return "key.fill"
            case .emulator: return "gamecontroller.fill"
            case .homebrew: return "hammer.fill"
            case .codeEditor: return "chevron.left.forwardslash.chevron.right"
            case .editing: return "clock.arrow.circlepath"
            case .externalEditors: return "square.and.pencil"
            case .appearance: return "paintpalette.fill"
            case .controls: return "keyboard.fill"
            }
        }
    }

    @AppStorage("settings.pane") private var selection = Pane.games.rawValue

    private func row(_ pane: Pane) -> some View {
        Label {
            Text(pane.rawValue)
        } icon: {
            Image(systemName: pane.icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(pane.tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .tag(pane.rawValue)
    }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                Section("Setup") { ForEach([Pane.games, .keys, .emulator, .homebrew]) { row($0) } }
                Section("Editing") { ForEach([Pane.codeEditor, .editing, .externalEditors]) { row($0) } }
                Section("App") { row(.appearance); row(.controls) }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(.regularMaterial)
            .safeAreaPadding(.top, 30)   // clear of the traffic lights
            .frame(width: 210)
            Divider()
            VStack(spacing: 0) {
                Text(selection).font(.title2.bold()).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.top, 36).padding(.bottom, 4)
                Group {
                    switch Pane(rawValue: selection) ?? .games {
                    case .games: GamesSettingsTab()
                    case .keys: KeysSettingsTab()
                    case .emulator: EmulatorSettingsTab()
                    case .homebrew: HomebrewSettingsTab()
                    case .codeEditor: CodeEditorSettingsTab()
                    case .editing: EditingSettingsTab()
                    case .externalEditors: ExternalEditorsSettingsTab()
                    case .appearance: AppearanceSettingsTab()
                    case .controls: ControlsSettingsTab()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 820, height: 580)
        .ignoresSafeArea()
        .background(SettingsWindowChrome())
    }
}

/// Lets the sidebar run up under a transparent title bar, like System Settings, instead of a separate strip above it.
private struct SettingsWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.styleMask.insert(.fullSizeContentView)
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// One "icon / title / detail / buttons" line, shared by every tab so they all read the same.
struct StatusRow<Buttons: View>: View {
    let title: String
    let detail: String?
    var placeholder = "Not set"
    @ViewBuilder var buttons: Buttons

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) { buttons }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: detail == nil ? "xmark.circle" : "checkmark.circle.fill")
                    .foregroundStyle(detail == nil ? Color.secondary : Color.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(detail ?? placeholder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }
}

extension View {
    /// Small grey explanatory text used as a section footer.
    func settingsNote() -> some View { font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
}

private struct KeysSettingsTab: View {
    @ObservedObject var keyManager = KeyManager.shared

    var body: some View {
        Form {
            Section {
                keyRow(label: "key.bin (common key)", path: keyManager.commonKeyPath, choose: {
                    PanelPresenter.openFile { url in
                        guard let url else { return }
                        try? keyManager.loadCommonKey(from: url)
                    }
                }, forget: { keyManager.forgetCommonKey() })
                keyRow(label: "kkey.bin (Korean key, optional)", path: keyManager.koreanKeyPath, choose: {
                    PanelPresenter.openFile { url in
                        guard let url else { return }
                        try? keyManager.loadKoreanKey(from: url)
                    }
                }, forget: { keyManager.forgetKoreanKey() })
            } footer: {
                Text("Wii discs are AES-encrypted. This app needs your own key.bin (16 bytes) to decrypt them, nothing is embedded or downloaded. Once chosen, a key is remembered for next time you open the app.").settingsNote()
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func keyRow(label: String, path: String?, choose: @escaping () -> Void, forget: @escaping () -> Void) -> some View {
        StatusRow(title: label, detail: path, placeholder: "Not loaded") {
            if path != nil { Button("Forget", role: .destructive, action: forget) }
            Button("Choose...", action: choose)
        }
    }
}

private struct EmulatorSettingsTab: View {
    @ObservedObject var emulator = EmulatorLauncher.shared
    @Environment(\.openWindow) private var openWindow
    @AppStorage(EmulatorLauncher.dumpTexturesKey) private var dumpTextures = false
    @AppStorage(EmulatorLauncher.backendKey) private var backend = ""
    @AppStorage(EmulatorLauncher.resolutionKey) private var resolution = -1
    @AppStorage(EmulatorLauncher.fullscreenKey) private var fullscreen = "default"
    @AppStorage(EmulatorLauncher.speedKey) private var speed = -1.0
    @AppStorage(EmulatorLauncher.dualCoreKey) private var dualCore = "default"
    @AppStorage(EmulatorLauncher.overclockKey) private var overclock = -1.0
    @AppStorage(EmulatorLauncher.pauseOnFocusLossKey) private var pauseOnFocusLoss = "default"
    @AppStorage(EmulatorLauncher.muteKey) private var mute = false
    @AppStorage(EmulatorLauncher.extraArgumentsKey) private var extraArguments = ""
    @AppStorage(HotSwapPreflight.enabledKey) private var safeguards = true

    private func triPicker(_ title: String, _ value: Binding<String>) -> some View {
        Picker(title, selection: value) {
            Text("Dolphin's setting").tag("default")
            Text("On").tag("on")
            Text("Off").tag("off")
        }
    }

    var body: some View {
        Form {
            Section {
                StatusRow(title: "Dolphin", detail: emulator.dolphinAppURL?.path, placeholder: "Not found") {
                    Button("Choose...") { chooseDolphin() }
                }
                Button("Controller / Wii Remote Settings...") { emulator.openDolphinSettings() }
                    .disabled(emulator.dolphinAppURL == nil)
                Button("Review Crash Logs") { openWindow(id: "crashLogs") }
            } header: {
                Text("Emulator")
            } footer: {
                Text("Revolution Editor doesn't reimplement an emulator, it shells out to your own installed Dolphin (dolphin-emu.org). Point it at Dolphin.app if auto-detection doesn't find it.").settingsNote()
            }
            Section {
                Picker("Video backend", selection: $backend) {
                    Text("Dolphin's setting").tag("")
                    Text("Metal").tag("Metal")
                    Text("Vulkan").tag("Vulkan")
                    Text("OpenGL").tag("OGL")
                    Text("Software Renderer").tag("Software Renderer")
                }
                Picker("Internal resolution", selection: $resolution) {
                    Text("Dolphin's setting").tag(-1)
                    Text("Native (480p)").tag(1)
                    ForEach(2...6, id: \.self) { Text("\($0)x native").tag($0) }
                }
                triPicker("Fullscreen", $fullscreen)
                Toggle("Dump textures on launch", isOn: $dumpTextures)
            } header: {
                Text("Graphics")
            } footer: {
                Text("Dump textures turns on Dolphin's own texture dumping (Graphics > Advanced), so textures a running game actually draws land in Dolphin/Dump/Textures/<GameID>/.").settingsNote()
            }
            Section {
                Picker("Emulation speed", selection: $speed) {
                    Text("Dolphin's setting").tag(-1.0)
                    Text("50%").tag(0.5)
                    Text("100%").tag(1.0)
                    Text("150%").tag(1.5)
                    Text("200%").tag(2.0)
                    Text("Unlimited").tag(0.0)
                }
                Picker("CPU clock", selection: $overclock) {
                    Text("Dolphin's setting").tag(-1.0)
                    Text("1.5x").tag(1.5)
                    Text("2x").tag(2.0)
                    Text("3x").tag(3.0)
                    Text("4x").tag(4.0)
                }
                triPicker("Dual-core CPU", $dualCore)
                triPicker("Pause when Dolphin loses focus", $pauseOnFocusLoss)
                Toggle("Mute audio", isOn: $mute)
            } header: {
                Text("Performance & Audio")
            } footer: {
                Text("Applied every time this app launches Dolphin. \"Dolphin's setting\" leaves that option as set in Dolphin itself.").settingsNote()
            }
            Section {
                Toggle("Check tracks before playing and building", isOn: $safeguards)
            } header: {
                Text("Safeguards")
            } footer: {
                Text(safeguards
                     ? "Before Hot Swap starts Dolphin, marked tracks, arenas and courses are checked. Anything likely to crash the game stops it running, and tracks with those problems aren't built to .wbz/.wlz."
                     : "Off: Hot Swap starts Dolphin without checking, and tracks are built even if they're likely to crash. Verify Archive still lists problems when you ask it to.").settingsNote()
            }
            Section {
                TextField("Extra launch options", text: $extraArguments).font(.system(.body, design: .monospaced))
            } header: {
                Text("Advanced")
            } footer: {
                Text("Added to Dolphin's command line as-is, e.g. -C Main.Core.MMU=True. Run Dolphin with --help for the list.").settingsNote()
            }
        }
        .formStyle(.grouped)
    }

    private func chooseDolphin() {
        PanelPresenter.openFile(configure: {
            $0.allowedContentTypes = [.application]
            $0.directoryURL = URL(fileURLWithPath: "/Applications")
        }) { url in
            guard let url else { return }
            emulator.rememberManuallyChosen(url)
        }
    }
}

private struct HomebrewSettingsTab: View {
    @State private var root = DevkitPro.root

    var body: some View {
        Form {
            Section {
                StatusRow(title: "devkitPro", detail: root?.path, placeholder: "Not found") {
                    Button("Choose...") { choose() }
                }
                Link("How to install devkitPro", destination: DevkitPro.installURL)
            } footer: {
                Text("Wii homebrew projects are built with your own devkitPro install (devkitpro.org), nothing from it is bundled or downloaded. Install devkitPPC and libogc (the wii-dev group), then it's found automatically at /opt/devkitpro.").settingsNote()
            }
        }
        .formStyle(.grouped)
    }

    private func choose() {
        PanelPresenter.openFile(configure: {
            $0.canChooseFiles = false
            $0.canChooseDirectories = true
            $0.directoryURL = URL(fileURLWithPath: "/opt")
        }) { url in
            guard let url else { return }
            if DevkitPro.isValid(url) {
                UserDefaults.standard.set(url.path, forKey: DevkitPro.pathKey)
            }
            root = DevkitPro.root
        }
    }
}

private struct EditingSettingsTab: View {
    @AppStorage(EditHistoryPrefs.limitKey) private var undoLimit: Int = EditHistoryPrefs.defaultLimit
    @AppStorage(SnapToGroundPrefs.startPointYPaddingKey) private var startPointYPadding = SnapToGroundPrefs.defaultStartPointYPadding
    @AppStorage(WorkbenchState.archiveOpensFolderKey) private var archiveOpensFolder = true

    var body: some View {
        Form {
            Section {
                Toggle("Opening an archive opens its folder", isOn: $archiveOpensFolder)
            } footer: {
                Text("When you open a .szs or .arc from outside the current project, its folder opens in the Project Navigator with the archive expanded.").settingsNote()
            }
            Section {
                Stepper("Undo History Limit: \(undoLimit)", value: $undoLimit, in: 1...200)
            } footer: {
                Text("How many steps back each editor's Undo History (Edit > Undo/Redo, or the History button in an editor's toolbar) keeps before the oldest step is dropped.").settingsNote()
            }
            Section {
                Stepper("Starting Point Y Padding: \(startPointYPadding)", value: $startPointYPadding, in: 0...500)
            } footer: {
                Text("Extra height added on top of the normal snap margin when \"Snap to Ground\" is applied to a Start Point (KTPT), so karts spawn well clear of the track. Other point kinds are unaffected.").settingsNote()
            }
        }
        .formStyle(.grouped)
    }
}

private struct ExternalEditorsSettingsTab: View {
    @AppStorage(ExternalEditorPrefs.imageEditorPathKey) private var imageEditorPath: String = ""
    @AppStorage(ExternalEditorPrefs.modelEditorPathKey) private var modelEditorPath: String = ""
    @AppStorage(ExternalEditorPrefs.codeEditorPathKey) private var codeEditorPath: String = ""

    var body: some View {
        Form {
            Section {
                appRow(label: "Image Editor", path: $imageEditorPath)
                appRow(label: "3D Model Editor", path: $modelEditorPath)
                appRow(label: "Code Editor (VS Code, Nova, ...)", path: $codeEditorPath)
            } footer: {
                Text("Optional apps used by \"Open in External Editor\" actions on textures, 3D models and code files. Leave unset to hide those actions.").settingsNote()
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func appRow(label: String, path: Binding<String>) -> some View {
        StatusRow(title: label, detail: path.wrappedValue.isEmpty ? nil : (path.wrappedValue as NSString).lastPathComponent) {
            if !path.wrappedValue.isEmpty { Button("Clear", role: .destructive) { path.wrappedValue = "" } }
            Button("Choose...") {
                PanelPresenter.openFile(configure: {
                    $0.allowedContentTypes = [.application]
                    $0.directoryURL = URL(fileURLWithPath: "/Applications")
                }) { url in
                    guard let url else { return }
                    path.wrappedValue = url.path
                }
            }
        }
    }
}

private struct AppearanceSettingsTab: View {
    @AppStorage("showArchiveInfoButton") private var showArchiveInfoButton = true
    @AppStorage("showPlatformTags") private var showPlatformTags = true
    @AppStorage("defaultYaz0Compression") private var defaultYaz0Compression = true
    @AppStorage("openArchivesInNewWindow") private var openArchivesInNewWindow = false
    @AppStorage("autoCollapseConsole") private var autoCollapseConsole = false
    @AppStorage("dragFilesShouldCopy") private var dragFilesShouldCopy = false
    @AppStorage(SCNMaterial.TransparencyMode.key) private var transparencyMode = SCNMaterial.TransparencyMode.automatic.rawValue

    var body: some View {
        Form {
            Section {
                Picker("Transparent surfaces", selection: $transparencyMode) {
                    ForEach(SCNMaterial.TransparencyMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } header: {
                Text("3D Preview")
            } footer: {
                Text("How textures with see-through parts are drawn. Automatic cuts out fences and foliage and blends glass and fades. Applies to models opened from now on.").settingsNote()
            }
            Section("Archive Editor & Workbench") {
                Toggle("Show 'Info' Button in SZS Toolbar", isOn: $showArchiveInfoButton)
                    .help("Toggles the 'i' button that explains expected archive structures.")

                Toggle("Show Platform Tags (e.g. [Wii], [GCN])", isOn: $showPlatformTags)
                    .help("Toggles the retro monospaced platform tags in the info popover's game picker.")

                Toggle("Compress New Archives (Yaz0) by Default", isOn: $defaultYaz0Compression)
                    .help("When creating a new SZS archive, automatically check the Yaz0 Compress toggle.")

                Toggle("Open Archives in New Window", isOn: $openArchivesInNewWindow)
                    .help("If enabled, double-clicking an archive in the Project Navigator will spawn a dedicated window instead of opening it as a tab.")

                Toggle("Auto-Collapse Console on Launch", isOn: $autoCollapseConsole)
                    .help("If enabled, the Workbench console panel will start completely collapsed.")

                Toggle("Dragging Files Should Copy", isOn: $dragFilesShouldCopy)
                    .help("If enabled, dragging a file onto a folder/archive in the Project Navigator (or out of one) copies it instead of moving it. Off by default, matching Finder: drags within the project move, drags from outside it copy, and holding Option flips either.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Which per-game tool submenus appear in the Workbench's menus (see `GameTools`).
private struct GamesSettingsTab: View {
    @AppStorage(GameTools.marioKartWii.defaultsKey) private var marioKartWiiEnabled = true
    @AppStorage(GameTools.nsmbw.defaultsKey) private var nsmbwEnabled = true
    @AppStorage(GameTools.marioKartDoubleDash.defaultsKey) private var doubleDashEnabled = true
    @AppStorage(BuildCompatibility.defaultsKey) private var buildCompatibility = BuildCompatibility.hardware.rawValue

    var body: some View {
        Form {
            Section("Course Models & Collision") {
                Picker("Build for", selection: $buildCompatibility) {
                    Text("Hardware-compatible").tag(BuildCompatibility.hardware.rawValue)
                    Text("Dolphin-compatible").tag(BuildCompatibility.dolphin.rawValue)
                }
                .pickerStyle(.radioGroup)
                Text(buildCompatibility == BuildCompatibility.hardware.rawValue
                     ? "Models from .obj/.dae are built the way RiiStudio's importer builds them (triangle strips, mipmapped textures), and collision exactly as Wiimm's wkclt builds it, the encoder Blender MKW Utilities uses. Use this for courses that will run on a real Wii."
                     : "This app's own quicker encoders: smaller collision, faster builds, no mipmaps. Fine for testing in Dolphin.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Game-Specific Tools") {
                Text("Commands that only apply to one game are grouped into their own submenu instead of sitting alongside the generic Wii/GCN ones. Switch a game off to hide its submenu everywhere.")
                    .settingsNote()

                gameToggle(GameTools.marioKartWii, isOn: $marioKartWiiEnabled)
                gameToggle(GameTools.marioKartDoubleDash, isOn: $doubleDashEnabled, badge: ("Beta", .blue))
                gameToggle(GameTools.nsmbw, isOn: $nsmbwEnabled, badge: ("Pre-Alpha", .orange),
                           note: " Early and rough, expect missing features and bugs.")
            }
            Section("Base Games") {
                Text("Link your own disc images. Mario Kart Wii: missing object models and effects are copied in from it, and its tracks fill the Texture Gallery and skybox picker (the common key comes from Settings > Keys, or a key.bin beside the disc). Double Dash: each slot's minimap position is read from it, its textures fill the Texture Gallery, and Hot Swap patches racers and karts into it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                discRow("Mario Kart Wii", name: baseGameName, types: ["iso", "wbfs"], link: { BaseGameLibrary.link($0); baseGameName = $0.lastPathComponent; SkyboxLibrary.shared.refresh() },
                        unlink: { BaseGameLibrary.unlink(); baseGameName = nil; SkyboxLibrary.shared.refresh() })
                discRow("Mario Kart: Double Dash!!", name: doubleDashName, types: ["iso", "gcm"], link: { DoubleDashDisc.link($0); doubleDashName = $0.lastPathComponent },
                        unlink: { DoubleDashDisc.unlink(); doubleDashName = nil })
            }
        }
        .formStyle(.grouped)
        .onAppear {
            baseGameName = BaseGameLibrary.linkedISO?.lastPathComponent
            doubleDashName = DoubleDashDisc.linkedISO?.lastPathComponent
        }
    }

    /// A game's toggle: the status pill sits right after the title, ahead of the switch.
    private func gameToggle(_ game: GameTools, isOn: Binding<Bool>, badge: (String, Color)? = nil, note: String = "") -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: isOn) {
                HStack(spacing: 6) {
                    Text(game.displayName)
                    if let badge {
                        Text(badge.0).font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(badge.1.opacity(0.2), in: Capsule())
                            .foregroundStyle(badge.1)
                    }
                }
            }
            .help(game.summary)
            Text(game.summary + note).font(.caption).foregroundStyle(.secondary)
        }
    }

    @State private var baseGameName: String?
    @State private var doubleDashName: String?

    private func discRow(_ game: String, name: String?, types: [String], link: @escaping (URL) -> Void, unlink: @escaping () -> Void) -> some View {
        StatusRow(title: game, detail: name, placeholder: "Not linked") {
            Button("Choose...") {
                PanelPresenter.openFile(configure: {
                    $0.allowedContentTypes = types.compactMap { UTType(filenameExtension: $0) }
                    $0.allowsOtherFileTypes = true
                }) { url in if let url { link(url) } }
            }
            if name != nil { Button("Unlink", action: unlink) }
        }
    }
}

/// Fonts, spacing, behaviour and colours of the built-in code editor.
private struct CodeEditorSettingsTab: View {
    @ObservedObject private var prefs = CodeEditorPrefs.shared

    private static let sample = """
    // Draw the score
    func draw(score: Int) {
    \tlet label = "Score: \\(score)"
    \tif score > 100 { print(label) }
    }
    """

    private var preview: AttributedString {
        let font = prefs.font
        let text = NSMutableAttributedString(attributedString: SyntaxHighlighter.highlight(Self.sample, language: .swift, font: font))
        let style = NSMutableParagraphStyle()
        style.lineSpacing = prefs.lineSpacing
        style.defaultTabInterval = (String(repeating: " ", count: prefs.tabWidth) as NSString).size(withAttributes: [.font: font]).width
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
        return (try? AttributedString(text, including: \.appKit)) ?? AttributedString(Self.sample)
    }

    var body: some View {
        Form {
            Section {
                Text(preview).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .background(prefs.backgroundColor, in: RoundedRectangle(cornerRadius: 8))
                    .listRowInsets(EdgeInsets())
            }
            Section("Font") {
                Picker("Font", selection: $prefs.fontName) {
                    Text("System Monospaced").tag("")
                    ForEach(CodeEditorPrefs.monospacedFonts, id: \.self) { Text($0).tag($0) }
                }
                Stepper("Size: \(Int(prefs.fontSize)) pt", value: $prefs.fontSize, in: 8...36)
                LabeledContent("Line spacing") {
                    HStack { Slider(value: $prefs.lineSpacing, in: 0...12, step: 0.5); Text("\(prefs.lineSpacing, specifier: "%.1f")").monospacedDigit().frame(width: 30) }
                }
            }
            Section("Indentation") {
                Stepper("Tab width: \(prefs.tabWidth)", value: $prefs.tabWidth, in: 2...8)
                Toggle("Insert spaces instead of tabs", isOn: $prefs.insertSpaces)
                Toggle("Auto-indent new lines", isOn: $prefs.autoIndent)
            }
            Section("Editing") {
                Toggle("Close brackets and quotes automatically", isOn: $prefs.autoClosePairs)
                Toggle("Suggest completions while typing", isOn: $prefs.autoComplete)
                Toggle("Wrap long lines", isOn: $prefs.wordWrap)
            }
            Section("Display") {
                Toggle("Line numbers", isOn: $prefs.showLineNumbers)
                Toggle("Code folding", isOn: $prefs.codeFolding)
                Toggle("Minimap", isOn: $prefs.showMinimap)
                Toggle("Status bar", isOn: $prefs.showStatusBar)
                Toggle("Highlight the current line", isOn: $prefs.highlightCurrentLine)
                Toggle("Highlight matching brackets", isOn: $prefs.matchBrackets)
            }
            Section {
                Picker("Theme", selection: $prefs.theme) {
                    ForEach(CodeTheme.presetNames, id: \.self) { Text($0).tag($0) }
                }
                ColorPicker("Background", selection: Binding(get: { prefs.backgroundColor }, set: { prefs.setBackground($0) }), supportsOpacity: false)
                ForEach(CodeRole.allCases) { role in
                    ColorPicker(role.title, selection: Binding(get: { prefs.color(role) }, set: { prefs.setColor(role, $0) }), supportsOpacity: false)
                }
                Button("Reset Colours to Theme") { prefs.resetColors() }
            } header: {
                Text("Colours")
            } footer: {
                Text("Pick a theme, then change any colour. Resetting returns every colour to the theme's own.").settingsNote()
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Controls

/// Settings > Controls: every keyboard shortcut and mouse-modifier control, rebindable.
private struct ControlsSettingsTab: View {
    @ObservedObject private var controls = Controls.shared
    @State private var recording: ControlAction?
    @State private var monitor: Any?

    private static let modifierChoices: [(String, UInt)] = {
        let s = ControlBinding.shift, c = ControlBinding.control, o = ControlBinding.option, m = ControlBinding.command
        return [("None", 0), ("\u{21E7} Shift", s), ("\u{2325} Option", o), ("\u{2318} Command", m), ("\u{2303} Control", c),
                ("\u{21E7}\u{2325} Shift + Option", s | o), ("\u{21E7}\u{2318} Shift + Command", s | m),
                ("\u{2325}\u{2318} Option + Command", o | m), ("\u{2303}\u{21E7} Control + Shift", c | s)]
    }()

    var body: some View {
        Form {
            ForEach(["File and Windows", "Editors", "Course Data Editor (2D) Mouse", "3D Track Editor Keys", "3D Track Editor Mouse"], id: \.self) { group in
                Section(group) {
                    ForEach(ControlAction.allCases.filter { $0.group == group }) { row($0) }
                }
            }
            Section {
                Button("Reset All to Defaults") { stopRecording(); controls.resetAll() }
                Text("Drag controls take the modifier keys held with the mouse. \"None\" means the plain drag; two controls for the same target swap if you give them the same modifier. Middle-drag always pans in the 2D editor.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onDisappear { stopRecording() }
    }

    @ViewBuilder private func row(_ a: ControlAction) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(a.title)
                let clash = controls.clashes(a)
                if !clash.isEmpty {
                    Text("Also used by \(clash.map(\.title).joined(separator: ", "))").font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer()
            if a.kind == .modifier {
                Picker("", selection: Binding(get: { controls.binding(a).mods }, set: { controls.set(.init(key: "", mods: $0), for: a) })) {
                    ForEach(Self.modifierChoices, id: \.1) { Text($0.0).tag($0.1) }
                }
                .labelsHidden().fixedSize()
            } else {
                Button(recording == a ? "Press a key..." : controls.binding(a).display) { recording == a ? stopRecording() : startRecording(a) }
                    .frame(minWidth: 110)
                    .buttonStyle(.bordered)
                    .tint(recording == a ? .accentColor : nil)
            }
            Button { controls.reset(a) } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.borderless).disabled(!controls.isCustom(a)).help("Back to the default")
        }
    }

    private func startRecording(_ a: ControlAction) {
        stopRecording()
        recording = a
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let b = ControlBinding.from(event) else { return event }
            controls.set(b, for: a)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; recording = nil
    }
}
