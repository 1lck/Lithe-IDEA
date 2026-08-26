import Foundation
import LitheCoreContracts
import LitheModuleAPI

@MainActor
public final class BundledLanguageExecutionModule: LitheModule {
    public let manifest: ModuleManifest
    private let languageID: String
    private let executionHost: (any LanguageExecutionHostProviding)?
    private var capability: BundledLanguageExecutionCapability?

    public init(
        languageID: String,
        executionHost: (any LanguageExecutionHostProviding)?
    ) {
        self.languageID = languageID
        self.executionHost = executionHost
        manifest = BundledLanguagePluginCatalog.manifests
            .flatMap(\.modules)
            .first { $0.manifest.id == .languageExecutionExtension(languageID) }!
            .manifest
    }

    public func activate(context: ModuleContext) async throws {
        guard let executionHost else {
            throw LanguageExtensionHostError.missingExecutionHost(languageID: languageID)
        }
        let resource = BundledLanguageExecutionResource(
            executionHost: executionHost,
            ownerModuleID: manifest.id,
            leases: context.leases,
            events: context.events
        )
        context.resources.register(resource)
        capability = BundledLanguageExecutionCapability(
            languageID: languageID,
            sessionFactory: { resource.makeSession() }
        )
    }

    public func prepareForSleep() async throws {}
    public func sleep() async { capability = nil }
    public func shutdown() async { capability = nil }

    public func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] {
        capability.map {
            [
                .languageExecutionExtension(languageID): $0,
                .languageTestingExtension(languageID): $0
            ]
        } ?? [:]
    }
}

@MainActor
public final class BundledLanguageExecutionCapability: NSObject,
    LanguageRunExtensionProviding,
    LanguageTestExtensionProviding {
    public let languageID: String
    private let sessionFactory: @MainActor () -> any LanguageExecutionSession

    init(
        languageID: String,
        sessionFactory: @escaping @MainActor () -> any LanguageExecutionSession
    ) {
        self.languageID = languageID
        self.sessionFactory = sessionFactory
    }

    public func makeExecutionSession() -> any LanguageExecutionSession { sessionFactory() }
    public func makeTestExecutionSession() -> any LanguageExecutionSession { sessionFactory() }

    public func launchPlan(for request: LanguageRunExtensionRequest) throws -> LanguageRunExtensionPlan {
        let path = try Self.checkedPath(request.relativeFilePath)
        switch languageID {
        case "python":
            return LanguageRunExtensionPlan(executable: .toolchain("project-python"), arguments: [path] + request.arguments, environment: request.environment)
        case "node":
            let toolchain = path.hasSuffix(".ts") || path.hasSuffix(".tsx") ? "project-tsx" : "project-node"
            return LanguageRunExtensionPlan(executable: .toolchain(toolchain), arguments: [path] + request.arguments, environment: request.environment)
        case "rust":
            return LanguageRunExtensionPlan(executable: .toolchain("project-cargo"), arguments: ["run"] + request.arguments, environment: request.environment)
        default:
            throw LanguageTestExtensionError.unsupportedProject(languageID: languageID)
        }
    }

    public func discoverTests(for request: LanguageTestExtensionDiscoveryRequest) throws -> [LanguageTestExtensionItem] {
        let paths = try request.relativeProjectFilePaths.map(Self.checkedPath)
        guard supportsProject(paths) else { return [] }
        let files = paths.filter(isTestFile).sorted().map {
            LanguageTestExtensionItem(id: "\(languageID):file:\($0)", label: $0, kind: .file, relativeFilePath: $0)
        }
        return [LanguageTestExtensionItem(id: "\(languageID):workspace", label: "All \(languageID) Tests", kind: .workspace)] + files
    }

    public func testPlan(for request: LanguageTestExtensionRequest) throws -> LanguageTestExtensionPlan {
        let paths = try request.relativeProjectFilePaths.map(Self.checkedPath)
        guard supportsProject(paths) else {
            throw LanguageTestExtensionError.unsupportedProject(languageID: languageID)
        }
        let selectedPath: String? = switch request.scope {
        case .workspace: nil
        case .file(let path): try Self.checkedPath(path)
        case .testCase(_, let path): try path.map(Self.checkedPath)
        }
        switch languageID {
        case "python":
            return testPlan(label: selectedPath ?? "All Python Tests", framework: "pytest", executable: .toolchain("project-python"), arguments: ["-m", "pytest"] + (selectedPath.map { [$0] } ?? []))
        case "node":
            return testPlan(label: selectedPath ?? "All Node.js Tests", framework: "npm", executable: .command("npm"), arguments: ["test"] + (selectedPath.map { ["--", $0] } ?? []))
        case "rust":
            return testPlan(label: selectedPath ?? "All Rust Tests", framework: "cargo", executable: .toolchain("project-cargo"), arguments: ["test"])
        default:
            throw LanguageTestExtensionError.unsupportedProject(languageID: languageID)
        }
    }

    private func testPlan(
        label: String,
        framework: String,
        executable: LanguageRunExtensionExecutable,
        arguments: [String]
    ) -> LanguageTestExtensionPlan {
        LanguageTestExtensionPlan(label: label, frameworkID: framework, launchPlan: LanguageRunExtensionPlan(executable: executable, arguments: arguments))
    }

    private func supportsProject(_ paths: [String]) -> Bool {
        let names = Set(paths.map { $0.split(separator: "/").last.map(String.init)?.lowercased() ?? "" })
        switch languageID {
        case "python": return !names.isDisjoint(with: ["pyproject.toml", "pytest.ini", "setup.cfg", "tox.ini"])
        case "node": return names.contains("package.json")
        case "rust": return names.contains("cargo.toml")
        default: return false
        }
    }

    private func isTestFile(_ path: String) -> Bool {
        let name = path.split(separator: "/").last.map(String.init)?.lowercased() ?? ""
        switch languageID {
        case "python": return name.hasPrefix("test_") && name.hasSuffix(".py") || name.hasSuffix("_test.py")
        case "node": return name.contains(".test.") || name.contains(".spec.")
        case "rust": return path.lowercased().contains("/tests/") || name.hasSuffix("_test.rs")
        default: return false
        }
    }

    private static func checkedPath(_ value: String) throws -> String {
        let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
            throw LanguageTestExtensionError.invalidRelativePath
        }
        return path
    }
}

