import SwiftUI
import LitheGitModule

struct GitExecutionSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var settings: AppSettings
    @State private var feature: GitFeatureModel?
    @State private var executable = ""
    @State private var showsAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Git execution").font(.headline)
            Text("Git executable").font(LitheTheme.smallFont)
            HStack {
                TextField("Use Git from PATH", text: $executable).textFieldStyle(.roundedBorder)
                Button("Save") { settings.gitExecutable = executable.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .disabled(executable == settings.gitExecutable)
                Button("Use Git from PATH") { executable = ""; settings.gitExecutable = "" }
            }
            Toggle("Use credential helper", isOn: $settings.gitUseCredentialHelper)
            Text("Git can request credentials in Lithe. Passwords are not saved by Lithe; the selected Git helper controls credential storage.")
                .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
            DisclosureGroup("Advanced configuration and sources", isExpanded: $showsAdvanced) {
                if showsAdvanced, let feature {
                    GitExecutionConfigurationPane(feature: feature, editor: feature.executionSettings,
                        preferencesKey: "\(settings.gitExecutable)|\(settings.gitUseCredentialHelper)|\(settings.gitFetchOptions)")
                        .padding(.top, 12)
                }
            }
        }
        .task(id: model.workspaceURL) { executable = settings.gitExecutable; feature = await model.activateGitModule() }
    }
}

private struct GitExecutionConfigurationPane: View {
    @ObservedObject var feature: GitFeatureModel
    @ObservedObject var editor: GitExecutionSettingsFeatureModel
    let preferencesKey: String
    @State private var scope = "local"
    @State private var selectedKey = "lithe.fetch.prune"
    @State private var value = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Configuration sources").font(.headline)
            Text("One-time choices override repository preferences, which override application defaults. Git configuration is changed only when you save or clear a field below.")
                .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
            Picker("Configuration scope", selection: $scope) {
                Text("Current repository").tag("local")
                Text("Global Git configuration").tag("global")
            }.pickerStyle(.segmented)
            if let snapshot = editor.snapshot {
                Text(verbatim: "\(snapshot.version)\n\(snapshot.executable ?? "Git not found")")
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text("Temporary configuration").font(.subheadline)
                ForEach(snapshot.temporaryConfig, id: \.self) { pair in
                    Text(verbatim: pair.joined(separator: " = ")).font(.system(.caption, design: .monospaced))
                }
                if let options = snapshot.fetchOptions {
                    Text("Effective Fetch options").font(.subheadline)
                    ForEach([("prune", String(options.prune)), ("submodules", options.submodules.rawValue), ("tags", options.tags.rawValue)], id: \.0) { name, value in
                        Text(verbatim: "\(name) = \(value) · \(snapshot.fetchSources?[name]?.scope ?? "application") · \(snapshot.fetchSources?[name]?.origin ?? "Lithe")")
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
                if let error = snapshot.fetchError { Text(verbatim: error.message).foregroundStyle(LitheTheme.error) }
                Picker("Configuration key", selection: $selectedKey) {
                    ForEach(snapshot.fields) { field in Text(verbatim: field.key).tag(field.key) }
                }
                if let field = snapshot.fields.first(where: { $0.key == selectedKey }) {
                    HStack {
                        Picker("Configuration value", selection: $value) {
                            Text("Choose a value").tag("")
                            ForEach(field.choices, id: \.self) { choice in Text(verbatim: choice).tag(choice) }
                        }
                        Button("Save") { save(field, value: value) }.disabled(value.isEmpty || field.configuredValues == [value])
                        Button("Clear Override") { save(field, value: nil) }.disabled(field.configuredValues.isEmpty)
                    }
                    .task(id: "\(snapshot.scope)|\(field.key)|\(field.configuredValues)") { value = field.configuredValues.last ?? "" }
                }
                ForEach(Array(snapshot.entries.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "\(entry.key) = \(entry.value)")
                        Text(verbatim: "\(entry.scope) · \(entry.origin)")
                            .foregroundStyle(LitheTheme.secondaryText)
                        if !entry.effective { Text("Overridden by a later value").foregroundStyle(LitheTheme.secondaryText) }
                    }.font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
            if let key = editor.savedKey { Text("Git configuration saved: \(key)").foregroundStyle(LitheTheme.accent) }
            if let error = editor.errorMessage { Text(verbatim: error).foregroundStyle(LitheTheme.error).textSelection(.enabled) }
            if editor.isBusy { ProgressView().controlSize(.small) }
            Button("Reload Git Configuration") { Task { await editor.load(at: feature.repositorySetupRoot, scope: scope) } }
        }
        .disabled(editor.isBusy)
        .task(id: "\(feature.repositorySetupRoot?.path ?? "")|\(scope)|\(preferencesKey)") {
            if scope == "global" && selectedKey.hasPrefix("lithe.") { selectedKey = "fetch.prune" }
            await editor.load(at: feature.repositorySetupRoot, scope: scope)
        }
    }
    private func save(_ field: GitConfigurationField, value: String?) {
        guard let root = feature.repositorySetupRoot else { return }
        Task { await feature.saveExecutionConfiguration(at: root, field: field, value: value) }
    }
}
