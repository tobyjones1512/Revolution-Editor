import SwiftUI
import SceneKit

/// `SCNView` subclass shared by every 3D preview in the app (model/collision-mesh viewers).
/// `allowsCameraControl`'s built-in gesture recognizers already give click+drag orbit and
/// pinch-to-zoom for free, but plain scroll wheel / two-finger trackpad scroll isn't wired to zoom
/// by default, unlike every real 3D viewer, so this forwards scroll events into the camera
/// controller's own `dollyToTarget`, which stays consistent with whatever orbit state the built-in
/// controller is already tracking (a manual camera-position edit here would fight it instead).
final class OrbitZoomSCNView: SCNView {
    /// Fires with the local click point on a plain click, mouse down then up with negligible
    /// movement in between, as opposed to `allowsCameraControl`'s own click-and-drag orbit, nil
    /// by default, so every existing use of this view (BRRES model preview, texture-collage
    /// fallback) is unaffected. `super` is still called from both overrides either way, so the
    /// built-in orbit/pan/zoom gesture handling behaves exactly as before regardless of this.
    var onClick: ((CGPoint) -> Void)?
    private var mouseDownLocation: CGPoint?

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if let start = mouseDownLocation {
            let end = convert(event.locationInWindow, from: nil)
            if hypot(end.x - start.x, end.y - start.y) < 3 {
                onClick?(end)
            }
        }
        mouseDownLocation = nil
        super.mouseUp(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard allowsCameraControl else { super.scrollWheel(with: event); return }
        defaultCameraController.dolly(toTarget: Float(event.scrollingDeltaY) * proportionalZoomUnit)
    }

    /// A flat dolly delta (the old `* 0.02` here) is
    /// imperceptible on a scene the scale of a whole race track (spans thousands of units) and
    /// too coarse on a small single object, scaling by a fraction of the *current* distance to
    /// the camera's target instead makes one scroll tick/button press always feel like the same
    /// relative zoom regardless of the model's actual scale. This is what was actually behind
    /// "zoom isn't working": the flat multiplier was firing, just too small to see on real
    /// track-scale meshes.
    var proportionalZoomUnit: Float {
        guard let pov = pointOfView else { return 1 }
        let target = defaultCameraController.target
        let p = pov.position
        let distance = Float((Double(p.x - target.x).squared + Double(p.y - target.y).squared + Double(p.z - target.z).squared).squareRoot())
        return distance.isFinite && distance > 0 ? distance * 0.0015 : 1
    }
}

private extension Double {
    var squared: Double { self * self }
}

/// Real-geometry viewport for a parsed `MDL0Model` (see `MDL0.swift`), an orbit-able SceneKit
/// view showing the model's actual mesh, not a texture-card placeholder.
struct SceneKitMeshPreviewView: NSViewRepresentable {
    let model: MDL0Model
    /// Texture name (`MDL0Mesh.textureName`, from the model's real material link) -> decoded
    /// image (plus whether it actually uses transparency, so a material with a translucent texture
    /// gets proper alpha-blend/depth settings instead of rendering as solid black, see
    /// `ImageUtil.hasTransparency`'s doc comment). Each mesh looks up its own entry here rather
    /// than the whole model sharing one texture, since different meshes in the same model
    /// legitimately use different materials.
    let textureLookup: [String: DecodedTexture]
    /// Which of `model.meshes` (by index, matching `UVMapEditorView`'s own mesh picker) is
    /// selected, clicking a polygon here sets it, and it's highlighted here in return, so picking
    /// a mesh to edit UVs for doesn't mean hunting for it by name in a separate list.
    @Binding var selectedMeshIndex: Int

