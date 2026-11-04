import Combine
import Foundation
import LitheModuleAPI

@MainActor
final class EditorSettingsImportFeatureModel: ObservableObject {
    @Published private(set) var sources: [EditorSettingsImportSource] = []
    @Published private(set) var isBusy = false
    @Published private(set) var isImporting = false
    @Published private(set) var importResult: (applied: Int, unselected: Int)?
    @Published private(set) var isChoosingSettings = false
    @Published var sourceID = ""
    @Published var selected: Set<String> = []
    @Published private(set) var baseline: [String: String] = [:]
    @Published private(set) var message: String?
    @Published private(set) var startupFinished: Bool
    @Published private(set) var startupChecked = false
    let settings: AppSettings
    private let chooseSourceDirectory: () -> URL?
    private let scanSources: ((URL?) async throws -> [EditorSettingsImportSource])?
    private let planKeymap: (([KeymapImportCurrent], [KeymapImportBinding]) throws -> KeymapImportBindingPlan)?
    private let loadKeymapOnSelection: Bool
    private let logSink: (any LogSink)?
    init(settings: AppSettings, chooseDirectory: @escaping () -> URL?,
         scan: ((URL?) async throws -> [EditorSettingsImportSource])?,
         planKeymap: (([KeymapImportCurrent], [KeymapImportBinding]) throws -> KeymapImportBindingPlan)? = nil,
         loadKeymapOnSelection: Bool = false, logSink: (any LogSink)? = nil) {
        self.settings = settings
        startupFinished = settings.didOfferEditorSettingsImport
        chooseSourceDirectory = chooseDirectory
        scanSources = scan
        self.planKeymap = planKeymap
        self.loadKeymapOnSelection = loadKeymapOnSelection
        self.logSink = logSink
    }
    var source: EditorSettingsImportSource? { sources.first { $0.id == sourceID } }

    var sourceStatusMessage: String? {
        guard let source else { return nil }
        if source.readFailed { return "The configuration could not be read. Check the selected directory and file permissions." }
        if source.settingsFileMissing && source.values.isEmpty { return "This editor has no saved user settings yet. Save settings in the editor, then scan again." }
        if source.values.isEmpty { return "This configuration has no supported explicit editor settings to import." }
        return changedFields.isEmpty ? "The settings we can read already match Lithe." : nil
    }

    /// Import only the source's mapped commands, preserving unrelated local overrides and preset.
    var importValues: [String: String] {
        var values = source?.values ?? [:]
        if let incoming = values["keymap"].flatMap(EditorImportKeymap.decode),
           var current = baseline["keymap"].flatMap(EditorImportKeymap.decode) {
            if let (plan, registrations) = try? keymapPlan(incoming: incoming, current: current), plan.conflicts.isEmpty {
                for displaced in plan.displaced {
                    guard let registration = registrations.first(where: { $0.commandID == displaced.commandID }) else { continue }
                    let keys = Set(displaced.keys)
                    current.commands[displaced.commandID] = registration.bindings.filter { binding in
                        guard let key = Self.portableKey(binding) else { return true }
                        return !keys.contains(key)
                    }
                }
            }
            current.commands.merge(incoming.commands) { _, imported in imported }
            values["keymap"] = current.encoded
        }
        return values
    }

    private static func portableKey(_ binding: KeyboardShortcutBinding) -> KeymapImportBinding.Key? {
        guard case let .keyPress(key, modifiers) = binding else { return nil }
        var result: [KeymapImportBinding.Key.Modifier] = []
        if modifiers.contains(.control) { result.append(.control) }
        if modifiers.contains(.option) { result.append(.alt) }
        if modifiers.contains(.shift) { result.append(.shift) }
        if modifiers.contains(.command) { result.append(.meta) }
        return .init(key: key == "delete" ? "backspace" : key, modifiers: result)
    }

    private func keymapPlan(incoming: EditorImportKeymap, current: EditorImportKeymap) throws
        -> (KeymapImportBindingPlan, [KeyboardShortcutRegistration])? {
        guard let planKeymap else { return nil }
        let registrations = KeyboardShortcutFeatureModel(settings: settings).registrations(for: current.commands)
        let currentBindings = registrations.map { registration in
            KeymapImportCurrent(commandID: registration.commandID,
                customized: current.commands[registration.commandID] != nil,
                keys: registration.bindings.compactMap(Self.portableKey))
        }
        let incomingRows = incoming.commands.map { id, bindings in
            (KeymapImportBinding(commandID: id, keys: bindings.compactMap(Self.portableKey)), bindings.count)
        }
        // Never silently discard a binding the shared plan cannot represent.
        guard incomingRows.allSatisfy({ $0.0.keys.count == $0.1 }) else { throw KeyboardShortcutUpdateError.invalidBinding }
        return (try planKeymap(currentBindings, incomingRows.map(\.0)), registrations)
    }

