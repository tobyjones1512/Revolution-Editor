import SwiftUI
import UniformTypeIdentifiers

/// "Run" sheet: picks what to hand to Dolphin (see `EmulatorLauncher`'s doc comment for why it's
/// Dolphin, and why that's named plainly), the currently-open disc image, a disk-mode or
/// WAD-mode choice when the project is a folder, or any file/folder browsed for manually, then
/// shows its live console output.
struct RunInEmulatorView: View {
    @EnvironmentObject var workbench: WorkbenchState
    @Environment(\.dismiss) var dismiss
    @ObservedObject var emulator: EmulatorLauncher

    private enum Mode: String, CaseIterable, Identifiable { case disk = "Disk", wad = "WAD", hotSwap = "Hot Swap"; var id: String { rawValue } }

    @State private var mode: Mode = .disk
    @State private var chosenWAD: URL?
    @State private var manualPath: URL?
    @State private var hotSwapBaseISO: URL?
    @State private var hotSwapFiles: [String] = []
    @State private var hotSwapFilesRoot: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            sourcePicker
            Divider()
            console
            Divider()
            footer
        }
        .padding()
        .frame(width: 640, height: 480)
        .onAppear {
            if case .discImage = workbench.project { /* nothing to preselect */ }
            if wadCandidates.isEmpty { mode = .disk }
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "gamecontroller.fill")
            Text("Run").font(.headline)
            Spacer()
            if emulator.dolphinAppURL == nil {
                Text("Dolphin not found").font(.caption).foregroundStyle(.red)
            }
            Button("Locate Dolphin...") { locateDolphin() }
                .help("Point this at your installed Dolphin.app if it wasn't found automatically. Dolphin is a separate, free Wii/GameCube emulator, get it from dolphin-emu.org if you don't have it yet.")
            Button("Controller / Wii Remote Settings...") { emulator.openDolphinSettings() }
                .disabled(emulator.dolphinAppURL == nil)
                .help("Opens Dolphin's own settings to configure a keyboard/gamepad as your Wii Remote/GameCube controller before launching.")
        }
    }

    // MARK: Source picker

    @ViewBuilder
    private var sourcePicker: some View {
        switch workbench.project {
        case .discImage(let url, _):
            HStack {
                Label(url.lastPathComponent, systemImage: "opticaldiscdrive")
                Spacer()
                launchButton(path: url)
            }
        case .folder(let root):
            folderProjectPicker(root: root)
        case nil:
            HStack {
                Text(manualPath?.lastPathComponent ?? "No project open, browse for a file to run.")
                    .foregroundStyle(manualPath == nil ? .secondary : .primary)
                Spacer()
                Button("Browse...") { browseManually() }
                if let manualPath { launchButton(path: manualPath) }
            }
        }
    }

    @ViewBuilder
    private func folderProjectPicker(root: ProjectNode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let looksLikeDisk = FileManager.default.fileExists(atPath: root.url.appendingPathComponent("sys/boot.bin").path)
            let wads = wadCandidates

            Picker("Mode", selection: $mode) {
                if looksLikeDisk { Text("Disk (folder)").tag(Mode.disk) }
                if !wads.isEmpty { Text("WAD").tag(Mode.wad) }
                Text("Hot Swap").tag(Mode.hotSwap)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)
            .help("Disk: run this folder directly as an extracted disc. WAD: run a channel/WAD file found in the project. Hot Swap: keep your files as a loose folder and have Dolphin swap them into a real disc image live at boot, no ISO rebuild needed.")

            switch mode {
            case .disk:
                if looksLikeDisk {
                    HStack {
                        Label(root.name, systemImage: "opticaldiscdrive")
                        Spacer()
                        launchButton(path: root.url)
                    }
                } else {
                    Text("This project folder doesn't look like an extracted disc (no sys/boot.bin).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .wad:
                if wads.isEmpty {
                    Text("No .wad file found in this project.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("WAD", selection: $chosenWAD) {
                        ForEach(wads, id: \.self) { url in Text(url.lastPathComponent).tag(Optional(url)) }
                    }
                    HStack {
                        Spacer()
                        launchButton(path: chosenWAD ?? wads[0])
                    }
                }
            case .hotSwap:
                hotSwapPicker(root: root)
            }

            HStack {
                Text("Or:").font(.caption).foregroundStyle(.secondary)
                Button("Browse for a File...") { browseManually() }
                if let manualPath { launchButton(path: manualPath) }
            }
        }
        .onAppear { hotSwapBaseISO = Self.rememberedHotSwapBaseISO(forProject: root.url) }
    }

    /// Boots a real Wii disc image with every file the user has marked (Project Navigator ->
    /// right-click a file -> "Mark for Hot Swap") swapped in live at boot time, Riivolution-style
    /// (see `EmulatorLauncher.runHotSwap`), the project never has to become a full rebuilt ISO.
    /// Requires a legitimately-owned base disc image the user points at once (remembered per
    /// project via `UserDefaults`); this app never bundles or downloads one.
    @ViewBuilder
    private func hotSwapPicker(root: ProjectNode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("""
            Boots a real Wii disc image with every file you've marked for Hot Swap (right-click a \
            file in the Project Navigator -> "Mark for Hot Swap") swapped in on the fly, \
            Riivolution-style: your project stays a loose folder, never a rebuilt ISO. Dolphin \
            applies the swap itself at boot; the disc image on disk is never modified.
            """)
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack {
                Image(systemName: hotSwapBaseISO != nil ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(hotSwapBaseISO != nil ? .green : .secondary)
                Text(hotSwapBaseISO?.lastPathComponent ?? "No base disc image chosen")
                    .foregroundStyle(hotSwapBaseISO == nil ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose Base Disc...") { chooseHotSwapBaseISO(forProject: root.url) }
            }

            hotSwapFileList

            HStack {
                Spacer()
                Button {
                    guard let hotSwapBaseISO else { return }
                    dismiss()
                    emulator.requestHotSwap(baseISO: hotSwapBaseISO, modRoot: root.url)
                } label: {
                    Label(emulator.isActive ? "Restart (Hot Swap)" : "Launch (Hot Swap)", systemImage: "play.fill")
                }
                .disabled(emulator.dolphinAppURL == nil || hotSwapBaseISO == nil || hotSwapFiles.isEmpty)
            }
        }
        .task(id: root.url) { await loadHotSwapFiles(root: root.url) }
    }

    /// Lists exactly which marked files Hot Swap is about to overlay onto the base disc, before
    /// the user commits to booting, computed the same way `EmulatorLauncher.filesToSwap` does
    /// (marked files intersected with what's still really on disk), so what's shown here matches
    /// what Dolphin will actually receive.
    @ViewBuilder
    private var hotSwapFileList: some View {
        if hotSwapFiles.isEmpty {
            Text("Nothing marked for Hot Swap yet, right-click a file in the Project Navigator and choose \"Mark for Hot Swap\".")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            DisclosureGroup("Will replace \(hotSwapFiles.count) file\(hotSwapFiles.count == 1 ? "" : "s") on the base disc:") {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(hotSwapFiles.prefix(500), id: \.self) { path in
                            Text(path).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                        }
                        if hotSwapFiles.count > 500 {
                            Text("... and \(hotSwapFiles.count - 500) more").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .background(Color(nsColor: .textBackgroundColor))
            }
            .font(.caption)
        }
    }

    private func loadHotSwapFiles(root: URL) async {
        guard hotSwapFilesRoot != root else { return }
        hotSwapFilesRoot = root
        let files = await Task.detached(priority: .userInitiated) {
            // Each with what it replaces when it has a chosen target.
            EmulatorLauncher.filesToSwap(modRoot: root).map { path in
                var dir: ObjCBool = false
                let isFolder = FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path, isDirectory: &dir) && dir.boolValue
                let shown = isFolder ? "\(path)/ (packed as \(HotSwapFolderModes.mode(for: path, project: root).title))" : path
                return HotSwapTargetMarks.target(for: path, project: root).map { "\(shown) \u{2192} \($0.path.joined(separator: " > ")) (\(HotSwapTargets.discFiles($0).joined(separator: ", ")))" } ?? shown
            }
        }.value
        guard hotSwapFilesRoot == root else { return }
        hotSwapFiles = files
    }

    /// This app is sandboxed (`com.apple.security.files.user-selected.read-write`), which only
    /// grants read access to a user-picked file for as long as the process that picked it keeps
    /// running, a plain remembered path silently loses that access on the next launch (reads
    /// then fail, which is what made `readGameID` report "not a valid Wii disc image" on a disc
    /// that was fine before). A security-scoped bookmark is what's actually meant to survive
    /// relaunches; `startAccessingSecurityScopedResource()` re-establishes access when resolved.
    private static func hotSwapBaseISOBookmarkKey(forProject projectURL: URL) -> String {
        "RunInEmulatorView.hotSwapBaseISO.bookmark.\(projectURL.path)"
    }

    /// Not `private`, `WorkbenchView`'s Run toolbar button also needs this, to launch Hot Swap
    /// directly (skipping this sheet entirely) when a base disc was already chosen previously.
    static func rememberedHotSwapBaseISO(forProject projectURL: URL) -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: hotSwapBaseISOBookmarkKey(forProject: projectURL)) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                                  relativeTo: nil, bookmarkDataIsStale: &isStale),
              url.startAccessingSecurityScopedResource() else { return nil }
        return url
    }

    private func chooseHotSwapBaseISO(forProject projectURL: URL) {
        PanelPresenter.openFile(configure: {
            $0.allowedContentTypes = ["iso", "wbfs"].compactMap { UTType(filenameExtension: $0) }
            $0.allowsOtherFileTypes = true
        }) { url in
            guard let url else { return }
            _ = url.startAccessingSecurityScopedResource()
            hotSwapBaseISO = url
            if let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(bookmark, forKey: Self.hotSwapBaseISOBookmarkKey(forProject: projectURL))
            }
        }
    }

    private var wadCandidates: [URL] {
        guard case .folder(let root) = workbench.project else { return [] }
        var out: [URL] = []
        func walk(_ node: ProjectNode) {
            guard out.count < 20 else { return }
            if !node.isDirectory, node.url.pathExtension.lowercased() == "wad" { out.append(node.url) }
            for c in node.children { walk(c) }
        }
        walk(root)
        return out
    }

    private func launchButton(path: URL) -> some View {
        Button {
            emulator.run(path: path)
        } label: {
            Label(emulator.isActive ? "Restart" : "Launch", systemImage: "play.fill")
        }
        .disabled(emulator.dolphinAppURL == nil)
    }

    private func browseManually() {
        PanelPresenter.openFile(configure: {
            $0.allowedContentTypes = ["iso", "wbfs", "wad", "gcm", "dol"].compactMap { UTType(filenameExtension: $0) }
            $0.allowsOtherFileTypes = true
            $0.canChooseDirectories = true
        }) { url in
            guard let url else { return }
            manualPath = url
        }
    }

    private func locateDolphin() {
        PanelPresenter.openFile(configure: {
            $0.allowedContentTypes = [.applicationBundle]
            $0.allowsOtherFileTypes = false
            $0.directoryURL = URL(fileURLWithPath: "/Applications")
        }) { url in
            guard let url else { return }
            emulator.rememberManuallyChosen(url)
        }
    }

    // MARK: Console

    private var console: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Console").font(.caption.bold())
                if emulator.isRunning {
                    ProgressView().controlSize(.small)
                    Button("Stop") { emulator.stop() }.font(.caption)
                } else if !emulator.capturedConsoleOutput, !emulator.logLines.isEmpty {
                    Text("(console output not captured, see log)").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if let code = emulator.lastExitCode {
                    Text("Exited (\(code))").font(.caption).foregroundStyle(code == 0 ? Color.secondary : Color.red)
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(emulator.logLines.enumerated()), id: \.offset) { i, line in
                            Text(line).font(.system(.caption2, design: .monospaced)).textSelection(.enabled).id(i)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: emulator.logLines.count) { _, _ in
                    proxy.scrollTo(emulator.logLines.count - 1, anchor: .bottom)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Text("Runs your build in Dolphin, a separate open-source Wii/GameCube emulator (GPLv2+), install it from dolphin-emu.org if it isn't found above.")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Button("Close") { dismiss() }
        }
    }
}

