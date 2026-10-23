import AppKit
import SwiftUI
import LitheGitModule

/// Version Control › Git. Ordered the way people set Git up: the program and
/// credentials, then who commits, then how the repository syncs with its
/// remote, then where local changes go. A card at the top names the
/// repository and chooses whether Git-backed rows write to it or to the
/// global Git configuration.
struct GitSettingsPage: View {
    @EnvironmentObject private var settingsContext: SettingsModelContext
    private var model: AppModel { settingsContext.model }
    @ObservedObject var settings: AppSettings
    @State private var feature: GitFeatureModel?

    var body: some View {
        Group {
            if let feature {
                GitSettingsLoadedPage(
                    feature: feature,
                    execution: feature.executionSettings,
                    identity: feature.identitySettings,
                    settings: settings
                )
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    GitProgramSection(settings: settings, execution: nil) { EmptyView() }
                    GitLocalChangesSection(settings: settings)
                }
            }
        }
        .task(id: model.workspaceURL) {
            let activated = await model.activateGitModule()
            feature = activated
            await activated?.executionSettings.loadExecutable()
        }
    }
}

private struct GitSettingsLoadedPage: View {
    @ObservedObject var feature: GitFeatureModel
    @ObservedObject var execution: GitExecutionSettingsFeatureModel
    @ObservedObject var identity: GitRepositorySetupFeatureModel
    @ObservedObject var settings: AppSettings
    @State private var scope = GitIdentityScope.local
    @State private var remoteURL: String?
    @State private var showsKeys = false

    private var root: URL? { feature.repositorySetupRoot }
    /// Without a repository every Git-backed row writes to the global file.
    private var effectiveScope: GitIdentityScope { root == nil ? .global : scope }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let root {
                GitRepositoryCard(feature: feature, root: root, remoteURL: remoteURL, scope: $scope) {
                    Task { await reload() }
                }
            } else {
                LitheSettingsBanner {
                    Text("No project is open")
                    LitheInfoTip("No project is open. Rows backed by Git configuration write to the global Git configuration; commit identity needs a repository.")
                    Spacer(minLength: 0)
                }
            }

            GitProgramSection(settings: settings, execution: execution) {
                configurationRows(where: { $0.hasPrefix("credential.") })
            }

            LitheSettingsSection(title: "Commit", accessory: {
                LitheInfoTip(effectiveScope == .global
                    ? "Name and email are written to the global Git configuration. Existing commits do not change."
                    : "Name and email are written to this repository's Git configuration and override the global values. Existing commits do not change.")
            }) {
                if root != nil {
                    GitIdentityRow(field: .name, title: "Name", draft: $identity.name,
                                   configured: identity.state?.configuredName,
                                   effective: identity.state?.effectiveName,
                                   isEditable: canEditIdentity, save: saveIdentity)
                    GitIdentityRow(field: .email, title: "Email", draft: $identity.email,
                                   configured: identity.state?.configuredEmail,
                                   effective: identity.state?.effectiveEmail,
                                   isEditable: canEditIdentity, save: saveIdentity)
                    if identity.state?.isRepository == false && effectiveScope == .local {
                        Text("Initialize this project from Git before saving repository-specific identity.")
                            .font(LitheTheme.smallFont)
                            .foregroundStyle(LitheTheme.warning)
                    }
                    if let error = identity.errorMessage {
                        Text(verbatim: error)
                            .font(LitheTheme.smallFont)
                            .foregroundStyle(LitheTheme.error)
                            .textSelection(.enabled)
                    }
                } else {
                    Text("Open a project to configure Git identity.")
                        .foregroundStyle(LitheTheme.secondaryText)
                }
            }

