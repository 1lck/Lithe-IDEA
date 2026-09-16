import SwiftUI
import LitheGitModule

struct GitExecutionSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var settings: AppSettings
    @State private var feature: GitFeatureModel?
    @State private var executable = ""
    @State private var showsAdvanced = true

    var body: some View {
        GitSettingsCard {
            GitSettingsHeader(icon: "arrow.triangle.branch", title: "Git execution", subtitle: "Choose how Lithe locates Git and handles credentials.")

            GitSettingsRow("Git executable") {
                HStack(spacing: 8) {
                    TextField("Use Git from PATH", text: $executable)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                    Button("Save") { settings.gitExecutable = executable.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .buttonStyle(LithePrimaryButtonStyle(backgroundColor: LitheTheme.settingsPrimaryAction, restingOpacity: 1))
                        .disabled(executable == settings.gitExecutable)
                    Button("Use Git from PATH") { executable = ""; settings.gitExecutable = "" }
                        .buttonStyle(LitheSecondaryButtonStyle())
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                GitSettingsRow("Credentials") {
                    Toggle("Use credential helper", isOn: $settings.gitUseCredentialHelper)
                }
                Text("Git can request credentials in Lithe. Passwords are not saved by Lithe; the selected Git helper controls credential storage.")
                    .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
                    .padding(.leading, 150)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DisclosureGroup(isExpanded: $showsAdvanced) {
                if showsAdvanced, let feature {
                    GitExecutionConfigurationPane(feature: feature, editor: feature.executionSettings,
                        preferencesKey: "\(settings.gitExecutable)|\(settings.gitUseCredentialHelper)|\(settings.gitFetchOptions)",
                        applicationFetchDefaults: settings.gitFetchOptions)
                        .padding(.top, 12)
                }
            } label: {
                Label("Git behavior and configuration", systemImage: "slider.horizontal.3")
                    .font(.system(size: 12.5, weight: .semibold))
            }
        }
        .task(id: model.workspaceURL) { executable = settings.gitExecutable; feature = await model.activateGitModule() }
    }
}

struct GitSettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14, content: { content })
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(LitheTheme.divider).frame(height: 1) }
    }
}

struct GitSettingsHeader: View {
    let icon: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: icon)
                .font(.system(size: 14, weight: .semibold))
            Text(subtitle).font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
        }
    }
}

struct GitSettingsRow<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .frame(width: 138, alignment: .leading)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 30)
    }
}

