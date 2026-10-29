import Foundation
import LitheModuleAPI
import SwiftUI
import LitheCoreContracts

struct ProjectRuntimeSettingsView: View {
    /// Observes the model: this page shows live run and Maven feature state,
    /// which the settings window's `SettingsModelContext` does not republish.
    @EnvironmentObject private var model: AppModel
    @ObservedObject var feature: RuntimeSettingsFeatureModel
    @State private var selectedSubprojectID = ProjectRuntimeInventory.projectDefaultsID
    /// Editing waits for the canonical toolchain snapshot. Opening is read-only.
    @State private var isPrepared = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if let message = feature.settingsError {
                Text(message).font(LitheTheme.smallFont).foregroundStyle(LitheTheme.error).padding(8)
            }
            if model.workspaceURL == nil {
                emptyWorkspace
            } else {
                HStack(spacing: 0) {
                    subprojectList
                    Rectangle().fill(LitheTheme.divider).frame(width: 1)
                    detail
                }
                .disabled(!isPrepared || feature.isSaving)
            }
        }
        .background(LitheTheme.settingsSurface)
        .task(id: model.currentWorkspaceIdentity) {
            let identity = model.currentWorkspaceIdentity
            isPrepared = false
            await model.prepareProjectRuntimeSettings()
            guard !Task.isCancelled, model.currentWorkspaceIdentity == identity else { return }
            if feature.subprojects.contains(where: { $0.id == selectedSubprojectID }) == false {
                selectedSubprojectID = ProjectRuntimeInventory.projectDefaultsID
            }
            isPrepared = true
        }
    }

    private var header: some View {
        HStack {
            if model.workspaceURL != nil {
                Text("This computer · This project")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            Text(verbatim: ".lithe/run/local.json")
                .font(LitheTheme.smallFont)
                .foregroundStyle(LitheTheme.secondaryText)
            Spacer()
            Button("Cancel") { feature.cancelChanges() }
                .buttonStyle(LitheActionButtonStyle())
                .disabled(!feature.hasChanges || feature.isSaving)
            Button("Save") { Task { await model.persistProjectRuntimeSettings() } }
                .buttonStyle(LitheActionButtonStyle())
                .disabled(!isPrepared || !feature.hasChanges || feature.isSaving)
            if feature.isDiscovering {
                ProgressView()
                    .controlSize(.small)
                Text("Discovering…")
                    .font(LitheTheme.uiFont(size: 11.5))
                    .foregroundStyle(LitheTheme.secondaryText)
            } else if !isPrepared && model.workspaceURL != nil {
                ProgressView()
                    .controlSize(.small)
                Text("Loading project environment…")
                    .font(LitheTheme.uiFont(size: 11.5))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            Button {
                Task {
                    await feature.refreshAvailableRuntimes()
                    await model.prepareProjectRuntimeSettings()
                }
            } label: {
                Label("Refresh detected runtimes", systemImage: "arrow.clockwise")
            }
            .buttonStyle(LitheActionButtonStyle())
            .disabled(feature.isDiscovering || feature.isSaving)
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(LitheTheme.settingsSurface)
    }

    private var emptyWorkspace: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Open a project to configure its JDK and Maven runtime.")
                .font(LitheTheme.uiFont(size: 13, weight: .medium))
                .foregroundStyle(LitheTheme.primaryText)
            Text("Application-wide editor and terminal settings remain available in the other categories.")
                .font(LitheTheme.smallFont)
                .foregroundStyle(LitheTheme.secondaryText)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var subprojectList: some View {
        LitheTreeList(
            feature.subprojects,
            selection: Binding(get: { selectedSubprojectID }, set: { if let id = $0 { selectedSubprojectID = id } }),
            hierarchy: { .init(depth: $0.parentID == nil ? 0 : 1) }, multiline: true
        ) { subproject in
            subprojectRow(subproject)
        }
        .frame(width: 230)
        .frame(maxHeight: .infinity)
        .background(LitheTheme.settingsSurface)
    }

    private func subprojectRow(_ subproject: ProjectRuntimeSubproject) -> some View {
        let isSelected = selectedSubprojectID == subproject.id
        return
            HStack(spacing: 8) {
                Image(systemName: icon(for: subproject.kind))
                    .font(LitheTheme.uiFont(size: 12, weight: .medium))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(subproject.title)
                        .font(
                            LitheTheme.uiFont(
                                size: 12.5, weight: subproject.kind == .projectDefaults ? .semibold : .regular)
                        )
                        .lineLimit(1)
                    if subproject.displaysPath {
                        Text(subproject.relativePath)
                            .font(LitheTheme.uiFont(size: 10.5, design: .monospaced))
                            .foregroundStyle(
                                isSelected ? LitheTheme.settingsSelectionText.opacity(0.8) : LitheTheme.tertiaryText
                            )
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(LitheTheme.primaryText)
    }

    private var selectedSubproject: ProjectRuntimeSubproject? {
        feature.subprojects.first { $0.id == selectedSubprojectID }
            ?? feature.subprojects.first
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let subproject = selectedSubproject {
                    HStack(spacing: 4) {
                        Text(subproject.title)
                            .font(LitheTheme.uiFont(size: 13, weight: .semibold))
                            .foregroundStyle(LitheTheme.primaryText)
                        LitheInfoTip("These defaults apply only to this project on this computer. Run configurations inherit them unless overridden. Use the Project save scope in a run configuration to share settings with your team.")
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                    if subproject.kind == .projectDefaults {
                        projectDefaultsDetail
                    } else if subproject.usesJava {
                        javaSubprojectDetail(subproject)
                    } else {
                        otherSubprojectDetail(subproject)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .litheScrollViewChrome(alwaysShowVertical: true, usesCompactScrollers: true)
    }

    private var projectDefaultsDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            group("Java SDK", info: "Maven, Run, and Debug use this JDK unless a subproject or run configuration overrides it.") {
                row("Project JDK") {
                    HStack(spacing: 6) {
                        runtimePicker(
                            selection: javaHomeBinding,
                            options: javaHomeOptions(current: feature.settings.javaHomePath),
                            accessibilityLabel: "Project JDK",
                            title: { feature.javaRuntimeTitle(for: $0, automaticTitle: "Detected JDK") }
                        )
                        chooseDirectoryButton(
                            value: javaHomeBinding,
                            title: "Choose a JDK directory",
                            help: L10n.string("Choose JDK directory")
                        )
                    }
                }
                EffectiveRuntimeLabel(
                    feature: feature,
                    choice: { feature.javaChoice(overridePath: nil) },
                    kind: .java,
                    mode: feature.settings.javaHomePath.isEmpty ? .automatic : .configured,
                    requirements: requirementMessages(for: "project-jdk")
                )
            }

            group("Maven", info: "Automatic uses a project mvnw first, then detected Maven, then mvnd.") {
                row("Maven source") {
                    LitheSettingsSelect(
                        selection: mavenHomeSelectionBinding,
                        options: MavenHomeSelection.allCases,
                        width: 220,
                        accessibilityLabel: "Maven source",
                        title: \MavenHomeSelection.title
                    )
                }
                if feature.settings.mavenHomeSelection == .custom {
                    pathField(
                        title: "Maven Home",
                        value: mavenHomePathBinding,
                        placeholder: "Choose Maven or mvnd home, bin, or executable",
                        chooseTitle: "Choose Maven or mvnd home, bin, or executable",
                        fileOrDirectory: true
                    )
                }
                if let workspaceURL = model.workspaceURL {
                    EffectiveRuntimeLabel(
                        feature: feature,
                        choice: {
                            feature.mavenChoice(
                                at: workspaceURL,
                                overridePath: feature.settings.mavenExecutableOverride
                            )
                        },
                        kind: .maven,
                        // A custom source without a path still resolves automatically.
                        mode: feature.settings.mavenExecutableOverride.isEmpty ? .automatic : .configured,
                        requirements: requirementMessages(for: "project-maven")
                    )
                }
                row("Maven JDK") {
                    HStack(spacing: 6) {
                        runtimePicker(
                            selection: mavenJavaHomeBinding,
                            options: javaHomeOptions(current: feature.settings.mavenJavaHomePath, includeAutomatic: true),
                            accessibilityLabel: "Maven JDK",
                            title: { feature.javaRuntimeTitle(for: $0, automaticTitle: "Use Project JDK") }
                        )
                        chooseDirectoryButton(
                            value: mavenJavaHomeBinding,
                            title: "Choose a JDK directory",
                            help: L10n.string("Choose Maven JDK")
                        )
                    }
                }
                EffectiveRuntimeLabel(
                    feature: feature,
                    choice: { feature.mavenJavaChoice(overridePath: nil) },
                    kind: .java,
                    mode: feature.settings.mavenJavaHomePath.isEmpty ? .projectJDK : .configured
                )

            }

            Text("Project runtime settings are saved locally for this project.")
                .font(LitheTheme.smallFont)
                .foregroundStyle(LitheTheme.secondaryText)
            if let error = model.runFeatureIfActive?.configurationSaveError {
                Text(error)
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.error)
            }
        }
    }

    private func javaSubprojectDetail(_ subproject: ProjectRuntimeSubproject) -> some View {
        let override = feature.settings.exactOverride(for: subproject.relativePath)
        let effectiveJavaHome = feature.effectiveJavaHome(for: subproject)
        return VStack(alignment: .leading, spacing: 10) {
            group("Java SDK", info: "This subproject can use a different JDK from other backends in the same workspace.") {
                row("Project JDK") {
                    HStack(spacing: 6) {
                        runtimePicker(
                            selection: moduleJavaHomeBinding(for: subproject),
                            options: javaHomeOptions(current: override?.javaHomePath ?? "", includeAutomatic: true),
                            accessibilityLabel: "Project JDK",
                            title: { feature.javaRuntimeTitle(for: $0, automaticTitle: "Inherit project JDK") }
                        )
                        chooseDirectoryButton(
                            value: moduleJavaHomeBinding(for: subproject),
                            title: "Choose a JDK directory",
                            help: L10n.string("Choose JDK directory")
                        )
                    }
                }
                EffectiveRuntimeLabel(
                    feature: feature,
                    choice: { feature.javaChoice(overridePath: effectiveJavaHome.isEmpty ? nil : effectiveJavaHome) },
                    kind: .java,
                    mode: (override?.javaHomePath ?? "").isEmpty ? .inherited : .configured
                )
            }

            group("Maven") {
                pathField(
                    title: "Maven Home",
                    value: moduleMavenHomeBinding(for: subproject),
                    placeholder: "Inherit project Maven",
                    chooseTitle: "Choose Maven or mvnd home, bin, or executable",
                    fileOrDirectory: true
                )
                row("Maven JDK") {
                    runtimePicker(
                        selection: moduleMavenJavaHomeBinding(for: subproject),
                        options: javaHomeOptions(
                            current: override?.mavenJavaHomePath ?? "",
                            includeAutomatic: true
                        ),
                        accessibilityLabel: "Maven JDK",
                        title: { feature.javaRuntimeTitle(for: $0, automaticTitle: "Inherit project Maven JDK") }
                    )
                }
            }
        }
    }

    private func otherSubprojectDetail(_ subproject: ProjectRuntimeSubproject) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                Text("This subproject does not use a JDK.")
                    .font(LitheTheme.uiFont(size: 13, weight: .medium))
                LitheInfoTip("Frontend and other non-Java roots keep the workspace editor and terminal settings. Java and Maven SDKs only apply to the backends listed on the left.")
            }
            if subproject.displaysPath {
                labeledValue("Path", subproject.relativePath)
            }
        }
    }

    private func requirementMessages(for toolchain: String) -> [String] {
        model.runFeatureIfActive?.configurationDiagnostics.toolchainRequirementMessages(for: toolchain) ?? []
    }

    private func labeledValue(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(title))
                .font(LitheTheme.uiFont(size: 11.5, weight: .medium))
                .foregroundStyle(LitheTheme.secondaryText)
            Text(value)
                .font(LitheTheme.uiFont(size: 11.5, design: .monospaced))
                .foregroundStyle(LitheTheme.primaryText)
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }

    private func runtimePicker(
        selection: Binding<String>,
        options: [String],
        accessibilityLabel: String,
        title: @escaping (String) -> String
    ) -> some View {
        LitheSettingsSelect(
            selection: selection,
            options: options,
            width: 280,
            accessibilityLabel: accessibilityLabel,
            title: title,
            expandsToFitOptions: true
        )
    }

    private func chooseDirectoryButton(
        value: Binding<String>,
        title: String,
        help: String
    ) -> some View {
        Button {
            if let url = model.platformUI.chooseDirectory(title: title, prompt: "Choose") {
                value.wrappedValue = url.standardizedFileURL.path
            }
        } label: {
            Image(systemName: "folder")
        }
        .litheIconButton()
        .help(help)
    }

    private func pathField(
        title: String,
        value: Binding<String>,
        placeholder: String,
        chooseTitle: String,
        fileOrDirectory: Bool,
        directoryOnly: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(LocalizedStringKey(title))
                .font(LitheTheme.uiFont(size: 11.5, weight: .medium))
            HStack(spacing: 6) {
                LitheTextField(LocalizedStringKey(placeholder), text: value)
                    .help(Text(verbatim: placeholder))
                Button {
                    value.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark")
                }
                .litheIconButton()
                .help("Use automatic value")
                Button {
                    let url: URL?
                    if directoryOnly {
                        url = model.platformUI.chooseDirectory(title: chooseTitle, prompt: "Choose")
                    } else if fileOrDirectory {
                        url = model.platformUI.chooseDirectory(title: chooseTitle, prompt: "Choose")
                            ?? model.platformUI.chooseFile(title: chooseTitle, prompt: "Choose")
                    } else {
                        url = model.platformUI.chooseFile(title: chooseTitle, prompt: "Choose")
                    }
                    if let url {
                        value.wrappedValue = url.standardizedFileURL.path
                    }
                } label: {
                    Image(systemName: "folder")
                }
                .litheIconButton()
                .help("Choose path")
            }
        }
    }

    private func group<Content: View>(
        _ title: String,
        info: LocalizedStringKey? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Text(LocalizedStringKey(title))
                        .font(LitheTheme.uiFont(size: 12, weight: .medium))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .fixedSize()
                    if let info {
                        LitheInfoTip(info)
                    }
                }
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
            }
            content()
        }
        .font(LitheTheme.uiFont(size: 12.5))
        .foregroundStyle(LitheTheme.primaryText)
        .padding(.top, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            LitheSettingsLabel(LocalizedStringKey(title))
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 16)
            content()
        }
        .frame(minHeight: 28)
    }

    private func icon(for kind: ProjectRuntimeSubprojectKind) -> String {
        switch kind {
        case .projectDefaults: "internaldrive"
        case .buildRoot: "shippingbox"
        case .buildProject: "cube"
        case .other: "globe"
        }
    }

    private func javaHomeOptions(current: String, includeAutomatic: Bool = true) -> [String] {
        var options: [String] = includeAutomatic ? [""] : []
        options.append(contentsOf: feature.javaRuntimes.map(\.homePath))
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !options.contains(trimmed) {
            options.append(trimmed)
        }
        return options
    }

    private var javaHomeBinding: Binding<String> {
        Binding(
            get: { feature.settings.javaHomePath },
            set: { value in
                feature.updateSettings { $0.javaHomePath = value }
            }
        )
    }

    private var mavenHomeSelectionBinding: Binding<MavenHomeSelection> {
        Binding(
            get: { feature.settings.mavenHomeSelection },
            set: { value in
                feature.updateSettings { $0.mavenHomeSelection = value }
            }
        )
    }

    private var mavenHomePathBinding: Binding<String> {
        Binding(
            get: { feature.settings.mavenHomePath },
            set: { value in
                feature.updateSettings { $0.mavenHomePath = value }
            }
        )
    }

    private var mavenJavaHomeBinding: Binding<String> {
        Binding(
            get: { feature.settings.mavenJavaHomePath },
            set: { value in
                feature.updateSettings { $0.mavenJavaHomePath = value }
            }
        )
    }

    private func moduleJavaHomeBinding(for subproject: ProjectRuntimeSubproject) -> Binding<String> {
        Binding(
            get: { feature.settings.exactOverride(for: subproject.relativePath)?.javaHomePath ?? "" },
            set: { value in
                feature.updateSettings {
                    $0.setOverride(path: subproject.relativePath, javaHomePath: value)
                }
            }
        )
    }

    private func moduleMavenHomeBinding(for subproject: ProjectRuntimeSubproject) -> Binding<String> {
        Binding(
            get: { feature.settings.exactOverride(for: subproject.relativePath)?.mavenExecutablePath ?? "" },
            set: { value in
                feature.updateSettings {
                    $0.setOverride(path: subproject.relativePath, mavenExecutablePath: value)
                }
            }
        )
    }

    private func moduleMavenJavaHomeBinding(for subproject: ProjectRuntimeSubproject) -> Binding<String> {
        Binding(
            get: { feature.settings.exactOverride(for: subproject.relativePath)?.mavenJavaHomePath ?? "" },
            set: { value in
                feature.updateSettings {
                    $0.setOverride(path: subproject.relativePath, mavenJavaHomePath: value)
                }
            }
        )
    }
}