    var keymapConflict: String? {
        if let incoming = source?.values["keymap"].flatMap(EditorImportKeymap.decode),
           let current = baseline["keymap"].flatMap(EditorImportKeymap.decode) {
            do {
                if let (plan, _) = try keymapPlan(incoming: incoming, current: current), let conflict = plan.conflicts.first {
                    return LitheCommandCatalog.command(id: conflict.ownerID)?.title ?? conflict.ownerID
                }
            // log-exempt: 随输入实时重算的校验提示：预览失败会阻止用户提交，提交边界记录实际失败
            } catch { return "Keyboard shortcuts" }
        }
        guard let map = importValues["keymap"].flatMap(EditorImportKeymap.decode) else { return nil }
        do { try KeyboardShortcutFeatureModel(settings: settings).validateOverrides(map.commands) }
        // log-exempt: 随输入实时重算的校验提示：导入草稿的快捷键冲突预览尚未执行写入
        catch KeyboardShortcutUpdateError.conflict(let command) {
            return LitheCommandCatalog.command(id: command)?.title ?? command
        // log-exempt: 随输入实时重算的校验提示：导入草稿冲突预览使用通用字段名
        } catch { return "Keyboard shortcuts" }
        return nil
    }

    var changedFields: [EditorSettingsImportField] {
        guard source?.readFailed != true else { return [] }
        return EditorSettingsImportField.allCases.filter { field in
            guard let value = importValues[field.rawValue] else { return false }
            return baseline[field.rawValue] != value
        }
    }

    func prepareStartup() async {
        guard !startupFinished, !startupChecked else { return }
        startupChecked = true
        if await scan(), sources.isEmpty { finishStartup() }
    }

    func finishStartup() {
        guard !isBusy else { return }
        settings.didOfferEditorSettingsImport = true
        startupFinished = true
    }

    @discardableResult
    func scan(directory: URL? = nil) async -> Bool {
        guard !isBusy, let scan = scanSources else { return false }
        isBusy = true; message = nil; importResult = nil
        defer { isBusy = false }
        do {
            let scanned = try await scan(directory)
            try Task.checkCancellation()
            let warningSources = scanned.filter { !$0.warnings.isEmpty }
            if !warningSources.isEmpty {
                logSink?.emit(EditorSettingsImportWarningsShown(sourceCount: Int64(warningSources.count),
                    warningCount: Int64(warningSources.reduce(0) { $0 + $1.warnings.count })))
            }
            if isChoosingSettings, let directory {
                // Refresh this preview without losing the other choices when navigating back.
                sources = sources.flatMap { $0.directory == directory ? scanned : [$0] }
            } else {
                sources = scanned
            }
            select(scanned.first?.id ?? "")
            if scanned.isEmpty { message = "No supported IDE configuration was found. You can choose a configuration directory." }
            return true
        // log-exempt: 用户取消：关闭导入界面会取消尚未应用的扫描
        } catch is CancellationError {
            return false
        } catch {
            logSink?.emit(EditorSettingsImportFailed(error: EditorSettingsImportError.logFailure(error), stage: "scan"))
            message = (error as? EditorSettingsImportError)?.errorDescription
                ?? "The configuration could not be read. Check the selected directory and file permissions."
            return false
        }
    }

    func chooseDirectory() async {
        guard !isBusy, let directory = chooseSourceDirectory() else { return }
        await scan(directory: directory)
    }

    func chooseSource(_ id: String) async {
        guard !isBusy, sources.contains(where: { $0.id == id }) else { return }
        select(id)
        isChoosingSettings = true
        if loadKeymapOnSelection, let source, source.values["keymap"] == nil {
            await scan(directory: source.directory)
        }
    }

    func backToSources() {
        guard !isBusy else { return }
        isChoosingSettings = false
    }

