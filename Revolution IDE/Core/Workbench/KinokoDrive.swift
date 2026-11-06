import Foundation
import simd

/// Game-accurate driving for Driver's View: Mario Kart Wii's own physics (Kinoko, an MIT-licensed
/// reimplementation, built from `Vendor/Kinoko` into the bundled `kinoko-drive` helper). It runs
/// in its own process, so a course the engine can't handle stops the drive, not the app.
///
/// One `step` is one 60 fps game frame: steering, drifting, mini-turbos, tricks, walls, off-road,
/// boost panels, cannons, respawns and lap counting all come from the engine. Ghost (.rkg) replays
/// play back frame-exact. Kinoko reads the game's own `Race/Common.szs` (kart and character stats,
/// physics tables), taken from the linked Mario Kart Wii disc; nothing is bundled.
nonisolated final class KinokoDrive {
    struct Input {
        var accelerate = false
        var brake = false
        /// -1...1, right / up positive.
        var stick = SIMD2<Float>(0, 0)
        /// 0 none, 1 up, 2 down, 3 left, 4 right.
        var trick = 0
    }

    struct State: Equatable {
        var position = SIMD3<Float>(0, 0, 0)
        var rotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        var speed: Float = 0
        /// 0 intro, 1 countdown, 2 racing, 3 finished.
        var stage = 0
        var lap = 0
        var checkpoint = 0
        /// The respawn point (JGPT) the kart would go back to.
        var respawnPoint = 0
        var raceMs = 0
        var inRespawn = false
        var inCannon = false
        var onGround = false
        var wrongWay = false
    }

    enum Racer {
        case live(character: Int, vehicle: Int, autoDrift: Bool)
        case ghost(Data)
    }

    enum DriveError: LocalizedError {
        case noHelper, noDisc, noCommon, badGhost
        var errorDescription: String? {
            switch self {
            case .noHelper: return "The physics engine (kinoko-drive) is missing from the app bundle."
            case .noDisc: return "Game physics needs your Mario Kart Wii disc: link it in Settings > Games, and load its key.bin."
            case .noCommon: return "The linked disc has no Race/Common.szs, is it Mario Kart Wii?"
            case .badGhost: return "That file isn't a Mario Kart Wii ghost (.rkg)."
            }
        }
    }

    /// Internal course names by course ID, the order ghost files and Kinoko use.
    static let courseNames = ["castle_course", "farm_course", "kinoko_course", "volcano_course", "factory_course",
        "shopping_course", "boardcross_course", "truck_course", "beginner_course", "senior_course", "ridgehighway_course",
        "treehouse_course", "koopa_course", "rainbow_course", "desert_course", "water_course", "old_peach_gc",
        "old_mario_gc", "old_waluigi_gc", "old_donkey_gc", "old_falls_ds", "old_desert_ds", "old_garden_ds",
        "old_town_ds", "old_mario_sfc", "old_obake_sfc", "old_mario_64", "old_sherbet_64", "old_koopa_64",
        "old_donkey_64", "old_koopa_gba", "old_heyho_gba"]
    /// The slot a course drives in when no ghost picks one: Luigi Circuit, the usual custom-track slot.
    static let defaultCourse = 8

    static let characters = ["Mario", "Baby Peach", "Waluigi", "Bowser", "Baby Daisy", "Dry Bones", "Baby Mario", "Luigi",
        "Toad", "Donkey Kong", "Yoshi", "Wario", "Baby Luigi", "Toadette", "Koopa Troopa", "Daisy", "Peach", "Birdo",
        "Diddy Kong", "King Boo", "Bowser Jr.", "Dry Bowser", "Funky Kong", "Rosalina"]
    static let vehicles = ["Standard Kart S", "Standard Kart M", "Standard Kart L", "Booster Seat", "Classic Dragster",
        "Offroader", "Mini Beast", "Wild Wing", "Flame Flyer", "Cheep Charger", "Super Blooper", "Piranha Prowler",
        "Tiny Titan", "Daytripper", "Jetsetter", "Blue Falcon", "Sprinter", "Honeycoupe", "Standard Bike S",
        "Standard Bike M", "Standard Bike L", "Bullet Bike", "Mach Bike", "Flame Runner", "Bit Bike", "Sugarscoot",
        "Wario Bike", "Quacker", "Zip Zip", "Shooting Star", "Magikruiser", "Sneakster", "Spear", "Jet Bubble",
        "Dolphin Dasher", "Phantom"]

    /// Ghost header: the course ID (0x07, upper six bits).
    static func ghostCourse(_ rkg: Data) -> Int? {
        guard rkg.count > 0x88, rkg.prefix(4) == Data("RKGD".utf8) else { return nil }
        return Int(rkg[rkg.startIndex + 7] >> 2)
    }

    private let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private var buffer = Data()
    /// Course objects the engine has moved (GOBJ index -> position, in course units).
    private(set) var objectPositions: [Int: SIMD3<Float>] = [:]
    /// Course units per engine unit (1 for Mario Kart Wii; a Double Dash course drives scaled up).
    let unitScale: Float
    private(set) var stopped: String?

    /// `course`: the track as a Mario Kart Wii .szs (needs `course.kmp` and `course.kcl`).
    init(course: Data, racer: Racer, unitScale: Float = 1, commonSZS: Data) throws {
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "kinoko-drive") else { throw DriveError.noHelper }
        self.unitScale = unitScale
        var courseID = Self.defaultCourse
        var args: [String]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kinoko-\(UUID().uuidString)")
        let courseDir = root.appendingPathComponent("Race/Course")
        try FileManager.default.createDirectory(at: courseDir, withIntermediateDirectories: true)
        try commonSZS.write(to: root.appendingPathComponent("Race/Common.szs"))
        switch racer {
        case .live(let character, let vehicle, let autoDrift):
            args = ["\(courseID)", "\(character)", "\(vehicle)", autoDrift ? "1" : "0"]
        case .ghost(let rkg):
            guard let id = Self.ghostCourse(rkg), id < Self.courseNames.count else { throw DriveError.badGhost }
            courseID = id
            let ghostURL = root.appendingPathComponent("ghost.rkg")
            try rkg.write(to: ghostURL)
            args = ["\(courseID)", "0", "0", "0", ghostURL.path]
        }
        try course.write(to: courseDir.appendingPathComponent(Self.courseNames[courseID] + ".szs"))
        process.executableURL = helper
        process.arguments = args
        process.environment = ["KINOKO_FILESYSTEM_ROOT": root.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { _ in try? FileManager.default.removeItem(at: root) }
        try process.run()
    }

    deinit { if process.isRunning { process.terminate() } }

    /// Runs one game frame. Nil once the engine has stopped (see `stopped`).
    func step(_ pad: Input = Input()) -> State? {
        guard stopped == nil else { return nil }
        let buttons = (pad.accelerate ? 1 : 0) | (pad.brake ? 2 : 0)
        let line = "\(buttons) \(pad.stick.x) \(pad.stick.y) \(pad.trick)\n"
        do { try input.fileHandleForWriting.write(contentsOf: Data(line.utf8)) } catch { return stop() }
        while true {
            guard let line = nextLine() else { return stop() }
            let f = line.split(separator: " ")
            if f.first == "o", f.count == 5, let i = Int(f[1]), let x = Float(f[2]), let y = Float(f[3]), let z = Float(f[4]) {
                objectPositions[i] = SIMD3(x, y, z) / unitScale
            } else if f.first == "k", f.count == 15 {
                let n = f.dropFirst().map { Float($0) ?? 0 }
                let flags = Int(n[13])
                return State(position: SIMD3(n[0], n[1], n[2]) / unitScale, rotation: simd_quatf(ix: n[3], iy: n[4], iz: n[5], r: n[6]),
                             speed: n[7] / unitScale, stage: min(Int(n[8]), 3), lap: Int(n[9]), checkpoint: Int(n[10]),
                             respawnPoint: Int(n[11]), raceMs: Int(n[12]), inRespawn: flags & 1 != 0, inCannon: flags & 2 != 0,
                             onGround: flags & 4 != 0, wrongWay: flags & 8 != 0)
            }
        }
    }

    private func nextLine() -> String? {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...nl)
                return line
            }
            let more = output.fileHandleForReading.availableData
            if more.isEmpty { return nil }
            buffer.append(more)
        }
    }

    private func stop() -> State? {
        process.waitUntilExit()
        let message = String(decoding: errors.fileHandleForReading.availableData, as: UTF8.self)
            .split(separator: "\n").last.map(String.init) ?? ""
        stopped = message.isEmpty ? "The physics engine stopped." : "The physics engine stopped: \(message)"
        return nil
    }

    // MARK: Game files

    private static let commonLock = NSLock()
    private static var commonCache: (iso: String, data: Data)?

    /// `Race/Common.szs` from the linked disc (slow the first time; call off the main thread).
    static func commonSZS(commonKey: [UInt8]?) throws -> Data {
        guard let iso = BaseGameLibrary.linkedISO, let commonKey else { throw DriveError.noDisc }
        commonLock.lock(); defer { commonLock.unlock() }
        if let commonCache, commonCache.iso == iso.path { return commonCache.data }
        let disc = try WiiDisc(url: iso, commonKey: commonKey, koreanKey: nil)
        guard let data = BaseGameLibrary.file(at: "Race/Common.szs", on: disc) else { throw DriveError.noCommon }
        commonCache = (iso.path, data)
        return data
    }
}
