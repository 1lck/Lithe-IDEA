import Foundation
import LitheTerminalModule
import Testing

@MainActor
struct TerminalModuleTests {
    @Test
    func explicitlyChosenShellNamesToolTabsWithoutRenamingDefaultSessions() {
        let feature = TerminalFeatureModel(terminalFactory: { TestTransport() })
        defer { feature.stopAllSessions() }
        let workspace = URL(fileURLWithPath: "/workspace")
        let local = feature.createSession(in: workspace, shellPath: "/bin/zsh")
        let firstZsh = feature.createSession(in: workspace, shellPath: "/bin/zsh", preferredToolTabTitle: "zsh")
        let secondZsh = feature.createSession(in: workspace, shellPath: "/bin/zsh", preferredToolTabTitle: "zsh")
        let bash = feature.createSession(in: workspace, shellPath: "/bin/bash", preferredToolTabTitle: "bash")
        let sessions = feature.terminalSessions

        #expect(feature.toolTabTitle(for: local, orderedSessions: sessions) == "Local")
        #expect(feature.toolTabTitle(for: firstZsh, orderedSessions: sessions) == "zsh")
        #expect(feature.toolTabTitle(for: secondZsh, orderedSessions: sessions) == "zsh (2)")
        #expect(feature.toolTabTitle(for: bash, orderedSessions: sessions) == "bash")
    }

