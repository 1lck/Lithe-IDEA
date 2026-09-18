// Real PHP integration: exercises the shared provider catalog, the language
// tooling manager, the PhpSupport plugin's run/test plans, and a real
// process-owning Rust Core with real external tools. Disabled by default; run
// explicitly with:
//
//   scripts/build-rust-core.sh --debug --target aarch64-apple-darwin
//
//   cd .artifacts/phpunit-project && composer install    # once, provisions PHPUnit
//
//   LITHE_RUN_PHP_INTEGRATION=1 \
//   LITHE_INTELEPHENSE_PATH="$HOME/.bun/bin/intelephense" \
//   swift test --disable-sandbox --no-parallel \
//     --triple arm64-apple-macosx \
//     -Xswiftc -Xfrontend -Xswiftc -disable-round-trip-debug-types \
//     -Xlinker -force_load \
//     -Xlinker "$(pwd)/rust/target/macos/aarch64-apple-darwin/debug/liblithe_core.a" \
//     --filter RealPhpIntegrationTests
//
// `scripts/test-macos.sh` performs the same `-force_load` step when
// LITHE_RUN_PHP_INTEGRATION=1 is set, which is also how the stability harness
// times this suite. Intel macOS needs the target/triple and library path swapped
// to x86_64.
//
// -force_load is required: the test bundle also contains the C bridge's weak
// fallback, so a normal link can succeed without the Rust archive loaded.
import Foundation
import LitheApplicationKernel
import LitheCoreContracts
import LitheLanguageIntelligenceModule
import LitheModuleAPI
import LithePhpSupportModule
import Testing
@testable import Lithe

@Suite("Real PHP integration", .serialized)
@MainActor
struct RealPhpIntegrationTests {
    @Test
    func intelephenseRunsThroughLanguageToolingSessionManager() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LITHE_RUN_PHP_INTEGRATION"] == "1" else { return }

