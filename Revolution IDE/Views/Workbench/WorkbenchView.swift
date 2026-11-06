import SwiftUI

/// The primary window: an Xcode-like shell with a project navigator, a tab strip over a
/// multi-format editor area, and a log console. Disc scrubbing lives in its own window (see
/// `DiscScrubberWindowView`), opened from the toolbar/menu here.
struct WorkbenchView: View {
    @EnvironmentObject var workbench: WorkbenchState
    @Environment(\.openWindow) private var openWindow
    @State private var showSourceControl = false
    @State private var showRunSheet = false

    @AppStorage("showWorkbenchConsole") private var showConsole = true

    @ViewBuilder private var busyOverlay: some View {
        if let message = workbench.busyMessage {
            ZStack {
                Color.black.opacity(0.25).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 10) {
                    Text(message).font(.headline)
                    ProgressView().progressViewStyle(.linear)
                    Text("This can take a minute on a big track.").font(.caption).foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(width: 360)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .shadow(radius: 20)
            }
            .contentShape(Rectangle())
        }
    }

    var body: some View {
        NavigationSplitView {
            ProjectNavigatorView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 480)
        } detail: {
            VStack(spacing: 0) {
                tabStrip
                Divider()
                if showConsole {
                    VSplitView {
                        editorArea
                            .frame(minHeight: 300)
                        bottomPanel
                            .frame(minHeight: 80, idealHeight: 90)
                    }
                } else {
                    editorArea
                }
            }
        }
        .toolbar { toolbarContent }
        .onAppear { WindowRouter.openWorkbench = { openWindow(id: "workbench") } }
        .overlay {
            if let outcome = workbench.buildOutcome {
                BuildHUD(success: outcome.success)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                    .task(id: outcome.id) {
                        try? await Task.sleep(for: .seconds(outcome.success ? 1.8 : 3))
                        withAnimation(.easeOut(duration: 0.25)) { workbench.buildOutcome = nil }
                    }
            }
        }
        .animation(.spring(duration: 0.3), value: workbench.buildOutcome?.id)
        // An overlay rather than a sheet, so an error alert right after it can't collide with
        // the sheet's dismissal.
        .overlay { busyOverlay }
        .sheet(isPresented: $showSourceControl) {
            SourceControlView(git: workbench.git, projectURL: currentProjectURL)
        }
        .sheet(isPresented: $showRunSheet) {
            RunInEmulatorView(emulator: workbench.emulator)
        }
        .modifier(HotSwapPreflightPresenter(emulator: workbench.emulator))
        .sheet(isPresented: $workbench.showHomebrewInfo) {
            if let root = workbench.projectRoot { HomebrewInfoSheet(project: root.url) }
        }
        .sheet(isPresented: $workbench.showNewHomebrew) {
            NewHomebrewSheet().environmentObject(workbench)
        }
        .sheet(isPresented: $workbench.showAboutSheet) {
            AboutView()
        }
        .sheet(item: $workbench.skyboxPicker) { SkyboxFromGameSheet(request: $0).environmentObject(workbench) }
        .sheet(item: $workbench.newDoubleDashCourse) { NewDoubleDashCourseSheet(request: $0).environmentObject(workbench) }
        .alert("Error", isPresented: Binding(get: { workbench.errorMessage != nil }, set: { if !$0 { workbench.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(workbench.errorMessage ?? "") }
        .onChange(of: workbench.pendingSZSWindowID) { _, id in
            guard let id else { return }
            openWindow(id: "szsWindow", value: id)
            workbench.pendingSZSWindowID = nil
        }
        .onChange(of: workbench.pendingNSMBWWindowID) { _, id in
            guard let id else { return }
            openWindow(id: "nsmbwWindow", value: id)
            workbench.pendingNSMBWWindowID = nil
        }
        .onChange(of: workbench.pendingTrackPreviewWindowID) { _, id in
            guard let id else { return }
            openWindow(id: "trackPreviewWindow", value: id)
            workbench.pendingTrackPreviewWindowID = nil
        }
    }

    private var currentProjectURL: URL? {
        switch workbench.project {
        case .folder(let root): return root.url
        case .discImage(let url, _): return url.deletingLastPathComponent()
        case nil: return nil
        }
    }

    // MARK: Tab strip

    private var bottomPanel: some View {
        WorkbenchLogPanelView()
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(workbench.tabs) { tab in
                    TabStripButton(tab: tab)
                }
            }
        }
        .frame(height: 32)
        .clipped()
        .background(.bar)
    }

