import Foundation
import Combine

/// Wii homebrew development on top of the user's own devkitPro install (devkitpro.org): nothing
/// from devkitPro is bundled or downloaded. The toolchain is found, a standard devkitPPC/libogc
/// project is generated, and `make` is run on it with devkitPro's environment set.
nonisolated enum DevkitPro {
    static let pathKey = "DevkitPro.path"
    static let installURL = URL(string: "https://devkitpro.org/wiki/Getting_Started")!

    /// The devkitPro root: the folder chosen in Settings, then `$DEVKITPRO`, then the installer's
    /// default `/opt/devkitpro`. Only a folder that really holds devkitPPC's compiler counts.
    static var root: URL? {
        var candidates: [String] = []
        if let chosen = UserDefaults.standard.string(forKey: pathKey), !chosen.isEmpty { candidates.append(chosen) }
        if let env = ProcessInfo.processInfo.environment["DEVKITPRO"], !env.isEmpty { candidates.append(env) }
        candidates.append("/opt/devkitpro")
        return candidates.map { URL(fileURLWithPath: $0) }.first(where: isValid)
    }

    static func isValid(_ root: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("devkitPPC/bin/powerpc-eabi-gcc").path)
    }

    /// The environment devkitPro's makefiles expect (a GUI app doesn't inherit a shell's).
    static func environment(root: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["DEVKITPRO"] = root.path
        env["DEVKITPPC"] = root.appendingPathComponent("devkitPPC").path
        let extra = [root.appendingPathComponent("devkitPPC/bin").path, root.appendingPathComponent("tools/bin").path]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        return env
    }
}

