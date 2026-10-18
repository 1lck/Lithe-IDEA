import Foundation
import SwiftUI
import LitheCoreContracts

struct ProjectRuntimeSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var feature: RuntimeSettingsFeatureModel
    @State private var subprojectListActive = false
    @State private var selectedSubprojectID = ProjectRuntimeInventory.projectDefaultsID
    /// Editing waits until the form is seeded from this project's saved defaults.
    /// An earlier edit could not reach `.lithe/run/local.json`, and adopting the
    /// saved defaults afterwards would silently revert it.
    @State private var isPrepared = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.workspaceURL == nil {
                emptyWorkspace
            } else {
                HStack(spacing: 0) {
                    subprojectList
                        .background(LitheToolWindowActivityTracker(isActive: $subprojectListActive))
                    Rectangle().fill(LitheTheme.divider).frame(width: 1)
                    detail
                }
                .disabled(!isPrepared)
            }
        }
        .background(LitheTheme.settingsSurface)
        .task {
            await model.prepareProjectRuntimeSettings()
            if feature.subprojects.contains(where: { $0.id == selectedSubprojectID }) == false {
                selectedSubprojectID = ProjectRuntimeInventory.projectDefaultsID
            }
            isPrepared = true
        }
        .onDisappear {
            // Before preparation the form holds unmerged values; persisting them
            // would overwrite the saved project and Maven settings.
            guard isPrepared else { return }
            model.persistProjectRuntimeSettings()
        }
    }

    private var header: some View {
        HStack {
            Spacer()
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
            .buttonStyle(LitheSecondaryButtonStyle())
            .disabled(feature.isDiscovering)
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
                    .font(LitheTheme.uiFont(size: 12, weight: .medium))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(subproject.title)
                        .font(LitheTheme.uiFont(size: 12.5, weight: subproject.kind == .projectDefaults ? .semibold : .regular))
                        .lineLimit(1)
                    if subproject.displaysPath {
                        Text(subproject.relativePath)
                            .font(LitheTheme.uiFont(size: 10.5, design: .monospaced))
                            .foregroundStyle(isSelected ? LitheTheme.settingsSelectionText.opacity(0.8) : LitheTheme.tertiaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .litheSelectionRow(isSelected: isSelected, isFocused: subprojectListActive, cornerRadius: LitheTheme.Metrics.cornerRadius)
            .clipShape(RoundedRectangle(cornerRadius: LitheTheme.Metrics.cornerRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.litheNoPress)
        .foregroundStyle(isSelected ? LitheTheme.settingsSelectionText : LitheTheme.primaryText)
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
                        .font(LitheTheme.uiFont(size: 13, weight: .semibold))
                        .foregroundStyle(LitheTheme.primaryText)
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
                            help: "Choose JDK directory"
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
                            help: "Choose Maven JDK"
                        )
                    }
                }
                EffectiveRuntimeLabel(
                    feature: feature,
                    choice: { feature.mavenJavaChoice(overridePath: nil) },
                    kind: .java,
                    mode: feature.settings.mavenJavaHomePath.isEmpty ? .projectJDK : .configured
                )
                pathField(
                    title: "settings.xml",
                    value: mavenSettingsPathBinding,
                    placeholder: effectiveMavenSettingsPath ?? String(localized: "Not found"),
                    chooseTitle: "Choose Maven settings.xml",
                    fileOrDirectory: false
                )
                pathField(
                    title: "Local Repository",
                    value: mavenLocalRepositoryBinding,
                    placeholder: effectiveMavenLocalRepositoryPath ?? String(localized: "Not found"),
                    chooseTitle: "Choose Maven Local Repository",
                    fileOrDirectory: true,
                    directoryOnly: true
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
                            help: "Choose JDK directory"
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
            Text("This subproject does not use a JDK.")
                .font(LitheTheme.uiFont(size: 13, weight: .medium))
            Text("Frontend and other non-Java roots keep the workspace editor and terminal settings. Java and Maven SDKs only apply to the backends listed on the left.")
                .font(LitheTheme.smallFont)
                .foregroundStyle(LitheTheme.secondaryText)
            if subproject.displaysPath {
                labeledValue("Path", subproject.relativePath)
            }
        }
    }

    private func requirementMessages(for toolchain: String) -> [String] {
        model.runFeatureIfActive?.configurationDiagnostics.toolchainRequirementMessages(for: toolchain) ?? []
    }

    /// The configured override, otherwise the file Maven would read by default
    /// or the installation's `conf/settings.xml`. Showing the resolved path is
    /// more useful than “Automatic”; when nothing exists, the field says so.
    private var effectiveMavenSettingsPath: String? {
        if let path = model.mavenFeatureIfActive?.settingsPath, !path.isEmpty { return path }
        let configured = feature.settings.mavenSettingsPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty { return configured }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let userSettings = home.appendingPathComponent(".m2/settings.xml")
        if FileManager.default.fileExists(atPath: userSettings.path) { return userSettings.path }
        guard let workspaceURL = model.workspaceURL,
              let executable = feature.mavenChoice(
                  at: workspaceURL,
                  overridePath: feature.settings.mavenExecutableOverride
              ).url else { return nil }
        // A selected launcher may be a symlink outside the installation.
        let installationSettings = executable.resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("conf/settings.xml")
        return FileManager.default.fileExists(atPath: installationSettings.path)
            ? installationSettings.path
            : nil
    }

    /// The same precedence Maven applies: the explicit Lithe override, then
    /// `<localRepository>` in the user settings, then the installation's
    /// `conf/settings.xml`, and finally the default repository.
    private var effectiveMavenLocalRepositoryPath: String? {
        if let path = model.mavenFeatureIfActive?.localRepositoryPath, !path.isEmpty { return path }
        let configured = feature.settings.mavenLocalRepositoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty { return configured }
        for settings in mavenSettingsCandidates {
            switch Self.localRepository(inSettingsAt: settings) {
            case .resolved(let repository):
                return repository
            case .unresolved:
                // A configured value that cannot be interpolated must not fall
                // back to a guessed default; leave the field unknown instead.
                return nil
            case .absent:
                continue
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".m2/repository").path
    }

    /// User settings first; the installation's global settings are merged
    /// below them and can define `<localRepository>` when the user file does
    /// not.
    private var mavenSettingsCandidates: [String] {
        var paths: [String] = []
        if let path = model.mavenFeatureIfActive?.settingsPath, !path.isEmpty {
            paths.append(path)
        } else {
            let configured = feature.settings.mavenSettingsPath.trimmingCharacters(in: .whitespacesAndNewlines)
            let userSettings = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".m2/settings.xml")
            if !configured.isEmpty {
                paths.append(configured)
            } else if FileManager.default.fileExists(atPath: userSettings.path) {
                paths.append(userSettings.path)
            }
        }
        if let workspaceURL = model.workspaceURL,
           let executable = feature.mavenChoice(
               at: workspaceURL,
               overridePath: feature.settings.mavenExecutableOverride
           ).url {
            let installationSettings = executable.resolvingSymlinksInPath()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("conf/settings.xml")
            if FileManager.default.fileExists(atPath: installationSettings.path),
               !paths.contains(installationSettings.path) {
                paths.append(installationSettings.path)
            }
        }
        return paths
    }

    /// Distinguishes a missing element from one that is configured but cannot
    /// be interpolated, so the caller never reports the default as the value.
    private static func localRepository(
        inSettingsAt path: String
    ) -> MavenLocalRepositoryValue {
        guard let data = FileManager.default.contents(atPath: path) else { return .absent }
        let parser = XMLParser(data: data)
        let reader = MavenLocalRepositoryReader()
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), reader.found else { return .absent }
        guard let raw = reader.value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return .absent }
        guard let resolved = resolveMavenPath(raw) else { return .unresolved }
        return .resolved(resolved)
    }

    /// Maven interpolates `${user.home}` and `${env.NAME}` plus a leading `~`.
    /// Any other expression or a relative result cannot be reported as the
    /// actual repository.
    private static func resolveMavenPath(_ raw: String) -> String? {
        var value = raw.replacingOccurrences(of: "${user.home}", with: NSHomeDirectory())
        // Bound the expansion so a self-referential environment value cannot
        // keep the loop running.
        for _ in 0..<16 {
            guard let start = value.range(of: "${env.") else { break }
            guard let end = value[start.upperBound...].firstIndex(of: "}") else { return nil }
            let name = String(value[start.upperBound..<end])
            guard let environment = ProcessInfo.processInfo.environment[name],
                  !environment.isEmpty else { return nil }
            value.replaceSubrange(start.lowerBound...end, with: environment)
        }
        if value.hasPrefix("~") {
            value = NSHomeDirectory() + String(value.dropFirst())
        }
        guard !value.contains("${") else { return nil }
        return value.hasPrefix("/") ? value : nil
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
                TextField(LocalizedStringKey(placeholder), text: value)
                    .litheSettingsTextField()
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

private enum MavenLocalRepositoryValue {
    case absent
    case resolved(String)
    case unresolved
}

/// Reads only `<localRepository>` from a Maven settings file.
private final class MavenLocalRepositoryReader: NSObject, XMLParserDelegate {
    var value: String?
    var found = false
    private var isReading = false
    private var text = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "localRepository" {
            found = true
            isReading = true
            text = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isReading { text += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "localRepository", isReading {
            value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            isReading = false
        }
    }
}
