import Foundation
import Combine

/// Adding and removing KMP entries, shared by the 2D KMP editor and the 3D track viewer so both
/// keep every cross-reference (path groups, checkpoint -> respawn point, camera/route indices)
/// consistent in exactly the same way.
extension KMPDocumentBox {
    /// Appends a new entry at `pos` to `section` and selects it. ENPT/ITPT/CKPT extend the *last*
    /// path group so the new point is immediately part of a path; `tangent` (direction of travel,
    /// X/Z) orients a checkpoint's gate across the path instead of along X.
    @discardableResult
    func addPoint(_ section: KMPSection, at pos: Vec3, tangent: SIMD2<Float>? = nil) -> Bool {
        switch section {
        case .ktpt:
            doc.ktpt.append(KTPTEntry(position: pos))
            selection = .ktpt(doc.ktpt.count - 1)
        case .enpt:
            let at = KMPDocument.insertIndexForLastGroup(doc.enph, arrayCount: doc.enpt.count)
            doc.enpt.insert(ENPTEntry(position: pos), at: at)
            KMPDocument.appendToLastGroup(&doc.enph, insertedAt: at)
            selection = .enpt(at)
        case .itpt:
            let at = KMPDocument.insertIndexForLastGroup(doc.itph, arrayCount: doc.itpt.count)
            doc.itpt.insert(ITPTEntry(position: pos), at: at)
            KMPDocument.appendToLastGroup(&doc.itph, insertedAt: at)
            selection = .itpt(at)
        case .ckpt:
            let halfWidth: Float = 1500
            var normal = SIMD2<Float>(-halfWidth, 0)
            if let t = tangent, (t.x * t.x + t.y * t.y) > 1e-8 {
                let len = (t.x * t.x + t.y * t.y).squareRoot()
                normal = SIMD2<Float>(t.y / len * halfWidth, -t.x / len * halfWidth)
            }
            let at = KMPDocument.insertIndexForLastGroup(doc.ckph, arrayCount: doc.ckpt.count)
            doc.ckpt.insert(CKPTEntry(left: Vec2(x: pos.x + normal.x, y: pos.z + normal.y),
                                      right: Vec2(x: pos.x - normal.x, y: pos.z - normal.y)), at: at)
            KMPDocument.appendToLastGroup(&doc.ckph, insertedAt: at)
            selection = .ckpt(at)
        case .gobj:
            doc.gobj.append(GOBJEntry(objectID: doc.isBOL ? 1 : 0x0065, position: pos)) // Item Box
            selection = .gobj(doc.gobj.count - 1)
        case .jgpt:
            doc.jgpt.append(JGPTEntry(position: pos))
            selection = .jgpt(doc.jgpt.count - 1)
        case .cnpt:
            doc.cnpt.append(CNPTEntry(position: pos))
            selection = .cnpt(doc.cnpt.count - 1)
        case .mspt:
            doc.mspt.append(MSPTEntry(position: pos))
            selection = .mspt(doc.mspt.count - 1)
        case .area:
            doc.area.append(AREAEntry(position: pos))
            selection = .area(doc.area.count - 1)
        case .came:
            doc.came.append(CAMEEntry(position: pos))
            selection = .came(doc.came.count - 1)
        default:
            return false
        }
        isDirty = true
        objectWillChange.send()
        return true
    }

    /// Whether `selection` can be removed. Any path point can: its group shrinks around it (and
    /// goes if it empties), and checkpoint links are recomputed on save.
    func canRemove(_ selection: KMPSelection) -> Bool {
        switch selection {
        case .ktpt, .gobj, .jgpt, .cnpt, .mspt, .area, .came: return true
        case .enpt(let i): return doc.enpt.indices.contains(i)
        case .itpt(let i): return doc.itpt.indices.contains(i)
        case .ckpt(let i): return doc.ckpt.indices.contains(i)
        case .poti(let route, let point):
            guard doc.poti.indices.contains(route) else { return false }
            guard let point else { return true }
            return doc.poti[route].points.indices.contains(point)
        case .enph(let i): return doc.enph.indices.contains(i)
        case .itph(let i): return doc.itph.indices.contains(i)
        case .ckph(let i): return doc.ckph.indices.contains(i)
        default: return false
        }
    }

