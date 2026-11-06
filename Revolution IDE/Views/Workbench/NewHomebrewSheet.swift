import SwiftUI

/// File > New > Wii Homebrew Project: names a project, picks C or C++ and where it goes, then
/// writes the devkitPPC template (see `HomebrewTemplate`) and opens it as the workbench project.
struct NewHomebrewSheet: View {
    @EnvironmentObject var workbench: WorkbenchState
    @Environment(\.dismiss) private var dismiss
    @State private var name = "MyHomebrew"
    @State private var language = HomebrewTemplate.Language.c
    @State private var parent: URL? = {
        UserDefaults.standard.string(forKey: "Homebrew.lastParent").map { URL(fileURLWithPath: $0) }
    }()
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Wii Homebrew Project").font(.headline)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            Picker("Language", selection: $language) {
                ForEach(HomebrewTemplate.Language.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            HStack {
                Text(parent?.path ?? "No folder chosen").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose Folder...") { chooseParent() }
            }
            if DevkitPro.root == nil {
                Text("devkitPro isn't installed yet. You can still create the project, but building needs it. Install it from devkitpro.org, or locate it in Settings > Homebrew.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(parent == nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
    }

    private func chooseParent() {
        PanelPresenter.openFile(configure: {
            $0.canChooseFiles = false
            $0.canChooseDirectories = true
            $0.canCreateDirectories = true
        }) { url in
            guard let url else { return }
            parent = url
            UserDefaults.standard.set(url.path, forKey: "Homebrew.lastParent")
        }
    }

    private func create() {
        guard let parent else { return }
        do {
            let dir = try HomebrewTemplate.create(name: name.trimmingCharacters(in: .whitespaces), language: language, in: parent)
            workbench.openFolder(url: dir)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
