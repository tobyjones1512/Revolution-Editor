import SwiftUI
import SceneKit
import UniformTypeIdentifiers

/// Everything "Create Render" lets someone set: lights, camera look, background/fog and the
/// export size. Applied live to the 3D preview's own scene (see `TrackRender.apply`), so what's
/// on screen is what gets exported.
struct RenderSettings: Equatable {
    var sunAzimuth: Double = 40
    var sunElevation: Double = 45
    var sunIntensity: Double = 1100
    var sunColor = Color(red: 1, green: 0.96, blue: 0.88)
    var shadows = true
    var shadowSoftness: Double = 3
    var ambientIntensity: Double = 380
    var ambientColor = Color(red: 0.78, green: 0.84, blue: 1)
    /// A second, shadowless light from the opposite side, lifting the shadowed faces.
    var fillIntensity: Double = 150

    var fieldOfView: Double = 55
    var exposure: Double = 0
    var bloom: Double = 0.25
    var ambientOcclusion: Double = 0.6
    var vignette: Double = 0.25
    var saturation: Double = 1.05
    var contrast: Double = 0.05

    enum Background: String, CaseIterable { case skybox = "Skybox", color = "Colour" }
    var background: Background = .skybox
    var backgroundColor = Color(red: 0.55, green: 0.72, blue: 0.92)
    var fog = false
    /// Where fog is fully opaque, as a fraction of the track's size.
    var fogDistance: Double = 1.2
    var fogColor = Color(red: 0.75, green: 0.82, blue: 0.9)
    var showObjects = true

    var width = 3840
    var height = 2160
    var supersample = true

    static let presets: [(String, RenderSettings)] = [
        ("Midday", RenderSettings()),
        ("Golden Hour", {
            var s = RenderSettings()
            s.sunAzimuth = 250; s.sunElevation = 12; s.sunIntensity = 1300; s.sunColor = Color(red: 1, green: 0.72, blue: 0.45)
            s.ambientIntensity = 260; s.ambientColor = Color(red: 0.65, green: 0.6, blue: 0.85); s.fillIntensity = 80
            s.bloom = 0.45; s.saturation = 1.15; s.vignette = 0.35; s.fog = true; s.fogDistance = 2.5; s.fogColor = Color(red: 1, green: 0.8, blue: 0.62)
            s.backgroundColor = Color(red: 0.95, green: 0.72, blue: 0.5)
            return s
        }()),
        ("Overcast", {
            var s = RenderSettings()
            s.sunElevation = 70; s.sunIntensity = 450; s.sunColor = .white; s.shadowSoftness = 12
            s.ambientIntensity = 700; s.ambientColor = Color(white: 0.92); s.fillIntensity = 0
            s.bloom = 0.1; s.saturation = 0.85; s.contrast = 0; s.fog = true; s.fogDistance = 2.2; s.fogColor = Color(white: 0.82); s.backgroundColor = Color(white: 0.78)
            return s
        }()),
        ("Night", {
            var s = RenderSettings()
            s.sunAzimuth = 120; s.sunElevation = 35; s.sunIntensity = 700; s.sunColor = Color(red: 0.6, green: 0.7, blue: 1)
            s.ambientIntensity = 330; s.ambientColor = Color(red: 0.45, green: 0.5, blue: 0.85); s.fillIntensity = 120
            s.exposure = 0.2; s.bloom = 0.8; s.vignette = 0.45; s.saturation = 0.85
            s.background = .color; s.backgroundColor = Color(red: 0.03, green: 0.04, blue: 0.1)
            return s
        }()),
    ]

    static let resolutions: [(String, Int, Int)] = [
        ("1080p (1920 x 1080)", 1920, 1080), ("1440p (2560 x 1440)", 2560, 1440), ("4K (3840 x 2160)", 3840, 2160),
        ("8K (7680 x 4320)", 7680, 4320), ("Square (2048 x 2048)", 2048, 2048), ("Banner (3000 x 1000)", 3000, 1000),
    ]
}

/// Applies `RenderSettings` to the preview scene and exports frames from it.
@MainActor enum TrackRender {
    static func cameraNode(in scene: SCNScene) -> SCNNode? { scene.rootNode.childNodes.first { $0.camera != nil } }

