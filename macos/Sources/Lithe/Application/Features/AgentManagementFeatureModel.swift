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
    @Published private(set) var cliUpdates: [String: AgentCliUpdateResult] = [:]

    @Published private(set) var installProgress: AgentInstallProgress?
    @Published private(set) var isCancelling = false
    private(set) var operationStartedAt: Date?
    private var operationID: UUID?

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
        run(agentID) { service, directory, progress in
            _ = try await service.install(agentID: agentID, dataDirectory: directory, onProgress: progress)
            return nil
        }
    }

    func uninstall(_ agentID: String) {
        run(agentID) { service, directory, _ in
            try await service.uninstall(agentID: agentID, dataDirectory: directory)
            return nil
        }
    }

    /// Update through the verified installation owner and retain warning diagnostics.
    func installCli(_ agentID: String) {
        run(agentID) { service, directory, progress in
            try await service.installCli(agentID: agentID, dataDirectory: directory, onProgress: progress)
        }
    }

    /// Stops a running npm install; the previous install stays intact.
    func cancelOperation() {
        guard operation != nil else { return }
        isCancelling = true
        operation?.cancel()
    }

    private func run(
        _ agentID: String,
        _ work: @escaping @Sendable (any AgentManagementService, URL, @escaping @Sendable (AgentInstallProgress) -> Void) async throws -> AgentCliUpdateResult?
    ) {
        guard busyAgentID == nil else { return }
        let id = UUID()
        operationID = id
        operationStartedAt = Date()
        installProgress = nil
        isCancelling = false
        busyAgentID = agentID
        errors[agentID] = nil
        cliUpdates[agentID] = nil
        let service = service
        let directory = dataDirectory
        operation = Task { [weak self] in
            do {
                let result = try await work(service, directory) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.operationID == id, !self.isCancelling else { return }
                        self.installProgress = progress
                    }
                }
                if !Task.isCancelled { self?.cliUpdates[agentID] = result }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { self?.errors[agentID] = error.localizedDescription }
            }
            self?.operationID = nil
            self?.installProgress = nil
            self?.operationStartedAt = nil
            self?.isCancelling = false
            self?.busyAgentID = nil
            self?.operation = nil
            await self?.refresh()
        }
    }
}
