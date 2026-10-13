import AppKit
import CryptoKit
import Foundation
import LitheCoreContracts
import UniformTypeIdentifiers

/// Metadata lives in platform preferences, never in an installed bundle or Agent files.
@MainActor
struct MacAgentHistoryPersistence: AgentHistoryPersisting {
    let store: any KeyValueStore

    func load(workspaceURL: URL, agentID: String) throws -> [String: AgentHistoryMetadata] {
        guard let data = store.data(forKey: key(workspaceURL, agentID)) else { return [:] }
        return try JSONDecoder().decode([String: AgentHistoryMetadata].self, from: data)
    }

    func save(_ metadata: [String: AgentHistoryMetadata], workspaceURL: URL, agentID: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        store.set(try encoder.encode(metadata), forKey: key(workspaceURL, agentID))
    }

    private func key(_ workspaceURL: URL, _ agentID: String) -> String {
        let identity = workspaceURL.standardizedFileURL.path + "\u{0}" + agentID
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return "lithe.agent-history.v1.\(digest)"
    }
}

/// Export destination is chosen by the user. No transcript cache or bundle writes.
@MainActor
struct MacAgentHistoryExporter: AgentHistoryExporting {
    let storage: any FileStorage

    func chooseDestination() -> URL? {
        let panel = NSSavePanel()
        panel.title = String(localized: "Export conversations")
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "agent-conversations.md"
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    func writeMarkdown(_ markdown: String, to url: URL) async throws {
        guard !url.resolvingSymlinksInPath().pathComponents.contains(where: { $0.hasSuffix(".app") }) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let data = Data(markdown.utf8)
        guard data.count <= 32 * 1024 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
        try await Task.detached(priority: .userInitiated) { [storage] in
            try Task.checkCancellation()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            try storage.writeData(data, to: url, options: .atomic)
        }.value
    }
}