    /// `nil` settings puts back the editor's plain look (the lights `frameCamera` sets up).
    /// `sky` is the skybox layer: while rendering it rides along with the camera and draws behind
    /// everything, as a skybox does in-game, otherwise an aerial shot from outside a small dome
    /// (Moo Moo Meadows') sees only the dome's outside.
    static func apply(_ s: RenderSettings?, to scene: SCNScene, extent: Float, sky: SCNNode? = nil) {
        let root = scene.rootNode
        if let sky { followCamera(sky, scene: scene, on: s != nil) }
        let sun = root.childNode(withName: "sun", recursively: false)
        let ambient = root.childNode(withName: "ambient", recursively: false)
        var fill = root.childNode(withName: "fill", recursively: false)
        let camera = cameraNode(in: scene)?.camera

        guard let s else {
            sun?.light?.intensity = 900; sun?.light?.color = NSColor.white; sun?.light?.castsShadow = false
            sun?.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 4, 0)
            ambient?.light?.intensity = 300; ambient?.light?.color = NSColor.white
            fill?.removeFromParentNode()
            scene.background.contents = NSColor.black
            scene.fogEndDistance = 0
            if let camera {
                camera.wantsHDR = false; camera.bloomIntensity = 0; camera.screenSpaceAmbientOcclusionIntensity = 0
                camera.vignettingIntensity = 0; camera.saturation = 1; camera.contrast = 0; camera.exposureOffset = 0
                camera.fieldOfView = 60
            }
            return
        }

        let az = Float(s.sunAzimuth) * .pi / 180, el = Float(s.sunElevation) * .pi / 180
        if let light = sun?.light {
            sun?.eulerAngles = SCNVector3(-el, az, 0)
            light.intensity = s.sunIntensity
            light.color = NSColor(s.sunColor)
            light.castsShadow = s.shadows
            light.shadowMode = .deferred
            light.automaticallyAdjustsShadowProjection = true
            light.maximumShadowDistance = CGFloat(extent * 1.5)
            light.shadowCascadeCount = 4
            light.shadowMapSize = CGSize(width: 4096, height: 4096)
            light.shadowSampleCount = 16
            light.shadowRadius = s.shadowSoftness
            light.shadowColor = NSColor.black.withAlphaComponent(0.65)
        }
        ambient?.light?.intensity = s.ambientIntensity
        ambient?.light?.color = NSColor(s.ambientColor)
        if fill == nil {
            let light = SCNLight()
            light.type = .directional
            let node = SCNNode()
            node.name = "fill"
            node.light = light
            root.addChildNode(node)
            fill = node
        }
        fill?.light?.intensity = s.fillIntensity
        fill?.light?.color = NSColor(s.ambientColor)
        fill?.eulerAngles = SCNVector3(-Float.pi / 6, az + .pi, 0)

        // Also behind the skybox: most domes are open underneath, which an aerial shot sees.
        scene.background.contents = NSColor(s.backgroundColor)
        if s.fog {
            scene.fogStartDistance = CGFloat(extent * 0.15)
            scene.fogEndDistance = CGFloat(extent * Float(s.fogDistance))
            scene.fogDensityExponent = 1.5
            scene.fogColor = NSColor(s.fogColor)
        } else {
            scene.fogEndDistance = 0
        }

