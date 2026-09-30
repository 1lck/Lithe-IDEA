import SwiftUI
import LitheCoreContracts

/// Provider selection is independent of the provider used for commit messages.
struct AgentProviderConfigurationView: View {
    let agentID: String
    let name: String
    let source: AIConfigurationSourceKind?
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @State private var editor: AgentProviderDraft?
    @State private var deletion: AIProviderProfile?
    @State private var errorMessage: String?
    @State private var actionTask: Task<Void, Never>?

    private var usesSubscription: Bool { settings.agentConfigurations[agentID]?.authentication == .codexSubscription }
    private var selected: AIProviderProfile? { settings.agentProvider(for: agentID) }
    private var sources: [AIConfigurationSourceKind] { source.map { [$0] } ?? AIConfigurationSourceKind.allCases }
    private var providers: [AIProviderProfile] {
        settings.commitMessageAI.providers.filter { provider in
            provider.credentialSource == .local && sources.contains {
                provider.apiProtocol == ($0 == .codex ? .responses : .anthropicMessages) &&
                    provider.authentication == ($0 == .codex ? .bearer : .apiKey)
            }
        }
    }

    var body: some View {
        AgentSettingsCard(title: "Providers", systemImage: "key") {
            HStack {
                Text("Use local configuration or add your own provider.")
                    .font(LitheTheme.uiFont(size: 12)).foregroundStyle(LitheTheme.secondaryText)
                Spacer(minLength: 8)
                if let source {
                    Button { openEditor(source: source) } label: { Label("Add", systemImage: "plus") }
                        .buttonStyle(LitheSecondaryButtonStyle(horizontalPadding: 10, height: 24, fontSize: 11.5))
                } else {
                    Menu {
                        ForEach(sources) { kind in
                            Button(kind.title) { openEditor(source: kind) }
                        }
                    } label: { Label("Add", systemImage: "plus") }
                }
            }
            if agentID == "codex-acp" { subscriptionRow }
            ForEach(sources) { kind in
                localRow(kind)
            }
            ForEach(providers) { provider in
                providerRow(provider)
            }
            if providers.isEmpty {
                Text("No custom providers yet.").font(LitheTheme.uiFont(size: 12)).foregroundStyle(LitheTheme.tertiaryText)
            }
            if let selected, selected.credentialSource == .local {
                Text(String(format: String(localized: "Current provider: %@"), selected.name))
                    .font(LitheTheme.uiFont(size: 11)).foregroundStyle(LitheTheme.secondaryText)
            }
            if self.selected != nil || usesSubscription {
                Button("Unlink") {
                    perform { try await model.useAgentProvider(nil, agentID: agentID, name: name) }
                }
                .buttonStyle(LitheSecondaryButtonStyle(horizontalPadding: 10, height: 24, fontSize: 11.5))
            }
            if let errorMessage {
                Text(errorMessage).font(LitheTheme.uiFont(size: 12)).foregroundStyle(LitheTheme.error)
                    .textSelection(.enabled)
            }
            AgentSettingsHint("Local configuration follows your CLI files. Custom providers are saved in Lithe and do not change those files. Switching restarts this project's Agent connection; open history again to continue a saved conversation.")
        }
        .disabled(model.isChangingAgentProvider)
        .sheet(item: $editor) { draft in
            AgentProviderEditorView(model: model, draft: draft)
        }
        .alert("Confirm deletion", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } })) {
            Button("Cancel", role: .cancel) { deletion = nil }
            Button("Delete", role: .destructive) {
                guard let provider = deletion else { return }
                deletion = nil
                perform { try await model.deleteAgentProvider(provider) }
            }
        } message: {
            Text("Delete this provider and its saved API key? Agents using it will be unlinked. It is also removed from AI Providers in Settings.")
        }
        .onDisappear { actionTask?.cancel() }
    }

    private var subscriptionRow: some View {
        HStack(spacing: 8) {
            Image(systemName: usesSubscription ? "checkmark.circle.fill" : "person.crop.circle")
                .foregroundStyle(usesSubscription ? LitheTheme.accent : LitheTheme.secondaryText)
            VStack(alignment: .leading, spacing: 3) {
                Text("Codex subscription").font(LitheTheme.uiFont(size: 12, weight: .medium))
                Text("Use your local ChatGPT account. No API key or URL is needed.")
                    .font(LitheTheme.uiFont(size: 11)).foregroundStyle(LitheTheme.secondaryText)
            }
            Spacer(minLength: 8)
            Button(usesSubscription ? "Enabled" : "Enable") {
                perform { try await model.useCodexSubscription() }
            }
            .buttonStyle(LitheSecondaryButtonStyle(horizontalPadding: 10, height: 24, fontSize: 11.5))
            .disabled(usesSubscription)
        }
        .padding(10)
        .background(LitheTheme.inputBackground, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(usesSubscription ? LitheTheme.accent : LitheTheme.panelBorder, lineWidth: 1))
    }

    private func localRow(_ kind: AIConfigurationSourceKind) -> some View {
        let active = selected?.credentialSource.configurationSource == kind
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: active ? "checkmark.circle.fill" : "doc.text.magnifyingglass")
                    .foregroundStyle(active ? LitheTheme.accent : LitheTheme.secondaryText)
                Text(String(format: String(localized: "Local %@ configuration"), kind.title))
                    .font(LitheTheme.uiFont(size: 12, weight: .medium))
                Spacer(minLength: 8)
                Button(active ? "Refresh" : "Use") {
                    perform { try await model.useLocalAgentProvider(source: kind, agentID: agentID, name: name) }
                }
                .buttonStyle(LitheSecondaryButtonStyle(horizontalPadding: 10, height: 24, fontSize: 11.5))
            }
            if active, let selected { metadata(selected) }
        }
        .padding(10)
        .background(LitheTheme.inputBackground, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(active ? LitheTheme.accent : LitheTheme.panelBorder, lineWidth: 1))
    }

    private func providerRow(_ provider: AIProviderProfile) -> some View {
        let active = selected?.id == provider.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: active ? "checkmark.circle.fill" : "server.rack")
                    .foregroundStyle(active ? LitheTheme.accent : LitheTheme.secondaryText)
                Text(provider.name).font(LitheTheme.uiFont(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 8)
                Button(active ? "Enabled" : "Enable") {
                    perform { try await model.useAgentProvider(provider, agentID: agentID, name: name) }
                }
                .buttonStyle(LitheSecondaryButtonStyle(horizontalPadding: 10, height: 24, fontSize: 11.5))
                .disabled(active)
                Button { openEditor(source: provider.apiProtocol == .responses ? .codex : .claude, provider: provider) } label: {
                    Image(systemName: "pencil")
                }.litheIconButton().help("Edit provider")
                Button { deletion = provider } label: { Image(systemName: "trash") }
                    .litheIconButton().help("Delete provider")
            }
            metadata(provider)
        }
        .padding(10)
        .background(LitheTheme.inputBackground, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(active ? LitheTheme.accent : LitheTheme.panelBorder, lineWidth: 1))
    }

    private func metadata(_ provider: AIProviderProfile) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(provider.endpoint).lineLimit(1).truncationMode(.middle).help(provider.endpoint)
            Text(provider.model).lineLimit(1)
        }.font(LitheTheme.uiFont(size: 11, design: .monospaced)).foregroundStyle(LitheTheme.secondaryText)
    }

    private func openEditor(source: AIConfigurationSourceKind, provider: AIProviderProfile? = nil) {
        do { editor = try model.agentProviderDraft(source: source, provider: provider); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard actionTask == nil else { return }
        actionTask = Task { @MainActor in
            defer { actionTask = nil }
            do { try await action(); errorMessage = nil }
            catch is CancellationError { }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct AgentProviderEditorView: View {
    @ObservedObject var model: AppModel
    @State var draft: AgentProviderDraft
    @State private var errorMessage: String?
    @State private var saveTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.providerID == nil ? "Add provider" : "Edit provider")
                .font(LitheTheme.uiFont(size: 17, weight: .semibold))
            TextField("Provider name", text: $draft.name).litheSettingsTextField()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    configurationEditor(draft.source == .codex ? "config.toml" : "settings.json", text: $draft.configuration,
                        canFormat: draft.source == .claude)
                    if draft.source == .codex {
                        configurationEditor("auth.json", text: $draft.authentication, canFormat: true)
                    }
                    Toggle("Allow insecure HTTP", isOn: $draft.allowsInsecureHTTP)
                        .font(LitheTheme.uiFont(size: 12))
                    AgentSettingsHint("Only the API URL, model and API key are saved. Other CLI options continue to use your local configuration. The key is stored separately from settings. Editing shows a template of these saved fields.")
                }
            }
            // Errors stay visible even when the configuration editors fill the scroll viewport.
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(LitheTheme.uiFont(size: 12)).foregroundStyle(LitheTheme.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                if saveTask != nil { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    .buttonStyle(LitheSecondaryButtonStyle())
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
                    .buttonStyle(LithePrimaryButtonStyle(backgroundColor: LitheTheme.accent, restingOpacity: 1))
            }
        }
        .padding(20).frame(width: 540, height: 620)
        .background(LitheTheme.raised)
        .disabled(model.isChangingAgentProvider || saveTask != nil)
        .interactiveDismissDisabled(saveTask != nil)
        .onDisappear { saveTask?.cancel() }
    }

    private func configurationEditor(_ title: String, text: Binding<String>, canFormat: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(LitheTheme.uiFont(size: 12, weight: .medium))
                Spacer()
                if canFormat {
                    Button("Format JSON") {
                        do {
                            let value = try JSONSerialization.jsonObject(with: Data(text.wrappedValue.utf8))
                            let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                            text.wrappedValue = String(decoding: data, as: UTF8.self)
                            errorMessage = nil
                        } catch { errorMessage = String(localized: "Invalid JSON. Check the configuration format.") }
                    }.buttonStyle(LitheSecondaryButtonStyle(horizontalPadding: 10, height: 24, fontSize: 11.5))
                }
            }
            MacConfigurationTextEditor(text: text, label: title)
                .frame(height: title == "auth.json" ? 110 : 210)
                .background(LitheTheme.inputBackground, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(LitheTheme.panelBorder, lineWidth: 1))
                .accessibilityLabel(title)
        }
    }

    private func save() {
        guard saveTask == nil else { return }
        saveTask = Task { @MainActor in
            defer { saveTask = nil }
            do { try await model.saveAgentProvider(draft); dismiss() }
            catch is CancellationError { }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
