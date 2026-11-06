import Foundation

/// Nintendo's "Binary Message" format for in-game text (menu strings, race messages, credits,
/// etc). Layout verified against the community-documented structure (header + INF1 index section + DAT1 UTF-16 string pool +
/// MID1 message-ID table, the usual 3 sections Mario Kart Wii uses).
///
/// 0x1A escape sequences (Mii names, colors, unicode chars, context-dependent references) are
/// preserved losslessly in `units` but not decoded to their real meaning, a message containing
/// one shows a `[esc ...]` placeholder in `displayText` and is read-only in the editor, since
/// editing text around an escape sequence without understanding it risks corrupting it.
nonisolated struct BMGMessage: Identifiable {
    let id = UUID()
    var messageID: UInt32?
    /// MKWii's per-message attribute bytes (font selector, etc.), preserved as-is, not
    /// interpreted, so round-tripping an unedited message is always byte-exact.
    var attribute: Data
    /// Raw UTF-16 code units, including any embedded 0x1A escape sequences.
    var units: [UInt16]

    var containsEscape: Bool { units.contains(0x1A) }

    var displayText: String {
        var result = ""
        var i = 0
        while i < units.count {
            if units[i] == 0x1A, i + 1 < units.count {
                let sizeInBytes = Int(units[i + 1] >> 8)
                let sizeInUnits = max(1, sizeInBytes / 2)
                let end = min(units.count, i + sizeInUnits)
                let hex = units[i..<end].map { String(format: "%04X", $0) }.joined(separator: " ")
                result += "[esc \(hex)]"
                i = end
            } else {
                if let scalar = Unicode.Scalar(units[i]) { result.unicodeScalars.append(scalar) }
                i += 1
            }
        }
        return result
    }
}