            LitheSettingsSection(title: "Sync with Remote", accessory: {
                LitheInfoTip("Pull and Push settings are written to the selected Git configuration. Fetch settings apply to both manual and background fetches.")
                Spacer(minLength: 0)
                Toggle(isOn: $showsKeys) {
                    Text("Show Git key names")
                        .font(LitheTheme.uiFont(size: 11.5))
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
            }) {
                if execution.snapshot == nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading Git configuration…").foregroundStyle(LitheTheme.secondaryText)
                    }
                } else {
                    LitheSettingsSubheading("Pull")
                    configurationRows(where: { $0.hasPrefix("pull.") })
                    LitheSettingsSubheading("Fetch")
                    configurationRows(where: { $0.hasPrefix("fetch.") || $0.hasPrefix("lithe.fetch.") })
                    LitheSettingsSubheading("Push")
                    configurationRows(where: { $0.hasPrefix("push.") })
                }
                if let error = execution.errorMessage {
                    Text(verbatim: error)
                        .font(LitheTheme.smallFont)
                        .foregroundStyle(LitheTheme.error)
                        .textSelection(.enabled)
                }
            }

            LitheSettingsSection(title: "Lithe Fetch Defaults", accessory: {
                LitheInfoTip("Defaults for ordinary Fetch in every project. A repository's own Git configuration above still wins where it is set.")
                Spacer(minLength: 0)
                Button("Reset") { settings.gitFetchOptions = GitFetchOptions() }
                    .buttonStyle(LitheActionButtonStyle())
                    .disabled(settings.gitFetchOptions == GitFetchOptions())
            }) {
                GitFetchDefaultRows(options: $settings.gitFetchOptions)
            }

            GitLocalChangesSection(settings: settings)
        }
        .disabled(execution.isBusy && execution.snapshot == nil)
        .task(id: "\(root?.path ?? "")|\(effectiveScope.rawValue)|\(settings.gitExecutable)|\(settings.gitUseCredentialHelper)|\(settings.gitFetchOptions)") {
            await reload()
        }
        .task(id: "\(root?.path ?? "")|\(feature.gitReferencesVersion)") {
            await loadRemoteURL()
        }
    }

    private var canEditIdentity: Bool {
        !identity.isBusy && identity.state != nil
            && (effectiveScope == .global || identity.state?.isRepository == true)
    }

    @ViewBuilder
    private func configurationRows(where matches: @escaping (String) -> Bool) -> some View {
        if let snapshot = execution.snapshot {
            ForEach(snapshot.fields.filter { matches($0.key) }) { field in
                GitConfigurationRow(
                    field: field,
                    effective: effectiveDescription(for: field, snapshot: snapshot),
                    showsKey: showsKeys
                ) { value in
                    guard let root else { return }
                    Task { await feature.saveExecutionConfiguration(at: root, field: field, value: value) }
                }
            }
        }
    }

    private func reload() async {
        await execution.load(at: root, scope: effectiveScope.rawValue)
        await identity.load(at: root, scope: effectiveScope)
    }

    private func saveIdentity(_ field: GitIdentityField, clear: Bool) {
        Task {
            await feature.saveGitIdentity(field, clear: clear)
            if identity.errorMessage == nil { await feature.refreshGitHistory() }
        }
    }

    private func loadRemoteURL() async {
        if feature.gitReferences.isEmpty {
            await feature.refreshGitReferencesForSettings()
        }
        guard let root, let remote = feature.currentGitReference?.remoteName else {
            remoteURL = nil
            return
        }
        let request = GitRemoteURLRequest(root: root, remote: remote)
        remoteURL = nil
        let value = await feature.remoteURL(named: remote, at: root)
        guard !Task.isCancelled,
              request.matches(root: feature.repositorySetupRoot, remote: feature.currentGitReference?.remoteName)
        else { return }
        remoteURL = value
    }

    /// The value Git uses now and where it comes from, for the row's pill.
    private func effectiveDescription(
        for field: GitConfigurationField,
        snapshot: GitExecutionSettingsSnapshot
    ) -> (value: String?, source: LocalizedStringKey) {
        let entries = snapshot.entries
        let fetchOptions = snapshot.fetchOptions
        if let entry = entries.last(where: { $0.key == field.key && $0.effective }) {
            if entry.value == "inherit", let override = inheritedOverride(field.key, fetchOptions: fetchOptions, entries: entries) {
                return override
            }
            return (entry.value, LocalizedStringKey(GitConfigurationSource.title(entry.scope)))
        }
        let value = GitConfigurationFallback.value(for: field.key, fetchOptions: fetchOptions, entries: entries)
        return (value, fallbackSource(field.key, fetchOptions: fetchOptions, entries: entries))
    }

    private func inheritedOverride(
        _ key: String,
        fetchOptions: GitFetchOptions?,
        entries: [GitConfigurationEntry]
    ) -> (value: String?, source: LocalizedStringKey)? {
        if key == "lithe.fetch.submodules" {
            let gitEntry = entries.last { $0.key == "fetch.recursesubmodules" && $0.effective }
            return (gitEntry?.value ?? "false",
                    gitEntry.map { LocalizedStringKey(GitConfigurationSource.title($0.scope)) } ?? "Git default")
        }
        if key == "lithe.fetch.tags", let fetchOptions {
            let behavior = GitConfigurationFallback.inheritedTagBehavior(
                remote: fetchOptions.remote, prune: fetchOptions.prune, entries: entries)
            return (behavior.value,
                    behavior.source.map { LocalizedStringKey(GitConfigurationSource.title($0.scope)) } ?? "Git default")
        }
        return nil
    }

    private func fallbackSource(
        _ key: String,
        fetchOptions: GitFetchOptions?,
        entries: [GitConfigurationEntry]
    ) -> LocalizedStringKey {
        if let override = inheritedOverride(key, fetchOptions: fetchOptions, entries: entries),
           fetchOptions?.submodules == .inherit || key == "lithe.fetch.tags" {
            return override.source
        }
        return key.hasPrefix("lithe.") ? "Lithe default" : "Git default"
    }
}

