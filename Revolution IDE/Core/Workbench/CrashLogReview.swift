import Foundation

/// Reads Dolphin's own log (and macOS's crash reports for Dolphin) for the last crash, explains
/// it in plain English and keeps the raw lines around it for anyone who'd rather read those.
nonisolated enum CrashLogReview {
    struct Finding: Identifiable {
        let id = UUID()
        let title: String
        let what: String
        let fixes: [String]
        /// The log line that matched, trimmed.
        let evidence: String
    }

    struct Report {
        var logURL: URL?
        var logDate: Date?
        var findings: [Finding] = []
        /// The lines around the last crash, as written.
        var excerpt = ""
        /// The last files the game read before the crash, newest last.
        var lastFiles: [String] = []
        /// A macOS crash report for Dolphin itself, when one exists.
        var systemReport: String?
        var problem: String?
    }

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Dolphin/Logs/dolphin.log")
    }

    private struct Rule {
        let pattern: String
        let title: String
        let what: String
        let fixes: [String]
    }

    // Most specific first: the first rule to match a line explains it.
    private static let rules: [Rule] = [
        Rule(pattern: #"Invalid (read|write) (from|to) 0x0000[0-9a-fA-F]{4}\b"#,
             title: "The game used something that doesn't exist",
             what: "A piece of the game's code tried to read or write memory at an address near zero. That nearly always means it looked for a model, route, camera, object or file that wasn't there and carried on as if it was. A real Wii freezes on this.",
             fixes: ["Run Verify Archive on the course. It lists broken links between objects, routes, cameras and paths.",
                     "Check every object has its model files in the course archive or beside it (Missing Object Files banner in the KMP editor).",
                     "Look for an Area or Camera that points at a Route or Camera that was deleted, and for an item path with no previous group.",
                     "If it only happens after a recent edit, undo that edit or save a copy and bisect: remove half of what you added and test again."]),
        Rule(pattern: #"Invalid (read|write) (from|to) 0x[0-9a-fA-F]+"#,
             title: "The game touched memory it shouldn't",
             what: "The game read or wrote an address that isn't mapped. Usually a corrupt or oversized file was loaded, or a count or offset inside a file is wrong.",
             fixes: ["Run Verify Archive and fix everything it flags.",
                     "Re-export or rebuild the last file you changed (KMP, KCL, BRRES) and test again.",
                     "If you edited a model, check it hasn't grown far past the original's polygon or texture size."]),
        Rule(pattern: #"FIFO: Unknown Opcode|GFX FIFO: Unknown Opcode"#,
             title: "A model sent the graphics chip a bad command",
             what: "The graphics command stream (the display lists inside a model) contained something the console can't run. This points at a damaged or badly aligned model, texture or minimap, not at the course data.",
             fixes: ["Think about the last model or texture you changed (course_model, map_model, vrcorn_model, an object's BRRES) and restore it to confirm.",
                     "Minimap (map_model) bones and display lists must be aligned correctly. Rebuild the minimap with the minimap tool rather than editing it by hand.",
                     "Try a different video backend in Settings > Emulator. If the crash goes away it's a Dolphin graphics quirk, otherwise it's the file.",
                     "Run Verify Archive on the course."]),
        Rule(pattern: #"[Aa]lignment exception|DSI exception|ISI exception"#,
             title: "The game hit a hardware exception",
             what: "The game's code did something a real Wii's processor rejects, such as reading a value from an address that isn't aligned. Dolphin often ignores these, so it can pass in Dolphin and still crash on a console.",
             fixes: ["Check recently edited BRRES, minimap and display list data for misaligned sizes (data should be 0x20 aligned).",
                     "Turn on Dolphin's MMU option (Config > Advanced) so Dolphin crashes the way hardware does, then test again."]),
        Rule(pattern: #"Unknown instruction|Illegal instruction|Invalid instruction|Unimplemented instruction"#,
             title: "The game ran data as code",
             what: "The processor reached bytes that aren't a valid instruction. That happens when the game jumps to the wrong place, often after a corrupt file or a bad code patch.",
             fixes: ["Disable any Gecko or Riivolution codes and test again.",
                     "Rebuild the last file you changed and make sure Hot Swap copied the whole archive."]),
        Rule(pattern: #"[Oo]ut of memory|Failed to allocate|[Aa]llocation failed|OSAllocFromHeap"#,
             title: "The game ran out of memory",
             what: "The Wii has very little memory. The course, its textures, models and sounds together are too big for it.",
             fixes: ["Open Track Budget on the course and trim whatever it flags first (large textures and high polygon counts).",
                     "Use smaller textures or a cheaper texture format, and remove objects you don't need."]),
        Rule(pattern: #"Failed to (open|read) (the )?(disc|game|ISO|file)|[Cc]ould not (open|read) (the )?(disc|game|ISO)|DVD.*read error"#,
             title: "A file couldn't be read",
             what: "The game or Dolphin asked for a file that isn't there or couldn't be read, such as a track that wasn't built into the game image.",
             fixes: ["Check the file name and folder match what the game expects (case matters on the disc).",
                     "Rebuild the .wbz or Hot Swap target and make sure the build finished without warnings."]),
        Rule(pattern: #"[Ss]hader.*(fail|error)|Failed to compile|[Pp]ipeline.*(fail|error)"#,
             title: "Dolphin's graphics backend failed",
             what: "Dolphin couldn't compile a graphics shader, which is a problem with the video backend rather than with your mod.",
             fixes: ["Switch the video backend in Settings > Emulator (Metal or Vulkan), then test again.",
                     "Update Dolphin to the latest version."]),
        Rule(pattern: #"[Pp]anic|[Uu]nhandled exception|[Aa]ssertion|[Ff]atal"#,
             title: "Dolphin reported a serious error",
             what: "Dolphin stopped on an error it couldn't recover from. The raw log lines below say what it was.",
             fixes: ["Read the log excerpt for the exact message.",
                     "Update Dolphin, and test the same game unmodified to see whether your mod is the cause."]),
    ]

    /// Scans the end of the log (it can run to gigabytes) and, if present, the newest macOS crash report for Dolphin.
    static func scan() -> Report {
        var report = Report()
        report.systemReport = latestSystemReport()
        let url = logURL
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            report.problem = "No Dolphin log was found. In Dolphin, open View > Show Log Configuration and turn on Write to File, run the game again, then come back."
            return report
        }
        defer { try? handle.close() }
        report.logURL = url
        report.logDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 24 * 1024 * 1024
        try? handle.seek(toOffset: size > window ? size - window : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")

        // Each entry starts at a timestamped line; unstamped lines continue the one above (Dolphin's multi-line warnings).
        let stamp = try! NSRegularExpression(pattern: #"^\d+:\d\d:\d\d"#)
        func isStart(_ s: String) -> Bool { stamp.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
        var hits: [(line: Int, rule: Rule, text: String)] = []
        var i = 0
        while i < lines.count {
            guard isStart(lines[i]) else { i += 1; continue }
            var j = i + 1
            while j < lines.count, !isStart(lines[j]) { j += 1 }
            let entry = lines[i..<j].joined(separator: "\n")
            // Only warnings and errors count: the log is mostly information about normal start-up.
            if !entry.contains("DoFileSearch"), !entry.contains("Translation.cpp"), entry.contains(" W[") || entry.contains(" E[") || entry.contains(" C[") || entry.contains(" P["),
               let rule = rules.first(where: { entry.range(of: $0.pattern, options: .regularExpression) != nil }) {
                hits.append((i, rule, lines[i]))
            }
            i = j
        }
        guard let last = hits.last else {
            if report.systemReport == nil { report.problem = "No crash was found in the end of Dolphin's log. If Dolphin closed by itself, turn on Write to File in View > Show Log Configuration and try again." }
            return report
        }
        // The last crash is the cluster of hits that ends the log: anything within 600 lines of the one before.
        var cluster = [last]
        for h in hits.dropLast().reversed() { if cluster[0].line - h.line < 600 { cluster.insert(h, at: 0) } else { break } }
        var seen = Set<String>()
        report.findings = cluster.compactMap { h in
            guard seen.insert(h.rule.title).inserted else { return nil }
            return Finding(title: h.rule.title, what: h.rule.what, fixes: h.rule.fixes, evidence: String(h.text.prefix(220)))
        }
        let from = max(0, cluster[0].line - 30), to = min(lines.count, last.line + 20)
        report.excerpt = lines[from..<to].map { String($0.prefix(400)) }.joined(separator: "\n")
        report.lastFiles = lines[max(0, cluster[0].line - 600)..<cluster[0].line]
            .compactMap { l in l.range(of: "FileMon]:") .map { String(l[$0.upperBound...]).trimmingCharacters(in: .whitespaces) } }
            .suffix(3).map { $0 }
        return report
    }

    /// A one-line summary of the newest macOS crash report for Dolphin from the last day, if any.
    private static func latestSystemReport() -> String? {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let newest = files.filter { $0.lastPathComponent.lowercased().hasPrefix("dolphin") && ["ips", "crash"].contains($0.pathExtension) }
            .compactMap { u in (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate.map { (u, $0) } }
            .max { $0.1 < $1.1 }
        guard let (url, date) = newest, date.timeIntervalSinceNow > -86400,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        func field(_ key: String) -> String? {
            text.range(of: "\"\(key)\"\\s*:\\s*\"([^\"]+)\"", options: .regularExpression).flatMap { r in
                text[r].split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
            }
        }
        let kind = field("type") ?? "an unknown exception", signal = field("signal").map { " (\($0))" } ?? ""
        return "macOS recorded Dolphin itself crashing with \(kind)\(signal) at \(date.formatted(date: .abbreviated, time: .shortened)). That is Dolphin closing, not the game freezing, so try another video backend or update Dolphin first. Report: \(url.lastPathComponent)"
    }
}