nonisolated enum HomebrewTemplate {
    enum Language: String, CaseIterable, Identifiable {
        case c, cpp
        /// C app with a visual UI (`ui/main.wiiui`) and node logic (`logic/main.wiinodes`).
        case uiApp
        /// C app with a visual UI and its logic written in Swift (`swift/main.swift`).
        case swiftApp
        /// A SwiftUI app: views, @State, buttons, toggles, sliders.
        case swiftUIApp
        /// Games: draw sprites and text every frame, read the controllers, play sounds.
        case gameC, gameSwift, gameNodes
        var id: String { rawValue }
        var title: String {
            switch self {
            case .c: return "C"
            case .cpp: return "C++"
            case .uiApp: return "C: UI app (designer + nodes)"
            case .swiftApp: return "Swift: UI app (designer + Swift)"
            case .swiftUIApp: return "Swift: SwiftUI app"
            case .gameC: return "Game: C"
            case .gameSwift: return "Game: Swift"
            case .gameNodes: return "Game: nodes (no code)"
            }
        }
        /// Everything except the plain console templates uses the generated runtime.
        var isApp: Bool { self != .c && self != .cpp }
        var sourceName: String { self == .cpp ? "main.cpp" : "main.c" }
    }

    /// A project name made safe for `make`: devkitPro's makefiles can't cope with spaces or
    /// punctuation in paths, so builds happen in a staging folder named with this.
    static func safeName(_ name: String) -> String {
        let s = String(name.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" })
        return s.isEmpty ? "homebrew" : s
    }

    /// Whether `folder` is a homebrew project made from this template (or any devkitPPC Wii
    /// project using `wii_rules`).
    static func isProject(_ folder: URL) -> Bool {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("Makefile"), encoding: .utf8) else { return false }
        return text.contains("wii_rules")
    }

    /// Writes `<parent>/<name>/` with a Makefile, `source/main.c|cpp` and a `.gitignore`.
    static func create(name: String, language: Language, in parent: URL) throws -> URL {
        let dir = parent.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: dir.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey: "A folder named \"\(name)\" already exists there."])
        }
        let source = dir.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        var mk = makefile
        if language.isApp {
            mk = mk.replacingOccurrences(of: "SOURCES  := source\n", with: "SOURCES  := source source/generated\n")
                   .replacingOccurrences(of: "LIBS     := -lwiiuse", with: "LIBS     := -lasnd -lwiiuse")
        }
        try mk.write(to: dir.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        let main = language == .gameC ? HomebrewSamples.gameC : (language.isApp ? uiMainSource : mainSource)
        try main.write(to: source.appendingPathComponent(language.sourceName), atomically: true, encoding: .utf8)
        if language.isApp {
            var files: [(String, String, Data)] = []
            switch language {
            case .uiApp:
                files = [("ui", "main.wiiui", UIDocument.sample().serialize()), ("logic", "main.wiinodes", NodeGraph.sample().serialize())]
            case .swiftApp:
                files = [("ui", "main.wiiui", UIDocument.sample().serialize()), ("swift", "main.swift", Data(swiftSample.utf8))]
            case .swiftUIApp:
                let screen = UIDocument(background: RGB(r: 0.05, g: 0.07, b: 0.12), widgets: [])
                files = [("ui", "main.wiiui", screen.serialize()), ("swift", "App.swift", Data(HomebrewSamples.swiftUI.utf8))]
            default:
                let screen = UIDocument(background: RGB(r: 0.05, g: 0.07, b: 0.12), widgets: [])
                files = [("ui", "main.wiiui", screen.serialize())]
                if language == .gameSwift { files.append(("swift", "main.swift", Data(HomebrewSamples.gameSwift.utf8))) }
                if language == .gameNodes { files.append(("logic", "main.wiinodes", HomebrewSamples.gameGraph().serialize())) }
                try HomebrewSamples.writeAssets(into: dir)
            }
            for (folder, file, data) in files {
                let d = dir.appendingPathComponent(folder, isDirectory: true)
                try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
                try data.write(to: d.appendingPathComponent(file))
            }
        }
        try "build/\nout/\ndata/wiiui_music_*.bin\n*.elf\n*.dol\n".write(to: dir.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        return dir
    }

    // devkitPro's own Wii template makefile (wii-examples/template), unchanged apart from being trimmed.
    static let makefile = """
    .SUFFIXES:
    ifeq ($(strip $(DEVKITPPC)),)
    $(error "Please set DEVKITPPC in your environment. export DEVKITPPC=<path to>devkitPPC")
    endif

    include $(DEVKITPPC)/wii_rules

    TARGET   := $(notdir $(CURDIR))
    BUILD    := build
    SOURCES  := source
    DATA     := data
    INCLUDES := include

    CFLAGS   = -g -O2 -Wall $(MACHDEP) $(INCLUDE)
    CXXFLAGS = $(CFLAGS)
    LDFLAGS  = -g $(MACHDEP) -Wl,-Map,$(notdir $@).map

    LIBS     := -lwiiuse -lbte -lfat -logc -lm
    LIBDIRS  :=

    ifneq ($(BUILD),$(notdir $(CURDIR)))

    export OUTPUT  := $(CURDIR)/$(TARGET)
    export VPATH   := $(foreach dir,$(SOURCES),$(CURDIR)/$(dir)) $(foreach dir,$(DATA),$(CURDIR)/$(dir))
    export DEPSDIR := $(CURDIR)/$(BUILD)

    CFILES   := $(foreach dir,$(SOURCES),$(notdir $(wildcard $(dir)/*.c)))
    CPPFILES := $(foreach dir,$(SOURCES),$(notdir $(wildcard $(dir)/*.cpp)))
    sFILES   := $(foreach dir,$(SOURCES),$(notdir $(wildcard $(dir)/*.s)))
    SFILES   := $(foreach dir,$(SOURCES),$(notdir $(wildcard $(dir)/*.S)))
    BINFILES := $(foreach dir,$(DATA),$(notdir $(wildcard $(dir)/*.*)))

    ifeq ($(strip $(CPPFILES)),)
    export LD := $(CC)
    else
    export LD := $(CXX)
    endif

    export OFILES    := $(addsuffix .o,$(BINFILES)) $(CPPFILES:.cpp=.o) $(CFILES:.c=.o) $(sFILES:.s=.o) $(SFILES:.S=.o)
    export INCLUDE   := $(foreach dir,$(INCLUDES), -iquote $(CURDIR)/$(dir)) $(foreach dir,$(LIBDIRS),-I$(dir)/include) -I$(CURDIR)/$(BUILD) -I$(LIBOGC_INC)
    export LIBPATHS  := -L$(LIBOGC_LIB) $(foreach dir,$(LIBDIRS),-L$(dir)/lib)

    .PHONY: $(BUILD) clean

    $(BUILD):
    \t@[ -d $@ ] || mkdir -p $@
    \t@$(MAKE) --no-print-directory -C $(BUILD) -f $(CURDIR)/Makefile

    clean:
    \t@echo clean ...
    \t@rm -fr $(BUILD) $(OUTPUT).elf $(OUTPUT).dol

    else

    DEPENDS := $(OFILES:.o=.d)

    $(OUTPUT).dol: $(OUTPUT).elf
    $(OUTPUT).elf: $(OFILES)

    %.bin.o %_bin.h: %.bin
    \t@echo $(notdir $<)
    \t@$(bin2o)

    -include $(DEPENDS)

    endif

    """.replacingOccurrences(of: "\\t", with: "\t")

    static let swiftSample = """
    // Your app's logic, in Swift. It is translated to C and built with devkitPro.
    // UI.<name> is a widget from ui/main.wiiui. Functions named appOnStart, appOnFrame,
    // appOnButton and appOnWpad are called by the app.

    var count = 0

    func appOnButton(_ id: Int) {
        if id == UI.go {
            count += 1
            setText(UI.status, "Pressed \\(count)")
        }
    }

    """

    /// The UI app's entry point: everything else is the designer's and node editor's generated code.
    static let uiMainSource = """
    #include "generated/ui_generated.h"

    /* Layout: ui/main.wiiui (designer). Logic: logic/main.wiinodes (node editor).
       Both are turned into C in source/generated/ each time you build. You can also define
       app_on_start / app_on_frame / app_on_button / app_on_wpad here yourself. */
    int main(void) {
        wiiui_init();
        while (wiiui_frame()) {}
        return 0;
    }

    """

    static let mainSource = """
    #include <stdio.h>
    #include <stdlib.h>
    #include <gccore.h>
    #include <wiiuse/wpad.h>

    static void *xfb = NULL;
    static GXRModeObj *rmode = NULL;

    int main(int argc, char **argv) {
        VIDEO_Init();
        WPAD_Init();

        rmode = VIDEO_GetPreferredMode(NULL);
        xfb = MEM_K0_TO_K1(SYS_AllocateFramebuffer(rmode));
        console_init(xfb, 20, 20, rmode->fbWidth, rmode->xfbHeight, rmode->fbWidth * VI_DISPLAY_PIX_SZ);
        VIDEO_Configure(rmode);
        VIDEO_SetNextFramebuffer(xfb);
        VIDEO_SetBlack(FALSE);
        VIDEO_Flush();
        VIDEO_WaitVSync();
        if (rmode->viTVMode & VI_NON_INTERLACE) VIDEO_WaitVSync();

        printf("\\x1b[2;0H");
        printf("Hello, Wii!\\n");
        printf("Press HOME to exit.\\n");

        while (1) {
            WPAD_ScanPads();
            if (WPAD_ButtonsDown(0) & WPAD_BUTTON_HOME) exit(0);
            VIDEO_WaitVSync();
        }
        return 0;
    }

    """
}

