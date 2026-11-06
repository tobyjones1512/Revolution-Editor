import SwiftUI

/// Right-click Partition > "Resize Partition (data size)..."
struct ResizePartitionSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) var dismiss
    let partitionIndex: Int

    @State private var sizeText: String = ""

    private var partition: RuntimePartition? { app.wiiDisc?.partitions[safe: partitionIndex] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Resize Partition \(partitionIndex)").font(.title2.bold())
            if let p = partition {
                Text("Current data size: \(ByteCountFormatter.string(fromByteCount: Int64(p.header.dataSize), countStyle: .binary)) (0x\(String(p.header.dataSize, radix: 16)))")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Used by files: \(ByteCountFormatter.string(fromByteCount: Int64(p.usedDataSize), countStyle: .binary))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("New size (bytes, hex ok e.g. 0x10000000):")
                TextField("bytes", text: $sizeText)
                    .frame(width: 160)
            }
            Text("Some discs set a partition's data size far larger than its actual data, wasting space that can't hold added/replaced files until you shrink it here (FAQ Q14).")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Resize") { apply() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { sizeText = partition.map { String($0.header.dataSize) } ?? "" }
    }

    private func apply() {
        guard let value = parseSize(sizeText) else { return }
        dismiss()
        app.resizePartition(index: partitionIndex, newDataSize: value)
    }

    private func parseSize(_ s: String) -> UInt64? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("0x") { return UInt64(trimmed.dropFirst(2), radix: 16) }
        return UInt64(trimmed)
    }
}

/// WII DISC > "Import Partition..."
struct ImportPartitionSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) var dismiss
    let initialTableIndex: Int
    let initialOffset: UInt64

    @State private var blobURL: URL?
    @State private var offsetText: String = ""
    @State private var tableIndex: Int = 0
    @State private var kind: PartitionKind = .data

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Crypted Partition").font(.title2.bold())
            Text("Table 0 may hold at most 3 partitions, a hard Wii limitation (README).")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Text("Partition file").frame(width: 110, alignment: .leading)
                Text(blobURL?.lastPathComponent ?? "Not chosen").foregroundStyle(.secondary)
                Spacer()
                Button("Choose...") {
                    PanelPresenter.openFile { url in
                        if let url { blobURL = url }
                    }
                }
            }
            HStack {
                Text("Disc offset").frame(width: 110, alignment: .leading)
                TextField("0x...", text: $offsetText).frame(width: 180)
            }
            Picker("Partition table", selection: $tableIndex) {
                ForEach(0..<4) { Text("Table \($0)").tag($0) }
            }
            Picker("Kind", selection: $kind) {
                Text("Data").tag(PartitionKind.data)
                Text("Update").tag(PartitionKind.update)
                Text("Channel").tag(PartitionKind.channel)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Import") { apply() }.keyboardShortcut(.defaultAction)
                    .disabled(blobURL == nil)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            tableIndex = initialTableIndex
            offsetText = "0x" + String(initialOffset, radix: 16)
        }
    }

    private func apply() {
        guard let blobURL else { return }
        let trimmed = offsetText.trimmingCharacters(in: .whitespaces)
        let offset: UInt64? = trimmed.lowercased().hasPrefix("0x") ? UInt64(trimmed.dropFirst(2), radix: 16) : UInt64(trimmed)
        guard let offset else { return }
        dismiss()
        app.importPartition(blobURL: blobURL, atOffset: offset, tableIndex: tableIndex, kind: kind)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
