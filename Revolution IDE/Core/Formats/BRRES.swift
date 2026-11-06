import Foundation

/// A name a resource refers to but does not contain.
///
/// BRRES keeps all its strings in one pool shared by the whole file, so a resource written from
/// scratch cannot resolve its own name offsets, they depend on where the container puts both the
/// resource and the pool. It records them instead, and `BRRESDocument.rebuild` patches them in.
/// Both offsets are relative to the start of the resource's own bytes; the stored value is the
/// distance from `anchorOffset` to the name's characters, matching how every offset in this format
/// is self-relative.
nonisolated struct BRRESStringReference {
    var fieldOffset: Int
    var anchorOffset: Int
    var text: String
}

/// One named sub-resource inside a BRRES container (a TEX0 texture, MDL0 model, CHR0 animation,
/// etc.), kept as its raw framed bytes (magic + length + ...) so round-tripping unedited
/// resources is always byte-exact regardless of how well this app understands their internals.
nonisolated final class BRRESResource: Identifiable {
    let id = UUID()
    var name: String
    var folderName: String // e.g. "3DModels(NW4R)", "Textures(NW4R)"
    var data: Data
    /// This resource's start offset within its parent `BRRESDocument.rawData`. MDL0's internal
    /// string references (material/sampler names) are stored relative to the *whole file*, not
    /// this resource's own local byte range, so resolving them needs this plus `rawData` (see
    /// `MDL0Parser`'s doc comment on `parseMaterials` for how that was confirmed).
    var fileOffset: Int = 0


    /// Name, folder and byte length as parsed, so `BRRESDocument.serialize` can tell whether this
    /// resource still occupies exactly the space it came from. Nil for a resource created in
    /// memory rather than read from a file.
    private(set) var original: (name: String, folderName: String, length: Int)?

    /// Names this resource points at in the file's shared string pool, for a resource built here
    /// rather than read from a file (see `BRRESStringReference`). Empty for a parsed resource,
    /// whose offsets already resolve against the pool it came with.
    var stringReferences: [BRRESStringReference] = []

    init(name: String, folderName: String, data: Data, fileOffset: Int = 0,
         stringReferences: [BRRESStringReference] = []) {
        self.name = name; self.folderName = folderName; self.data = data; self.fileOffset = fileOffset
        self.stringReferences = stringReferences
    }

    /// Marks this resource as having come from a file, recording its parsed shape.
    fileprivate func rememberAsParsed() {
        original = (name, folderName, data.count)
    }

    /// True when nothing that affects the file's layout or its dictionaries has changed.
    var matchesParsedLayout: Bool {
        guard let original else { return false }
        return original.name == name && original.folderName == folderName && original.length == data.count
    }

    var magic: String { data.count >= 4 ? data.asciiString(at: 0, length: 4) : "?" }
}