/// Builds a homebrew project with `make`. The project is copied to a staging folder first
/// (`/tmp/RevolutionEditorBuild/<safe name>`) because devkitPro's makefiles break on the spaces
/// in paths like "On-Device Documents"; the finished `.dol`/`.elf` are copied back into the project's `out/` folder.
nonisolated enum HomebrewBuild {
    /// Blocking; `log` may be called from any thread. Returns the built `.dol` (nil on failure,
    /// and after a clean).
    static func buildSync(project: URL, clean: Bool = false, log: @escaping @Sendable (String) -> Void) -> URL? {
        guard let devkitPro = DevkitPro.root else {
            log("devkitPro wasn't found. Install it (\(DevkitPro.installURL.absoluteString)) or locate it in Settings > Homebrew.")
            return nil
        }
        let name = HomebrewTemplate.safeName(project.lastPathComponent)
        let staging = URL(fileURLWithPath: "/tmp/RevolutionEditorBuild/\(name)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            log("ERROR: couldn't create the build folder: \(error.localizedDescription)")
            return nil
        }
        // Keeps staging's own build/ (incremental builds); the trailing slashes matter to rsync.
        let sync = run("/usr/bin/rsync", ["-a", "--delete", "--exclude", "build", "--exclude", "*.dol", "--exclude", "*.elf",
                                          "--exclude", "/out", "--exclude", ".git", project.path + "/", staging.path + "/"],
                       in: project, env: ProcessInfo.processInfo.environment, log: log)
        guard sync == 0 else { log("ERROR: couldn't copy the project to the build folder (rsync \(sync))."); return nil }

        log(clean ? "Cleaning \(name)..." : "Building \(name)...")
        let status = run("/usr/bin/make", clean ? ["clean"] : [], in: staging, env: DevkitPro.environment(root: devkitPro), log: log)
        guard status == 0 else { log("Build failed (make exited \(status))."); return nil }
        if clean { log("Clean."); return nil }

        let outDir = project.appendingPathComponent("out", isDirectory: true)
        let out = outDir.appendingPathComponent("\(name).dol")
        do {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            for ext in ["dol", "elf"] {
                let from = staging.appendingPathComponent("\(name).\(ext)"), to = outDir.appendingPathComponent("\(name).\(ext)")
                guard FileManager.default.fileExists(atPath: from.path) else { continue }
                try? FileManager.default.removeItem(at: to)
                try FileManager.default.copyItem(at: from, to: to)
            }
        } catch {
            log("ERROR: couldn't copy the build back: \(error.localizedDescription)")
            return nil
        }
        guard FileManager.default.fileExists(atPath: out.path) else {
            log("Build finished but \(out.lastPathComponent) wasn't produced.")
            return nil
        }
        do { try HomebrewPackage.write(project: project, dol: out) }
        catch { log("Built \(out.lastPathComponent), but the Homebrew Channel package failed: \(error.localizedDescription)") }
        log("Built out/\(out.lastPathComponent) (Homebrew Channel package in out/apps/\(name)/).")
        return out
    }

    private static func run(_ exe: String, _ args: [String], in dir: URL, env: [String: String], log: @escaping @Sendable (String) -> Void) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: exe)
        task.arguments = args
        task.currentDirectoryURL = dir
        task.environment = env
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        let emit: @Sendable (Data) -> Void = { data in
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") { log(String(line)) }
        }
        pipe.fileHandleForReading.readabilityHandler = { emit($0.availableData) }
        do { try task.run() } catch {
            log("ERROR: couldn't run \(exe): \(error.localizedDescription)")
            return -1
        }
        task.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        emit(pipe.fileHandleForReading.readDataToEndOfFile())
        return task.terminationStatus
    }
}

@MainActor final class HomebrewBuilder: ObservableObject {
    @Published var isBuilding = false

    /// Returns the built `.dol`, or nil if it failed (the reason is in the log).
    func build(project: URL, clean: Bool = false, log: @escaping @MainActor (String) -> Void) async -> URL? {
        guard !isBuilding else { return nil }
        isBuilding = true
        defer { isBuilding = false }
        return await Task.detached {
            HomebrewBuild.buildSync(project: project, clean: clean) { line in Task { @MainActor in log(line) } }
        }.value
    }
}
