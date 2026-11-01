import LitheModuleAPI
import SwiftUI

struct LanguageServerLogsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var feature: LanguageServerLogsModel

    private var providerIDs: [String] {
        Set(feature.entries.map(\.providerID) + model.statusBarLanguageServers.map(\.id)
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
            OutputTextView(
                output: logOutput,
                searchRoots: [],
                fileExists: { _ in false },
                emptyMessage: L10n.string("No matching language server logs"),
                fontSize: 12,
                onOpenLocation: { _, _, _ in }
            )
            // Replacing a filtered buffer is a new viewport, not an append to
            // another server's output. Native selection/scroll stays view-local.
            .id(feature.providerID + ":" + String(describing: feature.minimumLevel))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(LitheTheme.editor)
        .onAppear { selectInitialProvider() }
        .onChange(of: providerIDs) { _ in selectInitialProvider() }
    }

    private var serverPicker: some View {
        LitheSettingsSelect(selection: $feature.providerID, options: providerIDs, width: 180,
            accessibilityLabel: "Language Server", title: providerName, localizesTitles: false)
    }

    private var levelPicker: some View {
        LitheSettingsSelect(selection: $feature.minimumLevel,
            options: LanguageServerLogsModel.MinimumLevel.allCases, width: 120,
            accessibilityLabel: "Minimum level", title: levelTitle)
    }

    private var logChannel: some View {
        HStack(spacing: 4) {
            Text("Server Logs").foregroundStyle(LitheTheme.accent)
            LitheInfoTip("Shows session events and server output. Server Trace and RPC message capture are not available.")
        }
    }

    private var clearButton: some View {
        Button("Clear View") { feature.clear() }
            .buttonStyle(.litheNoPress)
            .help("Clear only the selected server's visible logs. Collected diagnostic logs are kept.")
    }

    private func selectInitialProvider() {
        if feature.providerID.isEmpty, let first = providerIDs.first { feature.providerID = first }
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

    private var logOutput: String {
        feature.visibleEntries.map { entry in
            let timestamp = entry.timestamp.formatted(date: .omitted, time: .standard)
            // These are structured log identifiers. The shared console colors
            // their prefixes; upstream messages and details remain unchanged.
            let level = entry.level == .warning ? "WARN" : entry.level.rawValue.uppercased()
            let detail = entry.detail.map { "\n" + $0 } ?? ""
            return "[\(level)] \(timestamp) \(entry.message)\(detail)\n"
        }
        .joined()
    }
}
