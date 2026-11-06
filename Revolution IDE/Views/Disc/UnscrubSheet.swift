import SwiftUI
import UniformTypeIdentifiers

/// "Unscrub Image": pick a scrubbed ISO + its .dif file, and where to save the restored image.
struct UnscrubSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) var dismiss

    @State private var scrubbedURL: URL?
    @State private var diffURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Unscrub Image").font(.title2.bold())

            picker(label: "Scrubbed ISO", url: $scrubbedURL, extensions: ["iso"])
            picker(label: "Diff (.dif) file", url: $diffURL, extensions: ["dif"])

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Unscrub...") { runUnscrub() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(scrubbedURL == nil || diffURL == nil)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    @ViewBuilder
    private func picker(label: String, url: Binding<URL?>, extensions: [String]) -> some View {
        HStack {
            Text(label).frame(width: 120, alignment: .leading)
            Text(url.wrappedValue?.lastPathComponent ?? "Not chosen")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Choose...") {
                PanelPresenter.openFile(configure: {
                    $0.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
                }) { picked in
                    if let picked { url.wrappedValue = picked }
                }
            }
        }
    }

    private func runUnscrub() {
        guard let scrubbedURL, let diffURL else { return }
        let suggested = scrubbedURL.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "(compress)", with: "") + "-fixed.iso"
        PanelPresenter.saveFile(configure: { $0.nameFieldStringValue = suggested }) { dest in
            guard let dest else { return }
            dismiss()
            app.unscrub(scrubbedURL: scrubbedURL, diffURL: diffURL, destinationURL: dest)
        }
    }
}
