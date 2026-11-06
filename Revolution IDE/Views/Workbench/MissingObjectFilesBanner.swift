import SwiftUI

/// Shown over a track editor when its objects need files the project doesn't have: imports them
/// from the linked base-game disc (Settings > Games) automatically, item boxes included, every
/// object a track uses must ship its files. Warns when no disc is linked to import from.
struct MissingObjectFilesBanner: View {
    /// The objects the track uses.
    let objectIDs: Set<UInt16>
    /// Lowercased file base names and folder names already in the project (see `BaseGameLibrary.names`).
    let present: () -> Set<String>
    /// Writes the files (paths relative to the course root) into the project.
    let install: ([(path: [String], data: Data)]) -> Void

    @State private var missing: [String] = []
    /// Needed but not on the retail disc at all, nothing to import.
    @State private var unavailable: [String] = []
    @State private var isWorking = false
    @State private var message: String?
    @State private var refresh = 0
    @State private var noDisc = false
    /// Resources already auto-imported once, so a target that can't take files (a disc entry)
    /// doesn't import forever.
    @State private var attempted: Set<String> = []

    var body: some View {
        Group {
            if noDisc {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("This track's objects need their files from the base game. Link your Mario Kart Wii disc in Settings > Games so they can be imported.")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .background(.bar, in: RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: 520)
            } else if !missing.isEmpty || message != nil || !unavailable.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: missing.isEmpty ? "checkmark.circle.fill" : "shippingbox.fill")
                        .foregroundStyle(missing.isEmpty ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        if let message { Text(message).font(.caption) }
                        else if !missing.isEmpty { Text("Objects need files this project doesn't have: \(missing.joined(separator: ", ")).").font(.caption) }
                        if !unavailable.isEmpty {
                            Text("No files on the retail disc for: \(unavailable.joined(separator: ", ")). Those objects are unused in the retail game or built by the game itself, so there's nothing to import, they may not appear in-game.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    if !missing.isEmpty {
                        if isWorking { ProgressView().controlSize(.small) }
                        Button("Import from Base Game") { importMissing() }
                            .disabled(isWorking)
                            .help("Copies the models/effects these objects use out of your linked Mario Kart Wii disc into this track.")
                    } else {
                        Button { message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                    }
                }
                .padding(8)
                .background(.bar, in: RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: 520)
            }
        }
        .task(id: "\(objectIDs.sorted())-\(refresh)") { await check() }
    }

    private func keys() -> ([UInt8]?, [UInt8]?) {
        if let iso = BaseGameLibrary.linkedISO { KeyManager.shared.autoLoad(nextTo: iso) }
        return (KeyManager.shared.commonKey, KeyManager.shared.koreanKey)
    }

    private func check() async {
        noDisc = BaseGameLibrary.linkedISO == nil && !objectIDs.isEmpty
        guard !noDisc, !objectIDs.isEmpty else { missing = []; unavailable = []; return }
        let (common, korean) = keys()
        let ids = objectIDs, have = present()
        let result = await Task.detached { () -> Result<(importable: [String], unavailable: [String]), Error> in
            Result {
                let index = try BaseGameLibrary.shared.index(commonKey: common, koreanKey: korean)
                return BaseGameLibrary.shared.missingResources(for: ids, present: have, in: index)
            }
        }.value
        switch result {
        case .success(let r):
            missing = r.importable; unavailable = r.unavailable
            if !isWorking, !missing.isEmpty, !Set(missing).isSubset(of: attempted) {
                attempted.formUnion(missing)
                importMissing()
            }
        case .failure(let error): missing = []; unavailable = []; message = error.localizedDescription
        }
    }

    private func importMissing() {
        isWorking = true
        let (common, korean) = keys()
        let wanted = missing
        Task {
            let result: Result<(files: [(path: [String], data: Data)], notFound: [String]), Error> = await Task.detached {
                Result {
                    let index = try BaseGameLibrary.shared.index(commonKey: common, koreanKey: korean)
                    return BaseGameLibrary.shared.files(for: wanted, in: index)
                }
            }.value
            isWorking = false
            switch result {
            case .success(let found):
                if !found.files.isEmpty { install(found.files) }
                message = "Imported \(wanted.joined(separator: ", ")) from the base game (\(found.files.count) file\(found.files.count == 1 ? "" : "s"))."
                missing = []
                refresh += 1
            case .failure(let error):
                message = error.localizedDescription
            }
        }
    }
}

/// The Double Dash counterpart: a course's objects need their models in its `objects/` folder,
/// imported from the linked Double Dash disc (see `MKDDObjectFiles`).
struct MissingDoubleDashObjectFilesBanner: View {
    let objectIDs: Set<UInt16>
    /// Lowercased file names already in the course's `objects/` folder.
    let present: () -> Set<String>
    let install: ([(path: [String], data: Data)]) -> Void

    @State private var missing: [(path: [String], data: Data)] = []
    @State private var noDisc = false
    @State private var message: String?
    @State private var refresh = 0

    var body: some View {
        Group {
            if noDisc {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("This track's objects need their models from the base game. Link your Double Dash disc in Settings > Games so they can be imported.")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .background(.bar, in: RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: 520)
            } else if !missing.isEmpty || message != nil {
                HStack(spacing: 8) {
                    Image(systemName: missing.isEmpty ? "checkmark.circle.fill" : "shippingbox.fill")
                        .foregroundStyle(missing.isEmpty ? .green : .orange)
                    Text(message ?? "Objects need files this course doesn't have: \(missing.map { $0.path.last! }.joined(separator: ", ")).")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    if !missing.isEmpty {
                        Button("Import from Base Game") {
                            install(missing)
                            message = "Imported \(missing.count) object file\(missing.count == 1 ? "" : "s") from the base game."
                            missing = []
                            refresh += 1
                        }
                        .help("Copies these objects' models and animations out of your linked Double Dash disc into this track's objects folder.")
                    } else {
                        Button { message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                    }
                }
                .padding(8)
                .background(.bar, in: RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: 520)
            }
        }
        .task(id: "\(objectIDs.sorted())-\(refresh)") {
            noDisc = DoubleDashDisc.linkedISO == nil && !objectIDs.isEmpty
            guard !noDisc, !objectIDs.isEmpty else { missing = []; return }
            let ids = objectIDs, have = present()
            let found = await Task.detached { (try? DoubleDashDisc.objectFiles()).map { MKDDObjectFiles.missing(for: ids, present: have, index: $0) } ?? [] }.value
            missing = found
        }
    }
}
