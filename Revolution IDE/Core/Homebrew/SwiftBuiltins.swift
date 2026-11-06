import Foundation

/// A function the app provides. `def` is the C text used when an optional argument is left out.
nonisolated struct Builtin {
    var params: [(label: String?, type: SType, def: String?)]
    var ret: SType
    var emit: ([String]) -> String
}

nonisolated extension SwiftTranslator {
    static func makeBuiltins() -> [String: Builtin] {
        typealias P = (label: String?, type: SType, def: String?)
        func p(_ t: SType) -> P { (nil, t, nil) }
        func opt(_ label: String, _ t: SType, _ def: String) -> P { (label, t, def) }
        let i = p(.int), str = p(.string), d = p(.double)
        let rgba = [opt("r", .int, "255"), opt("g", .int, "255"), opt("b", .int, "255"), opt("a", .int, "255")]
        func call(_ c: String) -> ([String]) -> String { { "\(c)(\($0.joined(separator: ", ")))" } }
        var t: [String: Builtin] = [:]
        t["setText"] = Builtin(params: [i, str], ret: .void) { "wiiui_set_text(\($0[0]), (\($0[1])).s)" }
        t["getText"] = Builtin(params: [i], ret: .string) { "ws_lit(wiiui_get_text(\($0[0])))" }
        t["setVisible"] = Builtin(params: [i, p(.bool)], ret: .void, emit: call("wiiui_set_visible"))
        t["setColor"] = Builtin(params: [i, i, i, i], ret: .void, emit: call("wiiui_set_color"))
        t["frameCount"] = Builtin(params: [], ret: .int) { _ in "((int)wiiui_frame_count())" }
        t["randomInt"] = Builtin(params: [i, i], ret: .int, emit: call("ws_random_int"))
        t["exitApp"] = Builtin(params: [], ret: .void) { _ in "exit(0)" }
        t["showLog"] = Builtin(params: [p(.bool)], ret: .void, emit: call("wiiui_show_log"))
        for f in ["sqrt", "sin", "cos", "tan", "floor", "ceil", "round", "log", "exp", "atan", "asin", "acos"] { t[f] = Builtin(params: [d], ret: .double, emit: call(f)) }
        t["pow"] = Builtin(params: [d, d], ret: .double, emit: call("pow"))
        t["atan2"] = Builtin(params: [d, d], ret: .double, emit: call("atan2"))
        // Drawing (call from appOnDraw)
        t["drawRect"] = Builtin(params: [i, i, i, i] + rgba, ret: .void, emit: call("wiiui_draw_rect"))
        t["drawText"] = Builtin(params: [str, i, i, opt("size", .int, "24")] + rgba, ret: .void) {
            "wiiui_draw_text(\($0[3]), \($0[1]), \($0[2]), (\($0[0])).s, \($0[4]), \($0[5]), \($0[6]), \($0[7]))"
        }
        t["textWidth"] = Builtin(params: [str, opt("size", .int, "24")], ret: .int) { "wiiui_text_width(\($0[1]), (\($0[0])).s)" }
        t["drawSprite"] = Builtin(params: [i, i, i], ret: .void, emit: call("wiiui_draw_sprite"))
        t["drawSpriteScaled"] = Builtin(params: [i, i, i, i, i, opt("flipX", .bool, "0"), opt("flipY", .bool, "0"), opt("alpha", .int, "255")], ret: .void,
                                        emit: call("wiiui_draw_sprite_ex"))
        t["drawSpriteRegion"] = Builtin(params: Array(repeating: i, count: 9), ret: .void, emit: call("wiiui_draw_sprite_region"))
        t["spriteWidth"] = Builtin(params: [i], ret: .int, emit: call("wiiui_sprite_width"))
        t["spriteHeight"] = Builtin(params: [i], ret: .int, emit: call("wiiui_sprite_height"))
        t["playSound"] = Builtin(params: [i, opt("volume", .int, "255")], ret: .void, emit: call("wiiui_play_sound_volume"))
        t["setFrameRate"] = Builtin(params: [i], ret: .void, emit: call("wiiui_set_fps"))
        t["playMusic"] = Builtin(params: [i, opt("loop", .bool, "1")], ret: .void, emit: call("wiiui_play_music"))
        t["stopMusic"] = Builtin(params: [], ret: .void, emit: call("wiiui_stop_music"))
        t["musicPlaying"] = Builtin(params: [], ret: .bool, emit: call("wiiui_music_playing"))
        // Input
        let player = opt("player", .int, "0")
        t["held"] = Builtin(params: [p(.uint32), player], ret: .bool) { "((wiiui_held(\($0[1])) & (\($0[0]))) != 0)" }
        t["pressed"] = Builtin(params: [p(.uint32), player], ret: .bool) { "((wiiui_pressed(\($0[1])) & (\($0[0]))) != 0)" }
        t["stickX"] = Builtin(params: [player], ret: .double) { "((double)wiiui_stick_x(\($0[0])))" }
        t["stickY"] = Builtin(params: [player], ret: .double) { "((double)wiiui_stick_y(\($0[0])))" }
        t["pointerX"] = Builtin(params: [], ret: .int) { _ in "ws_pointer(0)" }
        t["pointerY"] = Builtin(params: [], ret: .int) { _ in "ws_pointer(1)" }
        t["pointerVisible"] = Builtin(params: [], ret: .bool) { _ in "wiiui_pointer(NULL, NULL)" }
        t["showCursor"] = Builtin(params: [p(.bool)], ret: .void, emit: call("wiiui_show_cursor"))
        t["overlaps"] = Builtin(params: Array(repeating: i, count: 8), ret: .bool, emit: call("wiiui_rects_overlap"))
        return t
    }

    /// SwiftUI view constructors and modifiers (see SwiftTranslator+SwiftUI.swift).
    func viewCall(_ name: String, _ args: [Arg], _ whole: Expr) throws -> (String, SType)? {
        if let why = Self.unsupportedViews[name] { throw fail(why) }
        if Self.viewConstructors.contains(name) { throw fail("'\(name)' is a view: use it inside a view's body") }
        return nil
    }
}
