import Foundation

/// What a marked Hot Swap file can stand in for: "Mark for Hot Swap > Mario Kart Wii > Tracks >
/// Mushroom Cup > Luigi Circuit" makes `My Track.szs` replace `beginner_course.szs` (and its
/// multiplayer `_d` copy) instead of a disc file named "My Track.szs".
///
/// Sources, all checked against the retail discs or their community references:
/// - Mario Kart Wii tracks and arenas, their cups and file names: Wiimm's SZS tools' track
///   database (`db-mkw.c`), every file confirmed present in Race/Course with its `_d` twin.
/// - Mario Kart Wii vehicles: the game's own code table in `rel/StaticR.rel`, in the same order as
///   the English vehicle names in its message table; characters from the Race/Kart and
///   Scene/Model/Kart file names (one `<vehicle>-<character>.szs` per pairing, plus `_4` and --
///   except for Miis and the Honeycoupe, `_2` split-screen copies; `<character>-allkart.szs` + `_BT` for the menus).
/// - Double Dash courses: `MKDDSlots` (both of a slot's archives, renamed for it at swap time);
///   racers and karts are files inside `MRAM.arc` (`driver/<name>/driver.bmd`,
///   `kart/<name>_all/<part>.bmd`), patched into a copy of it at swap time.
/// - NSMBW levels: Reggie-Next's `levelnames.xml` (`Stage/<world>-<level>.arc`).
nonisolated enum HotSwapTargets {
    enum Game: String, CaseIterable, Codable { case marioKartWii, marioKartDoubleDash, nsmbw
        var title: String { switch self { case .marioKartWii: "Mario Kart Wii"; case .marioKartDoubleDash: "Mario Kart: Double Dash!!"; case .nsmbw: "New Super Mario Bros. Wii" } }
    }

    /// How the marked file becomes the target's disc files.
    enum Kind: Hashable {
        /// Installed as each of these disc files (bare names, as Hot Swap matches them).
        case files([String])
        /// A Double Dash course archive, renamed for this slot (root folder and file prefix).
        case mkddCourse(slot: String)
        /// Files inside `MRAM.arc` (Double Dash racers and karts), patched into a copy of it.
        case mramMembers([String])
    }

    struct Target: Hashable, Identifiable {
        let id: String
        let game: Game
        /// Full path for display, e.g. "Tracks > Mushroom Cup > Luigi Circuit".
        let path: [String]
        let kind: Kind
        var title: String { path.last ?? id }
    }

    indirect enum Node: Identifiable {
        case group(String, [Node])
        case target(Target)
        var id: String { switch self { case .group(let t, _): "g:" + t; case .target(let t): t.id } }
    }

    // MARK: Catalogue

    static func menu(for game: Game) -> [Node] {
        switch game {
        case .marioKartWii: mkwiiMenu
        case .marioKartDoubleDash: mkddMenu
        case .nsmbw: nsmbwMenu
        }
    }

    static func target(id: String) -> Target? { allTargets[id] }

    private static let allTargets: [String: Target] = {
        var out: [String: Target] = [:]
        func walk(_ n: Node) { switch n { case .group(_, let c): c.forEach(walk); case .target(let t): out[t.id] = t } }
        Game.allCases.flatMap(menu(for:)).forEach(walk)
        return out
    }()

    // Mario Kart Wii

    private static let mkwiiCups: [(String, [(String, String)])] = [
        ("Mushroom Cup", [("Luigi Circuit", "beginner_course"), ("Moo Moo Meadows", "farm_course"), ("Mushroom Gorge", "kinoko_course"), ("Toad's Factory", "factory_course")]),
        ("Flower Cup", [("Mario Circuit", "castle_course"), ("Coconut Mall", "shopping_course"), ("DK Summit", "boardcross_course"), ("Wario's Gold Mine", "truck_course")]),
        ("Star Cup", [("Daisy Circuit", "senior_course"), ("Koopa Cape", "water_course"), ("Maple Treeway", "treehouse_course"), ("Grumble Volcano", "volcano_course")]),
        ("Special Cup", [("Dry Dry Ruins", "desert_course"), ("Moonview Highway", "ridgehighway_course"), ("Bowser's Castle", "koopa_course"), ("Rainbow Road", "rainbow_course")]),
        ("Shell Cup", [("GCN Peach Beach", "old_peach_gc"), ("DS Yoshi Falls", "old_falls_ds"), ("SNES Ghost Valley 2", "old_obake_sfc"), ("N64 Mario Raceway", "old_mario_64")]),
        ("Banana Cup", [("N64 Sherbet Land", "old_sherbet_64"), ("GBA Shy Guy Beach", "old_heyho_gba"), ("DS Delfino Square", "old_town_ds"), ("GCN Waluigi Stadium", "old_waluigi_gc")]),
        ("Leaf Cup", [("DS Desert Hills", "old_desert_ds"), ("GBA Bowser Castle 3", "old_koopa_gba"), ("N64 DK's Jungle Parkway", "old_donkey_64"), ("GCN Mario Circuit", "old_mario_gc")]),
        ("Lightning Cup", [("SNES Mario Circuit 3", "old_mario_sfc"), ("DS Peach Gardens", "old_garden_ds"), ("GCN DK Mountain", "old_donkey_gc"), ("N64 Bowser's Castle", "old_koopa_64")]),
    ]
    private static let mkwiiArenas: [(String, [(String, String)])] = [
        ("Wii Arenas", [("Block Plaza", "block_battle"), ("Delfino Pier", "venice_battle"), ("Funky Stadium", "skate_battle"), ("Chain Chomp Wheel", "casino_battle"), ("Thwomp Desert", "sand_battle")]),
        ("Retro Arenas", [("SNES Battle Course 4", "old_battle4_sfc"), ("GBA Battle Course 3", "old_battle3_gba"), ("N64 Skyscraper", "old_matenro_64"), ("GCN Cookie Land", "old_CookieLand_gc"), ("DS Twilight House", "old_House_ds")]),
    ]
    // Characters by weight class (codes from the Race/Kart file names).
    private static let mkwiiCharacters: [(String, [(String, String)])] = [
        ("Light", [("Baby Mario", "bmr"), ("Baby Luigi", "blg"), ("Baby Peach", "bpc"), ("Baby Daisy", "bds"), ("Toad", "ko"), ("Toadette", "kk"), ("Koopa Troopa", "nk"), ("Dry Bones", "ka"),
                   ("Mii (Small, Outfit A, Male)", "sa_mii_m"), ("Mii (Small, Outfit A, Female)", "sa_mii_f"), ("Mii (Small, Outfit B, Male)", "sb_mii_m"), ("Mii (Small, Outfit B, Female)", "sb_mii_f")]),
        ("Medium", [("Mario", "mr"), ("Luigi", "lg"), ("Peach", "pc"), ("Daisy", "ds"), ("Yoshi", "ys"), ("Birdo", "ca"), ("Diddy Kong", "dd"), ("Bowser Jr.", "jr"),
                    ("Mii (Medium, Outfit A, Male)", "ma_mii_m"), ("Mii (Medium, Outfit A, Female)", "ma_mii_f"), ("Mii (Medium, Outfit B, Male)", "mb_mii_m"), ("Mii (Medium, Outfit B, Female)", "mb_mii_f")]),
        ("Heavy", [("Wario", "wr"), ("Waluigi", "wl"), ("Donkey Kong", "dk"), ("Bowser", "kp"), ("King Boo", "kt"), ("Rosalina", "rs"), ("Funky Kong", "fk"), ("Dry Bowser", "bk"),
                   ("Mii (Large, Outfit A, Male)", "la_mii_m"), ("Mii (Large, Outfit A, Female)", "la_mii_f"), ("Mii (Large, Outfit B, Male)", "lb_mii_m"), ("Mii (Large, Outfit B, Female)", "lb_mii_f")]),
    ]
    /// Vehicle codes in the game's own order (StaticR.rel) with their English names.
    private static let mkwiiVehicles: [(code: String, name: String)] = [
        ("sdf_kart", "Standard Kart S"), ("mdf_kart", "Standard Kart M"), ("ldf_kart", "Standard Kart L"), ("sa_kart", "Booster Seat"), ("ma_kart", "Classic Dragster"), ("la_kart", "Offroader"),
        ("sb_kart", "Mini Beast"), ("mb_kart", "Wild Wing"), ("lb_kart", "Flame Flyer"), ("sc_kart", "Cheep Charger"), ("mc_kart", "Super Blooper"), ("lc_kart", "Piranha Prowler"),
        ("sd_kart", "Tiny Titan"), ("md_kart", "Daytripper"), ("ld_kart", "Jetsetter"), ("se_kart", "Blue Falcon"), ("me_kart", "Sprinter"), ("le_kart", "Honeycoupe"),
        ("sdf_bike", "Standard Bike S"), ("mdf_bike", "Standard Bike M"), ("ldf_bike", "Standard Bike L"), ("sa_bike", "Bullet Bike"), ("ma_bike", "Mach Bike"), ("la_bike", "Flame Runner"),
        ("sb_bike", "Bit Bike"), ("mb_bike", "Sugarscoot"), ("lb_bike", "Wario Bike"), ("sc_bike", "Quacker"), ("mc_bike", "Zip Zip"), ("lc_bike", "Shooting Star"),
        ("sd_bike", "Magikruiser"), ("md_bike", "Sneakster"), ("ld_bike", "Spear"), ("se_bike", "Jet Bubble"), ("me_bike", "Dolphin Dasher"), ("le_bike", "Phantom"),
    ]
    /// The vehicles a weight class drives (its code's first letter: s/m/l).
    private static func vehicles(forClass cls: String) -> [(code: String, name: String)] {
        let letter = ["Light": "s", "Medium": "m", "Heavy": "l"][cls] ?? "s"
        return mkwiiVehicles.filter { $0.code.hasPrefix(letter) }
    }
    /// One pairing's files: the race model and its split-screen copies. Every pairing on the disc
    /// has a 4-player `_4`; the 2-player `_2` exists for all but Miis and the Honeycoupe.
    private static func pairing(_ vehicle: String, _ character: String) -> [String] {
        let base = "\(vehicle)-\(character)"
        let hasTwoPlayer = !character.contains("_mii_") && vehicle != "le_kart"
        return [base + ".szs"] + (hasTwoPlayer ? [base + "_2.szs"] : []) + [base + "_4.szs"]
    }

    private static var mkwiiMenu: [Node] {
        let tracks: [Node] = mkwiiCups.map { cup, courses in
            .group(cup, courses.map { name, file in
                .target(Target(id: "mkwii.track.\(file)", game: .marioKartWii, path: ["Tracks", cup, name], kind: .files(["\(file).szs", "\(file)_d.szs"])))
            })
        }
        let arenas: [Node] = mkwiiArenas.map { group, list in
            .group(group, list.map { name, file in
                .target(Target(id: "mkwii.battle.\(file)", game: .marioKartWii, path: ["Battle Maps", group, name], kind: .files(["\(file).szs", "\(file)_d.szs"])))
            })
        }
        let racers: [Node] = mkwiiCharacters.map { cls, chars in
            .group(cls, chars.map { name, code in
                .group(name, [.target(Target(id: "mkwii.menu.\(code)", game: .marioKartWii, path: ["Racers", cls, name, "Menu Model"],
                                             kind: .files(["\(code)-allkart.szs", "\(code)-allkart_BT.szs"])))]
                    + vehicles(forClass: cls).map { v in
                        .target(Target(id: "mkwii.pair.\(v.code)-\(code)", game: .marioKartWii, path: ["Racers", cls, name, "On \(v.name)"], kind: .files(pairing(v.code, code))))
                    })
            })
        }
        let karts: [Node] = ["Light", "Medium", "Heavy"].map { cls in
            .group(cls, vehicles(forClass: cls).map { v in
                .group(v.name, (mkwiiCharacters.first { $0.0 == cls }?.1 ?? []).map { name, code in
                    .target(Target(id: "mkwii.pair.\(v.code)-\(code)", game: .marioKartWii, path: ["Karts", cls, v.name, "Driven by \(name)"], kind: .files(pairing(v.code, code))))
                })
            })
        }
        return [.group("Tracks", tracks), .group("Battle Maps", arenas), .group("Racers", racers), .group("Karts", karts)]
    }

    // Double Dash

    private static let mkddCups: [(String, [String])] = [
        ("Mushroom Cup", ["Luigi2", "Peach", "BabyLuigi", "Desert"]),
        ("Flower Cup", ["Nokonoko", "Mario", "Daisy", "Waluigi"]),
        ("Star Cup", ["Snow", "Patapata", "Yoshi", "Donkey"]),
        ("Special Cup", ["Wario", "Diddy", "Koopa", "Rainbow"]),
    ]
    private static let mkddRacers: [(String, String)] = [
        ("Mario", "mario"), ("Luigi", "luigi"), ("Peach", "peach"), ("Daisy", "daisy"), ("Yoshi", "yoshi"), ("Birdo", "catherine"),
        ("Baby Mario", "babymario"), ("Baby Luigi", "babyluigi"), ("Koopa Troopa", "nokonoko"), ("Paratroopa", "patapata"),
        ("Donkey Kong", "dk"), ("Diddy Kong", "dkjr"), ("Bowser", "koopa"), ("Bowser Jr.", "koopajr"), ("Wario", "wario"), ("Waluigi", "waluigi"),
        ("Toad", "kinopio"), ("Toadette", "kinopico"), ("King Boo", "kingteresa"), ("Petey Piranha", "bosspakkun"),
    ]
    /// Kart folders in MRAM.arc's kart/ (the code is shown, as the folder names are the reference).
    private static let mkddKarts: [(String, String)] = [
        ("Red Fire", "mario"), ("Green Fire", "luigi"), ("Heart Coach", "peach"), ("Bloom Coach", "daisy"), ("Turbo Yoshi", "yoshi"), ("Turbo Birdo", "cathy"),
        ("Goo-Goo Buggy", "baby"), ("Rattle Buggy", "bblui"), ("Koopa Dasher", "noko"), ("Para-Wing", "pata"), ("DK Jumbo", "dk"), ("Barrel Train", "diddy"),
        ("Koopa King", "koopa"), ("Bullet Blaster", "jr"), ("Wario Car", "wario"), ("Waluigi Racer", "walui"), ("Toad Kart", "kpio"), ("Toadette Kart", "kpico"),
        ("Boo Pipes", "teres"), ("Piranha Pipes", "pakku"), ("Parade Kart", "extra"),
    ]
    /// Parts every kart folder has (Toad's, Toadette's and Diddy's have no shock).
    private static let mkddKartParts: [(String, String)] = [("Body", "k_body"), ("Arm", "k_arm"), ("Shock", "k_shock"), ("Left Tyre", "k_tire_l"), ("Right Tyre", "k_tire_r")]

    private static var mkddMenu: [Node] {
        func course(_ archive: String, _ group: [String]) -> Node? {
            guard let slot = MKDDSlots.slots.first(where: { $0.archive == archive }) else { return nil }
            return .target(Target(id: "mkdd.course.\(archive)", game: .marioKartDoubleDash, path: group + [slot.title], kind: .mkddCourse(slot: archive)))
        }
        let tracks: [Node] = mkddCups.map { cup, archives in .group(cup, archives.compactMap { course($0, ["Tracks", cup]) }) }
        let arenas: [Node] = MKDDSlots.slots.filter(\.battle).compactMap { course($0.archive, ["Battle Maps"]) }
        let racers: [Node] = mkddRacers.map { name, folder in
            .target(Target(id: "mkdd.driver.\(folder)", game: .marioKartDoubleDash, path: ["Racers", name],
                           kind: .mramMembers(["driver/\(folder)/driver.bmd", "driver/\(folder)/driver_200.bmd"])))
        }
        let karts: [Node] = mkddKarts.map { name, code in
            let parts = mkddKartParts.filter { !($0.1 == "k_shock" && ["kpio", "kpico", "diddy"].contains(code)) }
            return .group("\(name) (\(code)_all)", parts.map { part, file in
                .target(Target(id: "mkdd.kart.\(code).\(file)", game: .marioKartDoubleDash, path: ["Karts", name, part],
                               kind: .mramMembers(["kart/\(code)_all/\(code)_\(file).bmd"])))
            })
        }
        return [.group("Tracks", tracks), .group("Battle Maps", arenas), .group("Racers", racers), .group("Karts", karts)]
    }

    // NSMBW

    private static let nsmbwLevels: [(String, [(String, String)])] = [
        ("World 1", [("01-01", "World 1-1"), ("01-02", "World 1-2"), ("01-03", "World 1-3"), ("01-22", "World 1-Tower"), ("01-04", "World 1-4"), ("01-05", "World 1-5"), ("01-06", "World 1-6"), ("01-24", "World 1-Castle"), ("01-36", "World 1-Cannon"), ("01-41", "Peach's Castle"), ("01-26", "Toad House - 1UP Blast"), ("01-27", "Toad House - Powerup Panels (1)"), ("01-29", "Toad House - Powerup Panels (2)"), ("01-28", "Toad House - Star Chest"), ("01-33", "Goomba Ambush 1"), ("01-34", "Goomba Ambush 2"), ("01-35", "Goomba Ambush 3")]),
        ("World 2", [("02-01", "World 2-1"), ("02-02", "World 2-2"), ("02-03", "World 2-3"), ("02-22", "World 2-Tower"), ("02-04", "World 2-4"), ("02-05", "World 2-5"), ("02-06", "World 2-6"), ("02-24", "World 2-Castle"), ("02-36", "World 2-Cannon"), ("02-26", "Toad House - 1UP Blast"), ("02-27", "Toad House - Powerup Panels"), ("02-28", "Toad House - Star Chest"), ("02-33", "Sand Trap Ambush 1"), ("02-34", "Sand Trap Ambush 2"), ("02-35", "Sand Trap Ambush 3")]),
        ("World 3", [("03-01", "World 3-1"), ("03-02", "World 3-2"), ("03-03", "World 3-3"), ("03-21", "World 3-Ghost House"), ("03-22", "World 3-Tower"), ("03-04", "World 3-4"), ("03-05", "World 3-5"), ("03-24", "World 3-Castle"), ("03-36", "World 3-Cannon"), ("03-26", "Toad House - 1UP Blast"), ("03-27", "Toad House - Powerup Panels (1)"), ("03-29", "Toad House - Powerup Panels (2)"), ("03-28", "Toad House - Star Chest"), ("03-33", "Ice Bros Ambush 1"), ("03-34", "Ice Bros Ambush 2"), ("03-35", "Ice Bros Ambush 3")]),
        ("World 4", [("04-01", "World 4-1"), ("04-02", "World 4-2"), ("04-03", "World 4-3"), ("04-22", "World 4-Tower"), ("04-04", "World 4-4"), ("04-21", "World 4-Ghost House"), ("04-05", "World 4-5"), ("04-24", "World 4-Castle"), ("04-38", "World 4-Ship"), ("04-36", "World 4-Cannon"), ("04-26", "Toad House - 1UP Blast"), ("04-27", "Toad House - Powerup Panels"), ("04-28", "Toad House - Star Chest (1)"), ("04-29", "Toad House - Star Chest (2)"), ("04-33", "Porcu-puffer Ambush 1"), ("04-34", "Porcu-puffer Ambush 2"), ("04-35", "Porcu-puffer Ambush 3")]),
        ("World 5", [("05-01", "World 5-1"), ("05-02", "World 5-2"), ("05-03", "World 5-3"), ("05-22", "World 5-Tower"), ("05-04", "World 5-4"), ("05-21", "World 5-Ghost House"), ("05-05", "World 5-5"), ("05-24", "World 5-Castle"), ("05-36", "World 5-Cannon"), ("05-26", "Toad House - 1UP Blast"), ("05-27", "Toad House - Powerup Panels (1)"), ("05-29", "Toad House - Powerup Panels (2)"), ("05-28", "Toad House - Star Chest"), ("05-33", "Piranha Plant Ambush 1"), ("05-34", "Piranha Plant Ambush 2"), ("05-35", "Piranha Plant Ambush 3")]),
        ("World 6", [("06-01", "World 6-1"), ("06-02", "World 6-2"), ("06-03", "World 6-3"), ("06-04", "World 6-4"), ("06-22", "World 6-Tower"), ("06-05", "World 6-5"), ("06-06", "World 6-6"), ("06-24", "World 6-Castle"), ("06-38", "World 6-Ship"), ("06-36", "World 6-Cannon"), ("06-26", "Toad House - 1UP Blast"), ("06-27", "Toad House - Powerup Panels"), ("06-28", "Toad House - Star Chest"), ("06-33", "Bullet Bill Ambush 1"), ("06-34", "Bullet Bill Ambush 2"), ("06-35", "Bullet Bill Ambush 3")]),
        ("World 7", [("07-01", "World 7-1"), ("07-02", "World 7-2"), ("07-03", "World 7-3"), ("07-22", "World 7-Tower"), ("07-21", "World 7-Ghost House"), ("07-04", "World 7-4"), ("07-05", "World 7-5"), ("07-06", "World 7-6"), ("07-24", "World 7-Castle"), ("07-26", "Toad House - 1UP Blast"), ("07-27", "Toad House - Powerup Panels"), ("07-28", "Toad House - Star Chest (1)"), ("07-29", "Toad House - Star Chest (2)"), ("07-33", "Lakitu Ambush 1"), ("07-34", "Lakitu Ambush 2"), ("07-35", "Lakitu Ambush 3")]),
        ("World 8", [("08-01", "World 8-1"), ("08-02", "World 8-2"), ("08-03", "World 8-3"), ("08-22", "World 8-Tower"), ("08-04", "World 8-4"), ("08-05", "World 8-5"), ("08-06", "World 8-6"), ("08-07", "World 8-7"), ("08-38", "World 8-Ship"), ("08-24", "World 8-Castle"), ("08-26", "Toad House - 1UP Blast"), ("08-27", "Toad House - Powerup Panels"), ("08-28", "Toad House - Star Chest"), ("08-33", "Podoboo Ambush 1"), ("08-34", "Podoboo Ambush 2"), ("08-35", "Podoboo Ambush 3")]),
        ("World 9", [("09-01", "World 9-1"), ("09-02", "World 9-2"), ("09-03", "World 9-3"), ("09-04", "World 9-4"), ("09-05", "World 9-5"), ("09-06", "World 9-6"), ("09-07", "World 9-7"), ("09-08", "World 9-8"), ("09-26", "Toad House - 1UP Blast"), ("09-27", "Toad House - Powerup Panels"), ("09-28", "Toad House - Star Chest")]),
        ("Coin Battle", [("01-20", "Coin Battle 1"), ("02-20", "Coin Battle 2"), ("03-20", "Coin Battle 3"), ("04-20", "Coin Battle 4"), ("05-20", "Coin Battle 5")]),
        ("Other", [("01-40", "Titlescreen"), ("01-42", "Credits")])
    ]

    private static var nsmbwMenu: [Node] {
        [.group("Levels", nsmbwLevels.map { world, levels in
            .group(world, levels.map { file, name in
                .target(Target(id: "nsmbw.level.\(file)", game: .nsmbw, path: ["Levels", world, name], kind: .files(["\(file).arc"])))
            })
        })]
    }

    // MARK: Swapping

    /// Disc file names a target is installed as (for the plan and for display).
    static func discFiles(_ t: Target) -> [String] {
        switch t.kind {
        case .files(let names): names
        case .mkddCourse(let archive): MKDDSlots.slots.first { $0.archive == archive }?.archives.map(\.name) ?? []
        case .mramMembers: ["MRAM.arc"]
        }
    }

    /// A Double Dash course archive renamed for a slot: root folder `root`, and every top-level
    /// `<prefix>_...` file renamed `<stem>_...`, what mkdd-track-patcher's `rename_archive` does.
    static func renamedCourse(_ data: Data, root rootName: String, stem: String) throws -> Data {
        let (root, compressed) = try SZS.open(data)
        guard root.isRARC else { throw WSError.badStructure("Not a Double Dash course archive (RARC).") }
        root.name = rootName
        for child in root.children where !child.isDirectory {
            guard let underscore = child.name.firstIndex(of: "_") else { continue }
            child.name = stem + child.name[underscore...]
        }
        return SZS.save(root: root, compressed: compressed)
    }

    /// Lays out `files` (marked project files) in a staging folder named after the project, each
    /// under the disc name it replaces: its own name, or its Hot Swap target's, a Mario Kart Wii
    /// track also as its `_d` twin, a Double Dash course renamed for its slot (both archives), a
    /// Double Dash racer/kart patched into a copy of the base disc's `MRAM.arc`. Plain files are
    /// symlinks into the project, so the swap always reads the current build.
    static func stage(modRoot: URL, files: [String], baseISO: URL) throws -> (root: URL, files: [String], notes: [String]) {
        let fm = FileManager.default
        let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = appSupport.appendingPathComponent("Revolution IDE/HotSwap", isDirectory: true)
            .appendingPathComponent(modRoot.lastPathComponent, isDirectory: true)
            .appendingPathComponent(modRoot.lastPathComponent, isDirectory: true)
        try? fm.removeItem(at: root)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var notes: [String] = [], placed: [String: String] = [:], mram: [String: Data] = [:]
        // A marked folder is packed into an archive first (see `HotSwapFolderPack`).
        var packed: [String: Data] = [:]
        func isFolder(_ relative: String) -> Bool {
            var dir: ObjCBool = false
            return fm.fileExists(atPath: modRoot.appendingPathComponent(relative).path, isDirectory: &dir) && dir.boolValue
        }
        func contents(_ relative: String) throws -> Data {
            if let d = packed[relative] { return d }
            return try Data(contentsOf: modRoot.appendingPathComponent(relative))
        }
        func place(_ name: String, from relative: String, data: Data? = nil) throws {
            if let earlier = placed[name] { notes.append("\(relative) and \(earlier) both replace \(name); using \(relative).") }
            let dest = root.appendingPathComponent(name)
            try? fm.removeItem(at: dest)
            if let data { try data.write(to: dest, options: .atomic) }
            else { try fm.createSymbolicLink(at: dest, withDestinationURL: modRoot.appendingPathComponent(relative)) }
            placed[name] = relative
        }
        for relative in files {
            var filename = (relative as NSString).lastPathComponent
            let target = HotSwapTargetMarks.target(for: relative, project: modRoot)
            if isFolder(relative) {
                var mode = HotSwapFolderModes.mode(for: relative, project: modRoot)
                if case .mkddCourse = target?.kind { mode = .rarc } // Double Dash courses are RARC
                packed[relative] = try mode.pack(modRoot.appendingPathComponent(relative))
                filename += "." + mode.fileExtension
                notes.append("Packed the \(relative) folder as \(mode.title).")
            }
            guard let target else { try place(filename, from: relative, data: packed[relative]); continue }
            switch target.kind {
            case .files(let names):
                for name in names { try place(name, from: relative, data: packed[relative]) }
                notes.append("\(filename) replaces \(target.path.joined(separator: " > ")) (\(names.joined(separator: ", "))).")
            case .mkddCourse(let archive):
                guard let slot = MKDDSlots.slots.first(where: { $0.archive == archive }) else { continue }
                let data = try contents(relative)
                for a in slot.archives { try place(a.name, from: relative, data: try HotSwapTargets.renamedCourse(data, root: a.root, stem: slot.fileStem)) }
                notes.append("\(filename) replaces \(slot.title) (\(slot.archives.map(\.name).joined(separator: ", ")), renamed for the slot).")
            case .mramMembers(let members):
                let data = try contents(relative)
                for m in members { mram[m] = data }
                notes.append("\(filename) replaces \(target.path.joined(separator: " > ")) inside MRAM.arc.")
            }
        }
        if !mram.isEmpty {
            guard GameCubeHotSwap.isGameCubeDisc(baseISO), let disc = try? GameCubeDisc(url: baseISO),
                  let node = disc.root.children.first(where: { $0.name == "MRAM.arc" }) else {
                throw WSError.badStructure("Double Dash racers and karts are patched into the base disc's MRAM.arc, but \(baseISO.lastPathComponent) has none, pick a Double Dash disc as the Hot Swap base.")
            }
            let patched = try HotSwapTargets.patchedMRAM(try disc.readFile(node: node), replacing: mram)
            if !patched.missing.isEmpty { notes.append("Not in this disc's MRAM.arc, skipped: \(patched.missing.joined(separator: ", ")).") }
            try place("MRAM.arc", from: "racer/kart files", data: patched.data)
        }
        return (root, placed.keys.sorted(), notes)
    }

    /// `MRAM.arc` with `members` (paths inside it) replaced.
    static func patchedMRAM(_ mram: Data, replacing members: [String: Data]) throws -> (data: Data, missing: [String]) {
        let (root, compressed) = try SZS.open(mram)
        var missing: [String] = []
        for (path, data) in members {
            var node: U8Node? = root
            for part in path.split(separator: "/") { node = node?.children.first { $0.name == String(part) } }
            if let node, !node.isDirectory { node.data = data } else { missing.append(path) }
        }
        return (SZS.save(root: root, compressed: compressed), missing)
    }
}

