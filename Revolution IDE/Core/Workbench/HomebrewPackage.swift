import Foundation
import AppKit

/// Homebrew Channel metadata, kept in `<project>/meta.json` and `<project>/icon.png` (128x48).
/// Each build writes a ready-to-copy `out/apps/<name>/{boot.dol,meta.xml,icon.png}`.
nonisolated struct HomebrewMeta: Codable, Equatable {
    var name = ""
    var coder = ""
    var version = "1.0"
    var shortDescription = ""
    var longDescription = ""

    static func url(in project: URL) -> URL { project.appendingPathComponent("meta.json") }
    static func iconURL(in project: URL) -> URL { project.appendingPathComponent("icon.png") }

    static func load(project: URL) -> HomebrewMeta {
        var m = (try? JSONDecoder().decode(HomebrewMeta.self, from: Data(contentsOf: url(in: project)))) ?? HomebrewMeta()
        if m.name.isEmpty { m.name = project.lastPathComponent }
        return m
    }

    func save(project: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: Self.url(in: project), options: .atomic)
    }

    var xml: String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMddHHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <app version="1">
          <name>\(esc(name))</name>
          <coder>\(esc(coder))</coder>
          <version>\(esc(version))</version>
          <release_date>\(f.string(from: Date()))</release_date>
          <short_description>\(esc(shortDescription))</short_description>
          <long_description>\(esc(longDescription))</long_description>
        </app>

        """
    }

    /// Scales (letterboxed, transparent) any image to the Homebrew Channel's 128x48 icon and saves it.
    static func setIcon(from source: URL, project: URL) throws {
        guard let img = NSImage(contentsOf: source) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "That isn't an image I can read."])
        }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 48, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { throw CocoaError(.fileWriteUnknown) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let s = min(128 / img.size.width, 48 / img.size.height)
        let w = img.size.width * s, h = img.size.height * s
        img.draw(in: NSRect(x: (128 - w) / 2, y: (48 - h) / 2, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: iconURL(in: project), options: .atomic)
    }
}

nonisolated enum HomebrewPackage {
    /// Folder name used under `apps/` (the Homebrew Channel needs a plain one).
    static func appFolder(project: URL) -> String { HomebrewTemplate.safeName(project.lastPathComponent) }

    /// Writes `<project>/out/apps/<name>/` from a built `.dol`.
    @discardableResult
    static func write(project: URL, dol: URL) throws -> URL {
        let fm = FileManager.default
        let dir = project.appendingPathComponent("out/apps/\(appFolder(project: project))", isDirectory: true)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.copyItem(at: dol, to: dir.appendingPathComponent("boot.dol"))
        try HomebrewMeta.load(project: project).xml.write(to: dir.appendingPathComponent("meta.xml"), atomically: true, encoding: .utf8)
        let icon = HomebrewMeta.iconURL(in: project)
        if fm.fileExists(atPath: icon.path) { try fm.copyItem(at: icon, to: dir.appendingPathComponent("icon.png")) }
        return dir
    }

    /// Dolphin's "sync SD card with folder" directory (Config > Wii > SD Card > Automatically sync with folder).
    static var dolphinSDFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Dolphin/Load/WiiSDSync", isDirectory: true)
    }

    static var dolphinUserDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Dolphin", isDirectory: true)
    }

    /// The Homebrew Channel's title ID if it's installed on Dolphin's Wii NAND (OpenShop "HAXX" or "LULZ").
    static var channelTitleID: String? {
        ["000100014c554c5a", "0001000148415858"].first {
            FileManager.default.fileExists(atPath: dolphinUserDir.appendingPathComponent("Wii/title/00010001/\($0.suffix(8))").path)
        }
    }

    /// Turns on Dolphin's "Automatically sync with folder" SD card (and inserts it), via `[Core]` in Dolphin.ini.
    /// Call while Dolphin isn't running, or it overwrites the file on exit.
    static func enableSDSync() {
        let fm = FileManager.default
        let ini = dolphinUserDir.appendingPathComponent("Config/Dolphin.ini")
        try? fm.createDirectory(at: ini.deletingLastPathComponent(), withIntermediateDirectories: true)
        var lines = ((try? String(contentsOf: ini, encoding: .utf8)) ?? "").components(separatedBy: "\n")
        if !lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "[Core]" }) { lines.insert("[Core]", at: 0) }
        let header = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "[Core]" }!
        let end = lines[(header + 1)...].firstIndex { $0.hasPrefix("[") } ?? lines.count
        for (key, value) in [("WiiSDCard", "True"), ("WiiSDCardEnableFolderSync", "True")] {
            let line = "\(key) = \(value)"
            if let i = lines[(header + 1)..<end].firstIndex(where: { $0.hasPrefix(key + " ") || $0.hasPrefix(key + "=") }) { lines[i] = line }
            else { lines.insert(line, at: header + 1) }
        }
        try? lines.joined(separator: "\n").write(to: ini, atomically: true, encoding: .utf8)
    }

    static func dolphinAppDir(project: URL) -> URL {
        dolphinSDFolder.appendingPathComponent("apps/\(appFolder(project: project))", isDirectory: true)
    }

    /// Copies a project file or folder to the same relative path inside the app's folder on Dolphin's SD card.
    static func addToDolphinSD(_ item: URL, project: URL) throws -> URL {
        let fm = FileManager.default
        let root = project.standardizedFileURL.path, p = item.standardizedFileURL.path
        guard p.hasPrefix(root + "/") else { throw CocoaError(.fileNoSuchFile) }
        let dest = dolphinAppDir(project: project).appendingPathComponent(String(p.dropFirst(root.count + 1)))
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: dest)
        try fm.copyItem(at: item, to: dest)
        return dest
    }

    /// Installs the built app (boot.dol, meta.xml, icon.png) so it shows up in the Homebrew Channel.
    static func installToDolphinSD(project: URL) throws -> URL {
        let fm = FileManager.default
        let built = project.appendingPathComponent("out/apps/\(appFolder(project: project))", isDirectory: true)
        guard fm.fileExists(atPath: built.appendingPathComponent("boot.dol").path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Build the project first."])
        }
        let dest = dolphinAppDir(project: project)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for f in try fm.contentsOfDirectory(at: built, includingPropertiesForKeys: nil) {
            let to = dest.appendingPathComponent(f.lastPathComponent)
            try? fm.removeItem(at: to)
            try fm.copyItem(at: f, to: to)
        }
        return dest
    }
}
