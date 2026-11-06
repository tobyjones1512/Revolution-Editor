import SwiftUI
import SceneKit
import AppKit
import Combine

/// "Intro Cameras" (KMP editor header): builds and plays back a track's opening pan, the CAME
/// chain that starts at the header's opening index, over the course model in 3D. Playback is
/// `KMPCameraSequence.simulate`, frame for frame at 60fps; see that type for the rules it follows.
///
/// Workflow: fly the Free view to a spot, then use the "← View" buttons to drop a shot's route
/// start/end or look-at points there, and "Fit to Duration" to make it finish on time.
struct CameraSequenceEditorView: View {
    @ObservedObject var box: KMPDocumentBox
    let courseModel: MDL0Model?
    let textures: [String: DecodedTexture]
    /// Records an undo step in the KMP editor's history.
    let onCommit: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var selected: Int?
    @State private var frame = 0
    @State private var playing = false
    @State private var loop = true
    @State private var shotView = true
    /// Bumped on every edit, so the preview rebuilds its route/look-at guides.
    @State private var revision = 0
    @State private var confirmStandard = false
    @StateObject private var probe = PreviewProbe()
    private let tick = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    private var order: [Int] { KMPCameraSequence.chain(in: box.doc) }
    private var frames: [KMPCameraSequence.Frame] { KMPCameraSequence.simulate(box.doc) }

