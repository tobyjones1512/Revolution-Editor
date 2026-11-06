// Homebrew project template check: the generated project has the files a devkitPPC build needs
// (tab-indented Makefile recipes, a main source, .gitignore), is recognised as a homebrew
// project, refuses to overwrite, and names are made safe for make.
//
//   Tests/HomebrewCheck/run.sh

import Foundation

@main enum HomebrewCheck {
    static func main() throws {
        var failures = 0
        func check(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failures += 1 } }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hbcheck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        for lang in HomebrewTemplate.Language.allCases {
            let dir = try HomebrewTemplate.create(name: "Demo \(lang.title)", language: lang, in: tmp)
            let fm = FileManager.default
            check(fm.fileExists(atPath: dir.appendingPathComponent("source/\(lang.sourceName)").path), "\(lang.title): source/\(lang.sourceName)")
            check(fm.fileExists(atPath: dir.appendingPathComponent(".gitignore").path), "\(lang.title): .gitignore")
            check(HomebrewTemplate.isProject(dir), "\(lang.title): recognised as a homebrew project")
            let mk = try String(contentsOf: dir.appendingPathComponent("Makefile"), encoding: .utf8)
            check(mk.contains("\n\t@[ -d $@ ] || mkdir -p $@"), "\(lang.title): Makefile recipes are tab-indented")
            check(!mk.contains("    @$(MAKE)"), "\(lang.title): no space-indented recipes")
            check(throwsOnRecreate(lang, tmp), "\(lang.title): refuses to overwrite")
        }
        // The UI app template: designer + node files, generated code, Makefile building source/generated.
        let app = try HomebrewTemplate.create(name: "UIApp", language: .uiApp, in: tmp)
        let fm = FileManager.default
        check(fm.fileExists(atPath: app.appendingPathComponent("ui/main.wiiui").path), "UI app: ui/main.wiiui")
        check(fm.fileExists(atPath: app.appendingPathComponent("logic/main.wiinodes").path), "UI app: logic/main.wiinodes")
        check((try String(contentsOf: app.appendingPathComponent("Makefile"), encoding: .utf8)).contains("SOURCES  := source source/generated"), "UI app: Makefile builds source/generated")
        let log = try HomebrewGenerator.generate(project: app)
        check(log.last == "Generated UI code and node logic.", "generator ran (\(log))")
        for f in ["wiiui.h", "wiiui.c", "ui_generated.h", "ui_generated.c", "logic_generated.c"] {
            check(fm.fileExists(atPath: app.appendingPathComponent("source/generated/\(f)").path), "generated \(f)")
        }
        // The Swift app template: Swift sources are translated during generation.
        let sw = try HomebrewTemplate.create(name: "SwiftApp", language: .swiftApp, in: tmp)
        check(fm.fileExists(atPath: sw.appendingPathComponent("swift/main.swift").path), "Swift app: swift/main.swift")
        let swLog = try HomebrewGenerator.generate(project: sw)
        check(swLog.contains("Translated 1 Swift file to C."), "Swift app: translated (\(swLog))")
        check(fm.fileExists(atPath: sw.appendingPathComponent("source/generated/swift_generated.c").path), "Swift app: swift_generated.c written")
        // Swift and the node graph can't both handle the same hook.
        try fm.createDirectory(at: app.appendingPathComponent("swift"), withIntermediateDirectories: true)
        try Data("func appOnButton(_ id: Int) {}\n".utf8).write(to: app.appendingPathComponent("swift/x.swift"))
        do { _ = try HomebrewGenerator.generate(project: app); check(false, "Swift + node graph on the same hook is rejected") }
        catch { check("\(error.localizedDescription)".contains("Both the node graph and the Swift code"), "Swift + node graph on the same hook is rejected") }
        try fm.removeItem(at: app.appendingPathComponent("swift"))
        try? fm.removeItem(at: app.appendingPathComponent("source/generated/swift_generated.c"))
        // The SwiftUI template generates the layout runtime too.
        let sui = try HomebrewTemplate.create(name: "SUI", language: .swiftUIApp, in: tmp)
        let suiLog = try HomebrewGenerator.generate(project: sui)
        check(suiLog.contains("Translated 1 Swift file to C."), "SwiftUI app: translated (\(suiLog))")
        check(fm.fileExists(atPath: sui.appendingPathComponent("source/generated/wui.c").path) && fm.fileExists(atPath: sui.appendingPathComponent("source/generated/wui.h").path), "SwiftUI app: wui.c and wui.h written")
        if let dir = ProcessInfo.processInfo.environment["HB_KEEP_SUI"] { try? fm.removeItem(atPath: dir); try fm.copyItem(at: sui, to: URL(fileURLWithPath: dir)) }
        // The game templates: assets are found and everything generates.
        for kind in [HomebrewTemplate.Language.gameC, .gameSwift, .gameNodes] {
            let g = try HomebrewTemplate.create(name: "Game_\(kind.rawValue)", language: kind, in: tmp)
            check(fm.fileExists(atPath: g.appendingPathComponent("assets/ball.png").path) && fm.fileExists(atPath: g.appendingPathComponent("assets/blip.wav").path), "\(kind.title): sample sprite and sound")
            let gl = try HomebrewGenerator.generate(project: g)
            check(gl.contains("Assets: 1 sprite, 1 sound."), "\(kind.title): generates with its assets (\(gl))")
            check((try String(contentsOf: g.appendingPathComponent("Makefile"), encoding: .utf8)).contains("-lasnd"), "\(kind.title): Makefile links the sound library")
            if kind == .gameSwift, let dir = ProcessInfo.processInfo.environment["HB_KEEP_GAME"] { try? fm.removeItem(atPath: dir); try fm.copyItem(at: g, to: URL(fileURLWithPath: dir)) }
        }
        let plain = try HomebrewTemplate.create(name: "Plain", language: .c, in: tmp)
        check(try HomebrewGenerator.generate(project: plain).isEmpty && !fm.fileExists(atPath: plain.appendingPathComponent("source/generated").path), "plain project: generator does nothing")
        // A design referencing a bad widget in the graph must fail the build with a reason.
        var g = NodeGraph.sample(); g.nodes[0].params["widget"] = "ghost"
        try g.serialize().write(to: app.appendingPathComponent("logic/main.wiinodes"))
        do { _ = try HomebrewGenerator.generate(project: app); check(false, "bad widget fails generation") }
        catch { check("\(error.localizedDescription)".contains("ghost"), "bad widget fails generation, naming it") }
        if let dir = ProcessInfo.processInfo.environment["HB_KEEP"] { try? fm.removeItem(atPath: dir); try fm.copyItem(at: app, to: URL(fileURLWithPath: dir)) }
        check(HomebrewTemplate.safeName("My Game (v2)!") == "My_Game__v2__", "safeName replaces spaces/punctuation")
        check(HomebrewTemplate.safeName("") == "homebrew", "safeName of empty")
        check(!HomebrewTemplate.isProject(tmp), "plain folder isn't a project")
        print(failures == 0 ? "ALL OK" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    static func throwsOnRecreate(_ lang: HomebrewTemplate.Language, _ tmp: URL) -> Bool {
        (try? HomebrewTemplate.create(name: "Demo \(lang.title)", language: lang, in: tmp)) == nil
    }
}
