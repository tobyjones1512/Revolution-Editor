import Foundation

/// Mario Kart Wii's track-data format: start points, AI/item paths, checkpoints, objects,
/// cameras, areas, and stage info. Structure per the publicly documented format (tockdom wiki,
/// "KMP (File Format)"); this is a from-scratch, best-effort reimplementation, section layouts
/// have been stable and widely relied-on by the modding community for well over a decade, but a
/// few rarely-touched byte-level fields are annotated as approximate below.
///
/// All 15 sections always exist in a real KMP, in this fixed canonical order.
nonisolated enum KMPSection: Int, CaseIterable {
    case ktpt, enpt, enph, itpt, itph, ckpt, ckph, gobj, poti, area, came, jgpt, cnpt, mspt, stgi

    var magic: String {
        switch self {
        case .ktpt: return "KTPT"
        case .enpt: return "ENPT"
        case .enph: return "ENPH"
        case .itpt: return "ITPT"
        case .itph: return "ITPH"
        case .ckpt: return "CKPT"
        case .ckph: return "CKPH"
        case .gobj: return "GOBJ"
        case .poti: return "POTI"
        case .area: return "AREA"
        case .came: return "CAME"
        case .jgpt: return "JGPT"
        case .cnpt: return "CNPT"
        case .mspt: return "MSPT"
        case .stgi: return "STGI"
        }
    }

    /// Human-readable name for this section, used anywhere points are listed in the UI.
    var displayName: String {
        switch self {
        case .ktpt: return "Start Point"
        case .enpt: return "Enemy Point"
        case .enph: return "Enemy Path"
        case .itpt: return "Item Point"
        case .itph: return "Item Path"
        case .ckpt: return "Checkpoint"
        case .ckph: return "Checkpoint Path"
        case .gobj: return "Object"
        case .poti: return "Route"
        case .area: return "Area"
        case .came: return "Camera"
        case .jgpt: return "Respawn Point"
        case .cnpt: return "Cannon Point"
        case .mspt: return "Battle Respawn Point"
        case .stgi: return "Stage Info"
        }
    }

    /// A one- or two-sentence, no-jargon explanation of what this section actually does in-game --
    /// shown as a tooltip everywhere the section's abbreviation appears in the UI, since the
    /// four-letter tags (real KMP-tool convention, kept as the primary label above) mean nothing to
    /// someone modding their first track.
    var tooltip: String {
        switch self {
        case .ktpt: return "Where racers line up at the start of a race. Usually 1 entry per player slot (up to 12), though some tracks reuse fewer."
        case .enpt: return "\"Enemy\" points: the path CPU (computer) racers drive along. Also used by lakitu to judge if a player is going the wrong way. Radius controls how tightly CPUs can cut the point."
        case .enph: return "Groups ENPT points into one or more connected paths, so CPUs know which point follows which, tracks with forks/shortcuts need multiple linked groups."
        case .itpt: return "The path CPU racers follow when deciding where to throw/aim held items (shells, bananas, etc.), separate from the ENPT driving line."
        case .itph: return "Groups ITPT points into connected paths, same idea as ENPH but for the item-aiming line."
        case .ckpt: return "A checkpoint gate (a line from Left to Right) racers must cross in order. Used for lap counting, minimap progress %, and to detect shortcuts/wrong-way driving."
        case .ckph: return "Groups CKPT gates into the checkpoint sequence, forks in the track need more than one group so either path still counts as valid progress."
        case .gobj: return "An object placed on the track: item boxes, enemies (Goombas, Piranha Plants...), decorations, moving platforms, etc. The Object ID picks which one."
        case .poti: return "A path of points some GOBJ objects follow (e.g. a moving platform's route, a Chain Chomp's leash), referenced by object, not shown directly on this canvas."
        case .area: return "An invisible trigger volume: fog changes, camera swaps, forced paths for CPUs, mini-games, etc. What it does depends on its Area Type."
        case .came: return "A camera used for intro/replay shots or special effects (not the normal follow-cam). \"Next\" chains cameras together for a sequence."
        case .jgpt: return "A respawn point used after falling off the track (\"Jugem\" = Lakitu, who carries you back). Checkpoints reference these via Respawn Index."
        case .cnpt: return "A cannon launch point, position, aim direction, and ID (matched to a GOBJ cannon object) for where/how far a player gets launched."
        case .mspt: return "Respawn point used in Battle Mode only (separate from JGPT's race respawns)."
        case .stgi: return "Stage-wide settings: lap count, pole position side, first-place camera behaviour, speed modifier, etc., not an editable point on the canvas."
        }
    }
}

