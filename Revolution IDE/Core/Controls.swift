import SwiftUI
import AppKit
import Combine

/// Every keyboard shortcut and mouse-modifier control the app lets you change (Settings >
/// Controls). A `.key` action is a key plus modifiers; a `.modifier` action is the modifier keys
/// held with a mouse drag or click (none = the plain gesture).
enum ControlAction: String, CaseIterable, Identifiable {
    // File and windows
    case save, saveAs, openFile, openFolder, newWindow, welcome, help
    // Editing (every editor)
    case undo, redo, redoAlternate, selectAll, duplicate, copy, paste
    case zoomIn, zoomOut, zoomReset, zoomFit
    case exportImage, playPause, commit
    case penFinish, penCancel, penUndoAnchor
    // 3D track editor keys
    case flyForward, flyBack, flyLeft, flyRight, flyUp, flyDown
    case frameSelection, frameTrack, returnToStart, viewTop, viewFront, viewSide, toggleOrtho, deleteSelection
    // Mouse: 2D KMP/BOL editor
    case kmpBoxSelect, kmpPan, kmpDuplicateDrag, kmpRotate, kmpConstrain
    // Mouse: 3D track editor
    case view3DPan, view3DOrbitRight, view3DFlyFast, view3DStraight, view3DFaceCursor, view3DRotateRings, view3DBoxSelect
    // Mouse: node editor and UI designer
    case nodeExtendSelection, designerKeepAspect

    var id: String { rawValue }

    enum Kind { case key, modifier }
    var kind: Kind {
        switch self {
        case .kmpBoxSelect, .kmpPan, .kmpDuplicateDrag, .kmpRotate, .kmpConstrain,
             .view3DPan, .view3DOrbitRight, .view3DFlyFast, .view3DStraight, .view3DFaceCursor, .view3DRotateRings, .view3DBoxSelect,
             .nodeExtendSelection, .designerKeepAspect: return .modifier
        default: return .key
        }
    }

    /// Two modifier actions in one group act on the same target, so they can't share a value.
    var conflictGroup: String? {
        switch self {
        case .kmpBoxSelect, .kmpPan: return "kmp-empty"
        case .kmpDuplicateDrag, .kmpRotate, .kmpConstrain: return "kmp-point"
        case .view3DPan, .view3DOrbitRight, .view3DBoxSelect: return "3d-nav"
        case .view3DStraight, .view3DFaceCursor: return "3d-marker"
        default: return nil
        }
    }

    var group: String {
        switch self {
        case .save, .saveAs, .openFile, .openFolder, .newWindow, .welcome, .help: return "File and Windows"
        case .undo, .redo, .redoAlternate, .selectAll, .duplicate, .copy, .paste, .zoomIn, .zoomOut, .zoomReset, .zoomFit,
             .exportImage, .playPause, .commit, .penFinish, .penCancel, .penUndoAnchor: return "Editors"
        case .flyForward, .flyBack, .flyLeft, .flyRight, .flyUp, .flyDown, .frameSelection, .frameTrack, .returnToStart,
             .viewTop, .viewFront, .viewSide, .toggleOrtho, .deleteSelection: return "3D Track Editor Keys"
        case .kmpBoxSelect, .kmpPan, .kmpDuplicateDrag, .kmpRotate, .kmpConstrain: return "Course Data Editor (2D) Mouse"
        case .nodeExtendSelection, .designerKeepAspect: return "Node Editor and UI Designer Mouse"
        default: return "3D Track Editor Mouse"
        }
    }