    /// Cheap fingerprint of the mesh/texture data actually driving the scene. `model` is
    /// recomputed by the caller on every SwiftUI body evaluation (it re-parses the resource each
    /// time), so without this, `updateNSView` would tear down and rebuild the SCNScene, and
    /// with it the camera node SceneKit's `allowsCameraControl` orbits/zooms, on almost every
    /// unrelated UI update, making user zoom/orbit appear to silently reset.
    private var signature: String {
        let meshPart = model.meshes.map { mesh -> String in
            let tex = mesh.textureName.flatMap { textureLookup[$0] }
            return "\(mesh.vertices.count)|\(mesh.textureName ?? "-")|\(tex.map { "\($0.image.size.width)x\($0.image.size.height)" } ?? "-")"
        }.joined(separator: ",")
        return "\(meshPart)|\(model.boundsMin.x),\(model.boundsMin.y),\(model.boundsMin.z)"
            + "|\(model.boundsMax.x),\(model.boundsMax.y),\(model.boundsMax.z)"
    }

    final class Coordinator {
        var signature: String?
        var lastSelectedIndex: Int?
        var modelNode: SCNNode?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }


    func makeNSView(context: Context) -> OrbitZoomSCNView {
        let view = OrbitZoomSCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = NSColor.windowBackgroundColor
        let (scene, modelNode) = buildScene()
        view.scene = scene
        context.coordinator.signature = signature
        context.coordinator.modelNode = modelNode
        context.coordinator.lastSelectedIndex = selectedMeshIndex
        applyHighlight(modelNode, selected: selectedMeshIndex)
        view.onClick = { [weak view] point in
            guard let hit = view?.hitTest(point, options: [:]).first,
                  let name = hit.node.name, name.hasPrefix("mesh-"), let idx = Int(name.dropFirst(5)) else { return }
            selectedMeshIndex = idx
        }
        return view
    }

    func updateNSView(_ nsView: OrbitZoomSCNView, context: Context) {
        if signature != context.coordinator.signature {
            context.coordinator.signature = signature
            let (scene, modelNode) = buildScene()
            nsView.scene = scene
            context.coordinator.modelNode = modelNode
            context.coordinator.lastSelectedIndex = nil // force a fresh highlight pass below
        }
        nsView.onClick = { [weak nsView] point in
            guard let hit = nsView?.hitTest(point, options: [:]).first,
                  let name = hit.node.name, name.hasPrefix("mesh-"), let idx = Int(name.dropFirst(5)) else { return }
            selectedMeshIndex = idx
        }
        if context.coordinator.lastSelectedIndex != selectedMeshIndex {
            context.coordinator.lastSelectedIndex = selectedMeshIndex
            applyHighlight(context.coordinator.modelNode, selected: selectedMeshIndex)
        }
    }

    /// A plain yellow emissive tint on the selected mesh's material, cleared on every other one --
    /// changes the existing scene's materials in place rather than rebuilding it, so selecting a
    /// different mesh doesn't reset the camera orbit the way tearing down `nsView.scene` would.
    private func applyHighlight(_ modelNode: SCNNode?, selected: Int) {
        guard let modelNode else { return }
        for child in modelNode.childNodes {
            guard let name = child.name, name.hasPrefix("mesh-"), let idx = Int(name.dropFirst(5)) else { continue }
            child.geometry?.firstMaterial?.emission.contents = idx == selected ? NSColor.systemYellow.withAlphaComponent(0.5) : NSColor.black
        }
    }

