import Foundation
import LitheCoreContracts
import LitheLanguageIntelligenceModule
import Testing
@testable import Lithe

@Suite("Language server tool service")
@MainActor
struct LanguageServerToolServiceTests {
    @Test
    func customExecutablePersistsAndOverridesAutomaticDiscovery() async throws {
        let customURL = URL(fileURLWithPath: "/custom/bin/gopls")
        let brewURL = URL(fileURLWithPath: "/opt/homebrew/bin/gopls")
        let store = LanguageServerToolTestStore()
        let runtime = makeRuntime(
            executablePaths: [customURL.path, brewURL.path],
            candidates: [
                "gopls": [RuntimeToolCandidate(
                    command: "gopls",
                    executableURL: brewURL,
                    source: .homebrew
                )]
            ],
            store: store
        )
        let descriptor = goDescriptor()
        let service = LanguageServerToolService(
            runtimeService: runtime,
            commandRunner: LanguageServerToolTestProcessRunner(),
            settingsStore: store
        )

        try await service.setCustomExecutablePath(customURL.path, for: descriptor)
        #expect(service.executableURL(for: descriptor) == customURL)
        #expect(service.candidates(for: descriptor).map(\.source) == [.custom, .homebrew])

        let restored = LanguageServerToolService(
            runtimeService: runtime,
            commandRunner: LanguageServerToolTestProcessRunner(),
            settingsStore: store
        )
        #expect(restored.customExecutablePath(for: descriptor.id) == customURL.path)
        restored.clearCustomExecutablePath(for: descriptor.id)
        #expect(restored.executableURL(for: descriptor) == brewURL)
    }

