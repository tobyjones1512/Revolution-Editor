import SwiftUI

struct WorkbenchLogPanelView: View {
    @EnvironmentObject var workbench: WorkbenchState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(workbench.logLines.enumerated()), id: \.offset) { i, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .id(i)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: workbench.logLines.count) { _, _ in
                proxy.scrollTo(workbench.logLines.count - 1, anchor: .bottom)
            }
        }
        .background(.background.secondary)
    }
}
