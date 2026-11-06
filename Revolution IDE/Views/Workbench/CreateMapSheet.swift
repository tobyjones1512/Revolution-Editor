import SwiftUI

/// The `.brres` a minimap is being made from, what that model offers to keep, and where the result
/// goes. Read once before the sheet opens (see `ProjectNavigatorView.beginCreateMap`) so the sheet
/// itself never has to deal with a failure case.
///
/// `create` is supplied by the caller because the destination differs: a `.brres` sitting in the
/// project writes `map_model.brres` beside itself, while one inside a `.szs` writes a new entry
/// into that same archive, which is where Mario Kart Wii actually keeps a course's map model.
/// It receives each kept texture option's id mapped to its shade (255 = white).
struct MapModelRequest: Identifiable {
    let id: String
    let sourceName: String
    let options: [MapModelBuilder.TextureOption]
    let sourceData: Data
    let create: ([String: UInt8]) -> Void
}

/// The minimap editor: choose which of a course model's textures appear on the minimap and how
/// bright each one is, with a live top-down preview of the result.
///
/// Surfaces worth keeping line up with which texture they use (road yes, trees no), so choices are
/// per texture. Each kept texture gets a shade: white for the main road, darker greys for areas
/// like off-road, lower levels or tunnels, exactly how retail minimaps do it (Castle, Rainbow and
/// Treehouse use greys from 0x66 to 0xCC as vertex colours inside their single map mesh, which is
/// what `MDL0Writer` emits for a shaded group).
struct CreateMapSheet: View {
    let request: MapModelRequest

    @Environment(\.dismiss) private var dismiss
    /// Kept options and their shade; an option not in here is left out.
    @State private var shades: [String: UInt8]
    @State private var trianglesByOption: [String: [OBJImporter.Triangle]] = [:]

    /// The greys retail minimaps actually use, brightest first.
    static let presets: [(name: String, value: UInt8)] = [("White", 0xFF), ("Light", 0xCC), ("Mid", 0x99), ("Grey", 0x80), ("Dark", 0x66)]

    init(request: MapModelRequest) {
        self.request = request
        // Everything starts on and white: switching off scenery is a shorter job than switching
        // on the road.
        _shades = State(initialValue: Dictionary(uniqueKeysWithValues: request.options.map { ($0.id, UInt8(0xFF)) }))
    }

    /// Real retail minimaps (checked across the disc) sit around 2,000 triangles, just the road.
    private static let largeTriangleWarningThreshold = 6000

    private var keptTriangles: Int {
        request.options.filter { shades[$0.id] != nil }.reduce(0) { $0 + $1.triangleCount }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Minimap Editor").font(.headline)
                Text("Builds map_model.brres from \(request.sourceName). Tick the textures that belong on the minimap and give each a shade, white for the main road, darker for off-road, lower levels or tunnels.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            Divider()

            HStack(spacing: 0) {
                List {
                    ForEach(request.options) { option in
                        row(option)
                    }
                }
                .listStyle(.inset)
                .frame(minWidth: 360)

                Divider()

                preview
                    .frame(width: 320, height: 320)
                    .padding(16)
            }
            .frame(minHeight: 352)

            Divider()

            HStack(spacing: 12) {
                Button("All") { for o in request.options where shades[o.id] == nil { shades[o.id] = 0xFF } }
                Button("None") { shades.removeAll() }
                Spacer()
                Text("\(keptTriangles) triangles kept").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20).padding(.vertical, 10)

            if keptTriangles > Self.largeTriangleWarningThreshold {
                Label("A retail minimap is typically a couple of thousand triangles (just the road). Keeping far more risks the minimap not showing up in-game, switch off scenery textures (trees, buildings, sky).",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .padding(.horizontal, 20).padding(.bottom, 10)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    request.create(shades)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(shades.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 760)
        .task {
            let data = request.sourceData
            trianglesByOption = await Task.detached { MapModelBuilder.trianglesByOption(inBRRES: data) }.value
        }
    }

    private func row(_ option: MapModelBuilder.TextureOption) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { shades[option.id] != nil },
                                     set: { shades[option.id] = $0 ? 0xFF : nil }))
                .toggleStyle(.checkbox).labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                Text(option.displayName).foregroundStyle(option.textureName == nil ? .secondary : .primary)
                Text("\(option.meshCount == 1 ? "1 mesh" : "\(option.meshCount) meshes"), \(option.triangleCount) tris")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            if let shade = shades[option.id] {
                Picker("", selection: Binding(get: { shade }, set: { shades[option.id] = $0 })) {
                    ForEach(Self.presets, id: \.value) { preset in
                        Label {
                            Text(preset.name)
                        } icon: {
                            Image(systemName: "square.fill")
                        }
                        .tag(preset.value)
                    }
                    if !Self.presets.contains(where: { $0.value == shade }) { Text("Custom").tag(shade) }
                }
                .labelsHidden()
                .frame(width: 90)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(white: Double(shade) / 255))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary.opacity(0.5)))
                    .frame(width: 18, height: 18)
            }
        }
    }

    /// Top-down, as the game draws it: lower geometry first so higher surfaces (a bridge over a
    /// darker road) cover it, on the minimap's dark backdrop.
    private var preview: some View {
        Canvas { ctx, size in
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8), with: .color(Color(white: 0.12)))
            var tris: [(OBJImporter.Triangle, UInt8)] = []
            for (id, shade) in shades { for t in trianglesByOption[id] ?? [] { tris.append((t, shade)) } }
            guard !tris.isEmpty else { return }
            var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude
            var minZ = Float.greatestFiniteMagnitude, maxZ = -Float.greatestFiniteMagnitude
            for (t, _) in tris { for p in [t.v0, t.v1, t.v2] { minX = min(minX, p.x); maxX = max(maxX, p.x); minZ = min(minZ, p.z); maxZ = max(maxZ, p.z) } }
            let w = max(maxX - minX, 1), h = max(maxZ - minZ, 1)
            let scale = min(size.width / CGFloat(w), size.height / CGFloat(h)) * 0.9
            let ox = (size.width - CGFloat(w) * scale) / 2, oy = (size.height - CGFloat(h) * scale) / 2
            func pt(_ v: Vec3) -> CGPoint { CGPoint(x: ox + CGFloat(v.x - minX) * scale, y: oy + CGFloat(v.z - minZ) * scale) }
            tris.sort { ($0.0.v0.y + $0.0.v1.y + $0.0.v2.y) < ($1.0.v0.y + $1.0.v1.y + $1.0.v2.y) }
            // Batch consecutive same-shade triangles into one path per run.
            var i = 0
            while i < tris.count {
                let shade = tris[i].1
                var path = Path()
                while i < tris.count, tris[i].1 == shade {
                    let t = tris[i].0
                    path.move(to: pt(t.v0)); path.addLine(to: pt(t.v1)); path.addLine(to: pt(t.v2)); path.closeSubpath()
                    i += 1
                }
                ctx.fill(path, with: .color(Color(white: Double(shade) / 255)))
            }
        }
        .overlay(alignment: .bottom) {
            if trianglesByOption.isEmpty { ProgressView().controlSize(.small).padding(8) }
        }
    }
}