    /// Removes `sel` (a no-op for a stale index), fixing up everything that referenced it by index.
    func remove(_ sel: KMPSelection) {
        guard canRemove(sel) else { return }
        switch sel {
        case .ktpt(let i): guard doc.ktpt.indices.contains(i) else { return }; doc.ktpt.remove(at: i)
        case .gobj(let i): guard doc.gobj.indices.contains(i) else { return }; doc.gobj.remove(at: i)
        case .jgpt(let i):
            guard doc.jgpt.indices.contains(i) else { return }
            doc.jgpt.remove(at: i)
            // Checkpoints name their respawn point by index (= its written ID): one past the removed
            // point shifts down with it, one that pointed *at* it falls back to the point before.
            for c in doc.ckpt.indices where Int(doc.ckpt[c].respawnIndex) >= i {
                let r = Int(doc.ckpt[c].respawnIndex)
                doc.ckpt[c].respawnIndex = UInt8(max(0, r == i ? min(i, doc.jgpt.count) - 1 : r - 1))
            }
        case .cnpt(let i): guard doc.cnpt.indices.contains(i) else { return }; doc.cnpt.remove(at: i)
        case .mspt(let i): guard doc.mspt.indices.contains(i) else { return }; doc.mspt.remove(at: i)
        case .area(let i): guard doc.area.indices.contains(i) else { return }; doc.area.remove(at: i)
        case .came(let i): guard doc.came.indices.contains(i) else { return }; KMPCameraSequence.removeCamera(i, in: doc)
        case .enpt(let i):
            guard doc.enpt.indices.contains(i) else { return }
            KMPDocument.removePathPoint(i, groups: &doc.enph, points: &doc.enpt)
            for a in doc.area.indices where doc.area[a].enptID != 0xFF && Int(doc.area[a].enptID) >= i {
                doc.area[a].enptID = Int(doc.area[a].enptID) == i ? 0xFF : doc.area[a].enptID - 1
            }
        case .itpt(let i): guard doc.itpt.indices.contains(i) else { return }; KMPDocument.removePathPoint(i, groups: &doc.itph, points: &doc.itpt)
        case .ckpt(let i): guard doc.ckpt.indices.contains(i) else { return }; KMPDocument.removePathPoint(i, groups: &doc.ckph, points: &doc.ckpt)
        case .poti(let route, let point):
            guard doc.poti.indices.contains(route) else { return }
            if let point {
                guard doc.poti[route].points.indices.contains(point) else { return }
                doc.poti[route].points.remove(at: point)
            } else {
                KMPCameraSequence.removeRoute(route, in: doc)
            }
        case .enph(let i): guard doc.enph.indices.contains(i) else { return }; KMPDocument.deleteGroup(groups: &doc.enph, points: &doc.enpt, index: i)
        case .itph(let i): guard doc.itph.indices.contains(i) else { return }; KMPDocument.deleteGroup(groups: &doc.itph, points: &doc.itpt, index: i)
        case .ckph(let i): guard doc.ckph.indices.contains(i) else { return }; KMPDocument.deleteGroup(groups: &doc.ckph, points: &doc.ckpt, index: i)
        default: return
        }
        selection = nil
        isDirty = true
        objectWillChange.send()
    }

    /// Moves the selected enemy/item points or checkpoints (all one kind) into a new path group.
    /// Returns false when the selection isn't all one path kind.
    @discardableResult
    func separateToNewGroup(_ selections: Set<KMPSelection>) -> Bool {
        var enpt = Set<Int>(), itpt = Set<Int>(), ckpt = Set<Int>()
        for sel in selections {
            switch sel.asPoint {
            case .enpt(let i): enpt.insert(i)
            case .itpt(let i): itpt.insert(i)
            case .ckpt(let i): ckpt.insert(i)
            default: return false
            }
        }
        guard [enpt, itpt, ckpt].filter({ !$0.isEmpty }).count == 1 else { return false }
        if !enpt.isEmpty {
            guard let map = KMPDocument.separate(enpt, groups: &doc.enph, points: &doc.enpt) else { return false }
            for a in doc.area.indices where doc.area[a].enptID != 0xFF && map.indices.contains(Int(doc.area[a].enptID)) {
                doc.area[a].enptID = UInt8(map[Int(doc.area[a].enptID)])
            }
        } else if !itpt.isEmpty {
            guard KMPDocument.separate(itpt, groups: &doc.itph, points: &doc.itpt) != nil else { return false }
        } else {
            guard KMPDocument.separate(ckpt, groups: &doc.ckph, points: &doc.ckpt) != nil else { return false }
        }
        selection = nil
        isDirty = true
        objectWillChange.send()
        return true
    }
}


