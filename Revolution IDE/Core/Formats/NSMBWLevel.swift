import Foundation

/// New Super Mario Bros. Wii level data.
///
/// A level file is a U8 archive (see `U8Archive.swift`, the identical container this app
/// already uses for `.szs`/`.arc`) containing a `course` folder with up to 4 areas: for each
/// area N, a `courseN.bin` main-data file plus up to three `courseN_bgdatL{0,1,2}.bin` object
/// layer files (layer 1 always present; 0 and 2 optional).
///
/// This is a from-scratch reimplementation: no code from any existing NSMBW editor is used here.
/// The binary layout facts below (block table shape, per-entry field widths) were cross-checked
/// against the open-source Reggie Next level editor
/// (https://github.com/NSMBW-Community/Reggie-Next) purely to avoid guessing offsets, the same
/// way this app's other from-scratch format readers (BRRES/MDL0) were checked against reference
/// tools/sources after an earlier guess turned out wrong. Every struct/field name and all of the
/// Swift below is original.
///
/// `courseN.bin` is a fixed table of 14 (offset: u32, length: u32) blocks, all big-endian, each
/// pointing at a byte range later in the same file:
///   0  tileset names (four 32-byte, NUL-padded, Latin-1 strings)
///   1  area options
///   2  zone scroll-bounds (one 24-byte entry per zone)
///   3  extra options
///   4  background layer "A" entries (one 24-byte entry per zone)
///   5  background layer "B" entries (one 24-byte entry per zone)
///   6  entrances (one 20-byte entry each)
///   7  sprites (one 16-byte entry each, list terminated by 4 trailing 0xFF bytes)
///   8  IDs of sprite resources the game should keep loaded (one 4-byte entry each)
///   9  zones (one 24-byte entry each)
///   10 locations (one 12-byte entry each)
///   11 camera profiles (one 20-byte entry each)
///   12 paths (one 8-byte entry each)
///   13 path nodes (one 16-byte entry each, referenced by a path's start-index/count)
///
/// Blocks 2, 3, 4, 5, 8 and 11 aren't decoded into named fields (their exact per-byte meaning
/// wasn't confidently pinned down), they're preserved byte-for-byte across load/save instead of
/// guessed at, this app's usual approach for data it doesn't fully understand yet.
nonisolated struct NSMBWTilesetNames: Equatable {
    var slot0 = "", slot1 = "", slot2 = "", slot3 = ""
}

nonisolated struct NSMBWAreaOptions: Equatable {
    var eventBitsLow: UInt32 = 0
    var eventBitsHigh: UInt32 = 0
    var wrapSettings: UInt16 = 0
    var timeLimit: Int16 = 200
    var creditsFlag: Bool = false
    var unknownByte: UInt8 = 0
    var startEntrance: UInt8 = 0
    var faceLeftFlag: Bool = false
    var toadHouseType: UInt8 = 0
}

nonisolated struct NSMBWZone: Identifiable {
    let id = UUID()
    var x: Int, y: Int, width: Int, height: Int
    var modelId: UInt16
    var cameraProfile: UInt16
    var zoneId: UInt8, boundingId: UInt8, cameraBoundingId: UInt8, bgId: UInt8
    var visibility: UInt8, cameraModeId: UInt8, zoneType: UInt8, musicId: UInt8
}

nonisolated struct NSMBWEntrance: Identifiable {
    let id = UUID()
    var x: Int, y: Int
    var entranceId: UInt8
    var destArea: UInt8, destEntrance: UInt8
    var entranceType: UInt8
    var zoneId: UInt8, layerId: UInt8, pathId: UInt8
    var settings: UInt16
    var leaveLevelValue: UInt8
    var coinPortalDirection: UInt8
}

nonisolated struct NSMBWSprite: Identifiable {
    let id = UUID()
    var spriteType: UInt16
    var x: Int, y: Int
    /// The 8 raw settings bytes (usually shown/edited as nibbles by real sprite-specific UI --
    /// this app doesn't have per-sprite-type field definitions, so they're exposed as raw bytes).
    var settings: [UInt8] // always 8 bytes

    init(spriteType: UInt16, x: Int, y: Int, settings: [UInt8]) {
        self.spriteType = spriteType; self.x = x; self.y = y
        self.settings = settings.count == 8 ? settings : [UInt8](repeating: 0, count: 8)
    }
}

