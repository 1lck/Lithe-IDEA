import SwiftUI
import LitheCoreContracts

struct ProjectRuntimeSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var feature: RuntimeSettingsFeatureModel
    @State private var selectedSubprojectID = ProjectRuntimeInventory.projectDefaultsID

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            if model.workspaceURL == nil {
                emptyWorkspace
            } else {
                HStack(spacing: 0) {
                    subprojectList
                    Rectangle().fill(LitheTheme.divider).frame(width: 1)
                    detail
                }
            }
        }
        .background(LitheTheme.settingsSurface)
        .task {
            await model.prepareProjectRuntimeSettings()
            if feature.subprojects.contains(where: { $0.id == selectedSubprojectID }) == false {
                selectedSubprojectID = ProjectRuntimeInventory.projectDefaultsID
            }
        }
        .onDisappear {
            model.persistProjectRuntimeSettings()
        }
    }

    private var header: some View {
        HStack {
            Text("Project")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)
            Spacer()
            if feature.isDiscovering {
                ProgressView()
                    .controlSize(.small)
                Text("Discovering…")
                    .font(.system(size: 11.5))
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
            .buttonStyle(LitheSecondaryButtonStyle())
            .disabled(feature.isDiscovering)
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
        .background(LitheTheme.settingsSurface)
    }

    private var emptyWorkspace: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Open a project to configure its JDK and Maven runtime.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(LitheTheme.primaryText)
            Text("Application-wide editor and terminal settings remain available in the other categories.")
                .font(LitheTheme.smallFont)
                .foregroundStyle(LitheTheme.secondaryText)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var subprojectList: some View {
        ScrollView {
            VStack(spacing: 1) {
                ForEach(feature.subprojects) { subproject in
                    subprojectRow(subproject)
                }
            }
            .padding(8)
        }
        .frame(width: 230)
        .frame(maxHeight: .infinity)
        .background(LitheTheme.settingsSurface)
        .litheScrollViewChrome(alwaysShowVertical: true, usesCompactScrollers: true)
    }

    private func subprojectRow(_ subproject: ProjectRuntimeSubproject) -> some View {
        let isSelected = selectedSubprojectID == subproject.id
        return Button {
            selectedSubprojectID = subproject.id
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon(for: subproject.kind))
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(subproject.title)
                        .font(.system(size: 12.5, weight: subproject.kind == .projectDefaults ? .semibold : .regular))
                        .lineLimit(1)
                    if subproject.displaysPath {
                        Text(subproject.relativePath)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(isSelected ? Color.white.opacity(0.8) : LitheTheme.tertiaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? LitheTheme.settingsSelection : .clear)
            .clipShape(RoundedRectangle(cornerRadius: LitheTheme.Metrics.cornerRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(LitheTreeRowButtonStyle())
        .foregroundStyle(isSelected ? Color.white : LitheTheme.primaryText)
        .padding(.leading, subproject.parentID == nil ? 0 : 12)
    }

    private var selectedSubproject: ProjectRuntimeSubproject? {
        feature.subprojects.first { $0.id == selectedSubprojectID }
            ?? feature.subprojects.first
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let subproject = selectedSubproject {
                    Text(subproject.title)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(LitheTheme.primaryText)
                        .padding(.bottom, 8)
                    if subproject.kind == .projectDefaults {
                        projectDefaultsDetail
                    } else if subproject.usesJava {
                        javaSubprojectDetail(subproject)
                    } else {
                        otherSubprojectDetail(subproject)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .litheScrollViewChrome(alwaysShowVertical: true, usesCompactScrollers: true)
    }

    private var projectDefaultsDetail: some View {
        VStack(alignment: .leading, spacing: 18) {
            group("Java SDK") {
                row("Project JDK") {
                    runtimePicker(
                        selection: javaHomeBinding,
                        options: javaHomeOptions(current: feature.settings.javaHomePath),
                        accessibilityLabel: "Project JDK",
                        title: { feature.javaRuntimeTitle(for: $0, automaticTitle: "Detected JDK") }
                    )
                }
                pathChooserRow(
                    value: javaHomeBinding,
                    title: "Choose a JDK directory",
                    help: "Choose JDK directory"
                )
                effectiveJDKRow(path: feature.settings.javaHomePath)
                Text("Maven, Run, and Debug use this JDK unless a subproject or run configuration overrides it.")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
            }

            group("Maven") {
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
                        placeholder: "Choose Maven home or bin/mvn",
                        chooseTitle: "Choose Maven home or bin/mvn",
                        fileOrDirectory: true
                    )
                }
                Text("Automatic uses a project mvnw first, then the system Maven on PATH.")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                if let detected = feature.mavenRuntimes.first {
                    labeledValue("Detected Maven", detected.displayName + " — " + detected.homePath)
                }
                row("Maven JDK") {
                    runtimePicker(
                        selection: mavenJavaHomeBinding,
                        options: javaHomeOptions(current: feature.settings.mavenJavaHomePath, includeAutomatic: true),
                        accessibilityLabel: "Maven JDK",
                        title: { feature.javaRuntimeTitle(for: $0, automaticTitle: "Use Project JDK") }
                    )
                }
                pathChooserRow(
                    value: mavenJavaHomeBinding,
                    title: "Choose a JDK directory",
                    help: "Choose Maven JDK"
                )
                pathField(
                    title: "settings.xml",
                    value: mavenSettingsPathBinding,
                    placeholder: "Automatic",
                    chooseTitle: "Choose Maven settings.xml",
                    fileOrDirectory: false
                )
                pathField(
                    title: "Local Repository",
                    value: mavenLocalRepositoryBinding,
                    placeholder: "Automatic",
                    chooseTitle: "Choose Maven Local Repository",
                    fileOrDirectory: true,
                    directoryOnly: true
                )
            }

            Text("Project runtime settings are saved locally for this project.")
                .font(LitheTheme.smallFont)
                .foregroundStyle(LitheTheme.secondaryText)
        }
    }

    private func javaSubprojectDetail(_ subproject: ProjectRuntimeSubproject) -> some View {
        let override = feature.settings.exactOverride(for: subproject.relativePath)
        return VStack(alignment: .leading, spacing: 18) {
            group("Java SDK") {
                row("Project JDK") {
                    runtimePicker(
                        selection: moduleJavaHomeBinding(for: subproject),
                        options: javaHomeOptions(current: override?.javaHomePath ?? "", includeAutomatic: true),
                        accessibilityLabel: "Project JDK",
                        title: { feature.javaRuntimeTitle(for: $0, automaticTitle: "Inherit project JDK") }
                    )
                }
                pathChooserRow(
                    value: moduleJavaHomeBinding(for: subproject),
                    title: "Choose a JDK directory",
                    help: "Choose JDK directory"
                )
                effectiveJDKRow(path: feature.effectiveJavaHome(for: subproject))
                Text("This subproject can use a different JDK from other backends in the same workspace.")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
            }

            group("Maven") {
                pathField(
                    title: "Maven Home",
                    value: moduleMavenHomeBinding(for: subproject),
                    placeholder: "Inherit project Maven",
                    chooseTitle: "Choose Maven home or bin/mvn",
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
            Text("This subproject does not use a JDK.")
                .font(.system(size: 13, weight: .medium))
            Text("Frontend and other non-Java roots keep the workspace editor and terminal settings. Java and Maven SDKs only apply to the backends listed on the left.")
                .font(LitheTheme.smallFont)
                .foregroundStyle(LitheTheme.secondaryText)
            if subproject.displaysPath {
                labeledValue("Path", subproject.relativePath)
            }
        }
    }

    private func effectiveJDKRow(path: String) -> some View {
        let resolved = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let runtime = feature.javaRuntimes.first { $0.homePath == resolved } ?? feature.activeJavaRuntime()
        return labeledValue(
            "Effective JDK",
            runtime.map { "\($0.displayName) — \($0.homePath)" }
                ?? (resolved.isEmpty ? "Detected system JDK" : resolved)
        )
    }

    private func labeledValue(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(LitheTheme.secondaryText)
            Text(value)
                .font(.system(size: 11.5, design: .monospaced))
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
            title: title
        )
    }

    private func pathChooserRow(
        value: Binding<String>,
        title: String,
        help: String
    ) -> some View {
        HStack {
            Spacer()
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
                .font(.system(size: 11.5, weight: .medium))
            HStack(spacing: 6) {
                TextField(LocalizedStringKey(placeholder), text: value)
                    .litheSettingsTextField()
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

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LitheTheme.secondaryText)
            content()
        }
        .font(.system(size: 12.5))
        .foregroundStyle(LitheTheme.primaryText)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(LocalizedStringKey(title))
            Spacer()
            content()
        }
        .frame(minHeight: 28)
    }

    private func icon(for kind: ProjectRuntimeSubprojectKind) -> String {
        switch kind {
        case .projectDefaults: "internaldrive"
        case .mavenReactor: "shippingbox"
        case .mavenModule: "cube"
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
                model.persistProjectRuntimeSettings()
            }
        )
    }

    private var mavenHomeSelectionBinding: Binding<MavenHomeSelection> {
        Binding(
            get: { feature.settings.mavenHomeSelection },
            set: { value in
                feature.updateSettings { $0.mavenHomeSelection = value }
                model.persistProjectRuntimeSettings()
            }
        )
    }

    private var mavenHomePathBinding: Binding<String> {
        Binding(
            get: { feature.settings.mavenHomePath },
            set: { value in
                feature.updateSettings { $0.mavenHomePath = value }
                model.persistProjectRuntimeSettings()
            }
        )
    }

    private var mavenJavaHomeBinding: Binding<String> {
        Binding(
            get: { feature.settings.mavenJavaHomePath },
            set: { value in
                feature.updateSettings { $0.mavenJavaHomePath = value }
                model.persistProjectRuntimeSettings()
            }
        )
    }

    private var mavenSettingsPathBinding: Binding<String> {
        Binding(
            get: { feature.settings.mavenSettingsPath },
            set: { value in
                feature.updateSettings { $0.mavenSettingsPath = value }
                model.persistProjectRuntimeSettings()
            }
        )
    }

    private var mavenLocalRepositoryBinding: Binding<String> {
        Binding(
            get: { feature.settings.mavenLocalRepositoryPath },
            set: { value in
                feature.updateSettings { $0.mavenLocalRepositoryPath = value }
                model.persistProjectRuntimeSettings()
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
                model.persistProjectRuntimeSettings()
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
                model.persistProjectRuntimeSettings()
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
                model.persistProjectRuntimeSettings()
            }
        )
    }
}
