// Driver's View kart physics check (no discs needed): from a standstill the kart reaches its top
// speed, slows on off-road, a boost panel takes it to 115 and wears off, and a jump pad sets its speed.
//
//   find "Revolution IDE/Core" -name '*.swift' ! -path '*/Workbench/*' ! -path '*/Homebrew/*' \
//     ! -path '*/Editor/*' ! -name AppState.swift | tr '\n' '\0' | xargs -0 swiftc -O -parse-as-library \
//     -o /tmp/physcheck "Revolution IDE/Core/Workbench/BaseGameLibrary.swift" Tests/DriverPhysicsCheck/main.swift
//   /tmp/physcheck

import Foundation

@main enum DriverPhysicsCheck {
    static func main() {
        var failures = 0
        func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL", what); failures += 1 } }
        func run(_ k: inout Kart, _ frames: Int, surface: UInt8 = 0, air: Bool = false) { for _ in 0..<frames { k.frame(surface: surface, airborne: air) } }

        var k = Kart()
        run(&k, 60)
        check(abs(k.speed - 0.59 * 60) < 0.01, "one second of accelerating: \(k.speed)")
        run(&k, 600)
        check(abs(k.speed - 79.77) < 0.01, "top speed: \(k.speed)")

        run(&k, 120, surface: 3)
        check(abs(k.speed - 79.77 * 0.4538) < 0.01, "off-road: \(k.speed)")
        k.hit(.boost)
        run(&k, 30, surface: 3)
        check(abs(k.speed - 115) < 0.01, "boost panel ignores off-road and reaches 115: \(k.speed)")
        run(&k, 120)
        check(abs(k.speed - 79.77) < 0.01, "boost wears off: \(k.speed)")

        k.hit(.jump(speed: 73, height: 45))
        check(k.speed == 73, "jump pad speed")
        run(&k, 20, air: true)
        check(abs(k.speed - 73 * pow(0.999, 15)) < 0.01, "air drag: \(k.speed)")

        print(failures == 0 ? "ok" : "\(failures) failures")
        if failures > 0 { exit(1) }
    }
}