// MARK: Entries

nonisolated struct KTPTEntry: Identifiable { let id = UUID(); var position = Vec3(); var rotation = Vec3(); var playerIndex: Int16 = -1; var bol: Data? = nil }
/// Maps the ENPT/ITPT on-disk "scale" float (section entry offset 0x0C) to this editor's radius in
/// real map units. The game sizes a point's circle by its *diameter*: per the wiki's KMP_Editing
/// tutorial, `scale × 100` = diameter, so the radius the game actually simulates is `scale × 50`
/// (confirmed against retail calibration images, where an ENPT scale of 23 sits on a ~2450-unit
/// road, i.e. radius ~1225, stored as ~24.5). `ENPTEntry.radius` / `ITPTEntry.radius` hold that
/// radius directly, and `parse`/`serialize` convert through this factor. A retail-style default of
/// radius 500 therefore stores a scale of 10, matching stock enemy/item lines.
nonisolated let enptScaleToRadius: Float = 50
nonisolated struct ENPTEntry: Identifiable { let id = UUID(); var position = Vec3(); var radius: Float = 500; var setting1: UInt16 = 0; var setting2: UInt16 = 0; var fileScale: Float? = nil; var bol: Data? = nil }
nonisolated struct PathLinkEntry: Identifiable {
    let id = UUID()
    var startIndex: UInt8 = 0
    var pointCount: UInt8 = 0
    var previousGroups: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
    var nextGroups: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
    /// The entry's last two bytes. Not padding: retail battle arenas set them on ENPH (e.g.
    /// block_battle, casino_battle), so they are carried through untouched.
    var settings: UInt16 = 0
    /// Double Dash only: the original .bol record this came from (see `BOL`).
    var bol: Data? = nil
}
nonisolated struct ITPTEntry: Identifiable { let id = UUID(); var position = Vec3(); var radius: Float = 500; var setting1: UInt16 = 0; var setting2: UInt16 = 0; var fileScale: Float? = nil }

