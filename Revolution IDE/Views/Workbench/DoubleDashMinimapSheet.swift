import SwiftUI

/// Mario Kart: Double Dash!! > Minimap Editor...: the Double Dash counterpart of the Wii minimap
/// editor. A Double Dash minimap is a flat silhouette texture (`<course>_map.bti`) of the
/// driveable surfaces, drawn into the slot's fixed map rectangle (see `MKDDMinimap`), so this
/// picks which collision surfaces appear on it, with a live preview.
struct DoubleDashMinimapRequest: Identifiable {
    let id = UUID()
    let archiveName: String
    /// The course's collision triangles (Double Dash surface flags).
    let collision: [KCLTriangle]
    /// The slot's own map rectangle (from the linked disc), or nil to fit the course.
    let minimap: MKDDSlots.Minimap?
    let note: String?
    /// Writes the finished `_map.bti`.
    let save: (Data) throws -> Void
}

struct DoubleDashMinimapSheet: View {
    let request: DoubleDashMinimapRequest
    @Environment(\.dismiss) private var dismiss
    @State private var kept: Set<UInt16>
    @State private var outline = 2
    @State private var error: String?

    /// Surface types (flag >> 8) in the course, most triangles first.
    private let surfaces: [(type: UInt16, count: Int)]

    init(request: DoubleDashMinimapRequest) {
        self.request = request
        var counts: [UInt16: Int] = [:]
        for t in request.collision { counts[t.attribute >> 8, default: 0] += 1 }
        surfaces = counts.map { ($0.key, $0.value) }.sorted { $0.count > $1.count }
        _kept = State(initialValue: Set(counts.keys.filter { MKDDMinimap.onMap(bcoFlag: $0 << 8) }))
    }

    private var triangles: [(Vec3, Vec3, Vec3)] {
        request.collision.filter { kept.contains($0.attribute >> 8) }.map { ($0.v0, $0.v1, $0.v2) }
    }
    private var rect: MKDDSlots.Minimap { request.minimap ?? MKDDMinimap.fit(triangles) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Minimap Editor").font(.headline)
                Text("Draws \(request.archiveName)'s minimap from its collision. Tick the surfaces that belong on it: usually the road and anything else you drive on, not walls or out-of-bounds.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let note = request.note { Text(note).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            }
            .padding(20)
            Divider()
            HStack(spacing: 0) {
                List {
                    ForEach(surfaces, id: \.type) { s in
                        HStack(spacing: 8) {
                            Toggle("", isOn: Binding(get: { kept.contains(s.type) }, set: { if $0 { kept.insert(s.type) } else { kept.remove(s.type) } }))
                                .toggleStyle(.checkbox).labelsHidden()
                            Circle().fill(Color(kclFlagColor(s.type << 8, bco: true))).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(BCO.flagName(s.type << 8))
                                Text("\(s.count) triangles").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .frame(minWidth: 360)
                Divider()
                preview.frame(width: 320, height: 320).padding(16)
            }
            .frame(minHeight: 352)
            Divider()
            HStack(spacing: 12) {
                Button("All") { kept = Set(surfaces.map(\.type)) }
                Button("None") { kept.removeAll() }
                Stepper("Outline: \(outline) px", value: $outline, in: 0...6).fixedSize()
                    .help("The dark border round the road that makes it stand out over the course.")
                Spacer()
                Text(request.minimap == nil ? "Fitted to the course" : "Slot's map area").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            if let error { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 20) }
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }.keyboardShortcut(.defaultAction).disabled(kept.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 760)
    }

    private var preview: some View {
        let rgba = MKDDMinimap.render(triangles: triangles, minimap: rect, outline: outline)
        return ZStack {
            Color.black.opacity(0.6)
            if let img = ImageUtil.nsImage(fromRGBA: rgba, width: MKDDMinimap.width, height: MKDDMinimap.height) {
                Image(nsImage: img).resizable().interpolation(.none).aspectRatio(contentMode: .fit)
            }
        }
        .border(Color.gray.opacity(0.3))
        .help("The minimap as the game shows it (over a dark background here).")
    }

    private func create() {
        let rgba = MKDDMinimap.render(triangles: triangles, minimap: rect, outline: outline)
        let stem = (request.archiveName as NSString).deletingPathExtension.lowercased()
        let texture = J3DWriter.Texture(name: "\(stem)_map", format: .ia4, width: MKDDMinimap.width, height: MKDDMinimap.height,
                                        encoded: TextureCodec.encode(rgba: rgba, width: MKDDMinimap.width, height: MKDDMinimap.height, format: .ia4) ?? Data(),
                                        wrapS: 0, wrapT: 0, hasAlpha: true)
        do {
            try request.save(J3DWriter.bti(texture))
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