/// Moving, rotating, aligning and grounding KMP entries, one implementation for the 2D editor
/// and the 3D viewer's gizmo, so a drag does exactly the same thing in both.
extension KMPDocument {
    /// Where an entry sits in the world. Checkpoints are 2D gates, so they're placed at the height
    /// of the respawn point they use.
    func position3D(of sel: KMPSelection) -> Vec3? {
        switch sel.asPoint {
        case .ktpt(let i): return ktpt.indices.contains(i) ? ktpt[i].position : nil
        case .enpt(let i): return enpt.indices.contains(i) ? enpt[i].position : nil
        case .itpt(let i): return itpt.indices.contains(i) ? itpt[i].position : nil
        case .ckpt(let i):
            guard ckpt.indices.contains(i) else { return nil }
            let e = ckpt[i]
            let y = jgpt.indices.contains(Int(e.respawnIndex)) ? jgpt[Int(e.respawnIndex)].position.y : 0
            return Vec3(x: (e.left.x + e.right.x) / 2, y: y, z: (e.left.y + e.right.y) / 2)
        case .gobj(let i): return gobj.indices.contains(i) ? gobj[i].position : nil
        case .jgpt(let i): return jgpt.indices.contains(i) ? jgpt[i].position : nil
        case .cnpt(let i): return cnpt.indices.contains(i) ? cnpt[i].position : nil
        case .mspt(let i): return mspt.indices.contains(i) ? mspt[i].position : nil
        case .area(let i): return area.indices.contains(i) ? area[i].position : nil
        case .came(let i): return came.indices.contains(i) ? came[i].position : nil
        case .poti(let r, let p):
            guard poti.indices.contains(r) else { return nil }
            if let p { return poti[r].points.indices.contains(p) ? poti[r].points[p].position : nil }
            return poti[r].points.first?.position
        default: return nil
        }
    }

    /// Moves an entry. Checkpoints have no height of their own, so `dy` doesn't apply to them.
    func translate(_ sel: KMPSelection, dx: Float, dy: Float = 0, dz: Float) {
        func move(_ v: inout Vec3) { v.x += dx; v.y += dy; v.z += dz }
        switch sel.asPoint {
        case .ktpt(let i): if ktpt.indices.contains(i) { move(&ktpt[i].position) }
        case .enpt(let i): if enpt.indices.contains(i) { move(&enpt[i].position) }
        case .itpt(let i): if itpt.indices.contains(i) { move(&itpt[i].position) }
        case .ckpt(let i):
            if ckpt.indices.contains(i) {
                ckpt[i].left.x += dx; ckpt[i].left.y += dz
                ckpt[i].right.x += dx; ckpt[i].right.y += dz
            }
        case .gobj(let i): if gobj.indices.contains(i) { move(&gobj[i].position) }
        case .jgpt(let i): if jgpt.indices.contains(i) { move(&jgpt[i].position) }
        case .cnpt(let i): if cnpt.indices.contains(i) { move(&cnpt[i].position) }
        case .mspt(let i): if mspt.indices.contains(i) { move(&mspt[i].position) }
        case .area(let i): if area.indices.contains(i) { move(&area[i].position) }
        case .came(let i): if came.indices.contains(i) { move(&came[i].position) }
        case .poti(let r, let p):
            if let p, poti.indices.contains(r), poti[r].points.indices.contains(p) { move(&poti[r].points[p].position) }
        default: break
        }
    }

    /// Which rotation axes an entry has: all three for things with a full rotation, yaw only for a
    /// checkpoint gate and a cannon's launch direction, none for path/route points.
    func rotationAxes(of sel: KMPSelection) -> [Bool] {
        switch sel.asPoint {
        case .ktpt, .gobj, .jgpt, .mspt, .area, .came: return [true, true, true]
        case .ckpt, .cnpt: return [false, true, false]
        default: return [false, false, false]
        }
    }

    /// Rotation in degrees (X, Y, Z). A checkpoint's yaw is derived from its gate's direction.
    func rotation(of sel: KMPSelection) -> Vec3? {
        switch sel.asPoint {
        case .ktpt(let i): return ktpt.indices.contains(i) ? ktpt[i].rotation : nil
        case .gobj(let i): return gobj.indices.contains(i) ? gobj[i].rotation : nil
        case .jgpt(let i): return jgpt.indices.contains(i) ? jgpt[i].rotation : nil
        case .mspt(let i): return mspt.indices.contains(i) ? mspt[i].rotation : nil
        case .area(let i): return area.indices.contains(i) ? area[i].rotation : nil
        case .came(let i): return came.indices.contains(i) ? came[i].rotation : nil
        case .cnpt(let i): return cnpt.indices.contains(i) ? Vec3(x: 0, y: cnpt[i].effectVector.y, z: 0) : nil
        case .ckpt(let i):
            guard ckpt.indices.contains(i) else { return nil }
            let e = ckpt[i]
            let mx = (e.left.x + e.right.x) / 2, mz = (e.left.y + e.right.y) / 2
            return Vec3(x: 0, y: atan2(-(e.left.y - mz), e.left.x - mx) * 180 / .pi, z: 0)
        default: return nil
        }
    }

