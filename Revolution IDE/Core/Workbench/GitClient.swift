import Foundation

/// Thin wrapper over the `git` CLI (shelled out via `Process`), simplest, most reliable way to
/// get real Git support without embedding a Git library, and it transparently uses whatever
/// credential helper/SSH agent/config the user already has set up.
nonisolated struct GitFileEntry: Identifiable {
    var id: String { path }
    var path: String
    var indexStatus: Character // status in the index (staged), ' ' if none
    var workTreeStatus: Character // status in the working tree (unstaged), ' ' if none

    var isStaged: Bool { indexStatus != " " && indexStatus != "?" }
    var isUntracked: Bool { indexStatus == "?" && workTreeStatus == "?" }
    var summary: String {
        if isUntracked { return "Untracked" }
        var parts: [String] = []
        if indexStatus != " " { parts.append("staged: \(describe(indexStatus))") }
        if workTreeStatus != " " { parts.append("unstaged: \(describe(workTreeStatus))") }
        return parts.joined(separator: ", ")
    }
    private func describe(_ c: Character) -> String {
        switch c {
        case "M": return "modified"
        case "A": return "added"
        case "D": return "deleted"
        case "R": return "renamed"
        case "C": return "copied"
        case "U": return "conflicted"
        default: return String(c)
        }
    }
}

nonisolated enum GitClient {
    private static func gitBinary() -> String {
        for candidate in ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return "/usr/bin/git"
    }

    @discardableResult
    static func run(_ args: [String], in directory: URL, timeout: TimeInterval = 15) -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitBinary())
        process.arguments = args
        process.currentDirectoryURL = directory
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        // Avoid ever hanging on an interactive credential/editor prompt.
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_EDITOR"] = "true"
        let basePaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let currentPath = env["PATH"] ?? ""
        env["PATH"] = basePaths.joined(separator: ":") + (currentPath.isEmpty ? "" : ":" + currentPath)
        process.environment = env

        do {
            try process.run()
        } catch {
            return (-1, "", "Couldn't launch git: \(error.localizedDescription)")
        }
        // `timeout` used to be accepted but never enforced, a hung git process (unreachable
        // remote stalling DNS/network, a lock-file wait, ...) blocked `waitUntilExit()` forever,
        // with no way to cancel. This bounds the wait for real: terminate the process if it's
        // still running once `timeout` elapses, which unblocks `waitUntilExit()` below.
        let timeoutWorkItem = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)
        process.waitUntilExit()
        timeoutWorkItem.cancel()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, out, err)
    }

    static func findRepoRoot(from url: URL) -> URL? {
        let dir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true ? url : url.deletingLastPathComponent()
        let result = run(["rev-parse", "--show-toplevel"], in: dir)
        guard result.exitCode == 0 else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func currentBranch(repoRoot: URL) -> String? {
        let result = run(["rev-parse", "--abbrev-ref", "HEAD"], in: repoRoot)
        guard result.exitCode == 0 else { return nil }
        let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    static func status(repoRoot: URL) -> [GitFileEntry] {
        let result = run(["status", "--porcelain=v1"], in: repoRoot)
        guard result.exitCode == 0 else { return [] }
        var out: [GitFileEntry] = []
        for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.count > 3 else { continue }
            let chars = Array(line)
            let indexStatus = chars[0], workTreeStatus = chars[1]
            let path = String(line.dropFirst(3))
            out.append(GitFileEntry(path: path, indexStatus: indexStatus, workTreeStatus: workTreeStatus))
        }
        return out
    }

    static func stage(paths: [String], repoRoot: URL) {
        guard !paths.isEmpty else { return }
        run(["add", "--"] + paths, in: repoRoot)
    }

    static func unstage(paths: [String], repoRoot: URL) {
        guard !paths.isEmpty else { return }
        run(["reset", "--"] + paths, in: repoRoot)
    }

    static func stageAll(repoRoot: URL) {
        run(["add", "-A"], in: repoRoot)
    }

    @discardableResult
    static func commit(message: String, repoRoot: URL) -> (success: Bool, output: String) {
        let result = run(["commit", "-m", message], in: repoRoot)
        return (result.exitCode == 0, result.exitCode == 0 ? result.stdout : result.stderr)
    }

    static func diff(path: String, staged: Bool, repoRoot: URL) -> String {
        var args = ["diff", "--no-color"]
        if staged { args.append("--staged") }
        args.append(contentsOf: ["--", path])
        let result = run(args, in: repoRoot)
        return result.stdout.isEmpty ? result.stderr : result.stdout
    }

    static func recentCommits(repoRoot: URL, limit: Int = 30) -> [String] {
        let result = run(["log", "-\(limit)", "--pretty=format:%h  %ad  %s", "--date=short"], in: repoRoot)
        guard result.exitCode == 0 else { return [] }
        return result.stdout.split(separator: "\n").map(String.init)
    }

    @discardableResult
    static func pull(repoRoot: URL) -> (success: Bool, output: String) {
        let result = run(["pull"], in: repoRoot, timeout: 60)
        return (result.exitCode == 0, result.exitCode == 0 ? result.stdout : result.stderr)
    }

    @discardableResult
    static func push(repoRoot: URL) -> (success: Bool, output: String) {
        let result = run(["push"], in: repoRoot, timeout: 60)
        return (result.exitCode == 0, result.exitCode == 0 ? result.stdout : result.stderr)
    }

    @discardableResult
    static func initRepo(at url: URL) -> (success: Bool, output: String) {
        let result = run(["init"], in: url)
        return (result.exitCode == 0, result.exitCode == 0 ? result.stdout : result.stderr)
    }
}
