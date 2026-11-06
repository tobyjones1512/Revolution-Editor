import SwiftUI

enum Platform: String {
    case wii = "Wii"
    case gamecube = "GameCube"

    var label: String {
        switch self {
        case .wii: return "Wii"
        case .gamecube: return "GCN"
        }
    }
}

struct ArchiveType: Identifiable {
    let id = UUID()
    let title: String
    let description: String
    let files: [(name: String, desc: String)]
}

struct GameCategory: Identifiable {
    let id = UUID()
    let name: String
    let platform: Platform
    let archives: [ArchiveType]
}

/// The generic shell behind every format's "Info" popover (`SZSInfoPopoverView`, `KMPFormatInfo`,
/// `KCLFormatInfo`): a searchable, per-game list of archive/file types. Only `games` differs
/// between formats, this view just renders whatever it's handed.
struct FormatInfoPopoverView: View {
    let title: String
    let games: [GameCategory]

    @State private var searchText = ""
    @State private var selectedGameId: UUID
    @AppStorage("showPlatformTags") private var showPlatformTags = true

    init(title: String, games: [GameCategory]) {
        self.title = title
        self.games = games
        _selectedGameId = State(initialValue: games[0].id)
    }

    var selectedGame: GameCategory {
        games.first(where: { $0.id == selectedGameId }) ?? games[0]
    }

    var filteredArchives: [ArchiveType] {
        let archives = selectedGame.archives
        if searchText.isEmpty { return archives }
        return archives.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.description.localizedCaseInsensitiveContains(searchText) ||
            $0.files.contains { file in file.name.localizedCaseInsensitiveContains(searchText) || file.desc.localizedCaseInsensitiveContains(searchText) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "info.circle")
                Text(title)
                    .font(.headline)
                Spacer()
                Picker("Game", selection: $selectedGameId) {
                    ForEach(games) { game in
                        if showPlatformTags {
                            (Text("[\(game.platform.label)]").monospaced() + Text(" \(game.name)")).tag(game.id)
                        } else {
                            Text(game.name).tag(game.id)
                        }
                    }
                }
                .labelsHidden()
                .frame(width: 250)
            }
            .padding()

            TextField("Search (e.g. course, brres, UI)...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.bottom, 8)

            List(filteredArchives) { archive in
                VStack(alignment: .leading, spacing: 4) {
                    Text(archive.title).font(.subheadline).bold()
                    Text(archive.description).font(.caption).foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(archive.files, id: \.name) { file in
                            HStack(alignment: .top) {
                                Text(file.name).font(.system(.caption, design: .monospaced)).bold()
                                    .frame(width: 140, alignment: .leading)
                                Text(file.desc).font(.caption)
                            }
                        }
                    }
                    .padding(.top, 4)
                    .padding(.leading, 8)
                }
                .padding(.vertical, 4)
            }
            .listStyle(.plain)
        }
        .frame(width: 500, height: 420)
    }
}

/// KCL's container format (vertex list, triangle-index list with an attribute word, and an octree
/// for fast spatial lookup) is shared broadly across EAD-era Nintendo titles, but each game defines
/// its own meaning for the attribute word's bits, a KCL parsed correctly for one game's flag
/// layout will show meaningless surface-type data for another's.
enum KCLFormatInfo {
    static let games: [GameCategory] = [
        GameCategory(
            name: "Mario Kart Wii",
            platform: .wii,
            archives: [
                ArchiveType(
                    title: "Course Collision (course.kcl)",
                    description: "The invisible mesh a racer's kart actually touches, usually a simplified version of the visible course.brres model, not the exact same geometry. Drives physics (grip, speed, whether something is out-of-bounds).",
                    files: [
                        ("Vertices", "Raw XYZ positions referenced by every collision triangle."),
                        ("Triangle prisms", "Each triangle's vertex indices plus a 16-bit attribute (\"flag\") word."),
                        ("Attribute flags", "MKWii-specific bit layout: base surface type (road, off-road, wall, boost panel, ...) plus modifier bits (trickable, sound-effect group, wall type)."),
                        ("Octree", "A spatial index over the triangles so collision lookups don't have to test the whole mesh.")
                    ]
                )
            ]
        ),
        GameCategory(
            name: "Pikmin 1 & 2",
            platform: .gamecube,
            archives: [
                ArchiveType(
                    title: "Map/Cave Collision",
                    description: "Same KCL container (vertices, triangle prisms, octree) as Mario Kart Wii, but Pikmin defines its own attribute-flag layout, surface types here mean things like water, hazard terrain, or a Pikmin-carry path, not MKWii's road/off-road/boost set.",
                    files: [
                        ("Vertices / Triangle prisms / Octree", "Structurally identical to MKWii's KCL, the same reader parses the shape correctly."),
                        ("Attribute flags", "Pikmin-specific meaning, do not assume MKWii's flag names apply here.")
                    ]
                )
            ]
        ),
        GameCategory(
            name: "Battalion Wars",
            platform: .gamecube,
            archives: [
                ArchiveType(
                    title: "Terrain/Vehicle Collision",
                    description: "Uses the same underlying KCL container for battlefield terrain and large vehicle collision, again with its own attribute-flag layout distinct from MKWii's.",
                    files: [
                        ("Vertices / Triangle prisms / Octree", "Same shape as MKWii's KCL."),
                        ("Attribute flags", "Battalion Wars-specific meaning (terrain type, vehicle-only surfaces, etc).")
                    ]
                )
            ]
        )
    ]
}

/// KMP (course map data: checkpoints, routes, objects, respawns, cameras) is basically
/// Mario Kart Wii-specific among the games this IDE targets. Mario Kart: Double Dash!!'s closest
/// equivalent, .bol, is a structurally unrelated format, not an earlier KMP revision.
enum KMPFormatInfo {
    static let games: [GameCategory] = [
        GameCategory(
            name: "Mario Kart Wii",
            platform: .wii,
            archives: [
                ArchiveType(
                    title: "Course Map Data (course.kmp)",
                    description: "The non-visual data that turns a 3D model into a working race track: start positions, AI/route paths, checkpoints, item spawns, objects, and cameras. KMP is specific to Mario Kart Wii among the games this IDE targets. Mario Kart: Double Dash!!'s conceptually similar file, .bol, is a different format entirely and isn't read as KMP.",
                    files: [
                        ("KTPT", "Kart start points, where racers line up at the starting line."),
                        ("ENPT / ENPH", "Enemy (CPU) route points and the paths grouping them."),
                        ("ITPT / ITPH", "Item route points and paths, where item-ballon/shells target racers from."),
                        ("CKPT / CKPH", "Checkpoints and checkpoint paths, lap/progress tracking and CPU shortcuts."),
                        ("GOBJ", "Placed objects (item boxes, obstacles, decorations, trigger volumes)."),
                        ("JGPT", "Respawn points used after falling off the track."),
                        ("CNPT", "Cannon points for launch pads."),
                        ("MSPT", "Battle-mode respawn points."),
                        ("AREA", "Trigger regions (camera changes, weather, effects)."),
                        ("CAME", "Camera definitions, including the intro/replay cameras.")
                    ]
                )
            ]
        )
    ]
}
