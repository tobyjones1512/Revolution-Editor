import SwiftUI
import Combine

/// A to-do page per project: steps to take and loose ideas, with starter checklists for each
/// game's kinds of mod. Kept in UserDefaults under the project's folder path.
struct TodoItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var done = false
    var isIdea = false
}

private struct TodoTemplate: Identifiable {
    let game: String
    let name: String
    let steps: [String]
    var id: String { game + name }
}

private let todoTemplates: [TodoTemplate] = [
    TodoTemplate(game: "Mario Kart Wii", name: "Custom Track", steps: [
        "Sketch the layout, laps and theme",
        "Model the course and export it as a BRRES (course_model)",
        "Add the sky (vrcorn_model) and any textures",
        "Create the collision KCL and set every surface type",
        "Place the start point and respawn points in the KMP",
        "Draw the enemy paths and item paths",
        "Draw the checkpoints and run Check Laps",
        "Add item boxes and other objects, with their model files",
        "Add the intro cameras and replay cameras",
        "Build the minimap (map_model)",
        "Pick or make the music (BRSTM) and set the track name in the BMG",
        "Check Track Budget and fix anything over",
        "Run Verify Archive and fix every error",
        "Test with Hot Swap in Dolphin",
        "Build the .szs or .wbz to share",
    ]),
    TodoTemplate(game: "Mario Kart Wii", name: "Battle Arena", steps: [
        "Sketch the arena and where the players start",
        "Model the arena and export it as a BRRES",
        "Create the collision KCL and set every surface type",
        "Place one start point per player in the KMP",
        "Add the battle respawn points and a CPU path loop",
        "Add item boxes",
        "Add the intro camera",
        "Build the minimap",
        "Run Verify Archive and fix every error",
        "Test with Hot Swap in Dolphin, with a full set of players",
        "Build the .szs or .wbz to share",
    ]),
    TodoTemplate(game: "Mario Kart Wii", name: "Texture or Model Replacement", steps: [
        "List the files to change",
        "Extract them from the base game",
        "Edit the textures or models",
        "Put them back and keep the same names",
        "Check the file sizes against the originals",
        "Test with Hot Swap in Dolphin",
    ]),
    TodoTemplate(game: "Mario Kart: Double Dash!!", name: "Custom Track", steps: [
        "Choose the slot the track will replace",
        "Sketch the layout and theme",
        "Model the course (or port one with Wii to Double Dash)",
        "Create the BCO collision and set every surface type",
        "Place the start point and respawn points in the BOL",
        "Draw the enemy path, with equal-length checkpoint branches",
        "Draw the checkpoints and check the lap rules",
        "Add item boxes",
        "Add the intro cameras and the replay cameras",
        "Fit the track inside the slot's minimap area and draw the minimap",
        "Check Track Budget",
        "Run Verify Archive and fix every error",
        "Test in Dolphin",
        "Build the course archive",
    ]),
    TodoTemplate(game: "Mario Kart: Double Dash!!", name: "Battle Map", steps: [
        "Choose the battle slot to replace",
        "Sketch the arena",
        "Model the arena",
        "Create the BCO collision",
        "Place the battle start points in the BOL",
        "Add respawn points and item boxes",
        "Add the intro camera",
        "Draw the minimap",
        "Run Verify Archive and fix every error",
        "Test in Dolphin with several players",
        "Build the course archive",
    ]),
    TodoTemplate(game: "New Super Mario Bros. Wii", name: "Custom Level", steps: [
        "Sketch the level and its goal",
        "Build the tiles and the layout",
        "Place enemies, items and entrances",
        "Set the zones, camera and background",
        "Test in Dolphin and play it through",
        "Save and share the level",
    ]),
    TodoTemplate(game: "Wii Homebrew", name: "New App", steps: [
        "Write down what the app should do",
        "Create the project and build the first screen",
        "Add the main features",
        "Handle the Wii Remote and GameCube controller",
        "Build and run in Dolphin",
        "Fix crashes, using Review Crash Logs",
        "Write the Homebrew Channel info (meta.xml and icon)",
        "Build the final .dol",
    ]),
]

@MainActor private final class TodoStore: ObservableObject {
    @Published var items: [TodoItem] = []
    private var key = ""