private struct GitExecutionConfigurationPane: View {
    @ObservedObject var feature: GitFeatureModel
    @ObservedObject var editor: GitExecutionSettingsFeatureModel
    let preferencesKey: String
    let applicationFetchDefaults: GitFetchOptions
    @State private var scope = "local"
    @State private var remoteURL: String?
    @State private var showsTechnicalDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GitPaneSectionHeader(
                title: "Where should this apply?",
                subtitle: "Choose whether this setting belongs to the open repository or to Git everywhere."
            )
            GitSettingsRow("Configuration scope") {
                Picker("Configuration scope", selection: $scope) {
                    Text("Current repository").tag("local")
                    Text("Global Git configuration").tag("global")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            GitBranchContextView(feature: feature, remoteURL: remoteURL)

            if let snapshot = editor.snapshot {
                GitStatusBanner(snapshot: snapshot)
                if let error = snapshot.fetchError { Text(verbatim: error.message).foregroundStyle(LitheTheme.error) }

                GitPaneSectionHeader(
                    title: "Git configuration",
                    subtitle: "Choose a behavior on the right. Lithe shows the value Git is using and the value a reset would restore."
                )
                HStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(LitheTheme.secondaryText)
                    Text("Show Git key names")
                        .font(.system(size: 11.5, weight: .medium))
                    Toggle("Show Git key names", isOn: $showsTechnicalDetails)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                .foregroundStyle(LitheTheme.secondaryText)
                configurationGroup("Update", subtitle: "How Pull and Update Project combine your local and remote commits.", icon: "arrow.triangle.2.circlepath", fields: snapshot.fields.filter(isUpdateField), entries: snapshot.entries, fetchOptions: snapshot.fetchOptions)
                configurationGroup("Fetch", subtitle: "What Fetch removes or downloads before you start working.", icon: "arrow.down.circle", fields: snapshot.fields.filter(isFetchField), entries: snapshot.entries, fetchOptions: snapshot.fetchOptions)
                configurationGroup("Push", subtitle: "Where Push goes when you do not choose a target explicitly.", icon: "arrow.up.circle", fields: snapshot.fields.filter(isPushField), entries: snapshot.entries, fetchOptions: snapshot.fetchOptions)
                configurationGroup("Credentials", subtitle: "How Git matches and stores credentials for remote operations.", icon: "key", fields: snapshot.fields.filter(isCredentialField), entries: snapshot.entries, fetchOptions: snapshot.fetchOptions)
            }
            if let key = editor.savedKey { Text("Git configuration saved: \(key)").foregroundStyle(LitheTheme.accent) }
            if let error = editor.errorMessage { Text(verbatim: error).foregroundStyle(LitheTheme.error).textSelection(.enabled) }
            if editor.isBusy { ProgressView().controlSize(.small) }
            HStack {
                Spacer(minLength: 150)
                Button("Reload Git Configuration") { Task { await editor.load(at: feature.repositorySetupRoot, scope: scope) } }
                    .buttonStyle(LitheSecondaryButtonStyle())
            }
        }
        .disabled(editor.isBusy)
        .task(id: "\(feature.repositorySetupRoot?.path ?? "")|\(scope)|\(preferencesKey)") {
            await editor.load(at: feature.repositorySetupRoot, scope: scope)
        }
        .task(id: "\(feature.repositorySetupRoot?.path ?? "")|\(feature.gitReferencesVersion)") {
            if feature.gitReferences.isEmpty {
                await feature.refreshGitReferencesForSettings()
            }
            guard let root = feature.repositorySetupRoot,
                  let remote = feature.currentGitReference?.remoteName else {
                remoteURL = nil
                return
            }
            let request = GitRemoteURLRequest(root: root, remote: remote)
            remoteURL = nil
            let value = await feature.remoteURL(named: remote, at: root)
            guard !Task.isCancelled,
                  request.matches(
                    root: feature.repositorySetupRoot,
                    remote: feature.currentGitReference?.remoteName
                  ) else { return }
            remoteURL = value
        }
    }
    private func save(_ field: GitConfigurationField, value: String?) {
        guard let root = feature.repositorySetupRoot else { return }
        Task { await feature.saveExecutionConfiguration(at: root, field: field, value: value) }
    }

