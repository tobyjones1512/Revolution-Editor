import SwiftUI
import AppKit
import Combine

/// Where New > Skybox > From Game should save (nil: the save panel's own default).
struct SkyboxPickerRequest: Identifiable {
    let id = UUID()
    let directory: URL?
}

/// New > Skybox: Custom always; From Game only once a Mario Kart Wii disc is linked.
struct NewSkyboxMenu: View {
    let workbench: WorkbenchState
    var directory: URL? = nil
    @AppStorage(BaseGameLibrary.bookmarkKey) private var bookmark: Data?

    var body: some View {
        Menu("Skybox") {
            Button("Custom...") { workbench.newCustomSkybox(in: directory) }
                .help("A vrcorn_model.brres from a panorama image (2:1, wrapped all the way round) or your own .obj.")
            if bookmark != nil {
                Button("From Game...") { workbench.skyboxPicker = SkyboxPickerRequest(directory: directory) }
                    .help("Copies the skybox of any Mario Kart Wii track or battle arena from your linked disc.")
            }
        }
    }
}

struct GameSkybox: Identifiable {
    let id: String
    let name: String
    let data: Data
    let thumbnail: NSImage?
}

/// Every retail track's and battle arena's `vrcorn_model.brres`, pulled off the linked Mario Kart
/// Wii disc in the background as soon as it's linked (and on launch), and kept on disk so the
/// picker opens instantly, the disc is only read again when a different one is linked.
@MainActor final class SkyboxLibrary: ObservableObject {
    static let shared = SkyboxLibrary()
    @Published private(set) var skies: [GameSkybox] = []
    @Published private(set) var progress: String?
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?

    private nonisolated static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Revolution IDE/Base Game Skyboxes", isDirectory: true)
    /// Holds the disc path the files came from; written last, so a half-finished extraction redoes.
    private nonisolated static var sourceURL: URL { folder.appendingPathComponent("source.txt") }

    /// Brings `skies` in line with the linked disc. Call after linking/unlinking and at launch.
    func refresh() {
        task?.cancel()
        skies = []; error = nil; progress = nil
        guard let iso = BaseGameLibrary.linkedISO else {
            try? FileManager.default.removeItem(at: Self.folder)
            return
        }
        KeyManager.shared.autoLoad(nextTo: iso)
        let (common, korean) = (KeyManager.shared.commonKey, KeyManager.shared.koreanKey)
        progress = "Finding skyboxes on the disc..."
        task = Task {
            let result = await Task.detached(priority: .utility) { () -> Result<[GameSkybox], Error> in
                Result { try Self.load(iso: iso, common: common, korean: korean) }
            }.value
            guard !Task.isCancelled else { return }
            progress = nil
            switch result {
            case .success(let list): skies = list; if list.isEmpty { error = "No skyboxes found on the linked disc." }
            case .failure(let e): error = e.localizedDescription
            }
        }
    }

    private nonisolated static func load(iso: URL, common: [UInt8]?, korean: [UInt8]?) throws -> [GameSkybox] {
        let fm = FileManager.default
        if (try? String(contentsOf: sourceURL, encoding: .utf8)) != iso.path {
            try? fm.removeItem(at: folder)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let index = try BaseGameLibrary.shared.index(commonKey: common, koreanKey: korean)
            var byName: [String: DiscNode] = [:]
            func walk(_ n: DiscNode) { if n.isDirectory { n.children.forEach(walk) } else { byName[n.name] = n } }
            walk(index.disc.root)
            func find(_ n: U8Node) -> U8Node? {
                if n.name.lowercased() == "vrcorn_model.brres" { return n }
                for c in n.children { if let f = find(c) { return f } }
                return nil
            }
            for course in TextureGalleryView.courses {
                guard let node = byName[course.file + ".szs"], let disc = try? index.disc.readFile(node: node),
                      let (root, _) = try? SZS.open(disc), let data = find(root)?.data else { continue }
                try data.write(to: folder.appendingPathComponent(course.file + ".brres"))
            }
            try iso.path.write(to: sourceURL, atomically: true, encoding: .utf8)
        }
        return TextureGalleryView.courses.compactMap { course in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(course.file + ".brres")) else { return nil }
            // The biggest texture is the sky itself (others are clouds, stars, planets).
            let tex = (try? BRRESDocument.parse(data))?.resources.compactMap { $0.magic == "TEX0" ? TEX0View($0) : nil }
                .max { $0.width * $0.height < $1.width * $1.height }
            let thumb = tex.flatMap { v in v.decodeRGBA(palette: nil).flatMap { TextureGalleryView.thumbnail($0, v.width, v.height) } }
            return GameSkybox(id: course.file, name: course.name, data: data, thumbnail: thumb)
        }
    }
}

/// Picks one of `SkyboxLibrary`'s retail skyboxes.
struct SkyboxFromGameSheet: View {
    let request: SkyboxPickerRequest
    @EnvironmentObject var workbench: WorkbenchState
    @ObservedObject private var library = SkyboxLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?

    var body: some View {
        VStack(spacing: 0) {
            Text("Skybox From Game").font(.headline).padding(10)
            Divider()
            if let error = library.error {
                Text(error).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            } else if library.skies.isEmpty {
                ProgressView(library.progress ?? "Finding skyboxes...").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        ForEach(library.skies) { cell($0) }
                    }
                    .padding(12)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save .brres...") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
            .padding(10)
        }
        .frame(width: 720, height: 520)
        .onAppear { if library.skies.isEmpty, library.progress == nil { library.refresh() } }
    }

    private func cell(_ s: GameSkybox) -> some View {
        VStack(spacing: 4) {
            Group {
                if let t = s.thumbnail { Image(nsImage: t).resizable().aspectRatio(contentMode: .fill) }
                else { Image(systemName: "cloud.sun").font(.largeTitle).foregroundStyle(.tertiary) }
            }
            .frame(width: 140, height: 80).clipped()
            .background(CheckerboardBackground())
            Text(s.name).font(.caption).lineLimit(1)
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 6).fill(selection == s.id ? Color.accentColor.opacity(0.25) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selection == s.id ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { selection = s.id; save() }
        .onTapGesture { selection = s.id }
    }

    private func save() {
        guard let sky = library.skies.first(where: { $0.id == selection }) else { return }
        dismiss()
        workbench.saveSkybox(sky.data, in: request.directory)
    }
}