/// The repository this page edits, its branch and remote, and the switch
/// that decides where Git-backed rows are written.
private struct GitRepositoryCard: View {
    @ObservedObject var feature: GitFeatureModel
    let root: URL
    let remoteURL: String?
    @Binding var scope: GitIdentityScope
    let reload: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 1.0, green: 0.48, blue: 0.35), Color(red: 0.94, green: 0.32, blue: 0.20)],
                    startPoint: .top, endPoint: .bottom))
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(verbatim: root.lastPathComponent)
                        .font(LitheTheme.uiFont(size: 13, weight: .semibold))
                    LitheSettingsPill(verbatim: branch, kind: .value)
                    Text(upstream)
                        .font(LitheTheme.uiFont(size: 11.5))
                        .foregroundStyle(LitheTheme.tertiaryText)
                        .lineLimit(1)
                }
                remoteLine
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                LitheSettingsSegmentedControl(
                    selection: $scope,
                    options: GitIdentityScope.allCases,
                    width: 260,
                    title: { $0 == .local ? "Write to this repository" : "Write to global config" }
                )
                .accessibilityLabel("Configuration scope")
                .help(Text("Where the rows below that are backed by Git configuration are written."))
                HStack(spacing: 12) {
                    Button("Reload Configuration", action: reload)
                        .buttonStyle(LitheActionButtonStyle())
                    if let remoteURL, let browserURL = GitRemoteURLPresentation(remoteURL)?.browserURL {
                        Link("Open Remote ↗", destination: browserURL)
                    }
                }
                .font(LitheTheme.uiFont(size: 12))
                .foregroundStyle(LitheTheme.accent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(LitheTheme.settingsCard))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(LitheTheme.settingsCardRing, lineWidth: 0.5)
        )
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private var remoteLine: some View {
        if let remoteURL, let presentation = GitRemoteURLPresentation(remoteURL) {
            Text(verbatim: presentation.displayURL)
                .font(LitheTheme.uiFont(size: 11, design: .monospaced))
                .foregroundStyle(LitheTheme.tertiaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        } else {
            Text(feature.gitReferences.isEmpty && feature.currentBranch != "No Git"
                 ? "Loading branch details…" : "No remote URL")
                .font(LitheTheme.uiFont(size: 11))
                .foregroundStyle(LitheTheme.tertiaryText)
        }
    }

    private var branch: String {
        feature.currentGitReference?.shortName ?? feature.currentBranch
    }

    private var upstream: LocalizedStringKey {
        if let upstream = feature.currentGitReference?.upstreamShortName {
            return "→ \(upstream)"
        }
        return feature.gitReferences.isEmpty && feature.currentBranch != "No Git"
            ? "Loading branch details…"
            : "No upstream configured"
    }
}

/// Which Git runs and how it gets credentials; Git-backed credential rows
/// follow the two Lithe preferences.
private struct GitProgramSection<Extra: View>: View {
    @ObservedObject var settings: AppSettings
    let execution: GitExecutionSettingsFeatureModel?
    @ViewBuilder let extra: Extra
    @State private var executable = ""

