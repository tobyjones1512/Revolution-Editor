import SwiftUI

/// "Clean and Save": pick the scrub type, the output file and whether to keep the hash headers.
struct ScrubSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) var dismiss

    @State private var type: ScrubType = .fill0xFF
    @State private var output: ScrubOutput = .isoOnly
    @State private var keepHeaders = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Clean and Save").font(.title2.bold())

            Picker("Scrub type", selection: $type) {
                Text("0xFF (safe, no signing needed)").tag(ScrubType.fill0xFF)
                Text("TRUCHA (0-fill + fake-sign)").tag(ScrubType.trucha)
            }
            .pickerStyle(.radioGroup)

            Picker("Output", selection: $output) {
                Text("ISO only").tag(ScrubOutput.isoOnly)
                Text("DIFF only").tag(ScrubOutput.diffOnly)
                Text("Both").tag(ScrubOutput.both)
            }
            .pickerStyle(.radioGroup)

            Toggle("Keep cluster hash headers (bigger, less to lose if wrong)", isOn: $keepHeaders)
                .help("Wii discs store a hash alongside every data cluster so a real console can verify it wasn't corrupted. Keeping these makes the cleaned ISO a bit bigger but safer to fall back on; discarding them saves more space but there's less to recover from if something's wrong.")

            Text("""
            0xFF fills unused padding between files with 0xFF so it compresses away, without touching \
            any real file data or the disc's signatures (the default mode).
            TRUCHA additionally 0-fills that padding and fake-signs the affected partitions' ticket/TMD \
            using the "Trucha bug" that homebrew signing tools of that era relied on.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Clean and Save...") { runScrub() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func runScrub() {
        var options = ScrubOptions()
        options.type = type
        options.output = output
        options.keepHeaders = keepHeaders
        let baseName = (app.discURL?.deletingPathExtension().lastPathComponent ?? "disc")

        // Chained asynchronously (rather than back-to-back runModal() calls) since a second
        // app-modal panel presented synchronously right after the first can fail to show.
        chooseISODestination(options: options, baseName: baseName)
    }

    private func chooseISODestination(options: ScrubOptions, baseName: String) {
        guard options.output != .diffOnly else {
            chooseDiffDestination(options: options, baseName: baseName, isoDest: nil)
            return
        }
        PanelPresenter.saveFile(configure: { $0.nameFieldStringValue = "\(baseName)(compress).iso" }) { url in
            guard let url else { return }
            chooseDiffDestination(options: options, baseName: baseName, isoDest: url)
        }
    }

    private func chooseDiffDestination(options: ScrubOptions, baseName: String, isoDest: URL?) {
        guard options.output != .isoOnly else {
            dismiss()
            app.scrub(options: options, isoDestination: isoDest, diffDestination: nil)
            return
        }
        PanelPresenter.saveFile(configure: { $0.nameFieldStringValue = "\(baseName).dif" }) { url in
            guard let url else { return }
            dismiss()
            app.scrub(options: options, isoDestination: isoDest, diffDestination: url)
        }
    }
}