nonisolated struct NSMBWLocation: Identifiable {
    let id = UUID()
    var x: Int, y: Int, width: Int, height: Int
    var locationId: UInt8
}

nonisolated struct NSMBWPathNode: Identifiable {
    let id = UUID()
    var x: Int, y: Int
    var speed: Float = 1, accel: Float = 0
    var delay: Int16 = 0
}

nonisolated struct NSMBWPath: Identifiable {
    let id = UUID()
    var pathId: UInt8
    var loops: Bool
    var nodes: [NSMBWPathNode]
}

nonisolated struct NSMBWObject: Identifiable {
    let id = UUID()
    var tilesetIndex: Int   // which of the 4 tileset slots this object's shape comes from
    var objectId: Int
    var layer: Int          // 0, 1, or 2
    var x: Int, y: Int, width: Int, height: Int
}

/// One area (course) inside a level archive.
nonisolated final class NSMBWArea {
    var areaNumber: Int
    var tilesetNames = NSMBWTilesetNames()
    var options = NSMBWAreaOptions()
    var zones: [NSMBWZone] = []
    var entrances: [NSMBWEntrance] = []
    var sprites: [NSMBWSprite] = []
    var locations: [NSMBWLocation] = []
    var paths: [NSMBWPath] = []
    var objects: [NSMBWObject] = []

    /// Blocks this app round-trips unchanged rather than modeling (see file doc comment).
    var opaqueZoneBounds = Data()
    var opaqueExtraOptions = Data()
    var opaqueBackgroundA = Data()
    var opaqueBackgroundB = Data()
    var opaqueLoadedSpriteIDs = Data()
    var opaqueCameraProfiles = Data()

    init(areaNumber: Int) { self.areaNumber = areaNumber }
}

