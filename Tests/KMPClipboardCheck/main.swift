// Copy/paste check: Luigi Circuit's cameras, routes, start, item boxes and checkpoints copied into a
// new Double Dash course survive a BOL save + re-read (scaled), and copied back into a KMP.
//
//   find "Revolution IDE/Core" -name '*.swift' ! -path '*/Workbench/*' ! -path '*/Homebrew/*' \
//     ! -path '*/Editor/*' ! -name AppState.swift | tr '\n' '\0' | xargs -0 swiftc -O -parse-as-library \
//     -o /tmp/clipcheck "Revolution IDE/Core/Workbench/BaseGameLibrary.swift" "Revolution IDE/Core/Workbench/KMPClipboard.swift" Tests/KMPClipboardCheck/main.swift
//   /tmp/clipcheck [mkwii.iso] [common-key]

import Foundation

@main enum KMPClipboardCheck {
    static func main() throws {
        let args = CommandLine.arguments
        let roms = "\(ProcessInfo.processInfo.environment["ROMS_DIR"] ?? "Roms")/"
        let iso = args.count > 1 ? args[1] : roms + "Wii/MKWii/Mario Kart Wii (USA) (En,Fr,Es).iso"
        let key = args.count > 2 ? args[2] : roms + "Wii/Keys/common-key"
        let disc = try WiiDisc(url: URL(fileURLWithPath: iso), commonKey: [UInt8](try Data(contentsOf: URL(fileURLWithPath: key))), koreanKey: nil)
        func find(_ n: DiscNode) -> DiscNode? { n.isDirectory ? n.children.lazy.compactMap(find).first : (n.name == "beginner_course.szs" ? n : nil) }
        let (root, _) = try SZS.open(try disc.readFile(node: find(disc.root)!))
        let kmp = try KMPDocument.parse(root.children.first { $0.name == "course.kmp" }!.data!)
        var failures = 0
        func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL", what) } }

        var sel = Set<KMPSelection>()
        for i in kmp.came.indices { sel.insert(.came(i)) }
        for i in kmp.ckpt.indices { sel.insert(.ckpt(i)) }
        for i in kmp.gobj.indices { sel.insert(.gobj(i)) }
        sel.insert(.ktpt(0))
        let clip = KMPClipboard.copy(from: kmp, selection: sel)!

        let bol = BOL.newDocument()
        let result = clip.paste(into: bol)
        check(bol.came.count == kmp.came.count, "cameras \(bol.came.count) of \(kmp.came.count)")
        check(bol.ckpt.count == kmp.ckpt.count && bol.ckph.count == 1, "checkpoints pasted as one group")
        check(bol.gobj.isEmpty && result.note != nil, "objects are left out between games")
        let routesUsed = Set(kmp.came.map(\.routeID)).filter { Int($0) < kmp.poti.count }.count
        check(bol.poti.count == routesUsed, "routes \(bol.poti.count) of \(routesUsed)")
        let scale = MKWiiToMKDD.defaultScale
        check(abs(bol.ktpt[0].position.x - kmp.ktpt[0].position.x * scale) < 1e-3, "start position scaled")
        let again = try BOL.parse(BOL.serialize(bol, source: bol.bolSource!))
        check(again.came.count == bol.came.count && again.poti.count == bol.poti.count && again.ckpt.count == bol.ckpt.count, "BOL save + re-read")
        check(zip(again.came, bol.came).allSatisfy { abs($0.position.x - $1.position.x) < 1 && $0.routeID == $1.routeID }, "cameras keep position and route")

        // And back into a KMP.
        var all = Set<KMPSelection>()
        for i in again.came.indices { all.insert(.came(i)) }
        let back = KMPDocument()
        KMPClipboard.copy(from: again, selection: all)!.paste(into: back)
        check(back.came.count == again.came.count, "back to KMP")
        check(abs(back.came[0].position.x - kmp.came[0].position.x) < 1, "scaled back to the original position")
        _ = try KMPDocument.parse(back.serialize())

        // Same file: pastes beside the original.
        let before = kmp.ktpt.count
        KMPClipboard.copy(from: kmp, selection: [.ktpt(0)])!.paste(into: kmp)
        check(kmp.ktpt.count == before + 1 && kmp.ktpt.last!.position.x != kmp.ktpt[0].position.x, "same-file paste is offset")
        // The Wii's own opening pan becomes the Double Dash intro, then the parade camera.
        let intro = KMPCameraSequence.chain(in: kmp)
        let ported = try MKDDFileConvert.kmpToBOL(kmp)
        check(!intro.isEmpty && ported.came.count == intro.count + 1, "intro cameras \(ported.came.count) vs \(intro.count) + parade")
        check(ported.came.first?.startFlag == 1 && ported.came.dropLast().allSatisfy { $0.type == 5 && ported.poti.indices.contains(Int($0.routeID)) }, "intro cameras ride routes")
        check(zip(intro, ported.came).allSatisfy { abs($0.1.time - kmp.came[$0.0].time) < 1 }, "intro shot lengths kept")
        let reparsed = try BOL.parse(BOL.serialize(ported, source: ported.bolSource!))
        check(reparsed.came.count == ported.came.count, "ported cameras survive a BOL save")
        print(failures == 0 ? "ok" : "\(failures) failures")
        if failures > 0 { exit(1) }
    }
}
