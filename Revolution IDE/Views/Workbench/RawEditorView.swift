import SwiftUI

/// Fallback editor for any file this app doesn't have a dedicated format for: a read-only hex
/// dump preview plus the ability to swap the whole file's bytes from another file on disk.
struct RawEditorView: View {
    @ObservedObject var box: RawDocumentBox
    let title: String
    /// Undo/redo + history list, same `EditHistory` pattern `KMPEditorView` uses, snapshots are
    /// just `box.data` itself (already raw bytes, no serialize/parse round-trip needed).
    @StateObject private var history: EditHistory

    init(box: RawDocumentBox, title: String) {
        self.box = box
        self.title = title
        _history = StateObject(wrappedValue: EditHistory(initial: box.data))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.title3.bold())
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(box.data.count), countStyle: .file)).foregroundStyle(.secondary)
                HistoryControlsView(history: history) { data in
                    box.data = data
                    box.isDirty = true
                }
            }
            Button("Replace Contents from File...") { replace() }
            ScrollView {
                Text(hexDump(box.data.prefix(0x1000)))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if box.data.count > 0x1000 {
                Text("Showing first 4KB of \(box.data.count) bytes.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private func replace() {
        PanelPresenter.openFile { url in
            guard let url, let data = try? Data(contentsOf: url) else { return }
            box.data = data
            box.isDirty = true
            history.push(data, label: "Replace Contents")
        }
    }

    private func hexDump(_ data: Data) -> String {
        var lines: [String] = []
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            let chunk = bytes[i..<min(i + 16, bytes.count)]
            let hex = chunk.map { String(format: "%02X", $0) }.joined(separator: " ")
            let ascii = String(chunk.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." })
            let offsetStr = String(format: "%08X", i)
            lines.append("\(offsetStr)  \(hex.padding(toLength: 47, withPad: " ", startingAt: 0))  \(ascii)")
            i += 16
        }
        return lines.joined(separator: "\n")
    }
}
