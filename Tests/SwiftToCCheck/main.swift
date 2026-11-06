// Swift -> C translator check. Translates sample.swift and the starter game, writes the C beside
// the runtime, and checks that bad programs are rejected with a useful file:line:col message.
// run.sh then compiles the generated C against host stand-ins and runs it.
//
//   Tests/SwiftToCCheck/run.sh

import Foundation

@main enum SwiftToCCheck {
    static func translate(_ src: String, widgets: [String] = ["title", "status", "go"], sprites: [String] = ["ball"], sounds: [String] = ["blip"], testing: Bool = false) throws -> SwiftEmitter.Output {
        var prog = SwiftProgram()
        try SwiftParser.parse(source: src, file: "swift/test.swift", into: &prog)
        return try SwiftEmitter.emit(prog, widgets: widgets, sprites: sprites, sounds: sounds, testing: testing)
    }

    static func writeRuntime(_ ui: UICodegen.Output, to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, text) in [("ws.h", WiiUIRuntime.swiftSupport), ("wn.h", WiiUIRuntime.nodeHeader), ("wiiui.h", WiiUIRuntime.header),
                             ("wiiui.c", WiiUIRuntime.source), ("wgfx.h", WiiUIRuntime.gfxHeader), ("wgfx_gx.c", WiiUIRuntime.gfxSourceGX),
                             ("ui_generated.h", ui.header), ("ui_generated.c", ui.source)] {
            try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    static func main() throws {
        let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/hbswift")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var failures = 0
        func check(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failures += 1 } }

        // 1. The feature sample, with the sample UI.
        let sample = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
        let out = try translate(sample)
        check(out.hooks == ["app_on_start", "app_on_button", "app_on_wpad"], "hooks found: \(out.hooks.sorted())")
        try writeRuntime(UICodegen.generate(UIDocument.sample(), projectRoot: dir), to: dir)
        try out.source.write(to: dir.appendingPathComponent("swift_generated.c"), atomically: true, encoding: .utf8)

        // 2. The starter games: Swift and C, with their generated sprite and sound.
        let game = dir.appendingPathComponent("game")
        try HomebrewSamples.writeAssets(into: game)
        let gameUI = UICodegen.generate(UIDocument(background: RGB(r: 0.05, g: 0.07, b: 0.12), widgets: []), projectRoot: game)
        check(gameUI.warnings.isEmpty, "game assets: no warnings \(gameUI.warnings)")
        try writeRuntime(gameUI, to: game)
        let gameOut = try translate(HomebrewSamples.gameSwift, widgets: [], sprites: gameUI.spriteNames, sounds: gameUI.soundNames)
        check(gameOut.hooks == ["app_on_frame", "app_on_draw"], "starter game hooks: \(gameOut.hooks.sorted())")
        try gameOut.source.write(to: game.appendingPathComponent("swift_generated.c"), atomically: true, encoding: .utf8)
        try HomebrewSamples.gameC.write(to: game.appendingPathComponent("game_c.c"), atomically: true, encoding: .utf8)

        // 2b. The language test suite, which checks itself when run.
        let lang = dir.appendingPathComponent("lang")
        try writeRuntime(UICodegen.generate(UIDocument.sample(), projectRoot: dir), to: lang)
        let langSource = try String(contentsOfFile: CommandLine.arguments[3], encoding: .utf8)
        let langOut = try translate(langSource, testing: true)
        try langOut.source.write(to: lang.appendingPathComponent("swift_generated.c"), atomically: true, encoding: .utf8)
        check(true, "language suite translated")

        // 2c. A SwiftUI app
        let ui = dir.appendingPathComponent("swiftui")
        try writeRuntime(UICodegen.generate(UIDocument(background: RGB(r: 0.05, g: 0.07, b: 0.12), widgets: []), projectRoot: dir), to: ui)
        let uiSource = try String(contentsOfFile: CommandLine.arguments[4], encoding: .utf8)
        let uiOut = try translate(uiSource, widgets: [], testing: true)
        check(uiOut.usesWui && uiOut.hooks.contains("app_on_draw"), "SwiftUI app translated")
        try uiOut.source.write(to: ui.appendingPathComponent("swift_generated.c"), atomically: true, encoding: .utf8)
        try WuiRuntime.header.write(to: ui.appendingPathComponent("wui.h"), atomically: true, encoding: .utf8)
        try WuiRuntime.source.write(to: ui.appendingPathComponent("wui.c"), atomically: true, encoding: .utf8)

        // 2d. The SwiftUI template's own sample app
        let tpl = dir.appendingPathComponent("swiftui_template")
        try writeRuntime(UICodegen.generate(UIDocument(background: RGB(r: 0.05, g: 0.07, b: 0.12), widgets: []), projectRoot: dir), to: tpl)
        let tplOut = try translate(HomebrewSamples.swiftUI, widgets: [], testing: true)
        try tplOut.source.write(to: tpl.appendingPathComponent("swift_generated.c"), atomically: true, encoding: .utf8)
        try WuiRuntime.header.write(to: tpl.appendingPathComponent("wui.h"), atomically: true, encoding: .utf8)
        try WuiRuntime.source.write(to: tpl.appendingPathComponent("wui.c"), atomically: true, encoding: .utf8)

        // 3. Programs that must be rejected, with the message (and line) they should produce.
        let bad: [(String, String, Int)] = [
            ("func f() {\n    let x: Int = 3.5\n}", "cannot convert value of type 'Double' to expected type 'Int'", 2),
            ("func f() {\n    let a = 1\n    let b = 2.0\n    let c = a + b\n}", "cannot be applied to operands of type 'Int' and 'Double'", 4),
            ("func f() {\n    nothing()\n}", "cannot find 'nothing' in scope", 2),
            ("func f() {\n    let x = 5\n    x = 6\n}", "'let' constant", 3),
            ("protocol P {}\nextension P {}", "protocol extensions aren't supported", 2),
            ("class A: B {}", "cannot find the protocol 'B'", 1),
            ("class A {}\nclass B: A {}", "inheritance isn't supported", 2),
            ("protocol P { func f() }\nstruct S: P {}\nfunc g() { let x: P = S() }", "doesn't conform to 'P'", 2),
            ("func f<T>() -> Int { 1 }\nfunc g() { let y = f() }", "work out the type for 'T'", 2),
            ("enum E { case a(Int), b }\nfunc f(_ e: E) -> Bool { e == .b }", "enums with values can't be compared", 2),
            ("func f() {\n    defer { }\n}", "defer isn't supported", 2),
            ("func f() {\n    let x = try g()\n}", "errors (try/throw) aren't supported", 2),
            ("func f() -> Int {\n    return \"a\"\n}", "cannot convert", 2),
            ("enum E { case a, b }\nfunc f(_ e: E) {\n    switch e {\n    case .a: break\n    }\n}", "exhaustive", 3),
            ("func f() {\n    setText(UI.nope, \"x\")\n}", "no widget named 'nope'", 2),
            ("func appOnButton() {}", "appOnButton must be declared", 1),
            ("func g(a: Int) {}\nfunc f() {\n    g(1)\n}", "expects the label 'a:'", 3),
            ("struct S {\n    var n = 0\n    func bump() { n += 1 }\n}", "mutating", 3),
            ("func f() {\n    var n: Int? = nil\n    n = \"x\"\n}", "cannot convert value of type 'String' to expected type 'Int?'", 3),
            ("func f() {\n    let s = \"abc\"\n    if s { }\n}", "must be a Bool", 3),
            ("func f() {\n    for i in 0..<3 {\n        i = 2\n    }\n}", "'let' constant", 3),
            ("func f() {\n    let x = \"unterminated\n}", "unterminated string", 2),
            ("func f() {\n    drawSprite(Sprite.nope, 0, 0)\n}", "no sprite named 'nope'", 2),
            ("func f() {\n    playSound(Sound.nope)\n}", "no sound named 'nope'", 2),
            ("func f() {\n    drawRect(1, 2, 3)\n}", "takes an unlabeled argument here", 2),
            ("func f() {\n    drawRect(1, 2, 3, 4, g: 5, r: 6)\n}", "extra argument", 2),
            ("func f() {\n    let h = held(1.5)\n}", "cannot convert", 2),
        ]
        for (src, want, line) in bad {
            do { _ = try translate(src); check(false, "rejects: \(want)") }
            catch {
                let msg = error.localizedDescription
                let ok = msg.contains(want) && msg.hasPrefix("swift/test.swift:\(line):")
                check(ok, "rejects (line \(line)): \(want)")
                if !ok { print("     got: \(msg)") }
            }
        }
        // Optional arguments left out use their defaults.
        let defaults = try translate("func appOnDraw() {\n    drawRect(1, 2, 3, 4)\n    drawText(\"hi\", 5, 6)\n    playSound(Sound.blip)\n}")
        check(defaults.source.contains("wiiui_draw_rect(1, 2, 3, 4, 255, 255, 255, 255)") && defaults.source.contains("wiiui_draw_text(24, 5, 6,"), "default arguments are filled in")
        print(failures == 0 ? "TRANSLATED OK" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