    @ViewBuilder
    private func configurationGroup(_ title: LocalizedStringKey, subtitle: LocalizedStringKey, icon: String, fields: [GitConfigurationField], entries: [GitConfigurationEntry], fetchOptions: GitFetchOptions?) -> some View {
        if !fields.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LitheTheme.accent)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 13, weight: .semibold))
                        Text(subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(LitheTheme.secondaryText)
                    }
                    Spacer(minLength: 12)
                }
                .padding(.bottom, 8)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(fields) { field in
                        GitEditableConfigurationRow(
                            field: field,
                            effectiveEntry: entries.last { $0.key == field.key && $0.effective },
                            inheritedEntry: inheritedEntry(for: field.key, selectedScope: scope, entries: entries),
                            effectiveValueOverride: effectiveValueOverride(for: field.key, entries: entries),
                            effectiveSourceOverride: effectiveSourceOverride(for: field.key, entries: entries),
                            fallbackEffectiveValue: fallbackEffectiveValue(for: field.key, fetchOptions: fetchOptions, entries: entries),
                            fallbackEffectiveSource: fallbackEffectiveSource(for: field.key, fetchOptions: fetchOptions, entries: entries),
                            resetFallbackValue: fallbackEffectiveValue(for: field.key, fetchOptions: applicationFetchDefaults, entries: entries),
                            resetFallbackSource: fallbackEffectiveSource(for: field.key, fetchOptions: applicationFetchDefaults, entries: entries),
                            showsTechnicalDetails: showsTechnicalDetails
                        ) { value in
                            save(field, value: value)
                        }
                        if field.id != fields.last?.id {
                            Rectangle().fill(LitheTheme.divider.opacity(0.7)).frame(height: 1)
                        }
                    }
                }
            }
            .padding(12)
            .background(LitheTheme.settingsSurface.opacity(0.48))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(LitheTheme.inputBorder.opacity(0.65), lineWidth: 1) }
        }
    }

    private func isUpdateField(_ field: GitConfigurationField) -> Bool {
        field.key.hasPrefix("pull.")
    }

    private func isFetchField(_ field: GitConfigurationField) -> Bool {
        field.key.hasPrefix("fetch.") || field.key.hasPrefix("lithe.fetch.")
    }

    private func isPushField(_ field: GitConfigurationField) -> Bool {
        field.key.hasPrefix("push.")
    }

    private func isCredentialField(_ field: GitConfigurationField) -> Bool {
        field.key.hasPrefix("credential.")
    }

    private func fallbackEffectiveValue(for key: String, fetchOptions: GitFetchOptions?, entries: [GitConfigurationEntry]) -> String? {
        GitConfigurationFallback.value(for: key, fetchOptions: fetchOptions, entries: entries)
    }

    private func fallbackEffectiveSource(for key: String, fetchOptions: GitFetchOptions?, entries: [GitConfigurationEntry]) -> LocalizedStringKey {
        if key == "lithe.fetch.submodules", fetchOptions?.submodules == .inherit {
            if let gitEntry = entries.last(where: { $0.key == "fetch.recursesubmodules" && $0.effective }) {
                return LocalizedStringKey(sourceScope(gitEntry.scope))
            }
            return "Git default"
        }
        return key.hasPrefix("lithe.") ? "Lithe application default" : "Git default"
    }

    private func effectiveValueOverride(for key: String, entries: [GitConfigurationEntry]) -> String? {
        guard key == "lithe.fetch.submodules",
              let appEntry = entries.last(where: { $0.key == key && $0.effective }),
              appEntry.value == "inherit" else { return nil }
        return entries.last(where: { $0.key == "fetch.recursesubmodules" && $0.effective })?.value ?? "false"
    }

    private func effectiveSourceOverride(for key: String, entries: [GitConfigurationEntry]) -> LocalizedStringKey? {
        guard key == "lithe.fetch.submodules",
              let appEntry = entries.last(where: { $0.key == key && $0.effective }),
              appEntry.value == "inherit" else { return nil }
        if let gitEntry = entries.last(where: { $0.key == "fetch.recursesubmodules" && $0.effective }) {
            return LocalizedStringKey(sourceScope(gitEntry.scope))
        }
        return "Git default"
    }

    private func sourceScope(_ scope: String) -> String {
        switch scope {
        case "local": return "This repository"
        case "global": return "Global Git"
        case "system": return "System Git"
        case "application": return "Lithe application default"
        default: return scope.capitalized
        }
    }

    private func inheritedEntry(for key: String, selectedScope: String, entries: [GitConfigurationEntry]) -> GitConfigurationEntry? {
        guard let selectedPriority = scopePriority[selectedScope] else { return nil }
        return entries.last { entry in
            entry.key == key && (scopePriority[entry.scope] ?? Int.max) < selectedPriority
        }
    }

    private var scopePriority: [String: Int] {
        ["system": 0, "global": 1, "local": 2, "command": 3]
    }
}

struct GitRemoteURLRequest: Equatable {
    let root: URL
    let remote: String

    func matches(root currentRoot: URL?, remote currentRemote: String?) -> Bool {
        currentRoot?.standardizedFileURL == root.standardizedFileURL && currentRemote == remote
    }
}