    @Test
    func rejectsNonExecutableCustomPath() async {
        let store = LanguageServerToolTestStore()
        let service = LanguageServerToolService(
            runtimeService: makeRuntime(executablePaths: [], candidates: [:], store: store),
            commandRunner: LanguageServerToolTestProcessRunner(),
            settingsStore: store
        )

        await #expect(throws: LanguageServerToolConfigurationError.executableInvalid("/missing/gopls")) {
            try await service.setCustomExecutablePath("/missing/gopls", for: goDescriptor())
        }
    }

    @Test
    func rejectsBrokenProxyAndFallsBackToHomebrewCandidate() async {
        let proxyURL = URL(fileURLWithPath: "/Users/test/.cargo/bin/rust-analyzer")
        let brewURL = URL(fileURLWithPath: "/opt/homebrew/bin/rust-analyzer")
        let runner = LanguageServerToolTestProcessRunner(resultsByExecutablePath: [
            proxyURL.path: ProcessResult(
                output: "error: Unknown binary 'rust-analyzer' in official toolchain",
                exitCode: 1
            ),
            brewURL.path: ProcessResult(output: "rust-analyzer 1.0.0", exitCode: 0)
        ])
        let store = LanguageServerToolTestStore()
        let service = LanguageServerToolService(
            runtimeService: makeRuntime(
                executablePaths: [proxyURL.path, brewURL.path],
                candidates: [
                    "rust-analyzer": [
                        RuntimeToolCandidate(
                            command: "rust-analyzer",
                            executableURL: proxyURL,
                            source: .path
                        ),
                        RuntimeToolCandidate(
                            command: "rust-analyzer",
                            executableURL: brewURL,
                            source: .homebrew
                        )
                    ]
                ],
                store: store
            ),
            commandRunner: runner,
            settingsStore: store
        )

        let candidates = await service.refreshCandidates(for: rustDescriptor())

        #expect(candidates.map(\.executableURL) == [brewURL])
        #expect(service.executableURL(for: rustDescriptor()) == brewURL)
        #expect(runner.requests.count == 2)
        #expect(runner.requests.allSatisfy { $0.arguments == ["--version"] })
    }

    @Test
    func rejectsCustomExecutableThatFailsCatalogValidation() async {
        let proxyURL = URL(fileURLWithPath: "/Users/test/.cargo/bin/rust-analyzer")
        let store = LanguageServerToolTestStore()
        let runner = LanguageServerToolTestProcessRunner(resultsByExecutablePath: [
            proxyURL.path: ProcessResult(output: "unknown rustup proxy", exitCode: 1)
        ])
        let service = LanguageServerToolService(
            runtimeService: makeRuntime(
                executablePaths: [proxyURL.path],
                candidates: [:],
                store: store
            ),
            commandRunner: runner,
            settingsStore: store
        )

        await #expect(throws: LanguageServerToolConfigurationError.executableValidationFailed(
            path: proxyURL.path,
            message: "unknown rustup proxy"
        )) {
            try await service.setCustomExecutablePath(proxyURL.path, for: rustDescriptor())
        }
    }

    @Test
    func reportsFoundButUnverifiedWhenCatalogHasNoValidationCommand() {
        let executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/gopls")
        let store = LanguageServerToolTestStore()
        let runner = LanguageServerToolTestProcessRunner()
        let service = LanguageServerToolService(
            runtimeService: makeRuntime(
                executablePaths: [executableURL.path],
                candidates: [
                    "gopls": [RuntimeToolCandidate(
                        command: "gopls",
                        executableURL: executableURL,
                        source: .homebrew
                    )]
                ],
                store: store
            ),
            commandRunner: runner,
            settingsStore: store
        )

        #expect(service.executableVerificationState(for: goDescriptor()) == .foundUnverified)
        #expect(runner.requests.isEmpty)
    }

    @Test
    func reportsExecutableVerifiedOnlyAfterValidationCommandSucceeds() async {
        let executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/rust-analyzer")
        let store = LanguageServerToolTestStore()
        let runner = LanguageServerToolTestProcessRunner(
            result: ProcessResult(output: "rust-analyzer 1.0.0", exitCode: 0)
        )
        let service = LanguageServerToolService(
            runtimeService: makeRuntime(
                executablePaths: [executableURL.path],
                candidates: [
                    "rust-analyzer": [RuntimeToolCandidate(
                        command: "rust-analyzer",
                        executableURL: executableURL,
                        source: .homebrew
                    )]
                ],
                store: store
            ),
            commandRunner: runner,
            settingsStore: store
        )

        #expect(service.executableVerificationState(for: rustDescriptor()) == .unavailable)
        await service.refreshCandidates(for: rustDescriptor())
        #expect(service.executableVerificationState(for: rustDescriptor()) == .executableVerified)
        #expect(runner.requests.count == 1)
        #expect(runner.requests.first?.arguments == ["--version"])
    }

    @Test
    func installsVerifiedFormulaWithArgumentBasedProcessRequest() async throws {
        let brewURL = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        let store = LanguageServerToolTestStore()
        let runner = LanguageServerToolTestProcessRunner(
            result: ProcessResult(output: "installed gopls", exitCode: 0)
        )
        let runtime = makeRuntime(
            executablePaths: [brewURL.path],
            candidates: [
                "brew": [RuntimeToolCandidate(
                    command: "brew",
                    executableURL: brewURL,
                    source: .homebrew
                )]
            ],
            store: store
        )
        let service = LanguageServerToolService(
            runtimeService: runtime,
            commandRunner: runner,
            settingsStore: store
        )

        await service.installWithHomebrew(goDescriptor())

        let request = try #require(runner.lastRequest)
        #expect(request.executablePath == brewURL.path)
        #expect(request.arguments == ["install", "gopls"])
        #expect(service.installationState(for: "go") == .installed("installed gopls"))
    }

    @Test
    func installationCatalogUsesOfficialFallbacks() {
        let go = LanguageServerInstallPlan.plan(for: goDescriptor())
        #expect(go.homebrewFormula == "gopls")
        #expect(go.officialDownloadURL?.host == "go.dev")

        let swift = LanguageServerInstallPlan.plan(for: LanguageProviderDescriptor(
            id: "swift",
            displayName: "Swift",
            fileExtensions: ["swift"],
            capabilities: [.languageServer],
            activationPolicy: .onDemand,
            languageServerInstallation: LanguageServerInstallationDescriptor(
                homebrewFormula: nil,
                officialDownloadURL: URL(string: "https://github.com/swiftlang/sourcekit-lsp")
            )
        ))
        #expect(swift.homebrewFormula == nil)
        #expect(swift.officialDownloadURL?.host == "github.com")
    }

    @Test
    func installationCatalogRejectsUnsafeExecutableMetadata() {
        let descriptor = LanguageProviderDescriptor(
            id: "unsafe",
            displayName: "Unsafe",
            fileExtensions: ["unsafe"],
            capabilities: [.languageServer],
            activationPolicy: .onDemand,
            languageServerInstallation: LanguageServerInstallationDescriptor(
                homebrewFormula: "../../bin/tool",
                officialDownloadURL: URL(string: "http://example.com/tool")
            )
        )

        let plan = LanguageServerInstallPlan.plan(for: descriptor)
        #expect(plan.homebrewFormula == nil)
        #expect(plan.officialDownloadURL == nil)
    }

    private func goDescriptor() -> LanguageProviderDescriptor {
        LanguageProviderDescriptor(
            id: "go",
            displayName: "Go",
            fileExtensions: ["go"],
            capabilities: [.languageServer],
            activationPolicy: .onDemand,
            languageIdentifier: "go",
            languageServerLaunch: LanguageServerLaunchDescriptor(
                executableNames: ["gopls"],
                arguments: []
            ),
            languageServerInstallation: LanguageServerInstallationDescriptor(
                homebrewFormula: "gopls",
                officialDownloadURL: URL(string: "https://go.dev/gopls/")
            )
        )
    }

    private func rustDescriptor() -> LanguageProviderDescriptor {
        LanguageProviderDescriptor(
            id: "rust",
            displayName: "Rust",
            fileExtensions: ["rs"],
            capabilities: [.languageServer],
            activationPolicy: .onDemand,
            languageIdentifier: "rust",
            languageServerLaunch: LanguageServerLaunchDescriptor(
                executableNames: ["rust-analyzer"],
                validationArguments: ["--version"]
            ),
            languageServerInstallation: LanguageServerInstallationDescriptor(
                homebrewFormula: "rust-analyzer",
                officialDownloadURL: URL(string: "https://rust-analyzer.github.io/manual.html#installation")
            )
        )
    }

    private func makeRuntime(
        executablePaths: Set<String>,
        candidates: [String: [RuntimeToolCandidate]],
        store: any KeyValueStore
    ) -> ProjectRuntimeService {
        ProjectRuntimeService(
            runtimeLocator: LanguageServerToolTestRuntimeLocator(executablePaths: executablePaths),
            store: store,
            toolDiscovery: LanguageServerToolTestDiscovery(candidatesByCommand: candidates)
        )
    }
}

