import Foundation
import Testing
@testable import Lithe

@Suite("Language server tool service")
@MainActor
struct LanguageServerToolServiceTests {
    @Test
    func customExecutablePersistsAndOverridesAutomaticDiscovery() throws {
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
            processRunner: LanguageServerToolTestProcessRunner(),
            store: store
        )

        try service.setCustomExecutablePath(customURL.path, for: descriptor.id)
        #expect(service.executableURL(for: descriptor) == customURL)
        #expect(service.candidates(for: descriptor).map(\.source) == [.custom, .homebrew])

        let restored = LanguageServerToolService(
            runtimeService: runtime,
            processRunner: LanguageServerToolTestProcessRunner(),
            store: store
        )
        #expect(restored.customExecutablePath(for: descriptor.id) == customURL.path)
        restored.clearCustomExecutablePath(for: descriptor.id)
        #expect(restored.executableURL(for: descriptor) == brewURL)
    }

    @Test
    func rejectsNonExecutableCustomPath() {
        let store = LanguageServerToolTestStore()
        let service = LanguageServerToolService(
            runtimeService: makeRuntime(executablePaths: [], candidates: [:], store: store),
            processRunner: LanguageServerToolTestProcessRunner(),
            store: store
        )

        #expect(throws: LanguageServerToolConfigurationError.executableInvalid("/missing/gopls")) {
            try service.setCustomExecutablePath("/missing/gopls", for: "go")
        }
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
            processRunner: runner,
            store: store
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

private final class LanguageServerToolTestProcessRunner: ProcessRunner, @unchecked Sendable {
    private let lock = NSLock()
    private let result: ProcessResult
    private var recordedRequest: ProcessRequest?

    init(result: ProcessResult = ProcessResult(output: "", exitCode: 0)) {
        self.result = result
    }

    var lastRequest: ProcessRequest? {
        lock.withLock { recordedRequest }
    }

    func run(_ request: ProcessRequest) -> ProcessResult {
        lock.withLock { recordedRequest = request }
        return result
    }
}

private final class LanguageServerToolTestStore: KeyValueStore {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
