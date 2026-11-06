import SwiftUI
import UniformTypeIdentifiers

/// The main file browser: a tree of the disc's files with right-click operations (Save/Extract,
/// Replace, partition delete/resize/shrink/export, and the boot mode toggle on the WII DISC row).
struct DiscTreeView: View {
    @EnvironmentObject var app: AppState
    @Binding var pendingReplace: DiscNode?
    @Binding var pendingResize: Int?
    @Binding var pendingImport: (tableIndex: Int, offset: UInt64)?

    var body: some View {
        List(selection: $app.selection) {
            if let root = app.rootNode {
                OutlineGroup([root], children: \.childrenOrNil) { node in
                    row(for: node)
                        .tag(node)
                }
            } else {
                Text("No disc loaded. Use File > Open ISO...")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func row(for node: DiscNode) -> some View {
        HStack {
            Image(systemName: icon(for: node))
                .foregroundStyle(node.isFile ? .secondary : .primary)
            Text(node.name)
            Spacer()
            if node.isFile {
                Text(byteString(node.fileSize))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("fst #\(node.displayFSTIndex)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .contextMenu { contextMenu(for: node) }
    }

    private func icon(for node: DiscNode) -> String {
        switch node.kind {
        case .root: return "opticaldiscdrive"
        case .partition: return "square.stack.3d.up"
        case .partitionComponent: return "doc.badge.gearshape"
        case .directory: return "folder"
        case .file: return "doc"
        }
    }

    private func byteString(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .binary)
    }

    @ViewBuilder
    private func contextMenu(for node: DiscNode) -> some View {
        switch node.kind {
        case .root:
            if app.isWiiDisc {
                Button("Toggle Boot Mode (system menu <-> auto-boot)") { app.toggleBootMode() }
                Button("Shuffle Partitions (close gaps)") { app.shufflePartitions() }
                Button("Import Partition...") {
                    if let disc = app.wiiDisc {
                        pendingImport = (0, PartitionOperations.suggestedFreeOffset(disc: disc))
                    }
                }
            }
        case .partition(let idx):
            Button("Export Crypted Partition...") { exportPartition(idx) }
            Divider()
            Button("Resize Partition (data size)...") { pendingResize = idx }
            Button("Shrink Partition (defragment, uses Trucha)") { app.shrinkPartition(index: idx) }
            Divider()
            Button("Delete Partition", role: .destructive) { app.deletePartition(index: idx) }
        case .partitionComponent, .file:
            Button("Save / Extract...") { extract(node) }
            if node.isFile, app.isWiiDisc {
                Button("Replace...") { pendingReplace = node }
            }
        case .directory:
            EmptyView()
        }
    }

    private func extract(_ node: DiscNode) {
        let name = node.name.isEmpty ? "file.bin" : (node.name as NSString).lastPathComponent
        PanelPresenter.saveFile(configure: { $0.nameFieldStringValue = name }) { url in
            guard let url else { return }
            app.extract(node: node, to: url)
        }
    }

    private func exportPartition(_ idx: Int) {
        PanelPresenter.saveFile(configure: { $0.nameFieldStringValue = "partition\(idx).bin" }) { url in
            guard let url else { return }
            app.exportPartition(index: idx, to: url)
        }
    }
}