    func select(_ id: String) {
        importResult = nil
        sourceID = id
        baseline = settings.editorImportValues()
        guard source?.readFailed != true else { selected.removeAll(); return }
        var defaults = EditorAppearanceSettings().storedValues.mapValues { String(describing: $0) }
            .merging(["themePreference": "dark", "fontFamily": EditorFontDefaults.monospacedFamily, "fontSize": "13.0", "softWrap": "false", "minimap": "true"]) { _, new in new }
        if let incoming = source?.values["keymap"].flatMap(EditorImportKeymap.decode),
           let current = baseline["keymap"].flatMap(EditorImportKeymap.decode),
           Set(incoming.commands.keys).isDisjoint(with: current.commands.keys) {
            defaults["keymap"] = baseline["keymap"]
        }
        // Existing custom preferences require explicit selection in the preview.
        selected = Set(importValues.keys.filter { baseline[$0] == defaults[$0] || baseline[$0] == importValues[$0] })
        if let size = source?.lineHeightFontSize, baseline["fontSize"] != size, !selected.contains("fontSize") { selected.remove("lineHeight") }
        // Category-only selection must never hide a partially selected set of fields.
        // A category containing custom target values requires explicit confirmation.
        for category in ["appearance", "preferences", "keymap", "code"] {
            let keys = Set(EditorSettingsImportField.allCases.filter { $0.category == category && source?.values[$0.rawValue] != nil }.map(\.rawValue))
            if !keys.isSubset(of: selected) { selected.subtract(keys) }
        }
    }

    @discardableResult
    func apply() async -> Bool {
        guard !isBusy, let source, !source.readFailed, let scan = scanSources else { return false }
        let chosen = importValues.filter { selected.contains($0.key) }
        let changes = chosen.filter { baseline[$0.key] != $0.value }
        let importBaseline = baseline
        guard !chosen.isEmpty else { return false }
        let unselected = source.values.count - chosen.count
        isBusy = true; isImporting = true; message = nil; importResult = nil
        defer { isBusy = false; isImporting = false }
        do {
            let refreshed = try await scan(source.directory)
            try Task.checkCancellation()
            guard let current = refreshed.first(where: { $0.id == source.id }), current.revision == source.revision,
                  current.values == source.values else { throw EditorSettingsImportError.changed }
            let live = settings.editorImportValues()
            let persisted = settings.editorImportValues(persisted: true)
            guard !settings.editorImportRecoveryFailed,
                  chosen.keys.allSatisfy({ live[$0] == importBaseline[$0] && persisted[$0] == importBaseline[$0] }) else {
                throw EditorSettingsImportError.changed
            }
            guard chosen.allSatisfy({ EditorSettingsImportField(rawValue: $0.key)?.accepts($0.value) == true }) else {
                throw EditorSettingsImportError.invalid
            }
            if changes["lineHeight"] != nil, let size = source.lineHeightFontSize,
               ((changes["fontSize"] ?? settings.editorImportValues()["fontSize"]) != size ||
                (changes["fontSize"] ?? settings.editorImportValues(persisted: true)["fontSize"]) != size) {
                throw EditorSettingsImportError.fontSizeDependency
            }
            if chosen["keymap"] != nil, let conflict = keymapConflict { throw EditorSettingsImportError.shortcutConflict(conflict) }
            try Task.checkCancellation()
            if !changes.isEmpty { try settings.importEditorSettings(changes, baseline: importBaseline) }
            baseline = settings.editorImportValues()
            selected.removeAll()
            importResult = (changes.count, unselected)
            return true
        // log-exempt: 用户取消：取消导入时不会提交尚未完成的结果
        } catch is CancellationError {
            return false
        } catch {
            logSink?.emit(EditorSettingsImportFailed(error: EditorSettingsImportError.logFailure(error), stage: "apply"))
            message = (error as? EditorSettingsImportError)?.errorDescription ?? "The configuration could not be read. Check the selected directory and file permissions."
            return false
        }
    }

    func undo() {
        guard !isBusy else { return }
        do {
            try settings.undoEditorSettingsImport()
            importResult = nil
            baseline = settings.editorImportValues()
            selected.removeAll()
            message = "The previous editor settings have been restored."
        } catch {
            logSink?.emit(EditorSettingsImportFailed(error: EditorSettingsImportError.logFailure(error), stage: "undo"))
            message = (error as? EditorSettingsImportError)?.errorDescription
        }
    }
}
