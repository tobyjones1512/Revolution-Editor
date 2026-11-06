import SwiftUI
import Combine

/// Every STGI field plus the two header camera indices, the track-wide settings that don't
/// belong to any point on the canvas. Shared by the KMP editor and the 3D track viewer.
struct KMPStageInfoFields: View {
    @ObservedObject var box: KMPDocumentBox
    let onCommit: () -> Void

    private func bind<T>(_ get: @escaping () -> T, _ set: @escaping (T) -> Void) -> Binding<T> {
        Binding(get: get, set: { set($0); box.isDirty = true; box.objectWillChange.send(); onCommit() })
    }

    var body: some View {
        if box.doc.isBOL { doubleDashFields } else { wiiFields }
    }

    /// A Double Dash .bol has no STGI, just the lap count and each start point's pole side.
    private var doubleDashFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Stepper("Laps: \(box.doc.stgi.lapCount)", value: bind({ Int(box.doc.stgi.lapCount) }, { box.doc.stgi.lapCount = UInt8($0) }), in: 1...9)
                .font(.caption)
            Picker("Pole position", selection: bind({ box.doc.stgi.polePosition }, { box.doc.stgi.polePosition = $0 })) {
                Text("Left").tag(UInt8(0)); Text("Right").tag(UInt8(1))
            }.font(.caption)
            Text("Fog, lighting and other course settings are kept as they are in the file.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var wiiFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                Button("Reset to Defaults") {
                    // What retail tracks use: 3 laps, left pole, normal grid, lens flare on with the
                    // standard colour (stored A,R,G,B = 00 e6 e6 e6) and transparency, normal speed.
                    box.doc.stgi = STGIEntry(lapCount: 3, polePosition: 0, driverDistance: 0, lensFlareFlag: 1,
                                             flareColor: (0x00, 0xE6, 0xE6, 0xE6), flareTransparency: 0x4B, speedFactor: 0)
                    box.isDirty = true
                    box.objectWillChange.send()
                    speedText = Self.format(speed)
                    onCommit()
                }
                .font(.caption)
                .help("Sets Stage Info back to what retail tracks use: 3 laps, left pole, normal spacing, the standard lens flare, normal speed.")
            }
            Stepper("Laps: \(box.doc.stgi.lapCount)", value: bind({ Int(box.doc.stgi.lapCount) }, { box.doc.stgi.lapCount = UInt8($0) }), in: 1...9)
                .font(.caption)
            Picker("Pole position", selection: bind({ box.doc.stgi.polePosition }, { box.doc.stgi.polePosition = $0 })) {
                Text("Left").tag(UInt8(0)); Text("Right").tag(UInt8(1))
            }.font(.caption)
            Picker("Grid spacing", selection: bind({ box.doc.stgi.driverDistance }, { box.doc.stgi.driverDistance = $0 })) {
                Text("Normal").tag(UInt8(0)); Text("Narrow").tag(UInt8(1))
            }.font(.caption)
            HStack {
                Text("Speed").font(.caption)
                Spacer()
                TextField("1.0", text: $speedText)
                    .textFieldStyle(.roundedBorder).frame(width: 70)
                    .onSubmit { commitSpeed() }
                    .onChange(of: speedTextFocused) { _, focused in if !focused { commitSpeed() } }
                    .focused($speedTextFocused)
                Stepper("", onIncrement: { setSpeed(speed + 0.05) }, onDecrement: { setSpeed(speed - 0.05) }).labelsHidden()
                Text("x").font(.caption)
            }
            Text("1 = normal; decimals allowed (e.g. 1.25). Every retail track uses 1, and the unmodified game is believed to ignore this field, it takes effect with CTGP / LE-CODE. Stored as the top half of a float, so the nearest value it can hold is shown after you press Return.")
                .font(.caption2).foregroundStyle(.secondary)
            Divider()
            Toggle("Lens flare", isOn: bind({ box.doc.stgi.lensFlareFlag != 0 }, { box.doc.stgi.lensFlareFlag = $0 ? 1 : 0 })).font(.caption)
            // The file stores the colour as A,R,G,B with A always 0 on retail tracks; opacity is the
            // separate transparency byte below, so the picker only edits R,G,B.
            ColorPicker("Flare colour", selection: bind({
                let c = box.doc.stgi.flareColor
                return Color(.sRGB, red: Double(c.1) / 255, green: Double(c.2) / 255, blue: Double(c.3) / 255)
            }, { color in
                let c = NSColor(color).usingColorSpace(.sRGB) ?? .white
                box.doc.stgi.flareColor = (0, UInt8(c.redComponent * 255), UInt8(c.greenComponent * 255), UInt8(c.blueComponent * 255))
            }), supportsOpacity: false).font(.caption)
            HStack {
                Text("Flare transparency").font(.caption)
                Spacer()
                TextField("", value: bind({ Int(box.doc.stgi.flareTransparency) }, { box.doc.stgi.flareTransparency = UInt8(clamping: $0) }), format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder).frame(width: 70)
            }
            if !box.doc.came.isEmpty {
                Divider()
                cameraPicker("Opening camera", bind({ box.doc.openingCameraIndex }, { box.doc.openingCameraIndex = $0 }))
                cameraPicker("Course-select camera", bind({ box.doc.selectionCameraIndex }, { box.doc.selectionCameraIndex = $0 }))
            }
        }
        .onAppear { speedText = Self.format(speed) }
        // Undo or another view changing it: follow along unless the user is mid-typing.
        .onChange(of: box.doc.stgi.speedFactor) { _, _ in if !speedTextFocused { speedText = Self.format(speed) } }
    }

    @State private var speedText = ""
    @FocusState private var speedTextFocused: Bool

    /// The speed the game will actually use (0 in the file means normal, 1x).
    private var speed: Double {
        box.doc.stgi.speedFactor == 0 ? 1 : Double(Float(bitPattern: UInt32(box.doc.stgi.speedFactor) << 16))
    }

    private static func format(_ v: Double) -> String {
        String(format: "%.5f", v).replacingOccurrences(of: "0+$", with: "", options: .regularExpression).replacingOccurrences(of: "\\.$", with: ".0", options: .regularExpression)
    }

    private func commitSpeed() {
        // Accept a comma as the decimal separator too.
        if let v = Double(speedText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) { setSpeed(v) }
        speedText = Self.format(speed)
    }

    /// Rounds to the nearest value the top 16 bits of a float can hold, rather than truncating.
    private func setSpeed(_ v: Double) {
        let clamped = Float(min(max(v, 0.1), 10))
        let bits = UInt16(min(UInt32(0xFFFF), (clamped.bitPattern + 0x8000) >> 16))
        box.doc.stgi.speedFactor = bits == 0x3F80 ? 0 : bits
        box.isDirty = true
        box.objectWillChange.send()
        onCommit()
        speedText = Self.format(speed)
    }

    private func cameraPicker(_ label: String, _ value: Binding<UInt8>) -> some View {
        Picker(label, selection: value) {
            ForEach(box.doc.came.indices, id: \.self) { Text("Camera \($0 + 1)").tag(UInt8($0)) }
            if Int(value.wrappedValue) >= box.doc.came.count { Text("None").tag(value.wrappedValue) }
        }
        .font(.caption)
    }
}
