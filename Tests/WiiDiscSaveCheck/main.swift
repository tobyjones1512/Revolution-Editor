// Wii disc save check: replaces files inside a *copy* of a Wii disc image the way saving a
// disc-entry tab does (`FileOperations.replace`), once with a larger file (relocated into
// free space), once with a smaller one in place, then has
// `wiihash.py` (an independent reader written from the disc format, not this app's code) verify
// what a real Wii checks on every read: the H0/H1/H2 hash tree of each touched cluster, the H3
// table, the TMD's hash of it (H4), and that every file lies inside the partition's data.
// Dolphin checks none of these, so a disc that fails here still plays there.
//
//   find "Revolution IDE/Core" -name '*.swift' ! -path '*/Workbench/*' ! -name AppState.swift \
//     ! -name SyntaxHighlighter.swift -print0 | xargs -0 swiftc -O -parse-as-library -o /tmp/wiisave \
//     "Revolution IDE/Core/Workbench/BaseGameLibrary.swift" Tests/WiiDiscSaveCheck/main.swift
//   cp -c mkwii.iso /tmp/copy.iso; /tmp/wiisave /tmp/copy.iso common-key course.szs

import Foundation

@main enum WiiDiscSaveCheck {
    static func main() throws {
        let a = CommandLine.arguments
        let iso = URL(fileURLWithPath: a[1]), keyPath = a[2]
        let course = try Data(contentsOf: URL(fileURLWithPath: a[3]))
        let key = [UInt8](try Data(contentsOf: URL(fileURLWithPath: keyPath)).prefix(16))

        func node(_ name: String, in disc: WiiDisc) -> DiscNode? {
            var stack: [DiscNode] = [disc.root]
            while let n = stack.popLast() {
                if n.isFile, n.name == name, n.partitionIndex.map({ disc.partitions[$0].entry.kind == .data }) == true { return n }
                stack += n.children
            }
            return nil
        }
        func replace(_ name: String, with data: Data) throws {
            let disc = try WiiDisc(url: iso, commonKey: key, koreanKey: nil)
            guard let n = node(name, in: disc) else { print("FAIL \(name) not found"); exit(1) }
            try FileOperations.replace(discURL: iso, disc: disc, node: n, newData: data) { print("   ", $0) }
            // Read back through the app too: the bytes must round-trip.
            let check = try WiiDisc(url: iso, commonKey: key, koreanKey: nil)
            let back = try check.readFile(node: node(name, in: check)!)
            print(back == data ? "ok  " : "FAIL", "\(name) reads back (\(data.count) bytes)")
            if back != data { exit(1) }
        }
        // Larger than the original -> relocated into free space.
        try replace("beginner_course.szs", with: course)
        try replace("beginner_course_d.szs", with: course + Data(count: 1_500_000))
        // Smaller -> written in place.
        try replace("castle_course.szs", with: course.prefix(1000))

        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("wiihash.py").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", script, iso.path, keyPath, "beginner_course.szs", "beginner_course_d.szs", "castle_course.szs"]
        try p.run(); p.waitUntilExit()
        print(p.terminationStatus == 0 ? "ok   independent hash-tree check" : "FAIL independent hash-tree check")
        exit(p.terminationStatus)
    }
}