    func load(_ projectPath: String) {
        key = "todo." + projectPath
        items = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([TodoItem].self, from: $0) } ?? []
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: key)
    }
}

struct TodoView: View {
    private static let general = "General"
    @StateObject private var store = TodoStore()
    @State private var list = ""
    @State private var newTitle = ""
    @State private var newIsIdea = false

    private var lists: [String] {
        var out = [Self.general]
        let recent = (UserDefaults.standard.stringArray(forKey: "WorkbenchState.recentProjects") ?? [])
        for p in recent where !out.contains(p) { out.append(p) }
        if !out.contains(list) { out.append(list) }
        return out
    }

    private var steps: [TodoItem] { store.items.filter { !$0.isIdea } }
    private var progress: Double { steps.isEmpty ? 0 : Double(steps.filter(\.done).count) / Double(steps.count) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Project", selection: $list) {
                    ForEach(lists, id: \.self) { Text($0 == Self.general ? $0 : URL(fileURLWithPath: $0).lastPathComponent).tag($0) }
                }
                .frame(maxWidth: 280)
                Spacer()
                Menu {
                    ForEach(Dictionary(grouping: todoTemplates, by: \.game).keys.sorted(), id: \.self) { game in
                        Section(game) {
                            ForEach(todoTemplates.filter { $0.game == game }) { t in
                                Button(t.name) { fill(t) }
                            }
                        }
                    }
                } label: { Label("Auto Fill Steps", systemImage: "wand.and.stars") }
                    .help("Adds a starter checklist for a kind of mod. Steps you already have are kept, and none are added twice.")
            }
            .padding(12)
            if !steps.isEmpty {
                ProgressView(value: progress) { Text("\(steps.filter(\.done).count) of \(steps.count) steps done").font(.caption) }
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
            Divider()
            List {
                section("Steps", idea: false)
                section("Ideas", idea: true)
            }
            Divider()
            HStack {
                Picker("", selection: $newIsIdea) { Text("Step").tag(false); Text("Idea").tag(true) }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 120)
                TextField("Add a step or an idea", text: $newTitle).onSubmit(add)
                Button("Add", action: add).disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(minWidth: 520, minHeight: 480)
        .onAppear { if list.isEmpty { list = WorkbenchRegistry.shared.currentProjectPath ?? Self.general } }
        .onChange(of: list) { _, new in store.load(new) }
        .onChange(of: store.items) { store.save() }
    }

    @ViewBuilder private func section(_ title: String, idea: Bool) -> some View {
        let rows = store.items.indices.filter { store.items[$0].isIdea == idea }
        Section(title) {
            if rows.isEmpty {
                Text(idea ? "Ideas you want to come back to." : "Add steps, or use Auto Fill Steps.").foregroundStyle(.secondary).font(.callout)
            }
            ForEach(rows, id: \.self) { i in
                HStack {
                    Toggle("", isOn: $store.items[i].done).labelsHidden().toggleStyle(.checkbox)
                    TextField("", text: $store.items[i].title)
                        .textFieldStyle(.plain)
                        .strikethrough(store.items[i].done)
                        .foregroundStyle(store.items[i].done ? .secondary : .primary)
                    Spacer()
                    Button { store.items[i].isIdea.toggle() } label: { Image(systemName: idea ? "arrow.up.circle" : "lightbulb") }
                        .buttonStyle(.borderless).help(idea ? "Make this a step" : "Move to ideas")
                    Button { store.items.remove(at: i) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Delete")
                }
            }
            .onMove { from, to in
                // Reorder within this section, keeping the other section's rows where they are.
                var sub = rows.map { store.items[$0] }
                sub.move(fromOffsets: from, toOffset: to)
                for (k, i) in rows.enumerated() { store.items[i] = sub[k] }
            }
        }
    }

    private func add() {
        let t = newTitle.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        store.items.append(TodoItem(title: t, isIdea: newIsIdea))
        newTitle = ""
    }

    private func fill(_ t: TodoTemplate) {
        let have = Set(store.items.map(\.title))
        store.items += t.steps.filter { !have.contains($0) }.map { TodoItem(title: $0) }
    }
}
