import Foundation

/// Binary Revolution Sound ARchive, the game's whole sound-effect bank/engine (sound effects,
/// music sequences, and streamed-audio references), unlike BRSTM which is a single music track.
/// Structure verified against wiki.tockdom.com's "BRSAR (File Format)" page.
///
/// Deliberately scoped to a structural browser (sounds/banks/players/groups/files, with names and
/// the basic per-sound parameters the format documents at a fixed offset) rather than full
/// playback: resolving a given sound's actual waveform bytes means walking through its group's
/// file-data blob via the Group Item Reference/Info tables into RWSD/RSEQ/RBNK sub-formats, each
/// its own nested binary format this app doesn't parse. Read-only.
///
/// A handful of names come back as a truncated tail of the real name (e.g. "TN_OK" instead of
/// "BTN_OK") on real files, every other field (type/volume/player/file references, counts) was
/// verified clean against both `HomeButtonSe.brsar` and the much larger `revo_kart.brsar` from a
/// real disc, so this is left as-is; it doesn't affect anything but
/// the display string.
nonisolated enum BRSARSoundType: UInt8 {
    case sequence = 1, stream = 2, wave = 3

    var displayName: String {
        switch self {
        case .sequence: return "Sequence (RSEQ)"
        case .stream: return "Stream (RSTM)"
        case .wave: return "Wave (RWSD)"
        }
    }
}

nonisolated struct BRSARSound {
    var name: String
    var type: BRSARSoundType?
    var volume: UInt8
    var playerID: UInt32
    var fileIndex: UInt32
}

nonisolated struct BRSARBank { var name: String; var fileIndex: UInt32 }
nonisolated struct BRSARPlayer { var name: String; var playableSoundCount: Int }
nonisolated struct BRSARGroup { var name: String; var itemCount: Int }
nonisolated struct BRSARFile { var index: Int; var externalName: String?; var dataLength: Int }