private struct GitPaneSectionHeader: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(subtitle)
                .font(LitheTheme.smallFont)
                .foregroundStyle(LitheTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct GitStatusBanner: View {
    let snapshot: GitExecutionSettingsSnapshot

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: snapshot.executable == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(snapshot.executable == nil ? LitheTheme.warning : LitheTheme.success)
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(snapshot.executable == nil ? "Git was not found" : "Git is ready"))
                    .font(.system(size: 12.5, weight: .semibold))
                Group {
                    if let executable = snapshot.executable {
                        Text(verbatim: "\(snapshot.version) · \(executable)")
                    } else {
                        Text("Choose a Git executable above to continue.")
                    }
                }
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
        }
        .padding(11)
        .background(LitheTheme.settingsSurface.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).stroke(LitheTheme.inputBorder.opacity(0.7), lineWidth: 1) }
    }
}

private struct GitBranchContextView: View {
    @ObservedObject var feature: GitFeatureModel
    let remoteURL: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Branch context", systemImage: "arrow.triangle.branch")
                .font(.system(size: 12, weight: .semibold))

            HStack(alignment: .top, spacing: 24) {
                contextItem("Current branch", currentBranchValue)
                contextItem("Upstream branch", upstreamValue)
                contextItem("Remote", remoteValue)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Remote URL")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(LitheTheme.secondaryText)
                if let remoteURL, let presentation = GitRemoteURLPresentation(remoteURL) {
                    Text(verbatim: presentation.displayURL)
                        .font(.system(size: 10.5, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(Text(verbatim: presentation.displayURL))
                    if let browserURL = presentation.browserURL {
                        Link("Open remote", destination: browserURL)
                            .font(.system(size: 10.5, weight: .medium))
                    }
                } else {
                    Text(remoteURLValue)
                        .font(.system(size: 10.5))
                        .foregroundStyle(LitheTheme.secondaryText)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LitheTheme.settingsSurface.opacity(0.58))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).stroke(LitheTheme.inputBorder.opacity(0.62), lineWidth: 1) }
    }

