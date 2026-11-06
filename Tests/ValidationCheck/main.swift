// Bad-input check (no discs needed): each value here used to trap or allocate gigabytes; now each
// path survives it. NaN/infinite floats, absurd header sizes, coordinates out of any grid.
//
//   find "Revolution IDE/Core" -name '*.swift' ! -path '*/Workbench/*' ! -path '*/Homebrew/*' \
//     ! -path '*/Editor/*' ! -name AppState.swift | tr '\n' '\0' | xargs -0 swiftc -O -parse-as-library \
//     -o /tmp/validcheck "Revolution IDE/Core/Workbench/BaseGameLibrary.swift" Tests/ValidationCheck/main.swift
//   /tmp/validcheck

import Foundation

@main enum ValidationCheck {
    static func main() throws {
        var failures = 0
        func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL", what); failures += 1 } }
        let bad: [Float] = [.nan, .infinity, -.infinity, 1e30, -1e30]

        // The shared conversions.
        check(Float.nan.clampedInt == 0 && Float.infinity.clampedInt > 0 && (-Float.infinity).clampedInt < 0, "clampedInt")
        check(Float(12.7).rounded().clampedInt == 13, "clampedInt keeps ordinary values")
        check(bad.allSatisfy { abs(Int(gridCell($0, 500))) <= 1_000_000 } && gridCell(-1, 500) == -1, "gridCell")
        check(parseFloat("nan") == 0 && parseFloat("inf") == 0 && parseFloat("1e39") == 0 && parseFloat("2.5") == 2.5 && parseFloat("x") == nil, "parseFloat")

        // OBJ with non-finite numbers imports as zeros, not NaN.
        let obj = OBJImporter.parse("v nan 0 0\nv 1 inf 0\nv 0 0 1e39\nf 1 2 3\n")
        check(obj.count == 1 && [obj[0].v0, obj[0].v1, obj[0].v2].allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }, "OBJ non-finite values")

        // Collision with a NaN / far-away triangle still builds (the bad triangles are left out).
        let good = KCLTriangle(v0: Vec3(x: 0, y: 0, z: 0), v1: Vec3(x: 100, y: 0, z: 0), v2: Vec3(x: 0, y: 0, z: 100))
        var tris = [good]
        for v in bad { tris.append(KCLTriangle(v0: Vec3(x: v, y: 0, z: 0), v1: good.v1, v2: good.v2)) }
        check(!BCO.build(tris).isEmpty, "BCO with bad triangles")

        // A texture header claiming 65535x65535 is refused instead of allocating 17 GB.
        check(TextureCodec.decode(data: Data(count: 64), offset: 0, width: 65535, height: 65535, format: .i8) == nil, "huge texture header")

        // Cameras with bad numbers: intro preview, speed fitting and a Double Dash save.
        let bol = BOL.newDocument()
        bol.poti.append(POTIRoute(points: [RoutePoint(position: Vec3(x: 0, y: 0, z: 0)), RoutePoint(position: Vec3(x: 1e30, y: 0, z: 0))]))
        for v in bad {
            bol.came.append(CAMEEntry(type: 5, routeID: 0, rotation: Vec3(x: v, y: v, z: v), zoomStart: v, zoomEnd: v, time: v))
            let i = bol.came.count - 1
            check(KMPCameraSequence.simulate(bol.came[i], index: i, in: bol).count <= 36_000, "preview frames capped for time \(v)")
            KMPCameraSequence.fitSpeeds(camera: i, in: bol)
        }
        check(!BOL.serialize(bol, source: bol.bolSource!).isEmpty, "BOL save with bad camera numbers")

        print(failures == 0 ? "ok" : "\(failures) failures")
        if failures > 0 { exit(1) }
    }
}