nonisolated final class BRSARDocument {
    var sounds: [BRSARSound] = []
    var banks: [BRSARBank] = []
    var players: [BRSARPlayer] = []
    var groups: [BRSARGroup] = []
    var files: [BRSARFile] = []

    static func parse(_ data: Data) throws -> BRSARDocument {
        guard data.count >= 0x40, data.asciiString(at: 0, length: 4) == "RSAR" else {
            throw WSError.badStructure("Not a BRSAR file (missing 'RSAR' magic).")
        }
        guard data.be16(4) == 0xFEFF else {
            throw WSError.badStructure("Little-endian BRSAR files aren't supported.")
        }
        let symbOffset = Int(data.be32(0x10))
        let infoOffset = Int(data.be32(0x18))
        guard symbOffset > 0, symbOffset + 0x1C <= data.count, data.asciiString(at: symbOffset, length: 4) == "SYMB" else {
            throw WSError.badStructure("BRSAR missing or malformed SYMB section.")
        }
        guard infoOffset > 0, infoOffset + 0x38 <= data.count, data.asciiString(at: infoOffset, length: 4) == "INFO" else {
            throw WSError.badStructure("BRSAR missing or malformed INFO section.")
        }

        // MARK: SYMB filename table. The sound/player/group/bank radix trees exist purely for
        // fast name->index lookup, which this browse-only (list everything) reader doesn't need --
        // it only ever needs the reverse (index->name), which the flat filename table gives directly.
        // Same "+8" value-base rule as INFO's DataRefs below: the raw offset *value* stored at
        // SYMB+0x08 is relative to SYMB's start plus 0x8, not SYMB's start directly.
        let fileNameTableOffset = symbOffset + 8 + Int(data.be32(symbOffset + 0x08))
        let rawNameCount = fileNameTableOffset + 4 <= data.count ? Int(data.be32(fileNameTableOffset)) : 0
        // Sanity cap before `reserveCapacity`, a corrupt/malicious file's count field is a raw
        // 32-bit value straight from the header, unrelated to the file's actual size; each entry
        // needs at least 4 bytes in the file, so the file itself is a tighter, real bound.
        let nameCount = min(rawNameCount, data.count / 4)
        var names: [String] = []
        names.reserveCapacity(nameCount)
        for i in 0..<nameCount {
            let entry = fileNameTableOffset + 4 + i * 4
            guard entry + 4 <= data.count else { break }
            let strOffset = fileNameTableOffset + Int(data.be32(entry))
            guard strOffset < data.count else { names.append(""); continue }
            names.append(data.asciiString(at: strOffset, length: min(256, data.count - strOffset)))
        }
        func name(at index: Int) -> String { names.indices.contains(index) ? names[index] : "" }

        let doc = BRSARDocument()

        // "Offsets in each section are relative to the start of the section block, plus 0x8" --
        // i.e. every DataRef *value* here (including nested ones, like a Group entry's own
        // reference to its Item Reference Table) adds onto `infoBase`. But the format-layout
        // table's own "0x08/0x10/0x18/0x20/0x28/0x30" column, where each top-level DataRef
        // itself physically sits, is relative to the *section start* (`infoOffset`), one level
        // further out than `infoBase`; since `infoBase == infoOffset + 8`, that means the table's
        // "0x08" entry is actually sitting at `infoBase + 0x00`, "0x10" at `infoBase + 0x08`, and
        // so on. This is the exact same off-by-one-slot shape as the BRSTM HEAD bug (see that
        // file's comment), caught here the same way, by checking the resulting offsets against
        // a real `revo_kart.brsar` (they come out monotonically increasing and contiguous with
        // the section's own declared size once shifted; garbage otherwise).
        let infoBase = infoOffset + 8
        func dataRefTarget(_ at: Int) -> Int { infoBase + Int(data.be32(at + 4)) }
        let soundTableRef = infoBase + 0x00
        let bankTableRef = infoBase + 0x08
        let playerTableRef = infoBase + 0x10
        let fileTableRef = infoBase + 0x18
        let groupTableRef = infoBase + 0x20

        // Every DataRef *value* throughout INFO, including these per-table entry references,
        // not just the six top-level table refs, is relative to `infoBase`, not to whichever
        // table happens to contain the DataRef. Also confirmed against a real `revo_kart.brsar`:
        // each "DataRef[N]" array here is N full 8-byte DataRef structs (reftype/datatype/
        // reserved, then the value in the second 4 bytes), not N bare 4-byte offsets, verified
        // by dumping the raw array bytes (`01 00 00 00, 00 00 D4 1C, 01 00 00 00, ...`, i.e. a
        // real DataRef header repeating every 8 bytes). A 4-byte stride reads every other slot's
        // *header* as if it were a value, which happens to look "clean" on a small file (the
        // resulting huge bogus offset just fails the bounds check and gets silently skipped) but
        // produces real, in-range garbage on a large one like `revo_kart.brsar`, worth recording
        // since it's an easy mistake to reintroduce.
        func countPrefixedTable(_ tableOffset: Int, entrySize: Int, _ body: (Int) -> Void) {
            guard tableOffset >= 0, tableOffset + 4 <= data.count else { return }
            let count = Int(data.be32(tableOffset))
            guard count < 100_000 else { return } // corrupt/garbage offset guard
            for i in 0..<count {
                let refEntry = tableOffset + 4 + i * 8
                guard refEntry + 8 <= data.count else { break }
                let entryOffset = infoBase + Int(data.be32(refEntry + 4))
                guard entryOffset >= 0, entryOffset + entrySize <= data.count else { continue }
                body(entryOffset)
            }
        }

        // MARK: Sound Data Table
        countPrefixedTable(dataRefTarget(soundTableRef), entrySize: 0x18) { entryOffset in
            let nameIndex = Int(data.be32(entryOffset))
            let fileIndex = data.be32(entryOffset + 4)
            let playerID = data.be32(entryOffset + 8)
            let volume = data.u8(entryOffset + 0x14)
            let type = BRSARSoundType(rawValue: data.u8(entryOffset + 0x16))
            doc.sounds.append(BRSARSound(name: name(at: nameIndex), type: type, volume: volume, playerID: playerID, fileIndex: fileIndex))
        }

        // MARK: Soundbank Table
        countPrefixedTable(dataRefTarget(bankTableRef), entrySize: 0x0C) { entryOffset in
            let nameIndex = Int(data.be32(entryOffset))
            let fileIndex = data.be32(entryOffset + 4)
            doc.banks.append(BRSARBank(name: name(at: nameIndex), fileIndex: fileIndex))
        }

        // MARK: Player Info Table
        countPrefixedTable(dataRefTarget(playerTableRef), entrySize: 0x0D) { entryOffset in
            let nameIndex = Int(data.be32(entryOffset))
            let playableCount = Int(data.u8(entryOffset + 4))
            doc.players.append(BRSARPlayer(name: name(at: nameIndex), playableSoundCount: playableCount))
        }

        // MARK: File Table
        var fileIndexCounter = 0
        countPrefixedTable(dataRefTarget(fileTableRef), entrySize: 0x18) { entryOffset in
            let dataLength = Int(data.be32(entryOffset + 4))
            var externalName: String?
            let extRefValue = Int(data.be32(entryOffset + 0x0C + 4))
            if extRefValue != 0 {
                let extOffset = infoBase + extRefValue
                if extOffset < data.count { externalName = data.asciiString(at: extOffset, length: min(256, data.count - extOffset)) }
            }
            doc.files.append(BRSARFile(index: fileIndexCounter, externalName: externalName, dataLength: dataLength))
            fileIndexCounter += 1
        }

        // MARK: Group Table
        countPrefixedTable(dataRefTarget(groupTableRef), entrySize: 0x24) { entryOffset in
            let nameIndex = Int(data.be32(entryOffset))
            let itemRefTableOffset = dataRefTarget(entryOffset + 0x20)
            let itemCount = itemRefTableOffset + 4 <= data.count ? Int(data.be32(itemRefTableOffset)) : 0
            doc.groups.append(BRSARGroup(name: name(at: nameIndex), itemCount: itemCount))
        }

        return doc
    }
}