    var body: some View {
        LitheSettingsSection(title: "Git Program and Credentials", accessory: {
            LitheInfoTip("Lithe does not save passwords. Credentials are stored by the Git credential helper you choose.")
        }) {
            LitheSettingsRow("Git executable") {
                TextField("Use Git from PATH", text: $executable)
                    .litheSettingsTextField()
                    .frame(minWidth: 180, maxWidth: 320)
                    .onSubmit(save)
                if trimmed != settings.gitExecutable {
                    Button("Save", action: save)
                        .buttonStyle(LitheActionButtonStyle(isPrimary: true))
                }
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        executable = url.path
                        save()
                    }
                }
                .buttonStyle(LitheActionButtonStyle())
            } badges: {
                if let execution {
                    GitExecutableStatus(editor: execution)
                }
                if !settings.gitExecutable.isEmpty {
                    GitResetButton(help: "Use Git from PATH") {
                        executable = ""
                        settings.gitExecutable = ""
                    }
                }
            }
            LitheSettingsRow("Use credential helper", info: "Git can request credentials in Lithe. Passwords are not saved by Lithe; the selected Git helper controls credential storage.") {
                Toggle("", isOn: $settings.gitUseCredentialHelper)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            extra
        }
        .onAppear { executable = settings.gitExecutable }
        .onChange(of: settings.gitExecutable) { executable = $0 }
        .task(id: settings.gitExecutable) {
            await execution?.loadExecutable()
        }
    }

    private var trimmed: String { executable.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func save() {
        settings.gitExecutable = trimmed
    }
}

/// The Git that will actually run, as a status dot and path, so an empty
/// override field still shows whether Lithe found Git.
private struct GitExecutableStatus: View {
    @ObservedObject var editor: GitExecutionSettingsFeatureModel

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            label
                .font(LitheTheme.uiFont(size: 11.5))
                .foregroundStyle(editor.executableResolution?.executable == nil && editor.executableResolution != nil
                                 ? LitheTheme.error : LitheTheme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .frame(maxWidth: 260, alignment: .trailing)
    }

    @ViewBuilder
    private var label: some View {
        if let resolution = editor.executableResolution {
            if let executable = resolution.executable {
                Text(verbatim: [executable, resolution.version.map { $0.replacingOccurrences(of: "git version ", with: "") }]
                    .compactMap { $0 }.joined(separator: " "))
            } else {
                Text("Git not found")
            }
        } else {
            Text("Looking for Git…")
        }
    }

    private var color: Color {
        guard let resolution = editor.executableResolution else { return LitheTheme.tertiaryText }
        return resolution.executable == nil ? LitheTheme.error : LitheTheme.success
    }
}

/// One Git configuration key: choose a value or inherit, and see the value
/// Git uses now. A choice is written at once.
private struct GitConfigurationRow: View {
    let field: GitConfigurationField
    let effective: (value: String?, source: LocalizedStringKey)
    let showsKey: Bool
    let onSave: (String?) -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        let isOverridden = !field.configuredValues.isEmpty
        LitheSettingsRow(title, info: GitConfigurationText.description(field.key), isModified: isOverridden) {
            LitheSettingsSelect(
                selection: Binding(
                    get: { field.configuredValues.first ?? "" },
                    set: { onSave($0.isEmpty ? nil : $0) }
                ),
                options: [""] + field.choices,
                width: selectWidth,
                accessibilityLabel: "Value",
                title: { $0.isEmpty ? "Inherit" : GitConfigurationText.choiceKey(field.key, $0) },
                expandsToFitOptions: true
            )
            if showsKey {
                Text(verbatim: field.key)
                    .font(LitheTheme.uiFont(size: 10.5, design: .monospaced))
                    .foregroundStyle(LitheTheme.tertiaryText)
                    .textSelection(.enabled)
            }
        } badges: {
            effectivePill
            if isOverridden {
                GitResetButton(help: "Clear the override and inherit") { onSave(nil) }
            }
        }
    }

    private var title: LocalizedStringKey { GitConfigurationText.title(field.key) }

    @ViewBuilder
    private var effectivePill: some View {
        if let value = effective.value {
            HStack(spacing: 0) {
                Text("In effect: ")
                Text(LocalizedStringKey(GitConfigurationText.choiceKey(field.key, value)))
                Text(verbatim: " · ")
                Text(effective.source)
            }
            .font(LitheTheme.uiFont(size: 10.5))
            .foregroundStyle(LitheTheme.settingsPillText)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(LitheTheme.settingsPill))
            .fixedSize()
            .help(Text("The value Git uses now and where it comes from"))
        }
    }

    private var selectWidth: CGFloat {
        let font = LitheTheme.uiNSFont(size: LitheDropdownMetrics.fontSize)
        let widest = ([""] + field.choices).reduce(CGFloat.zero) { widest, choice in
            let key = choice.isEmpty ? "Inherit" : GitConfigurationText.choiceKey(field.key, choice)
            let title = String(localized: String.LocalizationValue(key), locale: locale)
            return max(widest, ceil((title as NSString).size(withAttributes: [.font: font]).width))
        }
        return min(max(150, widest + 40), 230)
    }
}

