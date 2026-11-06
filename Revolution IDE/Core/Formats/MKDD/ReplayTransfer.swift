import Foundation

/// Replay cameras and the areas that trigger them, carried between Mario Kart Wii (AREA type 0
/// + a CAME of the replay kinds) and Double Dash (AREA type 1 + a camera of the fixed/chase kinds).
nonisolated enum ReplayTransfer {
    /// Wii camera type -> Double Dash: 0 Goal, 1 FixSearch, 2 PathSearch, 3 KartFollow, 4 KartPathFollow
    /// -> 0 Fix, 1 FixPath, 2 FixChase.
    static let wiiToDDTypes: [UInt8: UInt8] = [0: 0, 1: 0, 2: 1, 3: 2, 4: 1]
    /// Double Dash camera type -> Wii (FixSpl and the start-only types have no direct match).
    static let ddToWiiTypes: [UInt8: UInt8] = [0: 1, 1: 2, 2: 3, 3: 1, 4: 2]
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
    private static func copy(_ src: KMPDocument, into dst: KMPDocument, from srcType: UInt8, to dstType: UInt8, types: [UInt8: UInt8],
                             scale: Float, place: (Vec3) -> Vec3, yaw: Float, centreShift: (Vec3) -> Float) -> (areas: Int, cameras: Int) {
        var cameraMap: [Int: UInt8] = [:], routeMap: [Int: UInt8] = [:]
        var areas = 0
        for a in src.area where a.type == srcType && src.came.indices.contains(Int(a.cameraIndex)) {
            let c = src.came[Int(a.cameraIndex)]
            guard let type = types[c.type], dst.area.count < 255 else { continue }
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
