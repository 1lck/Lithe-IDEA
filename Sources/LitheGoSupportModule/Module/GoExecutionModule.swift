import LitheCoreContracts
import LitheModuleAPI

@MainActor
public final class GoExecutionModule: LitheModule {
    public static let moduleManifest = OfficialPluginCatalog.moduleManifest(
        for: .languageExecutionExtension(goLanguageID)
    )!

    public let manifest = moduleManifest
    private let executionHost: (any LanguageExecutionHostProviding)?
    private var capability: GoExecutionCapability?

    public init(executionHost: (any LanguageExecutionHostProviding)? = nil) {
        self.executionHost = executionHost
    }

    public func activate(context: ModuleContext) async throws {
        guard let executionHost else {
            throw LanguageExtensionHostError.missingExecutionHost(languageID: goLanguageID)
        }
        let sessions = GoExecutionResource(
            executionHost: executionHost,
            ownerModuleID: manifest.id,
            leases: context.leases,
            events: context.events
        )
        context.resources.register(sessions)
        capability = GoExecutionCapability(sessionFactory: { sessions.makeSession() })
    }

    public func prepareForSleep() async throws {}
    public func sleep() async { releaseCapability() }
    public func shutdown() async { releaseCapability() }

    public func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] {
        capability.map {
            [
                .languageExecutionExtension(goLanguageID): $0,
                .languageTestingExtension(goLanguageID): $0
            ]
        } ?? [:]
    }

    private func releaseCapability() {
        capability = nil
    }
}

@MainActor
private final class GoExecutionResource: ModuleResource {
    let moduleResourceKind = "language-execution-process"
    private let executionHost: any LanguageExecutionHostProviding
    private let ownerModuleID: ModuleID
    private let leases: any ModuleLeaseManaging
    private let events: any ModuleEventPublishing
    private var sessions: [any LanguageExecutionSession] = []
    private var failedStopCount = 0

    init(
        executionHost: any LanguageExecutionHostProviding,
        ownerModuleID: ModuleID,
        leases: any ModuleLeaseManaging,
        events: any ModuleEventPublishing
    ) {
        self.executionHost = executionHost
        self.ownerModuleID = ownerModuleID
        self.leases = leases
        self.events = events
    }

    var isModuleResourceActive: Bool {
        failedStopCount > 0 || sessions.contains(where: \.isRunning)
    }

    func makeSession() -> any LanguageExecutionSession {
        let session = GoOwnedExecutionSession(
            underlying: executionHost.makeSession(ownerModuleID: ownerModuleID),
            ownerModuleID: ownerModuleID,
            leases: leases,
            events: events
        )
        sessions.append(session)
        return session
    }

    func stopModuleResource() async {
        failedStopCount = 0
        for session in sessions where session.isRunning {
            if !(await session.stopAndWait()) {
                failedStopCount += 1
            }
        }
        if failedStopCount == 0 {
            sessions.removeAll()
        }
    }
}

@MainActor
private final class GoOwnedExecutionSession: LanguageExecutionSession {
    var isRunning: Bool { underlying.isRunning }
    var onOutput: (@Sendable (String) -> Void)?
    var onTermination: (@Sendable (Int32) -> Void)?
    var onStateChange: (@Sendable (LanguageExecutionLifecycleEvent) -> Void)?

    private let underlying: any LanguageExecutionSession
    private let ownerModuleID: ModuleID
    private let leases: any ModuleLeaseManaging
    private let events: any ModuleEventPublishing
    private var activityLease: ModuleLease?

    init(
        underlying: any LanguageExecutionSession,
        ownerModuleID: ModuleID,
        leases: any ModuleLeaseManaging,
        events: any ModuleEventPublishing
    ) {
        self.underlying = underlying
        self.ownerModuleID = ownerModuleID
        self.leases = leases
        self.events = events
    }

    func start(_ request: LanguageExecutionProcessRequest) throws {
        beginActivity(operationID: request.operationID)
        installCallbacks()
        do {
            try underlying.start(request)
        } catch {
            endActivity()
            throw error
        }
    }

    func stop() {
        underlying.stop()
        endActivity()
    }

    func stopAndWait() async -> Bool {
        let stopped = await underlying.stopAndWait()
        if stopped { endActivity() }
        return stopped
    }

    private func installCallbacks() {
        let output = onOutput
        underlying.onOutput = { chunk in output?(chunk) }

        let termination = onTermination
        underlying.onTermination = { [weak self] exitCode in
            Task { @MainActor in
                self?.endActivity()
                termination?(exitCode)
            }
        }

        let stateChange = onStateChange
        underlying.onStateChange = { event in stateChange?(event) }
    }

    private func beginActivity(operationID: String?) {
        guard activityLease == nil else { return }
        let detail = operationID.map { "Language execution \($0)" } ?? "Language execution"
        activityLease = leases.acquireLease(reason: detail)
        events.publish(ModuleEvent(source: ownerModuleID, name: ModuleEvent.activityStartedName))
    }

    private func endActivity() {
        guard let activityLease else { return }
        activityLease.release()
        self.activityLease = nil
        events.publish(ModuleEvent(source: ownerModuleID, name: ModuleEvent.activityEndedName))
    }
}