/// Committer name or email, saved to the scope chosen on the repository card.
private struct GitIdentityRow: View {
    let field: GitIdentityField
    let title: LocalizedStringKey
    @Binding var draft: String
    let configured: String?
    let effective: String?
    let isEditable: Bool
    let save: (GitIdentityField, Bool) -> Void

    var body: some View {
        let shown = configured ?? effective ?? ""
        let isDirty = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft != shown
        LitheSettingsRow(title, isModified: configured != nil) {
            TextField(title, text: $draft)
                .litheSettingsTextField()
                .frame(width: 220)
                .onSubmit { if isDirty { save(field, false) } }
            if isDirty {
                Button("Save") { save(field, false) }
                    .buttonStyle(LitheActionButtonStyle(isPrimary: true))
            }
        } badges: {
            if let effective, !effective.isEmpty {
                LitheSettingsPill(verbatim: effective, kind: configured != nil ? .project : .neutral)
                    .help(Text("The value Git uses now"))
            } else {
                LitheSettingsPill("Not set", kind: .effect)
            }
            if configured != nil {
                GitResetButton(help: "Clear the override and inherit") { save(field, true) }
            }
        }
        .disabled(!isEditable)
    }
}

/// Lithe's own defaults for ordinary Fetch.
private struct GitFetchDefaultRows: View {
    @Binding var options: GitFetchOptions

    var body: some View {
        LitheSettingsRow("Prune stale remote-tracking references") {
            Toggle("", isOn: $options.prune).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        LitheSettingsRow("Fetch submodules") {
            LitheSettingsSelect(
                selection: $options.submodules,
                options: GitFetchSubmodules.allCases,
                width: 240,
                accessibilityLabel: "Fetch submodules",
                title: { option in
                    switch option {
                    case .inherit: "Use Git configuration"
                    case .no: "Do not fetch submodules"
                    case .onDemand: "Fetch submodules on demand"
                    case .yes: "Fetch all submodules"
                    }
                }
            )
        }
        LitheSettingsRow("Fetch tags") {
            LitheSettingsSelect(
                selection: $options.tags,
                options: GitFetchTags.allCases,
                width: 240,
                accessibilityLabel: "Fetch tags",
                title: { option in
                    switch option {
                    case .inherit: "Use Git configuration"
                    case .all: "Fetch all tags"
                    case .none: "Do not fetch tags"
                    case .prune: "Synchronize tags and remove local tags missing from the remote"
                    }
                },
                expandsToFitOptions: true
            )
        }
        .onChange(of: options.tags) { tags in if tags == .prune { options.prune = true } }
        .onChange(of: options.prune) { prune in if !prune && options.tags == .prune { options.tags = .inherit } }
    }
}

private struct GitLocalChangesSection: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        LitheSettingsSection(title: "Local Changes", accessory: {
            LitheInfoTip("How uncommitted changes are put aside before switching branches or pulling.")
        }) {
            LitheSettingsRow("Save local changes with", info: LocalizedStringKey(settings.gitSaveChangesPolicy.description)) {
                LitheSettingsSelect(
                    selection: $settings.gitSaveChangesPolicy,
                    options: GitSaveChangesPolicy.allCases,
                    width: 180,
                    accessibilityLabel: "Save local changes with",
                    title: \GitSaveChangesPolicy.title
                )
            }
        }
    }
}

private struct GitResetButton: View {
    let help: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.uturn.backward")
                .font(LitheTheme.uiFont(size: 11, weight: .medium))
                .foregroundStyle(LitheTheme.tertiaryText)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.litheNoPress)
        .help(Text(help))
        .accessibilityLabel(Text(help))
    }
}

enum GitConfigurationSource {
    static func title(_ scope: String) -> String {
        switch scope {
        case "local": "This repository"
        case "global": "Global Git"
        case "system": "System Git"
        case "application": "Lithe default"
        default: scope.capitalized
        }
    }
}

/// User-facing names for the Git configuration keys the page edits.
enum GitConfigurationText {
    static func title(_ key: String) -> LocalizedStringKey {
        switch key {
        case "fetch.prune": "Prune stale remote branches"
        case "fetch.prunetags": "Prune stale tags"
        case "fetch.recursesubmodules": "Fetch submodules"
        case "pull.rebase": "Pull strategy"
        case "pull.ff": "Fast-forward on pull"
        case "push.default": "Default push behavior"
        case "credential.usehttppath": "Use full HTTP path for credentials"
        case "lithe.fetch.prune": "Lithe: prune stale branches"
        case "lithe.fetch.submodules": "Lithe: fetch submodules"
        case "lithe.fetch.tags": "Lithe: fetch tags"
        default: LocalizedStringKey(key)
        }
    }