    /// Sets rotation in degrees; for a checkpoint only the yaw is used (the gate turns about its
    /// middle, keeping its width), matching the 2D editor's Alt-drag.
    func setRotation(_ sel: KMPSelection, _ r: Vec3) {
        switch sel.asPoint {
        case .ktpt(let i): if ktpt.indices.contains(i) { ktpt[i].rotation = r }
        case .gobj(let i): if gobj.indices.contains(i) { gobj[i].rotation = r }
        case .jgpt(let i): if jgpt.indices.contains(i) { jgpt[i].rotation = r }
        case .mspt(let i): if mspt.indices.contains(i) { mspt[i].rotation = r }
        case .area(let i): if area.indices.contains(i) { area[i].rotation = r }
        case .came(let i): if came.indices.contains(i) { came[i].rotation = r }
        case .cnpt(let i): if cnpt.indices.contains(i) { cnpt[i].effectVector.y = r.y }
        case .ckpt(let i):
            guard ckpt.indices.contains(i) else { return }
            let e = ckpt[i]
            let mx = (e.left.x + e.right.x) / 2, mz = (e.left.y + e.right.y) / 2
            let half = hypot(e.right.x - e.left.x, e.right.y - e.left.y) / 2
            let rad = r.y * .pi / 180
            let dx = cos(rad) * half, dz = -sin(rad) * half
            ckpt[i].left = Vec2(x: mx + dx, y: mz + dz)
            ckpt[i].right = Vec2(x: mx - dx, y: mz - dz)
        default: break
        }
    }

    /// Lines the points up on their average X or Z, whichever way they're more spread out.
    func straighten(_ selections: Set<KMPSelection>) {
        let ids = Set(selections.map(\.asPoint)).filter { position3D(of: $0) != nil }
        guard ids.count > 1 else { return }
        let ps = ids.map { position3D(of: $0)! }
        let xs = ps.map(\.x), zs = ps.map(\.z)
        let avgX = xs.reduce(0, +) / Float(ps.count), avgZ = zs.reduce(0, +) / Float(ps.count)
        let alignX = (xs.max()! - xs.min()!) < (zs.max()! - zs.min()!)
        for id in ids {
            let p = position3D(of: id)!
            if alignX { translate(id, dx: avgX - p.x, dz: 0) } else { translate(id, dx: 0, dz: avgZ - p.z) }
        }
    }

    /// Spaces the points evenly between the two furthest apart, along their longer spread.
    func equaliseGaps(_ selections: Set<KMPSelection>) {
        let ids = Array(Set(selections.map(\.asPoint)).filter { position3D(of: $0) != nil })
        guard ids.count > 2 else { return }
        let ps = ids.map { ($0, position3D(of: $0)!) }
        let xs = ps.map(\.1.x), zs = ps.map(\.1.z)
        let alongX = (xs.max()! - xs.min()!) > (zs.max()! - zs.min()!)
        let sorted = ps.sorted { alongX ? $0.1.x < $1.1.x : $0.1.z < $1.1.z }
        let first = alongX ? sorted.first!.1.x : sorted.first!.1.z
        let last = alongX ? sorted.last!.1.x : sorted.last!.1.z
        let step = (last - first) / Float(sorted.count - 1)
        for (k, (id, p)) in sorted.enumerated() where k > 0 && k < sorted.count - 1 {
            let target = first + step * Float(k)
            if alongX { translate(id, dx: target - p.x, dz: 0) } else { translate(id, dx: 0, dz: target - p.z) }
        }
    }

    /// Kinds of point that rest on the ground (not areas or cameras, which are placed by volume/view).
    static func supportsGroundSnap(_ sel: KMPSelection) -> Bool {
        switch sel.asPoint {
        case .ktpt, .enpt, .itpt, .gobj, .jgpt, .cnpt, .mspt: return true
        case .poti(_, let point): return point != nil
        default: return false
        }
    }

    /// Puts the entry's Y on the collision floor under it, plus `clearance`. False if nothing is below.
    @discardableResult
    func snapToGround(_ sel: KMPSelection, collision: KCLDocument, clearance: Float = 10) -> Bool {
        guard Self.supportsGroundSnap(sel), let p = position3D(of: sel),
              let y = collision.floorHeight(x: p.x, z: p.z) else { return false }
        translate(sel, dx: 0, dy: y + clearance - p.y, dz: 0)
        return true
    }
}

