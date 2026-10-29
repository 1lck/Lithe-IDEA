import LitheModuleAPI
import SwiftUI

/// Public directory search is separate from local Agent configuration. Adding
/// opens the normal editor and never starts a server or writes configuration.
struct McpDiscoveryView: View {
    @ObservedObject var feature: McpRegistryFeatureModel
    let add: (McpServerDraft) -> Void
    @State private var query = ""
    @State private var request = 0
    @State private var pageRequest = 0
    @State private var retrying = false
    @State private var route = McpRegistryRoute.system

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Discover MCP servers").font(LitheTheme.settingsFont)
                LitheInfoTip("Featured servers ship with Lithe and work offline. Searching also checks the official MCP Registry. Listing is not a security review. Adding opens a configuration to review; packages are not downloaded or run. Follow the publisher's documentation for authentication and other requirements.")
                Spacer()
                if feature.isLoading { ProgressView().controlSize(.small) }
                Text("Featured and the official MCP Registry")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.tertiaryText)
            }
            HStack(spacing: 8) {
                LitheSearchField("Search MCP servers — GitHub, browsers, documentation…", text: $query)
                    .onSubmit { search() }
                    .onChange(of: query) { value in
                        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { search() }
                    }
                Button("Search") { search() }
                    .buttonStyle(LitheActionButtonStyle())
            }
            if route == .direct {
                HStack(spacing: 6) {
                    Text("Direct connection").font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
                    LitheInfoTip("Direct retry applies only to public MCP Registry searches on this page. System proxy settings and Agent server connections are unchanged. TLS certificate validation remains enabled.")
                    Spacer()
                    Button("Use system proxy") { route = .system; search() }
                        .buttonStyle(.plain).font(LitheTheme.smallFont).foregroundStyle(LitheTheme.accent).lithePointer()
                }
            }
            if let error = feature.error {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "wifi.exclamationmark").foregroundStyle(LitheTheme.secondaryText)
                        Text(error).font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: LitheTheme.ActionButton.spacing) {
                        if !feature.entries.isEmpty {
                            Text("Showing available matches.").font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
                        }
                        Spacer(minLength: 0)
                        Button("Retry") { search(retry: true) }.buttonStyle(LitheActionButtonStyle())
                        if feature.canRetryDirectly {
                            Button("Retry directly") { route = .direct; search(retry: true) }
                                .buttonStyle(LitheActionButtonStyle())
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
                .background(LitheTheme.settingsControlBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if !feature.isLoading && feature.entries.isEmpty {
                Text("No matching MCP servers").font(LitheTheme.settingsFont)
                    .foregroundStyle(LitheTheme.secondaryText).padding(.vertical, 20)
            }
            McpRegistryCardsView(entries: feature.entries, add: add)
            LitheScrollLoadTrigger(
                continuationID: feature.nextCursor.map { "\(request):\($0)" },
                isEnabled: !feature.isLoading && feature.error == nil,
                load: { pageRequest += 1 }
            )
            .frame(height: 1)
        }
        .task(id: request) {
            if retrying { await feature.retry(route: route) }
            else { await feature.search(query, route: route) }
        }
        .task(id: pageRequest) { if pageRequest > 0 { await feature.loadNextPage() } }
    }

    private func search(retry: Bool = false) { retrying = retry; request += 1 }
}

struct McpRegistryCardsView: View {
    let entries: [McpRegistryEntry]
    let add: (McpServerDraft) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], alignment: .leading, spacing: 12) {
            ForEach(entries) { entry in McpRegistryCard(entry: entry, add: add) }
        }
    }
}

/// Registry descriptions are primary catalog content, rather than settings help.
/// Two lines let users compare servers without opening every documentation link.
private struct McpRegistryCard: View {
    let entry: McpRegistryEntry
    let add: (McpServerDraft) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                McpBrandIcon(entry: entry)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: entry.title)
                        .font(LitheTheme.uiFont(size: 13, weight: .semibold)).lineLimit(2)
                    HStack(spacing: 6) {
                        Text(verbatim: entry.publisher ?? entry.id.components(separatedBy: "/").first ?? entry.id)
                            .lineLimit(1)
                        if let transportLabel {
                            Text(transportLabel)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(LitheTheme.settingsControlBorder.opacity(0.4))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        if let message = McpServerDraft(entry: entry)?.setupMessage {
                            Image(systemName: entry.setup == .bearerToken ? "key" : "folder")
                                .help(message)
                        }
                    }
                    .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
                }
                Spacer(minLength: 0)
            }
            summary
                .font(LitheTheme.uiFont(size: 12)).foregroundStyle(LitheTheme.secondaryText)
                .lineLimit(2).frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
                .help(summary)
            HStack(spacing: 8) {
                if entry.source == .featured {
                    Text("Featured").font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
                }
                if !entry.version.isEmpty {
                    Text(verbatim: entry.version).font(LitheTheme.smallFont)
                        .foregroundStyle(LitheTheme.tertiaryText).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let website = entry.website {
                    Link("Documentation", destination: website).font(LitheTheme.smallFont)
                        .fixedSize()
                }
                if let draft = McpServerDraft(entry: entry) {
                    Button("Configure…") { add(draft) }.buttonStyle(LitheActionButtonStyle())
                        .fixedSize()
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(LitheTheme.settingsControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(LitheTheme.settingsControlBorder, lineWidth: 1))
    }

    private var summary: Text {
        entry.source == .featured ? Text(LocalizedStringKey(entry.summary)) : Text(verbatim: entry.summary)
    }

    private var transportLabel: String? {
        guard let draft = entry.draft else { return nil }
        guard draft.transport == .stdio else { return L10n.string("Remote") }
        switch draft.command {
        case "npx": return "npx"
        case "uvx": return "uvx"
        default: return L10n.string("Command")
        }
    }
}

/// Pasting a standard mcpServers object previews each recognized definition.
/// The user chooses a server, reviews its fields, then explicitly saves it.
struct McpJsonImportView: View {
    let feature: McpServerLibraryFeatureModel
    let cancel: () -> Void
    let select: (McpServerDraft) -> Void
    @State private var json = ""
    @State private var drafts: [McpServerDraft] = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Import MCP configuration").font(LitheTheme.uiFont(size: 16, weight: .semibold))
                LitheInfoTip("Paste standard JSON with an mcpServers object. Choose a server to review before saving. Only the editor's supported command, arguments, environment, URL and header fields are imported; authentication and client-specific options must be configured separately. Importing does not take ownership of an existing entry.")
                Spacer()
            }
            Divider()
            LitheTextEditor(text: $json, height: 240)
                .accessibilityLabel(Text("MCP JSON"))
                .onChange(of: json) { _ in drafts = []; error = nil }
            if let error { Text(error).foregroundStyle(LitheTheme.error).font(LitheTheme.smallFont) }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(drafts.indices, id: \.self) { index in
                        Button { select(drafts[index]) } label: {
                            HStack { Text(verbatim: drafts[index].name); Spacer(); Text("Review configuration"); Image(systemName: "chevron.right") }
                        }.buttonStyle(LitheActionButtonStyle())
                    }
                }
            }
            Spacer(minLength: 0)
            Divider()
            HStack(spacing: LitheTheme.ActionButton.spacing) {
                Spacer()
                Button("Cancel", action: cancel).buttonStyle(LitheActionButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Preview import") {
                    do { drafts = try feature.importedDrafts(json); error = nil }
                    catch { self.error = L10n.string("Could not import MCP JSON. Check the mcpServers object and try again.") }
                }.buttonStyle(LitheActionButtonStyle(isPrimary: true))
            }
        }
    }
}