        if let camera {
            camera.fieldOfView = s.fieldOfView
            camera.wantsHDR = true
            camera.exposureOffset = s.exposure
            camera.bloomIntensity = s.bloom
            camera.bloomThreshold = 0.85
            camera.bloomBlurRadius = 12
            camera.screenSpaceAmbientOcclusionIntensity = s.ambientOcclusion
            // Retail tracks run thousands of units across; AO's default radius is 5 units.
            camera.screenSpaceAmbientOcclusionRadius = CGFloat(max(50, extent / 400))
            camera.screenSpaceAmbientOcclusionBias = 0.03
            camera.vignettingIntensity = s.vignette
            camera.vignettingPower = 1
            camera.saturation = s.saturation
            camera.contrast = s.contrast
        }
    }

    private static func followCamera(_ sky: SCNNode, scene: SCNScene, on: Bool) {
        sky.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry else { return }
            node.renderingOrder = on ? -1000 : (geometry.materials.first?.isTranslucent == true ? 100 : 0)
            for m in geometry.materials {
                m.readsFromDepthBuffer = !on
                m.writesToDepthBuffer = !on && !m.isTranslucent
            }
        }
        sky.constraints = nil
        sky.position = SCNVector3Zero
        guard on else { return }
        let (lo, hi) = sky.boundingBox
        let center = SIMD3(Float(lo.x + hi.x), Float(lo.y + hi.y), Float(lo.z + hi.z)) / 2
        let follow = SCNTransformConstraint.positionConstraint(inWorldSpace: true) { _, position in
            guard let camera = cameraNode(in: scene) else { return position }
            let p = camera.presentation.simdWorldPosition - center
            return SCNVector3(p.x, p.y, p.z)
        }
        sky.constraints = [follow]
    }

    /// Renders the camera's view at `width` x `height`, framed to the guide `guideFraction` (the
    /// part of the viewport's height the export frame covers) so the export matches what the
    /// on-screen guide shows. Supersampled renders at twice the size and scales down.
    static func render(scene: SCNScene, width: Int, height: Int, supersample: Bool, guideFraction: CGFloat) -> NSImage? {
        guard let source = cameraNode(in: scene), let device = MTLCreateSystemDefaultDevice() else { return nil }
        let pov = source.clone()
        pov.camera = source.camera?.copy() as? SCNCamera
        if let camera = pov.camera {
            camera.projectionDirection = .vertical
            if camera.usesOrthographicProjection {
                camera.orthographicScale *= Double(guideFraction)
            } else {
                let half = tan(camera.fieldOfView * .pi / 360) * Double(guideFraction)
                camera.fieldOfView = atan(half) * 360 / .pi
            }
        }
        pov.simdWorldTransform = source.simdWorldTransform
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = pov
        let factor = supersample ? 2 : 1
        let full = renderer.snapshot(atTime: 0, with: CGSize(width: width * factor, height: height * factor), antialiasingMode: .multisampling4X)
        guard factor > 1 else { return full }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return full }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        full.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }

    static func pngData(_ image: NSImage) -> Data? {
        let rep = image.representations.first as? NSBitmapImageRep ?? image.tiffRepresentation.flatMap(NSBitmapImageRep.init)
        return rep?.representation(using: .png, properties: [:])
    }
}

