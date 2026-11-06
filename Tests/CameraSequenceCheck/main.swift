// Checks KMPCameraSequence against every retail course's intro, and that generated shots land
// where they're meant to.
//
//   swiftc -O -o /tmp/camcheck \
//     "Revolution IDE/Core/"{BinaryIO,DiscModel,WiiDisc,Crypto,ClusterCrypto,KeyManager,FSTBuilder,GameCubeDisc}.swift \
//     "Revolution IDE/Core/Formats/"{Yaz0,U8Archive,SZS,MathTypes,KMP,KMPCameraSequence,GOBJNames}.swift \
//     "Revolution IDE/Core/Formats/MKDD/"{BOL,BOLObjectNames,RARC}.swift \
//     Tests/CameraSequenceCheck/main.swift
//   /tmp/camcheck <iso> <common-key>

import Foundation

var failures = 0
func check(_ ok: Bool, _ what: @autoclosure () -> String) { if !ok { failures += 1; print("FAIL \(what())") } }
func near(_ a: Vec3, _ b: Vec3, _ tol: Float) -> Bool { (a - b).length <= tol }

// Generated shots, on a blank track.
let doc = KMPDocument()
doc.ktpt = [KTPTEntry(position: Vec3(x: 0, y: 100, z: 0), rotation: Vec3(x: 0, y: 90, z: 0))]
KMPCameraSequence.makeStandardIntro(in: doc, boundsMin: Vec3(x: -20000, y: 0, z: -20000), boundsMax: Vec3(x: 20000, y: 3000, z: 20000))
let order = KMPCameraSequence.chain(in: doc)
check(order.count == 3, "standard intro has \(order.count) shots")
check(order.map { doc.came[$0].time } == [220, 257, 294], "shot times \(order.map { doc.came[$0].time })")
for c in order {
    let cam = doc.came[c]
    let frames = KMPCameraSequence.simulate(cam, index: c, in: doc)
    let route = doc.poti[Int(cam.routeID)]
    check(route.points.count == 3 && route.isSmooth, "shot \(c) route")
    check(near(frames.last!.eye, route.points.last!.position, 1), "shot \(c) ends at route end (\(frames.last!.eye) vs \(route.points.last!.position))")
    check(near(frames.last!.target, cam.viewPositionEnd, 1), "shot \(c) ends looking at View End")
    check(abs(frames.last!.fov - cam.zoomEnd) < 0.1, "shot \(c) ends at Zoom End")
}
// Survives a save.
let back = try KMPDocument.parse(doc.serialize())
check(KMPCameraSequence.chain(in: back) == order, "chain survives serialize")
// Reorder + remove keep the chain consistent.
KMPCameraSequence.setChain(order.reversed(), in: doc)
check(KMPCameraSequence.chain(in: doc) == order.reversed(), "reorder")
KMPCameraSequence.removeCamera(order[1], in: doc, removingOwnRoute: true)
check(KMPCameraSequence.chain(in: doc).count == 2 && doc.poti.count == 2, "remove middle shot: chain \(KMPCameraSequence.chain(in: doc)), routes \(doc.poti.count)")

// Retail intros: how far along its route each shot gets. If the speed units were wrong this would
// be ~0 or pinned at 1 on the very first frames.
if CommandLine.arguments.count > 2 {
    let disc = try WiiDisc(url: URL(fileURLWithPath: CommandLine.arguments[1]),
                           commonKey: [UInt8](try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))), koreanKey: nil)
    var courses: [DiscNode] = []
    func walk(_ n: DiscNode) { if n.isDirectory { n.children.forEach(walk) } else if n.name.hasSuffix("_course.szs") { courses.append(n) } }
    walk(disc.root)
    var fractions: [Float] = []
    for node in courses {
        guard let data = try? disc.readFile(node: node), let (root, _) = try? SZS.open(data),
              let kmp = root.children.first(where: { $0.name == "course.kmp" })?.data,
              let d = try? KMPDocument.parse(kmp) else { continue }
        let chain = KMPCameraSequence.chain(in: d)
        check(!chain.isEmpty, "\(node.name) has no intro chain")
        var line = "\(node.name):"
        for c in chain where d.poti.indices.contains(Int(d.came[c].routeID)) {
            let path = KMPCameraSequence.RoutePath(d.poti[Int(d.came[c].routeID)])
            let last = KMPCameraSequence.simulate(d.came[c], index: c, in: d).last!.eye
            // Distance still to go along the route, from the last frame's position.
            let remaining = (last - d.poti[Int(d.came[c].routeID)].points.last!.position).length
            let f = path.length > 0 ? 1 - min(1, remaining / path.length) : 1
            fractions.append(f)
            line += String(format: " cam%d %.2f", c, f)
        }
        print(line)
    }
    let mean = fractions.reduce(0, +) / Float(max(1, fractions.count))
    print(String(format: "retail shots: %d, mean fraction of route travelled %.2f", fractions.count, mean))
    check(mean > 0.6 && mean <= 1, "retail route travel looks wrong (mean \(mean))")
}
// Double Dash: no look/zoom speeds and no per-point route speeds (they read as 0 and froze the
// preview on one frame). The camera's Route Speed moves it; look and zoom span the Duration.
let bol = BOL.newDocument()
bol.ktpt = [KTPTEntry(position: Vec3(x: 0, y: 100, z: 0), rotation: Vec3(x: 0, y: 90, z: 0), playerIndex: -1)]
KMPCameraSequence.makeStandardIntro(in: bol, boundsMin: Vec3(x: -20000, y: 0, z: -20000), boundsMax: Vec3(x: 20000, y: 3000, z: 20000))
for c in KMPCameraSequence.chain(in: bol) {
    let cam = bol.came[c], frames = KMPCameraSequence.simulate(cam, index: c, in: bol)
    let route = bol.poti[Int(cam.routeID)]
    check(cam.pointVelocity > 0, "BOL shot \(c) has a route speed")
    check(!near(frames.first!.eye, frames.last!.eye, 100), "BOL shot \(c) moves")
    check(near(frames.last!.eye, route.points.last!.position, 1), "BOL shot \(c) ends at route end (\(frames.last!.eye) vs \(route.points.last!.position))")
    check(near(frames.last!.target, cam.viewPositionEnd, 1), "BOL shot \(c) ends looking at Look End")
    check(abs(frames.last!.fov - cam.zoomEnd) < 0.1, "BOL shot \(c) ends at Zoom End")
}

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
