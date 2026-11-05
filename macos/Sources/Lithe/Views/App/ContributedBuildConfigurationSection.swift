import LitheCoreContracts
import LitheExecutionModule
import LitheModuleAPI
import SwiftUI

/// A provider's native settings, drawn without build-tool-specific knowledge.
struct ContributedBuildConfigurationSection: View {
    @EnvironmentObject private var settingsContext: SettingsModelContext
    let pluginID: PluginID
    let buildSystemIDs: [String]
    @State private var feature: BuildSystemsFeatureModel?
    @State private var error: String?

    var body: some View {
        Group {
            if let feature {
                NativeBuildConfigurationEntries(feature: feature, pluginID: pluginID, buildSystemIDs: buildSystemIDs,
                    choosePath: settingsContext.model.pluginSettingsHandlers(for: pluginID).choosePath)
            } else {
                LitheSettingsSection("Native configuration") {
                    Text(verbatim: error ?? L10n.string("Open a project to read its native configuration."))
                        .foregroundStyle(LitheTheme.secondaryText)
                }
            }
        }
        .task(id: settingsContext.model.currentWorkspaceIdentity?.generation) {
            feature = nil; error = nil
            let model = settingsContext.model
            guard let identity = model.currentWorkspaceIdentity else { return }
            guard let access = await model.activateExecutionModule(), let build = access.buildSystems,
                  model.isCurrentWorkspace(identity) else { return }
            do {
                _ = try await build.prepareLanguageImport(workspaceURL: identity.url)
                try Task.checkCancellation()
                guard model.isCurrentWorkspace(identity) else { return }
                feature = build
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}

private struct NativeBuildConfigurationEntries: View {
    @ObservedObject var feature: BuildSystemsFeatureModel
    let pluginID: PluginID
    let buildSystemIDs: [String]
    let choosePath: (Bool) -> URL?

    private var entries: [BuildSystemEntry] {
        feature.entries.filter {
            $0.source.pluginID == pluginID.rawValue && buildSystemIDs.contains($0.instance.buildSystemID)
                && $0.declaration.nativeConfiguration
        }
    }
    var body: some View {
        if entries.isEmpty {
            LitheSettingsSection("Native configuration") {
                Text("This project has no matching build-system instance.").foregroundStyle(LitheTheme.secondaryText)
            }
        }
        ForEach(entries) { entry in
            NativeBuildConfigurationEditor(feature: feature, entry: entry, choosePath: choosePath)
                .id(entry.id + (feature.workspaceURL?.absoluteString ?? ""))
        }
    }
}

private struct NativeBuildConfigurationEditor: View {
    @ObservedObject var feature: BuildSystemsFeatureModel
    let entry: BuildSystemEntry
    let choosePath: (Bool) -> URL?
    @State private var action: Task<Void, Never>?
    @State private var error: String?
    private var state: BuildNativeConfigurationState { feature.nativeConfigurationState(entry.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LitheSettingsSection(title: "Native configuration", accessory: {
                LitheSettingsPill(verbatim: entry.instance.displayName, kind: .value)
                Spacer(minLength: 0)
                if state.isBusy { ProgressView().controlSize(.small) }
                Button(LocalizedStringKey(state.requiresExplicitRead ? "Read using project tool" : "Reload")) {
                    perform { _ = try await feature.readNativeConfiguration(entry.id, allowProjectTool: true) }
                }
                    .buttonStyle(LitheActionButtonStyle()).disabled(state.isBusy)
            }) {
                if let message = error ?? state.error {
                    Text(verbatim: message).foregroundStyle(LitheTheme.error).textSelection(.enabled)
                }
                if state.isStale {
                    Text("Native configuration changed. Reload before saving; your draft has been kept.")
                        .foregroundStyle(LitheTheme.warning)
                }
                if state.snapshot == nil && !state.isBusy {
                    Text("No native configuration has been read.").foregroundStyle(LitheTheme.secondaryText)
                }
            }
            if let snapshot = state.snapshot {
                ForEach(snapshot.sources) { source in
                    NativeBuildConfigurationSourceEditor(source: source, busy: state.isBusy, stale: state.isStale,
                        choosePath: choosePath) { edits in
                        perform { _ = try await feature.saveNativeConfiguration(entry.id, snapshot: snapshot, edits: edits) }
                    }
                }
            }
        }
        .task {
            guard state.snapshot == nil else { return }
            do { _ = try await feature.readNativeConfiguration(entry.id) }
            catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
        .onDisappear { action?.cancel(); action = nil }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        action?.cancel(); error = nil
        action = Task { @MainActor in
            do { try await operation() }
            catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}

struct NativeBuildConfigurationSourceEditor: View {
    let source: BuildNativeConfiguration.Source
    let busy: Bool
    let stale: Bool
    let choosePath: (Bool) -> URL?
    let save: (BuildNativeConfigurationEdits) -> Void
    @State private var draft: BuildNativeConfigurationDraft

    init(source: BuildNativeConfiguration.Source, busy: Bool, stale: Bool,
         choosePath: @escaping (Bool) -> URL?, save: @escaping (BuildNativeConfigurationEdits) -> Void) {
        self.source = source; self.busy = busy; self.stale = stale; self.choosePath = choosePath; self.save = save
        _draft = State(initialValue: BuildNativeConfigurationDraft(source: source))
    }

    var body: some View {
        LitheSettingsSection(title: scope, accessory: {
            if !source.writable { LitheSettingsPill("Read-only", kind: .value) }
        }) {
            HStack(alignment: .top) {
                Text("Changes are written to")
                Text(verbatim: URL(string: source.uri)?.path ?? source.uri)
                    .foregroundStyle(LitheTheme.secondaryText).textSelection(.enabled)
            }
            ForEach(source.fields) { field in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(verbatim: field.id).fontWeight(.medium)
                        Spacer(minLength: 0)
                        Toggle("Override", isOn: Binding(
                            get: { draft.overrides.contains(field.id) },
                            set: { draft.setOverride($0, fieldID: field.id) }
                        )).toggleStyle(.checkbox).disabled(!source.writable || busy || stale)
                    }
                    input(field).disabled(!source.writable || busy || stale || !draft.overrides.contains(field.id))
                    HStack(alignment: .top, spacing: 6) {
                        Text("Effective value").foregroundStyle(LitheTheme.tertiaryText)
                        Text(verbatim: display(field.effectiveValue)).textSelection(.enabled)
                        LitheSettingsPill(verbatim: field.effectiveSource, kind: .value)
                    }.font(LitheTheme.uiFont(size: 11))
                }
            }
            if source.writable {
                HStack {
                    Spacer(minLength: 0)
                    Button("Cancel") { draft = BuildNativeConfigurationDraft(source: source) }
                        .buttonStyle(LitheActionButtonStyle()).disabled(!draft.isDirty || busy)
                    Button("Save") { save(draft.edits) }
                        .buttonStyle(LitheActionButtonStyle()).disabled(!draft.isDirty || busy || stale)
                }
            }
        }
        .onChange(of: source) { value in draft = BuildNativeConfigurationDraft(source: value) }
    }

    @ViewBuilder private func input(_ field: BuildNativeConfiguration.Field) -> some View {
        let text = Binding(get: { draft.text(field.id) }, set: { draft.setText($0, field: field) })
        switch field.kind {
        case .stringList:
            LitheTextEditor(text: text, height: 60).accessibilityLabel(Text(verbatim: field.id))
        case .boolean:
            Toggle(isOn: Binding(get: { draft.values[field.id] == .bool(true) },
                                 set: { draft.setValue(.bool($0), fieldID: field.id) })) { Text(verbatim: field.id) }
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
        case .text, .file, .directory:
            HStack {
                LitheTextField(verbatim: "", text: text).accessibilityLabel(Text(verbatim: field.id))
                if field.kind == .file || field.kind == .directory {
                    Button("Choose") {
                        if let url = choosePath(field.kind == .directory) { draft.setValue(.string(url.path), fieldID: field.id) }
                    }.buttonStyle(LitheActionButtonStyle())
                }
            }
        }
    }

    private var scope: String {
        switch source.scope {
        case .installation: "Installation"
        case .user: "User"
        case .workspace: "Workspace"
        }
    }
    private func display(_ value: ToolingJSONValue) -> String {
        switch value {
        case .string(let text): text
        case .bool(let value): value ? L10n.string("On") : L10n.string("Off")
        case .array(let items): items.map(display).joined(separator: ", ")
        default: "—"
        }
    }
}
