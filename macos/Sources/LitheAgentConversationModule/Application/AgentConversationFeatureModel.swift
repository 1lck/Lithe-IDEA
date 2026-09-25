import Combine
import Foundation
import LitheCoreContracts

/// An agent the user set up in Settings › Agents.
public struct AgentOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// The project's Agent panel: which agent is shown and one lazily created
/// connection per agent. Agents that were never selected start no process.
@MainActor
public final class AgentConversationFeatureModel: ObservableObject {
    @Published public private(set) var agents: [AgentOption] = []
    @Published public private(set) var selectedAgentID: String?

    /// Called when any agent starts or stops waiting for a permission decision.
    public var onAttentionChanged: ((Bool) -> Void)?

    private let transport: any AgentConversationTransport
    private var connections: [String: AgentConnectionModel] = [:]
    private var attention: Set<String> = []

    public init(transport: any AgentConversationTransport) {
        self.transport = transport
    }

    public var hasActiveConnection: Bool { connections.values.contains { $0.hasActiveConnection } }

    /// Connection model of the selected agent, created on first use.
    public var selectedConnection: AgentConnectionModel? {
        selectedAgentID.map(connection(for:))
    }

    /// Replace the configured agents, keeping the selection when still present.
    public func setAgents(_ agents: [AgentOption]) {
        self.agents = agents
        if selectedAgentID.map({ id in !agents.contains { $0.id == id } }) ?? true {
            selectedAgentID = agents.first?.id
        }
    }

    public func selectAgent(_ agentID: String) {
        guard agents.contains(where: { $0.id == agentID }) else { return }
        selectedAgentID = agentID
    }

    public func connection(for agentID: String) -> AgentConnectionModel {
        if let existing = connections[agentID] { return existing }
        let model = AgentConnectionModel(transport: transport)
        model.onAttentionChanged = { [weak self] needsAttention in
            self?.updateAttention(agentID, needsAttention)
        }
        connections[agentID] = model
        return model
    }

    /// Stop every agent of this project and wait for their processes to exit.
    public func stop() async {
        for connection in connections.values {
            await connection.stop()
        }
    }

    private func updateAttention(_ agentID: String, _ needsAttention: Bool) {
        let before = !attention.isEmpty
        if needsAttention {
            attention.insert(agentID)
        } else {
            attention.remove(agentID)
        }
        if before != !attention.isEmpty {
            onAttentionChanged?(!attention.isEmpty)
        }
    }
}
