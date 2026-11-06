import Foundation

/// Path-group (ENPH/ITPH/CKPH) bookkeeping shared by the KMP editor and the Hot Swap checks'
/// Auto Correct: no editor types, just a group list and its point array.
nonisolated extension KMPDocument {
    static func insertIndexForLastGroup(_ groups: [PathLinkEntry], arrayCount: Int) -> Int {
        guard let last = groups.last, last.pointCount < 255 else { return arrayCount }
        return Int(last.startIndex) + Int(last.pointCount)
    }

    static func appendToLastGroup(_ groups: inout [PathLinkEntry], insertedAt: Int) {
        guard let last = groups.indices.last else {
            groups.append(PathLinkEntry(startIndex: 0, pointCount: 1))
            return
        }
        if groups[last].pointCount == 255 {
            groups.append(PathLinkEntry(startIndex: UInt8(insertedAt), pointCount: 1))
            return
        }
        groups[last].pointCount += 1
        for i in groups.indices where i != last && groups[i].startIndex >= insertedAt {
            groups[i].startIndex += 1
        }
    }

    /// Deletes path groups nothing leads into (no previous group), repeatedly, keeping at least
    /// one. Returns how many went. For item paths: the game reads a missing previous group as a
    /// null pointer once items are in play.
    @discardableResult
    static func removeUnreachableGroups<T>(groups: inout [PathLinkEntry], points: inout [T]) -> Int {
        var removed = 0
        while groups.count > 1, let g = groups.firstIndex(where: { $0.previousGroups.allSatisfy { $0 == 0xFF } }) {
            deleteGroup(groups: &groups, points: &points, index: g)
            removed += 1
        }
        return removed
    }

    /// Removes one path point, shrinking its group, and the group too if that empties it.
    static func removePathPoint<T>(_ index: Int, groups: inout [PathLinkEntry], points: inout [T]) {
        guard points.indices.contains(index) else { return }
        let owner = groups.firstIndex { index >= Int($0.startIndex) && index < Int($0.startIndex) + Int($0.pointCount) }
        points.remove(at: index)
        shrinkGroupContaining(&groups, index: index)
        if let owner, groups[owner].pointCount == 0 { deleteGroup(groups: &groups, points: &points, index: owner) }
    }

    /// Moves `selected` points (in path order) into a new group after the others. A run cut off the
    /// end (or start) of one group is linked in after (or before) what's left of it, so the path
    /// stays connected; anything else starts unlinked. Groups left empty are deleted. Returns each
    /// old point index's new index, or nil if nothing moved.
    static func separate<T>(_ selected: Set<Int>, groups: inout [PathLinkEntry], points: inout [T]) -> [Int]? {
        guard groups.count < 255 else { return nil }
        var lists = groups.map { g in Array(Int(g.startIndex)..<min(points.count, Int(g.startIndex) + Int(g.pointCount))) }
        let moved = lists.flatMap { $0.filter(selected.contains) }
        guard let first = moved.first, let owner = lists.firstIndex(where: { $0.contains(first) }) else { return nil }
        let ownerList = lists[owner]
        let isRun = moved.count < ownerList.count && moved.allSatisfy(ownerList.contains) && moved == Array(first...moved.last!)
        let newIndex = UInt8(groups.count)
        var new = PathLinkEntry()
        func replace(_ links: inout [UInt8]) { links = links.map { $0 == UInt8(owner) ? newIndex : $0 } }
        func only(_ g: UInt8) -> [UInt8] { [g, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF] }
        if isRun && moved.last == ownerList.last {
            new.nextGroups = groups[owner].nextGroups
            for g in groups.indices { replace(&groups[g].previousGroups) }
            groups[owner].nextGroups = only(newIndex)
            new.previousGroups = only(UInt8(owner))
        } else if isRun && first == ownerList.first {
            new.previousGroups = groups[owner].previousGroups
            for g in groups.indices { replace(&groups[g].nextGroups) }
            groups[owner].previousGroups = only(newIndex)
            new.nextGroups = only(UInt8(owner))
        }
        for i in lists.indices { lists[i].removeAll(where: selected.contains) }
        groups.append(new)
        lists.append(moved)
        // Rebuild the points in group order (any ungrouped ones last), then drop emptied groups.
        let grouped = Set(lists.joined())
        let order = Array(lists.joined()) + points.indices.filter { !grouped.contains($0) }
        var map = [Int](repeating: 0, count: points.count)
        for (k, old) in order.enumerated() { map[old] = k }
        points = order.map { points[$0] }
        var start = 0
        for g in groups.indices {
            groups[g].startIndex = UInt8(min(start, 255))
            groups[g].pointCount = UInt8(lists[g].count)
            start += lists[g].count
        }
        for g in groups.indices.reversed() where groups[g].pointCount == 0 { deleteGroup(groups: &groups, points: &points, index: g) }
        return map
    }

    static func shrinkGroupContaining(_ groups: inout [PathLinkEntry], index: Int) {
        for i in groups.indices {
            let start = Int(groups[i].startIndex), count = Int(groups[i].pointCount)
            if index >= start && index < start + count, groups[i].pointCount > 0 { groups[i].pointCount -= 1 }
            if groups[i].startIndex > index { groups[i].startIndex -= 1 }
        }
    }

    static func deleteGroup<T>(groups: inout [PathLinkEntry], points: inout [T], index: Int) {
        guard groups.indices.contains(index) else { return }
        let start = Int(groups[index].startIndex), count = Int(groups[index].pointCount)
        if count > 0 && start + count <= points.count { points.removeSubrange(start..<(start + count)) }
        for i in groups.indices where groups[i].startIndex > start {
            groups[i].startIndex = UInt8(max(0, Int(groups[i].startIndex) - count))
        }
        groups.remove(at: index)
        let removed = UInt8(index)
        func fix(_ links: [UInt8]) -> [UInt8] {
            links.map { $0 == removed ? 0xFF : ($0 != 0xFF && $0 > removed ? $0 - 1 : $0) }
        }
        for i in groups.indices {
            groups[i].previousGroups = fix(groups[i].previousGroups)
            groups[i].nextGroups = fix(groups[i].nextGroups)
        }
    }
}
