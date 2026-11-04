import SwiftUI
import LitheModuleAPI

struct EditorSettingsImportControl: View {
    @ObservedObject var feature: EditorSettingsImportFeatureModel
    var iconOnly = false
    @State private var isPresented = false

    @ViewBuilder private var trigger: some View {
        if iconOnly {
            Button { isPresented = true } label: {
                LitheIDEAIcon(resourcePath: "expui/general/download.svg", size: 16)
            }
            .litheToolbarIconButton()
            .help("Import IDE settings")
            .accessibilityLabel("Import IDE settings")
        } else {
            Button("Import IDE settings") { isPresented = true }
                .buttonStyle(LitheActionButtonStyle())
        }
    }

    var body: some View {
        trigger
            .background(LitheCenteredPopup(isPresented: $isPresented,
                allowsDismiss: !feature.isBusy, dialogTitle: L10n.string("Import IDE settings")) {
                EditorSettingsImportView(feature: feature) { isPresented = false }
            }.frame(width: 0, height: 0).allowsHitTesting(false))

    }
}

/// The main scene waits here: no welcome/project content is mounted under the import page.
struct EditorSettingsImportStartup<Content: View>: View {
    @ObservedObject var feature: EditorSettingsImportFeatureModel
    var windowHandler: (any ProjectWindowSessionHandling)? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        Group {
            if feature.startupFinished {
                content()
            } else {
                EditorSettingsImportView(feature: feature, startup: true, onDismiss: feature.finishStartup)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(LitheCommitDialogStyle.background)
                    .background {
                        if let windowHandler {
                            WindowCloseGuard(windowHandler: windowHandler, layout: .settingsImport,
                                title: L10n.string("Import IDE settings"))
                        }
                    }
            }
        }
        .task { await feature.prepareStartup() }
    }
}

struct EditorSettingsImportView: View {
    @ObservedObject var feature: EditorSettingsImportFeatureModel
    @State private var operation: Task<Void, Never>?
    var startup = false
    let onDismiss: () -> Void
    private var language: AppLanguage { feature.settings.language }

    private func start(_ work: @escaping @MainActor () async -> Void) {
        operation?.cancel()
        operation = Task { await work() }
    }

    private func display(_ value: String, field: EditorSettingsImportField) -> String {
        let title: String
        switch field {
        case .customTheme: return ImportedEditorTheme.decode(value)?.name ?? language.localizedString("None")
        case .keymap: title = "Keyboard shortcuts"
        case .fontSize: title = Double(value).map { $0.isFinite && $0.rounded() == $0 ? String(format: "%.0f", $0) : value } ?? value
        case .lineHeight: title = Double(value) == 0 ? "Automatic" : value
        case .themePreference: title = AppThemePreference(rawValue: value)?.title ?? value
        case .colorScheme: title = EditorAppearanceSettings.ColorScheme(rawValue: value)?.title ?? value
        case .lineNumbers: title = EditorAppearanceSettings.LineNumbers(rawValue: value)?.title ?? value
        case .whitespace: title = EditorAppearanceSettings.Whitespace(rawValue: value)?.title ?? value
        case .cursorStyle: title = EditorAppearanceSettings.CursorStyle(rawValue: value)?.title ?? value
        case .cursorBlinking: title = EditorAppearanceSettings.CursorBlinking(rawValue: value)?.title ?? value
        default: title = value == "true" ? "On" : value == "false" ? "Off" : value
        }
        return language.localizedString(title)
    }