/// The on-disk scale for a point's radius. `radius / 50` doesn't always reproduce the float that
/// was read (it's `scale * 50` rounded), so an unedited point writes back its own original bytes.
nonisolated func kmpScale(radius: Float, fileScale: Float?) -> Float {
    if let fileScale, fileScale * enptScaleToRadius == radius { return fileScale }
    return radius / enptScaleToRadius
}
nonisolated struct CKPTEntry: Identifiable {
    let id = UUID()
    var left = Vec2(); var right = Vec2()
    var respawnIndex: UInt8 = 0
    var lapCounterType: Int8 = -1 // 0xFF = not a lap-counting checkpoint, else key-checkpoint order
    var bol: Data? = nil
    // No `previous`/`next` fields here on purpose: the on-disk bytes are fully determined by
    // this point's position within its CKPH group (see `computeCkptLinks`), storing them
    // separately just invites them to go stale the moment a point is inserted/reordered/moved
    // between groups, since nothing else in the editor ever touches them. `serialize()`
    // recomputes them fresh every time instead.
}
nonisolated struct GOBJEntry: Identifiable {
    let id = UUID()
    var objectID: UInt16 = 0x0065 // Item Box; 0 isn't a real object (see `isRetailObjectID`)
    var position = Vec3(); var rotation = Vec3(); var scale = Vec3(x: 1, y: 1, z: 1)
    var routeID: UInt16 = 0xFFFF
    var settings: [UInt16] = [0, 0, 0, 0, 0, 0, 0, 0]
    var presenceFlags: UInt16 = 0x0F // all game modes by default
    var bol: Data? = nil
}
nonisolated struct RoutePoint: Identifiable { let id = UUID(); var position = Vec3(); var setting1: UInt16 = 0; var setting2: UInt16 = 0; var bol: Data? = nil }
nonisolated struct POTIRoute: Identifiable {
    let id = UUID()
    /// Header byte 2: 0 = straight point-to-point, 1 = smooth curve (freezes the game on a route
    /// of 2 or fewer points). Byte 3: 0 = cyclic, 1 = back and forth. Per the wiki's POTI section
    /// and retail camera routes (smooth only on 3+ points, back-and-forth everywhere).
    var setting1: UInt8 = 0
    var setting2: UInt8 = 0
    var isSmooth: Bool { get { setting1 != 0 } set { setting1 = newValue ? 1 : 0 } }
    var isCyclic: Bool { get { setting2 == 0 } set { setting2 = newValue ? 0 : 1 } }
    var points: [RoutePoint] = []
    var bol: Data? = nil
}
nonisolated struct AREAEntry: Identifiable {
    let id = UUID()
    var shape: UInt8 = 0 // 0 = box, 1 = cylinder
    var type: UInt8 = 0
    var cameraIndex: UInt8 = 0xFF
    var priority: UInt8 = 0
    var position = Vec3(); var rotation = Vec3(); var scale = Vec3(x: 1, y: 1, z: 1)
    var setting1: UInt16 = 0
    var setting2: UInt16 = 0
    var routeID: UInt8 = 0xFF
    var enptID: UInt8 = 0xFF
    var bol: Data? = nil
}
nonisolated struct CAMEEntry: Identifiable {
    let id = UUID()
    var type: UInt8 = 0
    var next: UInt8 = 0xFF
    var shake: UInt8 = 0
    var routeID: UInt8 = 0xFF
    var pointVelocity: UInt16 = 0
    var zoomVelocity: UInt16 = 0
    var viewVelocity: UInt16 = 0
    var startFlag: UInt8 = 0
    var movieFlag: UInt8 = 0
    var position = Vec3(); var rotation = Vec3()
    var zoomStart: Float = 0
    var zoomEnd: Float = 0
    var viewPositionStart = Vec3()
    var viewPositionEnd = Vec3()
    var time: Float = 0
    var bol: Data? = nil
}
nonisolated struct JGPTEntry: Identifiable { let id = UUID(); var position = Vec3(); var rotation = Vec3(); var respawnID: UInt16 = 0; var extra: UInt16 = 0xFFFF; var bol: Data? = nil }
nonisolated struct CNPTEntry: Identifiable { let id = UUID(); var position = Vec3(); var effectVector = Vec3(); var cannonID: UInt16 = 0; var shootEffect: UInt16 = 0 }
nonisolated struct MSPTEntry: Identifiable { let id = UUID(); var position = Vec3(); var rotation = Vec3(); var entryID: UInt16 = 0; var extra: UInt16 = 0 }
nonisolated struct STGIEntry {
    var lapCount: UInt8 = 3
    var polePosition: UInt8 = 0 // 0 = left, 1 = right
    var driverDistance: UInt8 = 0 // 0 = normal, 1 = narrow
    var lensFlareFlag: UInt8 = 0
    /// Bytes 4-7, stored as **A, R, G, B**, every retail course has A = 0 and a light grey or
    /// white RGB (`00 e6 e6 e6`). The flare's visible opacity is `flareTransparency` instead.
    var flareColor: (UInt8, UInt8, UInt8, UInt8) = (0x00, 0xE6, 0xE6, 0xE6)
    /// The lens flare's own alpha/transparency, a real, separate byte from `flareColor`, not
    /// padding (real tracks commonly use 0x32 or 0x4B here). Was previously discarded on parse
    /// and always written back as 0, silently killing the flare effect's intended opacity on any
    /// round-tripped track.
    var flareTransparency: UInt8 = 0x4B
    /// Track-wide speed multiplier, stored as the *upper half of a 32-bit float*, so 0x3F80 is
    /// 1.0 and 0x0000 means "unset", which is what every retail track uses and what the game
    /// treats as normal speed. It is not fixed-point: the old default of 0x0100 decodes to
    /// roughly 1e-38, i.e. a track where nothing can move.
    var speedFactor: UInt16 = 0
}