    @Test
    func unavailableShellReportsFailureAndCanRetryWithoutSelectingAnotherShell() {
        let transport = TestTransport()
        transport.startError = NSError(domain: "TerminalTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Shell is missing"])
        let session = TerminalSession(transport: transport)
        defer { session.stop() }
        session.start(in: URL(fileURLWithPath: "/workspace"), shellPath: "/tools/fish")
        #expect(session.launchError == "Shell is missing")
        #expect(!session.isRunning)
        transport.startError = nil
        session.restart()
        #expect(session.launchError == nil)
        #expect(session.isRunning)
        #expect(transport.shellStarts == ["/tools/fish", "/tools/fish"])
    }

    @Test
    func shellDiscoveryRefreshesOnlyOnRequestAndKeepsExistingSessions() {
        var detected = ["/bin/zsh"]
        var discoveryCount = 0
        var transports: [TestTransport] = []
        let feature = TerminalFeatureModel(terminalFactory: {
            let transport = TestTransport()
            transports.append(transport)
            return transport
        }, shellDiscovery: {
            discoveryCount += 1
            return detected
        })
        defer { feature.stopAllSessions() }
        let first = feature.createSession(in: URL(fileURLWithPath: "/workspace"), shellPath: "/bin/zsh")
        #expect(feature.availableShells == ["/bin/zsh"])
        #expect(feature.availableShells == ["/bin/zsh"])
        #expect(discoveryCount == 1)

        detected.append("/tools/fish")
        feature.refreshAvailableShells()
        #expect(feature.availableShells == ["/bin/zsh", "/tools/fish"])
        #expect(feature.terminalSessions.count == 1)
        #expect(feature.activeTerminalSessionID == first.id)
        let second = feature.createSession(in: URL(fileURLWithPath: "/workspace"), shellPath: "/tools/fish")
        #expect(feature.activeTerminalSessionID == second.id)
        #expect(first.isRunning)
        #expect(second.isRunning)
        #expect(transports.map(\.shellStarts) == [["/bin/zsh"], ["/tools/fish"]])
        #expect(transports.allSatisfy { $0.stopCount == 0 })
    }

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
    func workspaceShellDiscoveryRejectsStaleResultsAndDoesNotFallBackAfterFailure() async {
        let first = URL(fileURLWithPath: "/fixture/first")
        let second = URL(fileURLWithPath: "/fixture/second")
        let gate = AsyncStream<Void>.makeStream()
        var requested: [URL] = []
        let feature = TerminalFeatureModel(terminalFactory: { TestTransport() }, shellDiscovery: { ["/local/shell"] },
            workspaceShellDiscovery: { root in
                requested.append(root)
                if root == first {
                    var iterator = gate.stream.makeAsyncIterator()
                    _ = await iterator.next()
                    // Deliberately return a value after cancellation: the
                    // owning feature must reject the old host's completion.
                    return ["/first/shell"]
                }
                throw NSError(domain: "ShellFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture disconnected"])
            })
        defer { feature.stopAllSessions(); gate.continuation.finish() }
        feature.setShellWorkspace(first)
        #expect(feature.availableShells.isEmpty)
        #expect(await shellDiscoveryEventually { requested == [first] })
        feature.setShellWorkspace(second)
        #expect(await shellDiscoveryEventually { !feature.isDiscoveringShells })
        #expect(requested == [first, second])
        #expect(feature.availableShells.isEmpty)
        #expect(feature.shellDiscoveryError == "fixture disconnected")
        feature.setShellWorkspace(nil)
        #expect(feature.availableShells == ["/local/shell"])
        #expect(feature.shellDiscoveryError == nil)
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
    func interactiveShellEnvironmentExportsColorFgbgForLightBackground() throws {
        let transport = TestTransport()
        transport.reportsLightBackground = true
        let session = TerminalSession(transport: transport)
        defer { session.stop() }
        session.start(in: URL(fileURLWithPath: "/workspace"), shellPath: "/bin/zsh")

        #expect(session.isRunning)
        #expect(transport.shellEnvironments.first?["COLORFGBG"] == "0;15")
    }

    @Test
    func interactiveShellEnvironmentExportsColorFgbgForDarkBackground() throws {
        let transport = TestTransport()
        transport.reportsLightBackground = false
        let session = TerminalSession(transport: transport)
        defer { session.stop() }
        session.start(in: URL(fileURLWithPath: "/workspace"), shellPath: "/bin/zsh")

        #expect(session.isRunning)
        #expect(transport.shellEnvironments.first?["COLORFGBG"] == "15;0")
    }

    @Test
    func interactiveShellEnvironmentOmitsColorFgbgWhenHostCannotTell() throws {
        let transport = TestTransport()
        let session = TerminalSession(transport: transport)
        defer { session.stop() }
        session.start(in: URL(fileURLWithPath: "/workspace"), shellPath: "/bin/zsh")

        #expect(session.isRunning)
        #expect(transport.shellEnvironments.first?["COLORFGBG"] == nil)
    }

    @Test
    func createSessionAppliesWallpaperStateBeforeSpawn() throws {
        let transport = TestTransport()
        transport.reportsLightBackground = true
        let feature = TerminalFeatureModel(terminalFactory: { transport })
        defer { feature.stopAllSessions() }
        let session = feature.createSession(
            in: URL(fileURLWithPath: "/workspace"),
            shellPath: "/bin/zsh",
            showsWorkbenchBackground: true
        )
        defer { session.stop() }

        #expect(transport.shellEnvironments.first?["COLORFGBG"] == "15;0")
    }

    @Test
    func interactiveShellEnvironmentClearsInheritedColorFgbgWhenHostCannotTell() throws {
        let transport = TestTransport()
        transport.inheritedEnvironment["COLORFGBG"] = "7;0"
        let session = TerminalSession(transport: transport)
        defer { session.stop() }
        session.start(in: URL(fileURLWithPath: "/workspace"), shellPath: "/bin/zsh")

        #expect(session.isRunning)
        #expect(transport.shellEnvironments.first?["COLORFGBG"] == nil)
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

    @Test
    func processOutputIsForwardedBeforeAndAfterProcessStart() throws {
        let transport = TestTransport()
        transport.outputOnStart = "early\n"
        let feature = TerminalFeatureModel(terminalFactory: { transport })
        var output: [String] = []

        let created = try feature.createProcessSession(
            TerminalProcessLaunch(
                title: "Debug Main",
                executablePath: "/usr/bin/java",
                arguments: ["Main"],
                workingDirectory: "/tmp"
            ),
            onOutput: { output.append($0) }
        )
        transport.emitOutput("late\n")

        #expect(created.session.isRunning)
        #expect(output == ["early\n", "late\n"])
        feature.stopAllSessions()
    }

    @Test
    func processOutputPreservesUTF8ScalarsSplitAcrossTransportReads() throws {
        let transport = TestTransport()
        let feature = TerminalFeatureModel(terminalFactory: { transport })
        var output: [String] = []
        let created = try feature.createProcessSession(
            TerminalProcessLaunch(
                title: "Debug Main",
                executablePath: "/usr/bin/java",
                arguments: ["Main"],
                workingDirectory: "/tmp"
            ),
            onOutput: { output.append($0) }
        )

        for byte in Data("日志🙂\n".utf8) {
            transport.emitOutput(Data([byte]))
        }

        #expect(created.session.isRunning)
        #expect(output.joined() == "日志🙂\n")
        #expect(!output.joined().contains("�"))
        feature.stopAllSessions()
    }

    @Test
    func interactiveShellEnvironmentReportsTermProgramVersion() {
        let transport = TestTransport()
        transport.termProgramVersion = "9.9.9"
        let feature = TerminalFeatureModel(terminalFactory: { transport })
        defer { feature.stopAllSessions() }
        feature.createSession(in: URL(fileURLWithPath: "/workspace"), shellPath: "/bin/zsh")
        #expect(transport.shellEnvironments.last?["TERM_PROGRAM"] == "Lithe")
        #expect(transport.shellEnvironments.last?["TERM_PROGRAM_VERSION"] == "9.9.9")
    }

    @Test
    func interactiveShellEnvironmentOmitsUnknownTermProgramVersion() {
        let transport = TestTransport()
        let feature = TerminalFeatureModel(terminalFactory: { transport })
        defer { feature.stopAllSessions() }
        feature.createSession(in: URL(fileURLWithPath: "/workspace"), shellPath: "/bin/zsh")
        #expect(transport.shellEnvironments.last?["TERM_PROGRAM_VERSION"] == nil)
    }

    @Test
    func interactiveShellEnvironmentClearsInheritedTermProgramVersionWhenUnknown() {
        let transport = TestTransport()
        transport.inheritedEnvironment["TERM_PROGRAM_VERSION"] = "3.5.13"
        let feature = TerminalFeatureModel(terminalFactory: { transport })
        defer { feature.stopAllSessions() }
        feature.createSession(in: URL(fileURLWithPath: "/workspace"), shellPath: "/bin/zsh")
        #expect(transport.shellEnvironments.last?["TERM_PROGRAM_VERSION"] == nil)
    }

    @Test
    func shellExitNotifiesHostExactlyOnce() {
        let transport = TestTransport()
        let feature = TerminalFeatureModel(terminalFactory: { transport })
        defer { feature.stopAllSessions() }
        let session = feature.createSession(in: URL(fileURLWithPath: "/workspace"), shellPath: "/bin/zsh")
        var endedSessions: [TerminalSession] = []
        session.onEnded = { endedSessions.append($0) }

        transport.onTermination?(0)

        #expect(endedSessions.count == 1)
        #expect(endedSessions.first === session)
        #expect(!session.isRunning)
        #expect(session.lastExitCode == 0)
        feature.stopAllSessions()
        #expect(endedSessions.count == 1)
    }

    @Test
    func launchFailureAndRestartFailureKeepHostUnnotified() {
        let transport = TestTransport()
        let session = TerminalSession(transport: transport)
        var endedCount = 0
        session.onEnded = { _ in endedCount += 1 }

        transport.startError = CocoaError(.fileNoSuchFile)
        session.start(in: URL(fileURLWithPath: "/workspace"), shellPath: "/bin/zsh")
        #expect(session.launchError != nil)
        #expect(endedCount == 0)

        transport.startError = nil
        session.start(in: URL(fileURLWithPath: "/workspace"), shellPath: "/bin/zsh")
        #expect(session.isRunning)
        transport.startError = CocoaError(.fileNoSuchFile)
        session.restart()
        #expect(session.launchError != nil)
        #expect(endedCount == 0)
        session.stop()
        #expect(endedCount == 0)
    }
}

