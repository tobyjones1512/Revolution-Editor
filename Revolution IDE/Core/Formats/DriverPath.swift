import Foundation
import simd

/// The line a CPU racer drives round a course, as a smooth, evenly sampled, ground-hugging loop --
/// what the 3D viewer's Driver's View rides along.
///
/// Built from the enemy route (ENPT, group 0 onwards, taking `choices`, else the first branch
/// at each fork), or the
/// checkpoints' midpoints when there's no route. Each sample sits on the collision floor nearest
/// the route's own height (so a road under a bridge stays under it), lightly smoothed so bumps in
/// the mesh don't shake the camera.
nonisolated struct DriverPath {
    /// Evenly spaced points on the ground, one lap, looping back to the first.
    let points: [SIMD3<Float>]
    let spacing: Float
    /// Boost panels, boost ramps and jump pads the line crosses, by sample index (see `Pad`).
    let pads: [Int: Pad]
    /// Each sample's ground, as a Wii KCL speed class (0 road, 2 weak / 3 / 4 heavy off-road...).
    let surfaces: [UInt8]
    /// Where the enemy route splits, by sample index: the end of a group with several next groups.
    let forks: [Int: Fork]
    var length: Float { Float(points.count) * spacing }

    static let defaultSpacing: Float = 50
    /// Eye height above the road, roughly where MKWii's chase camera sits over the kart.
    static let eyeHeight: Float = 450

    /// What a KCL surface does to a kart driving over it, per the "KCL Flag" wiki page.
    enum Pad: Equatable {
        /// Boost panel (0x06): a dash-panel boost.
        case boost
        /// Boost ramp (0x07): a ramp boost, then a trick boost of `trickFrames` (85/70/40 by variant)
        /// on landing; the jump itself is drawn as `airTime` seconds.
        case ramp(airTime: Float, trickFrames: Int)
        /// Jump pad (0x08): sets forward speed to `speed` and upward speed to `height`, units/frame.
        case jump(speed: Float, height: Float)

        init?(_ kcl: KCLDocument, attribute: UInt16) {
            let base = kcl.baseType(attribute)
            if kcl.isBCO {
                // Double Dash: 0x08 dash panel; 0x07/0x37/0x47 ramp boosts (no trick variants).
                switch base {
                case 0x08: self = .boost
                case 0x07, 0x37, 0x47: self = .ramp(airTime: 70.0 / 60, trickFrames: 70)
                default: return nil
                }
                return
            }
            let variant = Int((attribute >> 5) & 7)
            switch base {
            case 0x06: self = .boost
            case 0x07:
                let frames = variant == 0 ? 85 : variant == 1 ? 70 : 40
                self = .ramp(airTime: Float(frames) / 60, trickFrames: frames)
            case 0x08:
                // Speed, height pairs from the wiki's variant table (units/frame).
                let table: [(Float, Float)] = [(50, 35), (50, 47), (59, 30), (73, 45), (73, 53), (56, 50), (55, 35), (56, 50)]
                let (speed, height) = table[variant]
                self = .jump(speed: speed, height: height)
            default: return nil
            }
        }
    }

    /// A split in the enemy route: the group that ends there and the groups it can go on to.
    struct Fork: Equatable {
        let group: Int
        let options: [(group: Int, label: String)]
        /// The option this path takes.
        let chosen: Int
        static func == (a: Fork, b: Fork) -> Bool { a.group == b.group && a.chosen == b.chosen && a.options.map(\.group) == b.options.map(\.group) }
    }

    /// `choices`: the next group to take at each fork, by the group that ends there.
    init?(kmp: KMPDocument, collision: KCLDocument?, spacing: Float = DriverPath.defaultSpacing, choices: [Int: Int] = [:]) {
        let route = Self.routePoints(kmp, choices: choices)
        let raw = route.map(\.point)
        guard raw.count >= 2 else { return nil }
        var (samples, anchors) = Self.catmullRomLoop(raw, spacing: spacing)
        guard samples.count >= 4 else { return nil }
        var forks: [Int: Fork] = [:]
        for (i, r) in route.enumerated() { if let f = r.fork { forks[anchors[i]] = f } }
        var pads: [Int: Pad] = [:]
        var surfaces = [UInt8](repeating: 0, count: samples.count)
        if let collision {
            let ground = GroundQuery(collision)
            for i in samples.indices {
                // No floor near the route's own height: it's flying (a jump, a cannon, a gap), so
                // stay on the route rather than dropping to whatever is far below.
                if let hit = ground.floor(x: samples[i].x, z: samples[i].z, near: samples[i].y), abs(hit.y - samples[i].y) < 400 {
                    samples[i].y = hit.y
                    surfaces[i] = Kart.speedClass(collision, attribute: hit.attribute)
                }
            }
            // Pads: the centre line plus a little either side, since boost panels often sit off
            // the racing line. ponytail: fixed ±400 lateral probe, widen if pads get missed.
            for i in samples.indices {
                let dir = samples[(i + 1) % samples.count] - samples[i]
                var side = SIMD3<Float>(-dir.z, 0, dir.x)
                side = simd_length(side) > 0 ? simd_normalize(side) * 400 : side
                for p in [samples[i], samples[i] + side, samples[i] - side] {
                    if let hit = ground.floor(x: p.x, z: p.z, near: p.y), abs(hit.y - p.y) < 400,
                       let pad = Pad(collision, attribute: hit.attribute) { pads[i] = pad; break }
                }
            }
            // A short moving average: collision seams and kerbs would otherwise jolt the camera.
            let n = samples.count, w = 3
            let ys = samples.map(\.y)
            for i in 0..<n {
                var sum: Float = 0
                for k in -w...w { sum += ys[(i + k + n) % n] }
                samples[i].y = sum / Float(2 * w + 1)
            }
        }
        // Begin exactly where the race does.
        if let start = kmp.ktpt.first?.position {
            let s = SIMD3(start.x, start.y, start.z)
            if let i = samples.indices.min(by: { simd_distance_squared(samples[$0], s) < simd_distance_squared(samples[$1], s) }) {
                samples = Array(samples[i...] + samples[..<i])
                surfaces = Array(surfaces[i...] + surfaces[..<i])
                let n = samples.count
                pads = Dictionary(uniqueKeysWithValues: pads.map { (($0.key - i + n) % n, $0.value) })
                forks = Dictionary(forks.map { (($0.key - i + n) % n, $0.value) }, uniquingKeysWith: { a, _ in a })
            }
        }
        points = samples
        self.pads = pads
        self.surfaces = surfaces
        self.forks = forks
        self.spacing = spacing
    }

    /// The point `distance` along the loop (wrapping), interpolated between samples.
    func point(at distance: Float) -> SIMD3<Float> {
        let total = length
        var d = distance.truncatingRemainder(dividingBy: total)
        if d < 0 { d += total }
        let f = d / spacing
        let i = Int(f) % points.count
        return simd_mix(points[i], points[(i + 1) % points.count], SIMD3(repeating: f - Float(Int(f))))
    }

    /// A driver's eye and where they're looking, `distance` along the loop.
    func pose(at distance: Float, eyeHeight: Float = DriverPath.eyeHeight, lookAhead: Float = 1200) -> (eye: SIMD3<Float>, target: SIMD3<Float>) {
        let here = point(at: distance)
        // Look at a blend of points ahead, so the view turns smoothly into a corner rather than
        // snapping to each new segment.
        var ahead = SIMD3<Float>(repeating: 0)
        for k in 1...4 { ahead += point(at: distance + lookAhead * Float(k) / 4) }
        ahead /= 4
        return (here + SIMD3(0, eyeHeight, 0), ahead + SIMD3(0, eyeHeight * 0.6, 0))
    }

    // MARK: Building

    /// One lap of the CPU route: ENPT group 0, then the chosen (else first) next group each time,
    /// until it comes back round to a group already driven. Falls back to checkpoint midpoints.
    /// A group's last point carries the `Fork` when it has several next groups.
    static func routePoints(_ kmp: KMPDocument, choices: [Int: Int] = [:]) -> [(point: SIMD3<Float>, fork: Fork?)] {
        var out: [(point: SIMD3<Float>, fork: Fork?)] = []
        func v(_ p: Vec3) -> SIMD3<Float> { SIMD3(p.x, p.y, p.z) }
        if !kmp.enph.isEmpty, !kmp.enpt.isEmpty {
            var group = 0
            var visited = Set<Int>()
            while visited.insert(group).inserted {
                let g = kmp.enph[group]
                let range = Int(g.startIndex)..<min(kmp.enpt.count, Int(g.startIndex) + Int(g.pointCount))
                for k in range { out.append((v(kmp.enpt[k].position), nil)) }
                let next = g.nextGroups.filter { $0 != 0xFF && Int($0) < kmp.enph.count && kmp.enph[Int($0)].pointCount > 0 }.map(Int.init)
                guard let first = next.first else { break }
                let pick = choices[group].flatMap { next.contains($0) ? $0 : nil } ?? first
                let routes = Self.distinctRoutes(kmp, next)
                if routes.count > 1, let last = range.last, !out.isEmpty {
                    let here = v(kmp.enpt[last].position)
                    let heading = range.count > 1 ? here - v(kmp.enpt[last - 1].position) : SIMD3<Float>(0, 0, 1)
                    // Named by where each branch runs relative to the others, left to right.
                    func side(_ g: Int) -> Float {
                        let d = Self.pathPoint(kmp, g, 0.5) - here
                        return heading.x * d.z - heading.z * d.x // X/Z, Y up: positive is to the right
                    }
                    let order = routes.sorted { side($0) < side($1) }
                    let names = order.count == 2 ? ["Left", "Right"] : order.count == 3 ? ["Left", "Middle", "Right"]
                        : order.indices.map { "Route \($0 + 1) from the left" }
                    let options = order.enumerated().map { (group: $0.element, label: names[$0.offset]) }
                    let chosenRoute = routes.first { Self.separation(kmp, $0, pick) < Self.laneSeparation } ?? routes[0]
                    out[out.count - 1].fork = Fork(group: group, options: options, chosen: chosenRoute)
                }
                group = pick
            }
        }
        if out.count < 2 {
            out = []
            let next = CheckpointVerifier.successors(kmp)
            var i = 0
            var visited = Set<Int>()
            while kmp.ckpt.indices.contains(i), visited.insert(i).inserted {
                let c = kmp.ckpt[i]
                let y = kmp.enpt.first?.position.y ?? kmp.ktpt.first?.position.y ?? 0
                out.append((SIMD3((c.left.x + c.right.x) / 2, y, (c.left.y + c.right.y) / 2), nil))
                guard let n = next[i].first else { break }
                i = n
            }
        }
        // Drop repeated points (they'd make zero-length segments), keeping any fork they carry.
        var kept: [(point: SIMD3<Float>, fork: Fork?)] = []
        for p in out {
            if let last = kept.last, simd_distance(last.point, p.point) <= 1 { if p.fork != nil { kept[kept.count - 1].fork = p.fork } }
            else { kept.append(p) }
        }
        return kept
    }

    /// Retail routes split into side-by-side CPU lanes all the time (up to ~4,600 units apart in
    /// the retail courses); real alternative routes part by 6,000+ (Mushroom Gorge's cave: 14,900).
    /// ponytail: fixed threshold measured on retail; a very wide custom road may need it raised.
    static let laneSeparation: Float = 5000

    /// `groups` with lanes of the same road merged: one per different way to go.
    static func distinctRoutes(_ kmp: KMPDocument, _ groups: [Int]) -> [Int] {
        var reps: [Int] = []
        for g in groups where !reps.contains(where: { separation(kmp, $0, g) < laneSeparation }) { reps.append(g) }
        return reps
    }

    /// How far apart two enemy-path groups run (top-down), at a quarter, half and three quarters along.
    static func separation(_ kmp: KMPDocument, _ a: Int, _ b: Int) -> Float {
        [Float(0.25), 0.5, 0.75].map { f in
            let p = pathPoint(kmp, a, f), q = pathPoint(kmp, b, f)
            return simd_distance(SIMD2(p.x, p.z), SIMD2(q.x, q.z))
        }.max()!
    }

    /// The enemy point `fraction` of the way along a group.
    static func pathPoint(_ kmp: KMPDocument, _ group: Int, _ fraction: Float) -> SIMD3<Float> {
        let g = kmp.enph[group]
        let k = min(kmp.enpt.count - 1, Int(g.startIndex) + Int(Float(max(Int(g.pointCount) - 1, 0)) * fraction))
        let p = kmp.enpt[k].position
        return SIMD3(p.x, p.y, p.z)
    }

    /// A closed Catmull-Rom curve through `pts`, resampled every `spacing` units of arc length,
    /// plus the sample at (or just before) each of `pts`.
    static func catmullRomLoop(_ pts: [SIMD3<Float>], spacing: Float) -> (samples: [SIMD3<Float>], anchors: [Int]) {
        let n = pts.count
        var dense: [SIMD3<Float>] = []
        var denseStart: [Int] = []
        for i in 0..<n {
            denseStart.append(dense.count)
            let p0 = pts[(i - 1 + n) % n], p1 = pts[i], p2 = pts[(i + 1) % n], p3 = pts[(i + 2) % n]
            let steps = max(1, Int(simd_distance(p1, p2) / (spacing / 2)))
            for s in 0..<steps {
                let t = Float(s) / Float(steps), t2 = t * t, t3 = t2 * t
                let a = 2 * p1, b = p2 - p0, c = 2 * p0 - 5 * p1 + 4 * p2 - p3, d = 3 * p1 - p0 - 3 * p2 + p3
                dense.append(0.5 * (a + b * t + c * t2 + d * t3))
            }
        }
        // Resample to even spacing.
        var out = [dense[0]]
        var carry: Float = 0
        var sampleAtDense = [Int](repeating: 0, count: dense.count)
        for i in 0..<dense.count {
            sampleAtDense[i] = out.count - 1
            let a = dense[i], b = dense[(i + 1) % dense.count]
            let seg = simd_distance(a, b)
            var t = spacing - carry
            while t <= seg {
                out.append(simd_mix(a, b, SIMD3(repeating: t / seg)))
                t += spacing
            }
            carry = seg - (t - spacing)
        }
        if out.count > 1, simd_distance(out[out.count - 1], out[0]) < spacing / 2 { out.removeLast() }
        return (out, denseStart.map { sampleAtDense[$0] % out.count })
    }

    /// Floor heights from collision, bucketed by X/Z so each query only tests nearby triangles.
    struct GroundQuery {
        private var tris: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
        private var attributes: [UInt16] = []
        private var buckets: [SIMD2<Int32>: [Int32]] = [:]
        private let cell: Float = 1000

        init(_ kcl: KCLDocument) {
            for t in kcl.triangles {
                let base = kcl.baseType(t.attribute)
                // Floors you drive on, not walls, invisible walls or fall boundaries.
                if !kcl.isBCO, [0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x14, 0x19, 0x1C, 0x1E, 0x1F].contains(Int(base)) { continue }
                let a = SIMD3(t.v0.x, t.v0.y, t.v0.z), b = SIMD3(t.v1.x, t.v1.y, t.v1.z), c = SIMD3(t.v2.x, t.v2.y, t.v2.z)
                let n = simd_cross(b - a, c - a)
                guard simd_length(n) > 0, abs(n.y) >= 0.3 * simd_length(n) else { continue }
                let lo = key(min(a.x, b.x, c.x), min(a.z, b.z, c.z)), hi = key(max(a.x, b.x, c.x), max(a.z, b.z, c.z))
                guard hi.x - lo.x < 256, hi.y - lo.y < 256 else { continue }
                let index = Int32(tris.count)
                tris.append((a, b, c))
                attributes.append(t.attribute)
                for x in lo.x...hi.x { for z in lo.y...hi.y { buckets[SIMD2(x, z), default: []].append(index) } }
            }
        }

        private func key(_ x: Float, _ z: Float) -> SIMD2<Int32> {
            SIMD2(gridCell(x, cell), gridCell(z, cell))
        }

        /// The floor under (x, z) closest to `near`, the route's own height, so a road under
        /// a bridge isn't mistaken for the bridge deck.
        func height(x: Float, z: Float, near: Float) -> Float? { floor(x: x, z: z, near: near)?.y }

        /// `height`, plus the surface flag of the floor it found.
        func floor(x: Float, z: Float, near: Float) -> (y: Float, attribute: UInt16)? {
            var best: (y: Float, attribute: UInt16)?
            for i in buckets[key(x, z)] ?? [] {
                let (a, b, c) = tris[Int(i)]
                let den = (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
                guard abs(den) > 1e-9 else { continue }
                let u = ((b.z - c.z) * (x - c.x) + (c.x - b.x) * (z - c.z)) / den
                let v = ((c.z - a.z) * (x - c.x) + (a.x - c.x) * (z - c.z)) / den
                guard u >= -1e-4, v >= -1e-4, u + v <= 1 + 1e-4 else { continue }
                let y = u * a.y + v * b.y + (1 - u - v) * c.y
                if best == nil || abs(y - near) < abs(best!.y - near) { best = (y, attributes[Int(i)]) }
            }
            return best
        }
    }
}

/// One kart's forward speed, frame by frame (60 fps, units/frame), following Mario Kart Wii's own
/// rules as decompiled by Kinoko (github.com/vabold/Kinoko, KartMove.cc / KartBoost.cc).
///
/// Double Dash uses the same model with its ground types mapped onto the Wii's speed classes:
/// its decompilation (github.com/doldecomp/mkdd) shows the max-speed buckets by ground type
/// (KartCtrl::GetMaxSpeed) but its acceleration, dash and air code is not decompiled yet.
/// ponytail: Standard Kart M stats (Common.szs kartParam.bin values), no character bonus or cc
/// scaling; read kartParam.bin/driverParam.bin from the linked disc if per-combo speed matters.
nonisolated struct Kart {
    struct Stats {
        var speed: Float
        /// Acceleration A0..A3 at speed ratios 0, T1, T2, T3 (piecewise linear between them).
        var a: [Float]
        var t: [Float]
        /// Speed factor by KCL speed class (0x00..0x1F).
        var kclSpeed: [Float]
    }
    static let standardKartM = Stats(speed: 79.77, a: [0.59, 0.59, 0.462, 0.0662], t: [0.65, 0.85, 0.95],
                                     kclSpeed: [1, 1, 0.6697, 0.4538, 0.2641, 0.9199] + [Float](repeating: 1, count: 26))
    static let gravity: Float = 1.3
    static let hardLimit: Float = 120

    var stats = Kart.standardKartM
    private(set) var speed: Float = 0
    private var softLimit: Float = 0
    /// Frames left of each boost; the strongest active one applies.
    private var panelBoost = 0, trickBoost = 0, rampBoost = 0, offroadImmune = 0
    private var pendingTrick = 0
    private var airFrames = 0

    /// The Wii speed class of a collision attribute (Double Dash types mapped by their GetMaxSpeed bucket).
    static func speedClass(_ kcl: KCLDocument, attribute: UInt16) -> UInt8 {
        let base = kcl.baseType(attribute)
        guard kcl.isBCO else { return UInt8(base & 0x1F) }
        switch base {
        case 0x0C: return 2       // weak off-road
        case 0x00, 0x03: return 3 // dirt / grass
        case 0x13: return 4       // heavy off-road
        default: return 0
        }
    }

    /// Crossed a boost panel, boost ramp or jump pad.
    mutating func hit(_ pad: DriverPath.Pad) {
        switch pad {
        case .boost: panelBoost = 60; offroadImmune = 60
        case .ramp(_, let trick): rampBoost = 60; pendingTrick = trick
        case .jump(let s, _): speed = s; softLimit = max(softLimit, s)
        }
    }

    /// Landed from a ramp or jump: the trick boost kicks in.
    mutating func land() {
        airFrames = 0
        if pendingTrick > 0 { trickBoost = pendingTrick; pendingTrick = 0 }
    }

    /// One 60 fps frame on ground of speed class `surface` (ignored while `airborne`).
    mutating func frame(surface: UInt8, airborne: Bool) {
        // Boost: multiplier on the limit, its own acceleration, and a floor under the limit.
        let (mul, boostAccel, boostLimit): (Float, Float?, Float) =
            trickBoost > 0 ? (1.3, 6, 0) : panelBoost > 0 ? (1.4, 7, 115) : (1, nil, 0)
        let kcl = airborne || offroadImmune > 0 ? 1 : stats.kclSpeed[Int(surface & 0x1F)]
        var limit = max(stats.speed * mul * kcl, boostLimit * kcl)
        if rampBoost > 0 { limit = max(limit, 100) }
        limit = min(limit, Self.hardLimit)
        softLimit = softLimit > limit ? max(limit, softLimit - 3) : limit

        if airborne {
            airFrames += 1
            if airFrames > 5 { speed *= 0.999 }
        } else {
            let accel = boostAccel ?? (rampBoost > 0 && airFrames < 4 ? 7 : acceleration())
            speed += accel
        }
        speed = min(speed, softLimit)

        panelBoost = max(0, panelBoost - 1); trickBoost = max(0, trickBoost - 1)
        rampBoost = max(0, rampBoost - 1); offroadImmune = max(0, offroadImmune - 1)
    }

    /// Kinoko's calcVehicleAcceleration: A interpolated over the speed / soft-limit ratio.
    private func acceleration() -> Float {
        let ratio = softLimit > 0 ? speed / softLimit : 0
        guard ratio >= 0 else { return 1 }
        let a = stats.a, t = [0] + stats.t
        for i in 0..<3 where ratio < t[i + 1] {
            return a[i] + (a[i + 1] - a[i]) / (t[i + 1] - t[i]) * (ratio - t[i])
        }
        return a[3]
    }
}

/// Steers a `KinokoDrive` kart along a `DriverPath` hands-free: full throttle, stick toward a point
/// ahead on the line. ponytail: no drifting or tricks, so its lap times are a little slower than a
/// real player's; drift in Free Drive for real times.
nonisolated struct Autopilot {
    /// The sample the kart was last nearest, searched forward from so laps don't jump across the course.
    private(set) var index = 0
    private var started = false
    /// Frames spent nearly stopped (against a wall), then frames left backing off it.
    private var stuck = 0, reversing = 0

    mutating func input(for kart: KinokoDrive.State, on path: DriverPath) -> KinokoDrive.Input {
        let n = path.points.count
        func d2(_ i: Int) -> Float { let d = path.points[(i % n + n) % n] - kart.position; return d.x * d.x + d.z * d.z }
        if !started {
            index = path.points.indices.min { d2($0) < d2($1) } ?? 0
            started = true
        } else {
            index = (index - 20...index + 80).min { d2($0) < d2($1) }.map { ($0 % n + n) % n } ?? index
        }
        // Look further ahead the faster the kart goes (speed is units per frame).
        let ahead = Int((800 + max(kart.speed, 0) * 12) / path.spacing)
        let target = path.points[(index + ahead) % n] - kart.position
        let forward = kart.rotation.act(SIMD3<Float>(0, 0, 1))
        // Signed angle from the kart's heading to the target, in the ground plane (positive = to the right).
        let cross = forward.x * target.z - forward.z * target.x
        let dot = forward.x * target.x + forward.z * target.z
        let angle = atan2(cross, dot)
        var pad = KinokoDrive.Input()
        pad.stick.x = min(max(angle * 2.5, -1), 1)
        // Pinned on a wall: reverse out, steering the other way, as a player would.
        stuck = abs(kart.speed) < 5 ? stuck + 1 : 0
        if stuck > 30 { reversing = 45; stuck = 0 }
        if reversing > 0 {
            reversing -= 1
            pad.brake = true
            pad.stick.x = -pad.stick.x
            return pad
        }
        pad.accelerate = true
        return pad
    }
}
