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
    func managedProcessLaunchPreservesArgumentsEnvironmentAndProcessID() throws {
        let transport = TestTransport()
        let feature = TerminalFeatureModel(terminalFactory: { transport })
        let launch = TerminalProcessLaunch(
            title: "Debug Main",
            executablePath: "/opt/jdk/bin/java",
            arguments: ["-cp", "/workspace/classes", "example.Main"],
            workingDirectory: "/workspace",
            environmentChanges: [
                TerminalEnvironmentChange(name: "JAVA_HOME", value: "/opt/jdk"),
                TerminalEnvironmentChange(name: "REMOVE_ME", value: nil)
            ]
        )

        let created = try feature.createProcessSession(launch)

        #expect(created.processID == 1234)
        #expect(created.session.isManagedProcess)
        #expect(created.session.displayTitle == "Debug Main")
        #expect(transport.processLaunches == [launch])
        #expect(transport.processEnvironments.first?["JAVA_HOME"] == "/opt/jdk")
        #expect(transport.processEnvironments.first?["REMOVE_ME"] == nil)
        #expect(transport.processEnvironments.first?["TERM_PROGRAM"] == "Lithe")
        created.session.restart()
        #expect(transport.processLaunches.count == 1)

        feature.stopAllSessions()
        #expect(transport.stopCount == 1)
    }

    @Test
    func managedProcessForwardsInputToItsOwnPTY() throws {
        let transport = TestTransport()
        let feature = TerminalFeatureModel(terminalFactory: { transport })
        let launch = TerminalProcessLaunch(
            title: "Debug Main",
            executablePath: "/opt/jdk/bin/java",
            arguments: ["example.Main"],
            workingDirectory: "/workspace"
        )
        let created = try feature.createProcessSession(launch)

        #expect(feature.sendInput("username\n", to: created.session.id))
        #expect(transport.sentInputs == ["username\n"])

        created.session.stop()
        #expect(!feature.sendInput("late\n", to: created.session.id))
        feature.stopAllSessions()
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
    var processID: Int32? { isRunning ? 1234 : nil }
    var shellName = "Shell"
    var onTermination: ((Int32?) -> Void)?
    var onTitle: ((String) -> Void)?
    var onDirectoryUpdate: ((String?) -> Void)?
    var onLink: ((String, [String: String]) -> Void)?
    var stopCount = 0
    var processLaunches: [TerminalProcessLaunch] = []
    var processEnvironments: [[String: String]] = []
    var sentInputs: [String] = []
    func defaultShellPath() -> String { "/bin/zsh" }
    func defaultEnvironment() -> [String: String] { ["REMOVE_ME": "old"] }
    func start(workingDirectory: String, shellPath: String, environment: [String: String]) throws { isRunning = true }
    func startProcess(
        _ launch: TerminalProcessLaunch,
        environment: [String: String]
    ) throws -> Int32 {
        processLaunches.append(launch)
        processEnvironments.append(environment)
        isRunning = true
        return 1234
    }
    func send(_ input: Data) throws {
        sentInputs.append(String(decoding: input, as: UTF8.self))
    }
    func interrupt() throws {}
    func focus() {}
    func clear() {}
    func stop() { if isRunning { stopCount += 1 }; isRunning = false }
}