@MainActor
private func shellDiscoveryEventually(_ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        await Task.yield()
    }
    return true
}

@MainActor
private final class TestTransport: TerminalTransport {
    let nativeView: AnyObject = NSObject()
    var isRunning = false
    var processID: Int32? { isRunning ? 1234 : nil }
    var shellName = "Shell"
    var termProgramVersion: String?
    var shellStarts: [String] = []
    var shellEnvironments: [[String: String]] = []
    var reportsLightBackground: Bool?
    var inheritedEnvironment: [String: String] = ["REMOVE_ME": "old"]
    var startError: Error?
    var onTermination: ((Int32?) -> Void)?
    var onOutput: ((Data) -> Void)?
    var onTitle: ((String) -> Void)?
    var onDirectoryUpdate: ((String?) -> Void)?
    var onLink: ((String, [String: String]) -> Void)?
    var stopCount = 0
    var processLaunches: [TerminalProcessLaunch] = []
    var processEnvironments: [[String: String]] = []
    var sentInputs: [String] = []
    var outputOnStart: String?
    func configureInitialSurface(showsWorkbenchBackground: Bool) {
        if showsWorkbenchBackground { reportsLightBackground = false }
    }
    func defaultShellPath() -> String { "/bin/zsh" }
    func defaultEnvironment() -> [String: String] { inheritedEnvironment }
    func start(workingDirectory: String, shellPath: String, environment: [String: String]) throws {
        shellStarts.append(shellPath)
        shellEnvironments.append(environment)
        if let startError { throw startError }
        isRunning = true
    }
    func startProcess(
        _ launch: TerminalProcessLaunch,
        environment: [String: String]
    ) throws -> Int32 {
        processLaunches.append(launch)
        processEnvironments.append(environment)
        isRunning = true
        if let outputOnStart {
            onOutput?(Data(outputOnStart.utf8))
        }
        return 1234
    }
    func emitOutput(_ value: String) { onOutput?(Data(value.utf8)) }
    func emitOutput(_ data: Data) { onOutput?(data) }
    func send(_ input: Data) throws {
        sentInputs.append(String(decoding: input, as: UTF8.self))
    }
    func interrupt() throws {}
    func focus() {}
    func clear() {}
    func stop() { if isRunning { stopCount += 1 }; isRunning = false }
}
