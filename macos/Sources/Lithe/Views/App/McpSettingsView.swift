import SwiftUI

struct McpSettingsView: View {
    @ObservedObject var feature: IdeCapabilitiesFeatureModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MCP Configuration").font(.headline)
            Text("Authorize this project to expose environment, Maven, run configurations and output to connected agents. Output may contain sensitive project data. Access ends when this project or Lithe closes.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Enabled plugins can also use this project grant.").font(.caption).foregroundStyle(.secondary)
            Toggle("Allow project environment and Maven configuration changes", isOn: $feature.allowConfigure).disabled(feature.isEnabled)
            Toggle("Allow run, build, reload and stop (executes project code)", isOn: $feature.allowExecute).disabled(feature.isEnabled)
            HStack {
                Button(feature.isEnabled ? String(localized: "Disable MCP") : String(localized: "Enable MCP")) {
                    if feature.isEnabled { feature.disable() } else { feature.enable() }
                }
                if feature.isEnabled { Button("Copy agent configuration") { feature.copyConfiguration() } }
            }
            if !feature.configuration.isEmpty {
                Text(feature.configuration).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            if let error = feature.error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(16)
    }
}
