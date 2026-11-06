import SwiftUI
import UniformTypeIdentifiers

struct DiscScrubberView: View {
    @EnvironmentObject var app: AppState

    @State private var showScrubSheet = false
    @State private var showUnscrubSheet = false
    @State private var showKeysSheet = false
    @State private var showAboutSheet = false
    @State private var pendingReplace: DiscNode?
    @State private var pendingResize: Int?
    @State private var pendingImport: (tableIndex: Int, offset: UInt64)?

    var body: some View {
        VStack(spacing: 0) {
            infoBar
            Divider()
            VSplitView {
                DiscTreeView(pendingReplace: $pendingReplace, pendingResize: $pendingResize, pendingImport: $pendingImport)
                    .frame(minHeight: 200)
                LogPanelView()
                    .frame(minHeight: 100, idealHeight: 160)
            }
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $showScrubSheet) { ScrubSheet().environmentObject(app) }
        .sheet(isPresented: $showUnscrubSheet) { UnscrubSheet().environmentObject(app) }
        .sheet(isPresented: $showKeysSheet) { KeysView() }
        .sheet(isPresented: $showAboutSheet) { AboutView() }
        .sheet(isPresented: Binding(get: { pendingResize != nil }, set: { if !$0 { pendingResize = nil } })) {
            if let pendingResize {
                ResizePartitionSheet(partitionIndex: pendingResize).environmentObject(app)
            }
        }
        .sheet(isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } })) {
            if let pendingImport {
                ImportPartitionSheet(initialTableIndex: pendingImport.tableIndex, initialOffset: pendingImport.offset)
                    .environmentObject(app)
            }
        }
        .onChange(of: pendingReplace) { _, newValue in
            guard let node = newValue else { return }
            PanelPresenter.openFile(configure: { $0.message = "Choose the replacement file for \"\(node.name)\"" }) { url in
                if let url { app.replace(node: node, withDataAt: url) }
                pendingReplace = nil
            }
        }
        .alert("Error", isPresented: Binding(get: { app.errorMessage != nil }, set: { if !$0 { app.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.errorMessage ?? "")
        }
        .navigationTitle(app.discURL?.lastPathComponent ?? "Wii/GCN Disc Scrubber")
    }

    private var infoBar: some View {
        HStack {
            if let disc = app.wiiDisc {
                VStack(alignment: .leading, spacing: 2) {
                    Text(disc.gameTitle.isEmpty ? disc.gameID : disc.gameTitle).font(.headline)
                    Text("\(disc.gameID) - Disc \(disc.discNumber + 1), v\(disc.discVersion) - boot: \(disc.bootMode == 0 ? "auto" : String(UnicodeScalar(disc.bootMode)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                let used = disc.partitions.reduce(UInt64(0)) { $0 + $1.usedDataSize }
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Data size").font(.caption).foregroundStyle(.secondary)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(used), countStyle: .binary)).font(.headline)
                }
            } else if let gc = app.gcDisc {
                Text("\(gc.gameTitle) [\(gc.gameID)] (GameCube, read-only)").font(.headline)
                Spacer()
            } else {
                Text("No disc loaded").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { openISO() } label: { Label("Open ISO", systemImage: "opticaldiscdrive") }
                .help("Open a Wii or GameCube disc image (.iso/.gcm) to browse its files, replace them, or (Wii) clean/shrink the disc. Wii discs are encrypted, load your key.bin under Keys first if this fails.")
        }
        ToolbarItem { Button { showKeysSheet = true } label: { Label("Keys", systemImage: "key") }
            .help("Load your own key.bin (and kkey.bin for Korean discs) so this app can decrypt Wii disc images. No key is bundled or downloaded, you must supply your own.")
        }
        ToolbarItem {
            Button { showScrubSheet = true } label: { Label("Clean and Save", systemImage: "sparkles") }
                .disabled(!app.isWiiDisc || app.isBusy)
                .help("Rewrites the disc removing unused padding/junk data, producing a smaller, cleaner ISO with the same content, the classic \"scrubbing\" operation. Saves to a new file; your original is left alone.")
        }
        ToolbarItem {
            Button { trimISO() } label: { Label("Trim ISO", systemImage: "scissors") }
                .disabled(!app.isWiiDisc || app.isBusy)
                .help("Cuts off trailing empty space at the end of the disc image to shrink the file, without touching or reorganizing any of its actual content.")
        }
        ToolbarItem {
            Button { showUnscrubSheet = true } label: { Label("Unscrub Image", systemImage: "arrow.uturn.backward") }
                .disabled(app.isBusy)
                .help("Pads a previously-scrubbed/trimmed image back out to a full-size, standard-layout disc image, useful if a tool or real console expects the original untrimmed size.")
        }
        ToolbarItem {
            Button { showAboutSheet = true } label: { Label("About", systemImage: "info.circle") }
                .help("About Revolution Editor and attribution for the tools/formats it's built on.")
        }
    }

    private func openISO() {
        PanelPresenter.openFile(configure: {
            $0.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .data]
            $0.allowsOtherFileTypes = true
        }) { url in
            guard let url else { return }
            app.openISO(url: url)
        }
    }

    private func trimISO() {
        let base = app.discURL?.deletingPathExtension().lastPathComponent ?? "disc"
        PanelPresenter.saveFile(configure: { $0.nameFieldStringValue = "\(base)-trimmed.iso" }) { url in
            guard let url else { return }
            app.trim(destinationURL: url)
        }
    }
}

#Preview {
    DiscScrubberView().environmentObject(AppState())
}
