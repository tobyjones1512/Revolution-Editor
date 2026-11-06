import Foundation
import Combine

/// Drives the Source Control panel: repo detection, status, staging, commit, pull/push. All git
/// invocations run off the main thread since `git status`/`pull`/`push` can take real time.
@MainActor final class GitState: ObservableObject {
    @Published var repoRoot: URL?
    @Published var branch: String?
    @Published var entries: [GitFileEntry] = []
    @Published var isBusy = false
    @Published var lastMessage: String?
    @Published var selectedPath: String?
    @Published var diffText: String = ""

    var isRepo: Bool { repoRoot != nil }
    var stagedCount: Int { entries.filter(\.isStaged).count }
    var unstagedCount: Int { entries.count - stagedCount }

    /// Looks for a repo starting at (or above) `repoURL` and refreshes status if found. Safe to
    /// call whenever the Workbench opens a folder or disc image, it's a no-op if there's no
    /// repo, so it never forces Git on anyone.
    func refresh(repoURL: URL) {
        guard let root = GitClient.findRepoRoot(from: repoURL) else {
            repoRoot = nil; branch = nil; entries = []
            return
        }
        repoRoot = root
        reload()
    }

    func reload() {
        guard let root = repoRoot else { return }
        isBusy = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let branch = GitClient.currentBranch(repoRoot: root)
            let status = GitClient.status(repoRoot: root)
            await MainActor.run {
                self?.branch = branch
                self?.entries = status
                self?.isBusy = false
            }
        }
    }

    func initializeRepo(at url: URL) {
        let result = GitClient.initRepo(at: url)
        lastMessage = result.output
        refresh(repoURL: url)
    }

    func stage(_ paths: [String]) {
        guard let root = repoRoot else { return }
        GitClient.stage(paths: paths, repoRoot: root)
        reload()
    }

    func unstage(_ paths: [String]) {
        guard let root = repoRoot else { return }
        GitClient.unstage(paths: paths, repoRoot: root)
        reload()
    }

    func stageAll() {
        guard let root = repoRoot else { return }
        GitClient.stageAll(repoRoot: root)
        reload()
    }

    func commit(message: String) {
        guard let root = repoRoot, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isBusy = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = GitClient.commit(message: message, repoRoot: root)
            await MainActor.run {
                self?.lastMessage = result.output
                self?.isBusy = false
                self?.reload()
            }
        }
    }

    func pull() {
        guard let root = repoRoot else { return }
        isBusy = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = GitClient.pull(repoRoot: root)
            await MainActor.run {
                self?.lastMessage = result.output
                self?.isBusy = false
                self?.reload()
            }
        }
    }

    func push() {
        guard let root = repoRoot else { return }
        isBusy = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = GitClient.push(repoRoot: root)
            await MainActor.run {
                self?.lastMessage = result.output
                self?.isBusy = false
            }
        }
    }

    func selectDiff(_ path: String) {
        guard let root = repoRoot else { return }
        selectedPath = path
        let entry = entries.first { $0.path == path }
        let staged = entry?.isStaged ?? false
        diffText = GitClient.diff(path: path, staged: staged, repoRoot: root)
    }
}
