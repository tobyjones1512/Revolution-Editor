import Foundation

/// The Double Dash disc the user has linked, read for each slot's minimap rectangle (in
/// `main.dol`) when building or porting a course. Kept as a security-scoped bookmark, like the
/// Mario Kart Wii base game.
nonisolated enum DoubleDashDisc {
    static let bookmarkKey = "DoubleDash.isoBookmark"

    static var linkedISO: URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        return url
    }

    static func unlink() { UserDefaults.standard.removeObject(forKey: bookmarkKey) }

    static func link(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        if let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        }
    }

    private static let indexLock = NSLock()
    nonisolated(unsafe) private static var cachedIndex: (path: String, files: [String: Data])?

    /// Every retail course's object files (see `MKDDObjectFiles.index`), read once per linked disc.
    static func objectFiles() throws -> [String: Data] {
        guard let iso = linkedISO else { throw WSError.badStructure("No Double Dash disc is linked.") }
        indexLock.lock(); defer { indexLock.unlock() }
        if let c = cachedIndex, c.path == iso.path { return c.files }
        let files = try MKDDObjectFiles.index(GameCubeDisc(url: iso))
        cachedIndex = (iso.path, files)
        return files
    }

    /// The slot's minimap rectangle from the linked disc, or nil (with why) when it can't be read.
    static func minimap(for slot: MKDDSlots.Slot) -> (MKDDSlots.Minimap?, String?) {
        guard let iso = linkedISO else { return (nil, "No Double Dash disc linked") }
        guard let disc = try? GameCubeDisc(url: iso), let region = MKDDSlots.region(gameID: disc.gameID) else { return (nil, "The linked disc isn't Mario Kart: Double Dash!!") }
        guard let dol = try? MKDDSlots.dol(fromDisc: iso), let m = MKDDSlots.minimap(for: slot, dol: dol, region: region) else {
            return (nil, "Couldn't read \(slot.title)'s minimap from the disc's main.dol")
        }
        return (m, nil)
    }
}

