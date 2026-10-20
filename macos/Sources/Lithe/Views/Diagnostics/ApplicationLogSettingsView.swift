import SwiftUI

/// A bounded text preview over the same module/session selection used for export.
struct ApplicationLogSettingsView: View {
    @ObservedObject var feature: DiagnosticsFeatureModel
    @State private var confirmsClear = false

    private func categoryTitle(_ category: String) -> String {
        ["all": "All modules", "application": "Application", "language": "Editor and language services",
         "run": "Build, run and debug", "git": "Git", "plugins": "Plugins", "performance": "Performance"][category] ?? category
    }
    private func sessionTitle(_ session: String) -> String {
        ["current": "Current session", "previous": "Previous session", "all": "All sessions"][session] ?? session
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                LitheSettingsSelect(selection: $feature.logCategory, options: ["all", "application", "language", "run", "git", "plugins", "performance"], width: 150, accessibilityLabel: "Log filter", title: { categoryTitle($0) })
                LitheSettingsSelect(selection: $feature.logSession, options: ["current", "previous", "all"], width: 150, accessibilityLabel: "Log filter", title: { sessionTitle($0) })
                LitheSettingsSelect(selection: $feature.logLevel, options: ["debug", "info", "warn", "error"], width: 90, accessibilityLabel: "Log level", title: { $0.uppercased() })
            }
            LitheSearchTextField("Filter log messages", text: $feature.logSearch)
                .litheSearchField()
                .onSubmit { Task { await feature.refreshLogs() } }
            HStack {
                TextField("From (UTC ISO 8601)", text: $feature.logSince)
                TextField("Until (UTC ISO 8601)", text: $feature.logUntil)
            }
            HStack {
                Button("Refresh Logs") { Task { await feature.refreshLogs() } }
                    .disabled(feature.isLoadingLogs)
                Button("Export Diagnostics Bundle") { feature.presentExport() }
                Button("Clear Logs") { confirmsClear = true }
            }
            Toggle("Detailed diagnostics for 15 minutes", isOn: Binding(
                get: { feature.diagnosticEnabled },
                set: { enabled in Task { await feature.setDiagnosticEnabled(enabled) } }
            ))
            Text(feature.logStatus)
                .font(LitheTheme.smallFont)
                .foregroundStyle(LitheTheme.secondaryText)
                .textSelection(.enabled)
            ScrollView([.horizontal, .vertical]) {
                Text(feature.logContent.isEmpty ? String(localized: "No matching logs") : feature.logContent)
                    .font(LitheTheme.uiFont(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 180)
            .litheScrollViewChrome()
        }
        .task { await feature.refreshLogs() }
        .confirmationDialog("Delete collected application logs?", isPresented: $confirmsClear) {
            Button("Clear Logs", role: .destructive) { Task { await feature.clearLogs() } }
        }
    }
}
