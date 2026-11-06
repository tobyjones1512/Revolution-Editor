import Combine
import SwiftUI

/// A value one spreadsheet cell can show and parse back. Integers accept decimal or `0x` hex.
private protocol KMPCellValue {
    func cellText(hex: Bool) -> String
    init?(cellText: String)
}

extension Float: KMPCellValue {
    fileprivate func cellText(hex: Bool) -> String { "\(self)" }
    fileprivate init?(cellText s: String) { self.init(s.trimmingCharacters(in: .whitespaces)) }
}

extension KMPCellValue where Self: FixedWidthInteger {
    fileprivate func cellText(hex: Bool) -> String { hex ? "0x" + String(self, radix: 16, uppercase: true) : String(self) }
    fileprivate init?(cellText s: String) {
        let s = s.trimmingCharacters(in: .whitespaces)
        if s.lowercased().hasPrefix("0x") { self.init(s.dropFirst(2), radix: 16) } else { self.init(s) }
    }
}

extension UInt8: KMPCellValue {}
extension Int8: KMPCellValue {}
extension UInt16: KMPCellValue {}
extension Int16: KMPCellValue {}
extension UInt32: KMPCellValue {}

private struct KMPColumn {
    let title: String
    let width: CGFloat
    let get: (KMPDocument, Int) -> String
    /// Returns false when the text doesn't parse, so the cell reverts.
    let set: (KMPDocument, Int, String) -> Bool
}

/// The KMP editor's "Advanced" view: every field of every entry in a section as one editable grid.
struct KMPSpreadsheetView: View {
    @ObservedObject var box: KMPDocumentBox
    let onCommit: (String) -> Void
    @AppStorage("kmpSpreadsheetSection") private var sectionRaw = KMPSection.ktpt.rawValue

