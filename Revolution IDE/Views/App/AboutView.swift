import SwiftUI
import AppKit

/// Name, version, a one-line description and the places to get help. Legal notes are one short line at the bottom.
struct AboutView: View {
	@Environment(\.dismiss) private var dismiss

	private var version: String {
		let info = Bundle.main.infoDictionary
		let v = info?["CFBundleShortVersionString"] as? String ?? "1.0"
		let b = info?["CFBundleVersion"] as? String ?? "1"
		return "Version \(v) (\(b))"
	}

	var body: some View {
		VStack(spacing: 14) {
			Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
			VStack(spacing: 2) {
				Text("Revolution Editor").font(.title2.bold())
				HStack(spacing: 6) {
					Text(version).font(.subheadline).foregroundStyle(.secondary)
					Text("Alpha").font(.caption2.bold())
						.padding(.horizontal, 6).padding(.vertical, 2)
						.background(.orange.opacity(0.2), in: Capsule())
						.foregroundStyle(.orange)
				}
			}
			Text("An editor for Wii and GameCube mods and homebrew.").multilineTextAlignment(.center)
			Link("Discord", destination: URL(string: "https://discord.gg/nXFSaFZbHf")!)
			Text("You provide your own game files and keys. Nothing from Nintendo is included, and this app isn't affiliated with Nintendo.")
				.font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
			Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
		}
		.padding(28)
		.frame(width: 380)
	}
}
