import Foundation

/// Before a homebrew build: if the project holds a `.wiiui` design and/or a `.wiinodes` graph,
/// writes the runtime and generated C into `source/generated/`. Plain projects are left alone.
nonisolated enum HomebrewGenerator {
    struct Failure: LocalizedError { var errorDescription: String? }

    /// The first file with `ext` under `root` (skipping build output and generated code).
    static func findFile(ext: String, in root: URL) -> URL? {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        var found: [URL] = []
        for case let url as URL in walker {
            if url.lastPathComponent == "build" || url.lastPathComponent == "generated" { walker.skipDescendants(); continue }
            if url.pathExtension.lowercased() == ext { found.append(url) }
        }
        return found.sorted { $0.path < $1.path }.first
    }

    /// Every `.wiiui` in the project as a named screen: "main" first, then by path. A screen is named after its file.
    static func uiScreens(in project: URL) throws -> [(name: String, doc: UIDocument)] {
        guard let walker = FileManager.default.enumerator(at: project, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var files: [URL] = []
        for case let url as URL in walker {
            if ["build", "generated", "out"].contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            if url.pathExtension.lowercased() == "wiiui" { files.append(url) }
        }
        func rank(_ u: URL) -> Int { u.deletingPathExtension().lastPathComponent == "main" ? 0 : 1 }
        files.sort { (rank($0), $0.path) < (rank($1), $1.path) }
        var used = Set<String>(), out: [(name: String, doc: UIDocument)] = []
        for f in files {
            let doc: UIDocument
            do { doc = try UIDocument.parse(Data(contentsOf: f)) }
            catch { throw Failure(errorDescription: "\(f.lastPathComponent) couldn't be read: \(error.localizedDescription)") }
            let base = UIDocument.identifier(f.deletingPathExtension().lastPathComponent)
            var name = base, n = 2
            while !used.insert(name).inserted { name = "\(base)\(n)"; n += 1 }
            out.append((name, doc))
        }
        return out
    }

    /// Every `.wiinodes` in the project, "main" first. A graph with `actorSprite` set is a sprite actor named after its file;
    /// the rest are the program's own logic (the first one is used).
    static func nodeGraphs(in project: URL) throws -> [(name: String, url: URL, graph: NodeGraph)] {
        guard let walker = FileManager.default.enumerator(at: project, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var files: [URL] = []
        for case let url as URL in walker {
            if ["build", "generated", "out"].contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            if url.pathExtension.lowercased() == "wiinodes" { files.append(url) }
        }
        func rank(_ u: URL) -> Int { u.deletingPathExtension().lastPathComponent == "main" ? 0 : 1 }
        files.sort { (rank($0), $0.path) < (rank($1), $1.path) }
        var used = Set<String>(), out: [(name: String, url: URL, graph: NodeGraph)] = []
        for f in files {
            let graph: NodeGraph
            do { graph = try NodeGraph.parse(Data(contentsOf: f)) }
            catch { throw Failure(errorDescription: "\(f.lastPathComponent) couldn't be read: \(error.localizedDescription)") }
            let base = UIDocument.identifier(f.deletingPathExtension().lastPathComponent)
            var name = base, n = 2
            while !used.insert(name).inserted { name = "\(base)\(n)"; n += 1 }
            out.append((name, f, graph))
        }
        return out
    }

    private static let graphHooks: [NodeKind: String] = [.onStart: "app_on_start", .onFrame: "app_on_frame", .onDraw: "app_on_draw", .onButton: "app_on_button", .onWiimote: "app_on_wpad"]

    /// The project's Swift sources: every `.swift` under its `swift/` folder.
    static func swiftSources(in project: URL) -> [URL] {
        let dir = project.appendingPathComponent("swift", isDirectory: true)
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    }

    /// Returns log lines. Throws with the reason when the design or graph can't be turned into C.
    static func generate(project: URL) throws -> [String] {
        var screens = try uiScreens(in: project)
        let hasUI = !screens.isEmpty
        let allGraphs = try nodeGraphs(in: project)
        let graphFile = allGraphs.first { $0.graph.actorSprite == nil }?.url
        // Variables marked Global, from every node file (program and sprite actors), one shared copy each.
        var globalVars: [GraphVariable] = [], globalOwner: [String: String] = [:]
        for entry in allGraphs {
            for v in entry.graph.variables where v.global {
                if let other = globalOwner[v.name] {
                    throw Failure(errorDescription: "The global variable \"\(v.name)\" is defined in both \"\(other)\" and \"\(entry.name)\". A global needs one home; remove one.")
                }
                globalOwner[v.name] = entry.name
                globalVars.append(v)
            }
        }
        let actorGraphs = allGraphs.filter { $0.graph.actorSprite != nil }.map { (name: $0.name, graph: $0.graph) }
        let swiftFiles = swiftSources(in: project)
        guard hasUI || graphFile != nil || !actorGraphs.isEmpty || !swiftFiles.isEmpty else { return [] }
        var log: [String] = []

        if screens.isEmpty { screens = [("main", UIDocument(background: .black, widgets: []))] }
        var problems: [String] = []
        var owner: [String: String] = [:]
        for sc in screens {
            let prefix = screens.count > 1 ? "\(sc.name): " : ""
            problems += sc.doc.problems().map { prefix + $0 }
            for w in sc.doc.widgets {
                if let other = owner[w.name], other != sc.name { problems.append("The widget \"\(w.name)\" is on both the \"\(other)\" and \"\(sc.name)\" screens; widget names must be unique across screens.") }
                owner[w.name] = sc.name
            }
        }
        if !problems.isEmpty { throw Failure(errorDescription: problems.joined(separator: "\n")) }
        let widgetNames = screens.flatMap { $0.doc.widgets.map(\.name) }

        let dir = project.appendingPathComponent("source/generated", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let uiOut = UICodegen.generate(screens: screens, projectRoot: project)
        log += uiOut.warnings.map { "Warning: \($0)" }
        try write(WiiUIRuntime.header, "wiiui.h", in: dir)
        try write(WiiUIRuntime.source, "wiiui.c", in: dir)
        try write(WiiUIRuntime.gfxHeader, "wgfx.h", in: dir)
        try write(WiiUIRuntime.gfxSourceGX, "wgfx_gx.c", in: dir)
        try write(uiOut.header, "ui_generated.h", in: dir)
        try write(uiOut.source, "ui_generated.c", in: dir)
        try write(WiiUIRuntime.nodeHeader, "wn.h", in: dir)

        try syncMusic(uiOut.musicFiles, project: project)
        let logicURL = dir.appendingPathComponent("logic_generated.c")
        if let graphFile {
            let graph: NodeGraph
            do { graph = try NodeGraph.parse(Data(contentsOf: graphFile)) }
            catch { throw Failure(errorDescription: "\(graphFile.lastPathComponent) couldn't be read: \(error.localizedDescription)") }
            do { try write(NodeCodegen.generate(graph, widgetNames: widgetNames, spriteNames: uiOut.spriteNames, soundNames: uiOut.soundNames, musicNames: uiOut.musicNames, screenNames: uiOut.screenNames, actorNames: actorGraphs.map(\.name), globals: globalVars), "logic_generated.c", in: dir) }
            catch let f as NodeCodegen.Failure { throw Failure(errorDescription: "\(graphFile.lastPathComponent):\n" + f.messages.joined(separator: "\n")) }
        } else {
            try? FileManager.default.removeItem(at: logicURL)
        }

        if globalVars.isEmpty {
            for f in ["globals_generated.h", "globals_generated.c"] { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
        } else {
            let files = NodeCodegen.globalsFiles(globalVars)
            try write(files.header, "globals_generated.h", in: dir)
            try write(files.source, "globals_generated.c", in: dir)
            log.append("\(globalVars.count) global variable\(globalVars.count == 1 ? "" : "s") shared between node files.")
        }
        let actorsURL = dir.appendingPathComponent("actors_generated.c")
        if actorGraphs.isEmpty {
            try? FileManager.default.removeItem(at: actorsURL)
        } else {
            do { try write(NodeCodegen.generateActors(actorGraphs, widgetNames: widgetNames, spriteNames: uiOut.spriteNames, soundNames: uiOut.soundNames, musicNames: uiOut.musicNames, screenNames: uiOut.screenNames, globals: globalVars), "actors_generated.c", in: dir) }
            catch let f as NodeCodegen.Failure { throw Failure(errorDescription: "Sprite actors:\n" + f.messages.joined(separator: "\n")) }
            log.append("Generated \(actorGraphs.count) sprite actor\(actorGraphs.count == 1 ? "" : "s").")
        }

        let swiftOut = dir.appendingPathComponent("swift_generated.c")
        if swiftFiles.isEmpty {
            try? FileManager.default.removeItem(at: swiftOut)
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("ws.h"))
        } else {
            var prog = SwiftProgram()
            var errors: [String] = []
            for f in swiftFiles {
                let rel = f.resolvingSymlinksInPath().path.replacingOccurrences(of: project.resolvingSymlinksInPath().path + "/", with: "")
                do { try SwiftParser.parse(source: String(contentsOf: f, encoding: .utf8), file: rel, into: &prog) }
                catch { errors.append(error.localizedDescription) }
            }
            if errors.isEmpty {
                do {
                    let result = try SwiftEmitter.emit(prog, widgets: widgetNames, sprites: uiOut.spriteNames, sounds: uiOut.soundNames, musics: uiOut.musicNames)
                    if let graphFile, let graph = try? NodeGraph.parse(Data(contentsOf: graphFile)) {
                        let used = Set(graph.nodes.compactMap { graphHooks[$0.kind] })
                        let clash = used.intersection(result.hooks).sorted()
                        if !clash.isEmpty { throw Failure(errorDescription: "Both the node graph and the Swift code handle \(clash.joined(separator: ", ")). Use one or the other for each.") }
                    }
                    try write(WiiUIRuntime.swiftSupport, "ws.h", in: dir)
                    try write(result.source, "swift_generated.c", in: dir)
                    if result.usesWui {
                        try write(WuiRuntime.header, "wui.h", in: dir)
                        try write(WuiRuntime.source, "wui.c", in: dir)
                    } else {
                        for f in ["wui.h", "wui.c"] { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
                    }
                } catch let e as SwiftError { errors.append(e.localizedDescription) }
            }
            if !errors.isEmpty { throw Failure(errorDescription: errors.joined(separator: "\n")) }
            log.append("Translated \(swiftFiles.count) Swift file\(swiftFiles.count == 1 ? "" : "s") to C.")
        }

        let makefile = (try? String(contentsOf: project.appendingPathComponent("Makefile"), encoding: .utf8)) ?? ""
        if !makefile.contains("source/generated") {
            log.append("Warning: add source/generated to SOURCES in the Makefile, or the generated UI code won't be built.")
        }
        log.append("Generated UI code" + (graphFile != nil ? " and node logic" : "") + ".")
        if !uiOut.spriteNames.isEmpty || !uiOut.soundNames.isEmpty {
            log.append("Assets: \(uiOut.spriteNames.count) sprite\(uiOut.spriteNames.count == 1 ? "" : "s"), \(uiOut.soundNames.count) sound\(uiOut.soundNames.count == 1 ? "" : "s").")
        }
        return log
    }

    /// Copies each .brstm to data/wiiui_music_<n>.bin (the Makefile's bin2o rule turns that into linkable data)
    /// and removes copies of music that's gone.
    private static func syncMusic(_ files: [URL], project: URL) throws {
        let fm = FileManager.default
        let dir = project.appendingPathComponent("data", isDirectory: true)
        let wanted = Set(files.indices.map { "wiiui_music_\($0).bin" })
        for old in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where old.hasPrefix("wiiui_music_") && !wanted.contains(old) {
            try? fm.removeItem(at: dir.appendingPathComponent(old))
        }
        guard !files.isEmpty else { return }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, src) in files.enumerated() {
            let dest = dir.appendingPathComponent("wiiui_music_\(i).bin")
            if fm.contentsEqual(atPath: src.path, andPath: dest.path) { continue }
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: src, to: dest)
        }
    }

    /// Only touches the file when its content changed, so unchanged builds stay incremental.
    private static func write(_ text: String, _ name: String, in dir: URL) throws {
        let url = dir.appendingPathComponent(name)
        if (try? String(contentsOf: url, encoding: .utf8)) == text { return }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
