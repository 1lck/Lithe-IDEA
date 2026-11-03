import LitheModuleAPI
import SwiftUI

struct ApplicationLogSettingsView: View {
    @ObservedObject var feature: DiagnosticsFeatureModel
    var body: some View {
        Button("Open Log Window") { feature.openLogs() }
            .buttonStyle(LitheActionButtonStyle())
            .accessibilityIdentifier("logs.open-window")
    }
}

struct ApplicationLogDiagnosticsView: View {
    @ObservedObject var feature: DiagnosticsFeatureModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Toggle("Detailed diagnostics", isOn: Binding(
                    get: { feature.diagnosticEnabled },
                    set: { enabled in Task { await feature.setDiagnosticEnabled(enabled) } }
                ))
                .disabled(feature.isBusy)
                .accessibilityIdentifier("logs.diagnostic-toggle")
                LitheInfoTip("Detailed diagnostics cover all channels and expire after 15 minutes.")
            }
        }
    }
}

struct ApplicationLogCleanupView: View {
    @ObservedObject var feature: DiagnosticsFeatureModel
    @State private var confirmsClear = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Log storage: \(ByteCountFormatter.string(fromByteCount: Int64(clamping: feature.diskBytes), countStyle: .file))")
                .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
            Button("Clear Logs") { confirmsClear = true }
                .buttonStyle(LitheActionButtonStyle())
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
            ApplicationLogSettingsView(feature: feature)
            LitheSettingsSection("Diagnostics") { ApplicationLogDiagnosticsView(feature: feature) }
            LitheSettingsSection("Log locations", content: locations)
            LitheSettingsSection(title: "Retention and cleanup", accessory: {
                LitheInfoTip("Module logs rotate at 10 MiB and expire after 30 days. The combined budget is 100 MiB; performance logs have a separate 20 MiB budget.")
            }) { ApplicationLogCleanupView(feature: feature) }
            LitheSettingsSection(title: "Diagnostic bundle", accessory: {
                LitheInfoTip("Preview and export the selected logs with environment information. Credentials and home-directory paths are redacted; source code, editor buffers and terminal history are excluded.")
            }) {
                Button("Export diagnostic logs") { feature.presentExport() }
                    .buttonStyle(LitheActionButtonStyle()).disabled(feature.isBusy)
                    .accessibilityIdentifier("logs.export")
            }
        }
        .task { await feature.refreshStatus() }
        .sheet(isPresented: Binding(get: { feature.isPresented && !feature.isFromLogWindow }, set: { if !$0 { feature.dismiss() } })) {
            DiagnosticsExportSheet(feature: feature)
        }
    }
}
