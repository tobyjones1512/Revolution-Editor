import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// File > Texture Gallery: every texture in every course on a linked base disc (Settings > Games)
///. Mario Kart Wii's tracks and arenas, or Double Dash's courses, racers and karts, browsable by
/// course, name or size, and exportable as PNG; select several with Command/Shift-click.
struct TextureGalleryMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    @AppStorage(BaseGameLibrary.bookmarkKey) private var bookmark: Data?
    @AppStorage(DoubleDashDisc.bookmarkKey) private var doubleDashBookmark: Data?
    var body: some View {
        Button("Texture Gallery") { openWindow(id: "textureGallery") }
            .disabled(bookmark == nil && doubleDashBookmark == nil)
            .help("Browse and export the textures of every course on your Mario Kart Wii or Double Dash disc, link one in Settings > Games first.")
    }
}

struct GalleryTexture: Identifiable {
    let id: String
    let track: String
    let trackOrder: Int
    let file: String
    let name: String
    let width: Int, height: Int
    let format: String
    /// Full-size RGBA8 pixels, decoded when exported.
    let decode: @Sendable () -> [UInt8]?
    let thumbnail: NSImage
    let hash: Int
}

struct TextureGalleryView: View {
    enum Sort: String, CaseIterable, Identifiable { case track = "Track", name = "Name", size = "Size"; var id: String { rawValue } }

    @State private var textures: [GalleryTexture] = []
    @State private var loading = false
    @State private var progress = ""
    @State private var error: String?
    @State private var selection = Set<String>()
    @State private var lastClicked: String?
    @State private var search = ""
    @State private var sort: Sort = .track
    @State private var hideDuplicates = true
    @State private var status = ""
    @State private var game: HotSwapTargets.Game = BaseGameLibrary.linkedISO == nil && DoubleDashDisc.linkedISO != nil ? .marioKartDoubleDash : .marioKartWii