@MainActor
private final class BundledLanguageExecutionResource: ModuleResource {
    let moduleResourceKind = "language-execution-process"
    private let executionHost: any LanguageExecutionHostProviding
    private let ownerModuleID: ModuleID
    private let leases: any ModuleLeaseManaging
    private let events: any ModuleEventPublishing
    private var sessions: [BundledOwnedExecutionSession] = []

    init(executionHost: any LanguageExecutionHostProviding, ownerModuleID: ModuleID, leases: any ModuleLeaseManaging, events: any ModuleEventPublishing) {
        self.executionHost = executionHost
        self.ownerModuleID = ownerModuleID
        self.leases = leases
        self.events = events
    }

    var isModuleResourceActive: Bool { sessions.contains(where: \.isRunning) }

    func makeSession() -> any LanguageExecutionSession {
        let session = BundledOwnedExecutionSession(
            underlying: executionHost.makeSession(ownerModuleID: ownerModuleID),
            ownerModuleID: ownerModuleID,
            leases: leases,
            events: events
        )
        sessions.append(session)
        return session
    }

    func stopModuleResource() async {
        for session in sessions where session.isRunning { _ = await session.stopAndWait() }
        sessions.removeAll { !$0.isRunning }
    }
}

@MainActor
private final class BundledOwnedExecutionSession: LanguageExecutionSession {
    var isRunning: Bool { underlying.isRunning }
    var onOutput: (@Sendable (String) -> Void)?
    var onTermination: (@Sendable (Int32) -> Void)?
    var onStateChange: (@Sendable (LanguageExecutionLifecycleEvent) -> Void)?
    private let underlying: any LanguageExecutionSession
    private let ownerModuleID: ModuleID
    private let leases: any ModuleLeaseManaging
    private let events: any ModuleEventPublishing
    private var lease: ModuleLease?

    init(underlying: any LanguageExecutionSession, ownerModuleID: ModuleID, leases: any ModuleLeaseManaging, events: any ModuleEventPublishing) {
        self.underlying = underlying
        self.ownerModuleID = ownerModuleID
        self.leases = leases
        self.events = events
    }

    func start(_ request: LanguageExecutionProcessRequest) throws {
        lease = leases.acquireLease(reason: "Language execution")
        events.publish(ModuleEvent(source: ownerModuleID, name: ModuleEvent.activityStartedName))
        underlying.onOutput = onOutput
        underlying.onStateChange = onStateChange
        let termination = onTermination
        underlying.onTermination = { [weak self] code in
            Task { @MainActor in self?.finish(); termination?(code) }
        }
        do { try underlying.start(request) } catch { finish(); throw error }
    }

    func stop() { underlying.stop(); finish() }
    func stopAndWait() async -> Bool { let stopped = await underlying.stopAndWait(); if stopped { finish() }; return stopped }

    private func finish() {
        guard let lease else { return }
        lease.release()
        self.lease = nil
        events.publish(ModuleEvent(source: ownerModuleID, name: ModuleEvent.activityEndedName))
    }
}