    var title: String {
        switch self {
        case .save: return "Save"
        case .saveAs: return "Save As"
        case .openFile: return "Open File"
        case .openFolder: return "Open Folder"
        case .newWindow: return "New Window"
        case .welcome: return "Welcome Window"
        case .help: return "Help"
        case .undo: return "Undo"
        case .redo: return "Redo"
        case .redoAlternate: return "Redo (Alternate)"
        case .selectAll: return "Select All Points"
        case .duplicate: return "Duplicate"
        case .copy: return "Copy Course Data"
        case .paste: return "Paste Course Data"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        case .zoomReset: return "Reset Zoom"
        case .zoomFit: return "Zoom to Fit"
        case .exportImage: return "Export Image"
        case .playPause: return "Play / Pause"
        case .commit: return "Commit"
        case .penFinish: return "Pen Tool: Finish"
        case .penCancel: return "Pen Tool: Cancel"
        case .penUndoAnchor: return "Pen Tool: Undo Anchor"
        case .flyForward: return "Fly Forward"
        case .flyBack: return "Fly Back"
        case .flyLeft: return "Fly Left"
        case .flyRight: return "Fly Right"
        case .flyUp: return "Fly Up"
        case .flyDown: return "Fly Down"
        case .frameSelection: return "Frame Selection"
        case .frameTrack: return "Frame Whole Track"
        case .returnToStart: return "Return to Start"
        case .viewTop: return "Top View"
        case .viewFront: return "Front View"
        case .viewSide: return "Side View"
        case .toggleOrtho: return "Toggle Orthographic"
        case .deleteSelection: return "Delete Selection"
        case .kmpBoxSelect: return "Drag on empty space: box select"
        case .kmpPan: return "Drag on empty space: pan"
        case .kmpDuplicateDrag: return "Drag a point: duplicate it"
        case .kmpRotate: return "Drag a point: rotate it"
        case .kmpConstrain: return "Drag a point: keep to a straight line"
        case .view3DPan: return "Drag: pan (also middle drag, trackpad)"
        case .view3DOrbitRight: return "Right drag: orbit (otherwise pans)"
        case .view3DFlyFast: return "Fly keys: faster"
        case .view3DStraight: return "Drag a marker: keep to a straight line"
        case .view3DFaceCursor: return "Drag a marker: turn it to face the cursor"
        case .view3DRotateRings: return "Show rotation rings instead of move arrows"
        case .view3DBoxSelect: return "Drag: box select (click: toggle)"
        case .nodeExtendSelection: return "Click or drag: add to the selection"
        case .designerKeepAspect: return "Resize: keep the aspect ratio"
        }
    }

    var defaultBinding: ControlBinding {
        let c = ControlBinding.command, s = ControlBinding.shift, o = ControlBinding.option
        switch self {
        case .save: return .init(key: "s", mods: c)
        case .saveAs: return .init(key: "s", mods: c | s)
        case .openFile: return .init(key: "o", mods: c)
        case .openFolder: return .init(key: "o", mods: c | s)
        case .newWindow: return .init(key: "n", mods: c | s)
        case .welcome: return .init(key: "1", mods: c | s)
        case .help: return .init(key: "?", mods: c)
        case .undo: return .init(key: "z", mods: c)
        case .redo: return .init(key: "z", mods: c | s)
        case .redoAlternate: return .init(key: "y", mods: c)
        case .selectAll: return .init(key: "a", mods: c)
        case .duplicate: return .init(key: "d", mods: c)
        case .copy: return .init(key: "c", mods: c)
        case .paste: return .init(key: "v", mods: c)
        case .zoomIn: return .init(key: "=", mods: c)
        case .zoomOut: return .init(key: "-", mods: c)
        case .zoomReset: return .init(key: "0", mods: c)
        case .zoomFit: return .init(key: "9", mods: c)
        case .exportImage: return .init(key: "e", mods: c)
        case .playPause: return .init(key: "space", mods: 0)
        case .commit: return .init(key: "return", mods: c)
        case .penFinish: return .init(key: "return", mods: 0)
        case .penCancel: return .init(key: "escape", mods: 0)
        case .penUndoAnchor: return .init(key: "z", mods: c)
        case .flyForward: return .init(key: "w", mods: 0)
        case .flyBack: return .init(key: "s", mods: 0)
        case .flyLeft: return .init(key: "a", mods: 0)
        case .flyRight: return .init(key: "d", mods: 0)
        case .flyUp: return .init(key: "e", mods: 0)
        case .flyDown: return .init(key: "q", mods: 0)
        case .frameSelection: return .init(key: "f", mods: 0)
        case .frameTrack: return .init(key: "h", mods: 0)
        case .returnToStart: return .init(key: "0", mods: 0)
        case .viewTop: return .init(key: "7", mods: 0)
        case .viewFront: return .init(key: "1", mods: 0)
        case .viewSide: return .init(key: "3", mods: 0)
        case .toggleOrtho: return .init(key: "5", mods: 0)
        case .deleteSelection: return .init(key: "delete", mods: 0)
        case .kmpBoxSelect, .kmpDuplicateDrag, .view3DPan, .view3DFlyFast, .view3DStraight, .nodeExtendSelection, .designerKeepAspect: return .init(key: "", mods: s)
        case .kmpRotate, .view3DOrbitRight, .view3DFaceCursor, .view3DRotateRings: return .init(key: "", mods: o)
        case .kmpConstrain: return .init(key: "", mods: s | o)
        case .kmpPan: return .init(key: "", mods: 0)
        case .view3DBoxSelect: return .init(key: "", mods: c)
        }
    }
}

