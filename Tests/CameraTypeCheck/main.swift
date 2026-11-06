// Camera type check (no discs needed): Double Dash camera types are u16 (0x000-0x008, 0x100-0x103),
// a BOL save + re-read keeps the high byte, and Wii replay cameras port to the Double Dash kinds
// that aim at the player (and back).
//
//   find "Revolution IDE/Core" -name '*.swift' ! -path '*/Workbench/*' ! -path '*/Homebrew/*' \
//     ! -path '*/Editor/*' ! -name AppState.swift | tr '\n' '\0' | xargs -0 swiftc -O -parse-as-library \
//     -o /tmp/camcheck "Revolution IDE/Core/Workbench/BaseGameLibrary.swift" Tests/CameraTypeCheck/main.swift
//   /tmp/camcheck

import Foundation

@main enum CameraTypeCheck {
    static func main() throws {
        var failures = 0
        func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL", what); failures += 1 } }

        // Wii course: one replay camera of each kind (0 Goal .. 4 KartPathFollow), each with its own area.
        let kmp = KMPDocument()
        kmp.poti.append(POTIRoute(points: [RoutePoint(position: Vec3(x: 0, y: 0, z: 0)), RoutePoint(position: Vec3(x: 1000, y: 0, z: 0))]))
        let wiiTypes: [UInt16] = [0, 1, 2, 3, 4, 3]
        for (i, t) in wiiTypes.enumerated() {
            // The last KartFollow has no route, so it can't become a Chase.
            kmp.came.append(CAMEEntry(type: t, routeID: t == 1 || i == 5 ? 0xFF : 0, position: Vec3(x: Float(i) * 100, y: 50, z: 0)))
            kmp.area.append(AREAEntry(shape: 0, type: ReplayTransfer.wiiAreaType, cameraIndex: UInt8(i), priority: 0,
                                      position: Vec3(x: Float(i) * 100, y: 0, z: 0), rotation: Vec3(), scale: Vec3(x: 1, y: 1, z: 1)))
        }

        let bol = BOL.newDocument()
        let moved = ReplayTransfer.wiiToDD(kmp, into: bol, place: .init(scale: 1))
        check(moved.cameras == wiiTypes.count && moved.areas == wiiTypes.count, "all replay cameras ported: \(moved)")
        let expected: [UInt16] = [0x100, 0x100, 0x101, 0x102, 0x101, 0x100]
        check(bol.came.map(\.type) == expected, "Wii -> DD types: \(bol.came.map { String($0.type, radix: 16) })")
        check(bol.area.allSatisfy { $0.type == ReplayTransfer.ddAreaType }, "areas are Double Dash camera areas")

        // The u16 type survives a BOL save + re-read, including the parade camera.
        bol.came.append(MKWiiToMKDD.paradeCamera())
        let again = try BOL.parse(BOL.serialize(bol, source: bol.bolSource!))
        check(again.came.map(\.type) == expected + [0x008], "BOL keeps u16 types: \(again.came.map { String($0.type, radix: 16) })")

        // And back to the Wii.
        let back = KMPDocument()
        _ = ReplayTransfer.ddToWii(again, into: back, scale: 1)
        check(back.came.map(\.type) == [1, 1, 2, 3, 2, 1], "DD -> Wii types: \(back.came.map(\.type))")
        _ = try KMPDocument.parse(back.serialize())

        print(failures == 0 ? "ok" : "\(failures) failures")
        if failures > 0 { exit(1) }
    }
}