    var body: some View {
        VStack(spacing: 0) {
            if feature.isChoosingSettings { settingsPage }
            else { sourcePage }
            if feature.settings.editorImportRecoveryFailed {
                Text("Settings could not be verified. The recovery backup has been retained.")
                    .foregroundStyle(.red).padding(.horizontal, 20)
            }
            if let message = feature.message {
                Text(verbatim: language.localizedString(message))
                    .font(LitheTheme.uiFont(size: 12)).padding(.horizontal, 20).padding(.bottom, 10)
            }
            if feature.isImporting {
                ProgressView { Text("Importing settings…") }
                    .controlSize(.small).padding(.bottom, 10)
                    .accessibilityIdentifier("editor-import-progress")
            } else if feature.isChoosingSettings, let result = feature.importResult {
                Text("Applied: \(result.applied). Not selected: \(result.unselected).")
                    .font(LitheTheme.uiFont(size: 12)).padding(.horizontal, 20).padding(.bottom, 10)
                    .accessibilityIdentifier("editor-import-result")
            }
            HStack {
                Spacer()
                Button {
                    start { await feature.scan(directory: feature.isChoosingSettings ? feature.source?.directory : nil) }
                } label: {
                    Text("Scan again").font(LitheTheme.uiFont(size: 11))
                }
                .buttonStyle(LitheBannerActionStyle())
                .accessibilityIdentifier("editor-import-rescan")
                .disabled(feature.isBusy)
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            Divider()
            footer
        }
        .frame(width: LitheWindowLayout.settingsImport.contentSize.width,
               height: LitheWindowLayout.settingsImport.contentSize.height)
        .background(LitheCommitDialogStyle.background)
        .task {
            feature.backToSources()
            if !startup, feature.sources.isEmpty { await feature.scan() }
        }
        .onDisappear { operation?.cancel(); operation = nil }
    }

    private var sourcePage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)
            Text("Import settings from").font(LitheTheme.uiFont(.title2))
                .padding(.bottom, 26)
            if feature.isBusy { ProgressView().padding(.bottom, 12) }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(feature.sources) { source in
                        Button { start { await feature.chooseSource(source.id) } } label: {
                            HStack(spacing: 8) {
                                LitheIDEAIcon(resourcePath: source.isCursor ? "importSettings/cursor.svg" : source.isVSCode ? "importSettings/vscode.svg" : "importSettings/idea.svg",
                                              size: 20, preservesOriginalColors: true)
                                    .accessibilityHidden(true)
                                Text(verbatim: source.title)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            .frame(width: 280 - 2 * LitheTheme.ActionButton.horizontalPadding, height: 40)
                        }
                        .buttonStyle(LitheActionButtonStyle())
                        .help(Text(verbatim: source.directory.path))
                        .disabled(feature.isBusy)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: min(CGFloat(max(feature.sources.count, 1)) * 48, 240))
            .litheScrollViewChrome()
            Spacer(minLength: 20)
        }
    }

    private var settingsPage: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                if let source = feature.source {
                    HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Import settings from")
                            .font(LitheTheme.uiFont(size: 24, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(alignment: .top, spacing: 8) {
                            LitheIDEAIcon(resourcePath: source.isCursor ? "importSettings/cursor.svg" : source.isVSCode ? "importSettings/vscode.svg" : "importSettings/idea.svg",
                                          size: 24, preservesOriginalColors: true)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(verbatim: source.title).font(LitheTheme.uiFont(size: 14))
                                    .lineLimit(1).truncationMode(.middle)
                                    .help(Text(verbatim: ([source.title, language.localizedString("Only selected appearance and editor settings are copied into Lithe. Source files are never modified. Existing custom settings are unchecked by default.")]
                                        + source.warnings.map { language.localizedString($0) }).joined(separator: "\n\n")))
                                    .accessibilityIdentifier("editor-import-source-title")
                                Text(verbatim: source.directory.path)
                                    .font(LitheTheme.uiFont(size: 11)).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                    .help(Text(verbatim: source.directory.path))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if feature.isBusy && !feature.isImporting { ProgressView().controlSize(.small) }
                    }
                    .frame(width: 180, alignment: .leading)
                    VStack(alignment: .leading, spacing: 10) {
                    if let status = feature.sourceStatusMessage, source.readFailed || source.values.isEmpty {
                        VStack(spacing: 12) {
                            if source.readFailed {
                                Text("Unable to read settings")
                                    .font(LitheTheme.uiFont(size: 14, weight: .semibold))
                            } else if feature.importResult != nil {
                                Text("Import complete")
                                    .font(LitheTheme.uiFont(size: 14, weight: .semibold))
                            } else if !source.values.isEmpty {
                                Text("Settings already match")
                                    .font(LitheTheme.uiFont(size: 14, weight: .semibold))
                            } else {
                                Text("No settings to import yet")
                                    .font(LitheTheme.uiFont(size: 14, weight: .semibold))
                            }
                            if source.settingsFileMissing && source.values.isEmpty {
                                Text("\(source.title) has no saved user settings.")
                                    .font(LitheTheme.uiFont(size: 12)).foregroundStyle(.secondary)
                            } else {
                                Text(verbatim: language.localizedString(status))
                                    .font(LitheTheme.uiFont(size: 12))
                                    .foregroundStyle(source.readFailed ? Color.red : Color.secondary)
                            }
                        }
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("editor-import-empty-state")
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 24) {
                                ForEach(["appearance", "keymap", "code", "preferences"], id: \.self) { category in
                                    let fields = EditorSettingsImportField.allCases.filter { $0.category == category && source.values[$0.rawValue] != nil }
                                    let title = category == "appearance" ? "Appearance settings" : category == "keymap" ? "Keyboard shortcuts" : category == "code" ? "Code settings" : "Editor preferences"
                                    if !fields.isEmpty {
                                        let keys = Set(fields.map(\.rawValue))
                                        let descriptions = fields.flatMap { field -> [String] in
                                            if field == .customTheme && source.values[field.rawValue] == "" { return [] }
                                            if field == .keymap, let map = source.values[field.rawValue].flatMap(EditorImportKeymap.decode) {
                                                return map.commands.keys.sorted().map { LitheCommandCatalog.command(id: $0)?.title ?? $0 }
                                            }
                                            return [field.title]
                                        }
                                        HStack(alignment: .top, spacing: 10) {
                                            LitheIDEAIcon(resourcePath: category == "appearance" ? "importSettings/colorPicker.svg" : category == "keymap" ? "importSettings/keyboard.svg" : category == "code" ? "importSettings/configFile.svg" : "importSettings/settings.svg", size: 16)
                                                .accessibilityHidden(true)
                                            VStack(alignment: .leading, spacing: 5) {
                                                Text(verbatim: language.localizedString(title))
                                                    .font(LitheTheme.uiFont(size: 13))
                                                    .lineLimit(1).truncationMode(.tail)
                                                    .accessibilityIdentifier("editor-import-" + category + "-title")
                                                HStack(spacing: 6) {
                                                    Text(verbatim: descriptions.map { language.localizedString($0) }.joined(separator: ", "))
                                                        .lineLimit(1).truncationMode(.tail)
                                                }
                                                .font(LitheTheme.uiFont(size: 11)).foregroundStyle(.secondary)
                                                if category == "keymap", let conflict = feature.keymapConflict {
                                                    Text(verbatim: EditorSettingsImportError.shortcutConflict(conflict).errorDescription ?? "")
                                                        .font(LitheTheme.uiFont(size: 11)).foregroundStyle(.red)
                                                }
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .help(Text(verbatim: fields.map { field in
                                                let tags = [
                                                    source.defaultFields.contains(field.rawValue) ? language.localizedString("Default") : nil,
                                                    source.approximateFields.contains(field.rawValue) ? language.localizedString("Approximate") : nil,
                                                ].compactMap { $0 }.joined(separator: ", ")
                                                if field == .keymap, let map = source.values[field.rawValue].flatMap(EditorImportKeymap.decode) {
                                                    return map.commands.keys.sorted().map { id in
                                                        language.localizedString(LitheCommandCatalog.command(id: id)?.title ?? id) + ": "
                                                            + (map.commands[id] ?? []).map(\.displayText).joined(separator: ", ")
                                                    }.joined(separator: "\n")
                                                }
                                                return language.localizedString(field.title) + ": "
                                                    + display(feature.baseline[field.rawValue] ?? "—", field: field) + " → "
                                                    + display(source.values[field.rawValue] ?? "—", field: field)
                                                    + (tags.isEmpty ? "" : " (" + tags + ")")
                                            }.joined(separator: "\n")))
                                            LitheSettingsCheckbox(isOn: Binding(get: { !keys.isEmpty && keys.isSubset(of: feature.selected) }, set: { enabled in
                                                if enabled { feature.selected.formUnion(keys) } else { feature.selected.subtract(keys) }
                                            }), accessibilityLabel: LocalizedStringKey(title))
                                            .accessibilityIdentifier("editor-import-" + category + "-group")
                                            .disabled(feature.isBusy)
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 8)
                        }
                        .litheScrollViewChrome()
                    }

                    }
                    .frame(width: 400, alignment: .topLeading)
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if feature.isChoosingSettings {
                Button("Back") { feature.backToSources() }.buttonStyle(LitheActionButtonStyle())
                    .accessibilityIdentifier("editor-import-back")
            } else {
                Button("Skip") { onDismiss() }.buttonStyle(LitheActionButtonStyle())
                    .accessibilityIdentifier("editor-import-skip")
            }
            if feature.settings.canUndoEditorSettingsImport {
                Button("Undo last import") { feature.undo() }
                    .buttonStyle(LitheActionButtonStyle())
                    .accessibilityIdentifier("editor-import-undo")
            }
            Spacer(minLength: 0)
            Button("Close") { onDismiss() }.buttonStyle(LitheActionButtonStyle())
            if feature.isChoosingSettings, feature.source?.values.isEmpty == false {
                Button("Import selected") {
                    start { if await feature.apply(), startup { onDismiss() } }
                }
                .buttonStyle(LitheActionButtonStyle(isPrimary: true))
                .accessibilityIdentifier("editor-import-apply")
                .disabled(feature.source?.readFailed == true || feature.selected.isEmpty || feature.settings.editorImportRecoveryFailed)
            } else if !feature.isChoosingSettings {
                Button("Choose directory") { start { await feature.chooseDirectory() } }.buttonStyle(LitheActionButtonStyle())
            }
        }
        .disabled(feature.isBusy)
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(LitheTheme.toolHeader)
    }
}
