import SwiftUI

/// Field-by-field editor for the fixed-layout course files (`BinaryFieldSchema`): each value is
/// patched straight into the file's bytes, so anything not listed is kept exactly as it was.
struct BinaryFieldsEditorView: View {
    @ObservedObject var box: BinaryFieldsBox
    @State private var search = ""

    private var groups: [(String, [BinaryField])] {
        var order: [String] = [], byGroup: [String: [BinaryField]] = [:]
        for f in box.fields where search.isEmpty || f.label.localizedCaseInsensitiveContains(search) || f.group.localizedCaseInsensitiveContains(search) {
            if byGroup[f.group] == nil { order.append(f.group) }
            byGroup[f.group, default: []].append(f)
        }
        return order.map { ($0, byGroup[$0]!) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading) {
                    Text(box.title).font(.headline)
                    Text(box.summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                TextField("Filter fields", text: $search).textFieldStyle(.roundedBorder).frame(width: 180)
            }
            .padding([.horizontal, .top])
            Form {
                ForEach(groups, id: \.0) { group, fields in
                    Section(group) {
                        ForEach(fields) { f in FieldRow(field: f, box: box) }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}

private struct FieldRow: View {
    let field: BinaryField
    @ObservedObject var box: BinaryFieldsBox
    @State private var text = ""
    @State private var invalid = false

    var body: some View {
        HStack {
            Text(field.label)
            Spacer()
            if field.kind == .rgba {
                ColorPicker("", selection: Binding(get: { color }, set: { setColor($0) }), supportsOpacity: true).labelsHidden()
            }
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: field.kind == .text(32) ? 200 : 120)
                .foregroundStyle(invalid ? .red : .primary)
                .onSubmit(commit)
                .help(help)
        }
        .onAppear { text = BinaryFieldSchema.value(field, in: box.data) }
        .onChange(of: box.data) { _, d in text = BinaryFieldSchema.value(field, in: d) }
    }

    private var help: String {
        switch field.kind {
        case .u8: "Whole number 0-255. Press Return to apply."
        case .u16, .u32: "Whole number, or hex with 0x. Press Return to apply."
        case .f32: "Decimal number. Press Return to apply."
        case .rgba: "RRGGBBAA in hex, or use the colour well."
        case .text(let n): "Up to \(n - 1) characters."
        }
    }

    private func commit() {
        var d = box.data
        invalid = !BinaryFieldSchema.set(field, to: text, in: &d)
        guard !invalid, d != box.data else { return }
        box.data = d
        box.isDirty = true
    }

    private var color: Color {
        let v = box.data.be32(field.offset)
        return Color(.sRGB, red: Double(v >> 24 & 0xFF) / 255, green: Double(v >> 16 & 0xFF) / 255,
                     blue: Double(v >> 8 & 0xFF) / 255, opacity: Double(v & 0xFF) / 255)
    }

    private func setColor(_ c: Color) {
        guard let ns = NSColor(c).usingColorSpace(.sRGB) else { return }
        func b(_ x: CGFloat) -> Int { Int((max(0, min(1, x)) * 255).rounded()) }
        text = String(format: "%02X%02X%02X%02X", b(ns.redComponent), b(ns.greenComponent), b(ns.blueComponent), b(ns.alphaComponent))
        commit()
    }
}

/// A `.breff`'s emitters and the `.breft` textures each draws.
struct EffectEditorView: View {
    @ObservedObject var box: EffectDocumentBox
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Particle Effect: \(box.doc.name)").font(.headline)
                    Text("\(box.doc.emitters.count) emitters. Their textures live in the .breft of the same name.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                TextField("Filter", text: $search).textFieldStyle(.roundedBorder).frame(width: 180)
            }
            .padding([.horizontal, .top])
            Table(box.doc.emitters.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.textures.contains { $0.localizedCaseInsensitiveContains(search) } }) {
                TableColumn("Emitter", value: \.name)
                TableColumn("Textures") { Text($0.textures.joined(separator: ", ")).foregroundStyle(.secondary) }
                TableColumn("Size") { Text(ByteCountFormatter.string(fromByteCount: Int64($0.size), countStyle: .memory)) }.width(80)
            }
        }
    }
}