/// Container-level parse/serialize.
///
/// Note on "create/edit": each folder's resource dictionary is written as a real NW4R radix tree
/// (see `BRRESIndexGroup.buildTree`), not the flat "every node points at index 0" stub this used
/// to emit. That stub round-tripped fine through this app's own linear reader, but the Wii runtime
/// looks names up by *walking* the tree, so a file written the old way was one the game could
/// never find `course` (or any other resource) in.
nonisolated final class BRRESDocument {
    var resources: [BRRESResource] = []
    /// The complete file this was parsed from, kept around only so `MDL0Parser` can resolve
    /// string references that point outside an individual MDL0 resource's own byte range (see
    /// `BRRESResource.fileOffset`'s doc comment).
    var rawData: Data = Data()

    /// The shared string pool a real BRRES keeps after its last resource.
    ///
    /// Every name in the file lives here, the folder and resource names this container's own
    /// dictionaries point at, *and* the names each resource refers to internally (an MDL0's
    /// bones, materials and texture links). Those internal references sit outside the resource's
    /// own declared length, so they are not part of `BRRESResource.data`: re-serializing without
    /// carrying this pool across dropped every one of them, and a retail `course_model.brres`
    /// saved by this app came back with all 22 of its texture links pointing at nothing.
    ///
    /// Kept verbatim so an untouched file round-trips byte-for-byte; `stringPoolOffsets` maps the
    /// names already in it, and `appendString` adds any the container newly needs.
    var stringPool: Data = Data()

    static func parse(_ data: Data) throws -> BRRESDocument {
        guard data.count >= 0x20, data.asciiString(at: 0, length: 4) == "bres" else {
            throw WSError.badStructure("Not a BRRES file (missing 'bres' magic).")
        }
        // Root section: magic "root" + length(u32), then an index group of top-level folders.
        let rootSectionStart = 0x10
        guard data.asciiString(at: rootSectionStart, length: 4) == "root" else {
            throw WSError.badStructure("BRRES missing root section.")
        }
        let folderGroupStart = rootSectionStart + 8
        let folders = BRRESIndexGroup.parse(data, groupStart: folderGroupStart)

        let doc = BRRESDocument()
        doc.rawData = data
        for folder in folders {
            let entries = BRRESIndexGroup.parse(data, groupStart: folder.dataOffset)
            for entry in entries {
                guard entry.dataOffset >= 0, entry.dataOffset < data.count else { continue }
                let length = entry.dataOffset + 4 <= data.count ? Int(data.be32(entry.dataOffset + 4)) : 0
                guard length > 0, entry.dataOffset + length <= data.count else { continue }
                let raw = data.subdata(at: entry.dataOffset, length: length)
                let resource = BRRESResource(name: entry.name, folderName: folder.name, data: raw, fileOffset: entry.dataOffset)
                resource.rememberAsParsed()
                doc.resources.append(resource)
            }
        }
        // Everything after the last resource is the shared string pool.
        let end = doc.resources.map { $0.fileOffset + $0.data.count }.max() ?? 0
        if end > 0, end < data.count {
            doc.stringPool = data.subdata(at: end, length: data.count - end)
        }
        return doc
    }

    /// Maps each name already in `pool` to the offset of its characters within it.
    ///
    /// Pool entry layout, read off a retail `map_model.brres`: u32 length, the ASCII characters,
    /// a NUL, then zero padding up to the next 4-byte boundary, the padding is written even
    /// when the NUL already lands on one, so "NodeTree" (8 characters) is followed by four zero
    /// bytes, not none. An offset stored in a dictionary or inside a resource points at the
    /// characters, i.e. just past the length field.
    static func parseStringPool(_ pool: Data) -> [String: Int] {
        var map: [String: Int] = [:]
        var p = 0
        while p + 4 <= pool.count {
            let length = Int(pool.be32(p))
            guard length > 0, length < 4096, p + 4 + length + 1 <= pool.count else { break }
            let name = pool.asciiString(at: p + 4, length: length)
            if name.utf8.count == length, map[name] == nil { map[name] = p + 4 }
            p = (p + 4 + length + 1 + 3) & ~3
        }
        return map
    }

    /// Adds a name in that same layout, returning the offset of its characters.
    @discardableResult
    static func appendString(_ name: String, to pool: inout Data) -> Int {
        while pool.count % 4 != 0 { pool.append(0) }
        let bytes = Array(name.utf8)
        pool.append(contentsOf: [UInt8(truncatingIfNeeded: bytes.count >> 24), UInt8(truncatingIfNeeded: bytes.count >> 16),
                                 UInt8(truncatingIfNeeded: bytes.count >> 8), UInt8(truncatingIfNeeded: bytes.count)])
        let address = pool.count
        pool.append(contentsOf: bytes)
        pool.append(0)
        while pool.count % 4 != 0 { pool.append(0) }
        return address
    }

    /// One index group's node array. Names are no longer written inside the group: a retail file
    /// keeps them all in the shared pool at the end (see `stringPool`), and each node's
    /// `nameOffset` reaches it as a self-relative distance from the group's own start.
    private func buildIndexGroup(names: [String], targetOffsets: [Int], nameAddresses: [Int], groupStart: Int) -> Data {
        let w = MutableDataWriter()
        // totalSize covers this header and the node array, nothing else follows it now.
        let nodeAreaSize = Self.indexGroupByteSize(names: names)
        w.putU32(UInt32(nodeAreaSize))
        w.putU32(UInt32(names.count))
        // Root/sentinel node: id=0xFFFF marks "not a real entry", and its `left` is the tree's
        // actual entry point, the Wii runtime starts every name lookup there, so it is not
        // optional padding (see `BRRESIndexGroup.buildTree`).
        let tree = BRRESIndexGroup.buildTree(names: names)
        w.putU16(tree[0].id); w.putU16(0); w.putU16(tree[0].left); w.putU16(tree[0].right); w.putU32(0); w.putU32(0)
        for i in 0..<names.count {
            let node = tree[i + 1]
            w.putU16(node.id); w.putU16(0); w.putU16(node.left); w.putU16(node.right)
            w.putU32(UInt32(bitPattern: Int32(nameAddresses[i] - groupStart)))
            w.putU32(UInt32(bitPattern: Int32(targetOffsets[i] - groupStart)))
        }
        return w.data
    }

    private static func indexGroupByteSize(names: [String]) -> Int {
        8 + (names.count + 1) * 16
    }

    /// How far into the file a resource of this type has to start.
    ///
    /// Measured over every BRRES in a sample of ~150 archives from a retail disc: MDL0 begins on a
    /// 32-byte boundary in all 1050 cases and TEX0 in all 2838 (they are GPU data, and the gap
    /// before one runs up to 16 bytes purely to reach that boundary). Every other section type --
    /// CHR0, CLR0, PAT0, SRT0, SCN0, SHP0, is only ever 4-aligned, with gaps of 1, 2 and 3 bytes
    /// observed before them. Aligning everything to 32 padded files Nintendo's do not pad, which
    /// is what left `bombCore.brres` 2 bytes long and `driver.brres` 6.
    private static func alignment(forMagic magic: String) -> Int {
        magic == "MDL0" || magic == "TEX0" ? 32 : 4
    }

    func serialize() -> Data {
        if let unchanged = serializePreservingLayout() { return unchanged }
        return rebuild()
    }

    /// Writes each resource back into the bytes this document was parsed from, leaving everything
    /// else exactly as it was.
    ///
    /// A BRRES holds more than its header, dictionaries and resources: it also holds string data,
    /// and where that sits is not fixed. `course_model.brres` keeps it after the last resource
    /// while `castle_tree1.brres` keeps it between the folder dictionaries and the first resource,
    /// inside the root section's own declared length. A rebuild therefore cannot reproduce every
    /// retail file, and one that guesses wrong moves strings that resources refer to by offset.
    ///
    /// So when nothing about the layout has changed, same resources, same names, same folders,
    /// same lengths, each still at the offset it was read from, the original bytes are reused
    /// and only the resources' own contents are written over. That makes an untouched file
    /// round-trip byte-for-byte whatever its layout, and keeps a same-size edit (replacing a
    /// texture's pixels, say) from disturbing anything around it.
    private func serializePreservingLayout() -> Data? {
        guard !rawData.isEmpty, !resources.isEmpty else { return nil }
        guard resources.allSatisfy(\.matchesParsedLayout) else { return nil }
        var offsets = Set<Int>()
        for r in resources {
            guard r.fileOffset > 0, r.fileOffset + r.data.count <= rawData.count else { return nil }
            guard offsets.insert(r.fileOffset).inserted else { return nil }
        }
        // A resource that was dropped from the document would otherwise be left in the output.
        guard let parsed = try? BRRESDocument.parse(rawData), parsed.resources.count == resources.count else { return nil }

        var out = rawData
        for r in resources where r.data != out.subdata(at: r.fileOffset, length: r.data.count) {
            out.replaceSubrange((out.startIndex + r.fileOffset)..<(out.startIndex + r.fileOffset + r.data.count), with: r.data)
            if r.data.count >= 0x10 { out.setBE32(UInt32(bitPattern: Int32(-r.fileOffset)), at: r.fileOffset + 0x0C) }
        }
        return out
    }

    private func rebuild() -> Data {
        if let kept = rebuildKeepingOriginalBlock() { return kept }
        return rebuildFromScratch()
    }

    /// A rebuild for a document read from a file whose layout has changed (a resource added,
    /// removed, renamed or resized).
    ///
    /// Parsed resources reach their names through self-relative offsets into the file's string
    /// pool, and nothing records where those fields are. `rebuildFromScratch` moves resources and
    /// pool independently, so adding one texture to a retail `course_model.brres` left every
    /// texture link and material name in its MDL0 pointing at the wrong bytes. So everything after
    /// the original dictionaries, resources and strings alike, moves as one block, by a single
    /// 32-byte-preserving shift, which keeps every such offset valid. New or resized resources go
    /// after it, and names the new dictionaries need go in a small pool at the end. A resized or
    /// removed resource's old bytes stay in the block unreferenced.
    private func rebuildKeepingOriginalBlock() -> Data? {
        guard !rawData.isEmpty, rawData.count >= 0x20 else { return nil }
        let originalFolders = BRRESIndexGroup.parse(rawData, groupStart: rootSectionStart + 8)
        func groupEnd(_ start: Int) -> Int { start + Self.indexGroupByteSize(names: Array(repeating: "", count: Int(rawData.be32(start + 4)))) }
        let blockStart = originalFolders.map { groupEnd($0.dataOffset) }.reduce(groupEnd(rootSectionStart + 8), max)
        guard blockStart <= rawData.count else { return nil }
        let block = rawData.subdata(at: blockStart, length: rawData.count - blockStart)

        var order: [String] = []
        var byFolder: [String: [BRRESResource]] = [:]
        for r in resources {
            if byFolder[r.folderName] == nil { order.append(r.folderName) }
            byFolder[r.folderName, default: []].append(r)
        }
        // Stays in the block: read from this file and still the same length at its old offset.
        func staysInBlock(_ r: BRRESResource) -> Bool {
            r.matchesParsedLayout && r.fileOffset >= blockStart && r.fileOffset + r.data.count <= rawData.count
        }

        var cursor = rootSectionStart + 8 + Self.indexGroupByteSize(names: order)
        var folderGroupStart: [String: Int] = [:]
        for name in order {
            folderGroupStart[name] = cursor
            cursor += Self.indexGroupByteSize(names: (byFolder[name] ?? []).map(\.name))
        }
        let metadataEnd = cursor
        var newBlockStart = cursor
        while newBlockStart % 32 != blockStart % 32 { newBlockStart += 1 }
        let delta = newBlockStart - blockStart

        var out = Data(count: newBlockStart)
        out.append(block)
        var resourceOffset: [ObjectIdentifier: Int] = [:]
        for r in resources where staysInBlock(r) {
            let at = r.fileOffset + delta
            resourceOffset[ObjectIdentifier(r)] = at
            out.replaceSubrange(at..<(at + r.data.count), with: r.data)
        }
        for r in resources where !staysInBlock(r) {
            let alignment = Self.alignment(forMagic: r.magic)
            while out.count % alignment != 0 { out.append(0) }
            resourceOffset[ObjectIdentifier(r)] = out.count
            out.append(r.data)
        }
        // Every NW4R sub-file stores a negative offset back to the BRRES header at 0x0C.
        for r in resources {
            guard let at = resourceOffset[ObjectIdentifier(r)], r.data.count >= 0x10 else { continue }
            out.setBE32(UInt32(bitPattern: Int32(-at)), at: at + 0x0C)
        }

        while out.count % 4 != 0 { out.append(0) }
        let poolStart = out.count
        var pool = Data()
        var poolOffsets: [String: Int] = [:]
        func address(_ name: String) -> Int {
            if let existing = poolOffsets[name] { return poolStart + existing }
            let added = Self.appendString(name, to: &pool)
            poolOffsets[name] = added
            return poolStart + added
        }
        let folderNameAddress = order.map(address)
        var resourceNameAddress: [ObjectIdentifier: Int] = [:]
        for r in resources { resourceNameAddress[ObjectIdentifier(r)] = address(r.name) }
        for r in resources {
            for reference in r.stringReferences { _ = address(reference.text) }
        }
        out.append(pool)
        for r in resources where !r.stringReferences.isEmpty {
            guard let start = resourceOffset[ObjectIdentifier(r)] else { continue }
            for reference in r.stringReferences {
                out.setBE32(UInt32(bitPattern: Int32(address(reference.text) - (start + reference.anchorOffset))),
                            at: start + reference.fieldOffset)
            }
        }

        let header = MutableDataWriter()
        header.putData("bres".data(using: .ascii)!)
        header.putU16(0xFEFF); header.putU16(0)
        header.putU32(UInt32(out.count))
        header.putU16(0x10); header.putU16(UInt16(1 + resources.count))
        header.putData("root".data(using: .ascii)!)
        header.putU32(UInt32(metadataEnd - rootSectionStart))
        header.putData(buildIndexGroup(names: order, targetOffsets: order.map { folderGroupStart[$0] ?? 0 },
                                       nameAddresses: folderNameAddress, groupStart: rootSectionStart + 8))
        for name in order {
            let entries = byFolder[name] ?? []
            header.putData(buildIndexGroup(names: entries.map(\.name),
                                           targetOffsets: entries.map { resourceOffset[ObjectIdentifier($0)] ?? 0 },
                                           nameAddresses: entries.map { resourceNameAddress[ObjectIdentifier($0)] ?? 0 },
                                           groupStart: folderGroupStart[name] ?? 0))
        }
        precondition(header.data.count == metadataEnd)
        out.replaceSubrange(0..<metadataEnd, with: header.data)
        return out
    }

    private func rebuildFromScratch() -> Data {
        // Group resources by folder, preserving first-seen folder order.
        var order: [String] = []
        var byFolder: [String: [BRRESResource]] = [:]
        for r in resources {
            if byFolder[r.folderName] == nil { order.append(r.folderName) }
            byFolder[r.folderName, default: []].append(r)
        }

        // Pass 1: lay out absolute offsets for every group and every resource. With names in the
        // shared pool a group is just its node array, which is what makes this reproduce a retail
        // file's own layout exactly, for `map_model.brres` that is a root section of 88 bytes
        // and a first resource at 128, byte for byte what Nintendo's own tools emitted.
        var cursor = rootSectionStart + 8 // file header + "root"+length
        let rootGroupStart = cursor
        cursor += Self.indexGroupByteSize(names: order)

        var folderGroupStart: [String: Int] = [:]
        for name in order {
            folderGroupStart[name] = cursor
            cursor += Self.indexGroupByteSize(names: (byFolder[name] ?? []).map(\.name))
        }

        // The root section's declared length stops at the end of its metadata, before the
        // alignment that follows it.
        let metadataEnd = cursor
        // Only the *first* resource is aligned, by padding the root section out to 0x20. After
        // that they are packed back to back: measured across every BRRES in a retail course
        // archive, the gap between one resource's end and the next one's start is 0 in all 86
        // cases. They look 32-aligned because each one's own size is already a multiple of 32 --
        // an MDL0 pads itself, a TEX0's pixel data lands that way, and where that is not true
        // (a 228-byte SRT0, a 2984-byte SHP0) the next resource starts unaligned.
        // Padding every resource to 0x20 therefore inserted bytes Nintendo's own files do not
        // have, which is what made `course_model.brres` come back 44 bytes too long.
        cursor = (cursor + 31) & ~31

        var resourceOffset: [ObjectIdentifier: Int] = [:]
        var resourceBlob = Data()
        for name in order {
            for r in byFolder[name] ?? [] {
                let alignment = Self.alignment(forMagic: r.magic)
                while (cursor + resourceBlob.count) % alignment != 0 { resourceBlob.append(0) }
                resourceOffset[ObjectIdentifier(r)] = cursor + resourceBlob.count
                resourceBlob.append(r.data)
            }
        }

        // Pass 2: the string pool. The original is carried across verbatim so the offsets already
        // baked into each resource keep resolving and an untouched file comes back byte-identical;
        // any name this container needs that isn't in it yet is appended in the same layout.
        var pool = stringPool
        var poolOffsets = Self.parseStringPool(pool)
        func addressInPool(_ name: String) -> Int {
            if let existing = poolOffsets[name] { return existing }
            let added = Self.appendString(name, to: &pool)
            poolOffsets[name] = added
            return added
        }
        var folderNameAddress: [String: Int] = [:]
        for name in order { folderNameAddress[name] = addressInPool(name) }
        for r in resources {
            for reference in r.stringReferences { _ = addressInPool(reference.text) }
        }
        var resourceNameAddress: [ObjectIdentifier: Int] = [:]
        for name in order {
            for r in byFolder[name] ?? [] { resourceNameAddress[ObjectIdentifier(r)] = addressInPool(r.name) }
        }

        // The pool follows the last resource immediately, with no padding of its own.
        let poolStart = cursor + resourceBlob.count
        let fileLength = poolStart + pool.count

        // Pass 3: emit, now that every target offset is known.
        let rootGroup = buildIndexGroup(names: order,
                                        targetOffsets: order.map { folderGroupStart[$0] ?? 0 },
                                        nameAddresses: order.map { poolStart + (folderNameAddress[$0] ?? 0) },
                                        groupStart: rootGroupStart)
        var folderGroups: [String: Data] = [:]
        for name in order {
            let entries = byFolder[name] ?? []
            folderGroups[name] = buildIndexGroup(
                names: entries.map(\.name),
                targetOffsets: entries.map { resourceOffset[ObjectIdentifier($0)] ?? 0 },
                nameAddresses: entries.map { poolStart + (resourceNameAddress[ObjectIdentifier($0)] ?? 0) },
                groupStart: folderGroupStart[name] ?? 0)
        }

        // Now that both the resources and the pool have addresses, fill in the offsets each
        // resource left blank. The value is self-relative, so it survives the file being embedded
        // somewhere else later.
        for r in resources where !r.stringReferences.isEmpty {
            guard let start = resourceOffset[ObjectIdentifier(r)] else { continue }
            let blobBase = start - cursor
            for reference in r.stringReferences {
                guard let nameOffset = poolOffsets[reference.text] else { continue }
                let value = Int32(poolStart + nameOffset - (start + reference.anchorOffset))
                let at = blobBase + reference.fieldOffset
                guard at >= 0, at + 4 <= resourceBlob.count else { continue }
                let bytes = [UInt8(truncatingIfNeeded: UInt32(bitPattern: value) >> 24),
                             UInt8(truncatingIfNeeded: UInt32(bitPattern: value) >> 16),
                             UInt8(truncatingIfNeeded: UInt32(bitPattern: value) >> 8),
                             UInt8(truncatingIfNeeded: UInt32(bitPattern: value))]
                resourceBlob.replaceSubrange((resourceBlob.startIndex + at)..<(resourceBlob.startIndex + at + 4), with: bytes)
            }
        }

        let w = MutableDataWriter()
        w.putData("bres".data(using: .ascii)!)
        w.putU16(0xFEFF)
        w.putU16(0)
        w.putU32(UInt32(fileLength))
        // Root offset, then the header's own "data block count", confirmed against a real
        // Nintendo-built BRRES to be 1 (the root section) plus every individual *resource*
        // (MDL0/TEX0/CHR0/...), not the folder index-groups in between.
        w.putU16(0x10)
        w.putU16(UInt16(1 + resources.count))

        w.putData("root".data(using: .ascii)!)
        // The "root" section's own length, its metadata only (this index group plus every
        // folder's), stopping before the padding that aligns the first resource.
        w.putU32(UInt32(metadataEnd - rootSectionStart))
        w.putData(rootGroup)
        for name in order { w.putData(folderGroups[name] ?? Data()) }

        w.pad(to: cursor)
        // Every NW4R sub-file stores a negative offset back to the BRRES header at 0x0C. The game
        // reaches the shared string pool and the textures through it; a model built here used to
        // carry 0, so it resolved names and texture links against its own bytes instead.
        for r in resources {
            guard let at = resourceOffset[ObjectIdentifier(r)], r.data.count >= 0x10 else { continue }
            resourceBlob.setBE32(UInt32(bitPattern: Int32(-at)), at: at - cursor + 0x0C)
        }
        w.putData(resourceBlob)
        w.putData(pool)
        return w.data
    }

    private let rootSectionStart = 0x10
}