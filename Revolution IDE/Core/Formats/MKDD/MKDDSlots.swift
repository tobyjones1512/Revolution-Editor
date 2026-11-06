import Foundation

/// Mario Kart: Double Dash!! course slots and the per-slot data a custom course has to fit.
///
/// A course lives in `Course/<Archive>.arc` (single player) and `Course/<Archive>L.arc`
/// (multiplayer), RARC archives whose root folder is the lower-case prefix (plus "l" for the
/// multiplayer one) and whose files are all named `<prefix>_...`: `_course.bmd` (model),
/// `_course.bco` (collision), `_course.bol` (course data), `_map.bti` (minimap), and optionally
/// `_sky.bmd` and animations. Luigi Circuit's 150cc slot is `Luigi2.arc` but still uses "luigi_".
///
/// The minimap's world rectangle and orientation aren't in the archive at all: they're hardcoded
/// per slot in `main.dol`. Addresses (virtual, per region) are mkdd-track-patcher's
/// (RenolY2/mkdd-track-patcher, `minimap_locations.json`), four floats (corner 1 X/Z, corner 2
/// X/Z) and an `li r0, n` holding the orientation 0-3. Reading them from the player's own disc
/// lets a custom course's minimap image be drawn to fit the slot it replaces.
nonisolated enum MKDDSlots {
    struct Slot: Identifiable, Hashable {
        let title: String
        let archive: String
        let prefix: String
        let battle: Bool
        /// Region -> (corner1X, corner1Z, corner2X, corner2Z, orientation instruction) addresses.
        let minimap: [String: [UInt32]]
        var id: String { archive }
        var fileStem: String { prefix == "luigi2" ? "luigi" : prefix }
        /// The slot's retail music ID (course data header byte 0x19), read off the retail disc.
        var musicID: UInt8 {
            ["BabyLuigi": 0x21, "Peach": 0x22, "Daisy": 0x23, "Luigi2": 0x24, "Mario": 0x25, "Yoshi": 0x26, "Nokonoko": 0x28,
             "Patapata": 0x29, "Waluigi": 0x2A, "Wario": 0x2B, "Diddy": 0x2C, "Donkey": 0x2D, "Koopa": 0x2F, "Rainbow": 0x31,
             "Desert": 0x32, "Snow": 0x33, "Mini1": 0x34, "Mini2": 0x35, "Mini3": 0x36, "Mini5": 0x38, "Mini7": 0x3A, "Mini8": 0x3B][archive] ?? 0x21
        }
        /// Every archive this slot loads from: Luigi Circuit's 50cc race uses Luigi.arc, the
        /// other classes Luigi2.arc, both with "luigi_" files, replacing the course means both.
        var archives: [(name: String, root: String)] {
            var a = [(archive + ".arc", prefix), (archive + "L.arc", prefix + "l")]
            if archive == "Luigi2" { a += [("Luigi.arc", "luigi"), ("LuigiL.arc", "luigil")] }
            return a
        }
    }

    struct Minimap: Equatable {
        var corner1: Vec2
        var corner2: Vec2
        /// 0-3: quarter turns of the image.
        var orientation: Int
    }

    static let slots: [Slot] = [
        slot("Baby Park", "BabyLuigi", "babyluigi", us: [0x803CDDEC, 0x803CDDF0, 0x803CDDF4, 0x803CDDF8, 0x80141E14], pal: [0x803D7C2C, 0x803D7C30, 0x803D7C34, 0x803D7C38, 0x80141E44], jp: [0x803E840C, 0x803E8410, 0x803E8414, 0x803E8418, 0x80141E14]),
        slot("Peach Beach", "Peach", "peach", us: [0x803CDE0C, 0x803CDE10, 0x803CDE14, 0x803CDE18, 0x80141EE0], pal: [0x803D7C4C, 0x803D7C50, 0x803D7C54, 0x803D7C58, 0x80141F10], jp: [0x803E842C, 0x803E8430, 0x803E8434, 0x803E8438, 0x80141EE0]),
        slot("Daisy Cruiser", "Daisy", "daisy", us: [0x803CDE34, 0x803CDE38, 0x803CDE3C, 0x803CDE40, 0x8014200C], pal: [0x803D7C74, 0x803D7C78, 0x803D7C7C, 0x803D7C80, 0x8014203C], jp: [0x803E8454, 0x803E8458, 0x803E845C, 0x803E8460, 0x8014200C]),
        slot("Luigi Circuit", "Luigi2", "luigi2", us: [0x803CDE5C, 0x803CDE60, 0x803CDE64, 0x803CDE68, 0x801420D8], pal: [0x803D7C9C, 0x803D7CA0, 0x803D7CA4, 0x803D7CA8, 0x80142108], jp: [0x803E847C, 0x803E8480, 0x803E8484, 0x803E8488, 0x801420D8]),
        slot("Mario Circuit", "Mario", "mario", us: [0x803CDE74, 0x803CDE78, 0x803CDE7C, 0x803CDE80, 0x801421A4], pal: [0x803D7CB4, 0x803D7CB8, 0x803D7CBC, 0x803D7CC0, 0x801421D4], jp: [0x803E8494, 0x803E8498, 0x803E849C, 0x803E84A0, 0x801421A4]),
        slot("Yoshi Circuit", "Yoshi", "yoshi", us: [0x803CDE90, 0x803CDE94, 0x803CDE98, 0x803CDE9C, 0x80142270], pal: [0x803D7CD0, 0x803D7CD4, 0x803D7CD8, 0x803D7CDC, 0x801422A0], jp: [0x803E84B0, 0x803E84B4, 0x803E84B8, 0x803E84BC, 0x80142270]),
        slot("Mushroom Bridge", "Nokonoko", "nokonoko", us: [0x803CDEB0, 0x803CDEB4, 0x803CDEB8, 0x803CDEBC, 0x8014233C], pal: [0x803D7CF0, 0x803D7CF4, 0x803D7CF8, 0x803D7CFC, 0x8014236C], jp: [0x803E84D0, 0x803E84D4, 0x803E84D8, 0x803E84DC, 0x8014233C]),
        slot("Mushroom City", "Patapata", "patapata", us: [0x803CDEC8, 0x803CDECC, 0x803CDED0, 0x803CDED4, 0x80142408], pal: [0x803D7D08, 0x803D7D0C, 0x803D7D10, 0x803D7D14, 0x80142438], jp: [0x803E84E8, 0x803E84EC, 0x803E84F0, 0x803E84F4, 0x80142408]),
        slot("Waluigi Stadium", "Waluigi", "waluigi", us: [0x803CDEE8, 0x803CDEEC, 0x803CDEF0, 0x803CDEF4, 0x801424D4], pal: [0x803D7D28, 0x803D7D2C, 0x803D7D30, 0x803D7D34, 0x80142504], jp: [0x803E8508, 0x803E850C, 0x803E8510, 0x803E8514, 0x801424D4]),
        slot("Wario Colosseum", "Wario", "wario", us: [0x803CDF0C, 0x803CDF10, 0x803CDF14, 0x803CDF18, 0x801425A0], pal: [0x803D7D4C, 0x803D7D50, 0x803D7D54, 0x803D7D58, 0x801425D0], jp: [0x803E852C, 0x803E8530, 0x803E8534, 0x803E8538, 0x801425A0]),
        slot("Dino Dino Jungle", "Diddy", "diddy", us: [0x803CDF28, 0x803CDF2C, 0x803CDF30, 0x803CDF34, 0x8014266C], pal: [0x803D7D68, 0x803D7D6C, 0x803D7D70, 0x803D7D74, 0x8014269C], jp: [0x803E8548, 0x803E854C, 0x803E8550, 0x803E8554, 0x8014266C]),
        slot("DK Mountain", "Donkey", "donkey", us: [0x803CDF40, 0x803CDF44, 0x803CDF48, 0x803CDF4C, 0x80142738], pal: [0x803D7D80, 0x803D7D84, 0x803D7D88, 0x803D7D8C, 0x80142768], jp: [0x803E8560, 0x803E8564, 0x803E8568, 0x803E856C, 0x80142738]),
        slot("Bowser's Castle", "Koopa", "koopa", us: [0x803CDF5C, 0x803CDF60, 0x803CDF64, 0x803CDF68, 0x80142804], pal: [0x803D7D9C, 0x803D7DA0, 0x803D7DA4, 0x803D7DA8, 0x80142834], jp: [0x803E857C, 0x803E8580, 0x803E8584, 0x803E8588, 0x80142804]),
        slot("Rainbow Road", "Rainbow", "rainbow", us: [0x803CDF70, 0x803CDF74, 0x803CDF78, 0x803CDF7C, 0x801428D0], pal: [0x803D7DB0, 0x803D7DB4, 0x803D7DB8, 0x803D7DBC, 0x80142900], jp: [0x803E8590, 0x803E8594, 0x803E8598, 0x803E859C, 0x801428D0]),
        slot("Dry Dry Desert", "Desert", "desert", us: [0x803CDF84, 0x803CDF88, 0x803CDF8C, 0x803CDF90, 0x8014299C], pal: [0x803D7DC4, 0x803D7DC8, 0x803D7DCC, 0x803D7DD0, 0x801429CC], jp: [0x803E85A4, 0x803E85A8, 0x803E85AC, 0x803E85B0, 0x8014299C]),
        slot("Sherbet Land", "Snow", "snow", us: [0x803CDFA4, 0x803CDFA8, 0x803CDFAC, 0x803CDFB0, 0x80142A68], pal: [0x803D7DE4, 0x803D7DE8, 0x803D7DEC, 0x803D7DF0, 0x80142A98], jp: [0x803E85C4, 0x803E85C8, 0x803E85CC, 0x803E85D0, 0x80142A68]),
        slot("Luigi's Mansion", "Mini1", "mini1", battle: true, us: [0x803CDFB4, 0x803CDFB8, 0x803CDFBC, 0x803CDFC0, 0x80142B34], pal: [0x803D7DF4, 0x803D7DF8, 0x803D7DFC, 0x803D7E00, 0x80142B64], jp: [0x803E85D4, 0x803E85D8, 0x803E85DC, 0x803E85E0, 0x80142B34]),
        slot("Nintendo GameCube", "Mini2", "mini2", battle: true, us: [0x803CDFC4, 0x803CDFC8, 0x803CDFCC, 0x803CDFD0, 0x80142B6C], pal: [0x803D7E04, 0x803D7E08, 0x803D7E0C, 0x803D7E10, 0x80142B9C], jp: [0x803E85E4, 0x803E85E8, 0x803E85EC, 0x803E85F0, 0x80142B6C]),
        slot("Block City", "Mini3", "mini3", battle: true, us: [0x803CDFD4, 0x803CDFD8, 0x803CDFDC, 0x803CDFE0, 0x80142BA4], pal: [0x803D7E14, 0x803D7E18, 0x803D7E1C, 0x803D7E20, 0x80142BD4], jp: [0x803E85F4, 0x803E85F8, 0x803E85FC, 0x803E8600, 0x80142BA4]),
        slot("Tilt-a-Kart", "Mini5", "mini5", battle: true, us: [0x803CDFE4, 0x803CDFE8, 0x803CDFEC, 0x803CDFF0, 0x80142BDC], pal: [0x803D7E24, 0x803D7E28, 0x803D7E2C, 0x803D7E30, 0x80142C0C], jp: [0x803E8604, 0x803E8608, 0x803E860C, 0x803E8610, 0x80142BDC]),
        slot("Cookie Land", "Mini7", "mini7", battle: true, us: [0x803CDFF4, 0x803CDFF8, 0x803CDFFC, 0x803CE000, 0x80142C14], pal: [0x803D7E34, 0x803D7E38, 0x803D7E3C, 0x803D7E40, 0x80142C44], jp: [0x803E8614, 0x803E8618, 0x803E861C, 0x803E8620, 0x80142C14]),
        // Pipe Plaza shares Tilt-a-Kart's corner floats in retail.
        slot("Pipe Plaza", "Mini8", "mini8", battle: true, us: [0x803CDFE4, 0x803CDFE8, 0x803CDFEC, 0x803CDFF0, 0x80142C4C], pal: [0x803D7E24, 0x803D7E28, 0x803D7E2C, 0x803D7E30, 0x80142C7C], jp: [0x803E8604, 0x803E8608, 0x803E860C, 0x803E8610, 0x80142C4C]),
    ]

    private static func slot(_ title: String, _ archive: String, _ prefix: String, battle: Bool = false, us: [UInt32], pal: [UInt32], jp: [UInt32]) -> Slot {
        Slot(title: title, archive: archive, prefix: prefix, battle: battle, minimap: ["US": us, "PAL": pal, "JP": jp])
    }

    /// The slot an archive's root folder name belongs to ("luigi2", "luigi2l", "luigi" ...).
    static func slot(forRoot name: String) -> Slot? {
        slots.first { s in s.archives.contains { $0.root == name } }
    }

    static func slot(forArchive name: String) -> Slot? {
        let base = (name as NSString).deletingPathExtension
        return slots.first { $0.archive == base || $0.archive + "L" == base } ?? (base == "Luigi" || base == "LuigiL" ? slots.first { $0.archive == "Luigi2" } : nil)
    }

    /// Game ID (from the disc header) -> region key used by `Slot.minimap`.
    static func region(gameID: String) -> String? {
        guard gameID.hasPrefix("GM4") else { return nil }
        switch gameID.dropFirst(3).first {
        case "E": return "US"
        case "P": return "PAL"
        case "J": return "JP"
        default: return nil
        }
    }

    // MARK: main.dol

    /// The slot's minimap rectangle and orientation, read from a Double Dash `main.dol`.
    static func minimap(for slot: Slot, dol: Data, region: String) -> Minimap? {
        guard let a = slot.minimap[region], a.count == 5,
              let x1 = dolFloat(dol, a[0]), let z1 = dolFloat(dol, a[1]), let x2 = dolFloat(dol, a[2]), let z2 = dolFloat(dol, a[3]),
              let li = dolWord(dol, a[4]), li >> 16 == 0x3800 else { return nil }
        let orientation = Int(Int16(bitPattern: UInt16(li & 0xFFFF)))
        guard (0...3).contains(orientation) else { return nil }
        return Minimap(corner1: Vec2(x: x1, y: z1), corner2: Vec2(x: x2, y: z2), orientation: orientation)
    }

    /// `main.dol` from a GameCube disc image: its offset is at 0x420, its size from its sections.
    static func dol(fromDisc url: URL) throws -> Data {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        try h.seek(toOffset: 0x420)
        guard let o = h.readData(ofLength: 4) as Data?, o.count == 4 else { throw WSError.badStructure("Couldn't read the disc header.") }
        let offset = UInt64(o.be32(0))
        try h.seek(toOffset: offset)
        let header = h.readData(ofLength: 0x100)
        guard header.count == 0x100 else { throw WSError.badStructure("Couldn't read main.dol.") }
        var end = 0
        for i in 0..<18 { end = max(end, Int(header.be32(i * 4)) + Int(header.be32(0x90 + i * 4))) }
        try h.seek(toOffset: offset)
        return h.readData(ofLength: end)
    }

    private static func dolOffset(_ dol: Data, _ address: UInt32) -> Int? {
        guard dol.count >= 0x100 else { return nil }
        for i in 0..<18 {
            let off = dol.be32(i * 4), addr = dol.be32(0x48 + i * 4), size = dol.be32(0x90 + i * 4)
            guard off != 0, address >= addr, address < addr &+ size else { continue }
            let o = Int(off + (address - addr))
            return o + 4 <= dol.count ? o : nil
        }
        return nil
    }
    private static func dolWord(_ dol: Data, _ address: UInt32) -> UInt32? { dolOffset(dol, address).map { dol.be32($0) } }
    private static func dolFloat(_ dol: Data, _ address: UInt32) -> Float? { dolWord(dol, address).map { Float(bitPattern: $0) } }
}