    static func description(_ key: String) -> LocalizedStringKey {
        switch key {
        case "fetch.prune": "Remove local remote branches that no longer exist on the server."
        case "fetch.prunetags": "Remove local tags that were deleted from the remote."
        case "fetch.recursesubmodules": "Choose whether Fetch also updates submodules."
        case "pull.rebase": "Choose whether Pull merges remote commits or rebases your local commits."
        case "pull.ff": "Choose what Pull does when your branch and the remote branch have diverged."
        case "push.default": "Choose which branch Push targets when you do not name one."
        case "credential.usehttppath": "Include the URL path when Git looks up HTTP credentials."
        case "lithe.fetch.prune": "Controls whether Lithe's ordinary Fetch removes stale remote branches."
        case "lithe.fetch.submodules": "Controls how Lithe's ordinary Fetch updates submodules. Inherit follows Git's fetch.recurseSubmodules setting."
        case "lithe.fetch.tags": "Controls how Lithe's ordinary Fetch synchronizes tags. Inherit leaves tag selection to Git and the remote."
        default: "Choose how this Git setting behaves."
        }
    }

    static func choiceKey(_ key: String, _ choice: String) -> String {
        switch (key, choice) {
        case ("fetch.prune", "true"), ("lithe.fetch.prune", "true"): "Remove stale branches"
        case ("fetch.prune", "false"), ("lithe.fetch.prune", "false"): "Keep stale branches"
        case ("fetch.prunetags", "true"): "Remove stale tags"
        case ("fetch.prunetags", "false"): "Keep stale tags"
        case ("fetch.recursesubmodules", "true"), ("lithe.fetch.submodules", "yes"), ("lithe.fetch.submodules", "true"):
            "Fetch all"
        case ("fetch.recursesubmodules", "on-demand"), ("lithe.fetch.submodules", "onDemand"), ("lithe.fetch.submodules", "on-demand"):
            "Fetch when needed"
        case ("lithe.fetch.submodules", "inherit"): "Follow Git setting"
        case ("lithe.fetch.submodules", "no"), ("lithe.fetch.submodules", "false"): "Do not fetch"
        case ("pull.rebase", "true"): "Rebase"
        case ("pull.ff", "true"): "Allow fast-forward"
        case (_, "true"): "On"
        case ("pull.rebase", "false"): "Merge"
        case ("pull.ff", "false"): "Create merge commit"
        case ("fetch.recursesubmodules", "false"): "Do not fetch"
        case (_, "false"): "Off"
        case ("pull.rebase", "merges"): "Rebase and keep merges"
        case ("pull.ff", "only"): "Fast-forward only"
        case ("lithe.fetch.tags", "inherit"): "Follow Git tag rules"
        case ("lithe.fetch.tags", "reachable"): "Fetch tags that point to fetched commits"
        case ("lithe.fetch.tags", "remoteDependent"): "Follows each remote's tag setting"
        case ("lithe.fetch.tags", "all"): "Fetch all"
        case ("lithe.fetch.tags", "none"): "Do not fetch"
        case ("lithe.fetch.tags", "prune"): "Sync and remove missing tags"
        case ("push.default", "simple"): "Current branch with safety check"
        case ("push.default", "current"): "Current branch"
        case ("push.default", "upstream"): "Upstream branch"
        case ("push.default", "matching"): "Matching branches"
        case ("push.default", "nothing"): "Do not push by default"
        default: choice
        }
    }
}

struct GitRemoteURLRequest: Equatable {
    let root: URL
    let remote: String

    func matches(root currentRoot: URL?, remote currentRemote: String?) -> Bool {
        currentRoot?.standardizedFileURL == root.standardizedFileURL && currentRemote == remote
    }
}

/// A label column and control, used by Git dialogs outside the settings window.
struct GitSettingsRow<Content: View>: View {
    let title: LocalizedStringKey
    let info: LocalizedStringKey?
    @ViewBuilder let content: Content

    init(_ title: LocalizedStringKey, info: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.info = info
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 4) {
                Text(title)
                if let info {
                    LitheInfoTip(info)
                }
            }
            .frame(width: 150, alignment: .leading)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 30)
    }
}
