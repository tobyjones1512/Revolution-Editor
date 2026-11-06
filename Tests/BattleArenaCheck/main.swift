// Battle arena check, against the retail disc:
// - every retail arena is detected as a battle arena and passes the "Custom Battle Arena"
//   verifier with no required check failing, and Make Testable finds nothing to change in it;
// - every retail race track is not a battle arena and still passes the race verifier;
// - a new battle KMP (File > New > KMP (Battle Arena)), dropped into a retail arena archive,
//   passes the verifier; and an arena stripped of start/battle respawn points is restored.
//
//   find "Revolution IDE/Core" -name '*.swift' ! -path '*/Workbench/*' ! -name AppState.swift \
//     ! -name SyntaxHighlighter.swift | tr '\n' '\0' | xargs -0 swiftc -O -parse-as-library -o /tmp/battlecheck \
//     "Revolution IDE/Core/Workbench/BaseGameLibrary.swift" Tests/BattleArenaCheck/main.swift
//   /tmp/battlecheck [mkwii.iso] [common-key]

import Foundation

@main enum BattleArenaCheck {
    static func main() throws {
        var failures = 0
        func check(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failures += 1 } }
        let args = CommandLine.arguments
        let roms = "\(ProcessInfo.processInfo.environment["ROMS_DIR"] ?? "Roms")/"
        let disc = try WiiDisc(url: URL(fileURLWithPath: args.count > 1 ? args[1] : roms + "Wii/MKWii/Mario Kart Wii (USA) (En,Fr,Es).iso"),
                               commonKey: [UInt8](try Data(contentsOf: URL(fileURLWithPath: args.count > 2 ? args[2] : roms + "Wii/Keys/common-key"))), koreanKey: nil)
        var nodes: [String: DiscNode] = [:]
        func walk(_ x: DiscNode) { if x.isDirectory { x.children.forEach(walk) } else { nodes[x.name] = x } }
        walk(disc.root)
        func kmp(_ root: U8Node) throws -> KMPDocument { try KMPDocument.parse(root.children.first { $0.name == "course.kmp" }!.data!) }
        func failed(_ r: ModVerifier.Result) -> String { r.checks.filter { $0.required && !$0.passed }.map { "\($0.label): \($0.detail)" }.joined(separator: " | ") }

        for slot in BattleArena.slots {
            let (root, _) = try SZS.open(try disc.readFile(node: nodes[slot.file]!))
            let doc = try kmp(root)
            check(BattleArena.isBattle(doc), "\(slot.name): detected as a battle arena")
            let r = ModVerifier.verify(.mkwiiBattle, root: root)
            check(r.passed, "\(slot.name): passes the battle verifier \(failed(r))")
            let fixes = BattleArena.makeTestable(doc)
            check(fixes.isEmpty, "\(slot.name): Make Testable changes nothing \(fixes)")
        }
        for name in nodes.keys.sorted() where name.hasSuffix("_course.szs") {
            let (root, _) = try SZS.open(try disc.readFile(node: nodes[name]!))
            check(!BattleArena.isBattle(try kmp(root)), "\(name): not a battle arena")
            let r = ModVerifier.verify(.mkwiiCourse, root: root)
            check(r.passed, "\(name): still passes the race verifier \(failed(r))")
        }

        // A new battle KMP inside a retail arena's archive.
        let (root, _) = try SZS.open(try disc.readFile(node: nodes["block_battle.szs"]!))
        let template = BattleArena.template()
        root.children.first { $0.name == "course.kmp" }!.data = template.serialize()
        let r = ModVerifier.verify(.mkwiiBattle, root: root)
        check(r.passed, "new battle KMP passes the verifier \(failed(r))")
        check(template.ktpt.count == 12 && template.mspt.count == 4 && template.jgpt.count == 12 && !template.enpt.isEmpty,
              "new battle KMP: 12 starts, 4 battle respawns, 12 respawns, a CPU loop")
        let reparsed = try KMPDocument.parse(template.serialize())
        check(BattleArena.isBattle(reparsed) && Set(reparsed.ktpt.map(\.playerIndex)) == Set(0..<12), "new battle KMP round-trips as a battle arena")

        // Stripped arena: Make Testable restores what's needed.
        let (venice, _) = try SZS.open(try disc.readFile(node: nodes["venice_battle.szs"]!))
        let stripped = try kmp(venice)
        stripped.ktpt.removeLast(5); stripped.mspt.removeAll()
        let fixes = BattleArena.makeTestable(stripped)
        check(stripped.ktpt.count == 12 && Set(stripped.ktpt.map(\.playerIndex)) == Set(0..<12) && stripped.mspt.count == 4,
              "stripped arena restored: \(fixes.count) fix(es)")

        if failures > 0 { exit(1) }
    }
}