nonisolated final class BMGDocument {
    /// 0=Undefined, 1=CP1252, 2=UTF-16 (what MKWii uses), 3=Shift-JIS, 4=UTF-8.
    var encoding: UInt8 = 2
    var messages: [BMGMessage] = []
    /// Whether to write a MID1 (message-ID) section. Every retail Mario Kart Wii BMG has one and
    /// the game finds messages by those IDs, so a new document has it; a parsed file keeps
    /// whatever it came with.
    var hasMessageIDSection = true
    /// The file as read, returned as-is by `serialize` while nothing has changed: retail string
    /// pools aren't fully reproducible from content (some empty messages sit inline, most share
    /// offset 0), so an untouched file only round-trips byte-for-byte this way.
    private var source: (data: Data, encoding: UInt8, messages: [BMGMessage])?

    static func parse(_ data: Data) throws -> BMGDocument {
        guard data.count >= 0x20, data.asciiString(at: 0, length: 8) == "MESGbmg1" else {
            throw WSError.badStructure("Not a BMG file (missing 'MESGbmg1' magic).")
        }
        let numSections = Int(data.be32(0x0C))
        guard numSections > 0, numSections < 100 else {
            throw WSError.badStructure("BMG section count looks invalid.")
        }
        let doc = BMGDocument()
        doc.encoding = data.u8(0x10)
        doc.hasMessageIDSection = false

        struct InfEntry { var textOffset: Int; var attribute: Data }
        var infEntries: [InfEntry] = []
        var datStart = 0
        var midList: [UInt32] = []

        var offset = 0x20
        for _ in 0..<numSections {
            guard offset + 8 <= data.count else { break }
            let kind = data.asciiString(at: offset, length: 4)
            let size = Int(data.be32(offset + 4))
            guard size >= 8, offset + size <= data.count else { break }

            switch kind {
            case "INF1":
                let numEntries = Int(data.be16(offset + 8))
                let entrySize = Int(data.be16(offset + 10))
                if entrySize >= 4 {
                    for i in 0..<numEntries {
                        let base = offset + 0x10 + i * entrySize
                        guard base + entrySize <= data.count else { break }
                        let textOfs = Int(data.be32(base))
                        let attr = data.subdata(at: base + 4, length: entrySize - 4)
                        infEntries.append(InfEntry(textOffset: textOfs, attribute: attr))
                    }
                }
            case "DAT1":
                datStart = offset + 8
            case "MID1":
                doc.hasMessageIDSection = true
                let numEntries = Int(data.be16(offset + 8))
                for i in 0..<numEntries {
                    let base = offset + 0x10 + i * 4
                    guard base + 4 <= data.count else { break }
                    midList.append(data.be32(base))
                }
            default:
                break // FLW1/FLI1 and other sections aren't used by MKWii; skip them.
            }
            offset += size
        }

        for (i, entry) in infEntries.enumerated() {
            let units = readUnits(data, at: datStart + entry.textOffset)
            let mid = midList.indices.contains(i) ? midList[i] : nil
            doc.messages.append(BMGMessage(messageID: mid, attribute: entry.attribute, units: units))
        }
        doc.source = (data, doc.encoding, doc.messages)
        return doc
    }

    /// Reads one NULL-terminated UTF-16 string from the DAT1 pool, treating any embedded 0x1A
    /// escape sequence as an opaque run of bytes (per its own declared size) rather than data
    /// that could contain a spurious NULL and end the string early.
    private static func readUnits(_ data: Data, at start: Int) -> [UInt16] {
        guard start >= 0 else { return [] }
        var units: [UInt16] = []
        var pos = start
        while pos + 2 <= data.count {
            let u = data.be16(pos)
            if u == 0 { break }
            units.append(u)
            pos += 2
            if u == 0x1A, pos < data.count {
                let sizeInBytes = Int(data.u8(pos))
                let remaining = max(0, sizeInBytes - 2)
                var consumed = 0
                while consumed < remaining, pos + 2 <= data.count {
                    units.append(data.be16(pos))
                    pos += 2
                    consumed += 2
                }
            }
        }
        return units
    }

    func serialize() -> Data {
        if let source, source.encoding == encoding, source.messages.count == messages.count,
           zip(source.messages, messages).allSatisfy({ $0.messageID == $1.messageID && $0.attribute == $1.attribute && $0.units == $1.units }) {
            return source.data
        }
        let attrLen = messages.map(\.attribute.count).max() ?? 4
        let entrySize = 4 + attrLen

        // Retail layout (checked across every BMG on the disc): DAT1 opens with one empty string
        // at offset 0 that every empty message points at; everything else follows in order.
        let dat = MutableDataWriter()
        dat.putU16(0)
        var textOffsets: [Int] = []
        for m in messages {
            guard !m.units.isEmpty else { textOffsets.append(0); continue }
            textOffsets.append(dat.data.count)
            for u in m.units { dat.putU16(u) }
            dat.putU16(0)
        }

        let inf = MutableDataWriter()
        inf.putU16(UInt16(messages.count))
        inf.putU16(UInt16(entrySize))
        inf.putU16(0) // groupID
        inf.putU8(0); inf.putU8(0) // defaultColor + reserved
        for (i, m) in messages.enumerated() {
            inf.putU32(UInt32(textOffsets[i]))
            var attr = m.attribute
            if attr.count < attrLen { attr.append(Data(repeating: 0, count: attrLen - attr.count)) }
            inf.putData(attr.prefix(attrLen))
        }

        func section(_ magic: String, _ body: MutableDataWriter) -> Data {
            var payload = body.data
            while (8 + payload.count) % 32 != 0 { payload.append(0) } // retail pads every section to 32
            let w = MutableDataWriter()
            w.putData(Data(magic.utf8))
            w.putU32(UInt32(8 + payload.count))
            w.putData(payload)
            return w.data
        }

        let inf1 = section("INF1", inf)
        let dat1 = section("DAT1", dat)

        let hasIDs = hasMessageIDSection || messages.contains { $0.messageID != nil }
        var mid1 = Data()
        if hasIDs {
            let mid = MutableDataWriter()
            mid.putU16(UInt16(messages.count))
            mid.putU16(0x1000)
            mid.putU32(0)
            for m in messages { mid.putU32(m.messageID ?? 0) }
            mid1 = section("MID1", mid)
        }

        let w = MutableDataWriter()
        w.putData(Data("MESGbmg1".utf8))
        w.putU32(UInt32(0x20 + inf1.count + dat1.count + mid1.count))
        w.putU32(hasIDs ? 3 : 2)
        w.putU8(encoding)
        w.pad(to: w.data.count + 15)
        w.putData(inf1)
        w.putData(dat1)
        if hasIDs { w.putData(mid1) }
        return w.data
    }
}