    private func buildScene() -> (scene: SCNScene, modelNode: SCNNode) {
        let scene = SCNScene()
        let modelNode = SCNNode()
        for (i, mesh) in model.meshes.enumerated() where !mesh.vertices.isEmpty {
            let texture = mesh.textureName.flatMap { textureLookup[$0] }
            let node = SCNNode(geometry: Self.buildGeometry(mesh, texture: texture))
            node.name = "mesh-\(i)"
            modelNode.addChildNode(node)
        }

        let bmin = model.boundsMin, bmax = model.boundsMax
        let center = SCNVector3((bmin.x + bmax.x) / 2, (bmin.y + bmax.y) / 2, (bmin.z + bmax.z) / 2)
        modelNode.position = SCNVector3(-center.x, -center.y, -center.z)
        scene.rootNode.addChildNode(modelNode)

        let span = max(bmax.x - bmin.x, max(bmax.y - bmin.y, bmax.z - bmin.z))
        let radius = span.isFinite && span > 0 ? span * 1.6 : 10

        let camera = SCNCamera()
        camera.zFar = Double(radius * 20)
        camera.zNear = Double(max(radius * 0.01, 0.01))
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, radius)
        scene.rootNode.addChildNode(cameraNode)
        return (scene, modelNode)
    }

    private static func buildGeometry(_ mesh: MDL0Mesh, texture: DecodedTexture?) -> SCNGeometry {
        var positions: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var uvs: [CGPoint] = []
        positions.reserveCapacity(mesh.vertices.count)
        let hasNormals = mesh.vertices.contains { $0.normal != nil }
        let hasUVs = mesh.vertices.contains { $0.uv0 != nil }
        for v in mesh.vertices {
            positions.append(SCNVector3(v.position.x, v.position.y, v.position.z))
            if hasNormals {
                let n = v.normal ?? Vec3(x: 0, y: 1, z: 0)
                normals.append(SCNVector3(n.x, n.y, n.z))
            }
            // SceneKit's V runs down the image like GX's, so UVs pass straight through.
            if hasUVs {
                let uv = v.uv0 ?? Vec2(x: 0, y: 0)
                uvs.append(CGPoint(x: CGFloat(uv.x), y: CGFloat(uv.y)))
            }
        }
        var sources = [SCNGeometrySource(vertices: positions)]
        if hasNormals { sources.append(SCNGeometrySource(normals: normals)) }
        if hasUVs { sources.append(SCNGeometrySource(textureCoordinates: uvs)) }
        let indices: [Int32] = Array(0..<Int32(positions.count))
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: sources, elements: [element])
        let resolvedTexture = hasUVs ? texture : nil
        let material = SCNMaterial()
        material.diffuse.contents = resolvedTexture?.image ?? NSColor.systemGray
        material.isDoubleSided = true
        if !hasNormals { material.lightingModel = .constant }
        material.applyTransparency(resolvedTexture, vertexFades: false)
        geometry.materials = [material]
        return geometry
    }
}

/// Fallback viewport for whatever this app can't parse real geometry for (unsupported MDL0
/// version, or an extraction failure), shows the model's discovered textures on cards in 3D
/// space instead, clearly labeled as a structural placeholder by its caller.
struct SceneKitPreviewView: NSViewRepresentable {
    let images: [NSImage]

    private var signature: String {
        images.map { "\($0.size.width)x\($0.size.height)" }.joined(separator: ",")
    }

    final class Coordinator {
        var signature: String?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }


    func makeNSView(context: Context) -> SCNView {
        let view = OrbitZoomSCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = NSColor.windowBackgroundColor
        view.scene = buildScene()
        context.coordinator.signature = signature
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        guard signature != context.coordinator.signature else { return }
        context.coordinator.signature = signature
        nsView.scene = buildScene()
    }

    private func buildScene() -> SCNScene {
        let scene = SCNScene()
        if images.isEmpty {
            let box = SCNBox(width: 2, height: 2, length: 2, chamferRadius: 0.1)
            box.firstMaterial?.diffuse.contents = NSColor.systemGray
            let node = SCNNode(geometry: box)
            scene.rootNode.addChildNode(node)
        } else {
            let count = images.count
            let perRow = max(1, Int(ceil(sqrt(Double(count)))))
            for (i, img) in images.enumerated() {
                let plane = SCNPlane(width: 2, height: 2)
                plane.firstMaterial?.diffuse.contents = img
                plane.firstMaterial?.isDoubleSided = true
                let node = SCNNode(geometry: plane)
                let row = i / perRow, col = i % perRow
                node.position = SCNVector3(Float(col) * 2.4 - Float(perRow) * 1.2, Float(-row) * 2.4, 0)
                scene.rootNode.addChildNode(node)
            }
        }
        let camera = SCNCamera()
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 10)
        scene.rootNode.addChildNode(cameraNode)
        return scene
    }
}
