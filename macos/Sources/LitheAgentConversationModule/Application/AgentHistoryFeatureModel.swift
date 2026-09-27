import Combine
import Foundation
import LitheCoreContracts

/// Manages Lithe's history annotations and exports Agent-owned replayed messages.
@MainActor
public final class AgentHistoryFeatureModel: ObservableObject {
    @Published public private(set) var metadata: [String: AgentHistoryMetadata] = [:]
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var isExporting = false
    private let connection: AgentConnectionModel
    private let workspaceURL: URL?
    private let agentID: String
    private let persistence: (any AgentHistoryPersisting)?
    private let exporter: (any AgentHistoryExporting)?
    private var exportTask: Task<Void, Never>?

    public init(connection: AgentConnectionModel, workspaceURL: URL?, agentID: String,
                persistence: (any AgentHistoryPersisting)? = nil, exporter: (any AgentHistoryExporting)? = nil) {
        self.connection = connection
        self.workspaceURL = workspaceURL
        self.agentID = agentID
        self.persistence = persistence
        self.exporter = exporter
        do { metadata = try readMetadata() }
        catch { errorMessage = error.localizedDescription }
    }

    public func title(for session: AgentSessionSummary) -> String? {
        metadata[session.id]?.title ?? session.title
    }

    @discardableResult
    public func rename(_ sessionID: String, title: String) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        return change([sessionID]) { $0.title = title }
    }

    @discardableResult
    public func setFavorite(_ ids: [String], _ favorite: Bool) -> Bool {
        change(ids) { $0.isFavorite = favorite }
    }

    @discardableResult
    public func setHidden(_ ids: [String], _ hidden: Bool) -> Bool {
        change(ids) { $0.isHidden = hidden }
    }

    public func canExport(_ ids: [String]) -> Bool {
        let known = Set(connection.sessions.map(\.id))
        return !ids.isEmpty && !isExporting && exporter != nil
            && ids.allSatisfy { known.contains($0) && connection.canExportTranscript($0) }
    }

    /// Loads unopened sessions sequentially, without changing the active tab.
    public func export(_ ids: [String]) {
        guard canExport(ids), let exporter else { return }
        guard let destination = exporter.chooseDestination() else { return }
        let sessions = connection.sessions.filter { ids.contains($0.id) }
        isExporting = true
        errorMessage = nil
        exportTask = Task { [weak self, connection] in
            do {
                var documents: [AgentHistoryDocument] = []
                for session in sessions {
                    try Task.checkCancellation()
                    let messages = try await connection.historyTranscript(session.id)
                    documents.append(AgentHistoryDocument(
                        id: session.id, title: self?.title(for: session) ?? session.title,
                        messages: messages
                    ))
                }
                try Task.checkCancellation()
                try await exporter.writeMarkdown(AgentHistoryDocument.markdown(documents), to: destination)
            } catch is CancellationError {
                // Module shutdown or an explicit cancel owns this task's end.
            } catch {
                if !Task.isCancelled { self?.errorMessage = error.localizedDescription }
            }
            self?.isExporting = false
            self?.exportTask = nil
        }
    }

    public func cancelExport() { exportTask?.cancel() }

    public func stop() async {
        exportTask?.cancel()
        await exportTask?.value
    }

    private func readMetadata() throws -> [String: AgentHistoryMetadata] {
        guard let workspaceURL, let persistence else { return metadata }
        return try persistence.load(workspaceURL: workspaceURL, agentID: agentID)
    }

    private func change(_ ids: [String], mutation: (inout AgentHistoryMetadata) -> Void) -> Bool {
        let validIDs = Set(connection.sessions.map(\.id)).intersection(ids)
        guard !validIDs.isEmpty else { return false }
        do {
            // Re-read before mutation so two windows do not overwrite each other's annotations.
            var updated = try readMetadata()
            for id in validIDs { mutation(&updated[id, default: AgentHistoryMetadata()]) }
            if let workspaceURL, let persistence {
                try persistence.save(updated, workspaceURL: workspaceURL, agentID: agentID)
            }
            metadata = updated
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

public struct AgentHistoryDocument: Sendable {
    public let id: String
    public let title: String?
    public let messages: [AgentConversationMessage]

    public init(id: String, title: String?, messages: [AgentConversationMessage]) {
        self.id = id
        self.title = title
        self.messages = messages
    }

    /// A portable transcript; tool messages retain their input, output and content.
    public static func markdown(_ documents: [Self]) -> String {
        documents.map { document in
            let title = (document.title ?? String(localized: "Untitled conversation"))
                .components(separatedBy: .newlines).joined(separator: " ")
            var sections = ["# \(title)", "Session ID: \(document.id)"]
            for message in document.messages {
                let role: String
                switch message.role {
                case .user: role = String(localized: "You")
                case .agent: role = "Agent"
                case .tool: role = String(localized: "Tool")
                }
                var content = "## \(role)\n\n\(message.text)"
                if let status = message.toolStatus { content += "\n\nStatus: \(status.rawValue)" }
                for detail in [message.toolDetails.input, message.toolDetails.output].compactMap({ $0 }) {
                    content += "\n\n\(detail)"
                }
                for block in message.toolDetails.content {
                    content += "\n\n\(block.text)"
                }
                sections.append(content)
            }
            return sections.joined(separator: "\n\n")
        }.joined(separator: "\n\n---\n\n") + "\n"
    }
}
