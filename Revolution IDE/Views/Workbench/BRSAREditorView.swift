import SwiftUI

/// Browser for a `.brsar` sound archive, see `BRSARDocument`'s doc comment for why this is a
/// structural browse (sounds/banks/players/groups/files with their documented parameters) rather
/// than in-app playback.
struct BRSAREditorView: View {
    let doc: BRSARDocument

    private enum Tab: String, CaseIterable, Identifiable {
        case sounds = "Sounds", banks = "Banks", players = "Players", groups = "Groups", files = "Files"
        var id: String { rawValue }
    }
    @State private var tab: Tab = .sounds
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { t in Text("\(t.rawValue) (\(count(for: t)))").tag(t) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("A BRSAR is a sound archive bundling every sound effect and music sequence a game uses, organised into sounds, instrument banks, players, and groups. This is a read-only browser of that structure, not a sound player/editor.")
                TextField("Filter...", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }
            .padding()
            Divider()
            List {
                switch tab {
                case .sounds:
                    ForEach(Array(filteredSounds.enumerated()), id: \.offset) { _, s in
                        HStack {
                            Image(systemName: "speaker.wave.2")
                            VStack(alignment: .leading) {
                                Text(s.name.isEmpty ? "(unnamed)" : s.name)
                                Text("\(s.type?.displayName ?? "Unknown type") \u{2022} vol \(s.volume) \u{2022} player \(s.playerID) \u{2022} file #\(s.fileIndex)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                case .banks:
                    ForEach(Array(filteredBanks.enumerated()), id: \.offset) { _, b in
                        HStack {
                            Image(systemName: "pianokeys")
                            Text(b.name.isEmpty ? "(unnamed)" : b.name)
                            Spacer()
                            Text("file #\(b.fileIndex)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                case .players:
                    ForEach(Array(filteredPlayers.enumerated()), id: \.offset) { _, p in
                        HStack {
                            Image(systemName: "person.wave.2")
                            Text(p.name.isEmpty ? "(unnamed)" : p.name)
                            Spacer()
                            Text("\(p.playableSoundCount) sounds").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                case .groups:
                    ForEach(Array(filteredGroups.enumerated()), id: \.offset) { _, g in
                        HStack {
                            Image(systemName: "square.stack.3d.up")
                            Text(g.name.isEmpty ? "(unnamed)" : g.name)
                            Spacer()
                            Text("\(g.itemCount) items").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                case .files:
                    ForEach(Array(filteredFiles.enumerated()), id: \.offset) { _, f in
                        HStack {
                            Image(systemName: f.externalName != nil ? "waveform" : "doc.zipper")
                            Text(f.externalName ?? "(embedded #\(f.index))")
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(f.dataLength), countStyle: .file))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func count(for t: Tab) -> Int {
        switch t {
        case .sounds: return doc.sounds.count
        case .banks: return doc.banks.count
        case .players: return doc.players.count
        case .groups: return doc.groups.count
        case .files: return doc.files.count
        }
    }

    private var filteredSounds: [BRSARSound] {
        filter.isEmpty ? doc.sounds : doc.sounds.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }
    private var filteredBanks: [BRSARBank] {
        filter.isEmpty ? doc.banks : doc.banks.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }
    private var filteredPlayers: [BRSARPlayer] {
        filter.isEmpty ? doc.players : doc.players.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }
    private var filteredGroups: [BRSARGroup] {
        filter.isEmpty ? doc.groups : doc.groups.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }
    private var filteredFiles: [BRSARFile] {
        filter.isEmpty ? doc.files : doc.files.filter { ($0.externalName ?? "").localizedCaseInsensitiveContains(filter) }
    }
}
