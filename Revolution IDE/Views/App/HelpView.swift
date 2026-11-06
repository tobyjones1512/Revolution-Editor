import SwiftUI

/// The Help window.
struct HelpView: View {
	var body: some View {
		VStack(spacing: 14) {
			Image(systemName: "book.fill").font(.system(size: 40)).foregroundStyle(.tint)
			Text("Revolution Editor Help").font(.title2.bold())
			Text("Documentation for every editor, the homebrew tools and the supported games is in the project's README.")
				.foregroundStyle(.secondary).multilineTextAlignment(.center)
		}
		.padding(32).frame(width: 380)
	}
}
