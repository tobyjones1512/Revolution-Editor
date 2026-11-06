import Foundation

/// Copied course data (points, cameras, routes, ...) that can be pasted into any KMP or BOL
/// document, including one open in another window. Held in memory for the app's session.
///
/// Between the two games positions are scaled by the port factor; objects and areas are left out
/// (their IDs and types mean different things in each game). Path points paste as a new group, and
/// a camera or object brings its route along.
nonisolated struct KMPClipboard {
    static var current: KMPClipboard?

    var fromBOL = false
    var source: ObjectIdentifier?
    var ktpt: [KTPTEntry] = [], enpt: [ENPTEntry] = [], itpt: [ITPTEntry] = [], ckpt: [CKPTEntry] = []
    var gobj: [GOBJEntry] = [], jgpt: [JGPTEntry] = [], cnpt: [CNPTEntry] = [], mspt: [MSPTEntry] = []
    var area: [AREAEntry] = [], came: [CAMEEntry] = []
    /// Index in the source document of each copied camera (an area's camera link is kept if both are copied).
    var cameSource: [Int] = []
    var routes: [POTIRoute] = []
    var cameRoute: [Int?] = [], gobjRoute: [Int?] = []

    var count: Int { ktpt.count + enpt.count + itpt.count + ckpt.count + gobj.count + jgpt.count + cnpt.count + mspt.count + area.count + came.count + routes.count }
    var isEmpty: Bool { count == 0 }

    static func copy(from doc: KMPDocument, selection: Set<KMPSelection>) -> KMPClipboard? {
        var c = KMPClipboard(fromBOL: doc.isBOL, source: ObjectIdentifier(doc))
        func indices(_ pick: (KMPSelection) -> Int?) -> [Int] { Set(selection.compactMap { pick($0.asPoint) }).sorted() }
        func each<T>(_ array: [T], _ idx: [Int]) -> [T] { idx.filter(array.indices.contains).map { array[$0] } }
        c.ktpt = each(doc.ktpt, indices { if case .ktpt(let i) = $0 { return i }; return nil })
        c.enpt = each(doc.enpt, indices { if case .enpt(let i) = $0 { return i }; return nil })
        c.itpt = each(doc.itpt, indices { if case .itpt(let i) = $0 { return i }; return nil })
        c.ckpt = each(doc.ckpt, indices { if case .ckpt(let i) = $0 { return i }; return nil })
        c.gobj = each(doc.gobj, indices { if case .gobj(let i) = $0 { return i }; return nil })
        c.jgpt = each(doc.jgpt, indices { if case .jgpt(let i) = $0 { return i }; return nil })
        c.cnpt = each(doc.cnpt, indices { if case .cnpt(let i) = $0 { return i }; return nil })
        c.mspt = each(doc.mspt, indices { if case .mspt(let i) = $0 { return i }; return nil })
        c.area = each(doc.area, indices { if case .area(let i) = $0 { return i }; return nil })
        c.cameSource = indices { if case .came(let i) = $0 { return i }; return nil }.filter(doc.came.indices.contains)
        c.came = c.cameSource.map { doc.came[$0] }

        // Path groups selected as a whole bring their points.
        func groupPoints(_ groups: [PathLinkEntry], _ pick: (KMPSelection) -> Int?) -> [Int] {
            selection.compactMap(pick).filter(groups.indices.contains).flatMap { g in
                Int(groups[g].startIndex)..<(Int(groups[g].startIndex) + Int(groups[g].pointCount))
            }
        }
        let enphPoints = groupPoints(doc.enph) { if case .enph(let i) = $0 { return i }; return nil }
        let itphPoints = groupPoints(doc.itph) { if case .itph(let i) = $0 { return i }; return nil }
        let ckphPoints = groupPoints(doc.ckph) { if case .ckph(let i) = $0 { return i }; return nil }
        if !enphPoints.isEmpty { c.enpt = each(doc.enpt, Set(enphPoints + indices { if case .enpt(let i) = $0 { return i }; return nil }).sorted()) }
        if !itphPoints.isEmpty { c.itpt = each(doc.itpt, Set(itphPoints + indices { if case .itpt(let i) = $0 { return i }; return nil }).sorted()) }
        if !ckphPoints.isEmpty { c.ckpt = each(doc.ckpt, Set(ckphPoints + indices { if case .ckpt(let i) = $0 { return i }; return nil }).sorted()) }

        // Routes: those the copied cameras/objects use, plus any route or run of route points selected directly.
        func route(_ id: Int) -> Int? {
            guard doc.poti.indices.contains(id) else { return nil }
            c.routes.append(doc.poti[id]); return c.routes.count - 1
        }
        c.cameRoute = c.came.map { route(Int($0.routeID)) }
        c.gobjRoute = c.gobj.map { $0.routeID == 0xFFFF ? nil : route(Int($0.routeID)) }
        var byRoute: [Int: [Int]] = [:], whole = Set<Int>()
        for case .poti(let r, let p) in selection {
            if let p { byRoute[r, default: []].append(p) } else { whole.insert(r) }
        }
        for r in whole.sorted() { _ = route(r) }
        for (r, points) in byRoute.sorted(by: { $0.key < $1.key }) where doc.poti.indices.contains(r) && !whole.contains(r) {
            var part = doc.poti[r]
            part.points = points.sorted().filter(doc.poti[r].points.indices.contains).map { doc.poti[r].points[$0] }
            part.bol = nil
            c.routes.append(part)
        }
        return c.isEmpty ? nil : c
    }

    /// Pastes into `doc`; returns what was added (to select) and a note about anything left out.
    @discardableResult
    func paste(into doc: KMPDocument) -> (added: [KMPSelection], note: String?) {
        let cross = fromBOL != doc.isBOL
        let s: Float = !cross ? 1 : (fromBOL ? MKDDPort.defaultScale : MKWiiToMKDD.defaultScale)
        let keepRaw = fromBOL && doc.isBOL
        // Pasting into the file it came from would land exactly on top of the original.
        let nudge = source == ObjectIdentifier(doc) ? Vec3(x: 400 * s, y: 0, z: 400 * s) : Vec3()
        func p(_ v: Vec3) -> Vec3 { Vec3(x: v.x * s + nudge.x, y: v.y * s, z: v.z * s + nudge.z) }
        func p2(_ v: Vec2) -> Vec2 { Vec2(x: v.x * s + nudge.x, y: v.y * s + nudge.z) }
        var added: [KMPSelection] = []

        for var e in ktpt { e.position = p(e.position); if !keepRaw { e.bol = nil }; doc.ktpt.append(e); added.append(.ktpt(doc.ktpt.count - 1)) }
        for var e in jgpt { e.position = p(e.position); if !keepRaw { e.bol = nil }; doc.jgpt.append(e); added.append(.jgpt(doc.jgpt.count - 1)) }
        for var e in cnpt { e.position = p(e.position); doc.cnpt.append(e); added.append(.cnpt(doc.cnpt.count - 1)) }
        for var e in mspt { e.position = p(e.position); doc.mspt.append(e); added.append(.mspt(doc.mspt.count - 1)) }

        func group<T>(_ items: [T], points: inout [T], groups: inout [PathLinkEntry], make: (T) -> T, select: (Int) -> KMPSelection) {
            guard !items.isEmpty else { return }
            let start = points.count
            var entry = PathLinkEntry()
            entry.startIndex = UInt8(clamping: start); entry.pointCount = UInt8(clamping: items.count)
            for item in items { points.append(make(item)); added.append(select(points.count - 1)) }
            groups.append(entry)
        }
        group(enpt, points: &doc.enpt, groups: &doc.enph, make: { var e = $0; e.position = p(e.position); e.radius *= s; e.fileScale = nil; if !keepRaw { e.bol = nil }; return e }, select: { .enpt($0) })
        group(itpt, points: &doc.itpt, groups: &doc.itph, make: { var e = $0; e.position = p(e.position); e.radius *= s; e.fileScale = nil; return e }, select: { .itpt($0) })
        group(ckpt, points: &doc.ckpt, groups: &doc.ckph, make: { var e = $0; e.left = p2(e.left); e.right = p2(e.right); if !keepRaw { e.bol = nil }; return e }, select: { .ckpt($0) })

        // Routes, then the cameras and objects that point at them.
        var routeAt: [Int: Int] = [:]
        func addRoute(_ i: Int) -> Int {
            if let r = routeAt[i] { return r }
            var r = routes[i]
            r.points = r.points.map { var q = $0; q.position = p(q.position); if !keepRaw { q.bol = nil }; return q }
            if !keepRaw { r.bol = nil }
            doc.poti.append(r)
            routeAt[i] = doc.poti.count - 1
            return doc.poti.count - 1
        }
        let cameBase = doc.came.count
        for (i, var e) in came.enumerated() {
            e.position = p(e.position); e.viewPositionStart = p(e.viewPositionStart); e.viewPositionEnd = p(e.viewPositionEnd)
            if !keepRaw { e.bol = nil }
            e.routeID = cameRoute[i].map { UInt8(clamping: addRoute($0)) } ?? 0xFF
            e.next = 0xFF
            doc.came.append(e); added.append(.came(doc.came.count - 1))
        }
        var skipped: [String] = []
        if cross {
            if !gobj.isEmpty { skipped.append("\(gobj.count) object(s)") }
            if !area.isEmpty { skipped.append("\(area.count) area(s)") }
        } else {
            for (i, var e) in gobj.enumerated() {
                e.position = p(e.position)
                if !keepRaw { e.bol = nil }
                e.routeID = gobjRoute[i].map { UInt16(addRoute($0)) } ?? 0xFFFF
                doc.gobj.append(e); added.append(.gobj(doc.gobj.count - 1))
            }
            for var e in area {
                e.position = p(e.position)
                if !keepRaw { e.bol = nil }
                e.cameraIndex = cameSource.firstIndex(of: Int(e.cameraIndex)).map { UInt8(cameBase + $0) } ?? 0xFF
                doc.area.append(e); added.append(.area(doc.area.count - 1))
            }
        }
        // Routes copied on their own (not through a camera or object).
        let used = Set(cameRoute.compactMap { $0 } + gobjRoute.compactMap { $0 })
        for i in routes.indices where !used.contains(i) {
            let r = addRoute(i)
            added.append(.poti(route: r, point: nil))
        }
        let note = skipped.isEmpty ? nil : "Left out " + skipped.joined(separator: " and ") + ": their IDs and types differ between the games."
        return (added, note)
    }
}