/// A key (for `.key` actions) and the modifier keys, as a stable bitmask.
struct ControlBinding: Codable, Equatable {
    var key: String
    var mods: UInt

    static let shift: UInt = 1 << 17, control: UInt = 1 << 18, option: UInt = 1 << 19, command: UInt = 1 << 20
    static let mask = shift | control | option | command

    static func mods(of flags: NSEvent.ModifierFlags) -> UInt { flags.rawValue & mask }

    var eventModifiers: EventModifiers {
        var m: EventModifiers = []
        if mods & Self.shift != 0 { m.insert(.shift) }
        if mods & Self.control != 0 { m.insert(.control) }
        if mods & Self.option != 0 { m.insert(.option) }
        if mods & Self.command != 0 { m.insert(.command) }
        return m
    }

    var keyEquivalent: KeyEquivalent? {
        switch key {
        case "": return nil
        case "return": return .return
        case "escape": return .escape
        case "space": return .space
        case "delete": return .delete
        case "tab": return .tab
        default: return key.count == 1 ? KeyEquivalent(Character(key)) : nil
        }
    }

    /// "⇧⌘S"
    var display: String {
        var s = ""
        if mods & Self.control != 0 { s += "\u{2303}" }
        if mods & Self.option != 0 { s += "\u{2325}" }
        if mods & Self.shift != 0 { s += "\u{21E7}" }
        if mods & Self.command != 0 { s += "\u{2318}" }
        switch key {
        case "": return s.isEmpty ? "None" : s
        case "return": return s + "\u{21A9}"
        case "escape": return s + "\u{238B}"
        case "space": return s + "Space"
        case "delete": return s + "\u{232B}"
        case "tab": return s + "\u{21E5}"
        default: return s + key.uppercased()
        }
    }

    /// The binding a key-down event spells, or nil for a bare modifier press.
    static func from(_ event: NSEvent) -> ControlBinding? {
        let m = mods(of: event.modifierFlags)
        switch event.keyCode {
        case 36, 76: return .init(key: "return", mods: m)
        case 53: return .init(key: "escape", mods: m)
        case 49: return .init(key: "space", mods: m)
        case 51, 117: return .init(key: "delete", mods: m)
        case 48: return .init(key: "tab", mods: m)
        default:
            guard let c = event.charactersIgnoringModifiers?.lowercased(), c.count == 1 else { return nil }
            return .init(key: c, mods: m)
        }
    }
}

@MainActor final class Controls: ObservableObject {
    static let shared = Controls()
    private static let defaultsKey = "controls.bindings.v1"