// MARK: Ordering

extension KMPDocument {
    /// The range of points in the path group containing point `i`, for a grouped section.
    private func groupRange(_ groups: [PathLinkEntry], containing i: Int) -> Range<Int>? {
        groups.lazy.map { Int($0.startIndex)..<(Int($0.startIndex) + Int($0.pointCount)) }.first { $0.contains(i) }
    }

    /// Whether `movePoint(_:by:)` can move this selection `delta` places.
    func canMovePoint(_ sel: KMPSelection, by delta: Int) -> Bool { target(of: sel.asPoint, by: delta) != nil }

    private func target(of sel: KMPSelection, by delta: Int) -> Int? {
        func inGroup(_ groups: [PathLinkEntry], _ i: Int, _ count: Int) -> Int? {
            let j = i + delta
            guard let r = groupRange(groups, containing: i), r.contains(j), j < count else { return nil }
            return j
        }
        switch sel {
        case .enpt(let i): return inGroup(enph, i, enpt.count)
        case .itpt(let i): return inGroup(itph, i, itpt.count)
        case .ckpt(let i): return inGroup(ckph, i, ckpt.count)
        case .poti(let r, let p?):
            guard poti.indices.contains(r) else { return nil }
            let j = p + delta
            return poti[r].points.indices.contains(j) ? j : nil
        case .jgpt(let i): let j = i + delta; return jgpt.indices.contains(j) ? j : nil
        default: return nil
        }
    }

    /// Swaps a point with its neighbour `delta` places along its path (enemy/item points and
    /// checkpoints within their group, route points within their route, respawn points in their
    /// list), keeping everything that refers to them by index pointing at the same point: areas'
    /// enemy points, checkpoints' respawn points. Returns the point's new selection.
    @discardableResult
    func movePoint(_ sel: KMPSelection, by delta: Int) -> KMPSelection? {
        let sel = sel.asPoint
        guard let j = target(of: sel, by: delta) else { return nil }
        switch sel {
        case .enpt(let i):
            enpt.swapAt(i, j)
            for a in area.indices where Int(area[a].enptID) == i || Int(area[a].enptID) == j {
                area[a].enptID = UInt8(Int(area[a].enptID) == i ? j : i)
            }
            return .enpt(j)
        case .itpt(let i): itpt.swapAt(i, j); return .itpt(j)
        case .ckpt(let i): ckpt.swapAt(i, j); return .ckpt(j)
        case .poti(let r, let p?): poti[r].points.swapAt(p, j); return .poti(route: r, point: j)
        case .jgpt(let i):
            jgpt.swapAt(i, j)
            for c in ckpt.indices where Int(ckpt[c].respawnIndex) == i || Int(ckpt[c].respawnIndex) == j {
                ckpt[c].respawnIndex = UInt8(Int(ckpt[c].respawnIndex) == i ? j : i)
            }
            // Respawn IDs follow position (every retail track numbers them 0, 1, 2...).
            for k in jgpt.indices { jgpt[k].respawnID = UInt16(k) }
            return .jgpt(j)
        default: return nil
        }
    }

    /// Whether `insertPoint(after:)` can add a point after this one.
    func canInsertPoint(after sel: KMPSelection) -> Bool {
        // Groups index points with a byte, so a grouped section tops out at 255 points.
        func room(_ groups: [PathLinkEntry], _ i: Int, _ count: Int) -> Bool {
            i < count && count < 255 && groups.contains { $0.pointCount < 255 && (Int($0.startIndex)..<Int($0.startIndex) + Int($0.pointCount)).contains(i) }
        }
        switch sel.asPoint {
        case .enpt(let i): return room(enph, i, enpt.count)
        case .itpt(let i): return room(itph, i, itpt.count)
        case .ckpt(let i): return room(ckph, i, ckpt.count)
        case .poti(let r, let p?): return poti.indices.contains(r) && poti[r].points.indices.contains(p)
        default: return false
        }
    }

