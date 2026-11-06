import SwiftUI
import UniformTypeIdentifiers

/// Picks a GOBJ object type from `gobjGroups`: one entry per friendly name ("Item Box"), with the
/// real objects that are versions of it in a submenu, each labelled with its internal name and
/// the retail course(s) that use it. Used by the KMP editor and the 3D editor.
struct ObjectTypeMenu: View {
    let selection: UInt16
    /// Double Dash (.bol): a flat list of its own objects instead.
    var doubleDash = false
    /// Writes files into the track (paths relative to the course root). When set, the menu also
    /// offers the user's custom objects, installing the chosen one's model.
    var install: (([(path: [String], data: Data)]) -> Void)? = nil
    let onSelect: (UInt16) -> Void

    @ObservedObject private var customObjects = CustomObjectStore.shared
    @State private var creatingCustom = false

    var body: some View {
        if doubleDash {
            Menu {
                ForEach(BOL.objectNames.keys.sorted(), id: \.self) { item($0, title: BOL.objectName($0)) }
            } label: {
                Text(BOL.objectName(selection)).lineLimit(1)
            }
            .help("Double Dash object type.")
        } else {
            wiiMenu
        }
    }

    private var wiiMenu: some View {
        Menu {
            // The objects custom tracks use most, one click each (the standard version).
            ForEach(Self.basics, id: \.id) { basic in
                item(basic.id, title: basic.name)
            }
            Divider()
            if let install {
                Menu("Custom") {
                    ForEach(customObjects.objects) { object in
                        if let id = object.objectID, let host = object.host {
                            Button("\(object.name)  (\(host.title.components(separatedBy: " (").first ?? ""))") {
                                guard let data = customObjects.modelData(for: object) else { return }
                                install([(object.trackFilePath, data)])
                                onSelect(id)
                            }
                        }
                    }
                    if !customObjects.objects.isEmpty { Divider() }
                    Button("New Custom Object...") { creatingCustom = true }
                    if !customObjects.objects.isEmpty {
                        Menu("Delete") {
                            ForEach(customObjects.objects) { object in
                                Button(object.name) { customObjects.remove(object) }
                            }
                        }
                    }
                }
                .help("Your own models from .obj files. Each borrows a slot (a retail decoration whose model the track replaces), so a track can hold one custom object per slot.")
            }
            Menu("Other") {
                ForEach(gobjGroups) { group in
                    if group.ids.count == 1, let id = group.ids.first {
                        item(id, title: "\(group.name)  (\(variantLabel(id)))")
                    } else {
                        Menu(group.name) {
                            ForEach(group.ids, id: \.self) { item($0, title: variantLabel($0)) }
                        }
                    }
                }
            }
        } label: {
            Text(gobjFriendlyName(selection)).lineLimit(1)
        }
        .sheet(isPresented: $creatingCustom) { NewCustomObjectSheet() }
        .help("Object type. Each name groups the game's own versions of that object; the course next to each shows where Nintendo uses it.")
    }

    /// Top-level entries: the everyday version of each common object (every version is still
    /// under Other).
    static let basics: [(name: String, id: UInt16)] = [
        ("Item Box", 0x065), ("Coin", 0x073), ("Wooden Crate", 0x070),
        ("Goomba", 0x191), ("Chain Chomp", 0x196), ("Piranha Plant", 0x194), ("Thwomp", 0x0DB),
        ("Cheep Cheep", 0x172), ("Pokey", 0x199), ("Monty Mole", 0x192), ("Fire Snake", 0x1A4),
    ]

    private func variantLabel(_ id: UInt16) -> String {
        "\(gobjDisplayName(id)). \(gobjRetailWhere[id] ?? "unused")"
    }

    @ViewBuilder
    private func item(_ id: UInt16, title: String) -> some View {
        Button { onSelect(id) } label: {
            if id == selection { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}

/// Name, slot, collision and .obj for a new custom object (see `CustomObject`).
private struct NewCustomObjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var hostResource = CustomObject.hosts[0].resource
    @State private var solid = false
    @State private var objURL: URL?
    @State private var error: String?

    var body: some View {
        Form {
            TextField("Name", text: $name)
            Picker("Slot", selection: $hostResource) {
                ForEach(CustomObject.hosts, id: \.resource) { Text($0.title).tag($0.resource) }
            }
            Toggle("Solid (karts bump into a tree-trunk-sized cylinder)", isOn: $solid)
            HStack {
                Text(objURL?.lastPathComponent ?? "No model chosen").foregroundStyle(objURL == nil ? .secondary : .primary)
                Spacer()
                Button("Choose Model...") {
                    PanelPresenter.openFile(configure: { $0.allowedContentTypes = ModelFile.contentTypes }) { url in
                        objURL = url
                        if name.isEmpty, let url { name = url.deletingPathExtension().lastPathComponent }
                    }
                }
            }
            Text("The model replaces the slot's tree in any track you place this in, so each track can use one custom object per slot. Textures come from the .obj's .mtl, or the .dae's own materials.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(objURL == nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 440)
    }

    private func create() {
        guard let objURL, let host = CustomObject.hosts.first(where: { $0.resource == hostResource }) else { return }
        do {
            try CustomObjectStore.shared.add(name: name.trimmingCharacters(in: .whitespaces), host: host, solid: solid, objURL: objURL)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
