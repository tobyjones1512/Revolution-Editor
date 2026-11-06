import SwiftUI

/// The bottom panel that shows what the program is doing.
struct LogPanelView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            if app.isBusy {
                VStack(alignment: .leading, spacing: 2) {
                    ProgressView(value: app.progress)
                    Text(app.progressLabel).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.top, 6)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(app.logLines.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .id(i)
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: app.logLines.count) { _, _ in
                    proxy.scrollTo(app.logLines.count - 1, anchor: .bottom)
                }
            }
        }
        .background(.background.secondary)
    }
}
