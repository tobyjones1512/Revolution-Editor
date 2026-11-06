import SwiftUI
import UniformTypeIdentifiers

/// Edits the Homebrew Channel's name/author/description and 128x48 icon for the open project
/// (`meta.json` + `icon.png`); every build turns them into `out/apps/<name>/meta.xml` and `icon.png`.
struct HomebrewInfoSheet: View {
    let project: URL
    @Environment(\.dismiss) private var dismiss
    @State private var meta: HomebrewMeta
    @State private var iconVersion = 0
    @State private var error: String?

    init(project: URL) {
        self.project = project
        _meta = State(initialValue: HomebrewMeta.load(project: project))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Homebrew Channel Info").font(.headline)
            HStack(alignment: .top, spacing: 16) {
                VStack {
                    Group {
                        if let img = (iconVersion >= 0 ? NSImage(contentsOf: HomebrewMeta.iconURL(in: project)) : nil) {
                            Image(nsImage: img).resizable().interpolation(.none)
                        } else {
                            Image(systemName: "photo").font(.title).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 128, height: 48).background(Color.secondary.opacity(0.15))
                    Button("Choose Icon...") {
                        PanelPresenter.openFile(configure: { $0.allowedContentTypes = [.image] }) { url in
                            guard let url else { return }
                            do { try HomebrewMeta.setIcon(from: url, project: project); iconVersion += 1 } catch { self.error = error.localizedDescription }
                        }
                    }
                    Text("Scaled to 128 × 48").font(.caption).foregroundStyle(.secondary)
                }
                Form {
                    TextField("Name", text: $meta.name)
                    TextField("Author", text: $meta.coder)
                    TextField("Version", text: $meta.version)
                    TextField("Short description", text: $meta.shortDescription)
                    TextField("Long description", text: $meta.longDescription, axis: .vertical).lineLimit(3...6)
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            Text("Saved in meta.json and icon.png. Each build writes out/apps/\(HomebrewPackage.appFolder(project: project))/ for the Homebrew Channel.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do { try meta.save(project: project); dismiss() } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 520)
    }
}