    private var shown: [GalleryTexture] {
        var seen = Set<Int>()
        var list = textures.filter { t in
            guard search.isEmpty || t.name.localizedCaseInsensitiveContains(search) || t.track.localizedCaseInsensitiveContains(search) else { return false }
            return !hideDuplicates || seen.insert(t.hash).inserted
        }
        switch sort {
        case .track: break
        case .name: list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size: list.sort { $0.width * $0.height > $1.width * $1.height }
        }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if BaseGameLibrary.linkedISO != nil && DoubleDashDisc.linkedISO != nil {
                    Picker("", selection: $game) {
                        Text("Mario Kart Wii").tag(HotSwapTargets.Game.marioKartWii)
                        Text("Double Dash").tag(HotSwapTargets.Game.marioKartDoubleDash)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                TextField("Search textures or courses", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Picker("Sort", selection: $sort) { ForEach(Sort.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 220)
                Toggle("Hide duplicates", isOn: $hideDuplicates)
                    .help("Many textures (item boxes, shared objects) appear in several tracks; show each only once, under the first track that uses it.")
                Spacer()
                Text(selection.isEmpty ? "\(shown.count) textures" : "\(selection.count) selected").foregroundStyle(.secondary).font(.caption)
                Button("Select All") { selection = Set(shown.map(\.id)) }.disabled(shown.isEmpty)
                Button("Export \(selection.count > 1 ? "\(selection.count) " : "")as PNG...") { export() }
                    .disabled(selection.isEmpty)
                    .shortcut(.exportImage)
            }
            .padding(10)
            Divider()
            if loading {
                ProgressView(progress).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                Text(error).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            } else {
                grid
            }
            if !status.isEmpty {
                Divider()
                Text(status).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
        }
        .navigationTitle("Texture Gallery")
        .task(id: game) { textures = []; selection = []; error = nil; await load() }
    }

    private var grid: some View {
        let list = shown
        let sections: [(String, [GalleryTexture])] = sort == .track
            ? Dictionary(grouping: list, by: \.track).sorted { ($0.value.first?.trackOrder ?? 0) < ($1.value.first?.trackOrder ?? 0) }.map { ($0.key, $0.value) }
            : [("", list)]
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], alignment: .leading, spacing: 12, pinnedViews: [.sectionHeaders]) {
                ForEach(sections, id: \.0) { title, items in
                    Section {
                        ForEach(items) { t in cell(t, in: list) }
                    } header: {
                        if !title.isEmpty {
                            Text(title).font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4).background(.bar)
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    private func cell(_ t: GalleryTexture, in list: [GalleryTexture]) -> some View {
        let selected = selection.contains(t.id)
        return VStack(spacing: 4) {
            Image(nsImage: t.thumbnail).resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                .frame(width: 110, height: 110)
                .background(CheckerboardBackground())
            Text(t.name).font(.caption).lineLimit(1).truncationMode(.middle)
            Text("\(t.width)x\(t.height) \(t.format)").font(.caption2).foregroundStyle(.secondary)
            if sort != .track { Text(t.track).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.25) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture { click(t, in: list) }
        .help("\(t.track). \(t.file)")
        .contextMenu { Button("Export as PNG...") { selection = [t.id]; export() } }
    }

    /// Click selects one; Command-click toggles; Shift-click extends from the last click.
    private func click(_ t: GalleryTexture, in list: [GalleryTexture]) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift), let last = lastClicked, let a = list.firstIndex(where: { $0.id == last }), let b = list.firstIndex(where: { $0.id == t.id }) {
            selection.formUnion(list[min(a, b)...max(a, b)].map(\.id))
        } else if flags.contains(.command) {
            if selection.contains(t.id) { selection.remove(t.id) } else { selection.insert(t.id) }
        } else {
            selection = [t.id]
        }
        lastClicked = t.id
    }

    private func export() {
        let chosen = textures.filter { selection.contains($0.id) }
        guard !chosen.isEmpty else { return }
        PanelPresenter.openFile(configure: {
            $0.canChooseDirectories = true; $0.canChooseFiles = false; $0.canCreateDirectories = true
            $0.prompt = "Export Here"; $0.message = "Choose a folder for \(chosen.count) PNG file\(chosen.count == 1 ? "" : "s")."
        }) { folder in
            guard let folder else { return }
            var written = 0, used = Set<String>()
            for t in chosen {
                guard let rgba = t.decode(),
                      let image = ImageUtil.nsImage(fromRGBA: rgba, width: t.width, height: t.height),
                      let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { continue }
                var base = chosen.count == 1 ? t.name : "\(t.track) - \(t.name)"
                base = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                var name = base, n = 2
                while used.contains(name) || FileManager.default.fileExists(atPath: folder.appendingPathComponent(name + ".png").path) { name = "\(base) \(n)"; n += 1 }
                used.insert(name)
                if (try? png.write(to: folder.appendingPathComponent(name + ".png"))) != nil { written += 1 }
            }
            status = "Exported \(written) PNG file\(written == 1 ? "" : "s") to \(folder.lastPathComponent)."
        }
    }

    // MARK: Loading

    private func load() async {
        if game == .marioKartDoubleDash { await loadDoubleDash(); return }
        guard let iso = BaseGameLibrary.linkedISO else { error = "Link your Mario Kart Wii or Double Dash disc in Settings > Games to browse its textures."; return }
        KeyManager.shared.autoLoad(nextTo: iso)
        let (common, korean) = (KeyManager.shared.commonKey, KeyManager.shared.koreanKey)
        loading = true
        progress = "Reading the disc..."
        let result: Result<[GalleryTexture], Error> = await Task.detached(priority: .userInitiated) {
            do {
                let index = try BaseGameLibrary.shared.index(commonKey: common, koreanKey: korean)
                var byName: [String: DiscNode] = [:]
                func walk(_ n: DiscNode) { if n.isDirectory { n.children.forEach(walk) } else { byName[n.name] = n } }
                walk(index.disc.root)
                var out: [GalleryTexture] = []
                for (order, course) in Self.courses.enumerated() {
                    guard let node = byName[course.file + ".szs"], let data = try? index.disc.readFile(node: node),
                          let (root, _) = try? SZS.open(data) else { continue }
                    await MainActor.run { progress = "Reading \(course.name)..." }
                    func collect(_ n: U8Node, _ path: String) {
                        for c in n.children {
                            let p = path.isEmpty || path == "." ? c.name : path + "/" + c.name
                            if c.isDirectory { collect(c, p); continue }
                            guard c.name.lowercased().hasSuffix(".brres"), let d = c.data, let doc = try? BRRESDocument.parse(d) else { continue }
                            for r in doc.resources where r.magic == "TEX0" {
                                guard let v = TEX0View(r), let rgba = v.decodeRGBA(palette: nil),
                                      let thumb = Self.thumbnail(rgba, v.width, v.height) else { continue }
                                out.append(GalleryTexture(id: "\(course.file)/\(p)/\(r.name)", track: course.name, trackOrder: order, file: p,
                                                          name: r.name, width: v.width, height: v.height, format: "\(v.format)".uppercased(),
                                                          decode: { TEX0View(r)?.decodeRGBA(palette: nil) }, thumbnail: thumb, hash: rgba.hashValue))
                            }
                        }
                    }
                    collect(root, "")
                }
                return .success(out)
            } catch { return .failure(error) }
        }.value
        loading = false
        switch result {
        case .success(let list): textures = list
        case .failure(let e): error = e.localizedDescription
        }
    }

    /// Double Dash: each course's model, sky and minimap textures (courses in cup order, then
    /// arenas), then every racer's and kart's from MRAM.arc.
    private func loadDoubleDash() async {
        guard let iso = DoubleDashDisc.linkedISO else { error = "Link your Double Dash disc in Settings > Games to browse its textures."; return }
        loading = true
        progress = "Reading the disc..."
        let result: Result<[GalleryTexture], Error> = await Task.detached(priority: .userInitiated) {
            do {
                let disc = try GameCubeDisc(url: iso)
                var byName: [String: DiscNode] = [:]
                func walk(_ n: DiscNode) { if n.isDirectory { n.children.forEach(walk) } else { byName[n.name] = n } }
                walk(disc.root)
                var out: [GalleryTexture] = []
                /// Every texture in a J3D model or standalone .bti in `root`, under `group`.
                func collect(_ root: U8Node, group: String, order: Int, prefix: String) {
                    func visit(_ n: U8Node, _ path: String) {
                        for c in n.children {
                            let p = path.isEmpty ? c.name : path + "/" + c.name
                            if c.isDirectory { visit(c, p); continue }
                            guard let d = c.data else { continue }
                            let lower = c.name.lowercased()
                            if lower.hasSuffix(".bmd") || lower.hasSuffix(".bdl"), let model = try? J3DModel.parse(d) {
                                for t in model.textures {
                                    guard let rgba = t.decoded(), let thumb = Self.thumbnail(rgba, t.width, t.height) else { continue }
                                    out.append(GalleryTexture(id: "\(prefix)/\(p)/\(t.name)", track: group, trackOrder: order, file: p, name: t.name,
                                                              width: t.width, height: t.height, format: "\(t.format)".uppercased(),
                                                              decode: { t.decoded() }, thumbnail: thumb, hash: rgba.hashValue))
                                }
                            } else if lower.hasSuffix(".bti"), d.count >= 0x20, let fmt = GXTextureFormat(rawValue: UInt32(d.u8(0))) {
                                let w = Int(d.be16(2)), h = Int(d.be16(4)), at = Int(d.be32(0x1C))
                                guard let rgba = TextureCodec.decode(data: d, offset: at, width: w, height: h, format: fmt), let thumb = Self.thumbnail(rgba, w, h) else { continue }
                                out.append(GalleryTexture(id: "\(prefix)/\(p)", track: group, trackOrder: order, file: p, name: (c.name as NSString).deletingPathExtension,
                                                          width: w, height: h, format: "\(fmt)".uppercased(),
                                                          decode: { TextureCodec.decode(data: d, offset: at, width: w, height: h, format: fmt) }, thumbnail: thumb, hash: rgba.hashValue))
                            }
                        }
                    }
                    visit(root, "")
                }
                let courses = Self.doubleDashCourses
                for (order, slot) in courses.enumerated() {
                    guard let node = byName[slot.archive + ".arc"], let (root, _) = try? SZS.open(try disc.readFile(node: node)) else { continue }
                    await MainActor.run { progress = "Reading \(slot.title)..." }
                    collect(root, group: slot.title, order: order, prefix: slot.archive)
                }
                if let mram = byName["MRAM.arc"], let (root, _) = try? SZS.open(try disc.readFile(node: mram)) {
                    await MainActor.run { progress = "Reading racers and karts..." }
                    for (i, folder) in ["driver", "kart"].enumerated() {
                        guard let dir = root.children.first(where: { $0.name == folder }) else { continue }
                        collect(dir, group: folder == "driver" ? "Racers" : "Karts", order: courses.count + i, prefix: folder)
                    }
                }
                return .success(out)
            } catch { return .failure(error) }
        }.value
        loading = false
        switch result {
        case .success(let list): textures = list
        case .failure(let e): error = "Couldn't read the Double Dash disc: \(e.localizedDescription)"
        }
    }

    /// Double Dash courses in cup order, then battle arenas.
    nonisolated static var doubleDashCourses: [MKDDSlots.Slot] {
        let order = ["Luigi2", "Peach", "BabyLuigi", "Desert", "Nokonoko", "Mario", "Daisy", "Waluigi", "Snow", "Patapata", "Yoshi", "Donkey", "Wario", "Diddy", "Koopa", "Rainbow"]
        return order.compactMap { a in MKDDSlots.slots.first { $0.archive == a } } + MKDDSlots.slots.filter(\.battle)
    }

    /// At most 128 pixels on a side (textures stay encoded; exports decode at full size).
    nonisolated static func thumbnail(_ rgba: [UInt8], _ w: Int, _ h: Int) -> NSImage? {
        let scale = max(1, max(w, h) / 128)
        let tw = max(1, w / scale), th = max(1, h / scale)
        var small = [UInt8](repeating: 0, count: tw * th * 4)
        for y in 0..<th { for x in 0..<tw {
            let s = ((y * scale) * w + x * scale) * 4, d = (y * tw + x) * 4
            small[d] = rgba[s]; small[d + 1] = rgba[s + 1]; small[d + 2] = rgba[s + 2]; small[d + 3] = rgba[s + 3]
        } }
        return ImageUtil.nsImage(fromRGBA: small, width: tw, height: th)
    }

    /// Every race track (in cup order) and battle arena.
    nonisolated static let courses: [(file: String, name: String)] = [
        ("beginner_course", "Luigi Circuit"), ("farm_course", "Moo Moo Meadows"), ("kinoko_course", "Mushroom Gorge"),
        ("factory_course", "Toad's Factory"), ("castle_course", "Mario Circuit"), ("shopping_course", "Coconut Mall"),
        ("boardcross_course", "DK Summit"), ("truck_course", "Wario's Gold Mine"), ("senior_course", "Daisy Circuit"),
        ("water_course", "Koopa Cape"), ("treehouse_course", "Maple Treeway"), ("volcano_course", "Grumble Volcano"),
        ("desert_course", "Dry Dry Ruins"), ("ridgehighway_course", "Moonview Highway"), ("koopa_course", "Bowser's Castle"),
        ("rainbow_course", "Rainbow Road"), ("old_peach_gc", "GCN Peach Beach"), ("old_falls_ds", "DS Yoshi Falls"),
        ("old_obake_sfc", "SNES Ghost Valley 2"), ("old_mario_64", "N64 Mario Raceway"), ("old_sherbet_64", "N64 Sherbet Land"),
        ("old_heyho_gba", "GBA Shy Guy Beach"), ("old_town_ds", "DS Delfino Square"), ("old_waluigi_gc", "GCN Waluigi Stadium"),
        ("old_desert_ds", "DS Desert Hills"), ("old_koopa_gba", "GBA Bowser Castle 3"), ("old_donkey_64", "N64 DK's Jungle Parkway"),
        ("old_mario_gc", "GCN Mario Circuit"), ("old_mario_sfc", "SNES Mario Circuit 3"), ("old_garden_ds", "DS Peach Gardens"),
        ("old_donkey_gc", "GCN DK Mountain"), ("old_koopa_64", "N64 Bowser's Castle"),
        ("block_battle", "Block Plaza"), ("venice_battle", "Delfino Pier"), ("skate_battle", "Funky Stadium"),
        ("casino_battle", "Chain Chomp Wheel"), ("sand_battle", "Thwomp Desert"), ("old_battle4_sfc", "SNES Battle Course 4"),
        ("old_battle3_gba", "GBA Battle Course 3"), ("old_matenro_64", "N64 Skyscraper"), ("old_CookieLand_gc", "GCN Cookie Land"),
        ("old_House_ds", "DS Twilight House"),
    ]
}

/// Light grey checks behind a texture so transparency reads as transparency.
struct CheckerboardBackground: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 8
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) where (Int(x / s) + Int(y / s)) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(.gray.opacity(0.18)))
                }
            }
        }
    }
}
