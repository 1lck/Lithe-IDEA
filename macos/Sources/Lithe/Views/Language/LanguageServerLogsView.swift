import LitheModuleAPI
import SwiftUI

/// Editor-area "LSP Logs" tab: one server at a time, read from the v2 log store.
struct LanguageServerLogsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var feature: LanguageServerLogsModel

    private var providerIDs: [String] {
        Set(model.statusBarLanguageServers.map(\.id)
            + (feature.providerID.isEmpty ? [] : [feature.providerID])).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    serverPicker
                    logChannel
                    levelPicker
                    Spacer(minLength: 0)
                    clearButton
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) { serverPicker; Spacer(minLength: 0); clearButton }
                    HStack(spacing: 8) { logChannel; Spacer(minLength: 0); levelPicker }
                }
            }
            .font(LitheTheme.uiFont(size: 12))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            LanguageServerLogOutput(logs: feature.logs, channelError: feature.error, retry: feature.retry)
                // Replacing a filtered buffer is a new viewport, not an append to
                // another server's output. Native selection/scroll stays view-local.
                .id(feature.providerID + ":" + feature.minimumLevel.rawValue)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(LitheTheme.editor)
        .onAppear { selectInitialProvider() }
        .onChange(of: providerIDs) { _ in selectInitialProvider() }
    }

    private var serverPicker: some View {
        LitheSettingsSelect(selection: Binding(get: { feature.providerID }, set: feature.select),
            options: providerIDs, width: 180,
            accessibilityLabel: "Language Server", title: providerName, localizesTitles: false)
    }

    private var levelPicker: some View {
        LitheSettingsSelect(selection: Binding(get: { feature.minimumLevel }, set: feature.setMinimumLevel),
            options: LanguageServerLogsModel.MinimumLevel.allCases, width: 120,
            accessibilityLabel: "Minimum level", title: levelTitle)
    }

    private var logChannel: some View {
        HStack(spacing: 4) {
            Text("Server Logs").foregroundStyle(LitheTheme.accent)
            LitheInfoTip("Shows the selected server's session events, stderr and server messages from the redacted diagnostic logs. Server Trace and RPC message capture are not available. Application logs are in Logs and Diagnostics.")
        }
    }

    private var clearButton: some View {
        Button("Clear View") { feature.clear() }
            .buttonStyle(.litheNoPress)
            .help("Clear only the selected server's visible logs. Collected diagnostic logs are kept.")
    }

    private func selectInitialProvider() {
        if feature.providerID.isEmpty, let first = providerIDs.first { feature.select(first) }
    }

    private func providerName(_ id: String) -> String {
        model.statusBarLanguageServers.first { $0.id == id }?.displayName ?? id
    }

    private func levelTitle(_ level: LanguageServerLogsModel.MinimumLevel) -> String {
        switch level {
        case .info: "Info"
        case .warning: "Warning"
        case .error: "Error"
        }
    }
}

/// Observes the inner log query separately so live batches redraw only the output.
private struct LanguageServerLogOutput: View {
    @ObservedObject var logs: LogWindowModel
    let channelError: String?
    let retry: () -> Void
    /// Formats each record once; a publish that leaves the records unchanged
    /// formats nothing.
    @StateObject private var text = LanguageServerLogText()

    var body: some View {
        VStack(spacing: 0) {
            if let error = channelError ?? logs.error {
                HStack(spacing: 8) {
                    Text(error).foregroundStyle(LitheTheme.error).lineLimit(2)
                    Button("Retry", action: retry).buttonStyle(.litheNoPress)
                    Spacer(minLength: 0)
                }
                .font(LitheTheme.uiFont(size: 12))
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }
            OutputTextView(
                output: text.update(logs.state.records),
                searchRoots: [],
                fileExists: { _ in false },
                emptyMessage: L10n.string("No matching language server logs"),
                fontSize: 12,
                onOpenLocation: { _, _, _ in }
            )
        }
    }
}
