import SwiftUI

/// The Git panel: branch, staged/unstaged file lists with a diff preview, commit, pull/push.
/// Shells out to the `git` CLI (see `GitClient`) rather than embedding a Git library.
struct SourceControlView: View {
    @ObservedObject var git: GitState
    let projectURL: URL?
    @Environment(\.dismiss) var dismiss
    @State private var commitMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if git.isRepo {
                HSplitView {
                    fileLists.frame(minWidth: 260, idealWidth: 300)
                    diffPane.frame(minWidth: 320)
                }
            } else {
                noRepoState
            }
        }
        .frame(width: 760, height: 520)
    }

    private var header: some View {
        HStack {
            Image(systemName: "arrow.triangle.branch")
            if let branch = git.branch { Text(branch).font(.headline) } else { Text("Source Control").font(.headline) }
            if git.isBusy { ProgressView().controlSize(.small).padding(.leading, 4) }
            Spacer()
            if git.isRepo {
                Button("Pull") { git.pull() }
                    .help("Download and merge in the latest changes from the remote repository (e.g. GitHub) before you keep working.")
                Button("Push") { git.push() }
                    .help("Upload your committed changes to the remote repository so others (or another machine) can get them.")
            }
            Button("Done") { dismiss() }
        }
        .padding(10)
    }

    private var noRepoState: some View {
        VStack(spacing: 12) {
            Text("This project isn't a Git repository yet.").foregroundStyle(.secondary)
            if let projectURL {
                Button("Initialise Git Repository Here") { git.initializeRepo(at: projectURL) }
                    .help("Starts tracking this project folder's history with Git, so you can save checkpoints (commits) and undo mistakes across sessions. Optional, purely for your own version history, not required to mod.")
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var fileLists: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                Section("Staged (\(git.stagedCount))") {
                    ForEach(git.entries.filter(\.isStaged)) { entry in
                        fileRow(entry, staged: true)
                    }
                }
                Section("Not Staged (\(git.unstagedCount))") {
                    ForEach(git.entries.filter { !$0.isStaged }) { entry in
                        fileRow(entry, staged: false)
                    }
                }
            }
            .listStyle(.inset)

            Divider()
            VStack(alignment: .leading, spacing: 6) {
                TextEditor(text: $commitMessage)
                    .frame(height: 60)
                    .font(.system(.body, design: .monospaced))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3)))
                    .help("A short note describing what changed in this checkpoint, e.g. \"Fixed floating item boxes on turn 3\".")
                HStack {
                    Button("Stage All") { git.stageAll() }
                        .help("Marks every changed file as ready to include in the next commit. Staging just selects what to save, it doesn't save anything by itself.")
                    Spacer()
                    Button("Commit") {
                        git.commit(message: commitMessage)
                        commitMessage = ""
                    }
                    .shortcut(.commit)
                    .disabled(git.stagedCount == 0 || commitMessage.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Saves a permanent checkpoint of every staged file with your message, you can always come back to this exact state later.")
                }
            }
            .padding(8)
        }
    }

    private func fileRow(_ entry: GitFileEntry, staged: Bool) -> some View {
        HStack {
            Button {
                staged ? git.unstage([entry.path]) : git.stage([entry.path])
            } label: {
                Image(systemName: staged ? "minus.circle" : "plus.circle")
            }
            .buttonStyle(.plain)
            Text((entry.path as NSString).lastPathComponent)
            Spacer()
            Text(entry.summary).font(.caption2).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { git.selectDiff(entry.path) }
        .background(git.selectedPath == entry.path ? Color.accentColor.opacity(0.15) : .clear)
    }

    private var diffPane: some View {
        ScrollView {
            Text(git.diffText.isEmpty ? "Select a file to view its diff." : git.diffText)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
    }
}
