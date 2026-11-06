import SwiftUI

struct BMGEditorView: View {
    @ObservedObject var box: BMGDocumentBox
    @State private var selection: BMGMessage.ID?
    /// Undo/redo + history list, same `EditHistory` pattern `KMPEditorView` uses.
    @StateObject private var history: EditHistory

    init(box: BMGDocumentBox) {
        self.box = box
        _history = StateObject(wrappedValue: EditHistory(initial: box.doc.serialize()))
    }

    private func pushHistory(_ label: String) {
        history.push(box.doc.serialize(), label: label)
    }

    private func restoreFromHistory(_ data: Data) {
        guard let doc = try? BMGDocument.parse(data) else { return }
        box.doc = doc
        selection = nil
        box.isDirty = true
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(box.doc.messages, selection: $selection) { m in
                    HStack(spacing: 6) {
                        Text(m.messageID.map(String.init) ?? "-")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .trailing)
                        Text(m.displayText).lineLimit(1)
                        if m.containsEscape {
                            Image(systemName: "lock").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .tag(m.id)
                }
                .listStyle(.inset)
                .help("A BMG file holds a game's in-game text messages (dialogue, menu labels, credits, etc.) indexed by ID. The lock icon means a message contains a special control code that isn't shown/edited here to avoid corrupting it.")
                Divider()
                HStack(spacing: 12) {
                    Button { addMessage() } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("Add a new message")
                    Button { removeSelected() } label: { Image(systemName: "minus") }
                        .buttonStyle(.borderless)
                        .disabled(selection == nil)
                        .help("Remove the selected message")
                    Spacer()
                    HistoryControlsView(history: history, onRestore: restoreFromHistory)
                }
                .padding(6)
            }
            .frame(minWidth: 280, idealWidth: 340)

            if let idx = box.doc.messages.firstIndex(where: { $0.id == selection }) {
                detail(for: idx)
            } else {
                Text("Select a message.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Commits a history step for whatever was just edited when the user moves to a different
        // message (or deselects), rather than on every keystroke, same "settle point" idea as
        // `KMPEditorView`'s drag-end/field-commit pushes, just keyed off selection instead.
        .onChange(of: selection) { old, _ in
            if old != nil { pushHistory("Edit Message") }
        }
    }

    /// One past the highest existing message ID (0 if none are numbered yet, or if the document
    /// is empty), new messages need *some* ID to be referenceable from game code/KMP, and this
    /// is the least likely guess to collide with an existing one.
    private var nextMessageID: UInt32 {
        box.doc.messages.compactMap(\.messageID).max().map { $0 &+ 1 } ?? 0
    }

    private func addMessage() {
        let attrLen = box.doc.messages.first?.attribute.count ?? 4
        let m = BMGMessage(messageID: nextMessageID, attribute: Data(repeating: 0, count: attrLen), units: [])
        box.doc.messages.append(m)
        box.isDirty = true
        selection = m.id
        pushHistory("Add Message")
    }

    private func removeSelected() {
        guard let selection, let idx = box.doc.messages.firstIndex(where: { $0.id == selection }) else { return }
        box.doc.messages.remove(at: idx)
        box.isDirty = true
        self.selection = nil
        pushHistory("Remove Message")
    }

    @ViewBuilder
    private func detail(for idx: Int) -> some View {
        let m = box.doc.messages[idx]
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Message ID").font(.caption).foregroundStyle(.secondary)
                TextField("none", value: Binding(
                    get: { Int(m.messageID ?? 0) },
                    set: { box.doc.messages[idx].messageID = UInt32(max(0, min($0, Int(UInt32.max)))); box.isDirty = true }
                ), format: .number)
                .textFieldStyle(.roundedBorder).frame(width: 100).font(.caption.monospacedDigit())
            }
            if m.containsEscape {
                Text("Contains a 0x1A escape sequence (Mii name, colour, unicode character, or a game reference), shown read-only so editing here can't silently corrupt it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    Text(m.displayText)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(Color.gray.opacity(0.08))
            } else {
                TextEditor(text: Binding(
                    get: { m.displayText },
                    set: { newValue in
                        box.doc.messages[idx].units = Array(newValue.utf16)
                        box.isDirty = true
                    }
                ))
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3)))
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
