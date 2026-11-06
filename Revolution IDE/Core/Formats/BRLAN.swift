import Foundation

/// Binary Revolution Layout ANimation, keyframe animations for a `.brlyt` layout (fading a menu
/// panel in, sliding a button, ...), used together with BRLYT/BRCTR/BRFNT for Mario Kart Wii's UI.
/// Structure verified against wiki.tockdom.com's "BRLAN (File Format)" page.
///
/// Deliberately summary-level (view-only, like `.tpl`): each animated pane/material + which
/// property it animates (`RLPA` pane SRT, `RLVI` visibility, `RLMC` material color, ...) and how
/// many keyframes, but not the keyframe curve values themselves, a full curve editor is a much
/// bigger UI than this pass covers, and BRLAN is normally authored by hand-tweaking a real
/// animation tool rather than typing individual keyframe numbers anyway.
nonisolated struct BRLANAnimationEntry {
    var index: UInt8
    var target: UInt8
    var keyFrameType: UInt8
    var keyFrameCount: Int
}

nonisolated struct BRLANAnimationTag {
    var type: String // "RLPA", "RLTS", "RLVI", "RLVC", "RLMC", "RLTP"
    var entries: [BRLANAnimationEntry]
}

nonisolated struct BRLANAnimation {
    var name: String
    var animatesMaterial: Bool // false = pane
    var tags: [BRLANAnimationTag]
}

nonisolated final class BRLANDocument {
    var animationSetName: String = ""
    var frameCount: Int = 0
    var textureFilenames: [String] = []
    var animations: [BRLANAnimation] = []

    static func parse(_ data: Data) throws -> BRLANDocument {
        guard data.count >= 0x10, data.asciiString(at: 0, length: 4) == "RLAN" else {
            throw WSError.badStructure("Not a BRLAN file (missing 'RLAN' magic).")
        }
        guard data.be16(4) == 0xFEFF else {
            throw WSError.badStructure("Little-endian BRLAN files aren't supported.")
        }
        let doc = BRLANDocument()

        var offset = 0x10
        while offset + 8 <= data.count {
            let magic = data.asciiString(at: offset, length: 4)
            let sectionLength = Int(data.be32(offset + 4))
            guard sectionLength >= 8, offset + sectionLength <= data.count else { break }

            switch magic {
            case "pat1":
                let nameOffset = offset + Int(data.be32(offset + 0x0C))
                if nameOffset < data.count { doc.animationSetName = data.asciiString(at: nameOffset, length: min(64, data.count - nameOffset)) }

            case "pai1":
                doc.frameCount = Int(data.be16(offset + 8))
                let tplCount = Int(data.be16(offset + 0x0C))
                let animCount = Int(data.be16(offset + 0x0E))
                let animOffsetsStart = offset + Int(data.be32(offset + 0x10))
                let tplOffsetsStart = offset + 0x14

                for i in 0..<tplCount {
                    let entry = tplOffsetsStart + i * 4
                    guard entry + 4 <= data.count else { break }
                    let strOffset = tplOffsetsStart + Int(data.be32(entry))
                    guard strOffset < data.count else { continue }
                    doc.textureFilenames.append(data.asciiString(at: strOffset, length: min(256, data.count - strOffset)))
                }

                for i in 0..<animCount {
                    let entry = animOffsetsStart + i * 4
                    guard entry + 4 <= data.count else { break }
                    let animOffset = offset + Int(data.be32(entry))
                    guard let animation = parseAnimation(data, at: animOffset) else { continue }
                    doc.animations.append(animation)
                }

            default:
                break
            }

            offset += sectionLength
            if sectionLength == 0 { break }
        }
        return doc
    }

    private static func parseAnimation(_ data: Data, at animOffset: Int) -> BRLANAnimation? {
        guard animOffset + 0x18 <= data.count else { return nil }
        let name = data.asciiString(at: animOffset, length: 0x14)
        let tagCount = Int(data.u8(animOffset + 0x14))
        let animatesMaterial = data.u8(animOffset + 0x15) != 0
        var tags: [BRLANAnimationTag] = []
        for t in 0..<tagCount {
            let entry = animOffset + 0x18 + t * 4
            guard entry + 4 <= data.count else { break }
            let tagOffset = animOffset + Int(data.be32(entry))
            guard let tag = parseTag(data, at: tagOffset) else { continue }
            tags.append(tag)
        }
        return BRLANAnimation(name: name, animatesMaterial: animatesMaterial, tags: tags)
    }

    private static func parseTag(_ data: Data, at tagOffset: Int) -> BRLANAnimationTag? {
        guard tagOffset + 8 <= data.count else { return nil }
        let type = data.asciiString(at: tagOffset, length: 4)
        let entryCount = Int(data.u8(tagOffset + 4))
        var entries: [BRLANAnimationEntry] = []
        for e in 0..<entryCount {
            let ref = tagOffset + 8 + e * 4
            guard ref + 4 <= data.count else { break }
            let entryOffset = tagOffset + Int(data.be32(ref))
            guard entryOffset + 4 <= data.count else { continue }
            // Key frame count isn't a directly-documented field on the entry header itself, so
            // this is left at 0 (unknown), the entry's other fields
            // (index/target/keyframe type) are exactly what the format docs specify.
            entries.append(BRLANAnimationEntry(index: data.u8(entryOffset), target: data.u8(entryOffset + 1),
                                                keyFrameType: data.u8(entryOffset + 2), keyFrameCount: 0))
        }
        return BRLANAnimationTag(type: type, entries: entries)
    }
}
