import SwiftUI
import Combine

/// Mario Kart Double Dash > Port > To Mario Kart Wii on a Double Dash disc image: lists the disc's courses
/// and ports the chosen ones to Mario Kart Wii `.szs` tracks in a folder beside the disc.
struct DoubleDashPortRequest: Identifiable {
    let id: String
    let isoURL: URL
}

struct DoubleDashPortSheet: View {
    let request: DoubleDashPortRequest
    @EnvironmentObject var workbench: WorkbenchState
    @Environment(\.dismiss) private var dismiss
    @State private var courses: [(name: String, data: Data)] = []
    @State private var selected: Set<String> = []
    @State private var scale: Double = Double(MKDDPort.defaultScale)
    @State private var wallStrip = MKDDPort.defaultWallStripFlag
    @State private var error: String?

    /// Double Dash's archive names for its courses. Each has an `L` multiplayer twin, and Luigi
    /// Circuit's 50cc race has its own `Luigi.arc`; the same course, so only the main one is listed.
    nonisolated static let courseNames: [String: String] = [
        "Luigi2": "Luigi Circuit", "Peach": "Peach Beach", "BabyLuigi": "Baby Park",
        "Desert": "Dry Dry Desert", "Nokonoko": "Mushroom Bridge", "Daisy": "Daisy Cruiser", "Waluigi": "Waluigi Stadium",
        "Snow": "Sherbet Land", "Patapata": "Mushroom City", "Yoshi": "Yoshi Circuit", "Mario": "Mario Circuit",
        "Donkey": "DK Mountain", "Wario": "Wario Colosseum", "Diddy": "Dino Dino Jungle", "Koopa": "Bowser's Castle",
        "Rainbow": "Rainbow Road",
    ]

    private var destination: URL {
        request.isoURL.deletingLastPathComponent().appendingPathComponent("Double Dash Ports")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Port from Double Dash").font(.headline)
                Text("Each course becomes a Mario Kart Wii track (.szs) with its model, sky, collision, minimap, CPU and item paths, checkpoints, respawn points, item boxes and intro cameras. Rename a result to the track slot you want to replace (e.g. beginner_course.szs).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            Divider()
            if let error {
                Text(error).foregroundStyle(.red).padding(20)
            } else if courses.isEmpty {
                ProgressView("Reading disc...").frame(maxWidth: .infinity).padding(40)
            } else {
                List(courses, id: \.name) { course in
                    Toggle(isOn: Binding(get: { selected.contains(course.name) },
                                         set: { if $0 { selected.insert(course.name) } else { selected.remove(course.name) } })) {
                        HStack {
                            Text(Self.courseNames[course.name] ?? course.name)
                            Spacer()
                            Text(course.name.hasPrefix("Mini") ? "battle arena" : "\(course.name).arc")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                .frame(minHeight: 280)
            }
            Divider()
            HStack {
                Text("Scale").font(.caption)
                TextField("", value: $scale, format: .number.precision(.fractionLength(0...2))).frame(width: 50)
                Text("x: Nintendo's own Wii remake of Mario Circuit is ~1.18x").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("All") { selected = Set(courses.map(\.name)) }
                Button("None") { selected = [] }
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            WallStripPicker(flag: $wallStrip).padding(.horizontal, 20).padding(.bottom, 10)
            Divider()
            HStack {
                Text("Saved to \(destination.lastPathComponent)/ beside the disc image").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Port \(selected.count) Course\(selected.count == 1 ? "" : "s")") {
                    workbench.portFromDoubleDash(courses.filter { selected.contains($0.name) }, to: destination, scale: Float(max(0.1, scale)), wallStrip: wallStrip)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 520)
        .task { load() }
    }

    private func load() {
        let url = request.isoURL
        Task.detached(priority: .userInitiated) {
            do {
                let disc = try GameCubeDisc(url: url)
                var found: [(name: String, data: Data)] = []
                func walk(_ n: DiscNode, _ path: String) throws {
                    if n.isDirectory { for c in n.children { try walk(c, path + "/" + c.name) }; return }
                    let base = (n.name as NSString).deletingPathExtension
                    // Course archives only: skip the multiplayer and 50cc twins and the award/ending scenes.
                    guard path.contains("/Course/"), n.name.lowercased().hasSuffix(".arc"), !base.hasSuffix("L"),
                          !["Award", "Ending", "Luigi"].contains(base) else { return }
                    found.append((base, try disc.readFile(node: n)))
                }
                try walk(disc.root, "")
                guard !found.isEmpty else { throw WSError.badStructure("No Double Dash courses (Course/*.arc) on this disc.") }
                let races = found.filter { !$0.name.hasPrefix("Mini") }.sorted { (Self.courseNames[$0.name] ?? $0.name) < (Self.courseNames[$1.name] ?? $1.name) }
                let arenas = found.filter { $0.name.hasPrefix("Mini") }.sorted { $0.name < $1.name }
                await MainActor.run {
                    courses = races + arenas
                    selected = Set(races.map(\.name))
                }
            } catch {
                await MainActor.run { self.error = "Couldn't read this as a Double Dash disc: \(error.localizedDescription)" }
            }
        }
    }
}

/// What Double Dash's flat wall strips become in Mario Kart Wii (see `MKDDPort.defaultWallStripFlag`).
struct WallStripPicker: View {
    @Binding var flag: UInt16

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Double Dash wall strips become", selection: $flag) {
                ForEach(MKDDPort.wallStripChoices, id: \.self) { f in
                    Text(kclBaseTypeName(Int(f)) + (f == 0x000C ? " (facing up: usually wrong)" : "")).tag(f)
                }
            }
            .font(.caption)
            Text("Double Dash's walls are flat strips beside the road. Mario Kart Wii gets real upright walls along the track's edges either way; a wall facing up like a floor is almost always wrong.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Asks in a modal alert (for a port or conversion that starts straight away); nil if cancelled.
    @MainActor static func ask() -> UInt16? {
        final class Holder: ObservableObject { @Published var flag = MKDDPort.defaultWallStripFlag }
        struct Wrapper: View {
            @ObservedObject var holder: Holder
            var body: some View { WallStripPicker(flag: $holder.flag).padding(.vertical, 4).frame(width: 400) }
        }
        let holder = Holder()
        let alert = NSAlert()
        alert.messageText = "Choose a Flag for Double Dash's Walls"
        alert.informativeText = "Pick the Mario Kart Wii collision flag Double Dash's flat wall strips become."
        let host = NSHostingView(rootView: Wrapper(holder: holder))
        host.frame.size = host.fittingSize
        alert.accessoryView = host
        alert.addButton(withTitle: "Port")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? holder.flag : nil
    }
}
