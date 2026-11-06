// Game-physics Driver's View check, against your own discs (Mario Kart Wii + key.bin, and
// optionally Mario Kart: Double Dash!!):
// - Kinoko replays a ghost frame-exact: it finishes on the ghost's own time;
// - the autopilot laps Luigi Circuit (Wii) in game physics within plausible times;
// - a Double Dash course, converted for driving, drives under the same physics.
//
//   xcodebuild -project "Revolution IDE.xcodeproj" -target kinoko-drive -configuration Release \
//     CODE_SIGNING_ALLOWED=NO SYMROOT=/tmp/kinoko-build
//   find "Revolution IDE/Core" -name '*.swift' ! -path '*/Workbench/*' ! -path '*/Homebrew/*' \
//     ! -path '*/Editor/*' ! -name AppState.swift | tr '\n' '\0' | xargs -0 swiftc -O -parse-as-library \
//     -o /tmp/kinoko-build/Release/kinokocheck "Revolution IDE/Core/Workbench/"{BaseGameLibrary,KinokoDrive}.swift \
//     Tests/KinokoDriveCheck/main.swift
//   /tmp/kinoko-build/Release/kinokocheck <mkwii.iso> <key.bin> [ghost.rkg] [mkdd.iso]
//
// The ghost's course must be on the disc (Kinoko's samples/*.rkg are retail time trials).

import Foundation
import simd

@main enum KinokoDriveCheck {
    static func main() throws {
        var failures = 0
        func check(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failures += 1 } }
        let a = CommandLine.arguments
        guard a.count >= 3 else { print("usage: kinokocheck <mkwii.iso> <key.bin> [ghost.rkg] [mkdd.iso]"); exit(2) }
        let disc = try WiiDisc(url: URL(fileURLWithPath: a[1]), commonKey: [UInt8](try Data(contentsOf: URL(fileURLWithPath: a[2]))), koreanKey: nil)
        guard let common = BaseGameLibrary.file(at: "Race/Common.szs", on: disc) else { print("no Race/Common.szs"); exit(1) }

        // A ghost finishes on its own time.
        if a.count > 3, a[3].hasSuffix(".rkg") {
            let rkg = try Data(contentsOf: URL(fileURLWithPath: a[3]))
            let id = KinokoDrive.ghostCourse(rkg)!
            let course = BaseGameLibrary.file(at: "Race/Course/\(KinokoDrive.courseNames[id]).szs", on: disc)!
            let drive = try KinokoDrive(course: course, racer: .ghost(rkg), commonSZS: common)
            var last = KinokoDrive.State()
            for _ in 0..<36_000 { guard let s = drive.step() else { break }; last = s; if s.stage == 3 { break } }
            // Header 0x04: minutes (7 bits), seconds (7), milliseconds (10).
            let t = UInt32(rkg[4]) << 16 | UInt32(rkg[5]) << 8 | UInt32(rkg[6])
            let ghostMs = Int(t >> 17) * 60_000 + Int(t >> 10 & 0x7F) * 1000 + Int(t & 0x3FF)
            check(last.stage == 3 && last.raceMs == ghostMs, "ghost replay finishes on its time: \(last.raceMs) ms vs \(ghostMs) ms \(drive.stopped ?? "")")
        }

        // The autopilot laps a Wii course.
        func lapTimes(_ course: Data, kmp: KMPDocument, kcl: KCLDocument?, unitScale: Float, name: String) throws -> [Int] {
            guard let path = DriverPath(kmp: kmp, collision: kcl) else { print("no driving line on", name); return [] }
            let drive = try KinokoDrive(course: course, racer: .live(character: 0, vehicle: 1, autoDrift: true), unitScale: unitScale, commonSZS: common)
            var pilot = Autopilot(), state = KinokoDrive.State(), laps: [Int] = [], lapStart = 0, lap = 0
            for _ in 0..<(60 * 60 * 4) {
                guard let s = drive.step(state.stage == 2 ? pilot.input(for: state, on: path) : KinokoDrive.Input()) else { break }
                state = s
                if s.lap != lap { if lap >= 1 { laps.append(s.raceMs - lapStart) }; lap = s.lap; lapStart = s.raceMs }
                if s.stage == 3 || laps.count == 3 { break }
            }
            if let stopped = drive.stopped { print("     ", name, stopped) }
            return laps
        }
        let lc = BaseGameLibrary.file(at: "Race/Course/beginner_course.szs", on: disc)!
        let (root, _) = try SZS.open(lc)
        func find(_ n: U8Node, _ name: String) -> U8Node? { n.isDirectory ? n.children.lazy.compactMap { find($0, name) }.first : (n.name == name ? n : nil) }
        let wiiLaps = try lapTimes(lc, kmp: try KMPDocument.parse(find(root, "course.kmp")!.data!), kcl: try? KCLDocument.parse(find(root, "course.kcl")!.data!), unitScale: 1, name: "Luigi Circuit")
        check(wiiLaps.count == 3 && wiiLaps.allSatisfy { (20_000...40_000).contains($0) }, "autopilot laps Luigi Circuit: \(wiiLaps) ms")

        // A Double Dash course drives under the same physics.
        if let ddISO = a.dropFirst(3).first(where: { $0.hasSuffix(".iso") }) {
            let gc = try GameCubeDisc(url: URL(fileURLWithPath: ddISO))
            func gcFile(_ n: DiscNode, _ name: String) -> DiscNode? { n.isDirectory ? n.children.lazy.compactMap { gcFile($0, name) }.first : (n.name == name ? n : nil) }
            let rarc = try RARC.open(try gc.readFile(node: gcFile(gc.root, "Luigi2.arc")!))
            let szs = try MKDDPort.drivingArchive(rarc)
            let (ddRoot, _) = try SZS.open(szs)
            func f(_ s: String) -> Data? { rarc.children.first { $0.name.lowercased().hasSuffix(s) }?.data }
            let bol = try BOL.parse(f("_course.bol")!)
            let bco = try KCLDocument.parse(f("_course.bco")!)
            _ = ddRoot
            let ddLaps = try lapTimes(szs, kmp: bol, kcl: bco, unitScale: MKDDPort.defaultScale, name: "Double Dash Luigi Circuit")
            check(!ddLaps.isEmpty && ddLaps.allSatisfy { (15_000...90_000).contains($0) }, "autopilot laps Double Dash Luigi Circuit: \(ddLaps) ms")
        }

        print(failures == 0 ? "ok" : "\(failures) failures")
        if failures > 0 { exit(1) }
    }
}