/// Which target each marked file stands in for, per project (unset = the disc file with the
/// file's own name, the original Hot Swap behaviour).
nonisolated enum HotSwapTargetMarks {
    private static func key(_ project: URL) -> String { "HotSwapTargets.\(project.path)" }

    static func all(forProject project: URL) -> [String: String] {
        (UserDefaults.standard.dictionary(forKey: key(project)) as? [String: String]) ?? [:]
    }

    static func target(for relativePath: String, project: URL) -> HotSwapTargets.Target? {
        all(forProject: project)[relativePath].flatMap(HotSwapTargets.target(id:))
    }

    static func set(_ target: HotSwapTargets.Target?, for relativePath: String, project: URL) {
        var map = all(forProject: project)
        map[relativePath] = target?.id
        UserDefaults.standard.set(map, forKey: key(project))
    }
}

/// How a folder marked for Hot Swap is packed into the archive the game loads.
nonisolated enum HotSwapFolderPack: String, CaseIterable, Identifiable {
    /// Yaz0-compressed U8: Mario Kart Wii tracks and most Wii archives.
    case szs
    /// Uncompressed U8: New Super Mario Bros. Wii levels and other Wii `.arc` files.
    case arc
    /// GameCube RARC, Yaz0-compressed: Double Dash `.arc` courses.
    case rarc
    var id: String { rawValue }
    var title: String {
        switch self {
        case .szs: ".szs (U8, compressed)"
        case .arc: ".arc (U8)"
        case .rarc: ".arc (GameCube RARC)"
        }
    }
    var fileExtension: String { self == .szs ? "szs" : "arc" }

    func pack(_ folder: URL) throws -> Data {
        SZS.save(root: try tree(folder), compressed: self != .arc)
    }

    /// The archive `pack` would write, as a tree (what the Hot Swap checks read).
    func tree(_ folder: URL) throws -> U8Node {
        let root = U8Node(name: self == .rarc ? folder.lastPathComponent.lowercased() : "", isDirectory: true)
        try Self.add(folder, to: root)
        root.isRARC = self == .rarc
        return root
    }

    private static func add(_ dir: URL, to node: U8Node) throws {
        let items = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for item in items {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let child = U8Node(name: item.lastPathComponent, isDirectory: isDir, data: isDir ? nil : try Data(contentsOf: item))
            child.parent = node
            node.children.append(child)
            if isDir { try add(item, to: child) }
        }
    }
}

