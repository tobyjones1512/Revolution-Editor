import Combine
import SwiftUI

/// Mario Kart Wii > Port > To Double Dash on a track `.szs`: picks the Double Dash slot it
/// replaces and writes that slot's main archive beside the track (see `MKWiiToMKDD`).
struct WiiToDoubleDashRequest: Identifiable {
    let url: URL
    var id: String { url.path }
}

struct WiiToDoubleDashSheet: View {
    let request: WiiToDoubleDashRequest
    @EnvironmentObject var workbench: WorkbenchState
    @Environment(\.dismiss) private var dismiss
    @State private var slot = MKDDSlots.slots.first { $0.archive == "Luigi2" }!
    @State private var scale = Double(MKWiiToMKDD.defaultScale)
    @State private var fitScale = false
    @State private var discURL = DoubleDashDisc.linkedISO
    @State private var working = false
    @State private var error: String?
    @State private var unmatched: [(key: UInt16, count: Int)] = []
    @State private var choices: [UInt16: UInt16?] = [:]

    private var destination: URL { request.url.deletingLastPathComponent().appendingPathComponent("Double Dash Ports") }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Port to Double Dash").font(.headline)
            Text("Makes \(request.url.lastPathComponent) a Mario Kart: Double Dash!! course: the model and sky (textures fitted to the GameCube's memory, shadow maps baked into vertex colours), collision (Double Dash's flat walls laid along the track's edges), and course data (start, CPU route, checkpoints, respawns, item boxes, an intro camera). Objects, areas and cameras with no Double Dash equivalent are listed in the console.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                Picker("Replaces", selection: $slot) {
                    ForEach(MKDDSlots.slots.filter { !$0.battle }) { Text($0.title).tag($0) }
                }
                LabeledContent("Scale") {
                    HStack {
                        TextField("", value: $scale, format: .number.precision(.fractionLength(0...3))).frame(width: 60).disabled(fitScale)
                        Text("x. Double Dash courses are ~1/1.32 their Wii remakes").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Toggle("Scale to fit the slot's minimap", isOn: $fitScale)
                    .help("Double Dash hardcodes each slot's minimap area. The track is always centred on it (and turned if that fits better); this also scales it to fill the area, which changes how big it feels to drive.")
                    .disabled(discURL == nil)
                LabeledContent("Double Dash disc") {
                    HStack {
                        Text(discURL?.lastPathComponent ?? "Not linked, minimap drawn to fit").foregroundStyle(discURL == nil ? .secondary : .primary).lineLimit(1)
                        Button("Choose...") {
                            PanelPresenter.openFile(configure: { $0.allowsOtherFileTypes = true }) { url in
                                guard let url else { return }
                                DoubleDashDisc.link(url); discURL = url
                            }
                        }
                    }
                }
            }
            if !unmatched.isEmpty { BCOSurfaceChoicesView(items: unmatched, choices: $choices) }
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Text("Saved to \(destination.lastPathComponent)/ beside the track").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(working ? "Porting..." : "Port") { port() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || !(scale > 0))
            }
        }
        .padding(20)
        .frame(width: 540)
        .task {
            let url = request.url
            unmatched = await Task.detached {
                guard let (root, _) = try? SZS.open(Data(contentsOf: url)),
                      let data = root.children.first(where: { $0.name == "course.kcl" })?.data,
                      let kcl = try? KCLDocument.parse(data) else { return [] }
                return MKWiiToMKDD.unmatchedTypes(in: kcl)
            }.value
        }
    }

    private func port() {
        working = true
        let (url, slot, scale, fit, destination) = (request.url, slot, Float(scale), fitScale, destination)
        var picked: [UInt16: UInt16?] = [:]
        for item in unmatched { picked[item.key] = choices[item.key] ?? BCOSurfaceChoicesView.defaultChoice(item.key) }
        Task.detached(priority: .userInitiated) {
            let (minimap, why) = DoubleDashDisc.minimap(for: slot)
            do {
                let data = try Data(contentsOf: url)
                var out = try MKWiiToMKDD.port(data, name: url.lastPathComponent, slot: slot, scale: scale, minimap: minimap, fitScale: fit && minimap != nil, choices: picked)
                if let why { out.report.append("(\(why).)") }
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                for (name, archive) in out.archives { try archive.write(to: destination.appendingPathComponent(name), options: .atomic) }
                await MainActor.run { [out] in
                    workbench.log("Ported \(url.lastPathComponent) to Double Dash (\(slot.title)):")
                    AppNotifications.port(success: true, detail: "Ported \(url.lastPathComponent) to Double Dash (\(slot.title)).")
                    out.report.forEach { workbench.log("  " + $0) }
                    workbench.refreshFolderTree()
                    working = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    working = false
                    AppNotifications.port(success: false, detail: "\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
    }
}

/// Picks a Double Dash surface for each Mario Kart Wii collision type that has no exact match
/// (`MKWiiToMKDD.unmatchedTypes`), starting from the port's own guess.
struct BCOSurfaceChoicesView: View {
    let items: [(key: UInt16, count: Int)]
    @Binding var choices: [UInt16: UInt16?]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pick what these Mario Kart Wii surfaces become in Double Dash:").font(.caption).foregroundStyle(.secondary)
            ForEach(items, id: \.key) { item in
                Picker(selection: Binding(get: { choices[item.key] ?? Self.defaultChoice(item.key) },
                                          set: { choices[item.key] = .some($0) })) {
                    Text(item.key == MKWiiToMKDD.trickableKey ? "Keep its own surface" : item.key == MKWiiToMKDD.upwardWallKey ? "Keep as wall" : "Leave out").tag(UInt16?.none)
                    ForEach(BCO.typeNames.keys.sorted(), id: \.self) { type in
                        Text(BCO.flagName(type << 8)).tag(UInt16?.some(type << 8))
                    }
                } label: {
                    Text(Self.title(item.key))
                        + Text(" · \(item.count)").foregroundStyle(.secondary)
                }
            }
        }
    }

    private static func title(_ key: UInt16) -> String {
        switch key {
        case MKWiiToMKDD.trickableKey: return "Trickable surfaces (no tricks in Double Dash)"
        case MKWiiToMKDD.upwardWallKey: return "Walls facing up like a floor"
        default: return kclBaseTypeName(Int(key))
        }
    }

    static func defaultChoice(_ key: UInt16) -> UInt16? {
        switch key {
        case MKWiiToMKDD.trickableKey, MKWiiToMKDD.upwardWallKey: return nil
        default: return MKWiiToMKDD.unmatchedDefaults[key] ?? nil
        }
    }

    /// Asks in a modal alert (for a conversion that runs straight after its save panel); nil if cancelled.
    @MainActor static func ask(_ items: [(key: UInt16, count: Int)]) -> [UInt16: UInt16?]? {
        guard !items.isEmpty else { return [:] }
        final class Holder: ObservableObject { @Published var choices: [UInt16: UInt16?] = [:] }
        let holder = Holder()
        struct Wrapper: View {
            @ObservedObject var holder: Holder
            let items: [(key: UInt16, count: Int)]
            var body: some View { BCOSurfaceChoicesView(items: items, choices: $holder.choices).padding(.vertical, 4).frame(width: 420) }
        }
        let alert = NSAlert()
        alert.messageText = "Choose Double Dash Surfaces"
        alert.informativeText = "Choose what each of these Mario Kart Wii collision types becomes."
        let host = NSHostingView(rootView: Wrapper(holder: holder, items: items))
        host.frame.size = host.fittingSize
        alert.accessoryView = host
        alert.addButton(withTitle: "Convert")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        var out: [UInt16: UInt16?] = [:]
        for item in items { out[item.key] = holder.choices[item.key] ?? defaultChoice(item.key) }
        return out
    }
}
