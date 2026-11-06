import SwiftUI
import Combine

/// Photoshop-style history list for an `EditHistory`: every recorded state is shown (not just the
/// two neighbors undo/redo would reach), and clicking any entry jumps straight to it.
struct HistoryPanelView: View {
    @ObservedObject var history: EditHistory
    let onJump: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("History").font(.headline)
                Spacer()
                Text("\(history.entries.count) state\(history.entries.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
            }
            .padding([.top, .horizontal], 10)
            Divider().padding(.top, 8)
            List {
                ForEach(Array(history.entries.enumerated()), id: \.element.id) { i, entry in
                    HStack {
                        Image(systemName: i == history.currentIndex ? "arrow.right.circle.fill" : "circle")
                            .foregroundStyle(i == history.currentIndex ? Color.accentColor : Color.secondary)
                        Text(entry.label)
                        Spacer()
                        Text(entry.date, style: .time).font(.caption2).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onJump(i) }
                    .listRowBackground(i == history.currentIndex ? Color.accentColor.opacity(0.15) : Color.clear)
                }
            }
            .listStyle(.inset)
        }
        .frame(width: 260, height: 320)
    }
}

/// Undo/Redo buttons plus a "History" popover button, meant to be dropped into any editor that
/// keeps an `EditHistory`. `onRestore` is handed the chosen snapshot's bytes to re-parse and apply
/// back onto the live document, each editor owns how that happens since every document type
/// parses differently.
struct HistoryControlsView: View {
    @ObservedObject var history: EditHistory
    /// Off for text editors, so Cmd-Z keeps undoing typing through the text view's own undo.
    var shortcuts = true
    let onRestore: (Data) -> Void

    @State private var showHistory = false

    private func redo() {
        if let d = history.redo() { onRestore(d) }
    }

    var body: some View {
        HStack(spacing: 4) {
            Button { if let d = history.undo() { onRestore(d) } } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!history.canUndo)
                .shortcut(.undo, enabled: shortcuts)
                .help("Undo")
            Button { redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!history.canRedo)
                .shortcut(.redo, enabled: shortcuts)
                .help("Redo")
            // A `Button` only ever carries one `.keyboardShortcut`, this twin gives
            // Cmd-Y (the Windows/Office-style redo muscle memory some users have) the exact same
            // action as the visible Redo button above, rather than replacing its Cmd-Shift-Z.
            Button("Redo") { redo() }
                .disabled(!history.canRedo)
                .shortcut(.redoAlternate, enabled: shortcuts)
                .frame(width: 1, height: 1)
                .opacity(0.01)
            Button { showHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                .help("History")
                .popover(isPresented: $showHistory) {
                    HistoryPanelView(history: history) { index in
                        if let d = history.jump(to: index) { onRestore(d) }
                        showHistory = false
                    }
                }
        }
        .buttonStyle(.borderless)
    }
}

/// Undo/redo + history for an editor whose document can be snapshotted at any moment: records a
/// step each time edits settle (a short pause after the last change), and restores a snapshot on
/// undo/redo/jump. For editors that don't mark discrete steps themselves.
struct AutoHistoryControls: View {
    @StateObject private var history: EditHistory
    let changes: ObservableObjectPublisher
    /// The document now, or nil if it can't be captured yet (e.g. audio still encoding).
    let snapshot: () -> Data?
    let restore: (Data) -> Void
    var shortcuts = true
    @State private var restoring = false

    init(initial: Data, changes: ObservableObjectPublisher, shortcuts: Bool = true,
         snapshot: @escaping () -> Data?, restore: @escaping (Data) -> Void) {
        _history = StateObject(wrappedValue: EditHistory(initial: initial))
        self.changes = changes
        self.shortcuts = shortcuts
        self.snapshot = snapshot
        self.restore = restore
    }

    var body: some View {
        HistoryControlsView(history: history, shortcuts: shortcuts) { data in
            restoring = true
            restore(data)
        }
        .padding(6)
        .background(.bar, in: RoundedRectangle(cornerRadius: 8))
        .onReceive(changes.debounce(for: .milliseconds(600), scheduler: RunLoop.main)) { _ in
            // The change a restore itself causes isn't a new step.
            if restoring { restoring = false; return }
            guard let data = snapshot() else { return }
            history.push(data, label: "Edit")
        }
    }
}
