import Foundation

/// The intro ("opening pan") camera sequence of a KMP: the chain that starts at the CAME header's
/// opening index and follows each camera's `next`, plus a frame-by-frame simulation of it for
/// previewing. Behaviour per the community KMP documentation, checked against
/// the retail opening cameras on the disc:
///  - An opening camera (type 5, OP_FixMoveAt) rides its Route; `position` is ignored then. Its
///    speed is the Route point's Setting 1, in units per frame, eased from one point's speed to
///    the next's (retail: 160 → 0 over a 30,000-unit route in 220 frames on Luigi Circuit).
///  - The look-at point moves in a straight line from View Start to View End at `viewVelocity`
///    units per 100 frames; the field of view moves from Zoom Start to Zoom End at
///    `zoomVelocity` degrees per 100 frames. Whatever reaches its end first just stays there.
///  - The camera is shown for `time` frames, then `next` takes over (0xFF ends the intro).
nonisolated enum KMPCameraSequence {
    struct Frame {
        var camera: Int
        /// Frame number within this camera's own shot.
        var localFrame: Int
        var eye: Vec3
        var target: Vec3
        /// Vertical field of view, degrees.
        var fov: Float
    }

    /// Camera indices of the opening pan, in play order. Stops at the first repeat, so a chain
    /// looped back on itself for testing (as the wiki suggests) still yields each shot once.
    static func chain(in doc: KMPDocument) -> [Int] {
        var out: [Int] = []
        var c = Int(doc.openingCameraIndex)
        while doc.came.indices.contains(c), !out.contains(c) {
            out.append(c)
            c = Int(doc.came[c].next)
        }
        return out
    }

    /// Frames for one camera, `time` of them (at least 1).
    static func simulate(_ cam: CAMEEntry, index: Int, in doc: KMPDocument) -> [Frame] {
        let frames = min(max(1, cam.time.rounded().clampedInt), 36_000)
        var route = doc.poti.indices.contains(Int(cam.routeID)) ? doc.poti[Int(cam.routeID)] : nil
        if route?.points.isEmpty == true { route = nil }
        let path = route.map(RoutePath.init)
        if doc.isBOL { return simulateBOL(cam, index: index, frames: frames, path: path) }
        var distance: Float = 0
        var target = cam.viewPositionStart
        var fov = cam.zoomStart
        let viewStep = Float(cam.viewVelocity) / 100
        let zoomStep = Float(cam.zoomVelocity) / 100
        var out: [Frame] = []
        out.reserveCapacity(frames)
        for f in 0..<frames {
            let eye = path.map { $0.position(at: distance) } ?? cam.position
            out.append(Frame(camera: index, localFrame: f, eye: eye, target: target, fov: fov))
            if let path { distance = min(path.length, distance + path.speed(at: distance)) }
            target = moved(target, toward: cam.viewPositionEnd, by: viewStep)
            fov = fov < cam.zoomEnd ? min(cam.zoomEnd, fov + zoomStep) : max(cam.zoomEnd, fov - zoomStep)
        }
        return out
    }

    /// A Double Dash camera, which has no look or zoom speeds and no per-point route speeds (per
    /// mkdd-track-editor's libbol and camera-type notes): the look-at point and field of view go
    /// from start to end over the shot's Duration, and the camera rides its route at the camera's
    /// own Route Speed. By type: 1 (StartOnlyPath) rides the route looking along its own rotation;
    /// 4 (StartFixPath) rides it watching Look Start; 5 (StartPath) rides it panning Look Start ->
    /// Look End; 0 and 6 (StartFix, StartLookPath) stay at Position and pan.
    /// ponytail: Route Speed taken as units per frame, as on the Wii, retail shots often end
    /// partway along their 2-point routes under that reading; check against the game if a shot
    /// lands somewhere unexpected.
    private static func simulateBOL(_ cam: CAMEEntry, index: Int, frames: Int, path: RoutePath?) -> [Frame] {
        let kind = cam.type
        let rides = [1, 4, 5].contains(kind) ? path : nil
        let speed = Float(cam.pointVelocity)
        let forward = BOL.vectors(cam.rotation).forward
        return (0..<frames).map { f in
            let t = frames > 1 ? Float(f) / Float(frames - 1) : 0
            let eye = rides.map { $0.position(at: min($0.length, speed * Float(f))) } ?? cam.position
            let target: Vec3
            switch kind {
            case 1: target = eye + forward * 1000
            case 4: target = cam.viewPositionStart
            default: target = cam.viewPositionStart + (cam.viewPositionEnd - cam.viewPositionStart) * t
            }
            return Frame(camera: index, localFrame: f, eye: eye, target: target, fov: cam.zoomStart + (cam.zoomEnd - cam.zoomStart) * t)
        }
    }

    /// The whole intro, every shot back to back.
    static func simulate(_ doc: KMPDocument) -> [Frame] {
        chain(in: doc).flatMap { simulate(doc.came[$0], index: $0, in: doc) }
    }

    private static func moved(_ a: Vec3, toward b: Vec3, by step: Float) -> Vec3 {
        let d = b - a
        let len = d.length
        return len <= step || len == 0 ? b : a + d * (step / len)
    }

    /// A Route as a polyline with per-vertex speeds. A smooth route (header Setting 1) is sampled
    /// as a Catmull-Rom curve through its points.
    /// ponytail: Catmull-Rom is an approximation of the game's own curve; it passes through the
    /// same points, so shots line up, but mid-segment the path can differ slightly.
    struct RoutePath {
        private(set) var points: [Vec3] = []
        private(set) var speeds: [Float] = []
        private(set) var cumulative: [Float] = []
        var length: Float { cumulative.last ?? 0 }

        init(_ route: POTIRoute) {
            let p = route.points.map(\.position)
            let s = route.points.map { Float($0.setting1) }
            guard p.count > 1 else { points = p; speeds = s; cumulative = p.map { _ in 0 }; return }
            let steps = route.isSmooth && p.count > 2 ? 16 : 1
            for i in 0..<(p.count - 1) {
                for k in 0..<steps {
                    let t = Float(k) / Float(steps)
                    points.append(steps == 1 ? p[i] : Self.catmullRom(p[max(0, i - 1)], p[i], p[i + 1], p[min(p.count - 1, i + 2)], t))
                    speeds.append(s[i] + (s[i + 1] - s[i]) * t)
                }
            }
            points.append(p[p.count - 1]); speeds.append(s[s.count - 1])
            var acc: Float = 0
            cumulative = [0]
            for i in 1..<points.count { acc += (points[i] - points[i - 1]).length; cumulative.append(acc) }
        }

        private func locate(_ d: Float) -> (Int, Float) {
            guard points.count > 1 else { return (0, 0) }
            var lo = 0, hi = cumulative.count - 1
            while hi - lo > 1 { let mid = (lo + hi) / 2; if cumulative[mid] <= d { lo = mid } else { hi = mid } }
            let seg = cumulative[lo + 1] - cumulative[lo]
            return (lo, seg > 0 ? min(1, max(0, (d - cumulative[lo]) / seg)) : 0)
        }

        func position(at d: Float) -> Vec3 {
            guard points.count > 1 else { return points.first ?? Vec3() }
            let (i, t) = locate(d)
            return points[i] + (points[i + 1] - points[i]) * t
        }

        func speed(at d: Float) -> Float {
            guard speeds.count > 1 else { return speeds.first ?? 0 }
            let (i, t) = locate(d)
            return speeds[i] + (speeds[i + 1] - speeds[i]) * t
        }

        static func catmullRom(_ p0: Vec3, _ p1: Vec3, _ p2: Vec3, _ p3: Vec3, _ t: Float) -> Vec3 {
            let t2 = t * t, t3 = t2 * t
            let a = p1 * 2
            let b = (p2 - p0) * t
            let c = (p0 * 2 - p1 * 5 + p2 * 4 - p3) * t2
            let d = (p1 * 3 - p0 - p2 * 3 + p3) * t3
            return (a + b + c + d) * 0.5
        }
    }

    // MARK: Authoring

    /// Makes camera `i`'s route, look and zoom speeds exactly finish in its Duration: every route
    /// point gets the same speed (length / time), so it arrives at the last point as the shot
    /// ends. Retail shots ease out instead; this is the dependable starting point. Double Dash
    /// has one speed, the camera's Route Speed.
    static func fitSpeeds(camera i: Int, in doc: KMPDocument) {
        guard doc.came.indices.contains(i) else { return }
        let cam = doc.came[i]
        let frames = max(1, cam.time - 1) // the first frame is at the start, so time-1 steps
        if doc.isBOL {
            // Double Dash: only the route speed is a speed (look and zoom always span the Duration).
            if doc.poti.indices.contains(Int(cam.routeID)) {
                doc.came[i].pointVelocity = UInt16(clamping: (RoutePath(doc.poti[Int(cam.routeID)]).length / frames).rounded(.up).clampedInt)
            }
            return
        }
        if doc.poti.indices.contains(Int(cam.routeID)) {
            let length = RoutePath(doc.poti[Int(cam.routeID)]).length
            let speed = UInt16(clamping: (length / frames).rounded(.up).clampedInt)
            for p in doc.poti[Int(cam.routeID)].points.indices { doc.poti[Int(cam.routeID)].points[p].setting1 = speed }
        }
        doc.came[i].viewVelocity = UInt16(clamping: ((cam.viewPositionEnd - cam.viewPositionStart).length / frames * 100).rounded(.up).clampedInt)
        doc.came[i].zoomVelocity = UInt16(clamping: (abs(cam.zoomEnd - cam.zoomStart) / frames * 100).rounded(.up).clampedInt)
    }

    /// Appends one opening shot: a type-5 camera riding a new 3-point route from `from` to `to`
    /// (lifted in the middle), looking from `lookStart` to `lookEnd`, then links it onto the end
    /// of the intro chain (or makes it the intro if there is none). Returns the camera index.
    @discardableResult
    static func appendShot(to doc: KMPDocument, from: Vec3, to: Vec3, lookStart: Vec3, lookEnd: Vec3,
                           zoom: (Float, Float) = (55, 45), frames: Float = 257) -> Int? {
        guard doc.came.count < 255, doc.poti.count < 255 else { return nil }
        let mid = (from + to) * 0.5 + Vec3(x: 0, y: max(300, (to - from).length * 0.05), z: 0)
        // Smooth (3 points is the minimum that doesn't freeze the game), back and forth, what
        // every retail opening-camera route uses.
        doc.poti.append(POTIRoute(setting1: 1, setting2: 1, points: [from, mid, to].map { RoutePoint(position: $0) }))
        let cam = CAMEEntry(type: 5, next: 0xFF, routeID: UInt8(doc.poti.count - 1), position: from,
                            zoomStart: zoom.0, zoomEnd: zoom.1, viewPositionStart: lookStart, viewPositionEnd: lookEnd, time: frames)
        doc.came.append(cam)
        let index = doc.came.count - 1
        if let last = chain(in: doc).last { doc.came[last].next = UInt8(index) } else { doc.openingCameraIndex = UInt8(index) }
        fitSpeeds(camera: index, in: doc)
        return index
    }

    /// The driven area: start points, enemy/item paths and checkpoints. Preferred over a course
    /// model's bounds, which take in distant scenery and made generated shots far too wide.
    static func trackBounds(_ doc: KMPDocument) -> (Vec3, Vec3)? {
        let pts = doc.ktpt.map(\.position) + doc.enpt.map(\.position) + doc.itpt.map(\.position)
        guard pts.count >= 2 else { return nil }
        let ys = pts.map(\.y)
        var lo = pts[0], hi = pts[0]
        for p in pts + doc.ckpt.flatMap({ [Vec3(x: $0.left.x, y: p0y(ys), z: $0.left.y), Vec3(x: $0.right.x, y: p0y(ys), z: $0.right.y)] }) {
            lo = Vec3(x: min(lo.x, p.x), y: min(lo.y, p.y), z: min(lo.z, p.z))
            hi = Vec3(x: max(hi.x, p.x), y: max(hi.y, p.y), z: max(hi.z, p.z))
        }
        return (lo, hi)
    }
    private static func p0y(_ ys: [Float]) -> Float { ys.reduce(0, +) / Float(ys.count) }

    /// Replaces the intro with Nintendo's usual three shots (220, 257 and 294 frames): a high
    /// overview of the whole track, a sweep across the middle of it, then a swoop in on the start
    /// line. `boundsMin`/`boundsMax` are the course's extent; the start is KTPT 0 when present.
    /// The old intro's cameras (and routes only they used) are removed.
    static func makeStandardIntro(in doc: KMPDocument, boundsMin: Vec3, boundsMax: Vec3) {
        for c in chain(in: doc).sorted(by: >) { removeCamera(c, in: doc, removingOwnRoute: true) }
        let center = (boundsMin + boundsMax) * 0.5
        let extent = max(boundsMax.x - boundsMin.x, boundsMax.z - boundsMin.z, 2000)
        let high = boundsMax.y + extent * 0.35
        let start = doc.ktpt.first?.position ?? center
        let yaw = (doc.ktpt.first?.rotation.y ?? 0) * .pi / 180
        let forward = Vec3(x: sin(yaw), y: 0, z: cos(yaw))
        let side = Vec3(x: forward.z, y: 0, z: -forward.x)
        // Halfway round the track: the enemy path point farthest from the start, else the center.
        let far = doc.enpt.map(\.position).max { ($0 - start).length < ($1 - start).length } ?? center

        appendShot(to: doc,
                   from: Vec3(x: boundsMin.x, y: high, z: boundsMin.z),
                   to: Vec3(x: center.x, y: high * 0.8, z: boundsMax.z),
                   lookStart: center, lookEnd: far, zoom: (55, 45), frames: 220)
        // A low tracking pass outside the far side of the track, looking in across it.
        var outward = far - center; outward.y = 0
        outward = outward.length > 1 ? outward.normalized() : side
        let along = Vec3.cross(outward, Vec3(x: 0, y: 1, z: 0))
        let low = max(800, extent * 0.04)
        appendShot(to: doc,
                   from: far + outward * (extent * 0.15) + along * (extent * 0.12) + Vec3(x: 0, y: low, z: 0),
                   to: far + outward * (extent * 0.15) - along * (extent * 0.12) + Vec3(x: 0, y: low, z: 0),
                   lookStart: far + along * (extent * 0.06), lookEnd: far - along * (extent * 0.06), zoom: (60, 70), frames: 257)
        // Swoop in from high up ahead of the start line, ending in front of it looking back at
        // the grid (karts line up behind KTPT 0).
        appendShot(to: doc,
                   from: start + forward * (extent * 0.25) + side * (extent * 0.1) + Vec3(x: 0, y: extent * 0.1, z: 0),
                   to: start + forward * 2500 + Vec3(x: 0, y: 700, z: 0),
                   lookStart: start, lookEnd: start - forward * 800, zoom: (55, 40), frames: 294)
    }

    /// Takes camera `c` out of the intro chain, relinking around it; the camera itself stays.
    static func unlink(_ c: Int, in doc: KMPDocument) {
        guard doc.came.indices.contains(c) else { return }
        let order = chain(in: doc)
        guard let pos = order.firstIndex(of: c) else { return }
        let after = pos + 1 < order.count ? UInt8(order[pos + 1]) : 0xFF
        if pos == 0 { doc.openingCameraIndex = after } else { doc.came[order[pos - 1]].next = after }
        doc.came[c].next = 0xFF
    }

    /// Reorders the intro chain to `order` (camera indices), rewriting the header and `next` links.
    static func setChain(_ order: [Int], in doc: KMPDocument) {
        doc.openingCameraIndex = order.first.map(UInt8.init) ?? 0xFF
        for (k, c) in order.enumerated() { doc.came[c].next = k + 1 < order.count ? UInt8(order[k + 1]) : 0xFF }
    }

    /// Removes a camera, fixing up every index that points at cameras (other cameras' `next`,
    /// AREA camera links, the header's opening/selection indices). With `removingOwnRoute`, its
    /// route goes too when nothing else uses it.
    static func removeCamera(_ i: Int, in doc: KMPDocument, removingOwnRoute: Bool = false) {
        guard doc.came.indices.contains(i) else { return }
        unlink(i, in: doc)
        let route = Int(doc.came[i].routeID)
        doc.came.remove(at: i)
        func fix(_ v: inout UInt8) { if Int(v) == i { v = 0xFF } else if v != 0xFF, Int(v) > i { v -= 1 } }
        for j in doc.came.indices { fix(&doc.came[j].next) }
        for j in doc.area.indices { fix(&doc.area[j].cameraIndex) }
        fix(&doc.openingCameraIndex)
        fix(&doc.selectionCameraIndex)
        if removingOwnRoute, doc.poti.indices.contains(route),
           !doc.came.contains(where: { Int($0.routeID) == route }),
           !doc.area.contains(where: { Int($0.routeID) == route }),
           !doc.gobj.contains(where: { Int($0.routeID) == route }) {
            removeRoute(route, in: doc)
        }
    }

    /// Removes a route, fixing up the GOBJ/AREA/CAME indices that point at routes.
    static func removeRoute(_ i: Int, in doc: KMPDocument) {
        guard doc.poti.indices.contains(i) else { return }
        doc.poti.remove(at: i)
        for j in doc.gobj.indices {
            if Int(doc.gobj[j].routeID) == i { doc.gobj[j].routeID = 0xFFFF }
            else if doc.gobj[j].routeID != 0xFFFF, Int(doc.gobj[j].routeID) > i { doc.gobj[j].routeID -= 1 }
        }
        func fix(_ v: inout UInt8) { if Int(v) == i { v = 0xFF } else if v != 0xFF, Int(v) > i { v -= 1 } }
        for j in doc.area.indices { fix(&doc.area[j].routeID) }
        for j in doc.came.indices { fix(&doc.came[j].routeID) }
    }
}
