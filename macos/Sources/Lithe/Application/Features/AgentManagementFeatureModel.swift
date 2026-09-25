import Foundation
import LitheCoreContracts

/// State of Settings › Agents: runtime detection and adapter installs.
///
/// Nothing runs until the page asks for a refresh, so users who never open it
/// pay no detection or process cost.
@MainActor
final class AgentManagementFeatureModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status: AgentManagementStatus?
    /// Agent whose adapter is being installed or removed.
    @Published private(set) var busyAgentID: String?
    /// Last install or removal failure per agent.
    @Published private(set) var errors: [String: String] = [:]

    private let service: any AgentManagementService
    private let dataDirectory: URL
    private var operation: Task<Void, Never>?

    init(service: any AgentManagementService, dataDirectory: URL) {
        self.service = service
        self.dataDirectory = dataDirectory
    }

    func refresh() async {
        guard phase != .checking else { return }
        phase = .checking
        do {
            status = try await service.status(dataDirectory: dataDirectory)
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func install(_ agentID: String) {
        run(agentID) { service, directory in
            _ = try await service.install(agentID: agentID, dataDirectory: directory)
        }
    }

    func uninstall(_ agentID: String) {
        run(agentID) { service, directory in
            try await service.uninstall(agentID: agentID, dataDirectory: directory)
        }
    }

    /// Stops a running npm install; the previous install stays intact.
    func cancelOperation() {
        operation?.cancel()
    }

    private func run(
        _ agentID: String,
        _ work: @escaping @Sendable (any AgentManagementService, URL) async throws -> Void
    ) {
        guard busyAgentID == nil else { return }
        busyAgentID = agentID
        errors[agentID] = nil
        let service = service
        let directory = dataDirectory
        operation = Task { [weak self] in
            do {
                try await work(service, directory)
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { self?.errors[agentID] = error.localizedDescription }
            }
            self?.busyAgentID = nil
            self?.operation = nil
            await self?.refresh()
        }
    }
}