private struct LanguageServerToolTestRuntimeLocator: RuntimeLocator {
    let executablePaths: Set<String>

    func environment() -> [String: String] { ["PATH": ""] }
    func discover() -> RuntimeDiscoveryResult { RuntimeDiscoveryResult(javaRuntimes: [], mavenRuntimes: []) }
    func validJavaHome(path _: String) -> URL? { nil }
    func javaRuntime(at _: URL) -> JavaRuntimeCandidate? { nil }
    func isExecutable(at url: URL) -> Bool { executablePaths.contains(url.standardizedFileURL.path) }
    func systemMavenExecutable() -> URL? { nil }
    func mavenExecutable(forHomePath _: String) -> URL? { nil }
    func mavenRuntime(at _: URL) -> MavenRuntimeCandidate? { nil }
    func systemJDBExecutable() -> URL? { nil }
}

private struct LanguageServerToolTestDiscovery: RuntimeToolDiscovery {
    let candidatesByCommand: [String: [RuntimeToolCandidate]]

    func candidates(
        for command: String,
        projectURL _: URL?,
        environment _: [String: String]
    ) -> [RuntimeToolCandidate] {
        candidatesByCommand[command] ?? []
    }

    func guidance(
        for command: String,
        projectURL _: URL?,
        environment _: [String: String]
    ) -> RuntimeToolGuidance {
        RuntimeToolGuidance(
            command: command,
            summary: "Missing \(command).",
            recovery: "Install it."
        )
    }
}

private final class LanguageServerToolTestProcessRunner: ProcessRunner, LanguageToolCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let result: ProcessResult
    private let resultsByExecutablePath: [String: ProcessResult]
    private var recordedRequests: [ProcessRequest] = []

    init(
        result: ProcessResult = ProcessResult(output: "", exitCode: 0),
        resultsByExecutablePath: [String: ProcessResult] = [:]
    ) {
        self.result = result
        self.resultsByExecutablePath = resultsByExecutablePath
    }

    var lastRequest: ProcessRequest? {
        lock.withLock { recordedRequests.last }
    }

    var requests: [ProcessRequest] {
        lock.withLock { recordedRequests }
    }

    func run(_ request: ProcessRequest) -> ProcessResult {
        lock.withLock { recordedRequests.append(request) }
        return resultsByExecutablePath[request.executablePath] ?? result
    }

    func runLanguageToolCommand(
        operationID: String,
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        timeoutMilliseconds: Int
    ) -> LanguageToolCommandResult {
        let result = run(ProcessRequest(
            operationID: operationID,
            executablePath: executableURL.path,
            arguments: arguments,
            environment: environment,
            timeoutMilliseconds: timeoutMilliseconds
        ))
        return LanguageToolCommandResult(output: result.output, exitCode: result.exitCode)
    }
}

private final class LanguageServerToolTestStore: KeyValueStore, LanguageToolSettingsStoring {
    private static let languageToolKey = "lithe.language-server-tools.executable-paths"
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }

    func loadLanguageToolExecutablePaths() -> [String: String] {
        guard let data = data(forKey: Self.languageToolKey) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    func saveLanguageToolExecutablePaths(_ paths: [String: String]) {
        set(try? JSONEncoder().encode(paths), forKey: Self.languageToolKey)
    }
}
