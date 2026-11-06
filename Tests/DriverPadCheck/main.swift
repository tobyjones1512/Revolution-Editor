// Driver's View pad check: builds every retail course's DriverPath and lists the boost panels,
// boost ramps and jump pads its line crosses. Mushroom Gorge must find jump pads (its bouncy
// mushrooms) and Rainbow Road both boost panels and boost ramps. Also checks route forks: every
// option at every fork must build a path that still contains that fork and takes the option.
//
//   find "Revolution IDE/Core" -name '*.swift' ! -path '*/Workbench/*' ! -name AppState.swift \
//     ! -name SyntaxHighlighter.swift | tr '\n' '\0' | xargs -0 swiftc -O -parse-as-library -o /tmp/padcheck \
//     "Revolution IDE/Core/Workbench/BaseGameLibrary.swift" Tests/DriverPadCheck/main.swift
//   /tmp/padcheck [mkwii.iso] [common-key]

import Foundation

@main enum DriverPadCheck {
    static func main() throws {
        let args = CommandLine.arguments
        let roms = "\(ProcessInfo.processInfo.environment["ROMS_DIR"] ?? "Roms")/"
        let iso = args.count > 1 ? args[1] : roms + "Wii/MKWii/Mario Kart Wii (USA) (En,Fr,Es).iso"
        let key = args.count > 2 ? args[2] : roms + "Wii/Keys/common-key"
        let disc = try WiiDisc(url: URL(fileURLWithPath: iso), commonKey: [UInt8](try Data(contentsOf: URL(fileURLWithPath: key))), koreanKey: nil)
        var courses: [DiscNode] = []
        func walk(_ n: DiscNode) { if n.isDirectory { n.children.forEach(walk) } else if n.name.hasSuffix("_course.szs") { courses.append(n) } }
        walk(disc.root)
        var kinds: [String: Set<String>] = [:]
        var forkFailures = 0, forkCourses = 0
        for node in courses {
            let (root, _) = try SZS.open(try disc.readFile(node: node))
            guard let kmp = root.children.first(where: { $0.name == "course.kmp" })?.data,
                  let kcl = root.children.first(where: { $0.name == "course.kcl" })?.data,
                  let path = DriverPath(kmp: try KMPDocument.parse(kmp), collision: try KCLDocument.parse(kcl)) else { continue }
            // Count runs (entering a pad), not samples.
            var counts: [String: Int] = [:]
            let n = path.points.count
            for (i, pad) in path.pads where path.pads[(i - 1 + n) % n] != pad {
                let k: String
                switch pad { case .boost: k = "boost"; case .ramp: k = "ramp"; case .jump: k = "jump" }
                counts[k, default: 0] += 1
            }
            kinds[node.name] = Set(counts.keys)
            let doc = try KMPDocument.parse(kmp), coll = try KCLDocument.parse(kcl)
            var forkText: [String] = []
            for fork in path.forks.values {
                for option in fork.options {
                    guard let alt = DriverPath(kmp: doc, collision: coll, choices: [fork.group: option.group]),
                          alt.forks.values.contains(where: { $0.group == fork.group && $0.chosen == option.group }) else {
                        print("FAIL", node.name, "fork after group", fork.group, "option", option.group); forkFailures += 1; continue
                    }
                }
                forkText.append("g\(fork.group)->" + fork.options.map { "\($0.group) \($0.label)" }.joined(separator: "/"))
            }
            if !forkText.isEmpty { forkCourses += 1 }
            print(node.name, counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "), forkText.joined(separator: "  "))
        }
        var failures = 0
        for (course, need) in [("kinoko_course.szs", ["jump"]), ("rainbow_course.szs", ["boost", "ramp"])] {
            let ok = Set(need).isSubset(of: kinds[course] ?? [])
            print(ok ? "ok  " : "FAIL", course, "has", need.joined(separator: " + "))
            if !ok { failures += 1 }
        }
        print("\(forkCourses) courses have route forks; \(forkFailures) fork options failed")
        if forkCourses == 0 { failures += 1 }
        if failures + forkFailures > 0 { exit(1) }
    }
}