    // MARK: Editor area

    @ViewBuilder
    private var editorArea: some View {
        if let tab = workbench.selectedTab {
            // `.id(tab.id)` forces a fresh view (and fresh @State, zoom/pan/selection/etc.)
            // whenever the selected tab changes, instead of SwiftUI reusing the previous tab's
            // view identity and leaking its editor state into the newly-selected tab.
            Group {
                switch tab.payload {
                case .kmp(let box): KMPEditorView(box: box, source: tab.source)
                case .brres(let box): BRRESEditorView(box: box)
                case .bmg(let box): BMGEditorView(box: box)
                case .tpl(let box): TPLEditorView(box: box)
                case .kcl(let box): KCLEditorView(box: box)
                case .szs(let box): SZSArchiveView(box: box)
                case .nsmbwLevel(let box): NSMBWLevelView(box: box)
                case .brstm(let box): BRSTMEditorView(box: box)
                case .brlyt(let box): BRLYTEditorView(box: box)
                case .brlan(let box): BRLANEditorView(doc: box.doc)
                case .brsar(let box): BRSAREditorView(doc: box.doc)
                case .j3d(let box): J3DEditorView(box: box)
                case .j3dAnimation(let box): J3DAnimationView(box: box)
                case .code(let box):
                    if case .file(let url) = tab.source { CodeEditorView(box: box, fileURL: url) } else { CodeEditorView(box: box) }
                case .raw(let box): RawEditorView(box: box, title: tab.title)
                case .obj(let box): OBJEditorView(box: box)
                case .mtl(let box): MTLEditorView(box: box)
                case .uiDesign(let box): UIDesignerView(box: box)
                case .nodeGraph(let box): NodeEditorView(box: box)
                case .image(let box): ImageEditorView(box: box)
                case .fields(let box): BinaryFieldsEditorView(box: box)
                case .effect(let box): EffectEditorView(box: box)
                case .loading:
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading \(tab.title)...").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .id(tab.id)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "shippingbox").font(.system(size: 48)).foregroundStyle(.tertiary)
                Text("Open a .szs, .kmp, .brres, or .kcl file to start editing. Right-click a .szs archive to open it in its own window instead of a tab. Use the File menu for more ways to open or create a file.").foregroundStyle(.secondary)
                HStack {
                    Button("Open Wii/GCN Disc Image as Project...") { openDisc() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            Button { save() } label: { Label("Save", systemImage: "square.and.arrow.down") }
                .disabled(workbench.selectedTab?.isLoading ?? true)
                .help("Save the current tab. The dot on a tab means it has unsaved changes.")
        }
        ToolbarItem {
            Button { showSourceControl = true } label: { Label("Source Control", systemImage: "arrow.triangle.branch") }
                .overlay(alignment: .topTrailing) {
                    if workbench.git.isRepo, !workbench.git.entries.isEmpty {
                        Circle().fill(.orange).frame(width: 7, height: 7).offset(x: 2, y: -2)
                    }
                }
                .help("Git version control for this project, track changes, commit, and push/pull. Optional; you don't need Git to mod. The orange dot means there are uncommitted changes.")
        }
        ToolbarItem {
            Button { openWindow(id: "discScrubber") } label: { Label("Disc Scrubber", systemImage: "opticaldiscdrive") }
                .help("Opens the standalone disc tool for browsing Wii/GCN disc images, extracting or replacing files directly inside them, cleaning/shrinking Wii ISOs, and managing encryption keys, separate from this project workbench.")
        }
        ToolbarItem {
            Button { openWindow(id: "crashLogs") } label: { Label("Review Crash Logs", systemImage: "ladybug") }
                .help("Reads Dolphin's log for the last crash and explains what went wrong, or shows the crash section.")
        }
        if #available(macOS 26.0, *) { ToolbarSpacer(.fixed) }
        if workbench.isHomebrewProject {
            // Build, Run and Force Stop sit together in one capsule; the Console button is in another.
            ToolbarItem {
                HStack(spacing: 2) {
                    ToolbarSplitButton(title: "Build", icon: "hammer.fill",
                                       help: "Builds this Wii homebrew project with devkitPro (without running it). The arrow cleans, installs to Dolphin's SD card, or edits the Homebrew Channel info.",
                                       action: { workbench.buildHomebrew() }) {
                        Button("Clean") { workbench.buildHomebrew(clean: true) }
                        Divider()
                        Button("Install to Dolphin SD Card") { workbench.installToDolphinSD() }
                        Button("Homebrew Channel Info...") { workbench.showHomebrewInfo = true }
                    }
                    .disabled(workbench.homebrew.isBuilding)
                    ToolbarSplitButton(title: "Run", icon: "play.fill",
                                       help: "Builds this Wii homebrew project and runs it in Dolphin. The arrow runs it through the Homebrew Channel instead.",
                                       action: { workbench.buildHomebrew(thenRun: true) }) {
                        Button("Run via Homebrew Channel") { workbench.buildHomebrew(viaChannel: true) }
                            .help("Builds, installs the app on Dolphin's SD card folder and boots the Homebrew Channel from Dolphin's Wii menu NAND (install the channel's WAD in Dolphin first).")
                    }
                    .disabled(workbench.homebrew.isBuilding)
                    ForceStopButton(emulator: workbench.emulator)
                }
                .modifier(ToolbarCapsule())
            }
            .detached()
            if #available(macOS 26.0, *) { ToolbarSpacer(.fixed) }
            ToolbarItem {
                HStack(spacing: 2) {
                    Button { showConsole.toggle() } label: { Label("Console", systemImage: "terminal") }
                        .help("Show or hide the log console.")
                }
                .modifier(ToolbarCapsule())
            }
            .detached()
        } else {
            ToolbarItem {
                HStack(spacing: 2) {
                    ToolbarSplitButton(title: "Run", icon: "play.fill",
                                       help: hasHotSwapMarks
                                        ? "You have file(s) marked for Hot Swap, clicking Run launches them straight onto your chosen base disc. The arrow offers Standard Boot instead."
                                        : "Test your mod by launching it in Dolphin, a separate emulator you install yourself. Works with a disc image, an extracted folder, a WAD, or, for a loose mod folder. \"Hot Swap\" onto a real disc without building an ISO.",
                                       action: { primaryRunAction() }) {
                        Button("Hot Swap") { launchHotSwap() }
                        Button("Standard Boot") { showRunSheet = true }
                    }
                    .overlay(alignment: .topTrailing) {
                        if hasHotSwapMarks {
                            Image(systemName: "bolt.fill").font(.system(size: 9)).foregroundStyle(.yellow).offset(x: 3, y: -3)
                        }
                    }
                    ForceStopButton(emulator: workbench.emulator)
                }
                .modifier(ToolbarCapsule())
            }
            .detached()
            ToolbarItem {
                Button { showConsole.toggle() } label: { Label("Console", systemImage: "terminal") }
                    .help("Show or hide the log console.")
            }
        }
    }

    /// Whether the current folder project has at least one file marked for Hot Swap (see
    /// `HotSwapMarks`/`ProjectNavigatorView`'s "Mark for Hot Swap" context menu item), drives the
    /// Run button's lightning-bolt badge and its click-through-to-Hot-Swap shortcut below.
    private var hasHotSwapMarks: Bool {
        guard case .folder(let root) = workbench.project else { return false }
        return !HotSwapMarks.marked(forProject: root.url).isEmpty
    }

    /// The Run button's plain click: launches Hot Swap directly (skipping the Run sheet entirely)
    /// when there's something marked and a base disc was already chosen for this project; otherwise
    /// falls back to the sheet exactly like before, since there's nothing to launch straight to yet.
    private func primaryRunAction() {
        guard case .folder(let root) = workbench.project,
              !HotSwapMarks.marked(forProject: root.url).isEmpty,
              let baseISO = RunInEmulatorView.rememberedHotSwapBaseISO(forProject: root.url) else {
            showRunSheet = true
            return
        }
        workbench.emulator.requestHotSwap(baseISO: baseISO, modRoot: root.url)
    }

    /// The right-click menu's explicit "Hot Swap", same direct launch `primaryRunAction()` does
    /// when eligible; if no base disc has been chosen yet, opens the Run sheet instead (on its Hot
    /// Swap tab is a manual click away there) rather than silently doing nothing.
    private func launchHotSwap() {
        guard case .folder(let root) = workbench.project,
              let baseISO = RunInEmulatorView.rememberedHotSwapBaseISO(forProject: root.url) else {
            showRunSheet = true
            return
        }
        workbench.emulator.requestHotSwap(baseISO: baseISO, modRoot: root.url)
    }

    private func openDisc() {
        PanelPresenter.openFile(configure: { $0.allowsOtherFileTypes = true }) { url in
            guard let url else { return }
            workbench.openDiscAsProject(url: url)
        }
    }

    private func save() { workbench.saveSelected() }
}

/// One tab in the strip. `EditorTab` is itself an `ObservableObject`, but `tab.isDirty` only
/// actually reads a `@Published` property on whichever document *box* the tab wraps, a nested
/// object one level down. A plain function parameter (or `let tab: EditorTab`) doesn't subscribe
/// to that nested box's own `objectWillChange`, so the dirty dot would only ever update by
/// coincidence, the same reactivity gap already fixed for `SZSWindowView`/`NSMBWWindowView`. Using
/// `@ObservedObject` here means SwiftUI actually re-renders this row when an edit happens.
private struct TabStripButton: View {
    @EnvironmentObject var workbench: WorkbenchState
    @ObservedObject var tab: EditorTab

    var body: some View {
        HStack(spacing: 6) {
            if tab.isLoading {
                ProgressView().controlSize(.small).frame(width: 14, height: 14)
            } else {
                Image(systemName: tab.iconName)
            }
            Text(tab.title).lineLimit(1)
            if tab.isDirty { Circle().fill(.secondary).frame(width: 6, height: 6) }
            Button { workbench.closeTab(tab) } label: {
                Image(systemName: "xmark").font(.system(size: 9))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(workbench.selectedTabID == tab.id ? Color.accentColor.opacity(0.18) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { workbench.selectedTabID = tab.id }
        Divider()
    }
}

/// The "Build Succeeded" / "Build Failed" popup, centred over the window like Xcode's.
private struct BuildHUD: View {
    let success: Bool
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .font(.system(size: 54)).foregroundStyle(success ? Color.green : Color.red)
                .symbolRenderingMode(.hierarchical)
            Text(success ? "Build Succeeded" : "Build Failed").font(.title3.weight(.semibold))
            if !success { Text("See the console for details.").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 36).padding(.vertical, 28)
        .frame(minWidth: 220)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

/// Shown next to Run while a Dolphin this app started is open: ends it immediately.
private struct ForceStopButton: View {
    @ObservedObject var emulator: EmulatorLauncher
    var body: some View {
        if emulator.isActive {
            Button { emulator.forceStop() } label: { Label("Force Stop", systemImage: "stop.fill") }
                .tint(.red)
                .help("Force quit Dolphin.")
        }
    }
}

/// A toolbar button with a small menu arrow in its bottom-right corner.
private struct ToolbarSplitButton<MenuContent: View>: View {
    let title: String
    let icon: String
    let help: String
    let action: () -> Void
    @ViewBuilder let menu: () -> MenuContent

    var body: some View {
        Button(action: action) { Label(title, systemImage: icon).labelStyle(.iconOnly) }
            .overlay(alignment: .bottomTrailing) {
                Menu { menu() } label: { Image(systemName: "chevron.down").font(.system(size: 10, weight: .heavy)).frame(width: 13, height: 13) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .padding(.trailing, 1).padding(.bottom, 4)
            }
            .help(help)
    }
}

/// Gives a group of toolbar buttons its own capsule, apart from the buttons next to it.
private struct ToolbarCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.padding(.horizontal, 6).glassEffect(.regular, in: .capsule)
        } else {
            content
        }
    }
}

private extension ToolbarContent {
    /// Stops macOS merging this item's background with its neighbours'.
    @ToolbarContentBuilder func detached() -> some ToolbarContent {
        if #available(macOS 26.0, *) { self.sharedBackgroundVisibility(.hidden) } else { self }
    }
}