// MARK: Document

nonisolated final class KMPDocument {
    var ktpt: [KTPTEntry] = []
    var enpt: [ENPTEntry] = []
    var enph: [PathLinkEntry] = []
    var itpt: [ITPTEntry] = []
    var itph: [PathLinkEntry] = []
    var ckpt: [CKPTEntry] = []
    var ckph: [PathLinkEntry] = []
    var gobj: [GOBJEntry] = []
    var poti: [POTIRoute] = []
    var area: [AREAEntry] = []
    var came: [CAMEEntry] = []
    /// The CAME section header's own two bytes (not a per-entry field): which camera starts the
    /// opening pan around the track, and which camera the track-selection menu's preview video
    /// uses (the wiki notes the latter is actually ignored in-game, the preview videos are
    /// pre-rendered, but real KMPs still set it, and Lakitu's opening pan depends on
    /// the former). 0xFF means "none" for both, matching every other "no camera/entry" sentinel
    /// in this format; leaving these at 0 like every other section's unused header bytes would
    /// silently point the opening pan at camera 0 regardless of what it actually is.
    var openingCameraIndex: UInt8 = 0xFF
    var selectionCameraIndex: UInt8 = 0xFF
    var jgpt: [JGPTEntry] = []
    var cnpt: [CNPTEntry] = []
    var mspt: [MSPTEntry] = []
    var stgi = STGIEntry()
    /// Header version and STGI entry size as read. Retail race tracks are 0x9D8 with a 12-byte
    /// STGI entry; older demo KMPs (draw_demo.szs, 0x910) use 8 bytes, written back the same.
    var version: UInt32 = 0x9D8
    var stgiEntrySize = 12
    /// Set when this came from a Mario Kart: Double Dash!! `.bol`, it's then saved back as one
    /// (see `BOL`), and object IDs are Double Dash's.
    var bolSource: BOL.Source?
    var isBOL: Bool { bolSource != nil }

    init() {}

    static func parse(_ data: Data) throws -> KMPDocument {
        if BOL.isBOL(data) { return try BOL.parse(data) }
        guard data.count >= 0x4C, data.asciiString(at: 0, length: 4) == "RKMD" else {
            throw WSError.badStructure("Not a KMP file (missing RKMD magic).")
        }
        let sectionCount = Int(data.be16(8))
        guard sectionCount == 15 else {
            // Retail discs carry a few of these (e.g. old_mario_gc_hayasi.szs): prototype KMPs
            // (version 0x640, 8 sections) left over from development, which the game never loads.
            throw WSError.badStructure("This is a prototype-format KMP (\(sectionCount) sections, version 0x\(String(data.be32(0x0C), radix: 16, uppercase: true))), only the final 15-section Mario Kart Wii format can be edited.")
        }

        // Section offsets are stored relative to the end of the fixed 0x4C-byte header (i.e. to
        // where the first section, KTPT, always begins).
        var offsets: [Int] = []
        for i in 0..<15 { offsets.append(0x4C + Int(data.be32(0x10 + i * 4))) }

        let doc = KMPDocument()
        doc.version = data.be32(0x0C)
        for (i, section) in KMPSection.allCases.enumerated() {
            let off = offsets[i]
            guard off > 0, off < data.count else { continue }
            let magic = data.asciiString(at: off, length: 4)
            guard magic == section.magic else {
                throw WSError.badStructure("KMP section \(i) expected \(section.magic) but found \(magic).")
            }
            let count = Int(data.be16(off + 4))
            let entryBase = off + 8
            switch section {
            case .ktpt:
                for e in 0..<count {
                    let b = entryBase + e * 0x1C
                    doc.ktpt.append(KTPTEntry(position: Vec3(data, at: b), rotation: Vec3(data, at: b + 12), playerIndex: data.beInt16(b + 24)))
                }
            case .enpt:
                for e in 0..<count {
                    let b = entryBase + e * 0x14
                    doc.enpt.append(ENPTEntry(position: Vec3(data, at: b), radius: data.beFloat32(b + 12) * enptScaleToRadius, setting1: data.be16(b + 16), setting2: data.be16(b + 18), fileScale: data.beFloat32(b + 12)))
                }
            case .enph:
                doc.enph = parsePathLinks(data, entryBase: entryBase, count: count)
            case .itpt:
                for e in 0..<count {
                    let b = entryBase + e * 0x14
                    doc.itpt.append(ITPTEntry(position: Vec3(data, at: b), radius: data.beFloat32(b + 12) * enptScaleToRadius, setting1: data.be16(b + 16), setting2: data.be16(b + 18), fileScale: data.beFloat32(b + 12)))
                }
            case .itph:
                doc.itph = parsePathLinks(data, entryBase: entryBase, count: count)
            case .ckpt:
                for e in 0..<count {
                    let b = entryBase + e * 0x14
                    doc.ckpt.append(CKPTEntry(left: Vec2(data, at: b), right: Vec2(data, at: b + 8),
                                               respawnIndex: data.u8(b + 16), lapCounterType: data.beInt8(b + 17)))
                    // Bytes b+18/b+19 (previous/next) are read implicitly by not reading them --
                    // ignored on purpose, see `CKPTEntry`'s doc comment.
                }
            case .ckph:
                doc.ckph = parsePathLinks(data, entryBase: entryBase, count: count)
            case .gobj:
                for e in 0..<count {
                    let b = entryBase + e * 0x3C
                    var settings: [UInt16] = []
                    for s in 0..<8 { settings.append(data.be16(b + 42 + s * 2)) }
                    doc.gobj.append(GOBJEntry(objectID: data.be16(b), position: Vec3(data, at: b + 4),
                                               rotation: Vec3(data, at: b + 16), scale: Vec3(data, at: b + 28),
                                               routeID: data.be16(b + 40), settings: settings, presenceFlags: data.be16(b + 58)))
                }
            case .poti:
                var cursor = entryBase
                for _ in 0..<count {
                    let pointCount = Int(data.be16(cursor))
                    let setting1 = data.u8(cursor + 2)
                    let setting2 = data.u8(cursor + 3)
                    var route = POTIRoute(setting1: setting1, setting2: setting2, points: [])
                    var pb = cursor + 4
                    for _ in 0..<pointCount {
                        route.points.append(RoutePoint(position: Vec3(data, at: pb), setting1: data.be16(pb + 12), setting2: data.be16(pb + 14)))
                        pb += 16
                    }
                    doc.poti.append(route)
                    cursor = pb
                }
            case .area:
                for e in 0..<count {
                    let b = entryBase + e * 0x30
                    doc.area.append(AREAEntry(shape: data.u8(b), type: data.u8(b + 1), cameraIndex: data.u8(b + 2), priority: data.u8(b + 3),
                                               position: Vec3(data, at: b + 4), rotation: Vec3(data, at: b + 16), scale: Vec3(data, at: b + 28),
                                               setting1: data.be16(b + 40), setting2: data.be16(b + 42), routeID: data.u8(b + 44), enptID: data.u8(b + 45)))
                }
            case .came:
                doc.openingCameraIndex = data.u8(off + 6)
                doc.selectionCameraIndex = data.u8(off + 7)
                for e in 0..<count {
                    let b = entryBase + e * 0x48
                    doc.came.append(CAMEEntry(type: data.u8(b), next: data.u8(b + 1), shake: data.u8(b + 2), routeID: data.u8(b + 3),
                                               pointVelocity: data.be16(b + 4), zoomVelocity: data.be16(b + 6), viewVelocity: data.be16(b + 8),
                                               startFlag: data.u8(b + 10), movieFlag: data.u8(b + 11),
                                               position: Vec3(data, at: b + 12), rotation: Vec3(data, at: b + 24),
                                               zoomStart: data.beFloat32(b + 36), zoomEnd: data.beFloat32(b + 40),
                                               viewPositionStart: Vec3(data, at: b + 44), viewPositionEnd: Vec3(data, at: b + 56),
                                               time: data.beFloat32(b + 68)))
                }
            case .jgpt:
                for e in 0..<count {
                    let b = entryBase + e * 0x1C
                    doc.jgpt.append(JGPTEntry(position: Vec3(data, at: b), rotation: Vec3(data, at: b + 12), respawnID: data.be16(b + 24), extra: data.be16(b + 26)))
                }
            case .cnpt:
                for e in 0..<count {
                    let b = entryBase + e * 0x1C
                    doc.cnpt.append(CNPTEntry(position: Vec3(data, at: b), effectVector: Vec3(data, at: b + 12), cannonID: data.be16(b + 24), shootEffect: data.be16(b + 26)))
                }
            case .mspt:
                for e in 0..<count {
                    let b = entryBase + e * 0x1C
                    doc.mspt.append(MSPTEntry(position: Vec3(data, at: b), rotation: Vec3(data, at: b + 12), entryID: data.be16(b + 24), extra: data.be16(b + 26)))
                }
            case .stgi:
                if count > 0 {
                    let b = entryBase
                    let nextSection = offsets.filter { $0 > off }.min() ?? data.count
                    doc.stgiEntrySize = (nextSection - entryBase) / count >= 12 ? 12 : 8
                    doc.stgi = STGIEntry(lapCount: data.u8(b), polePosition: data.u8(b + 1), driverDistance: data.u8(b + 2),
                                          lensFlareFlag: data.u8(b + 3),
                                          flareColor: (data.u8(b + 4), data.u8(b + 5), data.u8(b + 6), data.u8(b + 7)),
                                          flareTransparency: data.u8(b + 8),
                                          speedFactor: data.be16(b + 10))
                }
            }
        }
        return doc
    }

    private static func parsePathLinks(_ data: Data, entryBase: Int, count: Int) -> [PathLinkEntry] {
        var out: [PathLinkEntry] = []
        for e in 0..<count {
            let b = entryBase + e * 0x10
            var prev: [UInt8] = []; var next: [UInt8] = []
            for i in 0..<6 { prev.append(data.u8(b + 2 + i)) }
            for i in 0..<6 { next.append(data.u8(b + 8 + i)) }
            out.append(PathLinkEntry(startIndex: data.u8(b), pointCount: data.u8(b + 1), previousGroups: prev, nextGroups: next,
                                     settings: data.be16(b + 14)))
        }
        return out
    }

    func serialize() -> Data {
        if let bolSource { return BOL.serialize(self, source: bolSource) }
        let w = MutableDataWriter()
        w.putData("RKMD".data(using: .ascii)!)
        w.putU32(0) // file length, patched below
        w.putU16(15)
        w.putU16(0x4C)
        w.putU32(version)
        let offsetTablePos = w.data.count
        for _ in 0..<15 { w.putU32(0) } // patched below

        var offsets: [Int] = Array(repeating: 0, count: 15)

        func writeSection(_ section: KMPSection, count: Int, extra: UInt16 = 0, body: () -> Void) {
            offsets[section.rawValue] = w.data.count
            w.putData(section.magic.data(using: .ascii)!)
            w.putU16(UInt16(count))
            w.putU16(extra)
            body()
        }

        writeSection(.ktpt, count: ktpt.count) {
            for e in ktpt { e.position.write(w); e.rotation.write(w); w.putInt16(e.playerIndex); w.putU16(0) }
        }
        writeSection(.enpt, count: enpt.count) {
            for e in enpt { e.position.write(w); w.putFloat32(kmpScale(radius: e.radius, fileScale: e.fileScale)); w.putU16(e.setting1); w.putU16(e.setting2) }
        }
        writeSection(.enph, count: enph.count) { Self.writePathLinks(enph, w) }
        writeSection(.itpt, count: itpt.count) {
            for e in itpt { e.position.write(w); w.putFloat32(kmpScale(radius: e.radius, fileScale: e.fileScale)); w.putU16(e.setting1); w.putU16(e.setting2) }
        }
        writeSection(.itph, count: itph.count) { Self.writePathLinks(itph, w) }
        writeSection(.ckpt, count: ckpt.count) {
            let links = Self.computeCkptLinks(pointCount: ckpt.count, groups: ckph)
            for (i, e) in ckpt.enumerated() {
                e.left.write(w); e.right.write(w); w.putU8(e.respawnIndex); w.putInt8(e.lapCounterType)
                w.putU8(links[i].previous); w.putU8(links[i].next)
            }
        }
        writeSection(.ckph, count: ckph.count) { Self.writePathLinks(ckph, w) }
        writeSection(.gobj, count: gobj.count) {
            for e in gobj {
                w.putU16(e.objectID); w.putU16(0)
                e.position.write(w); e.rotation.write(w); e.scale.write(w)
                w.putU16(e.routeID)
                for s in e.settings.prefix(8) { w.putU16(s) }
                for _ in e.settings.count..<8 { w.putU16(0) }
                w.putU16(e.presenceFlags)
            }
        }
        let totalPotiPoints = poti.reduce(0) { $0 + $1.points.count }
        writeSection(.poti, count: poti.count, extra: UInt16(min(totalPotiPoints, 0xFFFF))) {
            for route in poti {
                w.putU16(UInt16(route.points.count))
                w.putU8(route.setting1)
                w.putU8(route.setting2)
                for p in route.points { p.position.write(w); w.putU16(p.setting1); w.putU16(p.setting2) }
            }
        }
        writeSection(.area, count: area.count) {
            for e in area {
                w.putU8(e.shape); w.putU8(e.type); w.putU8(e.cameraIndex); w.putU8(e.priority)
                e.position.write(w); e.rotation.write(w); e.scale.write(w)
                w.putU16(e.setting1); w.putU16(e.setting2); w.putU8(e.routeID); w.putU8(e.enptID)
                w.putU16(0)
            }
        }
        // An opening-pan camera index of 0xFF with cameras actually present is what makes the game
        // read past the end of the camera array during a track's intro, so it is pinned to a real
        // camera here rather than written out as-is. With no cameras at all, 0xFF is correct.
        let openingIndex = came.isEmpty ? 0xFF : (Int(openingCameraIndex) < came.count ? openingCameraIndex : 0)
        // 0xFF ("none") is a real value here, retail ending_demo uses it with 19 cameras.
        let selectionIndex = came.isEmpty || Int(selectionCameraIndex) >= came.count ? 0xFF : selectionCameraIndex
        writeSection(.came, count: came.count, extra: UInt16(openingIndex) << 8 | UInt16(selectionIndex)) {
            for e in came {
                w.putU8(e.type); w.putU8(e.next); w.putU8(e.shake); w.putU8(e.routeID)
                w.putU16(e.pointVelocity); w.putU16(e.zoomVelocity); w.putU16(e.viewVelocity)
                w.putU8(e.startFlag); w.putU8(e.movieFlag)
                e.position.write(w); e.rotation.write(w)
                w.putFloat32(e.zoomStart); w.putFloat32(e.zoomEnd)
                e.viewPositionStart.write(w); e.viewPositionEnd.write(w)
                w.putFloat32(e.time)
            }
        }
        writeSection(.jgpt, count: jgpt.count) {
            // The ID is always written as the point's index: checkpoints find their respawn point
            // by this number, every retail course numbers them 0, 1, 2..., and an editor-added
            // point otherwise kept a stale/zero ID, a Lakitu respawn then found no point.
            for (i, e) in jgpt.enumerated() { e.position.write(w); e.rotation.write(w); w.putU16(UInt16(i)); w.putU16(e.extra) }
        }
        writeSection(.cnpt, count: cnpt.count) {
            // IDs are written as the index, as on every retail course (see the JGPT note above).
            for (i, e) in cnpt.enumerated() { e.position.write(w); e.effectVector.write(w); w.putU16(UInt16(i)); w.putU16(e.shootEffect) }
        }
        writeSection(.mspt, count: mspt.count) {
            for (i, e) in mspt.enumerated() { e.position.write(w); e.rotation.write(w); w.putU16(UInt16(i)); w.putU16(e.extra) }
        }
        writeSection(.stgi, count: 1) {
            w.putU8(stgi.lapCount); w.putU8(stgi.polePosition); w.putU8(stgi.driverDistance); w.putU8(stgi.lensFlareFlag)
            w.putU8(stgi.flareColor.0); w.putU8(stgi.flareColor.1); w.putU8(stgi.flareColor.2); w.putU8(stgi.flareColor.3)
            if stgiEntrySize >= 12 {
                w.putU8(stgi.flareTransparency); w.putU8(0)
                w.putU16(stgi.speedFactor)
            }
        }

        var final = w.data
        final.replaceSubrange(4..<8, with: withUnsafeBytes(of: UInt32(final.count).bigEndian) { Data($0) })
        for i in 0..<15 {
            let off = offsetTablePos + i * 4
            let value = UInt32(offsets[i] - 0x4C) // relative to the end of the header, matching parse()
            final.replaceSubrange(off..<(off + 4), with: withUnsafeBytes(of: value.bigEndian) { Data($0) })
        }
        return final
    }

    /// Every CKPT point's previous/next byte, purely as a function of where it sits in its CKPH
    /// group, the first point of a group has no previous (0xFF), the last has no next, and
    /// every point in between just links to its array-index neighbors. A point not covered by any
    /// group (shouldn't normally happen, but the array and group ranges are edited independently)
    /// gets 0xFF/0xFF, matching "not part of a path".
    private static func computeCkptLinks(pointCount: Int, groups: [PathLinkEntry]) -> [(previous: UInt8, next: UInt8)] {
        var links = Array(repeating: (previous: UInt8(0xFF), next: UInt8(0xFF)), count: pointCount)
        for group in groups {
            let start = Int(group.startIndex), count = Int(group.pointCount)
            guard count > 0 else { continue }
            for offset in 0..<count {
                let i = start + offset
                guard links.indices.contains(i) else { continue }
                links[i] = (previous: offset == 0 ? 0xFF : UInt8(i - 1), next: offset == count - 1 ? 0xFF : UInt8(i + 1))
            }
        }
        return links
    }

    private static func writePathLinks(_ links: [PathLinkEntry], _ w: MutableDataWriter) {
        for e in links {
            w.putU8(e.startIndex); w.putU8(e.pointCount)
            for i in 0..<6 { w.putU8(i < e.previousGroups.count ? e.previousGroups[i] : 0xFF) }
            for i in 0..<6 { w.putU8(i < e.nextGroups.count ? e.nextGroups[i] : 0xFF) }
            w.putU16(e.settings)
        }
    }
}
