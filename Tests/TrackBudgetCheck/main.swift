// Track budget check: re-measures every retail course/skybox/minimap model (all race tracks and
// battle arenas; `*_d.szs` duplicates and the old_mario_gc_* prototype test courses excluded) and
// requires `TrackBudget.reference` to hold exactly those medians and maxima.
//
//   find "Revolution IDE/Core" -name '*.swift' ! -path '*/Workbench/*' ! -name AppState.swift \
//     ! -name SyntaxHighlighter.swift | tr '\n' '\0' | xargs -0 swiftc -O -parse-as-library -o /tmp/budgetcheck \
//     "Revolution IDE/Core/Workbench/BaseGameLibrary.swift" Tests/TrackBudgetCheck/main.swift
//   /tmp/budgetcheck [mkwii.iso] [common-key]

import Foundation

@main enum TrackBudgetCheck {
    static func main() throws {
        let args = CommandLine.arguments
        let roms = "\(ProcessInfo.processInfo.environment["ROMS_DIR"] ?? "Roms")/"
        let iso = args.count > 1 ? args[1] : roms + "Wii/MKWii/Mario Kart Wii (USA) (En,Fr,Es).iso"
        let key = args.count > 2 ? args[2] : roms + "Wii/Keys/common-key"
        let disc = try WiiDisc(url: URL(fileURLWithPath: iso), commonKey: [UInt8](try Data(contentsOf: URL(fileURLWithPath: key))), koreanKey: nil)
        var courses: [DiscNode] = []
        func walk(_ n: DiscNode) {
            if n.isDirectory { n.children.forEach(walk) }
            else if (n.name.hasSuffix("_course.szs") || n.name.hasPrefix("old_")) && !n.name.hasPrefix("old_mario_gc_") && !n.name.hasSuffix("_d.szs") { courses.append(n) }
        }
        walk(disc.root)
        var values: [TrackBudget.Kind: [TrackBudget.Metric: [Int]]] = [:]
        let files: [(String, String, TrackBudget.Kind)] = [("course_model.brres", "course", .course), ("vrcorn_model.brres", "vrcorn", .skybox), ("map_model.brres", "map", .minimap)]
        for node in courses {
            let (root, _) = try SZS.open(try disc.readFile(node: node))
            for (file, name, kind) in files {
                guard let data = root.children.first(where: { $0.name == file })?.data, let doc = try? BRRESDocument.parse(data),
                      let r = doc.resources.first(where: { $0.magic == "MDL0" && $0.name == name }), let m = MDL0Parser.parse(r, rawFile: doc.rawData) else { continue }
                values[kind, default: [:]][.triangles, default: []].append(m.meshes.reduce(0) { $0 + $1.vertices.count / 3 })
                values[kind, default: [:]][.vertices, default: []].append(Int(r.data.be32(0x5C)))
                values[kind, default: [:]][.meshes, default: []].append(m.meshes.count)
                values[kind, default: [:]][.textureKB, default: []].append(doc.resources.filter { $0.magic == "TEX0" }.reduce(0) { $0 + $1.data.count } / 1024)
            }
        }
        var failures = 0
        for kind in TrackBudget.Kind.allCases {
            for metric in TrackBudget.Metric.allCases {
                let v = (values[kind]?[metric] ?? []).sorted()
                guard !v.isEmpty else { failures += 1; print("FAIL", kind, metric, "no data"); continue }
                let median = v.count % 2 == 1 ? v[v.count / 2] : (v[v.count / 2 - 1] + v[v.count / 2]) / 2
                let measured = (median: median, max: v.last!)
                let table = TrackBudget.reference(kind, metric)
                let ok = table == measured
                if !ok { failures += 1 }
                print(ok ? "ok  " : "FAIL", kind.rawValue, metric.rawValue, "measured \(measured) table \(table) over \(v.count) courses")
            }
        }
        if failures > 0 { exit(1) }
    }
}
