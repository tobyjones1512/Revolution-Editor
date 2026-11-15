import SwiftUI
import AppKit

/// Shown once each time a different version of the app is opened (newer or older), on whichever
/// window launch puts on screen: Welcome, or the Workbench when Finder opened files directly.
/// Also opens any time from Revolution Editor > What's New.
struct WhatsNewView: View {
	@Environment(\.dismiss) private var dismiss

	/// This release's new features (not bug fixes). Update with each version.
	private static let items: [(icon: String, title: String, detail: String)] = [
		("wrench.and.screwdriver", "Bug fixes", "Fixed areas drawing too large in the Mario Kart Double Dash .bol editor under certain conditions, plus other UI fixes."),
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
