import Foundation

/// Replay cameras and the areas that trigger them, carried between Mario Kart Wii (AREA type 0
/// + a CAME of the replay kinds) and Double Dash (AREA type 1 + a camera of the fixed/chase kinds).
nonisolated enum ReplayTransfer {
    /// Wii camera type -> Double Dash. Wii replay cameras all watch the player, so they go to the
    /// 0x1xx kinds: 0 Goal / 1 FixSearch -> 0x100 FixSearch (fixed point, aims at player);
    /// 2 PathSearch / 4 KartPathFollow -> 0x101 ChasePath (slides along its route, aims at player);
    /// 3 KartFollow -> 0x102 Chase (follows the kart). 0x000 Fix / 0x001 FixPath never turn to the player.
    static let wiiToDDTypes: [UInt16: UInt16] = [0: 0x100, 1: 0x100, 2: 0x101, 3: 0x102, 4: 0x101]
    /// Double Dash camera type -> Wii. The static 0x000/0x001 kinds have no Wii match; nearest is used.
    static let ddToWiiTypes: [UInt16: UInt16] = [0x100: 1, 0x101: 2, 0x102: 3, 0x000: 1, 0x001: 2]
    static let wiiAreaType: UInt8 = 0, ddAreaType: UInt8 = 1
    /// A Wii area of scale 1 is 10000 units across, a Double Dash one 100 (mkdd-track-editor draws scale x 100).
    static let wiiUnit: Float = 10000, ddUnit: Float = 100

    /// Wii replay cameras -> `bol`, each on a copy of its route, placed like the rest of the course.
    static func wiiToDD(_ kmp: KMPDocument, into bol: KMPDocument, place: MKWiiToMKDD.Placement) -> (areas: Int, cameras: Int) {
        copy(kmp, into: bol, from: wiiAreaType, to: ddAreaType, types: wiiToDDTypes, scale: place.scale * wiiUnit / ddUnit,
             place: place.apply, yaw: place.yawDegrees, centreShift: { $0.y * ddUnit / 2 })
    }

    /// Double Dash replay cameras -> a Wii KMP, scaled by `s` like the rest of the port.
    static func ddToWii(_ bol: KMPDocument, into kmp: KMPDocument, scale s: Float) -> (areas: Int, cameras: Int) {
        copy(bol, into: kmp, from: ddAreaType, to: wiiAreaType, types: ddToWiiTypes, scale: s * ddUnit / wiiUnit,
             place: { $0 * s }, yaw: 0, centreShift: { -$0.y * wiiUnit / 2 })
    }

    /// `scale` is how much an area's scale number changes between the two games' units.
    private static func copy(_ src: KMPDocument, into dst: KMPDocument, from srcType: UInt8, to dstType: UInt8, types: [UInt16: UInt16],
                             scale: Float, place: (Vec3) -> Vec3, yaw: Float, centreShift: (Vec3) -> Float) -> (areas: Int, cameras: Int) {
        var cameraMap: [Int: UInt8] = [:], routeMap: [Int: UInt8] = [:]
        var areas = 0
        for a in src.area where a.type == srcType && src.came.indices.contains(Int(a.cameraIndex)) {
            let c = src.came[Int(a.cameraIndex)]
            guard var type = types[c.type], dst.area.count < 255 else { continue }
            if cameraMap[Int(a.cameraIndex)] == nil {
                guard dst.came.count < 254 else { continue }
                var route: UInt8 = 0xFF
                if src.poti.indices.contains(Int(c.routeID)) {
                    if let r = routeMap[Int(c.routeID)] { route = r } else if dst.poti.count < 255 {
                        dst.poti.append(POTIRoute(points: src.poti[Int(c.routeID)].points.map { RoutePoint(position: place($0.position)) }))
                        route = UInt8(dst.poti.count - 1)
                        routeMap[Int(c.routeID)] = route
                    }
                }
                // Chase without a route has nothing to follow on; fall back to a fixed watcher.
                if type == 0x102, route == 0xFF { type = 0x100 }
                dst.came.append(CAMEEntry(type: type, next: 0xFF, routeID: route, pointVelocity: c.pointVelocity, zoomVelocity: c.zoomVelocity,
                                          viewVelocity: c.viewVelocity, position: place(c.position), rotation: Vec3(x: c.rotation.x, y: c.rotation.y + yaw, z: c.rotation.z),
                                          zoomStart: c.zoomStart, zoomEnd: c.zoomEnd,
                                          viewPositionStart: place(c.viewPositionStart), viewPositionEnd: place(c.viewPositionEnd), time: c.time))
                cameraMap[Int(a.cameraIndex)] = UInt8(dst.came.count - 1)
            }
            let s = Vec3(x: a.scale.x * scale, y: a.scale.y * scale, z: a.scale.z * scale)
            var p = place(a.position)
            p.y += centreShift(s)
            dst.area.append(AREAEntry(shape: a.shape, type: dstType, cameraIndex: cameraMap[Int(a.cameraIndex)]!, priority: a.priority, position: p,
                                      rotation: Vec3(x: a.rotation.x, y: a.rotation.y + yaw, z: a.rotation.z), scale: s))
            areas += 1
        }
        return (areas, cameraMap.count)
    }
}
