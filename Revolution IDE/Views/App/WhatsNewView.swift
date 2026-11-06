import SwiftUI
import AppKit

/// Shown once each time a different version of the app is opened (newer or older), on whichever
/// window launch puts on screen: Welcome, or the Workbench when Finder opened files directly.
/// Also opens any time from Revolution Editor > What's New.
struct WhatsNewView: View {
	@Environment(\.dismiss) private var dismiss

	/// This release's new features (not bug fixes). Update with each version.
	private static let items: [(icon: String, title: String, detail: String)] = [
		("folder.badge.plus", "Folder tabs", "Open several project folders at once. Each one gets a tab above the Project Navigator, so you can switch between them."),
		("archivebox", "Archives open their folder", "Opening a .szs or .arc brings up the folder it lives in, with the archive already expanded. You can turn this off in Settings > Editing."),
		("list.bullet.indent", "Outliner in the inspector", "Expand any section in the KMP inspector to see every point, object, area and camera in it, and click one to select it."),
		("square.dashed", "Areas on the canvas", "Every AREA now shows its box or cylinder outline on the KMP canvas, turning with its rotation."),
		("video", "Replay cameras and areas travel between games", "Porting between Mario Kart Wii and Double Dash now carries replay cameras and the areas that trigger them in both directions."),
		("cube.transparent", "Better transparent geometry", "Fences, foliage, glass and fades now draw correctly in every 3D preview."),
		("square.and.arrow.up", "Edit collision as OBJ", "In the KCL editor, Edit as OBJ writes the collision out and offers to open it in your model editor, ready to bring back with Import OBJ."),
		("ladybug", "Review Crash Logs", "Reads Dolphin's log, explains what went wrong in plain English with ideas for fixing it, or shows just the crash section. Find it in Settings > Emulator and the Help menu."),
		("checklist", "To-Do list", "Keep steps and ideas for each project, and auto fill a starter checklist for a custom track, battle map and more in each game."),
	]

	static let lastShownKey = "whatsNew.lastShownVersion"
	static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
	/// Set once a window has taken the job of showing it this launch.
	@MainActor static var claimed = false

	/// Claims the sheet for the caller if this version hasn't shown it yet. A first-ever launch
	/// goes through setup instead, so it just records the version.
	@MainActor static func claim() -> Bool {
		guard !claimed else { return false }
		claimed = true
		let d = UserDefaults.standard
		guard d.string(forKey: lastShownKey) != currentVersion else { return false }
		d.set(currentVersion, forKey: lastShownKey)
		return !SetupWizardView.needed
	}

	var body: some View {
		VStack(spacing: 18) {
			VStack(spacing: 4) {
				Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
				Text("What's New").font(.title2.bold())
				Text("Revolution Editor \(Self.currentVersion)").font(.subheadline).foregroundStyle(.secondary)
			}
			ScrollView {
			VStack(alignment: .leading, spacing: 14) {
				ForEach(Self.items, id: \.title) { item in
					HStack(alignment: .top, spacing: 12) {
						Image(systemName: item.icon).font(.title3).foregroundStyle(.tint).frame(width: 28)
						VStack(alignment: .leading, spacing: 2) {
							Text(item.title).font(.headline)
							Text(item.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
						}
					}
				}
			}
			}
			.frame(maxHeight: 420)
			Button("Continue") { dismiss() }.keyboardShortcut(.defaultAction).controlSize(.large)
		}
		.padding(28)
		.frame(width: 440)
	}
}

extension View {
	/// Presents What's New over this window when it's the one launch shows and this version is new.
	/// `delay` lets a window that may be hidden at launch (the Workbench) wait for Welcome to claim it.
	func whatsNewSheet(delay: Duration = .zero, onlyIfVisible: Bool = false) -> some View {
		modifier(WhatsNewPresenter(delay: delay, onlyIfVisible: onlyIfVisible))
	}
}

private struct WhatsNewPresenter: ViewModifier {
	let delay: Duration
	let onlyIfVisible: Bool
	@State private var showing = false

	func body(content: Content) -> some View {
		content
			.task {
				try? await Task.sleep(for: delay)
				if onlyIfVisible, NSApp.windows.contains(where: { ($0.identifier?.rawValue ?? "").hasPrefix("welcome") && $0.isVisible }) { return }
				if WhatsNewView.claim() { showing = true }
			}
			.sheet(isPresented: $showing) { WhatsNewView() }
	}
}