    @ViewBuilder
    private func contextItem(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(LitheTheme.secondaryText)
            Text(verbatim: value)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(Text(verbatim: value))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var currentBranchValue: String {
        feature.currentGitReference?.shortName ?? feature.currentBranch
    }

    private var upstreamValue: String {
        if let upstream = feature.currentGitReference?.upstreamShortName {
            return upstream
        }
        return feature.gitReferences.isEmpty && feature.currentBranch != "No Git"
            ? String(localized: "Loading branch details…")
            : String(localized: "No upstream configured")
    }

    private var remoteValue: String {
        if let remote = feature.currentGitReference?.remoteName {
            return remote
        }
        return feature.gitReferences.isEmpty && feature.currentBranch != "No Git"
            ? String(localized: "Loading branch details…")
            : String(localized: "No remote")
    }

    private var remoteURLValue: LocalizedStringKey {
        feature.gitReferences.isEmpty && feature.currentBranch != "No Git"
            ? "Loading branch details…"
            : "No remote URL"
    }
}

private struct GitEditableConfigurationRow: View {
    let field: GitConfigurationField
    let effectiveEntry: GitConfigurationEntry?
    let inheritedEntry: GitConfigurationEntry?
    let effectiveValueOverride: String?
    let effectiveSourceOverride: LocalizedStringKey?
    let fallbackEffectiveValue: String?
    let fallbackEffectiveSource: LocalizedStringKey
    let resetFallbackValue: String?
    let resetFallbackSource: LocalizedStringKey
    let showsTechnicalDetails: Bool
    let onSave: (String?) -> Void
    @State private var selection = ""

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(LitheTheme.primaryText)
                    if !field.configuredValues.isEmpty {
                        Text("Override")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(LitheTheme.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(LitheTheme.accent.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
                Text(description)
                    .font(.system(size: 10.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                effectiveValueLine
                if !field.configuredValues.isEmpty {
                    // Reset targets the nearest lower-priority configured scope,
                    // even when that value is also the current effective entry.
                    if let inheritedEntry {
                        inheritedValueLine(label: "If reset, use", value: inheritedEntry.value, source: LocalizedStringKey(sourceScope(inheritedEntry.scope)), origin: inheritedEntry.origin)
                    } else if let resetFallbackValue {
                        inheritedValueLine(label: "If reset, use", value: resetFallbackValue, source: resetFallbackSource, origin: nil)
                    }
                }
                if showsTechnicalDetails {
                    Text(verbatim: "Git key: \(field.key)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(LitheTheme.tertiaryText)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 7) {
                LitheSettingsSelect(
                    selection: $selection,
                    options: [""] + field.choices,
                    width: 220,
                    accessibilityLabel: "Value",
                    title: { choice in
                        choice.isEmpty ? "Inherit" : choiceKey(choice)
                    }
                )

                HStack(spacing: 7) {
                    Button("Reset") {
                        if field.configuredValues.isEmpty {
                            selection = ""
                        } else {
                            onSave(nil)
                        }
                    }
                    .buttonStyle(LitheSecondaryButtonStyle(horizontalPadding: 12, height: 28, fontSize: 12))
                    .disabled(!canReset)
                    .help("Reset this setting to its inherited value")

                    Button("Apply") {
                        onSave(selection.isEmpty ? nil : selection)
                    }
                    .buttonStyle(LithePrimaryButtonStyle(restingOpacity: isDirty ? 0.92 : 0.38))
                    .disabled(!isDirty)
                }
            }
            .frame(width: 220, alignment: .trailing)
        }
        .padding(.vertical, 10)
        .task(id: "\(field.key)|\(field.configuredValues)") {
            selection = field.configuredValues.first ?? ""
        }
    }

    private var title: LocalizedStringKey {
        switch field.key {
        case "fetch.prune": return "Prune stale remote branches"
        case "fetch.prunetags": return "Prune stale tags"
        case "fetch.recursesubmodules": return "Fetch submodules"
        case "pull.rebase": return "Pull strategy"
        case "pull.ff": return "Fast-forward on pull"
        case "push.default": return "Default push behavior"
        case "credential.usehttppath": return "Use full HTTP path for credentials"
        case "lithe.fetch.prune": return "Lithe: prune stale branches"
        case "lithe.fetch.submodules": return "Lithe: fetch submodules"
        case "lithe.fetch.tags": return "Lithe: fetch tags"
        default: return LocalizedStringKey(field.key)
        }
    }

    private var description: LocalizedStringKey {
        switch field.key {
        case "fetch.prune": return "Remove local remote branches that no longer exist on the server."
        case "fetch.prunetags": return "Remove local tags that were deleted from the remote."
        case "fetch.recursesubmodules": return "Choose whether Fetch also updates submodules."
        case "pull.rebase": return "Choose whether Pull merges remote commits or rebases your local commits."
        case "pull.ff": return "Choose what Pull does when your branch and the remote branch have diverged."
        case "push.default": return "Choose which branch Push targets when you do not name one."
        case "credential.usehttppath": return "Include the URL path when Git looks up HTTP credentials."
        case "lithe.fetch.prune": return "Controls whether Lithe's ordinary Fetch removes stale remote branches."
        case "lithe.fetch.submodules": return "Controls how Lithe's ordinary Fetch updates submodules. Inherit follows Git's fetch.recurseSubmodules setting."
        case "lithe.fetch.tags": return "Controls how Lithe's ordinary Fetch synchronizes tags. Inherit leaves tag selection to Git and the remote."
        default: return "Choose how this Git setting behaves."
        }
    }

    @ViewBuilder
    private var effectiveValueLine: some View {
        HStack(spacing: 4) {
            Text(field.configuredValues.isEmpty ? "Inherited value" : "Currently effective")
            if let effectiveEntry {
                Text(choiceTitle(effectiveValueOverride ?? effectiveEntry.value))
                Text(verbatim: "·")
                Text(effectiveSourceOverride ?? LocalizedStringKey(sourceScope(effectiveEntry.scope)))
                if effectiveSourceOverride == nil, !effectiveEntry.origin.isEmpty {
                    Text(verbatim: "· \(effectiveEntry.origin)")
                }
            } else if let fallbackEffectiveValue {
                Text(choiceTitle(fallbackEffectiveValue))
                Text(verbatim: "·")
                Text(fallbackEffectiveSource)
            } else {
                Text("Unavailable")
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(LitheTheme.secondaryText)
        .lineLimit(1)
        .truncationMode(.middle)
    }

    @ViewBuilder
    private func inheritedValueLine(label: LocalizedStringKey, value: String, source: LocalizedStringKey, origin: String?) -> some View {
        HStack(spacing: 4) {
            Text(label)
            Text(choiceTitle(value))
            Text(verbatim: "·")
            Text(source)
            if let origin, !origin.isEmpty {
                Text(verbatim: "· \(origin)")
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(LitheTheme.secondaryText.opacity(0.9))
        .lineLimit(1)
        .truncationMode(.middle)
    }

    private func choiceTitle(_ choice: String) -> LocalizedStringKey {
        LocalizedStringKey(choiceKey(choice))
    }

    private func choiceKey(_ choice: String) -> String {
        switch (field.key, choice) {
        case ("fetch.prune", "true"), ("lithe.fetch.prune", "true"): return "Remove stale branches"
        case ("fetch.prune", "false"), ("lithe.fetch.prune", "false"): return "Keep stale branches"
        case ("fetch.prunetags", "true"): return "Remove stale tags"
        case ("fetch.prunetags", "false"): return "Keep stale tags"
        case ("fetch.recursesubmodules", "true"), ("lithe.fetch.submodules", "yes"):
            return "Fetch all"
        case ("lithe.fetch.submodules", "true"): return "Fetch all"
        case ("fetch.recursesubmodules", "on-demand"), ("lithe.fetch.submodules", "onDemand"), ("lithe.fetch.submodules", "on-demand"):
            return "Fetch when needed"
        case ("lithe.fetch.submodules", "inherit"): return "Follow Git setting"
        case ("lithe.fetch.submodules", "no"), ("lithe.fetch.submodules", "false"): return "Do not fetch"
        case (_, "true"):
            if field.key == "pull.rebase" { return "Rebase" }
            if field.key == "pull.ff" { return "Allow fast-forward" }
            return "On"
        case (_, "false"):
            if field.key == "pull.rebase" { return "Merge" }
            if field.key == "pull.ff" { return "Create merge commit" }
            if field.key == "fetch.recursesubmodules" { return "Do not fetch" }
            return "Off"
        case ("pull.rebase", "merges"): return "Rebase and keep merges"
        case ("pull.ff", "only"): return "Fast-forward only"
        case ("credential.usehttppath", "true"): return "Match host and URL path"
        case ("credential.usehttppath", "false"): return "Match host only"
        case ("lithe.fetch.tags", "inherit"): return "Follow Git tag rules"
        case ("lithe.fetch.tags", "all"): return "Fetch all"
        case ("lithe.fetch.tags", "none"): return "Do not fetch"
        case ("lithe.fetch.tags", "prune"): return "Sync and remove missing tags"
        case ("push.default", "simple"): return "Current branch with safety check"
        case ("push.default", "current"): return "Current branch"
        case ("push.default", "upstream"): return "Upstream branch"
        case ("push.default", "matching"): return "Matching branches"
        case ("push.default", "nothing"): return "Do not push by default"
        default: return choice
        }
    }

    private var isDirty: Bool {
        field.configuredValues != (selection.isEmpty ? [] : [selection])
    }

    private var canReset: Bool {
        !field.configuredValues.isEmpty || !selection.isEmpty
    }

    private func sourceScope(_ scope: String) -> String {
        switch scope {
        case "local": return "This repository"
        case "global": return "Global Git"
        case "system": return "System Git"
        case "application": return "Application default"
        default: return scope.capitalized
        }
    }
}