nonisolated final class NSMBWLevelDocument {
    var areas: [NSMBWArea] = []

    static func parse(root: U8Node) throws -> NSMBWLevelDocument {
        guard let courseDir = root.children.first(where: { $0.isDirectory && $0.name == "course" }) else {
            throw WSError.badStructure("Not an NSMBW level (no 'course' folder).")
        }
        let doc = NSMBWLevelDocument()
        for areaNum in 1...4 {
            guard let mainFile = courseDir.children.first(where: { !$0.isDirectory && $0.name == "course\(areaNum).bin" }),
                  let mainData = mainFile.data else { continue }
            let area = NSMBWArea(areaNumber: areaNum)
            try area.load(course: mainData, layers: (0...2).map { l in
                courseDir.children.first(where: { !$0.isDirectory && $0.name == "course\(areaNum)_bgdatL\(l).bin" })?.data
            })
            doc.areas.append(area)
        }
        guard !doc.areas.isEmpty else {
            throw WSError.badStructure("NSMBW level archive has no readable areas.")
        }
        return doc
    }

    /// Writes every area back into (a copy of) the U8 tree it was parsed from, replacing the
    /// `course` folder's files in place.
    func write(into root: U8Node) {
        guard let courseDir = root.children.first(where: { $0.isDirectory && $0.name == "course" }) else { return }
        for area in areas {
            let (course, l0, l1, l2) = area.save()
            setFile(in: courseDir, name: "course\(area.areaNumber).bin", data: course)
            setFile(in: courseDir, name: "course\(area.areaNumber)_bgdatL1.bin", data: l1)
            if let l0 { setFile(in: courseDir, name: "course\(area.areaNumber)_bgdatL0.bin", data: l0) }
            if let l2 { setFile(in: courseDir, name: "course\(area.areaNumber)_bgdatL2.bin", data: l2) }
        }
    }

    private func setFile(in dir: U8Node, name: String, data: Data) {
        if let existing = dir.children.first(where: { !$0.isDirectory && $0.name == name }) {
            existing.data = data
        } else {
            let node = U8Node(name: name, isDirectory: false, data: data)
            node.parent = dir
            dir.children.append(node)
        }
    }

    // MARK: Undo/redo snapshots

    /// One `EditHistory` snapshot covering every area's current state, built from each area's
    /// own already-trusted `save()` (the same one every real Save already goes through), not a
    /// separate ad-hoc serialization. `NSMBWAreaEditorView`/`NSMBWDocumentBox` previously had no
    /// undo at all; Cmd-Z did nothing and the only way back from a mistaken edit was closing the
    /// window without saving.
    func snapshotData() -> Data {
        let w = MutableDataWriter()
        w.putU32(UInt32(areas.count))
        for area in areas {
            let (course, l0, l1, l2) = area.save()
            w.putU32(UInt32(area.areaNumber))
            Self.putBlob(w, course)
            Self.putBlob(w, l0)
            Self.putBlob(w, l1)
            Self.putBlob(w, l2)
        }
        return w.data
    }

    /// Rebuilds a document from a `snapshotData()` blob via each area's own `load()`, mirroring
    /// how `parse(root:)` builds one from a real archive.
    static func restoring(from snapshot: Data) throws -> NSMBWLevelDocument {
        var offset = 0
        func readU32() throws -> UInt32 {
            guard offset + 4 <= snapshot.count else { throw WSError.badStructure("Corrupt NSMBW undo snapshot.") }
            let v = snapshot.be32(offset); offset += 4
            return v
        }
        func readBlob() throws -> Data? {
            let len = try readU32()
            guard len != 0xFFFFFFFF else { return nil } // sentinel for "no layer" vs. a real 0-length one
            guard offset + Int(len) <= snapshot.count else { throw WSError.badStructure("Corrupt NSMBW undo snapshot.") }
            let d = snapshot.subdata(at: offset, length: Int(len)); offset += Int(len)
            return d
        }
        let count = try readU32()
        let doc = NSMBWLevelDocument()
        for _ in 0..<count {
            let areaNumber = try readU32()
            guard let course = try readBlob() else { throw WSError.badStructure("Corrupt NSMBW undo snapshot.") }
            let l0 = try readBlob()
            guard let l1 = try readBlob() else { throw WSError.badStructure("Corrupt NSMBW undo snapshot.") }
            let l2 = try readBlob()
            let area = NSMBWArea(areaNumber: Int(areaNumber))
            try area.load(course: course, layers: [l0, l1, l2])
            doc.areas.append(area)
        }
        return doc
    }

    private static func putBlob(_ w: MutableDataWriter, _ data: Data?) {
        guard let data else { w.putU32(0xFFFFFFFF); return } // sentinel: "nil" vs. a real empty blob
        w.putU32(UInt32(data.count))
        w.putData(data)
    }
}