    private var section: KMPSection { KMPSection(rawValue: sectionRaw) ?? .ktpt }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Section", selection: $sectionRaw) {
                    ForEach(KMPSection.allCases, id: \.rawValue) { s in
                        Text("\(s.magic). \(s.displayName) (\(rowCount(s)))").tag(s.rawValue)
                    }
                }
                .frame(maxWidth: 360)
                .help(section.tooltip)
                Spacer()
                Text("Click a row's # to select it. Return or leaving a cell commits; integers accept 0x hex.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(8)
            Divider()
            grid(columns: columns(section), rows: rowCount(section))
        }
    }

    private func grid(columns: [KMPColumn], rows: Int) -> some View {
        let doc = box.doc
        return ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(0..<rows, id: \.self) { r in
                        let selected = selection(section, r).map { box.selection?.asPoint == $0 } ?? false
                        HStack(spacing: 0) {
                            Button { box.selection = selection(section, r) } label: {
                                Text("\(r + 1)").monospacedDigit().frame(width: 44, alignment: .trailing)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .padding(.trailing, 6)
                            ForEach(columns.indices, id: \.self) { c in
                                let col = columns[c]
                                KMPCell(value: col.get(doc, r)) { text in
                                    guard col.set(doc, r, text) else { return false }
                                    box.isDirty = true
                                    box.objectWillChange.send()
                                    onCommit("Edit \(section.magic) \(col.title)")
                                    return true
                                }
                                .frame(width: col.width)
                            }
                        }
                        .background(selected ? Color.accentColor.opacity(0.2) : r.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.04))
                    }
                } header: {
                    HStack(spacing: 0) {
                        Text("#").frame(width: 44, alignment: .trailing).padding(.trailing, 6)
                        ForEach(columns.indices, id: \.self) { c in
                            Text(columns[c].title).lineLimit(1).frame(width: columns[c].width, alignment: .leading).padding(.leading, 4)
                        }
                    }
                    .font(.caption.bold())
                    .padding(.vertical, 4)
                    .background(.bar)
                }
            }
            .padding(.bottom, 8)
        }
        .id(section) // fresh scroll position + cell state per section
    }

    // MARK: Rows

    /// POTI is a list of routes each holding points; the sheet flattens it to one row per point.
    private var potiRows: [(route: Int, point: Int)] {
        box.doc.poti.indices.flatMap { r in box.doc.poti[r].points.indices.map { (r, $0) } }
    }

    private func rowCount(_ s: KMPSection) -> Int {
        let d = box.doc
        switch s {
        case .ktpt: return d.ktpt.count
        case .enpt: return d.enpt.count
        case .enph: return d.enph.count
        case .itpt: return d.itpt.count
        case .itph: return d.itph.count
        case .ckpt: return d.ckpt.count
        case .ckph: return d.ckph.count
        case .gobj: return d.gobj.count
        case .poti: return potiRows.count
        case .area: return d.area.count
        case .came: return d.came.count
        case .jgpt: return d.jgpt.count
        case .cnpt: return d.cnpt.count
        case .mspt: return d.mspt.count
        case .stgi: return 1
        }
    }

    private func selection(_ s: KMPSection, _ r: Int) -> KMPSelection? {
        switch s {
        case .ktpt: return .ktpt(r)
        case .enpt: return .enpt(r)
        case .enph: return .enph(r)
        case .itpt: return .itpt(r)
        case .itph: return .itph(r)
        case .ckpt: return .ckpt(r)
        case .ckph: return .ckph(r)
        case .gobj: return .gobj(r)
        case .poti: let p = potiRows; return p.indices.contains(r) ? .poti(route: p[r].route, point: p[r].point) : nil
        case .area: return .area(r)
        case .came: return .came(r)
        case .jgpt: return .jgpt(r)
        case .cnpt: return .cnpt(r)
        case .mspt: return .mspt(r)
        case .stgi: return .stgi
        }
    }

    // MARK: Columns

    private typealias Path<E> = (Int) -> ReferenceWritableKeyPath<KMPDocument, E>

    private func col<V: KMPCellValue>(_ title: String, _ path: @escaping Path<V>, width: CGFloat = 90, hex: Bool = false) -> KMPColumn {
        KMPColumn(title: title, width: width,
                  get: { doc, r in doc[keyPath: path(r)].cellText(hex: hex) },
                  set: { doc, r, text in
                      guard let v = V(cellText: text) else { return false }
                      doc[keyPath: path(r)] = v
                      return true
                  })
    }

    private func col<E, V: KMPCellValue>(_ title: String, _ base: @escaping Path<E>, _ kp: WritableKeyPath<E, V>, width: CGFloat = 90, hex: Bool = false) -> KMPColumn {
        col(title, { base($0).appending(path: kp) }, width: width, hex: hex)
    }

    /// A reference to another entry by index: shown counting from 1 like the rest of the editor,
    /// stored counting from 0 as the KMP does. All bits set (0xFF/0xFFFF) means none, shown as "-".
    private func ref<V: KMPCellValue & FixedWidthInteger>(_ title: String, _ path: @escaping Path<V>, width: CGFloat = 56) -> KMPColumn {
        let none = ~V.zero
        return KMPColumn(title: title, width: width,
                         get: { doc, r in let v = doc[keyPath: path(r)]; return v == none ? "-" : String(Int(v) + 1) },
                         set: { doc, r, text in
                             let s = text.trimmingCharacters(in: .whitespaces).lowercased()
                             if s.isEmpty || s == "-" || s == "none" { doc[keyPath: path(r)] = none; return true }
                             guard let n = Int(s), let v = V(exactly: n - 1), n >= 1, v != none else { return false }
                             doc[keyPath: path(r)] = v
                             return true
                         })
    }

    private func ref<E, V: KMPCellValue & FixedWidthInteger>(_ title: String, _ base: @escaping Path<E>, _ kp: WritableKeyPath<E, V>, width: CGFloat = 56) -> KMPColumn {
        ref(title, { base($0).appending(path: kp) }, width: width)
    }

    private func vec3<E>(_ title: String, _ base: @escaping Path<E>, _ kp: WritableKeyPath<E, Vec3>) -> [KMPColumn] {
        [col("\(title) X", base, kp.appending(path: \.x)), col("\(title) Y", base, kp.appending(path: \.y)), col("\(title) Z", base, kp.appending(path: \.z))]
    }

    private func vec2<E>(_ title: String, _ base: @escaping Path<E>, _ kp: WritableKeyPath<E, Vec2>) -> [KMPColumn] {
        [col("\(title) X", base, kp.appending(path: \.x)), col("\(title) Z", base, kp.appending(path: \.y))]
    }

    private func pathColumns(_ base: @escaping Path<PathLinkEntry>) -> [KMPColumn] {
        [ref("Start", base, \.startIndex, width: 50), col("Count", base, \.pointCount, width: 50)]
            + (0..<6).map { ref("Prev \($0 + 1)", base, \.previousGroups[$0]) }
            + (0..<6).map { ref("Next \($0 + 1)", base, \.nextGroups[$0]) }
            + [col("Settings", base, \.settings, width: 70, hex: true)]
    }

    private func columns(_ s: KMPSection) -> [KMPColumn] {
        switch s {
        case .ktpt:
            let b: Path<KTPTEntry> = { \KMPDocument.ktpt[$0] }
            return vec3("Pos", b, \.position) + vec3("Rot", b, \.rotation) + [col("Player", b, \.playerIndex, width: 60)]
        case .enpt:
            let b: Path<ENPTEntry> = { \KMPDocument.enpt[$0] }
            return vec3("Pos", b, \.position) + [col("Radius", b, \.radius), col("Setting 1", b, \.setting1, width: 70), col("Setting 2", b, \.setting2, width: 70)]
        case .itpt:
            let b: Path<ITPTEntry> = { \KMPDocument.itpt[$0] }
            return vec3("Pos", b, \.position) + [col("Radius", b, \.radius), col("Setting 1", b, \.setting1, width: 70), col("Setting 2", b, \.setting2, width: 70)]
        case .enph: return pathColumns { \KMPDocument.enph[$0] }
        case .itph: return pathColumns { \KMPDocument.itph[$0] }
        case .ckph: return pathColumns { \KMPDocument.ckph[$0] }
        case .ckpt:
            let b: Path<CKPTEntry> = { \KMPDocument.ckpt[$0] }
            return vec2("Left", b, \.left) + vec2("Right", b, \.right) + [ref("Respawn", b, \.respawnIndex, width: 60), col("Lap Type", b, \.lapCounterType, width: 60)]
        case .gobj:
            let b: Path<GOBJEntry> = { \KMPDocument.gobj[$0] }
            return [col("Object ID", b, \.objectID, width: 70, hex: true)]
                + vec3("Pos", b, \.position) + vec3("Rot", b, \.rotation) + vec3("Scale", b, \.scale)
                + [ref("Route", b, \.routeID, width: 64)]
                + (0..<8).map { col("S\($0 + 1)", b, \.settings[$0], width: 60) }
                + [col("Presence", b, \.presenceFlags, width: 64, hex: true)]
        case .poti:
            let rows = potiRows
            let route: Path<POTIRoute> = { \KMPDocument.poti[rows[$0].route] }
            let point: Path<RoutePoint> = { \KMPDocument.poti[rows[$0].route].points[rows[$0].point] }
            return [KMPColumn(title: "Route", width: 50, get: { _, r in "\(rows[r].route + 1)" }, set: { _, _, _ in false }),
                    KMPColumn(title: "Point", width: 50, get: { _, r in "\(rows[r].point + 1)" }, set: { _, _, _ in false }),
                    col("Smooth", route, \.setting1, width: 56), col("Open", route, \.setting2, width: 56)]
                + vec3("Pos", point, \.position) + [col("Setting 1", point, \.setting1, width: 70), col("Setting 2", point, \.setting2, width: 70)]
        case .area:
            let b: Path<AREAEntry> = { \KMPDocument.area[$0] }
            return [col("Shape", b, \.shape, width: 50), col("Type", b, \.type, width: 50), ref("Camera", b, \.cameraIndex, width: 60), col("Priority", b, \.priority, width: 60)]
                + vec3("Pos", b, \.position) + vec3("Rot", b, \.rotation) + vec3("Scale", b, \.scale)
                + [col("Setting 1", b, \.setting1, width: 70), col("Setting 2", b, \.setting2, width: 70), ref("Route", b, \.routeID), ref("Enemy Pt", b, \.enptID, width: 64)]
        case .came:
            let b: Path<CAMEEntry> = { \KMPDocument.came[$0] }
            return [col("Type", b, \.type, width: 50), ref("Next", b, \.next), col("Shake", b, \.shake, width: 50), ref("Route", b, \.routeID),
                    col("Point Vel", b, \.pointVelocity, width: 64), col("Zoom Vel", b, \.zoomVelocity, width: 64), col("View Vel", b, \.viewVelocity, width: 64),
                    col("Start", b, \.startFlag, width: 50), col("Movie", b, \.movieFlag, width: 50)]
                + vec3("Pos", b, \.position) + vec3("Rot", b, \.rotation)
                + [col("Zoom Start", b, \.zoomStart), col("Zoom End", b, \.zoomEnd)]
                + vec3("View Start", b, \.viewPositionStart) + vec3("View End", b, \.viewPositionEnd)
                + [col("Time", b, \.time)]
        case .jgpt:
            // The on-disk ID is always written as the entry's index (see `serialize`), so it isn't a column.
            let b: Path<JGPTEntry> = { \KMPDocument.jgpt[$0] }
            return vec3("Pos", b, \.position) + vec3("Rot", b, \.rotation) + [col("Extra", b, \.extra, width: 70, hex: true)]
        case .cnpt:
            let b: Path<CNPTEntry> = { \KMPDocument.cnpt[$0] }
            return vec3("Pos", b, \.position) + vec3("Effect", b, \.effectVector) + [col("Shoot Effect", b, \.shootEffect, width: 80)]
        case .mspt:
            let b: Path<MSPTEntry> = { \KMPDocument.mspt[$0] }
            return vec3("Pos", b, \.position) + vec3("Rot", b, \.rotation) + [col("Extra", b, \.extra, width: 70, hex: true)]
        case .stgi:
            let b: Path<STGIEntry> = { _ in \KMPDocument.stgi }
            return [col("Laps", b, \.lapCount, width: 50), col("Pole", b, \.polePosition, width: 50), col("Distance", b, \.driverDistance, width: 64),
                    col("Flare", b, \.lensFlareFlag, width: 50),
                    col("Flare A", b, \.flareColor.0, width: 60, hex: true), col("Flare R", b, \.flareColor.1, width: 60, hex: true),
                    col("Flare G", b, \.flareColor.2, width: 60, hex: true), col("Flare B", b, \.flareColor.3, width: 60, hex: true),
                    col("Flare Alpha", b, \.flareTransparency, width: 76, hex: true), col("Speed", b, \.speedFactor, width: 64, hex: true),
                    ref("Opening Cam", { _ in \KMPDocument.openingCameraIndex }, width: 84), ref("Select Cam", { _ in \KMPDocument.selectionCameraIndex }, width: 76),
                    col("Version", { _ in \KMPDocument.version }, width: 64, hex: true)]
        }
    }
}

/// One editable cell: keeps its own text while typing and only writes back on Return or focus loss,
/// so half-typed numbers ("1.", "-") aren't reformatted mid-edit.
private struct KMPCell: View {
    let value: String
    let commit: (String) -> Bool
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.system(.caption, design: .monospaced))
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .focused($focused)
            .overlay(alignment: .trailing) { Divider() }
            .onAppear { text = value }
            .onChange(of: value) { _, v in text = v }
            .onSubmit(apply)
            .onChange(of: focused) { _, f in if !f { apply() } }
    }

    private func apply() {
        guard text != value else { return }
        if !commit(text) { text = value }
    }
}