        let intelephenseURL = URL(fileURLWithPath: environment["LITHE_INTELEPHENSE_PATH"]
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".bun/bin/intelephense").path)
        #expect(FileManager.default.isExecutableFile(atPath: intelephenseURL.path))
        guard FileManager.default.isExecutableFile(atPath: intelephenseURL.path) else { return }

        let core = RustCoreBridge()
        #expect(core.isAvailable)
        guard core.isAvailable else { return }

        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lithe-real-php-\(UUID().uuidString)",
            isDirectory: true
        )
        // Intelephense keeps its symbol index outside the workspace. Point it at a
        // temporary directory so a run never touches the user's own index and every
        // run starts from a cold, reproducible state.
        let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(rootURL.lastPathComponent)-intelephense-cache",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
            try? FileManager.default.removeItem(at: cacheURL)
        }

        let sourceURL = rootURL.appendingPathComponent("index.php")
        let source = """
        <?php

        declare(strict_types=1);

        function greet(string $name): string
        {
            return strtoupper($name);
        }

        $value = str
        """
        try #"{"name":"example/api","require":{"php":"^8.2"}}"#
            .write(to: rootURL.appendingPathComponent("composer.json"), atomically: true, encoding: .utf8)
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)

        // The descriptor comes from the Rust-embedded provider catalog, so this
        // asserts the launch contract the application actually ships: intelephense
        // only speaks LSP over stdio, and a bare launch exits instead of serving.
        let descriptor = try #require(LanguageProviderCatalog.standard.provider(for: sourceURL))
        #expect(descriptor.id == "php")
        let launch = try #require(descriptor.languageServerLaunch)
        #expect(launch.executableNames == ["intelephense"])
        #expect(launch.arguments == ["--stdio"])

        let session = StdioLanguageServerSession(
            providerID: descriptor.id,
            executableURL: intelephenseURL,
            arguments: launch.arguments,
            environment: environment,
            initializationOptions: .object(["storagePath": .string(cacheURL.path)]),
            cacheDirectoryURL: cacheURL,
            initializeTimeout: 60,
            requestTimeout: 60,
            shutdownTimeout: 5,
            core: core
        )
        let runtime = RealPhpLanguageRuntime(descriptor: descriptor, session: session)
        let manager = LanguageToolingSessionManager(
            catalog: LanguageProviderCatalog(descriptors: [descriptor]),
            runtimes: [runtime],
            builtinCore: core
        )
        defer { manager.stopAll() }

        try manager.synchronizeLanguageServer(
            for: sourceURL,
            text: source,
            rootURL: rootURL
        )
        let initialized = await awaitChange(on: manager, timeout: .seconds(60)) {
            manager.languageServerFeatures["php"]?.contains(.completion) == true
                && manager.languageServerFeatures["php"]?.contains(.hover) == true
        }
        #expect(initialized, "intelephense did not publish completion and hover in time")
        guard initialized else { return }

        let completionItems = try await Self.completions(
            manager,
            sourceURL: sourceURL,
            text: source,
            position: LanguageServerPosition(line: 9, utf16Column: 12),
            rootURL: rootURL
        )
        #expect(!completionItems.isEmpty)
        #expect(completionItems.contains { $0.label.hasPrefix("str") })

        let hover = try await Self.hover(
            manager,
            sourceURL: sourceURL,
            text: source,
            position: LanguageServerPosition(line: 6, utf16Column: 11),
            rootURL: rootURL
        )
        #expect(hover?.contents.isEmpty == false)

        manager.closeDocument(sourceURL)
        manager.stopLanguageServer(providerID: "php")
        let terminated = await Self.awaitSessionTermination(session)
        #expect(terminated, "intelephense did not terminate its process after the session stopped")
        #expect(manager.languageServerStates["php"] == .stopped)
    }

    @Test
    func phpUnitTestPlanRunsInARealComposerProject() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LITHE_RUN_PHP_INTEGRATION"] == "1" else { return }

        let projectURL = URL(
            fileURLWithPath: environment["LITHE_PHP_TEST_PROJECT"]
                ?? Self.repositoryRoot.appendingPathComponent(".artifacts/phpunit-project").path,
            isDirectory: true
        )
        let fileManager = FileManager.default
        #expect(fileManager.isExecutableFile(atPath: projectURL.appendingPathComponent("vendor/bin/phpunit").path))
        guard fileManager.isExecutableFile(atPath: projectURL.appendingPathComponent("vendor/bin/phpunit").path) else {
            return
        }
        let phpURL = try #require(
            Self.executableOnPath("php", environment: environment),
            "The real PHPUnit test needs `php` on PATH."
        )

        let processRegistry = ManagedProcessRegistry()
        let executionHost = MacLanguageExecutionHost(processRegistry: processRegistry)
        let runtime = ModuleRuntime()
        let workspace = BuiltInModuleCatalog.manifest(for: .workspace)!
        try runtime.register(ModuleFactory(manifest: workspace) {
            PhpIntegrationWorkspaceModule(manifest: workspace)
        })
        try runtime.register(ModuleFactory(manifest: PhpExecutionModule.moduleManifest) {
            PhpExecutionModule(executionHost: executionHost)
        })
        try await runtime.setEnabled(true, for: .languageExecutionExtension("php"))

        let capability = try #require(
            try await runtime.activateCapability(.languageExecutionExtension("php"))
                as? any LanguageTestExtensionProviding
        )

        let projectFiles = ["composer.json", "phpunit.xml", "src/Store.php", "tests/StoreTest.php"]
        let items = try capability.discoverTests(for: LanguageTestExtensionDiscoveryRequest(
            relativeProjectFilePaths: projectFiles
        ))
        #expect(items.map(\.id) == [
            "php:workspace",
            "php:file:tests/StoreTest.php"
        ])

        // A single test case is the strongest scope: it exercises the `--filter`
        // expression and the file argument against the real PHPUnit CLI. The
        // fixture deliberately contains a second method sharing the same prefix,
        // so running exactly one test proves the filter is precise rather than a
        // bare substring match.
        let casePlan = try capability.testPlan(for: LanguageTestExtensionRequest(
            scope: .testCase(
                identifier: "testKeepsInsertionOrder",
                relativeFilePath: "tests/StoreTest.php"
            ),
            relativeProjectFilePaths: projectFiles
        ))
        #expect(casePlan.frameworkID == "phpunit")
        #expect(casePlan.launchPlan.executable == .command("php"))
        #expect(casePlan.launchPlan.arguments == [
            "vendor/bin/phpunit", "--filter", "\\btestKeepsInsertionOrder\\b", "tests/StoreTest.php"
        ])
        #expect(casePlan.launchPlan.workingDirectory == ".")

        let singleCase = await Self.runPhpUnit(
            capability,
            plan: casePlan,
            projectURL: projectURL,
            phpURL: phpURL
        )
        #expect(singleCase.exitCode == 0, "PHPUnit did not report success.\n\(singleCase.output)")
        #expect(
            singleCase.output.contains("OK (1 test"),
            "PHPUnit ran the wrong number of tests.\n\(singleCase.output)"
        )
        #expect(!singleCase.isRunning)

        // The workspace scope is the default "All PHP Tests" action.
        let workspacePlan = try capability.testPlan(for: LanguageTestExtensionRequest(
            scope: .workspace,
            relativeProjectFilePaths: projectFiles
        ))
        let allTests = await Self.runPhpUnit(
            capability,
            plan: workspacePlan,
            projectURL: projectURL,
            phpURL: phpURL
        )
        #expect(allTests.exitCode == 0, "PHPUnit did not report success.\n\(allTests.output)")
        #expect(
            allTests.output.contains("OK (2 tests"),
            "PHPUnit did not run the whole suite.\n\(allTests.output)"
        )

        // Disabling the module is both the cleanup path and an assertion that the
        // plugin owns no live process once its test runs have finished.
        try await runtime.setEnabled(false, for: .languageExecutionExtension("php"))
        #expect(try runtime.snapshot(for: .languageExecutionExtension("php")).state == .disabled)
    }

    private static func runPhpUnit(
        _ capability: any LanguageTestExtensionProviding,
        plan: LanguageTestExtensionPlan,
        projectURL: URL,
        phpURL: URL
    ) async -> (exitCode: Int32?, output: String, isRunning: Bool) {
        let session = capability.makeTestExecutionSession()
        let output = PhpProcessOutput()
        session.onOutput = { chunk in output.append(chunk) }
        // The plan reports its working directory relative to the workspace root,
        // which the run feature resolves before starting the process.
        let exitCode = await runToCompletion(session, LanguageExecutionProcessRequest(
            operationID: "php-phpunit-e2e",
            executablePath: phpURL.path,
            arguments: plan.launchPlan.arguments,
            workingDirectory: projectURL.path
        ))
        return (exitCode, output.text, session.isRunning)
    }

    private static func completions(
        _ manager: LanguageToolingSessionManager,
        sourceURL: URL,
        text: String,
        position: LanguageServerPosition,
        rootURL: URL
    ) async throws -> [LanguageServerCompletionItem] {
        try await result { completion in
            try manager.completions(
                fileURL: sourceURL,
                text: text,
                position: position,
                rootURL: rootURL,
                completion: completion
            )
        }
    }

    private static func hover(
        _ manager: LanguageToolingSessionManager,
        sourceURL: URL,
        text: String,
        position: LanguageServerPosition,
        rootURL: URL
    ) async throws -> LanguageServerHover? {
        try await result { completion in
            try manager.hover(
                fileURL: sourceURL,
                text: text,
                position: position,
                rootURL: rootURL,
                completion: completion
            )
        }
    }

    /// Language requests are only delivered through their completion handler, so
    /// the continuation is resumed exactly once by production code and never by a
    /// timer. This cannot dangle on a live server: the Rust runtime session owns a
    /// per-request deadline (`requestTimeout` above) and fails every pending
    /// operation when it expires or when the session stops.
    private static func result<T: Sendable>(
        _ start: (@escaping (Result<T, Error>) -> Void) throws -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try start { continuation.resume(with: $0) }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Runs an owned process to completion and returns its exit code. The session
    /// reports termination through a callback, so the continuation is resumed by
    /// production code; the local timer only bounds how long a stuck process may
    /// hold the runner, and its `nil` result fails the calling assertion.
    private static func runToCompletion(
        _ session: any LanguageExecutionSession,
        _ request: LanguageExecutionProcessRequest,
        timeout: DispatchTimeInterval = .seconds(120)
    ) async -> Int32? {
        await withCheckedContinuation { continuation in
            let resumption = PhpSingleResumption<Int32?>(continuation)
            session.onTermination = { exitCode in resumption.finish(exitCode) }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { resumption.finish(nil) }
            do {
                try session.start(request)
            } catch {
                Issue.record("Could not start the PHPUnit process: \(error)")
                resumption.finish(nil)
            }
        }
    }

    /// Waits for the session to publish a terminal state. `isRunning` is derived
    /// from the last lifecycle state Rust published, and the manager already owns
    /// `onStateChange`, so the test handler is chained in front of it and restored
    /// afterwards. A local timer bounds the wait, so a session that never stops
    /// fails this assertion instead of stalling the runner.
    private static func awaitSessionTermination(
        _ session: any LanguageServerSession,
        timeout: DispatchTimeInterval = .seconds(30)
    ) async -> Bool {
        if !session.isRunning { return true }
        let previous = session.onStateChange
        defer { session.onStateChange = previous }
        return await withCheckedContinuation { continuation in
            let resumption = PhpSingleResumption<Bool>(continuation)
            session.onStateChange = { state in
                previous?(state)
                switch state {
                case .stopped, .failed: resumption.finish(true)
                default: break
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                resumption.finish(false)
            }
        }
    }

    /// Resolves a bare command the same way the run feature does for
    /// `SharedLaunchPlan.Executable.command`, which is a PATH lookup.
    private static func executableOnPath(
        _ command: String,
        environment: [String: String]
    ) -> URL? {
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

@MainActor
private final class RealPhpLanguageRuntime: LanguageProviderRuntime {
    let descriptor: LanguageProviderDescriptor
    let supportsLanguageServerSession = true
    private let session: any LanguageServerSession

    init(descriptor: LanguageProviderDescriptor, session: any LanguageServerSession) {
        self.descriptor = descriptor
        self.session = session
    }

    func makeLanguageServerSession() -> (any LanguageServerSession)? { session }
}

@MainActor
private final class PhpIntegrationWorkspaceModule: LitheModule {
    let manifest: ModuleManifest
    private var capability: PhpIntegrationWorkspaceCapability?

    init(manifest: ModuleManifest) { self.manifest = manifest }
    func activate(context _: ModuleContext) async throws {
        capability = PhpIntegrationWorkspaceCapability()
    }
    func prepareForSleep() async throws {}
    func sleep() async { capability = nil }
    func shutdown() async { capability = nil }
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] {
        capability.map { [.workspaceFoundation: $0] } ?? [:]
    }
}

private final class PhpIntegrationWorkspaceCapability {}

/// Collects process output for failure diagnostics. The output callback is
/// `@Sendable` and fires while the test is awaiting termination.
private final class PhpProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [String] = []

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return chunks.joined()
    }

    func append(_ chunk: String) {
        lock.lock()
        defer { lock.unlock() }
        chunks.append(chunk)
    }
}

/// Guards a continuation against the arms of a bounded wait, which may race for a
/// continuation that must only be resumed once. The lock keeps that contract
/// explicit even if a callback ever arrives off the main thread.
private final class PhpSingleResumption<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func finish(_ value: Value) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}
