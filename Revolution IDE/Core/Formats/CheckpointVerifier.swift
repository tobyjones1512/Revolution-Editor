import Foundation

/// Checks that a course's checkpoints (CKPT/CKPH) will actually track race progress and count
/// laps, the way Mario Kart Wii uses them:
///
/// - Each checkpoint is a line (left/right point) and, with the next checkpoint along its group
///   (or the first of a following group), bounds one quad. A kart's progress is the quad it's in.
/// - Lap rule, from the game's own `RaceManager::Player::calcCheckpoint` (as matched by the Kinoko
///   decompilation): entering a key checkpoint (lap counter type >= 0) higher than any reached so
///   far records it; entering the finish line (key 0) from the checkpoint before it, once the
///   *highest* key on the course has been reached, counts a lap. Keys in between may be skipped
///   or even missing (retail DK Summit has no key 4), they only stop the game's checkpoint
///   search from skipping ahead past them.
/// - A kart's checkpoint is found by searching outward from its current one, so a concave or
///   bow-tied quad, or one facing backwards, is a hole where progress stops.
///
/// The simulation drives the CPU route (ENPT), the line every racer is meant to follow, a few
/// times round and counts laps exactly like that, so a failure names the checkpoint where
/// progress was lost. Validated against every retail course (all pass, every lap counted).
nonisolated enum CheckpointVerifier {
    struct Issue: Identifiable {
        let id = UUID()
        let severity: Severity
        let message: String
        /// The checkpoint the issue is about, for jumping to it in the editor.
        var checkpoint: Int?
    }
    enum Severity: Int, Comparable { case info, warning, error
        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }
    struct Report {
        var issues: [Issue] = []
        /// Route loops driven vs laps the game would count (nil when there's nothing to drive).
        var loopsDriven = 0
        var lapsCounted = 0
        var passed: Bool { !issues.contains { $0.severity == .error } }
    }

    /// The checkpoints each checkpoint leads on to: the next in its group, or the first of each
    /// following group.
    static func successors(_ doc: KMPDocument) -> [[Int]] {
        var out = [[Int]](repeating: [], count: doc.ckpt.count)
        for g in doc.ckph {
            let start = Int(g.startIndex), count = Int(g.pointCount)
            guard count > 0, start + count <= doc.ckpt.count else { continue }
            for i in start..<(start + count - 1) { out[i] = [i + 1] }
            out[start + count - 1] = g.nextGroups.filter { $0 != 0xFF && Int($0) < doc.ckph.count }
                .map { Int(doc.ckph[Int($0)].startIndex) }.filter { doc.ckpt.indices.contains($0) }
        }
        return out
    }

    /// Groups every lap must pass through: removing one leaves no way from group 0 round to
    /// group 0 again. (A fork's branches are avoidable; the shared track either side isn't.)
    static func unavoidableGroups(groupNext: [[Int]]) -> Set<Int> {
        Set(groupNext.indices.filter { $0 == 0 || !canLoop(groupNext: groupNext, avoiding: [$0]) })
    }

    /// Whether some route leads from group 0 round to group 0 without entering `avoiding`.
    static func canLoop(groupNext: [[Int]], avoiding: Set<Int>) -> Bool {
        guard !groupNext.isEmpty else { return false }
        var seen = Set<Int>(), stack = groupNext[0]
        while let x = stack.popLast() {
            if x == 0 { return true }
            guard !avoiding.contains(x), groupNext.indices.contains(x), seen.insert(x).inserted else { continue }
            stack += groupNext[x]
        }
        return false
    }

    /// Groups in the order a lap meets them (breadth-first from group 0).
    static func drivingOrder(groupNext: [[Int]]) -> [Int] {
        guard !groupNext.isEmpty else { return [] }
        var order = [0], seen: Set<Int> = [0], i = 0
        while i < order.count {
            for n in groupNext[order[i]] where groupNext.indices.contains(n) && seen.insert(n).inserted { order.append(n) }
            i += 1
        }
        return order
    }

    /// The quad from checkpoint `i` to `j`, as left_i, right_i, right_j, left_j.
    private static func quad(_ doc: KMPDocument, _ i: Int, _ j: Int) -> [Vec2] {
        [doc.ckpt[i].left, doc.ckpt[i].right, doc.ckpt[j].right, doc.ckpt[j].left]
    }

    private static func cross(_ o: Vec2, _ a: Vec2, _ b: Vec2) -> Float {
        (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
    }

    /// Convex with every turn the same way (no bow-tie, no dent). Returns the turn sign, or 0.
    private static func convexSign(_ q: [Vec2]) -> Int {
        var sign = 0
        for k in 0..<4 {
            let c = cross(q[k], q[(k + 1) % 4], q[(k + 2) % 4])
            if abs(c) < 1e-3 { continue }
            let s = c > 0 ? 1 : -1
            if sign == 0 { sign = s } else if s != sign { return 0 }
        }
        return sign
    }

    private static func contains(_ q: [Vec2], _ p: Vec2) -> Bool {
        var pos = false, neg = false
        for k in 0..<4 {
            let c = cross(q[k], q[(k + 1) % 4], p)
            if c > 0 { pos = true } else if c < 0 { neg = true }
            if pos && neg { return false }
        }
        return true
    }

    static func verify(_ doc: KMPDocument, laps: Int = 3) -> Report {
        var r = Report()
        func issue(_ s: Severity, _ m: String, _ c: Int? = nil) { r.issues.append(Issue(severity: s, message: m, checkpoint: c)) }
        guard !doc.ckpt.isEmpty else {
            issue(.error, "No checkpoints. A race course needs a loop of checkpoints with a lap counter (key 0) to count laps; battle arenas have none.")
            return r
        }

        // MARK: Groups cover every checkpoint once, in order.
        var covered = [Int](repeating: 0, count: doc.ckpt.count)
        var expectedStart = 0
        for (gi, g) in doc.ckph.enumerated() {
            if Int(g.startIndex) != expectedStart {
                issue(.error, "Checkpoint group \(gi + 1) starts at checkpoint \(Int(g.startIndex) + 1), but the previous group ends at \(expectedStart). Groups must run back to back.")
            }
            expectedStart = Int(g.startIndex) + Int(g.pointCount)
            for i in Int(g.startIndex)..<min(doc.ckpt.count, expectedStart) { covered[i] += 1 }
        }
        if doc.ckph.isEmpty { issue(.error, "There are checkpoints but no checkpoint groups (CKPH).") }
        let orphans = covered.indices.filter { covered[$0] == 0 }
        if !orphans.isEmpty { issue(.error, "Checkpoint(s) \(list(orphans)) aren't in any group, so the game never reaches them.", orphans.first) }

        // MARK: Key checkpoints.
        let keyed = doc.ckpt.indices.filter { doc.ckpt[$0].lapCounterType >= 0 }
        let maxKey = keyed.map { Int(doc.ckpt[$0].lapCounterType) }.max() ?? -1
        let finishLines = keyed.filter { doc.ckpt[$0].lapCounterType == 0 }
        if finishLines.isEmpty {
            issue(.error, "No checkpoint is the lap counter (key checkpoint 0, the finish line), so laps can never count.")
        } else if doc.ckpt[0].lapCounterType != 0 {
            issue(.warning, "Checkpoint 1 is \(keyName(doc.ckpt[0].lapCounterType)), but every retail course makes it the finish line, race progress and positions are measured from checkpoint 1.", 0)
        }
        if finishLines.count > 1 { issue(.warning, "\(finishLines.count) checkpoints are the lap counter (\(list(finishLines))); retail courses have exactly one.", finishLines[1]) }
        if maxKey == 0 { issue(.warning, "Only the finish line is a key checkpoint, so a shortcut straight back across it counts as a lap. Retail courses add keys around the track.") }

        // The last key must be on track every lap covers, or a lap down the other branch of a
        // fork never reaches it and doesn't count.
        if maxKey > 0 {
            let lastKeys = keyed.filter { Int(doc.ckpt[$0].lapCounterType) == maxKey }
            let groupOf = { (i: Int) in doc.ckph.firstIndex { i >= Int($0.startIndex) && i < Int($0.startIndex) + Int($0.pointCount) } }
            let lastKeyGroups = Set(lastKeys.compactMap(groupOf))
            let groupNext = doc.ckph.map { $0.nextGroups.filter { Int($0) < doc.ckph.count }.map(Int.init) }
            if !lastKeyGroups.contains(0), canLoop(groupNext: groupNext, avoiding: lastKeyGroups) {
                issue(.error, "The last key checkpoint (key \(maxKey), checkpoint \(list(lastKeys))) is on a branch racers can drive around, a lap taken the other way never reaches it and doesn't count. Move it to track every lap passes, or give each branch the same key.", lastKeys.first)
            }
        }

        // MARK: Respawns.
        let badRespawn = doc.ckpt.indices.filter { Int(doc.ckpt[$0].respawnIndex) >= doc.jgpt.count }
        if !badRespawn.isEmpty { issue(.error, "Checkpoint(s) \(list(badRespawn)) respawn at a point that doesn't exist (only \(doc.jgpt.count) respawn point(s)).", badRespawn.first) }

        // MARK: Quad shapes.
        let next = successors(doc)
        let deadEnds = next.indices.filter { next[$0].isEmpty && covered[$0] > 0 }
        if !deadEnds.isEmpty { issue(.error, "Checkpoint(s) \(list(deadEnds)) lead nowhere (their group has no next group), so the track never loops back to the finish.", deadEnds.first) }
        var signs: [Int: Int] = [:] // turn direction, per quad start
        for i in next.indices { for j in next[i] {
            let s = convexSign(quad(doc, i, j))
            if s == 0 { issue(.warning, "The area between checkpoints \(i + 1) and \(j + 1) is twisted or dented (not a convex quad), karts there lose track of their progress. Move the points so the four corners form a simple convex shape.", i) }
            else { signs[i] = s }
        }}
        // Every quad on every retail course turns the same way (left -> right -> next right is
        // clockwise in X/Z); one that doesn't has its left and right swapped, it faces backwards,
        // so the game sees karts driving the wrong way through it.
        let backwards = signs.keys.sorted().filter { signs[$0] != -1 }
        if !backwards.isEmpty { issue(.error, "Checkpoint(s) \(list(backwards)) face backwards (left and right swapped). Swap their left and right points.", backwards.first) }

        // MARK: Start line. Retail grids start behind the finish line (beginner_course: 150 units);
        // one already past it begins the race having skipped the line, so lap 1 never counts.
        if let start = doc.ktpt.first, let after = next[0].first {
            let l = doc.ckpt[0].left, rt = doc.ckpt[0].right
            let ahead = Vec2(x: (doc.ckpt[after].left.x + doc.ckpt[after].right.x) / 2, y: (doc.ckpt[after].left.y + doc.ckpt[after].right.y) / 2)
            let side = cross(l, rt, Vec2(x: start.position.x, y: start.position.z))
            if side * cross(l, rt, ahead) > 0 {
                issue(.error, "The start position is already past the finish line (checkpoint 1), so the first crossing doesn't count and laps come out wrong. Move the start point (or checkpoint 1) so racers line up behind the line.", 0)
            }
        }

        // MARK: Reachability: every checkpoint lies on a loop through the finish line.
        var reach = Set<Int>([0]), stack = [0]
        while let i = stack.popLast() { for j in next[i] where reach.insert(j).inserted { stack.append(j) } }
        let unreachable = doc.ckpt.indices.filter { !reach.contains($0) }
        if !unreachable.isEmpty { issue(.warning, "Checkpoint(s) \(list(unreachable)) can't be reached from the finish line by following the groups' next links.", unreachable.first) }
        if !next.indices.contains(where: { next[$0].contains(0) }) { issue(.error, "No checkpoint leads back to checkpoint 1, so a lap can never complete.", 0) }

        // MARK: Drive the CPU route and count laps.
        simulate(doc, next: next, maxKey: maxKey, laps: laps, report: &r)

        r.issues.sort { $0.severity > $1.severity }
        if r.issues.isEmpty { issue(.info, "Checkpoints look good: \(doc.ckpt.count) checkpoint(s) in \(doc.ckph.count) group(s), keys 0-\(max(0, maxKey)).") }
        return r
    }

    /// Follows ENPT (group 0, first next group at each fork) and tracks progress like the game:
    /// only the current quad's neighbours are candidates, keys must be crossed in order, and
    /// crossing the finish line with every key done counts a lap.
    private static func simulate(_ doc: KMPDocument, next: [[Int]], maxKey: Int, laps: Int, report r: inout Report) {
        guard maxKey >= 0, !doc.enph.isEmpty, !doc.enpt.isEmpty else {
            if doc.enpt.isEmpty { r.issues.append(Issue(severity: .info, message: "No CPU route (ENPT) to drive, so laps weren't simulated.")) }
            return
        }
        // The route as a polyline, looped `laps + 1` times (the first pass reaches the finish line).
        var route: [Vec2] = []
        var group = 0, loops = 0, guardSteps = 0
        while loops <= laps, guardSteps < 10_000 {
            guardSteps += 1
            let g = doc.enph[group]
            for k in Int(g.startIndex)..<min(doc.enpt.count, Int(g.startIndex) + Int(g.pointCount)) {
                route.append(Vec2(x: doc.enpt[k].position.x, y: doc.enpt[k].position.z))
            }
            guard let n = g.nextGroups.first(where: { $0 != 0xFF && Int($0) < doc.enph.count }) else { break }
            group = Int(n)
            if group == 0 { loops += 1 }
        }
        var prev: [[Int]] = Array(repeating: [], count: next.count)
        for i in next.indices { for j in next[i] { prev[j].append(i) } }
        func quadIndex(of p: Vec2, near: Int?) -> (start: Int, end: Int)? {
            // Search outward along the links from the current checkpoint, like the game's
            // neighbour search; with no current checkpoint (race start), search them all.
            if let near {
                var frontier = [near], seen = Set([near])
                for _ in 0..<3 {
                    for i in frontier { for j in next[i] where contains(quad(doc, i, j), p) { return (i, j) } }
                    frontier = frontier.flatMap { next[$0] + prev[$0] }.filter { seen.insert($0).inserted }
                }
                return nil
            }
            for i in next.indices { for j in next[i] where contains(quad(doc, i, j), p) { return (i, j) } }
            return nil
        }
        var current: Int? = nil
        var keyReached = maxKey // the game starts every racer as if the last key was reached
        var lapsCounted = 0, crossings = 0
        var reported = Set<Int>()
        var outside = 0, samples = 0
        for s in 0..<max(0, route.count - 1) {
            let a = route[s], b = route[s + 1]
            let len = ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot()
            let steps = max(1, Int(len / 50))
            for t in 0..<steps {
                let f = Float(t) / Float(steps)
                let p = Vec2(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
                samples += 1
                guard let q = quadIndex(of: p, near: current) else { outside += 1; continue }
                guard let cur = current, q.start != cur else { current = current ?? q.start; continue }
                let key = Int(doc.ckpt[q.start].lapCounterType)
                if key > keyReached {
                    keyReached = key
                } else if key == 0, next[cur].contains(q.start) {
                    crossings += 1
                    if keyReached == maxKey { lapsCounted += 1; keyReached = 0 }
                    else if reported.insert(q.start).inserted {
                        let last = doc.ckpt.indices.first { Int(doc.ckpt[$0].lapCounterType) == maxKey }
                        r.issues.append(Issue(severity: .error, message: "Driving the CPU route, a lap reached the finish line without entering the last key checkpoint (key \(maxKey)\(last.map { ", checkpoint \($0 + 1)" } ?? "")), that lap doesn't count. Check that the route passes through that checkpoint's area.", checkpoint: last))
                    }
                } else if !next[cur].contains(q.start), !prev[cur].contains(q.start), reported.insert(q.start).inserted {
                    r.issues.append(Issue(severity: .warning, message: "Driving the CPU route jumps from checkpoint \(cur + 1) to \(q.start + 1), skipping the ones between, a gap or overlap in the checkpoints there.", checkpoint: cur))
                }
                current = q.start
            }
        }
        r.loopsDriven = crossings
        r.lapsCounted = lapsCounted
        if samples > 0, outside * 10 > samples {
            r.issues.append(Issue(severity: .warning, message: "\(outside * 100 / samples)% of the CPU route lies outside every checkpoint area, checkpoints should cover the whole road, or progress (and respawns) stall there."))
        }
        if crossings == 0 {
            r.issues.append(Issue(severity: .error, message: "Driving the CPU route never crosses the finish line. Make sure the route and checkpoints follow the same track.", checkpoint: finishLine(doc)))
        } else {
            r.issues.append(Issue(severity: lapsCounted == crossings ? .info : .error,
                                  message: "Drove the CPU route across the finish line \(crossings) time(s): \(lapsCounted) lap(s) counted."))
        }
    }

    private static func finishLine(_ doc: KMPDocument) -> Int? { doc.ckpt.indices.first { doc.ckpt[$0].lapCounterType == 0 } }

    private static func keyName(_ t: Int8) -> String { t < 0 ? "a normal checkpoint" : "key checkpoint \(t)" }
    private static func list(_ xs: [Int]) -> String {
        xs.count > 8 ? xs.prefix(8).map { String($0 + 1) }.joined(separator: ", ") + " and \(xs.count - 8) more" : xs.map { String($0 + 1) }.joined(separator: ", ")
    }
}
