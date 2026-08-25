import Foundation
import LitheLanguageIntelligenceModule
import Testing
@testable import Lithe

@Suite("Real gopls integration")
@MainActor
struct RealGoplsIntegrationTests {
    @Test
    func goplsRunsThroughLanguageToolingSessionManager() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LITHE_RUN_GOPLS_INTEGRATION"] == "1" else { return }

        let goplsURL = URL(fileURLWithPath: environment["LITHE_GOPLS_PATH"]
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".go/bin/gopls").path)
        #expect(FileManager.default.isExecutableFile(atPath: goplsURL.path))
        guard FileManager.default.isExecutableFile(atPath: goplsURL.path) else { return }

        let core = RustCoreBridge()
        #expect(core.isAvailable)
        guard core.isAvailable else { return }

        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-real-gopls-\(UUID().uuidString)", isDirectory: true)
        let sourceURL = rootURL.appendingPathComponent("main.go")
        let source = """
        package main

        import "fmt"

        func main() {
            fmt.Pr
        }

        """
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try "module example.com/lithegopls\n\ngo 1.24\n".write(
            to: rootURL.appendingPathComponent("go.mod"),
            atomically: true,
            encoding: .utf8
        )
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)

        let descriptor = LanguageProviderDescriptor(
            id: "go",
            displayName: "Go",
            fileExtensions: ["go"],
            capabilities: [.languageServer],
            activationPolicy: .onDemand,
            languageIdentifier: "go"
        )
        let session = StdioLanguageServerSession(
            providerID: descriptor.id,
            executableURL: goplsURL,
            arguments: [],
            environment: environment,
            core: core
        )
        let runtime = RealGoplsLanguageRuntime(descriptor: descriptor, session: session)
        let manager = LanguageToolingSessionManager(
            catalog: LanguageProviderCatalog(descriptors: [descriptor]),
            runtimes: [runtime],
            builtinCore: core
        )
        defer {
            manager.stopAll()
            try? FileManager.default.removeItem(at: rootURL)
        }

        try manager.synchronizeLanguageServer(
            for: sourceURL,
            text: source,
            rootURL: rootURL
        )
        let initialized = await waitUntil {
            manager.languageServerFeatures["go"]?.contains(.completion) == true
                && manager.languageServerFeatures["go"]?.contains(.hover) == true
        }
        #expect(initialized)
        guard initialized else { return }

        var completionResult: Result<[LanguageServerCompletionItem], Error>?
        try manager.completions(
            fileURL: sourceURL,
            text: source,
            position: LanguageServerPosition(line: 5, utf16Column: 10),
            rootURL: rootURL
        ) { completionResult = $0 }
        let completed = await waitUntil { completionResult != nil }
        #expect(completed)
        let resolvedCompletions = try #require(completionResult)
        let completionItems = try resolvedCompletions.get()
        #expect(!completionItems.isEmpty)
        #expect(completionItems.contains { $0.label.lowercased().contains("print") })

        var hoverResult: Result<LanguageServerHover?, Error>?
        try manager.hover(
            fileURL: sourceURL,
            text: source,
            position: LanguageServerPosition(line: 5, utf16Column: 5),
            rootURL: rootURL
        ) { hoverResult = $0 }
        let hovered = await waitUntil { hoverResult != nil }
        #expect(hovered)
        let resolvedHover = try #require(hoverResult)
        let hover = try resolvedHover.get()
        #expect(hover?.contents.isEmpty == false)

        manager.closeDocument(sourceURL)
        try manager.synchronizeLanguageServer(
            for: sourceURL,
            text: source,
            rootURL: rootURL
        )
        manager.stopLanguageServer(providerID: "go")
        let stopped = await waitUntil { !session.isRunning }
        #expect(stopped)
    }

    private func waitUntil(
        timeout: TimeInterval = 15,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }
}

@MainActor
private final class RealGoplsLanguageRuntime: LanguageProviderRuntime {
    let descriptor: LanguageProviderDescriptor
    let supportsLanguageServerSession = true
    private let session: any LanguageServerSession

    init(descriptor: LanguageProviderDescriptor, session: any LanguageServerSession) {
        self.descriptor = descriptor
        self.session = session
    }

    func makeLanguageServerSession() -> (any LanguageServerSession)? { session }
}
