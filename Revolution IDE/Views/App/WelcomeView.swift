import SwiftUI
import AppKit

/// The startup window: app identity, the three ways in (open, open a disc, new), and recent
/// projects. Opening anything hands over to the Workbench window and closes this one.
struct WelcomeView: View {
	@ObservedObject var workbench: WorkbenchState
	@Environment(\.openWindow) private var openWindow
	@Environment(\.dismissWindow) private var dismissWindow
	/// Opening things only hands over to the Workbench once the window has settled, tabs restored at launch must not skip Welcome.
	@State private var armed = false

	/// Projects first, then plain files not already listed.
	private var recents: [URL] {
		let fm = FileManager.default
		var seen = Set<URL>()
		return (workbench.recentProjectURLs + workbench.recentFileURLs)
			.filter { fm.fileExists(atPath: $0.path) && seen.insert($0).inserted }
	}

	private var version: String {
		let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
		return "Version \(v)"
	}

	var body: some View {
		VStack(spacing: 0) {
			identity.padding(.top, 36)
			actions.padding(.top, 20).padding(.horizontal, 20)
			recentList.padding(20)
		}
		.frame(width: 480, height: 640)
		.overlay(alignment: .topLeading) { closeButton.padding(14) }
		.background(.regularMaterial)
		.ignoresSafeArea()
		.background(WindowChrome())
		.onAppear { WindowRouter.openWorkbench = { openWindow(id: "workbench") } }
		.task {
			// A first launch goes through setup before anything else.
			if SetupWizardView.needed { openWindow(id: "setup"); dismissWindow(id: "welcome"); return }
			try? await Task.sleep(for: .seconds(1.5)); armed = true
		}
		.onChange(of: workbench.tabs.count) { _, _ in if armed { reveal() } }
		.onChange(of: workbench.project == nil) { _, _ in if armed { reveal() } }
		.onExitCommand { reveal() }
	}

	// MARK: Pieces

	private var closeButton: some View {
		Button { reveal() } label: {
			Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28)
		}
		.buttonStyle(.plain)
		.background(.quaternary, in: Circle())
		.help("Close and continue to the Workbench")
		.accessibilityLabel("Close")
	}

	private var identity: some View {
		VStack(spacing: 6) {
			Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 112, height: 112)
				.shadow(color: .black.opacity(0.25), radius: 8, y: 4)
			Text("Revolution Editor").font(.title2.bold()).padding(.top, 6)
			HStack(spacing: 6) {
				Text(version).font(.subheadline).foregroundStyle(.secondary)
				Text("Alpha").font(.caption2.bold())
					.padding(.horizontal, 6).padding(.vertical, 2)
					.background(.orange.opacity(0.2), in: Capsule())
					.foregroundStyle(.orange)
			}
		}
	}

	private var actions: some View {
		HStack(spacing: 8) {
			Button("Open\u{2026}") {
				PanelPresenter.openFile(configure: { $0.canChooseDirectories = true; $0.allowsOtherFileTypes = true }) { open($0) }
			}
			.frame(maxWidth: .infinity)
			Button("Open Disc\u{2026}") {
				PanelPresenter.openFile(configure: { $0.allowsOtherFileTypes = true }) { url in
					guard let url else { return }
					workbench.openDiscAsProject(url: url)
					reveal()
				}
			}
			.frame(maxWidth: .infinity)
			Menu("New") { NewFileMenuItems(workbench: workbench) }
				.frame(maxWidth: .infinity)
		}
		.buttonStyle(.bordered).controlSize(.large).buttonBorderShape(.capsule)
	}

	@ViewBuilder
	private var recentList: some View {
		if recents.isEmpty {
			ContentUnavailableView("No Recent Projects", systemImage: "clock", description: Text("Projects and files you open appear here."))
				.frame(maxHeight: .infinity)
		} else {
			ScrollView {
				LazyVStack(spacing: 0) {
					ForEach(recents, id: \.self) { url in RecentRow(url: url) { open(url) } }
				}
				.padding(6)
			}
			.background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
			.clipShape(RoundedRectangle(cornerRadius: 12))
		}
	}

	// MARK: Actions

	private func open(_ url: URL?) {
		guard let url else { return }
		if url.hasDirectoryPath { workbench.openFolder(url: url) }
		else if ["iso", "wbfs", "gcm"].contains(url.pathExtension.lowercased()) { workbench.openDiscAsProject(url: url) }
		else { workbench.openFile(url: url) }
		reveal()   // straight away: reopening what is already open changes no state to wait for
	}

	/// Shows the Workbench (creating its window if needed) and closes the Welcome window.
	private func reveal() {
		let existing = NSApp.windows.first { ($0.identifier?.rawValue ?? "").hasPrefix("workbench") }
		if let existing {
			if existing.isMiniaturized { existing.deminiaturize(nil) }
			existing.alphaValue = 1
			existing.makeKeyAndOrderFront(nil)
		} else { openWindow(id: "workbench") }
		NSApp.activate(ignoringOtherApps: true)
		dismissWindow(id: "welcome")
	}
}

/// Makes the window chrome-less: transparent title bar, no traffic lights (Welcome has its own close button).
private struct WindowChrome: NSViewRepresentable {
	func makeNSView(context: Context) -> NSView {
		let v = NSView()
		DispatchQueue.main.async {
			guard let w = v.window else { return }
			w.titlebarAppearsTransparent = true
			w.standardWindowButton(.zoomButton)?.isHidden = true
			w.standardWindowButton(.miniaturizeButton)?.isHidden = true
			w.standardWindowButton(.closeButton)?.isHidden = true
		}
		return v
	}
	func updateNSView(_ nsView: NSView, context: Context) {}
}

/// One recent project: a single click opens it, like Xcode's Welcome window.
private struct RecentRow: View {
	let url: URL
	let action: () -> Void
	@State private var hovering = false

	var body: some View {
		Button(action: action) {
			HStack(spacing: 10) {
				Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 32, height: 32)
				VStack(alignment: .leading, spacing: 1) {
					Text(url.deletingPathExtension().lastPathComponent).lineLimit(1)
					Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
						.font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
				}
				Spacer(minLength: 0)
			}
			.padding(.horizontal, 8).padding(.vertical, 6)
			.contentShape(Rectangle())
			.background(hovering ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8))
		}
		.buttonStyle(.plain)
		.onHover { hovering = $0 }
	}
}
