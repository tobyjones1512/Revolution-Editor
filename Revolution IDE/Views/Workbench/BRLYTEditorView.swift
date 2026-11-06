import SwiftUI
import Combine

/// Viewer/editor for a `.brlyt` UI layout: the pane hierarchy on the left (plus reference lists of
/// the materials/textures/groups it uses), a transform inspector for the selected pane on the
/// right. See `BRLYTDocument`'s doc comment for why this edits pane transforms in place rather
/// than being a full layout/material editor.
struct BRLYTEditorView: View {
    @ObservedObject var box: BRLYTDocumentBox
    /// Undo/redo + history list, same `EditHistory` pattern `KMPEditorView` uses.
    @StateObject private var history: EditHistory

    init(box: BRLYTDocumentBox) {
        self.box = box
        _history = StateObject(wrappedValue: EditHistory(initial: box.doc.serialize()))
    }

    private func pushHistory(_ label: String) {
        history.push(box.doc.serialize(), label: label)
    }

    private func restoreFromHistory(_ data: Data) {
        guard let doc = try? BRLYTDocument.parse(data) else { return }
        box.doc = doc
        box.selectedPaneID = nil
        box.isDirty = true
    }

    var body: some View {
        HSplitView {
            paneTree
                .frame(minWidth: 220, idealWidth: 260)
            previewPane
                .frame(minWidth: 300, idealWidth: 420)
            inspector
                .frame(minWidth: 280)
        }
    }

    // MARK: Preview

