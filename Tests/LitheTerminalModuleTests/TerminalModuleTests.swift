import Foundation
import LitheTerminalModule
import Testing

@MainActor
struct TerminalModuleTests {
    @Test
    func sessionOwnsTransportAndStopReleasesIt() {
        let transport = TestTransport()
        let feature = TerminalFeatureModel(terminalFactory: { transport })
        let session = feature.createSession(
            in: URL(fileURLWithPath: "/tmp/lithe-terminal-module-test"),
            shellPath: "/bin/zsh"
        )

        #expect(session.isRunning)
        #expect(ObjectIdentifier(session.nativeView) == ObjectIdentifier(transport.nativeView))
        feature.stopAllSessions()
        #expect(!transport.isRunning)
        #expect(transport.stopCount == 1)
        #expect(feature.terminalSessions.isEmpty)
    }

    @Test
    func linkResolverKeepsExternalURLsAndResolvesLocations() {
        let workspace = URL(fileURLWithPath: "/tmp/lithe-terminal-module-test")
        let expected = workspace.appendingPathComponent("Sources/App.swift").standardizedFileURL
        #expect(TerminalLinkResolver.resolve(
            "Sources/App.swift:12:4",
            relativeTo: workspace,
            fileExists: { $0 == expected }
        ) == .file(TerminalLinkLocation(url: expected, line: 12, column: 4)))
        #expect(TerminalLinkResolver.resolve(
            "https://example.com",
            relativeTo: workspace,
            fileExists: { _ in false }
        ) == .external(URL(string: "https://example.com")!))
    }
}

@MainActor
private final class TestTransport: TerminalTransport {
    let nativeView: AnyObject = NSObject()
    var isRunning = false
    var shellName = "Shell"
    var onTermination: ((Int32?) -> Void)?
    var onTitle: ((String) -> Void)?
    var onDirectoryUpdate: ((String?) -> Void)?
    var onLink: ((String, [String: String]) -> Void)?
    var stopCount = 0
    func defaultShellPath() -> String { "/bin/zsh" }
    func defaultEnvironment() -> [String: String] { [:] }
    func start(workingDirectory: String, shellPath: String, environment: [String: String]) throws { isRunning = true }
    func send(_ input: Data) throws {}
    func interrupt() throws {}
    func focus() {}
    func clear() {}
    func stop() { if isRunning { stopCount += 1 }; isRunning = false }
}
