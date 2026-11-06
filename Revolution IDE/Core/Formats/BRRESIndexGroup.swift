import Foundation

/// The radix-tree "index group" (aka resource dictionary) format used everywhere in BRRES to map
/// names to sub-resources: the root "folder list", each named folder's contents, and (inside
/// MDL0) its own bones/materials/vertex-buffer/shape sub-dictionaries.
///
/// Layout, confirmed against a real Nintendo-built BRRES (not just this app's own writer --
/// see below): u32 totalSize (this dictionary's own header + node array byte size, not including
/// the string table), u32 entryCount (not counting a header/root placeholder entry), then
/// (entryCount + 1) 16-byte nodes: id(u16), unk(u16), leftIndex(u16), rightIndex(u16),
/// nameOffset(u32), dataOffset(u32), both offsets relative to the start of this index group
/// (the totalSize field). Node 0 is the tree root placeholder and is skipped when listing
/// entries.
///
/// A prior version of this reader treated the leading `totalSize` field as if it were the entry
/// count (missing that field entirely), which happened to round-trip against this app's own
/// writer (same mistake on both ends) but silently misread every real-world BRRES, reading
/// name/data offsets 4 bytes off from every node onward, which is what produced garbled resource
/// names ("symbols") when opening real game files. Verified against `riidefi/RiiStudio`'s
/// `kuribo.brres` test asset: totalSize there is 0x48 for a 3-entry group, i.e.
/// `8 + (3+1)*16 = 0x48`, confirming both the extra field and this exact size formula.
nonisolated struct BRRESIndexEntry {
    var name: String
    var dataOffset: Int // absolute offset into the containing file
}