    @Published private(set) var overrides: [String: ControlBinding] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([String: ControlBinding].self, from: data) { overrides = saved }
    }

    func binding(_ a: ControlAction) -> ControlBinding { overrides[a.rawValue] ?? a.defaultBinding }
    func isCustom(_ a: ControlAction) -> Bool { overrides[a.rawValue] != nil }

    func set(_ b: ControlBinding, for a: ControlAction) {
        let old = binding(a)
        // Two controls for the same target can't share a modifier: the other one takes the old value.
        if a.kind == .modifier, let g = a.conflictGroup {
            for other in ControlAction.allCases where other != a && other.conflictGroup == g && binding(other).mods == b.mods {
                overrides[other.rawValue] = .init(key: "", mods: old.mods)
            }
        }
        overrides[a.rawValue] = b == a.defaultBinding ? nil : b
        persist()
    }

    func reset(_ a: ControlAction) { overrides[a.rawValue] = nil; persist() }
    func resetAll() { overrides = [:]; persist() }

    /// Other key actions that use this exact key combination in the same part of the app.
    func clashes(_ a: ControlAction) -> [ControlAction] {
        guard a.kind == .key else { return [] }
        let b = binding(a)
        return ControlAction.allCases.filter { $0 != a && $0.kind == .key && $0.group == a.group && binding($0) == b }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(overrides) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
    }

    // MARK: Wording for help text (so it follows the user's bindings)

    /// "Shift", "Shift+Option", or "" for the plain gesture.
    func modifierName(_ a: ControlAction) -> String {
        let m = binding(a).mods
        return [(ControlBinding.control, "Ctrl"), (ControlBinding.option, "Option"), (ControlBinding.shift, "Shift"), (ControlBinding.command, "Cmd")]
            .filter { m & $0.0 != 0 }.map(\.1).joined(separator: "+")
    }

    /// "Shift-drag", or "Drag" when the gesture is plain.
    func phrase(_ a: ControlAction, _ gesture: String) -> String {
        let m = modifierName(a)
        return m.isEmpty ? gesture.prefix(1).uppercased() + gesture.dropFirst() : "\(m)-\(gesture)"
    }

    /// A key action's shortcut as it appears in menus (glyphs).
    func keys(_ a: ControlAction) -> String { binding(a).display }

    /// Whether the modifier keys held right now are exactly `a`'s.
    func held(_ a: ControlAction, _ flags: NSEvent.ModifierFlags = NSEvent.modifierFlags) -> Bool {
        ControlBinding.mods(of: flags) == binding(a).mods
    }

    /// Whether a key event is `a`'s key, whatever Shift/Option are doing (for held keys like fly controls);
    /// Command and Control combinations are menu shortcuts and never match.
    func keyOnly(_ a: ControlAction, _ event: NSEvent) -> Bool {
        guard let b = ControlBinding.from(event), b.mods & (ControlBinding.command | ControlBinding.control) == 0 else { return false }
        return b.key == binding(a).key
    }

    /// Whether a key-down event is `a`'s shortcut (ignoring caps lock, the numeric pad and Fn).
    func matches(_ a: ControlAction, _ event: NSEvent) -> Bool {
        guard let b = ControlBinding.from(event) else { return false }
        return b == binding(a)
    }
}

private struct CustomShortcut: ViewModifier {
    @ObservedObject private var controls = Controls.shared
    let action: ControlAction
    var enabled = true
    func body(content: Content) -> some View {
        let b = controls.binding(action)
        if enabled, let key = b.keyEquivalent { content.keyboardShortcut(key, modifiers: b.eventModifiers) } else { content }
    }
}

extension View {
    /// This control's keyboard shortcut, as set in Settings > Controls.
    func shortcut(_ action: ControlAction, enabled: Bool = true) -> some View { modifier(CustomShortcut(action: action, enabled: enabled)) }
}