/// The marked files' problems, shown when Hot Swap's Play finds any (`HotSwapPreflight`): each
/// one says what's wrong, what it does in-game and how to fix it, with Auto Correct where the
/// fix is mechanical.
struct HotSwapPreflightSheet: View {
    let report: HotSwapPreflightReport
    let play: () -> Void
    let autoCorrect: ([HotSwapPreflight.Finding]) -> Void
    @Environment(\.dismiss) private var dismiss

    private var errors: [HotSwapPreflight.Finding] { report.findings.filter { $0.level == .error } }
    private var fixable: [HotSwapPreflight.Finding] { report.findings.filter { $0.fix != nil && $0.level != .suggestion } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !report.corrected.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Auto Correct fixed:", systemImage: "checkmark.circle.fill").font(.callout.bold()).foregroundStyle(.green)
                    ForEach(report.corrected, id: \.self) { Text("\u{2022} \($0)").font(.caption).fixedSize(horizontal: false, vertical: true) }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(HotSwapPreflight.Level.allCases, id: \.self) { level in
                        let items = report.findings.filter { $0.level == level }
                        if !items.isEmpty {
                            Text("\(level.title) (\(items.count))").font(.headline).foregroundStyle(color(level))
                            ForEach(items) { card($0) }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 280)
            HStack {
                Button("Copy Report") {
                    let text = report.findings.map { "[\($0.level.title.dropLast())] \($0.file): \($0.title). \($0.detail) \($0.howTo)" }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .help("Copy every finding as text, e.g. to ask for help.")
                Spacer()
                if fixable.count > 1 {
                    Button("Auto Correct All (\(fixable.count))") { dismiss(); autoCorrect(fixable) }
                        .help("Applies every available fix to the marked files, saves them, then checks again (and plays if nothing is left).")
                }
                if !errors.isEmpty {
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                } else {
                    Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Play Anyway") { dismiss(); play() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding()
        .frame(width: 640, height: 560)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: errors.isEmpty ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                .font(.system(size: 30)).foregroundStyle(errors.isEmpty ? .orange : .red)
            VStack(alignment: .leading, spacing: 4) {
                if errors.isEmpty {
                    Text("Ready to play, with a few things to look at").font(.title3.bold())
                    Text("Nothing below should crash the game.").font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("\(errors.count) problem\(errors.count == 1 ? "" : "s") would crash the game or stop it loading").font(.title3.bold())
                    Text(fixable.isEmpty
                         ? "Fix the errors below, then press Run again. (To play anyway, turn off Safeguards in Settings > Emulator.)"
                         : "Use Auto Correct where offered, fix the rest by hand, then press Run again. (To play anyway, turn off Safeguards in Settings > Emulator.)")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func card(_ f: HotSwapPreflight.Finding) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(f.level)).foregroundStyle(color(f.level)).font(.title3).frame(width: 22)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(f.title).font(.body.bold())
                    Text(f.file).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                }
                Text(f.detail).font(.callout).fixedSize(horizontal: false, vertical: true)
                if !f.howTo.isEmpty, f.howTo != f.detail {
                    (Text("How to fix: ").bold() + Text(f.howTo)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let fix = f.fix {
                    Button { dismiss(); autoCorrect([f]) } label: { Label("Auto Correct: \(fix.title)", systemImage: "wand.and.stars") }
                        .controlSize(.small)
                        .help("Changes the marked file for you, saves it, and checks again.")
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color(f.level).opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color(f.level).opacity(0.3)))
    }

    private func icon(_ l: HotSwapPreflight.Level) -> String {
        switch l { case .error: "xmark.octagon.fill"; case .warning: "exclamationmark.triangle.fill"; case .suggestion: "lightbulb.fill" }
    }
    private func color(_ l: HotSwapPreflight.Level) -> Color {
        switch l { case .error: .red; case .warning: .orange; case .suggestion: .yellow }
    }
}

/// Shows `HotSwapPreflightSheet` whenever the launcher has findings waiting.
struct HotSwapPreflightPresenter: ViewModifier {
    @ObservedObject var emulator: EmulatorLauncher
    func body(content: Content) -> some View {
        content
            .sheet(item: $emulator.hotSwapPreflight) { report in
                HotSwapPreflightSheet(report: report,
                                      play: { emulator.runHotSwap(baseISO: report.baseISO, modRoot: report.modRoot) },
                                      autoCorrect: { emulator.autoCorrect($0, in: report) })
            }
            .overlay(alignment: .top) {
                if emulator.checkingHotSwap {
                    Label("Preparing Hot Swap...", systemImage: "checklist").font(.caption)
                        .padding(8).background(.regularMaterial, in: Capsule()).padding(.top, 8)
                }
            }
    }
}
