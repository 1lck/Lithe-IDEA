import AppKit
import LitheCoreContracts
import LitheModuleAPI
import SwiftUI

// Note: 新建项目向导与项目生成器见 .agents/notes/implemented/feature/2026-10-23-plugin-project-generators.md

/// Owns the window's state for as long as the sheet is shown, so a
/// re-render of the presenting view does not start over.
struct NewProjectSheet: View {
    @StateObject private var feature: NewProjectFeatureModel

    init(feature: @autoclosure @escaping () -> NewProjectFeatureModel) {
        _feature = StateObject(wrappedValue: feature())
    }

    var body: some View {
        NewProjectView(feature: feature)
    }
}

/// The New Project window, laid out like IntelliJ IDEA's: entries on the
/// left, the selected entry's form on the right. The host draws the window,
/// the name, location, and Git fields, and the empty project; every other
/// entry and its fields come from plugin declarations.
struct NewProjectView: View {
    @ObservedObject var feature: NewProjectFeatureModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isSearchFocused: Bool
    @State private var listActive = true

    private static let sidebarWidth: CGFloat = 240
    private static let labelWidth: CGFloat = 120

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                    .frame(width: Self.sidebarWidth)
                Rectangle().fill(LitheTheme.divider).frame(width: 1)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            footer
        }
        .frame(width: 880, height: 660)
        .background(LitheTheme.window)
        .task { await feature.load() }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            LitheSettingsSearchField("Search", text: $feature.searchText, focus: $isSearchFocused)
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 4)
            ScrollView {
                VStack(spacing: 0) {
                    LitheSidebarHeading("New Project")
                    ForEach(feature.entries(in: .project)) { entry in
                        entryRow(entry)
                    }
                    if feature.showsEmptyProject {
                        LitheSidebarRow(
                            Text(LocalizedStringKey("Empty Project")),
                            style: .item,
                            isSelected: feature.selection == .empty,
                            isFocused: listActive
                        ) {
                            feature.selection = .empty
                        } leading: {
                            LitheIDEAIcon(resourcePath: "expui/nodes/folder.svg", size: 16, fallbackSystemImage: "folder")
                        }
                    }
                    let generators = feature.entries(in: .generator)
                    if !generators.isEmpty {
                        LitheSidebarHeading("Generators")
                        ForEach(generators) { entry in
                            entryRow(entry)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 10)
            }
            .litheScrollViewChrome(alwaysShowVertical: false, usesCompactScrollers: true)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            Button {
                feature.openMarketplace(searching: "")
            } label: {
                Text(LocalizedStringKey("Get more languages and frameworks from plugins…"))
                    .font(LitheTheme.uiFont(size: 12))
                    .foregroundStyle(LitheTheme.link)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.litheNoPress)
            .lithePointer()
            .padding(.horizontal, 14)
            .frame(height: 40)
        }
        .background(LitheTheme.settingsSidebar)
    }

    private func entryRow(_ entry: ProjectGeneratorEntry) -> some View {
        LitheSidebarRow(
            Text(LocalizedStringKey(entry.generator.displayName)),
            style: .item,
            isSelected: feature.selection == .generator(entry.id),
            isFocused: listActive
        ) {
            feature.selection = .generator(entry.id)
        } leading: {
            WorkbenchContributionIcon(
                asset: .init(entry.generator.icon, resources: feature.icon(for: entry)),
                role: .listItem
            )
            .opacity(entry.pluginEnabled ? 1 : 0.5)
        }
        .help(entry.pluginEnabled ? Text(verbatim: entry.pluginName) : Text(LocalizedStringKey("Provided by a disabled plugin")))
    }

    // MARK: Detail

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let error = feature.catalogError {
                    notice(error, systemImage: "exclamationmark.triangle.fill", color: LitheTheme.warning)
                }
                Text(LocalizedStringKey(feature.selectedEntry?.generator.description ?? "A basic project with a free structure."))
                    .font(LitheTheme.uiFont(size: 12.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                projectFields
                pluginNotices

                if let entry = feature.selectedEntry {
                    generatorFields(entry)
                }
                if let error = feature.formError {
                    notice(error, systemImage: "exclamationmark.triangle.fill", color: LitheTheme.error)
                }
                progress
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .litheScrollViewChrome(alwaysShowVertical: false, usesCompactScrollers: true)
        .disabled(feature.isCreating)
    }

    private var projectFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Name") {
                TextField("", text: $feature.projectName)
                    .litheSettingsTextField()
                    .frame(maxWidth: 360)
                    .accessibilityLabel(Text(LocalizedStringKey("Name")))
            } footer: {
                problemText(feature.nameProblem)
            }
            row("Location") {
                HStack(spacing: 6) {
                    TextField("", text: $feature.location)
                        .litheSettingsTextField()
                        .accessibilityLabel(Text(LocalizedStringKey("Location")))
                    Button {
                        if let path = LitheDirectoryPicker.choose(startingAt: feature.location) {
                            feature.location = path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                        }
                    } label: {
                        Image(systemName: "folder")
                    }
                    .litheIconButton()
                    .help(Text(LocalizedStringKey("Choose…")))
                }
            } footer: {
                Text(String(format: String(localized: "Project will be created in: %@"), feature.destinationPath))
                    .font(LitheTheme.uiFont(size: 11.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(2)
            }
            row(nil) {
                LitheSettingsCheckbox(isOn: $feature.createGitRepository, title: "Create Git repository")
            }
        }
    }

    @ViewBuilder private var pluginNotices: some View {
        if let entry = feature.selectedEntry, !entry.pluginEnabled {
            pluginNotice(
                Text(String(format: String(localized: "This template comes from %@, which is disabled."), entry.pluginName)),
                actionTitle: "Enable",
                pluginID: PluginID(entry.pluginID)
            )
        }
        ForEach(feature.requirementNotices) { notice in
            switch notice.action {
            case .enable(let pluginID, let name):
                pluginNotice(
                    Text(String(format: String(localized: "%@ is needed for this project but %@ is disabled."),
                                Self.subjectName(notice.subject), name)),
                    actionTitle: "Enable",
                    pluginID: pluginID
                )
            case .findInMarketplace(let query):
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(LitheTheme.secondaryText)
                    Text(String(format: String(localized: "No installed plugin supports %@ yet."),
                                Self.subjectName(notice.subject)))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(LocalizedStringKey("Find in Marketplace")) { feature.openMarketplace(searching: query) }
                        .buttonStyle(LitheActionButtonStyle())
                        .fixedSize()
                }
                .modifier(NoticeChrome())
            }
        }
    }

    private func pluginNotice(_ text: Text, actionTitle: LocalizedStringKey, pluginID: PluginID) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(LitheTheme.warning)
            text.fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                Task { await feature.enablePlugin(pluginID) }
            } label: {
                HStack(spacing: 6) {
                    if feature.enablingPluginID == pluginID { ProgressView().controlSize(.small) }
                    Text(actionTitle)
                }
            }
            .buttonStyle(LitheActionButtonStyle(isPrimary: true))
            .disabled(feature.enablingPluginID != nil)
            .fixedSize()
        }
        .modifier(NoticeChrome())
    }

    @ViewBuilder private func generatorFields(_ entry: ProjectGeneratorEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(feature.visibleFields(advanced: false)) { field in
                fieldRow(field)
            }
        }
        let advanced = feature.visibleFields(advanced: true)
        if !advanced.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    feature.showsAdvancedFields.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(LitheTheme.uiFont(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(feature.showsAdvancedFields ? 90 : 0))
                        Text(LocalizedStringKey("Advanced Settings"))
                            .font(LitheTheme.uiFont(size: 12.5, weight: .medium))
                        Rectangle().fill(LitheTheme.divider).frame(height: 1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.litheNoPress)
                .foregroundStyle(LitheTheme.primaryText)
                if feature.showsAdvancedFields {
                    ForEach(advanced) { field in
                        fieldRow(field)
                    }
                }
            }
            .padding(.top, 6)
        }
        if entry.usesNetwork {
            Label(LocalizedStringKey("Creating this project downloads files from the internet."), systemImage: "network")
                .font(LitheTheme.uiFont(size: 11.5))
                .foregroundStyle(LitheTheme.secondaryText)
        }
    }

    @ViewBuilder private func fieldRow(_ field: ProjectGeneratorField) -> some View {
        if field.kind == .boolean {
            row(nil) {
                LitheSettingsCheckbox(
                    isOn: Binding(
                        get: { feature.value(of: field) == .bool(true) },
                        set: { feature.setValue(.bool($0), for: field) }
                    ),
                    title: LocalizedStringKey(field.title)
                )
                if let description = field.description { LitheInfoTip(LocalizedStringKey(description)) }
            }
        } else {
            row(field.title, info: field.description) {
                control(for: field)
            } footer: {
                problemText(feature.problem(of: field))
            }
        }
    }

    @ViewBuilder private func control(for field: ProjectGeneratorField) -> some View {
        switch field.kind {
        case .text:
            PluginTextSettingField(
                value: feature.value(of: field).stringValue,
                placeholder: field.placeholder.map { String(localized: String.LocalizationValue($0)) },
                width: 360,
                isFlexible: true,
                accessibilityLabel: field.title,
                savesWhileTyping: true,
                accepts: { _ in true },
                onChange: { feature.setValue(.string($0), for: field) }
            )
        case .enum:
            let selection = Binding(
                get: { feature.value(of: field).stringValue },
                set: { feature.setValue(.string($0), for: field) }
            )
            let title = { (value: String) in field.options.first { $0.value == value }?.title ?? value }
            if field.presentation == .segmented {
                LitheSettingsSegmentedControl(
                    selection: selection,
                    options: field.options.map(\.value),
                    width: CGFloat(field.options.count) * 124,
                    title: title
                )
            } else {
                LitheSettingsSelect(
                    selection: selection,
                    options: field.options.map(\.value),
                    width: 240,
                    accessibilityLabel: field.title,
                    title: title
                )
            }
        case .multiSelect:
            PluginMultiSelectField(
                options: field.options.map { PluginFieldOption(value: $0.value, title: $0.title, group: $0.group) },
                width: 360,
                selected: feature.value(of: field).stringArray,
                accessibilityLabel: field.title
            ) { feature.setValue(.array($0.map(ToolingJSONValue.string)), for: field) }
        case .runtime:
            runtimeControl(field)
        case .boolean:
            EmptyView()
        }
    }

    @ViewBuilder private func runtimeControl(_ field: ProjectGeneratorField) -> some View {
        if feature.javaRuntimes.isEmpty {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(LocalizedStringKey("Looking for installed JDKs…"))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
        } else {
            LitheSettingsSelect(
                selection: Binding(
                    get: { feature.selectedRuntimeHome(for: field) },
                    set: { feature.selectRuntime(home: $0, for: field) }
                ),
                options: feature.javaRuntimes.map(\.homePath),
                width: 420,
                accessibilityLabel: field.title,
                title: { home in
                    guard let runtime = feature.javaRuntimes.first(where: { $0.homePath == home }) else { return home }
                    return "\(runtime.displayName) — \(home.replacingOccurrences(of: NSHomeDirectory(), with: "~"))"
                },
                localizesTitles: false,
                searchPrompt: feature.javaRuntimes.count > 8 ? "Search JDKs" : nil
            )
        }
    }

    @ViewBuilder private var progress: some View {
        if let error = feature.errorMessage {
            notice(error, systemImage: "exclamationmark.triangle.fill", color: LitheTheme.error)
                .textSelection(.enabled)
        }
        if feature.isCreating, !feature.progressOutput.isEmpty {
            ScrollView {
                Text(verbatim: String(feature.progressOutput.suffix(4_000)))
                    .font(LitheTheme.uiFont(size: 11, design: .monospaced))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 120)
            .modifier(NoticeChrome())
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: LitheTheme.ActionButton.spacing) {
            if feature.isCreating {
                ProgressView().controlSize(.small)
                Text(LocalizedStringKey("Creating project…"))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            Spacer()
            Button(LocalizedStringKey("Cancel")) {
                if feature.isCreating { feature.cancelCreation() } else { dismiss() }
            }
            .buttonStyle(LitheActionButtonStyle())
            .keyboardShortcut(.cancelAction)
            Button(LocalizedStringKey("Create")) {
                feature.create { dismiss() }
            }
            .buttonStyle(LitheActionButtonStyle(isPrimary: true))
            .keyboardShortcut(.defaultAction)
            .disabled(!feature.canCreate)
        }
        .padding(14)
        .background(LitheTheme.toolHeader)
    }

    // MARK: Building blocks

    private func row<Control: View, Footer: View>(
        _ title: String?,
        info: String? = nil,
        @ViewBuilder control: () -> Control,
        @ViewBuilder footer: () -> Footer
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            HStack(spacing: 4) {
                if let title {
                    Text(LocalizedStringKey(title))
                        .foregroundStyle(LitheTheme.primaryText)
                }
                if let info { LitheInfoTip(LocalizedStringKey(info)) }
            }
            .frame(width: Self.labelWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) { control() }
                footer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(LitheTheme.settingsFont)
    }

    private func row<Control: View>(
        _ title: String?,
        info: String? = nil,
        @ViewBuilder control: () -> Control
    ) -> some View {
        row(title, info: info, control: control, footer: { EmptyView() })
    }

    @ViewBuilder private func problemText(_ problem: ProjectFieldProblem?) -> some View {
        if let problem {
            Text(ProjectGenerationService.message(for: problem))
                .font(LitheTheme.uiFont(size: 11.5))
                .foregroundStyle(LitheTheme.error)
        }
    }

    private func notice(_ text: String, systemImage: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(color)
            Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .modifier(NoticeChrome())
    }

    private static func subjectName(_ subject: ProjectGeneratorRequirement.Subject) -> String {
        switch subject {
        case .language(let id), .buildSystem(let id):
            id.prefix(1).uppercased() + id.dropFirst()
        }
    }
}

private struct NoticeChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(LitheTheme.uiFont(size: 12))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LitheTheme.settingsCard)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6).stroke(LitheTheme.divider, lineWidth: 1)
            }
    }
}

private extension ToolingJSONValue {
    var stringValue: String {
        if case .string(let value) = self { value } else { "" }
    }

    var stringArray: [String] {
        guard case .array(let values) = self else { return [] }
        return values.compactMap { if case .string(let value) = $0 { value } else { nil } }
    }
}
