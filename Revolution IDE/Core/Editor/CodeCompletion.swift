import Foundation

/// Suggestions for the code editor's completion popup: the language's keywords, the app's own API
/// (the Wii runtime for C/C++, the Swift builtins for homebrew Swift), and words already in the file.
nonisolated enum CodeCompletion {
    /// Candidates that start with `prefix`, best first.
    static func candidates(prefix: String, language: CodeLanguage, text: String) -> [String] {
        guard !prefix.isEmpty else { return [] }
        var pool = Set(SyntaxHighlighter.keywords(for: language))
        pool.formUnion(api(for: language))
        var counts: [String: Int] = [:]
        for word in identifiers(in: text) { counts[word, default: 0] += 1 }
        pool.formUnion(counts.keys)
        let lower = prefix.lowercased()
        let matches = pool.filter { $0.count > prefix.count && $0.lowercased().hasPrefix(lower) }
        return matches.sorted { a, b in
            let ae = a.hasPrefix(prefix), be = b.hasPrefix(prefix)       // same capitalisation first
            if ae != be { return ae }
            let ac = counts[a, default: 0], bc = counts[b, default: 0]    // then words used in this file
            if (ac > 0) != (bc > 0) { return ac > 0 }
            if a.count != b.count { return a.count < b.count }
            return a < b
        }
        .prefix(40).map { $0 }
    }

    private static func identifiers(in text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for u in text.unicodeScalars {
            if (u.value >= 65 && u.value <= 90) || (u.value >= 97 && u.value <= 122) || u.value == 95 || (u.value >= 48 && u.value <= 57 && !current.isEmpty) || u.value > 127 {
                current.unicodeScalars.append(u)
            } else if !current.isEmpty {
                if current.count >= 3 { out.append(current) }
                current = ""
            }
        }
        if current.count >= 3 { out.append(current) }
        return out
    }

    private static func symbols(in text: String, prefixes: [String]) -> Set<String> {
        var found = Set<String>()
        for word in identifiers(in: text) where prefixes.contains(where: { word.hasPrefix($0) }) { found.insert(word) }
        return found
    }

    static func api(for language: CodeLanguage) -> Set<String> {
        switch language {
        case .c, .cpp, .objc: return cAPI
        case .swift: return swiftAPI
        default: return []
        }
    }

    private static let cAPI: Set<String> = {
        var s = symbols(in: WiiUIRuntime.header, prefixes: ["wiiui_", "WIIUI_", "wgfx_", "WGFX_"])
        s.formUnion(symbols(in: WiiUIRuntime.nodeSupport, prefixes: ["wn_"]))
        s.formUnion([
            "printf", "snprintf", "sprintf", "malloc", "calloc", "realloc", "free", "memset", "memcpy", "memmove", "strlen", "strcmp",
            "strncmp", "strcpy", "strncpy", "strcat", "strstr", "atoi", "atof", "rand", "srand", "abs", "sqrt", "sqrtf", "sin", "cos", "tan",
            "atan2", "floor", "ceil", "fabs", "pow", "exit", "stdio.h", "stdlib.h", "string.h", "math.h", "gccore.h", "wiiuse/wpad.h",
            "WPAD_Init", "WPAD_ScanPads", "WPAD_ButtonsDown", "WPAD_ButtonsHeld", "WPAD_ButtonsUp", "WPAD_SetDataFormat", "WPAD_SetVRes",
            "WPAD_BUTTON_A", "WPAD_BUTTON_B", "WPAD_BUTTON_1", "WPAD_BUTTON_2", "WPAD_BUTTON_PLUS", "WPAD_BUTTON_MINUS", "WPAD_BUTTON_HOME",
            "WPAD_BUTTON_UP", "WPAD_BUTTON_DOWN", "WPAD_BUTTON_LEFT", "WPAD_BUTTON_RIGHT", "WPAD_FMT_BTNS_ACC_IR",
            "PAD_Init", "PAD_ScanPads", "PAD_ButtonsDown", "PAD_ButtonsHeld", "PAD_StickX", "PAD_StickY", "PAD_BUTTON_A", "PAD_BUTTON_B",
            "VIDEO_Init", "VIDEO_Configure", "VIDEO_Flush", "VIDEO_WaitVSync", "VIDEO_SetNextFramebuffer", "VIDEO_SetBlack",
            "VIDEO_GetPreferredMode", "SYS_AllocateFramebuffer", "console_init", "ASND_Init", "ASND_Pause", "ASND_SetVoice",
            "ASND_StopVoice", "ASND_GetFirstUnusedVoice", "GX_Init", "GX_ClearVtxDesc", "GX_SetVtxDesc", "GX_Begin", "GX_End",
            "GX_Position3f32", "GX_Color4u8", "GX_TexCoord2f32", "GX_CopyDisp", "GX_DrawDone", "GX_SetViewport", "GX_SetScissor",
            "GXRModeObj", "GXColor", "GXTexObj", "Mtx", "Mtx44", "guMtxIdentity", "guOrtho", "u8", "u16", "u32", "u64", "s8", "s16",
            "s32", "s64", "f32", "f64", "bool", "size_t", "NULL", "app_on_start", "app_on_frame", "app_on_draw", "app_on_button", "app_on_wpad",
        ])
        return s
    }()

    private static let swiftAPI: Set<String> = {
        var s = Set(SwiftTranslator.makeBuiltins().keys)
        s.formUnion([
            "appOnStart", "appOnFrame", "appOnDraw", "appOnButton", "appOnWpad", "UI", "Sprite", "Sound", "Music", "Button",
            "print", "String", "Int", "Int32", "UInt32", "UInt8", "Double", "Float", "Bool", "Array", "Dictionary", "Optional", "Character",
            "count", "isEmpty", "append", "remove", "removeAll", "insert", "first", "last", "contains", "sorted", "reversed", "filter",
            "map", "reduce", "forEach", "min", "max", "abs", "sqrt", "sin", "cos", "random", "randomElement", "shuffled", "joined",
            "split", "hasPrefix", "hasSuffix", "uppercased", "lowercased", "enumerated", "indices", "zip", "stride", "fatalError", "precondition",
            "View", "Text", "VStack", "HStack", "ZStack", "Spacer", "Toggle", "Slider", "List", "ForEach", "State", "Binding", "padding",
            "font", "foregroundColor", "background", "frame", "disabled", "onTapGesture", "Color", "Image", "Divider", "Section",
        ])
        return s
    }()
}