    /// Adds a point right after `sel` in its path, halfway to the next one (the next path's first
    /// point at a group's end; the same step on again at a dead end), with `sel`'s settings.
    /// Everything that refers to later points by index, path groups, areas' enemy points, moves
    /// along with them. Returns the new point's selection.
    @discardableResult
    func insertPoint(after sel: KMPSelection) -> KMPSelection? {
        let sel = sel.asPoint
        guard canInsertPoint(after: sel) else { return nil }
        func mid(_ a: Vec3, _ b: Vec3) -> Vec3 { Vec3(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2, z: (a.z + b.z) / 2) }
        func mid2(_ a: Vec2, _ b: Vec2) -> Vec2 { Vec2(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        func ext2(_ a: Vec2, _ b: Vec2) -> Vec2 { Vec2(x: b.x + (b.x - a.x) / 2, y: b.y + (b.y - a.y) / 2) }
        /// The point after `i`: the next in its group, else the first of its group's first next group.
        func nextIndex(_ groups: [PathLinkEntry], _ i: Int, _ count: Int) -> Int? {
            guard let r = groupRange(groups, containing: i) else { return nil }
            if r.contains(i + 1) { return i + 1 }
            let g = groups.firstIndex { Int($0.startIndex) == r.lowerBound && Int($0.pointCount) == r.count }!
            guard let n = groups[g].nextGroups.first(where: { $0 != 0xFF && Int($0) < groups.count }) else { return nil }
            let start = Int(groups[Int(n)].startIndex)
            return groups[Int(n)].pointCount > 0 && start < count && start != i ? start : nil
        }
        /// Where the new point goes between point `i` and the next (or a half step beyond `i`).
        func between(_ p: (Int) -> Vec3, _ i: Int, _ next: Int?) -> Vec3 {
            if let next { return mid(p(i), p(next)) }
            guard i > 0 else { return Vec3(x: p(i).x + 1000, y: p(i).y, z: p(i).z) }
            let a = p(i - 1), b = p(i)
            return Vec3(x: b.x + (b.x - a.x) / 2, y: b.y + (b.y - a.y) / 2, z: b.z + (b.z - a.z) / 2)
        }
        /// Grows the group holding `i` by one and moves later groups' starts past the new point.
        func grow(_ groups: inout [PathLinkEntry], _ i: Int) {
            let k = i + 1
            guard let g = groups.firstIndex(where: { (Int($0.startIndex)..<Int($0.startIndex) + Int($0.pointCount)).contains(i) }) else { return }
            groups[g].pointCount += 1
            for h in groups.indices where h != g && Int(groups[h].startIndex) >= k { groups[h].startIndex += 1 }
        }
        switch sel {
        case .enpt(let i):
            let e = enpt[i]
            let pos = between({ self.enpt[$0].position }, i, nextIndex(enph, i, enpt.count))
            enpt.insert(ENPTEntry(position: pos, radius: e.radius, setting1: e.setting1, setting2: e.setting2, fileScale: e.fileScale, bol: e.bol), at: i + 1)
            grow(&enph, i)
            for a in area.indices where area[a].enptID != 0xFF && Int(area[a].enptID) > i { area[a].enptID += 1 }
            return .enpt(i + 1)
        case .itpt(let i):
            let e = itpt[i]
            let pos = between({ self.itpt[$0].position }, i, nextIndex(itph, i, itpt.count))
            itpt.insert(ITPTEntry(position: pos, radius: e.radius, setting1: e.setting1, setting2: e.setting2, fileScale: e.fileScale), at: i + 1)
            grow(&itph, i)
            return .itpt(i + 1)
        case .ckpt(let i):
            let c = ckpt[i]
            let left: Vec2, right: Vec2
            if let n = nextIndex(ckph, i, ckpt.count) { left = mid2(c.left, ckpt[n].left); right = mid2(c.right, ckpt[n].right) }
            else if i > 0 { left = ext2(ckpt[i - 1].left, c.left); right = ext2(ckpt[i - 1].right, c.right) }
            else { left = Vec2(x: c.left.x, y: c.left.y + 1000); right = Vec2(x: c.right.x, y: c.right.y + 1000) }
            // A plain checkpoint: key checkpoints (lap counting) stay as they were.
            ckpt.insert(CKPTEntry(left: left, right: right, respawnIndex: c.respawnIndex, lapCounterType: -1, bol: c.bol), at: i + 1)
            grow(&ckph, i)
            return .ckpt(i + 1)
        case .poti(let r, let p?):
            let pts = poti[r].points, q = pts[p]
            let next: Int? = p + 1 < pts.count ? p + 1 : (poti[r].isCyclic && pts.count > 2 ? 0 : nil)
            let pos = between({ pts[$0].position }, p, next)
            poti[r].points.insert(RoutePoint(position: pos, setting1: q.setting1, setting2: q.setting2, bol: q.bol), at: p + 1)
            return .poti(route: r, point: p + 1)
        default: return nil
        }
    }

    /// Adds a point right before `sel` in its path: halfway from the previous point, or (for the
    /// first point of its path) half a step back, mirroring where `insertPoint(after:)` would go.
    func insertPoint(before sel: KMPSelection) -> KMPSelection? {
        let sel = sel.asPoint
        if let prev = target(of: sel, by: -1) {
            switch sel {
            case .enpt: return insertPoint(after: .enpt(prev))
            case .itpt: return insertPoint(after: .itpt(prev))
            case .ckpt: return insertPoint(after: .ckpt(prev))
            case .poti(let r, _): return insertPoint(after: .poti(route: r, point: prev))
            default: return nil
            }
        }
        guard let added = insertPoint(after: sel), let moved = movePoint(added, by: -1) else { return nil }
        func mirror(_ p: Vec3, around o: Vec3) -> Vec3 { Vec3(x: 2 * o.x - p.x, y: 2 * o.y - p.y, z: 2 * o.z - p.z) }
        func mirror2(_ p: Vec2, around o: Vec2) -> Vec2 { Vec2(x: 2 * o.x - p.x, y: 2 * o.y - p.y) }
        switch moved {
        case .enpt(let i): enpt[i].position = mirror(enpt[i].position, around: enpt[i + 1].position)
        case .itpt(let i): itpt[i].position = mirror(itpt[i].position, around: itpt[i + 1].position)
        case .ckpt(let i):
            ckpt[i].left = mirror2(ckpt[i].left, around: ckpt[i + 1].left)
            ckpt[i].right = mirror2(ckpt[i].right, around: ckpt[i + 1].right)
        case .poti(let r, let p?): poti[r].points[p].position = mirror(poti[r].points[p].position, around: poti[r].points[p + 1].position)
        default: break
        }
        return moved
    }

    /// Swaps route `i` with its neighbour `delta` places away, keeping every object, area and
    /// camera on the route it was using.
    @discardableResult
    func moveRoute(_ i: Int, by delta: Int) -> Bool {
        let j = i + delta
        guard poti.indices.contains(i), poti.indices.contains(j) else { return false }
        poti.swapAt(i, j)
        func swap16(_ v: inout UInt16) { if Int(v) == i { v = UInt16(j) } else if Int(v) == j { v = UInt16(i) } }
        func swap8(_ v: inout UInt8) { if Int(v) == i { v = UInt8(j) } else if Int(v) == j { v = UInt8(i) } }
        for k in gobj.indices { swap16(&gobj[k].routeID) }
        for k in area.indices { swap8(&area[k].routeID) }
        for k in came.indices { swap8(&came[k].routeID) }
        return true
    }

    // MARK: Respawns

    /// Replaces the respawn points with one per checkpoint: on the ground at the checkpoint's
    /// middle, facing the next checkpoint, each checkpoint set to respawn at its own. Heights come
    /// from `collision` (the floor nearest the course's own height there, the nearest enemy
    /// point's, else the start's, so a road under a bridge isn't mistaken for the bridge);
    /// without collision, from that nearby height. Returns how many were made.
    @discardableResult
    func makeRespawnPerCheckpoint(collision: KCLDocument?) -> Int {
        guard !ckpt.isEmpty, ckpt.count <= 255 else { return 0 }
        let ground = collision.map(DriverPath.GroundQuery.init)
        let next = CheckpointVerifier.successors(self)
        func mid(_ c: CKPTEntry) -> Vec2 { Vec2(x: (c.left.x + c.right.x) / 2, y: (c.left.y + c.right.y) / 2) }
        func nearbyHeight(_ x: Float, _ z: Float) -> Float {
            let p = enpt.min { ($0.position.x - x) * ($0.position.x - x) + ($0.position.z - z) * ($0.position.z - z)
                             < ($1.position.x - x) * ($1.position.x - x) + ($1.position.z - z) * ($1.position.z - z) }
            return p?.position.y ?? ktpt.first?.position.y ?? 0
        }
        var made: [JGPTEntry] = []
        for (i, c) in ckpt.enumerated() {
            let m = mid(c)
            let ahead = next[i].first.map { mid(ckpt[$0]) }
            // Facing the next checkpoint; the last of a dead end faces along its gate's normal.
            var dx = (ahead?.x ?? m.x) - m.x, dz = (ahead?.y ?? m.y) - m.y
            if dx == 0 && dz == 0 { dx = -(c.right.y - c.left.y); dz = c.right.x - c.left.x }
            let near = nearbyHeight(m.x, m.y)
            let y = (ground?.height(x: m.x, z: m.y, near: near)).map { $0 + 10 } ?? near
            made.append(JGPTEntry(position: Vec3(x: m.x, y: y, z: m.y), rotation: Vec3(x: 0, y: atan2(dx, dz) * 180 / .pi, z: 0), respawnID: UInt16(i)))
            ckpt[i].respawnIndex = UInt8(i)
        }
        jgpt = made
        return made.count
    }
}

extension KMPDocument {
    /// Replaces the item paths with a copy of the enemy paths (positions and widths; settings
    /// cleared, since ENPT and ITPT settings mean different things), leaving out `excluded`
    /// enemy path groups, any links to them, and any branch that leaving them out cuts off (see
    /// `itemPathsCutOff`).
    func copyEnemyPathsToItemPaths(excluding excluded: Set<Int>) {
        let (groups, newIndex) = Self.keptGroups(enph, excluding: excluded.union(itemPathsCutOff(excluding: excluded)))
        itpt = []
        itph = []
        for (g, var entry) in groups {
            let start = itpt.count
            for i in Int(enph[g].startIndex)..<Int(enph[g].startIndex) + Int(enph[g].pointCount) where enpt.indices.contains(i) {
                itpt.append(ITPTEntry(position: enpt[i].position, radius: enpt[i].radius, fileScale: enpt[i].fileScale))
            }
            entry.startIndex = UInt8(min(start, 255))
            entry.pointCount = UInt8(itpt.count - start)
            entry.settings = 0
            entry.bol = nil
            entry.previousGroups = Self.remapLinks(entry.previousGroups, newIndex)
            entry.nextGroups = Self.remapLinks(entry.nextGroups, newIndex)
            itph.append(entry)
        }
        // Enemy paths don't always list a link from both ends (old_garden_ds); every retail item
        // path does, so fill in the missing halves.
        for i in itph.indices {
            for n in itph[i].nextGroups where n != 0xFF && !itph[Int(n)].previousGroups.contains(UInt8(i)) {
                if let slot = itph[Int(n)].previousGroups.firstIndex(of: 0xFF) { itph[Int(n)].previousGroups[slot] = UInt8(i) }
            }
            for p in itph[i].previousGroups where p != 0xFF && !itph[Int(p)].nextGroups.contains(UInt8(i)) {
                if let slot = itph[Int(p)].nextGroups.firstIndex(of: 0xFF) { itph[Int(p)].nextGroups[slot] = UInt8(i) }
            }
        }
    }

    /// Enemy path groups that leaving out `excluded` would leave with nothing leading into them or
    /// nowhere to go, e.g. the rest of a shortcut whose off-road entry was left out, or an enemy
    /// path only CPUs respawning use (old_town_ds, treehouse_course have one). Every retail
    /// race track's item paths have both, and one with no previous path crashed the game (a null
    /// read) as soon as the first item was picked up, so these are left out too.
    func itemPathsCutOff(excluding excluded: Set<Int>) -> Set<Int> {
        // A link counts from either end: enemy paths don't always list both.
        var into = [Set<Int>](repeating: [], count: enph.count), outOf = into
        for (i, g) in enph.enumerated() {
            for n in g.nextGroups where n != 0xFF && Int(n) < enph.count { outOf[i].insert(Int(n)); into[Int(n)].insert(i) }
            for p in g.previousGroups where p != 0xFF && Int(p) < enph.count { into[i].insert(Int(p)); outOf[Int(p)].insert(i) }
        }
        var out = excluded
        while true {
            let kept = enph.indices.filter { !out.contains($0) }
            let cut = kept.filter { into[$0].isDisjoint(with: kept) || outOf[$0].isDisjoint(with: kept) }
            guard !cut.isEmpty else { return out.subtracting(excluded) }
            out.formUnion(cut)
        }
    }

    private static func keptGroups(_ groups: [PathLinkEntry], excluding excluded: Set<Int>) -> ([(Int, PathLinkEntry)], [Int: UInt8]) {
        let kept = groups.indices.filter { !excluded.contains($0) }
        var newIndex: [Int: UInt8] = [:]
        for (k, g) in kept.enumerated() { newIndex[g] = UInt8(k) }
        return (kept.map { ($0, groups[$0]) }, newIndex)
    }

    private static func remapLinks(_ links: [UInt8], _ newIndex: [Int: UInt8]) -> [UInt8] {
        let mapped = links.compactMap { $0 == 0xFF ? nil : newIndex[Int($0)] }
        return Array((mapped + Array(repeating: 0xFF, count: links.count)).prefix(links.count))
    }
}