private nonisolated extension NSMBWArea {
    struct BlockTable { var offsets: [Int]; var lengths: [Int] }

    static func readBlockTable(_ d: Data) -> BlockTable {
        var offsets: [Int] = [], lengths: [Int] = []
        for i in 0..<14 {
            offsets.append(Int(d.be32(i * 8)))
            lengths.append(Int(d.be32(i * 8 + 4)))
        }
        return BlockTable(offsets: offsets, lengths: lengths)
    }

    func block(_ d: Data, _ table: BlockTable, _ index: Int) -> Data {
        let off = table.offsets[index], len = table.lengths[index]
        guard off >= 0, len >= 0, off + len <= d.count else { return Data() }
        return d.subdata(at: off, length: len)
    }

    func load(course d: Data, layers: [Data?]) throws {
        guard d.count >= 14 * 8 else { throw WSError.badStructure("NSMBW course data is too short.") }
        let table = Self.readBlockTable(d)

        // Block 0: tileset names.
        let names = block(d, table, 0)
        if names.count >= 128 {
            tilesetNames = NSMBWTilesetNames(
                slot0: names.asciiString(at: 0, length: 32),
                slot1: names.asciiString(at: 32, length: 32),
                slot2: names.asciiString(at: 64, length: 32),
                slot3: names.asciiString(at: 96, length: 32))
        }

        // Block 1: area options (20 bytes: u32 u32 u16 i16 bool u8 [2 pad] u8 bool u8 [1 pad]).
        let opt = block(d, table, 1)
        if opt.count >= 20 {
            options = NSMBWAreaOptions(
                eventBitsLow: opt.be32(0), eventBitsHigh: opt.be32(4),
                wrapSettings: opt.be16(8), timeLimit: opt.beInt16(10),
                creditsFlag: opt.u8(12) != 0, unknownByte: opt.u8(13),
                startEntrance: opt.u8(16), faceLeftFlag: opt.u8(17) != 0, toadHouseType: opt.u8(18))
        }

        opaqueZoneBounds = block(d, table, 2)
        opaqueExtraOptions = block(d, table, 3)
        opaqueBackgroundA = block(d, table, 4)
        opaqueBackgroundB = block(d, table, 5)

        // Block 6: entrances, 20 bytes each.
        let entData = block(d, table, 6)
        var loadedEntrances: [NSMBWEntrance] = []
        var eOff = 0
        while eOff + 20 <= entData.count {
            loadedEntrances.append(NSMBWEntrance(
                x: Int(entData.be16(eOff)), y: Int(entData.be16(eOff + 2)),
                entranceId: entData.u8(eOff + 8), destArea: entData.u8(eOff + 9),
                destEntrance: entData.u8(eOff + 10), entranceType: entData.u8(eOff + 11),
                zoneId: entData.u8(eOff + 13), layerId: entData.u8(eOff + 14), pathId: entData.u8(eOff + 15),
                settings: entData.be16(eOff + 16), leaveLevelValue: entData.u8(eOff + 18),
                coinPortalDirection: entData.u8(eOff + 19)))
            eOff += 20
        }
        entrances = loadedEntrances

        // Block 7: sprites, 16 bytes each; trailing 4 bytes are a 0xFFFFFFFF terminator.
        let sprData = block(d, table, 7)
        var loadedSprites: [NSMBWSprite] = []
        var sOff = 0
        while sOff + 16 <= sprData.count - 4 {
            loadedSprites.append(NSMBWSprite(
                spriteType: sprData.be16(sOff), x: Int(sprData.beInt16(sOff + 2)), y: Int(sprData.beInt16(sOff + 4)),
                settings: (0..<8).map { sprData.u8(sOff + 6 + $0) }))
            sOff += 16
        }
        sprites = loadedSprites

        opaqueLoadedSpriteIDs = block(d, table, 8)

        // Block 9: zones, 24 bytes each.
        let zoneData = block(d, table, 9)
        var loadedZones: [NSMBWZone] = []
        var zOff = 0
        while zOff + 24 <= zoneData.count {
            loadedZones.append(NSMBWZone(
                x: Int(zoneData.be16(zOff)), y: Int(zoneData.be16(zOff + 2)),
                width: Int(zoneData.be16(zOff + 4)), height: Int(zoneData.be16(zOff + 6)),
                modelId: zoneData.be16(zOff + 8), cameraProfile: zoneData.be16(zOff + 10),
                zoneId: zoneData.u8(zOff + 12), boundingId: zoneData.u8(zOff + 13),
                cameraBoundingId: zoneData.u8(zOff + 14), bgId: zoneData.u8(zOff + 15),
                visibility: zoneData.u8(zOff + 17), cameraModeId: zoneData.u8(zOff + 18),
                zoneType: zoneData.u8(zOff + 19), musicId: zoneData.u8(zOff + 22)))
            zOff += 24
        }
        zones = loadedZones

        // Block 10: locations, 12 bytes each.
        let locData = block(d, table, 10)
        var loadedLocations: [NSMBWLocation] = []
        var lOff = 0
        while lOff + 12 <= locData.count {
            loadedLocations.append(NSMBWLocation(
                x: Int(locData.be16(lOff)), y: Int(locData.be16(lOff + 2)),
                width: Int(locData.be16(lOff + 4)), height: Int(locData.be16(lOff + 6)),
                locationId: locData.u8(lOff + 8)))
            lOff += 12
        }
        locations = loadedLocations

        opaqueCameraProfiles = block(d, table, 11)

        // Blocks 12/13: paths + path nodes, 8 and 16 bytes each respectively.
        let pathData = block(d, table, 12)
        let nodeData = block(d, table, 13)
        var loadedPaths: [NSMBWPath] = []
        var pOff = 0
        while pOff + 8 <= pathData.count {
            let pathId = pathData.u8(pOff)
            let startIndex = Int(pathData.be16(pOff + 2))
            let count = Int(pathData.be16(pOff + 4))
            let loops = pathData.be16(pOff + 6) == 2
            var nodes: [NSMBWPathNode] = []
            for i in 0..<count {
                let nOff = (startIndex + i) * 16
                guard nOff + 16 <= nodeData.count else { break }
                nodes.append(NSMBWPathNode(
                    x: Int(nodeData.be16(nOff)), y: Int(nodeData.be16(nOff + 2)),
                    speed: nodeData.beFloat32(nOff + 4), accel: nodeData.beFloat32(nOff + 8),
                    delay: nodeData.beInt16(nOff + 12)))
            }
            loadedPaths.append(NSMBWPath(pathId: pathId, loops: loops, nodes: nodes))
            pOff += 8
        }
        paths = loadedPaths

        // Object layers: separate files, 10 bytes per object, trailing 2-byte 0xFFFF terminator.
        var loadedObjects: [NSMBWObject] = []
        for (layerIdx, layerData) in layers.enumerated() {
            guard let layerData else { continue }
            var oOff = 0
            while oOff + 10 <= layerData.count - 2 {
                let packed = layerData.be16(oOff)
                loadedObjects.append(NSMBWObject(
                    tilesetIndex: Int(packed >> 12), objectId: Int(packed & 0x0FFF), layer: layerIdx,
                    x: Int(layerData.be16(oOff + 2)), y: Int(layerData.be16(oOff + 4)),
                    width: Int(layerData.be16(oOff + 6)), height: Int(layerData.be16(oOff + 8))))
                oOff += 10
            }
        }
        objects = loadedObjects
    }

    /// Serializes this area back to (course, layer0, layer1, layer2) data, laying the 14 blocks
    /// out sequentially in the same order they were read (mirroring the original layout closely
    /// keeps this simple and avoids re-deriving Nintendo's exact allocation strategy).
    func save() -> (course: Data, l0: Data?, l1: Data, l2: Data?) {
        var blocks: [Data] = []

        var names = Data()
        for s in [tilesetNames.slot0, tilesetNames.slot1, tilesetNames.slot2, tilesetNames.slot3] {
            var bytes = Array(s.prefix(32).utf8)
            bytes.append(contentsOf: [UInt8](repeating: 0, count: 32 - bytes.count))
            names.append(contentsOf: bytes)
        }
        blocks.append(names)

        let optW = MutableDataWriter()
        optW.putU32(options.eventBitsLow); optW.putU32(options.eventBitsHigh)
        optW.putU16(options.wrapSettings); optW.putInt16(options.timeLimit)
        optW.putU8(options.creditsFlag ? 1 : 0); optW.putU8(options.unknownByte)
        optW.putU8(0); optW.putU8(0)
        optW.putU8(options.startEntrance); optW.putU8(options.faceLeftFlag ? 1 : 0); optW.putU8(options.toadHouseType)
        optW.putU8(0)
        blocks.append(optW.data)

        blocks.append(opaqueZoneBounds)
        blocks.append(opaqueExtraOptions)
        blocks.append(opaqueBackgroundA)
        blocks.append(opaqueBackgroundB)

        let entW = MutableDataWriter()
        for e in entrances {
            entW.putU16(UInt16(clamping: e.x)); entW.putU16(UInt16(clamping: e.y))
            entW.pad(to: entW.data.count + 4)
            entW.putU8(e.entranceId); entW.putU8(e.destArea); entW.putU8(e.destEntrance); entW.putU8(e.entranceType)
            entW.putU8(0)
            entW.putU8(e.zoneId); entW.putU8(e.layerId); entW.putU8(e.pathId)
            entW.putU16(e.settings)
            entW.putU8(e.leaveLevelValue); entW.putU8(e.coinPortalDirection)
        }
        blocks.append(entW.data)

        let sprW = MutableDataWriter()
        for s in sprites {
            sprW.putU16(s.spriteType); sprW.putInt16(Int16(clamping: s.x)); sprW.putInt16(Int16(clamping: s.y))
            for b in s.settings { sprW.putU8(b) }
            sprW.putU16(0)
        }
        sprW.putU32(0xFFFFFFFF)
        blocks.append(sprW.data)

        blocks.append(opaqueLoadedSpriteIDs)

        let zoneW = MutableDataWriter()
        for z in zones {
            zoneW.putU16(UInt16(clamping: z.x)); zoneW.putU16(UInt16(clamping: z.y))
            zoneW.putU16(UInt16(clamping: z.width)); zoneW.putU16(UInt16(clamping: z.height))
            zoneW.putU16(z.modelId); zoneW.putU16(z.cameraProfile)
            zoneW.putU8(z.zoneId); zoneW.putU8(z.boundingId); zoneW.putU8(z.cameraBoundingId); zoneW.putU8(z.bgId)
            zoneW.putU8(0)
            zoneW.putU8(z.visibility); zoneW.putU8(z.cameraModeId); zoneW.putU8(z.zoneType)
            zoneW.putU8(0); zoneW.putU8(0)
            zoneW.putU8(z.musicId)
            zoneW.putU8(0)
        }
        blocks.append(zoneW.data)

        let locW = MutableDataWriter()
        for l in locations {
            locW.putU16(UInt16(clamping: l.x)); locW.putU16(UInt16(clamping: l.y))
            locW.putU16(UInt16(clamping: l.width)); locW.putU16(UInt16(clamping: l.height))
            locW.putU8(l.locationId)
            locW.pad(to: locW.data.count + 3)
        }
        blocks.append(locW.data)

        blocks.append(opaqueCameraProfiles)

        let pathW = MutableDataWriter()
        let nodeW = MutableDataWriter()
        var nodeCursor = 0
        for p in paths {
            pathW.putU8(p.pathId); pathW.putU8(0)
            pathW.putU16(UInt16(clamping: nodeCursor)); pathW.putU16(UInt16(clamping: p.nodes.count))
            pathW.putU16(p.loops ? 2 : 0)
            for n in p.nodes {
                nodeW.putU16(UInt16(clamping: n.x)); nodeW.putU16(UInt16(clamping: n.y))
                nodeW.putFloat32(n.speed); nodeW.putFloat32(n.accel)
                nodeW.putInt16(n.delay); nodeW.putU8(0); nodeW.putU8(0)
            }
            nodeCursor += p.nodes.count
        }
        blocks.append(pathW.data)
        blocks.append(nodeW.data)

        let header = MutableDataWriter()
        var cursor = 14 * 8
        for b in blocks {
            header.putU32(UInt32(cursor))
            header.putU32(UInt32(b.count))
            cursor += b.count
        }
        let course = MutableDataWriter()
        course.putData(header.data)
        for b in blocks { course.putData(b) }

        var layerData: [Data] = [Data(), Data(), Data()]
        for layerIdx in 0..<3 {
            let w = MutableDataWriter()
            for o in objects where o.layer == layerIdx {
                let packed = (UInt16(o.tilesetIndex & 0xF) << 12) | UInt16(o.objectId & 0x0FFF)
                w.putU16(packed)
                w.putU16(UInt16(clamping: o.x)); w.putU16(UInt16(clamping: o.y))
                w.putU16(UInt16(clamping: o.width)); w.putU16(UInt16(clamping: o.height))
            }
            w.putU16(0xFFFF)
            layerData[layerIdx] = w.data
        }
        return (course.data, layerData[0].count > 2 ? layerData[0] : nil, layerData[1], layerData[2].count > 2 ? layerData[2] : nil)
    }
}