/// Darkens what falls outside the export frame, so framing the shot on screen is framing the export.
struct RenderFrameGuide: View {
    let aspect: CGFloat
    var body: some View {
        GeometryReader { g in
            let frame = Self.frame(in: g.size, aspect: aspect)
            Path { p in
                p.addRect(CGRect(origin: .zero, size: g.size))
                p.addRect(frame)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            Rectangle().stroke(Color.white.opacity(0.7), lineWidth: 1)
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
            // Rule-of-thirds lines.
            Path { p in
                for k in 1...2 {
                    let x = frame.minX + frame.width * CGFloat(k) / 3, y = frame.minY + frame.height * CGFloat(k) / 3
                    p.move(to: CGPoint(x: x, y: frame.minY)); p.addLine(to: CGPoint(x: x, y: frame.maxY))
                    p.move(to: CGPoint(x: frame.minX, y: y)); p.addLine(to: CGPoint(x: frame.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.18), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }

    /// The largest rect of `aspect` centred in `size`.
    static func frame(in size: CGSize, aspect: CGFloat) -> CGRect {
        guard size.width > 0, size.height > 0, aspect > 0 else { return CGRect(origin: .zero, size: size) }
        let w = min(size.width, size.height * aspect), h = w / aspect
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}

/// The inspector while in Create Render: lights, look, background and export.
struct TrackRenderPanel: View {
    @Binding var settings: RenderSettings
    let hasSkybox: Bool
    let onExport: () -> Void
    let onCopy: () -> Void
    let onDone: () -> Void
    @State private var exporting = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Create Render").font(.headline)
                Spacer()
                Button("Done", action: onDone).help("Back to editing (restores the KMP layers)")
            }
            .padding(10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Preset").font(.caption.bold())
                        Spacer()
                        Menu("Apply...") {
                            ForEach(RenderSettings.presets, id: \.0) { preset in
                                Button(preset.0) {
                                    var s = preset.1
                                    s.width = settings.width; s.height = settings.height; s.supersample = settings.supersample
                                    s.showObjects = settings.showObjects
                                    settings = s
                                }
                            }
                        }
                        .fixedSize()
                    }

                    section("Sun") {
                        slider("Direction", $settings.sunAzimuth, 0...360, "%.0f°")
                        slider("Height", $settings.sunElevation, 2...90, "%.0f°")
                        slider("Strength", $settings.sunIntensity, 0...3000, "%.0f")
                        ColorPicker("Colour", selection: $settings.sunColor, supportsOpacity: false).font(.caption)
                        Toggle("Shadows", isOn: $settings.shadows).font(.caption)
                        if settings.shadows { slider("Softness", $settings.shadowSoftness, 0...20, "%.0f") }
                    }
                    section("Sky light") {
                        slider("Ambient", $settings.ambientIntensity, 0...1500, "%.0f")
                        ColorPicker("Colour", selection: $settings.ambientColor, supportsOpacity: false).font(.caption)
                        slider("Fill light", $settings.fillIntensity, 0...1000, "%.0f")
                    }
                    section("Camera") {
                        slider("Field of view", $settings.fieldOfView, 15...110, "%.0f°")
                        slider("Exposure", $settings.exposure, -2...2, "%.1f")
                        slider("Bloom", $settings.bloom, 0...2, "%.2f")
                        slider("Ambient occlusion", $settings.ambientOcclusion, 0...2, "%.2f")
                        slider("Vignette", $settings.vignette, 0...1.5, "%.2f")
                        slider("Saturation", $settings.saturation, 0...2, "%.2f")
                        slider("Contrast", $settings.contrast, -0.5...0.5, "%.2f")
                    }
                    section("Scene") {
                        Picker("Background", selection: $settings.background) {
                            ForEach(RenderSettings.Background.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented).font(.caption)
                        .disabled(!hasSkybox)
                        ColorPicker(settings.background == .color || !hasSkybox ? "Background colour" : "Colour below the sky", selection: $settings.backgroundColor, supportsOpacity: false)
                            .font(.caption)
                            .help("Fills whatever the skybox doesn't cover, most sky domes are open underneath, which shows in shots from above.")
                        Toggle("Fog", isOn: $settings.fog).font(.caption)
                        if settings.fog {
                            slider("Fog distance", $settings.fogDistance, 0.2...4, "%.1fx")
                            ColorPicker("Fog colour", selection: $settings.fogColor, supportsOpacity: false).font(.caption)
                        }
                        Toggle("Show objects (trees, item boxes...)", isOn: $settings.showObjects).font(.caption)
                    }
                    section("Export") {
                        Picker("Size", selection: Binding(get: { "\(settings.width)x\(settings.height)" }, set: { v in
                            let parts = v.split(separator: "x").compactMap { Int($0) }
                            if parts.count == 2 { settings.width = parts[0]; settings.height = parts[1] }
                        })) {
                            ForEach(RenderSettings.resolutions, id: \.0) { Text($0.0).tag("\($0.1)x\($0.2)") }
                            if !RenderSettings.resolutions.contains(where: { $0.1 == settings.width && $0.2 == settings.height }) {
                                Text("Custom").tag("\(settings.width)x\(settings.height)")
                            }
                        }
                        .font(.caption)
                        HStack {
                            TextField("W", value: $settings.width, format: .number.grouping(.never)).frame(width: 64)
                            Text("x").foregroundStyle(.secondary)
                            TextField("H", value: $settings.height, format: .number.grouping(.never)).frame(width: 64)
                            Text("px").foregroundStyle(.secondary)
                        }
                        .textFieldStyle(.roundedBorder).font(.caption)
                        Toggle("Supersample (2x, smoother edges)", isOn: $settings.supersample).font(.caption)
                            .help("Renders at twice the size and scales down, the cleanest edges and texture detail, at four times the render time.")
                        HStack {
                            Button { onExport() } label: { Label("Export PNG...", systemImage: "square.and.arrow.down") }
                                .shortcut(.exportImage)
                                .disabled(!validSize)
                            Button { onCopy() } label: { Image(systemName: "doc.on.doc") }
                                .help("Copy the render to the clipboard")
                                .disabled(!validSize)
                        }
                        if !validSize { Text("Size must be 16-16384 pixels each way.").font(.caption2).foregroundStyle(.red) }
                    }
                    Text("Frame the shot in the viewport: the bright area is exactly what's exported. Drag to orbit, scroll to zoom, WASD to fly.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
            }
        }
    }

    private var validSize: Bool { (16...16384).contains(settings.width) && (16...16384).contains(settings.height) }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.bold())
            content()
        }
    }

    private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ format: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(String(format: format, value.wrappedValue)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range).controlSize(.small)
        }
    }
}