/// The packing chosen for each marked folder, per project (unset = `.szs`).
nonisolated enum HotSwapFolderModes {
    private static func key(_ project: URL) -> String { "HotSwapFolderModes.\(project.path)" }
    static func mode(for relativePath: String, project: URL) -> HotSwapFolderPack {
        ((UserDefaults.standard.dictionary(forKey: key(project)) as? [String: String])?[relativePath]).flatMap(HotSwapFolderPack.init) ?? .szs
    }
    static func set(_ mode: HotSwapFolderPack?, for relativePath: String, project: URL) {
        var map = (UserDefaults.standard.dictionary(forKey: key(project)) as? [String: String]) ?? [:]
        map[relativePath] = mode?.rawValue
        UserDefaults.standard.set(map, forKey: key(project))
    }
}

/// What Hot Swap checks before booting: each marked track/arena/course/level runs through
/// `ModVerifier` (failed required checks are errors, failed optional ones warnings), plus Hot
/// Swap-specific mistakes (a battle arena on a race slot, a track that replaces nothing, the wrong
/// base disc) and suggestions that make a track feel finished (item boxes, item paths, cameras).
nonisolated enum HotSwapPreflight {
    enum Level: Int, CaseIterable, Comparable {
        case error, warning, suggestion
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
        var title: String { switch self { case .error: "Errors"; case .warning: "Warnings"; case .suggestion: "Suggestions" } }
    }

    struct Finding: Identifiable {
        let id = UUID()
        let level: Level
        let file: String
        let title: String
        /// What's wrong, and what happens in-game because of it.
        let detail: String
        /// What to do about it, in plain words.
        var howTo: String = ""
        /// What Auto Correct can do instead.
        var fix: HotSwapAutoFix? = nil
        /// The marked project path the finding is about (what Auto Correct opens).
        var relative: String = ""
    }

    /// The checks a Mario Kart Wii track or arena fails that are likely to crash it (empty for
    /// anything else). Builds and Hot Swap refuse while there are any.
    static func crashRisks(_ root: U8Node) -> [ModVerifier.Check] {
        guard let kmpData = root.children.first(where: { !$0.isDirectory && $0.name == "course.kmp" })?.data else { return [] }
        let battle = (try? KMPDocument.parse(kmpData)).map(BattleArena.isBattle) ?? false
        return ModVerifier.verify(battle ? .mkwiiBattle : .mkwiiCourse, root: root).checks.filter { $0.required && !$0.passed }
    }

    /// Settings > Emulator > Safeguards. On by default; off skips the checks before Hot Swap
    /// play and lets tracks with crash risks be built.
    static let enabledKey = "safeguards.enabled"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    static let itemBoxIDs: Set<UInt16> = [0x065, 0x076, 0x0C9, 0x0D4, 0x0EE]

    /// `files` are the marked project paths (`EmulatorLauncher.filesToSwap`); `gameID` the base disc's.
    static func check(modRoot: URL, files: [String], gameID: String?) -> [Finding] {
        var out: [Finding] = []
        let mkwiiFiles = Set(HotSwapTargets.menu(for: .marioKartWii).flatMap(discFileNames))
        for relative in files {
            let url = modRoot.appendingPathComponent(relative)
            let name = (relative as NSString).lastPathComponent
            let target = HotSwapTargetMarks.target(for: relative, project: modRoot)
            func add(_ level: Level, _ title: String, _ detail: String, howTo: String = "", fix: HotSwapAutoFix? = nil) {
                out.append(Finding(level: level, file: name, title: title, detail: detail, howTo: howTo, fix: fix, relative: relative))
            }
            if let target, let gameID, gamePrefix(target.game) != nil, !gameID.hasPrefix(gamePrefix(target.game)!) {
                add(.error, "Wrong base disc", "\(name) replaces \(target.path.joined(separator: " > ")), a \(target.game.title) slot, but the base disc is \(gameID), so it would replace nothing or the wrong game's files.",
                    howTo: "Open Run > Standard Boot, go to the Hot Swap tab and choose your \(target.game.title) disc as the base disc.")
            }
            var dir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) else { continue }
            let ext = url.pathExtension.lowercased()
            guard dir.boolValue || ["szs", "arc"].contains(ext) else { continue }
            // A folder is checked as the archive staging packs it into (Double Dash courses as RARC).
            var mode = HotSwapFolderModes.mode(for: relative, project: modRoot)
            if case .mkddCourse = target?.kind { mode = .rarc }
            let discName = dir.boolValue ? name + "." + mode.fileExtension : name
            let root = dir.boolValue ? try? mode.tree(url) : (try? Data(contentsOf: url)).flatMap { try? SZS.open($0).root }
            guard let root else {
                add(.error, "Unreadable archive", "\(name) couldn't be opened as an archive, so the game can't load it either.",
                    howTo: "Open it in Revolution Editor to see what's wrong, or rebuild it from its folder.")
                continue
            }
            let file = { (n: String) in root.children.first { !$0.isDirectory && $0.name == n }?.data }
            if let kmpData = file("course.kmp") {
                let kmp = try? KMPDocument.parse(kmpData)
                let battle = kmp.map(BattleArena.isBattle) ?? false
                let result = ModVerifier.verify(battle ? .mkwiiBattle : .mkwiiCourse, root: root)
                for c in result.checks where !c.passed {
                    let (fix, howTo) = HotSwapAutoFix.forWiiCheck(c, root: root, battle: battle)
                    add(c.required ? .error : .warning, c.label, c.detail, howTo: howTo, fix: fix)
                }
                if let target, target.game == .marioKartWii {
                    let onArena = target.path.first == "Battle Maps"
                    if battle && !onArena { add(.error, "Battle arena on a race track", "\(name) is a battle arena but replaces the race track \(target.title). The race would start with no route or laps and freeze.",
                                                howTo: "Right-click it and choose Mark for Hot Swap > Mario Kart Wii > Battle Maps, then an arena.") }
                    if !battle && onArena { add(.error, "Race track on a battle arena", "\(name) is a race track but replaces the arena \(target.title). Battle mode would load it without its 12 starts and crash.",
                                                howTo: "Right-click it and choose Mark for Hot Swap > Mario Kart Wii > Tracks, then a cup and track.") }
                } else if target == nil, !mkwiiFiles.contains(discName) {
                    add(.warning, "Replaces nothing", "Hot Swap swaps in a file under its own name, and the game has no \(name), so your track won't appear anywhere.",
                        howTo: "Right-click it and choose Mark for Hot Swap > Mario Kart Wii > Tracks (or Battle Maps) to pick the slot it should replace.")
                }
                if let kmp { out += suggestions(kmp: kmp, root: root, battle: battle).map { Finding(level: .suggestion, file: name, title: $0.0, detail: $0.1) } }
            } else if root.isRARC || root.children.contains(where: { $0.name.hasSuffix("_course.bol") }) {
                for c in ModVerifier.verify(.mkddCourse, root: root).checks where !c.passed {
                    // Hot Swap renames the archive for its slot, so the slot check only matters unmarked.
                    if c.label == "Course slot", target != nil { continue }
                    let (fix, howTo) = HotSwapAutoFix.forDoubleDashCheck(c)
                    add(c.required ? .error : .warning, c.label, c.detail, howTo: howTo, fix: fix)
                }
                if let bolData = root.children.first(where: { $0.name.lowercased().hasSuffix("_course.bol") })?.data, let bol = try? BOL.parse(bolData) {
                    out += doubleDashSuggestions(bol).map { Finding(level: .suggestion, file: name, title: $0.0, detail: $0.1) }
                }
            } else if target?.game == .nsmbw {
                for c in ModVerifier.verify(.nsmbwLevel, root: root).checks where !c.passed { add(c.required ? .error : .warning, c.label, c.detail) }
            }
        }
        return out.sorted { $0.level < $1.level }
    }

    /// Opens a marked track (an archive, or a folder packed the way staging packs it), applies
    /// `fixes` and saves it back where it was. Returns what each fix did.
    static func applyFixes(_ fixes: [HotSwapAutoFix], to relative: String, modRoot: URL, keys: (common: [UInt8]?, korean: [UInt8]?)) throws -> [String] {
        let url = modRoot.appendingPathComponent(relative)
        var dir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) else { throw WSError.badStructure("\(relative) is gone.") }
        var said: [String] = []
        if dir.boolValue {
            var mode = HotSwapFolderModes.mode(for: relative, project: modRoot)
            if case .mkddCourse = HotSwapTargetMarks.target(for: relative, project: modRoot)?.kind { mode = .rarc }
            let root = try mode.tree(url)
            for fix in fixes { said.append(try HotSwapAutoFix.apply(fix, to: root, keys: keys)) }
            func write(_ node: U8Node, to folder: URL) throws {
                for c in node.children {
                    let dest = folder.appendingPathComponent(c.name)
                    if c.isDirectory {
                        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                        try write(c, to: dest)
                    } else if let data = c.data, (try? Data(contentsOf: dest)) != data {
                        try data.write(to: dest, options: .atomic)
                    }
                }
            }
            try write(root, to: url)
        } else {
            let (root, compressed) = try SZS.open(try Data(contentsOf: url))
            for fix in fixes { said.append(try HotSwapAutoFix.apply(fix, to: root, keys: keys)) }
            try SZS.save(root: root, compressed: compressed).write(to: url, options: .atomic)
        }
        return said
    }

    private static func gamePrefix(_ game: HotSwapTargets.Game) -> String? {
        switch game { case .marioKartWii: "RMC"; case .marioKartDoubleDash: "GM4"; case .nsmbw: "SMN" }
    }

    private static func discFileNames(_ node: HotSwapTargets.Node) -> [String] {
        switch node {
        case .group(_, let children): children.flatMap(discFileNames)
        case .target(let t): HotSwapTargets.discFiles(t)
        }
    }

    /// Double Dash item boxes: GeoItemBox, GeoF_ItemBox and Block City's moving TMapObjMoveItemBox.
    static let doubleDashItemBoxIDs: Set<UInt16> = [1, 10, 9906]

    /// The Double Dash counterpart of `suggestions`.
    static func doubleDashSuggestions(_ bol: KMPDocument) -> [(String, String)] {
        var out: [(String, String)] = []
        if !bol.gobj.contains(where: { doubleDashItemBoxIDs.contains($0.objectID) }) {
            out.append(("No item boxes", "Every retail track and battle arena has item boxes. Add some as objects in the course data editor."))
        }
        if bol.came.isEmpty {
            out.append(("No cameras", "Without cameras there is no intro fly-over or replay camera. Add an intro camera in the course data editor (Tools > Intro Cameras)."))
        }
        return out
    }

    /// Things every retail track has that this one doesn't: not wrong, just unfinished.
    static func suggestions(kmp: KMPDocument, root: U8Node, battle: Bool) -> [(String, String)] {
        var out: [(String, String)] = []
        if !kmp.gobj.contains(where: { itemBoxIDs.contains($0.objectID) }) {
            out.append(("No item boxes", "Every retail \(battle ? "arena" : "track") has item boxes. Add some as Objects (GOBJ) in the KMP editor."))
        }
        if !battle, kmp.itpt.isEmpty {
            out.append(("No item paths", "Item paths (ITPT) guide Bullet Bills and Red/Blue Shells. Without them those items behave oddly. Copy the enemy paths to item paths in the KMP editor."))
        }
        if kmp.came.isEmpty {
            out.append(("No cameras", "Without cameras (CAME) there is no opening pan or replay camera. Add an opening camera in the KMP editor."))
        }
        return out
    }
}