    var body: some View {
        let frames = frames
        VStack(spacing: 0) {
            HStack {
                Text("Intro Cameras").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(10)
            Divider()
            HSplitView {
                sidebar.frame(minWidth: 300, idealWidth: 330, maxWidth: 420)
                VStack(spacing: 0) {
                    preview(frames)
                    Divider()
                    transport(frames)
                }
                .frame(minWidth: 480)
            }
        }
        .frame(minWidth: 960, minHeight: 620)
        .onReceive(tick) { _ in
            guard playing, !frames.isEmpty else { return }
            if frame + 1 < frames.count { frame += 1 } else if loop { frame = 0 } else { playing = false }
        }
        .confirmationDialog("Replace the intro with a standard 3-shot sequence?", isPresented: $confirmStandard) {
            Button("Replace Intro", role: .destructive) { makeStandard() }
        } message: {
            Text("The current intro's \(order.count) camera(s), and routes only they use, are removed.")
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button { confirmStandard = !order.isEmpty; if order.isEmpty { makeStandard() } } label: {
                        Label("Standard Intro", systemImage: "wand.and.stars")
                    }
                    .help("Nintendo's usual three shots (220, 257, 294 frames): a high overview, a sweep across the far side of the track, then a swoop in on the start line.")
                    Button { addShot() } label: { Label("Add Shot", systemImage: "plus") }
                        .help("Adds a shot at the end of the intro, starting at the Free view's camera position.")
                }
                shotList
                if let selected, box.doc.came.indices.contains(selected) {
                    Divider()
                    shotInspector(selected)
                }
                if !box.doc.came.isEmpty {
                    let others = box.doc.came.indices.filter { !order.contains($0) }
                    if !others.isEmpty {
                        Divider()
                        Menu("Add Existing Camera") {
                            ForEach(others, id: \.self) { c in
                                Button("Camera \(c + 1) (type \(box.doc.came[c].type))") { edit("Add Camera to Intro") { KMPCameraSequence.setChain(order + [c], in: box.doc) } }
                            }
                        }
                        .help("Links a camera that isn't part of the intro onto its end.")
                    }
                }
            }
            .padding(10)
        }
    }

    private var shotList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Shots").font(.caption).foregroundStyle(.secondary)
            if order.isEmpty {
                Text("No intro yet, make a Standard Intro or Add Shot.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(order.enumerated()), id: \.element) { k, c in
                let cam = box.doc.came[c]
                HStack {
                    Circle().fill(Self.color(k)).frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Shot \(k + 1) · Camera \(c + 1)").font(.callout)
                        Text("\(Int(cam.time)) frames · \(String(format: "%.1f", cam.time / 60))s · type \(cam.type)").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { move(k, by: -1) } label: { Image(systemName: "chevron.up") }.disabled(k == 0).buttonStyle(.borderless)
                    Button { move(k, by: 1) } label: { Image(systemName: "chevron.down") }.disabled(k == order.count - 1).buttonStyle(.borderless)
                    Menu {
                        Button("Remove from Intro") { edit("Remove Shot from Intro") { KMPCameraSequence.unlink(c, in: box.doc) }; selected = nil }
                        Button("Delete Camera and Its Route", role: .destructive) {
                            edit("Delete Shot") { KMPCameraSequence.removeCamera(c, in: box.doc, removingOwnRoute: true) }; selected = nil
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                .padding(6)
                .background(selected == c ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .onTapGesture { select(c) }
            }
            if !order.isEmpty {
                Text("Total \(frames.count) frames (\(String(format: "%.1f", Double(frames.count) / 60))s). Retail intros are 771 frames.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func shotInspector(_ c: Int) -> some View {
        let cam = box.doc.came[c]
        let route = Int(cam.routeID)
        VStack(alignment: .leading, spacing: 10) {
            Text("Camera \(c + 1)").font(.subheadline.bold())
            Picker("Type", selection: binding(c, \.type, "Change Camera Type")) {
                Text("5: Opening, rides route").tag(UInt8(5))
                Text("6: Opening, player-relative").tag(UInt8(6))
                Text("1: Fixed position").tag(UInt8(1))
                if ![1, 5, 6].contains(cam.type) { Text("\(cam.type): other").tag(cam.type) }
            }
            if cam.type == 6 { hint("Type 6 moves relative to the player, so this preview (which has no player) only approximates it.") }

            row("Duration (frames)") { number(Float(cam.time)) { v in edit("Shot Duration") { box.doc.came[c].time = max(1, v.rounded()) } } }
            HStack {
                Text("Zoom (FOV°)").font(.caption)
                Spacer()
                number(cam.zoomStart) { v in edit("Zoom Start") { box.doc.came[c].zoomStart = v } }
                Text("→").foregroundStyle(.secondary)
                number(cam.zoomEnd) { v in edit("Zoom End") { box.doc.came[c].zoomEnd = v } }
            }

            vec3("Look Start", cam.viewPositionStart) { v in edit("Look Start") { box.doc.came[c].viewPositionStart = v } }
            captureButton("Look Start ← View Target") { _, target in box.doc.came[c].viewPositionStart = target }
            vec3("Look End", cam.viewPositionEnd) { v in edit("Look End") { box.doc.came[c].viewPositionEnd = v } }
            captureButton("Look End ← View Target") { _, target in box.doc.came[c].viewPositionEnd = target }

            Divider()
            if box.doc.poti.indices.contains(route) {
                let r = box.doc.poti[route]
                Text("Route \(route + 1) · \(r.points.count) points · \(Int(KMPCameraSequence.RoutePath(r).length)) units").font(.caption).foregroundStyle(.secondary)
                Toggle("Smooth", isOn: Binding(get: { r.isSmooth }, set: { v in edit("Route Smooth") { box.doc.poti[route].isSmooth = v } }))
                if r.isSmooth, r.points.count <= 2 { warning("Smooth on 2 or fewer points freezes the game.") }
                ForEach(Array(r.points.indices), id: \.self) { p in
                    HStack(alignment: .bottom) {
                        vec3(box.doc.isBOL ? "Point \(p + 1)" : "Point \(p + 1) · speed \(r.points[p].setting1)", r.points[p].position) { v in edit("Route Point") { box.doc.poti[route].points[p].position = v } }
                        Button { capture("Route Point ← View") { eye, _ in box.doc.poti[route].points[p].position = eye } } label: { Image(systemName: "scope") }
                            .buttonStyle(.borderless).help("Move this point to the Free view's camera position.")
                            .disabled(shotView)
                    }
                }
                HStack {
                    Button("Add Point") {
                        edit("Add Route Point") {
                            let last = box.doc.poti[route].points.last?.position ?? cam.position
                            box.doc.poti[route].points.append(RoutePoint(position: last + Vec3(x: 1000, y: 0, z: 0), setting1: box.doc.poti[route].points.last?.setting1 ?? 0))
                        }
                    }
                    Button("Remove Last") { edit("Remove Route Point") { _ = box.doc.poti[route].points.popLast() } }.disabled(r.points.count <= 2)
                }
            } else {
                vec3("Position", cam.position) { v in edit("Camera Position") { box.doc.came[c].position = v } }
                captureButton("Position ← View") { eye, _ in box.doc.came[c].position = eye }
                if box.doc.isBOL ? [1, 4, 5].contains(cam.type) : (cam.type == 5 || cam.type == 6) { warning("This camera type rides a Route; pick one.") }
            }

            Divider()
            if box.doc.isBOL {
                row("Route speed") { number(Float(cam.pointVelocity)) { v in edit("Route Speed") { box.doc.came[c].pointVelocity = UInt16(clamping: Int(v)) } } }
                Button { edit("Fit Shot to Duration") { KMPCameraSequence.fitSpeeds(camera: c, in: box.doc) } } label: {
                    Label("Fit Route Speed to Duration", systemImage: "timer")
                }
                .help("Sets the route speed so the camera reaches the end of its route as the shot ends.")
                hint("Double Dash: route speed in units/frame; the look-at point and zoom always go from start to end over the Duration.")
            } else {
                HStack {
                    row("Look speed") { number(Float(cam.viewVelocity)) { v in edit("Look Speed") { box.doc.came[c].viewVelocity = UInt16(clamping: Int(v)) } } }
                    row("Zoom speed") { number(Float(cam.zoomVelocity)) { v in edit("Zoom Speed") { box.doc.came[c].zoomVelocity = UInt16(clamping: Int(v)) } } }
                }
                Button { edit("Fit Shot to Duration") { KMPCameraSequence.fitSpeeds(camera: c, in: box.doc) } } label: {
                    Label("Fit Speeds to Duration", systemImage: "timer")
                }
                .help("Sets the route, look and zoom speeds so each finishes exactly as the shot ends.")
                hint("Speeds: route points in units/frame; look and zoom in units per 100 frames. Anything that finishes early holds still.")
            }
        }
    }

    // MARK: Preview

    private func preview(_ frames: [KMPCameraSequence.Frame]) -> some View {
        let current = frames.indices.contains(frame) ? frames[frame] : nil
        return ZStack(alignment: .topLeading) {
            Color.black
            CameraPreviewSCNView(courseModel: courseModel, textures: textures, doc: box.doc, order: order,
                                 selected: selected, revision: revision, frame: current, shotView: shotView, probe: probe)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 2) {
                if let current, let k = order.firstIndex(of: current.camera) {
                    Text("Shot \(k + 1) · frame \(current.localFrame + 1)/\(Int(box.doc.came[current.camera].time)) · FOV \(String(format: "%.1f", current.fov))°")
                }
                if courseModel == nil { Text("No course model loaded, load one in the KMP editor to see the track.") }
                if !shotView { Text("Free view: drag to orbit, scroll to zoom, then use the ← View buttons.") }
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.white)
            .padding(6).background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6)).padding(8)
        }
    }

    private func transport(_ frames: [KMPCameraSequence.Frame]) -> some View {
        HStack(spacing: 10) {
            Button { if frame + 1 >= frames.count { frame = 0 }; playing.toggle() } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
            }
            .shortcut(.playPause)
            .disabled(frames.isEmpty)
            Button { frame = 0 } label: { Image(systemName: "backward.end.fill") }.disabled(frames.isEmpty)
            Slider(value: Binding(get: { Double(min(frame, max(0, frames.count - 1))) }, set: { frame = Int($0); playing = false }),
                   in: 0...Double(max(1, frames.count - 1)))
                .disabled(frames.isEmpty)
            Text("\(String(format: "%.2f", Double(frame) / 60))s").font(.caption.monospacedDigit()).frame(width: 50)
            Toggle("Loop", isOn: $loop).toggleStyle(.checkbox)
            Picker("", selection: $shotView) {
                Text("Shot View").tag(true)
                Text("Free View").tag(false)
            }
            .pickerStyle(.segmented).fixedSize()
        }
        .padding(8)
    }

    // MARK: Actions

    private func edit(_ label: String, _ change: () -> Void) {
        change()
        box.isDirty = true
        box.objectWillChange.send()
        revision += 1
        onCommit(label)
    }

    private func select(_ c: Int) {
        selected = c
        playing = false
        var start = 0
        for o in order { if o == c { break }; start += max(1, Int(box.doc.came[o].time.rounded())) }
        frame = start
    }

    private func move(_ k: Int, by delta: Int) {
        var o = order
        o.swapAt(k, k + delta)
        edit("Reorder Shots") { KMPCameraSequence.setChain(o, in: box.doc) }
    }

    private func bounds() -> (Vec3, Vec3) {
        if let b = KMPCameraSequence.trackBounds(box.doc) { return b }
        if let m = courseModel, !m.meshes.isEmpty { return (m.boundsMin, m.boundsMax) }
        return (Vec3(x: -10000, y: 0, z: -10000), Vec3(x: 10000, y: 1000, z: 10000))
    }

    private func makeStandard() {
        let (lo, hi) = bounds()
        edit("Standard Intro") { KMPCameraSequence.makeStandardIntro(in: box.doc, boundsMin: lo, boundsMax: hi) }
        selected = order.first
        frame = 0
    }

    private func addShot() {
        let (lo, hi) = bounds()
        let center = (lo + hi) * 0.5
        let pose = shotView ? nil : probe.pose()
        let eye = pose?.eye ?? center + Vec3(x: 0, y: max(hi.y - lo.y, 1000) + 2000, z: (hi.z - lo.z) * 0.4)
        let target = pose?.target ?? center
        let toward = (target - eye)
        let side = Vec3.cross(toward, Vec3(x: 0, y: 1, z: 0)).normalized() * max(1500, toward.length * 0.3)
        var index: Int?
        edit("Add Shot") { index = KMPCameraSequence.appendShot(to: box.doc, from: eye, to: eye + side, lookStart: target, lookEnd: target) }
        if let index { select(index) }
    }

    private func capture(_ label: String, _ apply: (Vec3, Vec3) -> Void) {
        guard let pose = probe.pose() else { return }
        edit(label) { apply(pose.eye, pose.target) }
    }

    // MARK: Small views

    private func captureButton(_ title: String, _ apply: @escaping (Vec3, Vec3) -> Void) -> some View {
        Button(title) { capture(title, apply) }
            .font(.caption)
            .disabled(shotView)
            .help(shotView ? "Switch to Free View and fly to the spot first." : "Uses the Free view's current camera.")
    }

    private func binding<T>(_ c: Int, _ key: WritableKeyPath<CAMEEntry, T>, _ label: String) -> Binding<T> {
        Binding(get: { box.doc.came[c][keyPath: key] }, set: { v in edit(label) { box.doc.came[c][keyPath: key] = v } })
    }

    private func number(_ value: Float, _ set: @escaping (Float) -> Void) -> some View {
        TextField("", value: Binding(get: { value }, set: set), format: .number)
            .textFieldStyle(.roundedBorder).frame(width: 64)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack { Text(label).font(.caption); Spacer(); content() }
    }

    private func vec3(_ label: String, _ v: Vec3, _ set: @escaping (Vec3) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                number(v.x) { set(Vec3(x: $0, y: v.y, z: v.z)) }
                number(v.y) { set(Vec3(x: v.x, y: $0, z: v.z)) }
                number(v.z) { set(Vec3(x: v.x, y: v.y, z: $0)) }
            }
        }
    }

    private func hint(_ s: String) -> some View { Text(s).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    private func warning(_ s: String) -> some View {
        Label(s, systemImage: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
    }

    static func color(_ k: Int) -> Color { [Color.orange, .cyan, .pink, .green, .yellow, .purple][k % 6] }
    static func nsColor(_ k: Int) -> NSColor { [NSColor.systemOrange, .systemTeal, .systemPink, .systemGreen, .systemYellow, .systemPurple][k % 6] }
}

/// Lets the SwiftUI side read the Free view's camera without owning the `SCNView`.
@MainActor final class PreviewProbe: ObservableObject {
    weak var view: SCNView?

    func pose() -> (eye: Vec3, target: Vec3)? {
        guard let view, let pov = view.pointOfView else { return nil }
        let p = pov.worldPosition
        let eye = Vec3(x: Float(p.x), y: Float(p.y), z: Float(p.z))
        let t = view.defaultCameraController.target
        var target = Vec3(x: Float(t.x), y: Float(t.y), z: Float(t.z))
        if (target - eye).length < 1 {
            let f = pov.worldFront
            target = eye + Vec3(x: Float(f.x), y: Float(f.y), z: Float(f.z)) * 3000
        }
        return (eye, target)
    }
}

/// The 3D preview: course model, every intro shot's route (and look-at line) in its shot colour,
/// and a camera that either plays the current frame (Shot view) or orbits freely (Free view) with
/// a marker showing where the shot camera is.
private struct CameraPreviewSCNView: NSViewRepresentable {
    let courseModel: MDL0Model?
    let textures: [String: DecodedTexture]
    let doc: KMPDocument
    let order: [Int]
    let selected: Int?
    let revision: Int
    let frame: KMPCameraSequence.Frame?
    let shotView: Bool
    let probe: PreviewProbe

    final class Coordinator {
        let scene = SCNScene()
        let shotCamera = SCNNode()
        let freeCamera = SCNNode()
        let guides = SCNNode()
        let marker = SCNNode()
        var builtRevision = -1
        var builtSelected: Int?
        var wasShotView: Bool?
        var extent: Float = 60000
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let c = context.coordinator
        var extent: Float
        if let courseModel, !courseModel.meshes.isEmpty {
            c.scene.rootNode.addChildNode(MDL0SceneKit.node(for: courseModel, textures: textures))
            let lo = courseModel.boundsMin, hi = courseModel.boundsMax
            extent = max(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z, 5000)
        } else {
            extent = 60000
            let floor = SCNFloor()
            floor.reflectivity = 0
            floor.firstMaterial?.diffuse.contents = NSColor(white: 0.18, alpha: 1)
            c.scene.rootNode.addChildNode(SCNNode(geometry: floor))
        }
        c.extent = extent
        for node in [c.shotCamera, c.freeCamera] {
            let cam = SCNCamera()
            cam.zNear = 10
            cam.zFar = Double(extent) * 6
            node.camera = cam
            c.scene.rootNode.addChildNode(node)
        }
        c.freeCamera.position = SCNVector3(0, CGFloat(extent) * 0.6, CGFloat(extent) * 0.8)
        c.freeCamera.look(at: SCNVector3Zero)
        let light = SCNNode()
        light.light = SCNLight()
        light.light?.type = .directional
        light.light?.intensity = 900
        light.eulerAngles = SCNVector3(-CGFloat.pi / 3, CGFloat.pi / 4, 0)
        c.scene.rootNode.addChildNode(light)
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 350
        c.scene.rootNode.addChildNode(ambient)
        c.scene.rootNode.addChildNode(c.guides)
        let body = SCNSphere(radius: CGFloat(extent) * 0.006)
        body.firstMaterial?.diffuse.contents = NSColor.white
        body.firstMaterial?.lightingModel = .constant
        c.marker.geometry = body
        c.scene.rootNode.addChildNode(c.marker)

        let view = SCNView()
        view.scene = c.scene
        view.backgroundColor = NSColor(calibratedRed: 0.45, green: 0.62, blue: 0.85, alpha: 1)
        view.antialiasingMode = .multisampling4X
        probe.view = view
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        let c = context.coordinator
        if c.builtRevision != revision || c.builtSelected != selected {
            c.builtRevision = revision
            c.builtSelected = selected
            rebuildGuides(c.guides, dotSize: CGFloat(c.extent) * 0.003)
        }
        if let frame {
            c.shotCamera.camera?.fieldOfView = CGFloat(max(1, min(170, frame.fov)))
            c.shotCamera.position = scn(frame.eye)
            c.shotCamera.look(at: scn(frame.target), up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
            c.marker.position = scn(frame.eye)
        }
        c.marker.isHidden = shotView || frame == nil
        c.guides.isHidden = shotView
        if c.wasShotView != shotView {
            c.wasShotView = shotView
            view.pointOfView = shotView ? c.shotCamera : c.freeCamera
            view.allowsCameraControl = !shotView
            if !shotView { view.defaultCameraController.interactionMode = .orbitTurntable }
        }
    }

    private func scn(_ v: Vec3) -> SCNVector3 { SCNVector3(CGFloat(v.x), CGFloat(v.y), CGFloat(v.z)) }

    private func rebuildGuides(_ root: SCNNode, dotSize: CGFloat) {
        root.childNodes.forEach { $0.removeFromParentNode() }
        for (k, c) in order.enumerated() {
            let cam = doc.came[c]
            let color = CameraSequenceEditorView.nsColor(k).withAlphaComponent(selected == nil || selected == c ? 1 : 0.35)
            if doc.poti.indices.contains(Int(cam.routeID)) {
                let path = KMPCameraSequence.RoutePath(doc.poti[Int(cam.routeID)])
                root.addChildNode(line(path.points.map(scn), color))
                for p in doc.poti[Int(cam.routeID)].points { root.addChildNode(dot(p.position, color, dotSize)) }
            }
            root.addChildNode(line([scn(cam.viewPositionStart), scn(cam.viewPositionEnd)], color.blended(withFraction: 0.5, of: .white) ?? color))
            root.addChildNode(dot(cam.viewPositionStart, color, dotSize * 0.6))
            root.addChildNode(dot(cam.viewPositionEnd, color, dotSize * 1.4))
        }
    }

    private func line(_ points: [SCNVector3], _ color: NSColor) -> SCNNode {
        guard points.count > 1 else { return SCNNode() }
        let source = SCNGeometrySource(vertices: points)
        var indices: [Int32] = []
        for i in 0..<(points.count - 1) { indices += [Int32(i), Int32(i + 1)] }
        let geometry = SCNGeometry(sources: [source], elements: [SCNGeometryElement(indices: indices, primitiveType: .line)])
        geometry.firstMaterial?.diffuse.contents = color
        geometry.firstMaterial?.lightingModel = .constant
        geometry.firstMaterial?.readsFromDepthBuffer = false
        let node = SCNNode(geometry: geometry)
        node.renderingOrder = 10
        return node
    }

    private func dot(_ p: Vec3, _ color: NSColor, _ radius: CGFloat) -> SCNNode {
        let s = SCNSphere(radius: radius)
        s.firstMaterial?.diffuse.contents = color
        s.firstMaterial?.lightingModel = .constant
        s.firstMaterial?.readsFromDepthBuffer = false
        let node = SCNNode(geometry: s)
        node.position = scn(p)
        node.renderingOrder = 11
        return node
    }
}