    private var previewPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Preview").font(.caption.bold())
                Spacer()
                Text("Approximate, textures, fonts, and pane anchor points aren't rendered.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(6)
            Divider()
            previewCanvas
        }
    }

    /// A geometric approximation of the layout, not a pixel-accurate render: each pane's anchor
    /// point (an alignment byte this reader doesn't parse, see `BRLYTDocument`'s doc comment for
    /// why only the fixed-offset transform fields are modeled) is assumed top-left, and textures/
    /// fonts/materials aren't drawn at all. Good enough to see the pane hierarchy's rough position,
    /// rotation, and scale at a glance, and to click a pane here to select it in the tree/inspector
    /// too, not a claim this matches the game pixel-for-pixel.
    private var previewCanvas: some View {
        GeometryReader { geo in
            let layoutW = CGFloat(box.doc.layoutWidth > 0 ? box.doc.layoutWidth : 608)
            let layoutH = CGFloat(box.doc.layoutHeight > 0 ? box.doc.layoutHeight : 456)
            let rawScale = min(geo.size.width / max(layoutW, 1), geo.size.height / max(layoutH, 1))
            let scale = rawScale.isFinite && rawScale > 0 ? rawScale : 1

            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.black)
                    .frame(width: layoutW, height: layoutH)
                ForEach(box.doc.rootPanes, id: \.id) { pane in
                    paneRect(pane)
                }
            }
            .frame(width: layoutW, height: layoutH)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipped()
    }

    /// One pane's rectangle plus its children, recursively, nesting the children as siblings
    /// inside this pane's own (untransformed) `ZStack` and applying this pane's scale/rotation/
    /// translation to that whole group is what makes a child's position, rotation, and scale
    /// compose relative to its parent's, the same way the real layout hierarchy works.
    /// Returns `AnyView`, not `some View`, this function calls itself for `pane.children`, and a
    /// recursive function can't infer an opaque return type in terms of itself.
    private func paneRect(_ pane: BRLYTPane) -> AnyView {
        let isSelected = box.selectedPaneID == pane.id
        return AnyView(
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(pane.visible ? fillColor(for: pane.kind) : .clear)
                    .overlay(
                        Rectangle().strokeBorder(
                            isSelected ? Color.accentColor : strokeColor(for: pane.kind),
                            style: StrokeStyle(lineWidth: isSelected ? 2 : 1, dash: pane.visible ? [] : [3, 2])
                        )
                    )
                    .frame(width: CGFloat(pane.width), height: CGFloat(pane.height))
                    .contentShape(Rectangle())
                    .onTapGesture { box.selectedPaneID = pane.id }
                    .help("\(pane.name.isEmpty ? "(unnamed)" : pane.name) (\(pane.kind))")

                ForEach(pane.children, id: \.id) { child in
                    paneRect(child)
                }
            }
            .frame(width: CGFloat(pane.width), height: CGFloat(pane.height), alignment: .topLeading)
            .scaleEffect(x: CGFloat(pane.scale.x), y: CGFloat(pane.scale.y), anchor: .topLeading)
            .rotationEffect(.degrees(Double(pane.rotation.z)), anchor: .topLeading)
            .offset(x: CGFloat(pane.translation.x), y: CGFloat(pane.translation.y))
        )
    }

    private func fillColor(for kind: String) -> Color {
        switch kind {
        case "pic1": return Color.blue.opacity(0.25)
        case "txt1": return Color.green.opacity(0.25)
        case "wnd1": return Color.orange.opacity(0.2)
        default: return Color.clear
        }
    }

    private func strokeColor(for kind: String) -> Color {
        switch kind {
        case "pic1": return .blue
        case "txt1": return .green
        case "wnd1": return .orange
        case "bnd1": return .gray
        default: return .purple
        }
    }

    private var paneTree: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Layout \(Int(box.doc.layoutWidth))\u{d7}\(Int(box.doc.layoutHeight))\(box.doc.isCentered ? ", centered" : "")")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                HistoryControlsView(history: history, onRestore: restoreFromHistory)
            }
            .padding(8)
            Divider()
            List(selection: $box.selectedPaneID) {
                Section(content: {
                    OutlineGroup(box.doc.rootPanes, id: \.id, children: \.childrenOrNil) { pane in
                        HStack {
                            Image(systemName: icon(for: pane.kind))
                            Text(pane.name.isEmpty ? "(unnamed)" : pane.name)
                            if !pane.visible {
                                Image(systemName: "eye.slash").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .tag(pane.id)
                    }
                }, header: {
                    Text("Panes").help("The elements making up this menu/HUD screen, text boxes, pictures, windows/frames, and groups, nested to match how they're drawn and positioned relative to each other.")
                })
                if !box.doc.materials.isEmpty {
                    Section("Materials (\(box.doc.materials.count))") {
                        ForEach(Array(box.doc.materials.enumerated()), id: \.offset) { _, m in
                            Text(m.name).font(.caption)
                        }
                    }
                }
                if !box.doc.textureFilenames.isEmpty {
                    Section("Textures (\(box.doc.textureFilenames.count))") {
                        ForEach(box.doc.textureFilenames, id: \.self) { t in Text(t).font(.caption) }
                    }
                }
                if !box.doc.groups.isEmpty {
                    Section("Groups (\(box.doc.groups.count))") {
                        ForEach(Array(box.doc.groups.enumerated()), id: \.offset) { _, g in
                            Text("\(g.name) (\(g.paneNames.count) panes)").font(.caption)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func icon(for kind: String) -> String {
        switch kind {
        case "pic1": return "photo"
        case "bnd1": return "square.dashed.inset.filled"
        case "txt1": return "textformat"
        case "wnd1": return "macwindow"
        default: return "square.dashed"
        }
    }

    // MARK: Inspector

    @ViewBuilder
    private var inspector: some View {
        if let id = box.selectedPaneID, let pane = box.doc.allPanes.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(pane.name.isEmpty ? "(unnamed)" : pane.name)").font(.headline).padding([.top, .horizontal])
                    Text(pane.kind).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Visible", isOn: Binding(
                            get: { pane.visible },
                            set: { box.doc.setVisible(pane, $0); box.isDirty = true; box.objectWillChange.send(); pushHistory("Toggle Visible") }
                        ))
                        vec3Field("Translation", get: { pane.translation }, set: { box.doc.setTranslation(pane, $0); box.isDirty = true; box.objectWillChange.send(); pushHistory("Edit Translation") })
                        vec3Field("Rotation", get: { pane.rotation }, set: { box.doc.setRotation(pane, $0); box.isDirty = true; box.objectWillChange.send(); pushHistory("Edit Rotation") })
                        vec2Field("Scale", get: { pane.scale }, set: { box.doc.setScale(pane, $0); box.isDirty = true; box.objectWillChange.send(); pushHistory("Edit Scale") })
                        HStack {
                            Text("Size").font(.caption).foregroundStyle(.secondary)
                            numberField("W", pane.width) { box.doc.setSize(pane, width: $0, height: pane.height); box.isDirty = true; box.objectWillChange.send(); pushHistory("Edit Size") }
                            numberField("H", pane.height) { box.doc.setSize(pane, width: pane.width, height: $0); box.isDirty = true; box.objectWillChange.send(); pushHistory("Edit Size") }
                        }
                    }
                    .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 12)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "cursorarrow.click").font(.system(size: 32)).foregroundStyle(.tertiary)
                Text("Select a pane to edit its transform.").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func vec3Field(_ label: String, get: () -> Vec3, set: @escaping (Vec3) -> Void) -> some View {
        let v = get()
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack {
                numberField("X", v.x) { set(Vec3(x: $0, y: v.y, z: v.z)) }
                numberField("Y", v.y) { set(Vec3(x: v.x, y: $0, z: v.z)) }
                numberField("Z", v.z) { set(Vec3(x: v.x, y: v.y, z: $0)) }
            }
        }
    }

    @ViewBuilder
    private func vec2Field(_ label: String, get: () -> Vec2, set: @escaping (Vec2) -> Void) -> some View {
        let v = get()
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack {
                numberField("X", v.x) { set(Vec2(x: $0, y: v.y)) }
                numberField("Y", v.y) { set(Vec2(x: v.x, y: $0)) }
            }
        }
    }

    private func numberField(_ label: String, _ value: Float, _ set: @escaping (Float) -> Void) -> some View {
        TextField(label, value: Binding(get: { value }, set: set), format: .number)
            .textFieldStyle(.roundedBorder)
            .frame(width: 70)
    }
}

/// Viewer for a `.brlan` layout animation, which panes/materials it animates and which property
/// (pane SRT, visibility, vertex/material color, texture SRT/pattern), not the keyframe curve
/// values themselves. See `BRLANDocument`'s doc comment for the scoping rationale.
struct BRLANEditorView: View {
    let doc: BRLANDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if !doc.animationSetName.isEmpty { Text(doc.animationSetName).font(.headline) }
                Spacer()
                Text("\(doc.frameCount) frame\(doc.frameCount == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
            }
            .padding()
            Divider()
            List {
                if !doc.textureFilenames.isEmpty {
                    Section("Textures (\(doc.textureFilenames.count))") {
                        ForEach(doc.textureFilenames, id: \.self) { t in Text(t).font(.caption) }
                    }
                }
                Section("Animations (\(doc.animations.count))") {
                    ForEach(Array(doc.animations.enumerated()), id: \.offset) { _, anim in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Image(systemName: anim.animatesMaterial ? "paintpalette" : "square.dashed")
                                Text(anim.name.isEmpty ? "(unnamed)" : anim.name).font(.subheadline.bold())
                            }
                            Text(anim.tags.map { "\($0.type) (\($0.entries.count))" }.joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}
