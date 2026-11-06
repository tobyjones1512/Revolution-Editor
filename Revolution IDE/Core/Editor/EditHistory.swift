import Foundation
import Combine

/// App-wide preference for how many undo steps each editor's history keeps, backing the "Undo
/// History Limit" control in Settings.
nonisolated enum EditHistoryPrefs {
    static let limitKey = "EditHistoryPrefs.limit"
    static let defaultLimit = 15

    static var limit: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: limitKey)
            return stored > 0 ? stored : defaultLimit
        }
        set { UserDefaults.standard.set(max(1, newValue), forKey: limitKey) }
    }
}

/// Generic bounded undo/redo history for one open document: a list of labeled snapshots with a
/// current-position pointer, so both linear undo/redo (Cmd-Z / Cmd-Shift-Z) and "jump straight to
/// any earlier state" (a Photoshop-style history list, not just one step at a time) work off the
/// same data.
///
/// Snapshots are each document's own already-trusted `serialize()` bytes rather than a deep copy
/// of the live document object, every document class in this app already round-trips through
/// `serialize()`/`parse()` for Save, so undo can never diverge from what Save would actually
/// write, and there's no risk of two "different" snapshots secretly aliasing the same mutable
/// array/object underneath (a real risk with a naive struct/class copy of a document containing
/// class-typed children, e.g. BRRES's `BRRESResource`).
@MainActor final class EditHistory: ObservableObject {
    struct Entry: Identifiable {
        let id = UUID()
        let label: String
        let snapshot: Data
        let date = Date()
    }

    @Published private(set) var entries: [Entry]
    @Published private(set) var currentIndex: Int
    var limit: Int

    init(initial: Data, label: String = "Opened", limit: Int = EditHistoryPrefs.limit) {
        entries = [Entry(label: label, snapshot: initial)]
        currentIndex = 0
        self.limit = limit
    }

    var canUndo: Bool { currentIndex > 0 }
    var canRedo: Bool { currentIndex < entries.count - 1 }

    /// Records a new state after an edit "settles", a drag ends, a discrete action (add/delete/
    /// import) completes, not on every intermediate change, or the history fills with noise
    /// instead of meaningful steps. Discards any "future" redo entries beyond the current position,
    /// exactly like every real undo stack does once you make a new edit after undoing.
    func push(_ snapshot: Data, label: String) {
        if currentIndex < entries.count - 1 {
            entries.removeSubrange((currentIndex + 1)...)
        }
        // Never push a no-op entry (e.g. a field committed back to the same value).
        if snapshot == entries[currentIndex].snapshot { return }
        entries.append(Entry(label: label, snapshot: snapshot))
        currentIndex = entries.count - 1
        trim()
    }

    private func trim() {
        let maxEntries = max(1, limit) + 1 // +1 for the permanent "Opened" baseline entry
        guard entries.count > maxEntries else { return }
        let overflow = entries.count - maxEntries
        entries.removeFirst(overflow)
        currentIndex -= overflow
    }

    @discardableResult
    func undo() -> Data? {
        guard canUndo else { return nil }
        currentIndex -= 1
        return entries[currentIndex].snapshot
    }

    @discardableResult
    func redo() -> Data? {
        guard canRedo else { return nil }
        currentIndex += 1
        return entries[currentIndex].snapshot
    }

    /// Jumps straight to any recorded state, the Photoshop-style history-list behavior, distinct
    /// from stepwise `undo()`/`redo()`.
    @discardableResult
    func jump(to index: Int) -> Data? {
        guard entries.indices.contains(index), index != currentIndex else { return nil }
        currentIndex = index
        return entries[index].snapshot
    }
}
