// Checkpoint/lap verifier check: every retail Mario Kart Wii race course must verify with no
// errors and count every lap driven, and every Double Dash port must too. Also breaks a retail
// course on purpose (swaps one checkpoint's left/right, drops a key) and requires the errors.
//
//   find "Revolution IDE/Core" -name '*.swift' ! -path '*/Workbench/*' ! -name AppState.swift \
//     ! -name SyntaxHighlighter.swift | tr '\n' '\0' | xargs -0 swiftc -O -parse-as-library -o /tmp/ckptcheck \
//     "Revolution IDE/Core/Workbench/BaseGameLibrary.swift" Tests/CheckpointCheck/main.swift
//   /tmp/ckptcheck [mkwii.iso] [common-key] [mkdd.iso]

import Foundation

@main enum CheckpointCheck {
    static func main() throws {
        let args = CommandLine.arguments
        let roms = "\(ProcessInfo.processInfo.environment["ROMS_DIR"] ?? "Roms")/"
        let iso = args.count > 1 ? args[1] : roms + "Wii/MKWii/Mario Kart Wii (USA) (En,Fr,Es).iso"
        let key = args.count > 2 ? args[2] : roms + "Wii/Keys/common-key"
        let gcIso = args.count > 3 ? args[3] : roms + "GCN/MKDD/Mario Kart - Double Dash!! (USA).iso"
        var failures = 0
        func report(_ name: String, _ r: CheckpointVerifier.Report) {
            let errors = r.issues.filter { $0.severity == .error }
            let ok = errors.isEmpty && r.loopsDriven >= 3 && r.lapsCounted == r.loopsDriven
            if !ok { failures += 1 }
            print(ok ? "ok  " : "FAIL", name, "laps \(r.lapsCounted)/\(r.loopsDriven)", errors.map(\.message).joined(separator: " | "))
            for w in r.issues where w.severity == .warning { print("      warning:", w.message) }
        }

        let disc = try WiiDisc(url: URL(fileURLWithPath: iso), commonKey: [UInt8](try Data(contentsOf: URL(fileURLWithPath: key))), koreanKey: nil)
        var courses: [DiscNode] = []
        func walk(_ n: DiscNode) { if n.isDirectory { n.children.forEach(walk) } else if n.name.hasSuffix("_course.szs") { courses.append(n) } }
        walk(disc.root)
        var sample: KMPDocument?
        for node in courses {
            let (root, _) = try SZS.open(try disc.readFile(node: node))
            guard let data = root.children.first(where: { $0.name == "course.kmp" })?.data else { continue }
            let doc = try KMPDocument.parse(data)
            report(node.name, CheckpointVerifier.verify(doc))
            if node.name == "beginner_course.szs" { sample = doc }
        }

        // Deliberately broken copies must be caught.
        if let doc = sample {
            let swapped = try KMPDocument.parse(doc.serialize())
            let c5 = swapped.ckpt[5]; swapped.ckpt[5].left = c5.right; swapped.ckpt[5].right = c5.left
            let r1 = CheckpointVerifier.verify(swapped)
            let caught1 = r1.issues.contains { $0.severity == .error && $0.checkpoint != nil }
            print(caught1 ? "ok  " : "FAIL", "swapped checkpoint 5 is reported")
            if !caught1 { failures += 1 }
            let noKey = try KMPDocument.parse(doc.serialize())
            // Moving the last key to a spot the route never passes makes every lap fail.
            let last = noKey.ckpt.map(\.lapCounterType).max()!
            if let k = noKey.ckpt.firstIndex(where: { $0.lapCounterType == last }) { noKey.ckpt[k].lapCounterType = -1 }
            noKey.ckpt[noKey.ckpt.count - 1].lapCounterType = -1
            noKey.ckpt.append(CKPTEntry(left: Vec2(x: 1e6, y: 1e6), right: Vec2(x: 1e6 + 10, y: 1e6), respawnIndex: 0, lapCounterType: last))
            let r2 = CheckpointVerifier.verify(noKey)
            // The game counts the first crossing (lap 0 -> 1) regardless; every later one must fail.
            let caught2 = r2.loopsDriven >= 3 && r2.lapsCounted == 1
            print(caught2 ? "ok  " : "FAIL", "unreachable last key: only the starting crossing counts")
            if !caught2 { failures += 1 }
        }

        let gc = try GameCubeDisc(url: URL(fileURLWithPath: gcIso))
        func walkGC(_ n: DiscNode, _ p: String) throws {
            if n.isDirectory { for c in n.children { try walkGC(c, p + "/" + c.name) }; return }
            let base = (n.name as NSString).deletingPathExtension
            guard p.contains("/Course/"), n.name.hasSuffix(".arc"), !base.hasSuffix("L"), !base.hasPrefix("Mini"),
                  !["Award", "Ending"].contains(base) else { return }
            let result = try MKDDPort.port(try gc.readFile(node: n), name: base)
            let (root, _) = try SZS.open(result.archive)
            report("port " + base, CheckpointVerifier.verify(try KMPDocument.parse(root.children.first { $0.name == "course.kmp" }!.data!)))
        }
        try walkGC(gc.root, "")
        print(failures == 0 ? "all passed" : "\(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
