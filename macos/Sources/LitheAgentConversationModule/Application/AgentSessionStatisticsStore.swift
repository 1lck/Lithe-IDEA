import Foundation
import LitheCoreContracts

/// Session statistics that outlive a connection, for one workspace and Agent.
/// Loading a session from history starts from its record, and every finished
/// turn writes the new totals back. Statistics are optional: without a
/// persistence port, scope or a readable document they start from zero as before.
@MainActor
final class AgentSessionStatisticsStore {
    /// Agents keep far more history than anyone reopens; the oldest records go first.
    static let maximumSessions = 200

    private let persistence: any AgentSessionStatisticsPersisting
    private let agentID: String
    /// The workspace can be bound after the module is created.
    private let workspaceURL: () -> URL?
    private let currentDate: () -> Date
    private var loaded: (workspaceURL: URL, records: [String: AgentSessionStatisticsRecord])?

    init(persistence: any AgentSessionStatisticsPersisting, agentID: String,
         workspaceURL: @escaping () -> URL?, currentDate: @escaping () -> Date = Date.init) {
        self.persistence = persistence
        self.agentID = agentID
        self.workspaceURL = workspaceURL
        self.currentDate = currentDate
    }

    func record(for sessionID: String) -> AgentSessionStatisticsRecord? {
        records()?[sessionID]
    }

    /// Saves the conversation's totals when they changed; empty sessions are not stored.
    func save(_ conversation: AgentConversation, sessionID: String) {
        guard let workspaceURL = workspaceURL(), var records = records() else { return }
        let record = conversation.statisticsRecord(at: currentDate())
        guard !record.isEmpty, records[sessionID].map({ !$0.hasSameTotals(as: record) }) ?? true else { return }
        records[sessionID] = record
        if records.count > Self.maximumSessions {
            let oldest = records.sorted { ($0.value.updatedAt, $0.key) < ($1.value.updatedAt, $1.key) }
                .prefix(records.count - Self.maximumSessions).map(\.key)
            for id in oldest { records[id] = nil }
        }
        loaded = (workspaceURL, records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(records) else { return }
        persistence.saveStatistics(data, workspaceURL: workspaceURL, agentID: agentID)
    }

    private func records() -> [String: AgentSessionStatisticsRecord]? {
        guard let workspaceURL = workspaceURL() else { return nil }
        if let loaded, loaded.workspaceURL == workspaceURL { return loaded.records }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        // An unreadable document is replaced by the next save rather than blocking the panel.
        let records = persistence.loadStatistics(workspaceURL: workspaceURL, agentID: agentID)
            .flatMap { try? decoder.decode([String: AgentSessionStatisticsRecord].self, from: $0) } ?? [:]
        loaded = (workspaceURL, records)
        return records
    }
}
