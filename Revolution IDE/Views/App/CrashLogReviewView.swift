import SwiftUI
import AppKit

/// Settings > Emulator > Review Crash Logs: what Dolphin's log says went wrong, in plain English,
/// or just the lines around the crash.
struct CrashLogReviewView: View {
    private enum Mode: String, CaseIterable { case explanation = "Simple", excerpt = "Advanced" }

    @State private var report: CrashLogReview.Report?
    @State private var mode = Mode.explanation
    @State private var scanning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Review Crash Logs").font(.title2.bold())
                Spacer()
                Button { scan() } label: { Label("Scan Again", systemImage: "arrow.clockwise") }.disabled(scanning)
            }
            Picker("", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            if scanning || report == nil {
                ProgressView("Reading Dolphin's log...").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let report {
                if let problem = report.problem, report.findings.isEmpty {
                    note(problem)
                } else {
                    switch mode {
                    case .explanation: explanation(report)
                    case .excerpt: excerpt(report)
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 460)
        .task { scan() }
    }

    private func note(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal").font(.largeTitle).foregroundStyle(.secondary)
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func explanation(_ report: CrashLogReview.Report) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let date = report.logDate {
                    Text("From Dolphin's log, last written \(date.formatted(date: .abbreviated, time: .shortened)).").font(.caption).foregroundStyle(.secondary)
                }
                if let system = report.systemReport { Label(system, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                if !report.lastFiles.isEmpty {
                    Text("Just before it stopped, the game was loading: \(report.lastFiles.joined(separator: ", ")).").fixedSize(horizontal: false, vertical: true)
                }
                ForEach(report.findings) { f in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(f.title).font(.headline)
                        Text(f.what).fixedSize(horizontal: false, vertical: true)
                        Text("What to try").font(.subheadline.bold()).padding(.top, 2)
                        ForEach(f.fixes, id: \.self) { fix in
                            Label { Text(fix).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "wrench.and.screwdriver").foregroundStyle(.tint) }
                        }
                        Text(f.evidence).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func excerpt(_ report: CrashLogReview.Report) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView([.vertical, .horizontal]) {
                Text(report.excerpt.isEmpty ? "No crash section was found." : report.excerpt)
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.primary).textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true).padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(report.excerpt, forType: .string) }.disabled(report.excerpt.isEmpty)
                if let url = report.logURL { Button("Show Full Log in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
            }
        }
    }

    private func scan() {
        scanning = true
        Task {
            let result = await Task.detached { CrashLogReview.scan() }.value
            report = result
            scanning = false
        }
    }
}
