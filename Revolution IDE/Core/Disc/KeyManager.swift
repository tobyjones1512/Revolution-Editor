import Foundation
import Combine

/// Holds the AES "common key" (and the Korean "kkey") used to decrypt Wii partition title keys.
///
/// This app does not embed the key: you supply your own
/// `key.bin` (16 raw bytes) and, optionally, `kkey.bin` for Korean discs, via File > Load Keys.
/// Nothing is downloaded or guessed.
///
/// Once chosen, a key file is remembered across launches: since the app is sandboxed, plain paths
/// aren't enough (permission to read a user-selected file doesn't survive a relaunch on its own),
/// so a security-scoped bookmark for it is stored in UserDefaults and silently re-resolved next
/// time the app starts, no reprompt, no re-selecting the file.
@MainActor
final class KeyManager: ObservableObject {
    static let shared = KeyManager()

    @Published private(set) var commonKey: [UInt8]?
    @Published private(set) var koreanKey: [UInt8]?
    @Published private(set) var commonKeyPath: String?
    @Published private(set) var koreanKeyPath: String?

    /// True once startup bookmark resolution has run, so callers (AppState) can log what, if
    /// anything, was restored.
    private(set) var restoredCommonKeyOnLaunch = false
    private(set) var restoredKoreanKeyOnLaunch = false

    private let defaults = UserDefaults.standard
    private let commonBookmarkDefaultsKey = "KeyManager.commonKeyBookmark"
    private let koreanBookmarkDefaultsKey = "KeyManager.koreanKeyBookmark"

    private init() {
        restoredCommonKeyOnLaunch = restoreBookmark(defaultsKey: commonBookmarkDefaultsKey) { url in
            try self.applyCommonKey(data: try Data(contentsOf: url), path: url.path)
        }
        restoredKoreanKeyOnLaunch = restoreBookmark(defaultsKey: koreanBookmarkDefaultsKey) { url in
            try self.applyKoreanKey(data: try Data(contentsOf: url), path: url.path)
        }
    }

    func loadCommonKey(from url: URL) throws {
        try applyCommonKey(data: try Data(contentsOf: url), path: url.path)
        saveBookmark(for: url, defaultsKey: commonBookmarkDefaultsKey)
    }

    func loadKoreanKey(from url: URL) throws {
        try applyKoreanKey(data: try Data(contentsOf: url), path: url.path)
        saveBookmark(for: url, defaultsKey: koreanBookmarkDefaultsKey)
    }

    private func applyCommonKey(data: Data, path: String) throws {
        guard data.count == 16 else { throw WSError.ioError("key.bin must be exactly 16 bytes (got \(data.count)).") }
        commonKey = [UInt8](data)
        commonKeyPath = path
    }

    private func applyKoreanKey(data: Data, path: String) throws {
        guard data.count == 16 else { throw WSError.ioError("kkey.bin must be exactly 16 bytes (got \(data.count)).") }
        koreanKey = [UInt8](data)
        koreanKeyPath = path
    }

    /// Forgets a remembered key (and its bookmark), e.g. if the user wants to pick a different file.
    func forgetCommonKey() {
        commonKey = nil
        commonKeyPath = nil
        defaults.removeObject(forKey: commonBookmarkDefaultsKey)
    }

    func forgetKoreanKey() {
        koreanKey = nil
        koreanKeyPath = nil
        defaults.removeObject(forKey: koreanBookmarkDefaultsKey)
    }

    private func saveBookmark(for url: URL, defaultsKey: String) {
        do {
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            defaults.set(data, forKey: defaultsKey)
        } catch {
            // Non-fatal: the key still works for this session, it just won't be remembered next launch.
        }
    }

    /// Resolves a previously-saved bookmark (if any) and, on success, runs `use` with
    /// security-scoped access active. Returns whether a key was actually restored.
    @discardableResult
    private func restoreBookmark(defaultsKey: String, use: (URL) throws -> Void) -> Bool {
        guard let data = defaults.data(forKey: defaultsKey) else { return false }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                  relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            defaults.removeObject(forKey: defaultsKey)
            return false
        }
        guard url.startAccessingSecurityScopedResource() else { return false }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            try use(url)
        } catch {
            return false
        }
        if isStale { saveBookmark(for: url, defaultsKey: defaultsKey) }
        return true
    }

    /// Auto-load key.bin/kkey.bin if they sit next to the opened ISO, mirroring the original
    /// tool's "same directory as the exe" convention (here: same directory as the loaded ISO).
    func autoLoad(nextTo isoURL: URL) {
        let dir = isoURL.deletingLastPathComponent()
        let keyURL = dir.appendingPathComponent("key.bin")
        let kkeyURL = dir.appendingPathComponent("kkey.bin")
        if commonKey == nil, FileManager.default.fileExists(atPath: keyURL.path) {
            try? loadCommonKey(from: keyURL)
        }
        if koreanKey == nil, FileManager.default.fileExists(atPath: kkeyURL.path) {
            try? loadKoreanKey(from: kkeyURL)
        }
    }

    func key(for commonKeyIndex: UInt8) throws -> [UInt8] {
        switch commonKeyIndex {
        case 0:
            guard let k = commonKey else { throw WSError.keyMissing("key.bin (common key) not loaded.") }
            return k
        case 1:
            guard let k = koreanKey else { throw WSError.keyMissing("kkey.bin (Korean key) not loaded.") }
            return k
        default:
            guard let k = commonKey else { throw WSError.keyMissing("key.bin (common key) not loaded.") }
            return k
        }
    }
}
