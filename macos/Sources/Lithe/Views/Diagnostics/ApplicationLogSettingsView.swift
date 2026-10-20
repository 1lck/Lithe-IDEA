import SwiftUI

private func logCategoryTitle(_ category: String) -> String {
    ["all": "All modules", "application": "Application", "language": "Editor and language services",
     "run": "Build, run and debug", "git": "Git", "plugins": "Plugins", "performance": "Performance"][category] ?? category
}

/// A bounded preview over the same module/session selection used for export.
struct ApplicationLogSettingsView: View {
    @ObservedObject var feature: DiagnosticsFeatureModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                LitheSettingsSelect(selection: $feature.logCategory, options: ["all", "application", "language", "run", "git", "plugins", "performance"], width: 150, accessibilityLabel: "Module", title: logCategoryTitle)
                LitheSettingsSelect(selection: $feature.logSession, options: ["current", "previous", "all"], width: 150, accessibilityLabel: "Session", title: {
                    ["current": "Current session", "previous": "Previous session", "all": "All sessions"][$0] ?? $0
                })
                LitheSettingsSelect(selection: $feature.logLevel, options: ["debug", "info", "warn", "error"], width: 90, accessibilityLabel: "Minimum level", title: { $0.uppercased() })
            }
            LitheSearchTextField("Filter log messages", text: $feature.logSearch)
                .litheSearchField()
                .onSubmit { Task { await feature.refreshLogs() } }
            HStack {
                TextField("From (UTC ISO 8601)", text: $feature.logSince).litheSettingsTextField()
                TextField("Until (UTC ISO 8601)", text: $feature.logUntil).litheSettingsTextField()
            }
            Button("Refresh Logs") { Task { await feature.refreshLogs() } }
                .buttonStyle(LitheSecondaryButtonStyle())
                .disabled(feature.isBusy)
                .accessibilityIdentifier("logs.refresh")
            if feature.isLoadingLogs { ProgressView().controlSize(.small) }
            if feature.logTruncated {
                Text("Earlier evidence was omitted by collection limits.")
                    .foregroundStyle(LitheTheme.warning)
            }
            if let error = feature.logError {
                Text(error).foregroundStyle(LitheTheme.error)
                    .accessibilityIdentifier("logs.error")
            }
            Text("Dropped: \(feature.droppedEvents); write failures: \(feature.writeFailures)")
                .font(LitheTheme.smallFont)
                .foregroundStyle(LitheTheme.secondaryText)
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    Group {
                        if feature.logContent.isEmpty { Text("No matching logs") }
                        else { Text(verbatim: feature.logContent) }
                    }
                    .font(LitheTheme.uiFont(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                }
                .litheScrollViewChrome()
            }
            .frame(height: 180)
            .accessibilityIdentifier("logs.timeline")
        }
        .task { await feature.refreshLogs() }
    }
}

struct ApplicationLogDiagnosticsView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var feature: DiagnosticsFeatureModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Detailed diagnostics", isOn: Binding(
                get: { feature.diagnosticEnabled },
                set: { enabled in Task { await feature.setDiagnosticEnabled(enabled) } }
            ))
            .disabled(feature.isBusy)
            .accessibilityIdentifier("logs.diagnostic-toggle")
            Text("Detailed diagnostics cover the selected module and expire after 15 minutes. Refresh to see the current status.")
                .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
            if feature.diagnosticEnabled {
                let module = String(localized: String.LocalizationValue(logCategoryTitle(feature.diagnosticCategory ?? "all")), locale: locale)
                Text("Detailed diagnostics: On (\(module))")
            } else {
                Text("Detailed diagnostics: Off")
            }
        }
    }
}

struct ApplicationLogCleanupView: View {
    @ObservedObject var feature: DiagnosticsFeatureModel
    @State private var confirmsClear = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Module logs rotate at 10 MiB and expire after 30 days. The combined budget is 100 MiB; performance logs have a separate 20 MiB budget.")
                .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
            Button("Clear Logs") { confirmsClear = true }
                .buttonStyle(LitheSecondaryButtonStyle())
                .disabled(feature.isBusy)
                .accessibilityIdentifier("logs.clear")
            if let error = feature.logError { Text(error).foregroundStyle(LitheTheme.error) }
            if feature.logsCleared { Text("Collected logs cleared.").foregroundStyle(LitheTheme.success) }
        }
        .confirmationDialog("Clear collected logs?", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("Clear Logs", role: .destructive) { Task { await feature.clearLogs() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete only Lithe-managed logs in the active directory across all modules and sessions. Filters do not limit this action. New events will continue to be recorded.")
        }
    }
}

/// Both settings platforms use this section order; filesystem controls stay native.
struct ApplicationLogDiagnosticsPage<Locations: View>: View {
    @ObservedObject var feature: DiagnosticsFeatureModel
    @ViewBuilder var locations: () -> Locations

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose a module, enable detailed diagnostics, reproduce the problem, then preview and export a diagnostic bundle.")
                .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
            LitheSettingsSection("Log timeline") { ApplicationLogSettingsView(feature: feature) }
            LitheSettingsSection("Diagnostics") { ApplicationLogDiagnosticsView(feature: feature) }
            LitheSettingsSection("Log locations", content: locations)
            LitheSettingsSection("Retention and cleanup") { ApplicationLogCleanupView(feature: feature) }
            LitheSettingsSection("Diagnostic bundle") {
                Text("Preview and export the selected logs with environment information. Credentials and home-directory paths are redacted; source code, editor buffers and terminal history are excluded.")
                    .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
                Button("Preview and Export…") { feature.presentExport() }
                    .buttonStyle(LitheSecondaryButtonStyle()).disabled(feature.isBusy)
                    .accessibilityIdentifier("logs.export")
            }
        }
        .sheet(isPresented: Binding(get: { feature.isPresented }, set: { if !$0 { feature.dismiss() } })) {
            DiagnosticsExportSheet(feature: feature)
        }
    }
}