nonisolated enum BRRESIndexGroup {
    /// `names`, when given, is `(wholeFile, thisGroupsOffsetWithinWholeFile)`, needed for a
    /// dictionary nested inside an MDL0 resource (bones/materials/meshes/render tree/...), whose
    /// entry names are offsets into a string pool shared by the *whole* file, not this resource's
    /// own local byte range (confirmed against a real course.brres off a real MKWii disc, see
    /// `MDL0Parser.parseMaterials`'s doc comment for how). Top-level BRRES folder dictionaries
    /// don't need this: `data` passed there already *is* the whole file, so the default (resolve
    /// names directly in `data`) is already correct for them.
    static func parse(_ data: Data, groupStart: Int, names: (wholeFile: Data, offset: Int)? = nil) -> [BRRESIndexEntry] {
        guard groupStart + 8 <= data.count else { return [] }
        let count = Int(data.be32(groupStart + 4))
        guard count >= 0, count < 10000, groupStart + 8 + (count + 1) * 16 <= data.count else { return [] }
        guard count > 0 else { return [] }
        let nameBuffer = names?.wholeFile ?? data
        let nameBase = names?.offset ?? 0
        var out: [BRRESIndexEntry] = []
        for i in 1...count {
            let base = groupStart + 8 + i * 16
            let nameOffset = Int(Int32(bitPattern: data.be32(base + 8)))
            let dataOffset = Int(data.be32(base + 12))
            let nameAt = nameBase + groupStart + nameOffset
            let name = nameAt >= 0 ? nameBuffer.asciiString(at: nameAt, length: max(0, nameBuffer.count - nameAt)) : ""
            out.append(BRRESIndexEntry(name: name, dataOffset: groupStart + dataOffset))
        }
        return out
    }

    /// One built tree node: the three fields a reader/runtime actually navigates by.
    nonisolated struct TreeNode { var id: UInt16; var left: UInt16; var right: UInt16 }

    /// Builds the real NW4R radix tree for `names`, node 0 is the root sentinel, node `i + 1`
    /// describes `names[i]`.
    ///
    /// This matters because the Wii runtime (nw4r's `ResDic`) does *not* scan a dictionary
    /// linearly: it walks this tree bit by bit to find a name, so a dictionary whose id/left/right
    /// fields are left at zero (what this app wrote before) is a dictionary the game cannot look
    /// anything up in, `course` is simply never found in `course_model.brres`. Ported from
    /// Wiimm's SZS tools (`lib-brres.c`: `get_highest_bit` / `calc_brres_id` / `CalcEntryBRRES`),
    /// and verified byte-for-byte against a retail Mario Kart Wii `course_model.brres`, see
    /// `selfCheck()`, which reproduces that file's own 22-material dictionary exactly.
    static func buildTree(names: [String]) -> [TreeNode] {
        struct Node { var name: [UInt8]; var id: UInt16; var left: UInt16; var right: UInt16 }
        var nodes: [Node] = [Node(name: [], id: 0xFFFF, left: 0, right: 0)]
        nodes.append(contentsOf: names.map { Node(name: Array($0.utf8), id: 0, left: 0, right: 0) })

        // Bit number of the highest set bit of `value` (0 when none are set).
        func highestBit(_ value: UInt8) -> UInt16 {
            for bit in stride(from: 7, through: 1, by: -1) where value & (1 << UInt8(bit)) != 0 { return UInt16(bit) }
            return 0
        }
        /// "Index of the last differing character, times 8, plus which bit differs", the key the
        /// tree branches on. With an empty `previous` this degenerates to "the last character of
        /// `current`", which is how a node's initial id is derived.
        func calcID(previous: [UInt8], current: [UInt8]) -> UInt16 {
            if previous.count < current.count {
                guard let last = current.last else { return 0xFFFF }
                return UInt16(current.count - 1) << 3 | highestBit(last)
            }
            var i = current.count
            while i > 0 {
                i -= 1
                let ch = previous[i] ^ current[i]
                if ch != 0 { return UInt16(i) << 3 | highestBit(ch) }
            }
            return 0xFFFF
        }
        /// Is bit `id` set within this node's name? (Out-of-range character index reads as 0.)
        func idBit(_ node: Node, _ id: UInt16) -> Bool {
            let charIndex = Int(id >> 3)
            return charIndex < node.name.count && (node.name[charIndex] >> (id & 7)) & 1 == 1
        }

        for entryIndex in 1..<nodes.count {
            nodes[entryIndex].id = calcID(previous: [], current: nodes[entryIndex].name)
            nodes[entryIndex].left = UInt16(entryIndex)
            nodes[entryIndex].right = UInt16(entryIndex)

            var previousIndex = 0
            var currentIndex = Int(nodes[0].left)
            var isRight = false
            while nodes[entryIndex].id <= nodes[currentIndex].id, nodes[currentIndex].id < nodes[previousIndex].id {
                if nodes[entryIndex].id == nodes[currentIndex].id {
                    nodes[entryIndex].id = calcID(previous: nodes[currentIndex].name, current: nodes[entryIndex].name)
                    if idBit(nodes[currentIndex], nodes[entryIndex].id) {
                        nodes[entryIndex].left = UInt16(entryIndex)
                        nodes[entryIndex].right = UInt16(currentIndex)
                    } else {
                        nodes[entryIndex].left = UInt16(currentIndex)
                        nodes[entryIndex].right = UInt16(entryIndex)
                    }
                }
                previousIndex = currentIndex
                isRight = idBit(nodes[entryIndex], nodes[currentIndex].id)
                currentIndex = Int(isRight ? nodes[currentIndex].right : nodes[currentIndex].left)
            }
            if nodes[currentIndex].name.count == nodes[entryIndex].name.count,
               idBit(nodes[currentIndex], nodes[entryIndex].id) {
                nodes[entryIndex].right = UInt16(currentIndex)
            } else {
                nodes[entryIndex].left = UInt16(currentIndex)
            }
            if isRight { nodes[previousIndex].right = UInt16(entryIndex) } else { nodes[previousIndex].left = UInt16(entryIndex) }
        }
        return nodes.map { TreeNode(id: $0.id, left: $0.left, right: $0.right) }
    }

    /// Fails loudly if `buildTree` ever stops reproducing a real Nintendo dictionary. The expected
    /// values below are the literal id/left/right fields read out of a retail Mario Kart Wii
    /// `course_model.brres` (its MDL0 render-tree and material dictionaries).
    static func selfCheck() {
        let renderTree = buildTree(names: ["NodeTree", "DrawOpa", "DrawXlu"])
        let expectedRenderTree: [(UInt16, UInt16, UInt16)] = [(65535, 1, 0), (62, 2, 1), (54, 0, 3), (52, 2, 3)]
        precondition(renderTree.count == expectedRenderTree.count)
        for (built, expected) in zip(renderTree, expectedRenderTree) {
            precondition((built.id, built.left, built.right) == expected, "BRRES index-group tree no longer matches a real file")
        }
        let materials = buildTree(names: [
            "WT_EleArrow_ALL", "a_MainRoad_m", "a_SAND_m", "a_bc_enseki_m", "a_bc_kankyakuseat_m",
            "a_kusa_soto", "a_kusa_waki_m", "bc_kankyaku_m", "bc_spot_m", "bc_tree_one_m", "block3_m",
            "ef_dushBoard", "enkei_yama_m", "fence", "hana_m", "kinoko_m", "kusa_kanban_m", "lake_m",
            "lugcap_m", "popkanban_m", "tatemono_m", "yama_m",
        ])
        let expectedMaterials: [(UInt16, UInt16, UInt16)] = [
            (65535, 5, 0), (118, 4, 1), (94, 6, 12), (62, 15, 11), (102, 2, 8), (150, 1, 5), (86, 21, 20),
            (66, 7, 4), (84, 10, 8), (70, 3, 9), (83, 10, 17), (46, 11, 16), (91, 12, 13), (74, 13, 2),
            (38, 0, 14), (46, 14, 18), (45, 3, 19), (82, 7, 17), (26, 22, 18), (44, 16, 19), (81, 20, 6),
            (78, 9, 21), (17, 22, 15),
        ]
        precondition(materials.count == expectedMaterials.count)
        for (built, expected) in zip(materials, expectedMaterials) {
            precondition((built.id, built.left, built.right) == expected, "BRRES index-group tree no longer matches a real file")
        }
    }
}
