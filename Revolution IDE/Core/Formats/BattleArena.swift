import Foundation

/// Mario Kart Wii battle arenas (Balloon Battle and Coin Runners).
///
/// What a battle `course.kmp` holds, measured from all 10 retail arenas: exactly 12 start points
/// (KTPT) numbered 0-11 by player, one per racer, unlike a race track's single grid point at
/// -1; exactly 4 battle respawn points (MSPT); 12 respawn points (JGPT; Delfino Pier 36); a CPU
/// network of enemy points (ENPT/ENPH, many small linked groups); no item paths and no
/// checkpoints; 72-134 coins (object 0x73) for Coin Runners plus item boxes (0x65, Thwomp
/// Desert's 0x76); and a coin.brres + itembox.brres in the archive for those objects.
nonisolated enum BattleArena {
    /// The battle slots, by the file name a custom arena replaces.
    static let slots: [(file: String, name: String)] = [
        ("block_battle.szs", "Block Plaza"), ("venice_battle.szs", "Delfino Pier"), ("skate_battle.szs", "Funky Stadium"),
        ("casino_battle.szs", "Chain Chomp Wheel"), ("sand_battle.szs", "Thwomp Desert"), ("old_battle4_sfc.szs", "SNES Battle Course 4"),
        ("old_battle3_gba.szs", "GBA Battle Course 3"), ("old_matenro_64.szs", "N64 Skyscraper"), ("old_CookieLand_gc.szs", "GCN Cookie Land"),
        ("old_House_ds.szs", "DS Twilight House"),
    ]

    static let playerCount = 12
    static let battleRespawnCount = 4
    static let coinID: UInt16 = 0x0073

    /// A battle arena rather than a race track: per-player start points, battle respawns, or no
    /// checkpoints with more than one start.
    static func isBattle(_ doc: KMPDocument) -> Bool {
        guard doc.ckpt.isEmpty else { return false }
        return !doc.mspt.isEmpty || doc.ktpt.contains { $0.playerIndex >= 0 }
    }

    /// A new, loadable battle KMP centred on the origin: everything `makeTestable` would add.
    static func template() -> KMPDocument {
        let doc = KMPDocument()
        _ = makeTestable(doc)
        return doc
    }

    /// Adds what a battle arena is missing to load and play, never touching what's already
    /// there: start points up to one per player 0-11, 4 battle respawns, respawn points, and a
    /// small CPU loop when there is none. New points are placed around the existing start (or
    /// the origin) and set on the ground via `ground` when given.
    static func makeTestable(_ doc: KMPDocument, ground: ((Float, Float) -> Float?)? = nil) -> [String] {
        var fixes: [String] = []
        let centre = doc.ktpt.first?.position ?? Vec3()
        func onGround(_ p: Vec3) -> Vec3 {
            guard let y = ground?(p.x, p.z) else { return p }
            return Vec3(x: p.x, y: y + 10, z: p.z)
        }
        /// `count` points on a circle round the centre, each facing it.
        func ring(_ count: Int, radius: Float) -> [(Vec3, Vec3)] {
            (0..<count).map { k in
                let a = Float(k) / Float(count) * 2 * .pi
                let p = onGround(Vec3(x: centre.x + radius * sin(a), y: centre.y, z: centre.z + radius * cos(a)))
                // Facing the centre: yaw is measured from +Z, as in the rest of the KMP editor.
                return (p, Vec3(x: 0, y: (a * 180 / .pi + 180).truncatingRemainder(dividingBy: 360), z: 0))
            }
        }

        // Start points: one per player, 0-11, each index once.
        var used = Set<Int16>()
        for i in doc.ktpt.indices {
            let p = doc.ktpt[i].playerIndex
            if p < 0 || p >= Int16(playerCount) || used.contains(p) {
                let free = (0..<Int16(playerCount)).first { !used.contains($0) && !doc.ktpt.map(\.playerIndex).contains($0) }
                if let free {
                    fixes.append("Start Point \(i) had player index \(p), battle arenas number one start per player 0-11; set it to \(free).")
                    doc.ktpt[i].playerIndex = free
                }
            }
            used.insert(doc.ktpt[i].playerIndex)
        }
        let missingPlayers = (0..<Int16(playerCount)).filter { !used.contains($0) }
        if !missingPlayers.isEmpty {
            let spots = ring(playerCount, radius: 2500)
            for player in missingPlayers {
                let (p, r) = spots[Int(player)]
                doc.ktpt.append(KTPTEntry(position: p, rotation: r, playerIndex: player))
            }
            fixes.append("Added \(missingPlayers.count) Start Point(s) for player(s) \(missingPlayers.map(String.init).joined(separator: ", ")) in a ring round the start, every retail arena has one per player, 0-11.")
        }

        if doc.mspt.count < battleRespawnCount {
            let have = doc.mspt.count
            for (p, r) in ring(battleRespawnCount, radius: 4000).dropFirst(have) {
                doc.mspt.append(MSPTEntry(position: p, rotation: r))
            }
            fixes.append("Added \(battleRespawnCount - have) Battle Respawn Point(s) (MSPT), every retail arena has exactly \(battleRespawnCount).")
        }

        if doc.jgpt.isEmpty {
            for (i, k) in doc.ktpt.enumerated() {
                doc.jgpt.append(JGPTEntry(position: k.position, rotation: k.rotation, respawnID: UInt16(i)))
            }
            fixes.append("Added \(doc.jgpt.count) Respawn Points (JGPT) at the start points, falling off would otherwise have nowhere to return to.")
        }

        if doc.enpt.isEmpty {
            for (p, _) in ring(8, radius: 3500) { doc.enpt.append(ENPTEntry(position: p, radius: 600)) }
            doc.enph = [PathLinkEntry(startIndex: 0, pointCount: 8, previousGroups: [0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF], nextGroups: [0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])]
            fixes.append("No Enemy Points, added a loop of 8 round the arena so CPU players can move. Reshape it to follow the arena's paths.")
        }
        return fixes
    }

    /// Battle-specific verifier checks (the shared KMP checks run as well).
    static func checks(_ doc: KMPDocument) -> [ModVerifier.Check] {
        typealias Check = ModVerifier.Check
        var checks: [Check] = []
        let indices = doc.ktpt.map(\.playerIndex)
        let perPlayer = Set(indices) == Set(0..<Int16(playerCount)) && indices.count == playerCount
        checks.append(Check(label: "Start points (KTPT)", required: true, passed: perPlayer,
                            detail: perPlayer ? "12 start points, one per player 0-11."
                                : "\(doc.ktpt.count) start point(s) with player indices \(indices.map(String.init).joined(separator: ", ")). Every retail arena has exactly 12, one per player 0-11, use Make Testable to add the missing ones."))
        checks.append(Check(label: "Battle respawns (MSPT)", required: true, passed: !doc.mspt.isEmpty,
                            detail: doc.mspt.isEmpty ? "None, players knocked out of a battle have nowhere to come back."
                                : "\(doc.mspt.count) battle respawn point(s)."))
        if !doc.mspt.isEmpty, doc.mspt.count != battleRespawnCount {
            checks.append(Check(label: "Battle respawn count", required: false, passed: false,
                                detail: "\(doc.mspt.count) battle respawn points; every retail arena has exactly \(battleRespawnCount)."))
        }
        checks.append(Check(label: "CPU network (ENPT)", required: true, passed: !doc.enpt.isEmpty,
                            detail: doc.enpt.isEmpty ? "No enemy points. CPU players can't move." : "\(doc.enpt.count) enemy point(s) in \(doc.enph.count) group(s)."))
        let coins = doc.gobj.filter { $0.objectID == coinID }.count
        checks.append(Check(label: "Coins (Coin Runners)", required: false, passed: coins > 0,
                            detail: coins > 0 ? "\(coins) coin(s); retail arenas have 72-134."
                                : "No coins (object 0x73), so Coin Runners has nothing to collect. Retail arenas place 72-134."))
        let boxes = doc.gobj.filter { $0.objectID == 0x0065 || $0.objectID == 0x0076 }.count
        checks.append(Check(label: "Item boxes", required: false, passed: boxes > 0,
                            detail: boxes > 0 ? "\(boxes) item box(es)." : "No item boxes. Balloon Battle is played with items."))
        if !doc.itpt.isEmpty || !doc.ckpt.isEmpty {
            checks.append(Check(label: "Race-only data", required: false, passed: false,
                                detail: "Has \(doc.itpt.count) item point(s) and \(doc.ckpt.count) checkpoint(s); no retail arena has either."))
        }
        checks.append(Check(label: "Battle slot", required: false, passed: true,
                            detail: "Save the arena over one of: " + slots.map { "\($0.file) (\($0.name))" }.joined(separator: ", ") + "."))
        return checks
    }
}
