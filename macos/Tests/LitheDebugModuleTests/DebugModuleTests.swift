import Foundation
import LitheApplicationKernel
import LitheCoreContracts
@testable import LitheDebugModule
import LitheModuleAPI
import Testing

@MainActor
struct DebugModuleTests {
    @Test
    func explicitHotUpdateRestartReplacesTheOriginalSessionWithNewRuntimePaths() async {
        let session = DeferredInspectionDebugSession()
        let feature = makeDeferredFeature(session: session, rootPath: "/workspace/hot-update-restart")
        defer { feature.stop() }
        feature.registerJavaUpdateTarget(JavaDebugLaunchTarget(mainClass: "example.Main", projectName: "app"))
        let previousID = feature.activeSessionID
        await feature.restartJavaService { _, _ in
            JavaDebugLaunchTarget(mainClass: "example.Main", projectName: "app", classPaths: ["/workspace/new-output"])
        }
        #expect(feature.activeSessionID != previousID)
        #expect(session.startCount == 2)
        #expect(session.launchConfigurations.last?.arguments["classPaths"] == .array([.string("/workspace/new-output")]))
        #expect(feature.canUpdateJavaService)
    }

    /// A host that registers debug adapters while it runs hands back its current
    /// set on each lookup, so a debugger installed later is found without
    /// rebuilding the manager.
    @Test
    func providerLookupFollowsTheProvidersSourceAtEveryCall() {
        var providers: [DebugProviderDescriptor] = []
        let manager = DebugAdapterSessionManager(providersSource: { providers }) { _, _ in nil }
        let source = URL(fileURLWithPath: "/workspace/main.c")

        #expect(manager.provider(for: source) == nil)

        providers = [DebugProviderDescriptor(id: "clangd", displayName: "C/C++", fileExtensions: ["c"])]
        #expect(manager.provider(for: source)?.id == "clangd")

        providers = []
        #expect(manager.provider(for: source) == nil)
    }

    @Test
    func hotUpdateRestartKeepsOtherDebugSessionsAlive() async throws {
        let descriptor = DebugProviderDescriptor(id: "java", displayName: "Java", fileExtensions: ["java"])
        var createdSessions: [DeferredInspectionDebugSession] = []
        let manager = DebugAdapterSessionManager(providers: [descriptor]) { _, _ in
            let session = DeferredInspectionDebugSession()
            createdSessions.append(session)
            return session
        }
        let feature = GenericDebugFeatureModel(sessions: manager)
        defer { feature.reset() }
        let root = URL(fileURLWithPath: "/workspace/hot-update-multiple", isDirectory: true)
        let source = root.appendingPathComponent("src/Main.java")
        let configuration = DebugLaunchConfiguration(
            name: "Main", request: .launch, arguments: ["mainClass": .string("example.Main")]
        )
        #expect(feature.start(fileURL: source, rootURL: root, configuration: configuration))
        let firstID = try #require(feature.activeSessionID)
        #expect(feature.startAdditional(fileURL: source, rootURL: root, configuration: configuration))
        feature.registerJavaUpdateTarget(JavaDebugLaunchTarget(mainClass: "example.Main", projectName: "app"))
        await feature.restartJavaService { _, _ in JavaDebugLaunchTarget(mainClass: "example.Main", projectName: "app") }
        #expect(createdSessions.count == 3)
        #expect(createdSessions[0].isRunning)
        #expect(!createdSessions[1].isRunning)
        #expect(feature.sessionSummaries.contains { $0.id == firstID })
        #expect(feature.sessionSummaries.count == 2)
    }

    /// A plugin that goes away ends its own sessions. Another plugin's session
    /// of the same language, which a language-keyed stop would also end, keeps
    /// running.
    @Test
    func stoppingSessionsByOwnerLeavesOtherSessionsOfTheSameLanguageRunning() throws {
        let descriptor = DebugProviderDescriptor(id: "zig", displayName: "Zig", fileExtensions: ["zig"])
        var createdSessions: [DeferredInspectionDebugSession] = []
        let manager = DebugAdapterSessionManager(providers: [descriptor]) { _, _ in
            let session = DeferredInspectionDebugSession()
            createdSessions.append(session)
            return session
        }
        let feature = GenericDebugFeatureModel(sessions: manager)
        defer { feature.reset() }
        let root = URL(fileURLWithPath: "/workspace/owned-sessions", isDirectory: true)
        let source = root.appendingPathComponent("src/main.zig")
        let configuration = DebugLaunchConfiguration(name: "main", request: .launch, arguments: [:])
        #expect(feature.start(fileURL: source, rootURL: root, configuration: configuration))
        #expect(feature.startAdditional(fileURL: source, rootURL: root, configuration: configuration))
        #expect(createdSessions.count == 2)
        #expect(createdSessions[0].isRunning)
        #expect(createdSessions[1].isRunning)
        let withdrawn = createdSessions[0]

        manager.stopSessions { $0 === withdrawn }

        #expect(!withdrawn.isRunning)
        #expect(createdSessions[1].isRunning)
        #expect(feature.sessionSummaries.count == 1)
    }

    @Test
    func hotUpdateBuildFailureNeverTouchesRunningClasses() async {
        let session = DeferredInspectionDebugSession()
        let feature = makeDeferredFeature(session: session, rootPath: "/workspace/hot-update")
        defer { feature.stop() }
        feature.registerJavaUpdateTarget(JavaDebugLaunchTarget(
            mainClass: "example.Main", projectName: "app", classPaths: ["/workspace/hot-update/bin"]
        ))
        await feature.applyJavaServiceUpdate { _, _, _ in
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Compilation errors"])
        }
        #expect(session.redefineCount == 0)
        #expect(feature.serviceUpdateMessage?.contains("Compilation errors") == true)
        #expect(feature.updatingServiceSessionID == nil)
    }

    @Test
    func hotUpdateStopsBeforeApplyingWhenExecutionEndsDuringBuild() async {
        let session = DeferredInspectionDebugSession()
        let feature = makeDeferredFeature(session: session, rootPath: "/workspace/hot-update-stop")
        defer { feature.stop() }
        feature.registerJavaUpdateTarget(JavaDebugLaunchTarget(mainClass: "example.Main", projectName: "app"))
        await feature.applyJavaServiceUpdate { _, _, _ in feature.stop() }
        #expect(session.redefineCount == 0)
        #expect(feature.serviceUpdateMessage == nil)
    }

    @Test
    func hotUpdateAppliesAfterBuildAndDoesNotResumeExecution() async {
        let session = DeferredInspectionDebugSession()
        let feature = makeDeferredFeature(session: session, rootPath: "/workspace/hot-update-success")
        defer { feature.stop() }
        feature.registerJavaUpdateTarget(JavaDebugLaunchTarget(mainClass: "example.Main", projectName: "app"))
        var built = false
        await feature.applyJavaServiceUpdate { target, source, root in
            #expect(target.mainClass == "example.Main")
            #expect(source == root.appendingPathComponent("src/Main.java"))
            #expect(session.redefineCount == 0)
            built = true
        }
        #expect(built)
        #expect(session.redefineCount == 1)
        #expect(session.executionCommands.isEmpty)
        #expect(feature.serviceUpdateMessage == "Code changes applied.")
    }

    @Test
    func debuggeeOutputPreservesSGRButDiscardsTerminalControlSequences() {
        let manager = DebugAdapterSessionManager(providers: []) { _, _ in nil }
        let feature = GenericDebugFeatureModel(sessions: manager)

        feature.appendDebuggeeOutput("\u{001B}[2J\u{001B}[31mready\u{001B}[0m\u{001B}]0;title\u{0007}\r\n")

        #expect(feature.output == "\u{001B}[31mready\u{001B}[0m\n")
    }

    @Test
    func debuggeeOutputNormalizationPreservesStateAcrossOutputChunks() {
        let manager = DebugAdapterSessionManager(providers: []) { _, _ in nil }
        let feature = GenericDebugFeatureModel(sessions: manager)

        feature.appendDebuggeeOutput("\u{001B}")
        feature.appendDebuggeeOutput("[31mready\u{001B}[0m\r")
        feature.appendDebuggeeOutput("\nnext\n")

        #expect(feature.output == "\u{001B}[31mready\u{001B}[0m\nnext\n")
    }

    @Test(arguments: [false, true], [8, 72])
    func boundedConsoleOutputPreservesSGRAcrossChunksAndSessions(background: Bool, padding: Int) throws {
        var adapters: [DeferredInspectionDebugSession] = []
        let manager = DebugAdapterSessionManager(providers: [
            DebugProviderDescriptor(id: "java", displayName: "Java", fileExtensions: ["java"])
        ]) { _, _ in
            let adapter = DeferredInspectionDebugSession()
            adapters.append(adapter)
            return adapter
        }
        let feature = GenericDebugFeatureModel(sessions: manager)
        defer { feature.reset() }
        let root = URL(fileURLWithPath: "/workspace/bounded-output")
        let source = root.appendingPathComponent("Main.java")
        let configuration = DebugLaunchConfiguration(name: "Main", request: .launch, arguments: [:])
        #expect(feature.start(fileURL: source, rootURL: root, configuration: configuration))
        let first = try #require(feature.activeSessionID)
        if background { #expect(feature.startAdditional(fileURL: source, rootURL: root, configuration: configuration)) }
        func emit(_ text: String) { adapters[0].emit(.output(category: "stdout", output: text)) }
        emit(String(repeating: "x", count: padding))
        emit("\u{001B}[3")
        emit("1m")
        // Exercise both the old cut (10) and the reserved-prefix cut (74) inside SGR.
        emit(String(repeating: "y", count: 400_010 - padding - "\u{001B}[31m".count))
        if background { #expect(feature.selectSession(first)) }
        #expect(feature.output.count <= 400_000)
        #expect(feature.output.hasPrefix("\u{001B}[0;31m"))
        #expect(feature.output.dropFirst("\u{001B}[0;31m".count).allSatisfy { $0 == "y" })
    }

    @Test(arguments: ["31", "38;5;196", "38;2;4;5;6"])
    func boundedConsoleOutputRebuildsCombinedColorsAndHonorsResets(foreground: String) {
        let feature = GenericDebugFeatureModel(sessions: DebugAdapterSessionManager(providers: []) { _, _ in nil })
        defer { feature.reset() }
        feature.appendDebuggeeOutput("\u{001B}[\(foreground)m\u{001B}[1m\u{001B}[48;2;1;2;3m" + String(repeating: "🙂", count: 400_000))
        #expect(feature.output.count <= 400_000)
        #expect(feature.output.hasPrefix("\u{001B}[0;1;\(foreground);48;2;1;2;3m"))
        feature.appendDebuggeeOutput("\u{001B}[22;39;49m" + String(repeating: "z", count: 400_000))
        #expect(feature.output.count <= 400_000)
        #expect(feature.output.allSatisfy { $0 == "z" })
        feature.clearOutput()
        feature.appendDebuggeeOutput(String(repeating: "🙂", count: 400_010))
        #expect(feature.output == String(repeating: "🙂", count: 400_000))
    }

    @Test
    func debuggeeOutputRejectsOversizedOrPrivateCSIAndPreservesFollowingText() {
        let manager = DebugAdapterSessionManager(providers: []) { _, _ in nil }
        let feature = GenericDebugFeatureModel(sessions: manager)
        feature.appendDebuggeeOutput("\u{001B}[" + String(repeating: "1;", count: 100))
        feature.appendDebuggeeOutput("mtext\u{001B}[?25mvisible\u{001B}[36mcyan\u{001B}[0m")
        #expect(feature.output == "textvisible\u{001B}[36mcyan\u{001B}[0m")
    }

    @Test
    func debugConsolePresentationCoalescesChattyOutputUntilOneFlush() {
        let manager = DebugAdapterSessionManager(providers: []) { _, _ in nil }
        let feature = GenericDebugFeatureModel(sessions: manager)

        feature.appendDebuggeeOutput("first")
        feature.appendDebuggeeOutput(" second")

        #expect(feature.output == "first second")
        #expect(feature.hasOutput)
        #expect(feature.outputPresentation.text.isEmpty)
        feature.outputPresentation.flush()
        #expect(feature.outputPresentation.text == "first second")
    }

    @Test
    func clearingDebugOutputDiscardsAPendingPresentationBatch() {
        let presentation = GenericDebugOutputPresentation(flushDelay: .seconds(60))
        presentation.schedule { "obsolete" }

        presentation.replace(with: "replacement")
        presentation.flush()

        #expect(presentation.text == "replacement")
    }

    @Test
    func springPortConflictOutputProducesAnActionableDiagnostic() {
        let manager = DebugAdapterSessionManager(providers: []) { _, _ in nil }
        let feature = GenericDebugFeatureModel(sessions: manager)

        feature.appendDebuggeeOutput("Web server failed to start. Port 8080 was already in use.\n")

        #expect(feature.errorMessage == "Port 8080 is already in use. Stop the process using it or change server.port in the Run configuration.")
        #expect(feature.output.contains("Port 8080 was already in use."))
    }

    @Test
    func staleSessionCallbacksCannotOverwriteAReplacementSession() throws {
        let descriptor = DebugProviderDescriptor(
            id: "java",
            displayName: "Java",
            fileExtensions: ["java"]
        )
        var createdSessions: [DeferredInspectionDebugSession] = []
        let manager = DebugAdapterSessionManager(providers: [descriptor]) { _, _ in
            let session = DeferredInspectionDebugSession()
            createdSessions.append(session)
            return session
        }
        let root = URL(fileURLWithPath: "/tmp/java-debug-reconnect", isDirectory: true)
        let source = root.appendingPathComponent("src/Main.java")

        _ = try manager.activate(for: source, rootURL: root)
        let first = try #require(createdSessions.first)
        manager.stop(providerID: "java")

        _ = try manager.activate(for: source, rootURL: root)
        let second = try #require(createdSessions.dropFirst().first)
        second.emit(.output(category: "stdout", output: "current\n"))
        first.emit(.output(category: "stderr", output: "stale\n"))
        first.fail()

        #expect(manager.lastEvents["java"] == .output(category: "stdout", output: "current\n"))
        #expect(manager.states["java"] == .ready)
        manager.stopAll()
    }

    @Test
    func independentSessionsShareBreakpointsButKeepStateAndCallbacksSeparate() throws {
        let descriptor = DebugProviderDescriptor(
            id: "java",
            displayName: "Java",
            fileExtensions: ["java"]
        )
        var createdSessions: [DeferredInspectionDebugSession] = []
        let manager = DebugAdapterSessionManager(providers: [descriptor]) { _, _ in
            let session = DeferredInspectionDebugSession()
            createdSessions.append(session)
            return session
        }
        var receivedEvents: [(DebugSessionID, String, DebugAdapterEvent)] = []
        manager.onSessionEvent = { sessionID, providerID, event in
            receivedEvents.append((sessionID, providerID, event))
        }

        let root = URL(fileURLWithPath: "/tmp/java-debug-multiple", isDirectory: true)
        let source = root.appendingPathComponent("src/Main.java")
        let first = try manager.activateNew(for: source, rootURL: root)
        let second = try manager.activateNew(for: source, rootURL: root)
        let firstSession = try #require(createdSessions.first)
        let secondSession = try #require(createdSessions.dropFirst().first)

        #expect(first.id != second.id)
        #expect(manager.sessionSummaries.map(\.id) == [first.id, second.id])
        #expect(manager.activeAdapterIDs == ["java"])
        #expect(manager.session(providerID: "java") === secondSession)

        try manager.setBreakpoints([
            DebugSourceBreakpoint(line: 12, enabled: true)
        ], in: source)
        #expect(firstSession.breakpointUpdates.last?.first?.line == 12)
        #expect(secondSession.breakpointUpdates.last?.first?.line == 12)

        firstSession.emit(.output(category: "stdout", output: "old\n"))
        secondSession.emit(.output(category: "stdout", output: "new\n"))
        #expect(receivedEvents.map { $0.0 } == [first.id, second.id])
        #expect(manager.lastEvents["java"] == .output(category: "stdout", output: "new\n"))

        #expect(manager.select(sessionID: first.id))
        firstSession.emit(.output(category: "stdout", output: "selected-first\n"))
        #expect(manager.lastEvents["java"] == .output(category: "stdout", output: "selected-first\n"))

        manager.stop(sessionID: second.id)
        #expect(manager.session(providerID: "java") === firstSession)
        #expect(manager.activeSessionIDs == [first.id])
        #expect(manager.states["java"] == .ready)
        #expect(manager.sessionSummaries.map(\.id) == [first.id])

        manager.stop(sessionID: first.id)
        #expect(manager.activeSessionIDs.isEmpty)
        #expect(manager.activeAdapterIDs.isEmpty)
        #expect(manager.states["java"] == .idle)
    }

    @Test
    func sessionAwareRunInTerminalRequestsKeepTheirOwningSessionIdentity() throws {
        let descriptor = DebugProviderDescriptor(
            id: "java",
            displayName: "Java",
            fileExtensions: ["java"]
        )
        var createdSessions: [DeferredInspectionDebugSession] = []
        let manager = DebugAdapterSessionManager(providers: [descriptor]) { _, _ in
            let session = DeferredInspectionDebugSession()
            createdSessions.append(session)
            return session
        }
        var requests: [(DebugSessionID, DebugRunInTerminalRequest)] = []
        manager.onSessionRunInTerminalRequest = { sessionID, request, completion in
            requests.append((sessionID, request))
            completion(.success(DebugRunInTerminalResponse(processID: 42)))
        }
        let root = URL(fileURLWithPath: "/tmp/java-debug-terminal-routing", isDirectory: true)
        let source = root.appendingPathComponent("src/Main.java")
        let first = try manager.activateNew(for: source, rootURL: root)
        let second = try manager.activateNew(for: source, rootURL: root)
        let request = DebugRunInTerminalRequest(
            kind: .integrated,
            title: "Second",
            cwd: root.path,
            args: ["/usr/bin/java", "example.Second"],
            environment: [],
            argsCanBeInterpretedByShell: false
        )

        createdSessions[0].emitRunInTerminalRequest(request)
        createdSessions[1].emitRunInTerminalRequest(request)

        #expect(requests.map(\.0) == [first.id, second.id])
        manager.stopAll()
    }

    @Test
    func consoleHistoryIsBoundedDeduplicatedAndScopedToTheSelectedSession() throws {
        let descriptor = DebugProviderDescriptor(
            id: "java",
            displayName: "Java",
            fileExtensions: ["java"]
        )
        var createdSessions: [DeferredInspectionDebugSession] = []
        let manager = DebugAdapterSessionManager(providers: [descriptor]) { _, _ in
            let session = DeferredInspectionDebugSession()
            createdSessions.append(session)
            return session
        }
        let feature = GenericDebugFeatureModel(sessions: manager)
        let root = URL(fileURLWithPath: "/tmp/java-debug-console-history", isDirectory: true)
        let source = root.appendingPathComponent("src/Main.java")
        let configuration = DebugLaunchConfiguration(
            name: "Main",
            request: .launch,
            arguments: ["mainClass": .string("example.Main")]
        )

        #expect(feature.start(fileURL: source, rootURL: root, configuration: configuration))
        for index in 0..<105 {
            feature.evaluate("value\(index)")
        }
        feature.evaluate("value104")

        #expect(feature.consoleHistory.count == 100)
        #expect(feature.consoleHistory.first == "value5")
        #expect(feature.consoleHistory.last == "value104")
        #expect(feature.previousConsoleExpression(current: "") == "value104")
        #expect(feature.previousConsoleExpression(current: "value104") == "value103")
        #expect(feature.nextConsoleExpression() == "value104")
        #expect(feature.nextConsoleExpression() == "")

        #expect(feature.startAdditional(
            fileURL: source,
            rootURL: root,
            configuration: configuration
        ))
        #expect(feature.consoleHistory.isEmpty)
        feature.stop()
    }

    @Test
    func consoleInputRunsDebuggerCommandsOnlyWhilePaused() throws {
        let session = DeferredInspectionDebugSession()
        let descriptor = DebugProviderDescriptor(
            id: "c",
            displayName: "C",
            fileExtensions: ["c"]
        )
        let manager = DebugAdapterSessionManager(providers: [descriptor]) { _, _ in session }
        let feature = GenericDebugFeatureModel(sessions: manager)
        let root = URL(fileURLWithPath: "/tmp/c-debug-console-input", isDirectory: true)
        #expect(feature.start(
            fileURL: root.appendingPathComponent("main.c"),
            rootURL: root,
            configuration: DebugLaunchConfiguration(name: "main", request: .launch, arguments: [:])
        ))
        defer { feature.stop() }

        // A running program cannot answer debugger commands, so the draft stays.
        session.transition(to: .running)
        #expect(!feature.submitConsoleInput("bt"))
        #expect(session.evaluateExpressions.isEmpty)

        session.transition(to: .paused)
        #expect(feature.submitConsoleInput("  bt  "))
        #expect(session.evaluateExpressions == ["bt"])
        #expect(feature.output.hasSuffix("> bt\n"))

        session.completeEvaluation(
            at: 0,
            with: .success(DebugVariable(
                id: "bt",
                name: "bt",
                value: "frame #0: main",
                type: nil,
                evaluateName: nil,
                variablesReference: 0
            ))
        )
        #expect(feature.output.hasSuffix("> bt\nframe #0: main\n"))
        #expect(feature.previousConsoleExpression(current: "") == "bt")

        // Blank lines are consumed without reaching the adapter.
        #expect(feature.submitConsoleInput("   "))
        #expect(session.evaluateExpressions == ["bt"])
    }

    @Test
    func featureSwitchesSessionsWithoutMixingTheirConsoleState() throws {
        let descriptor = DebugProviderDescriptor(
            id: "java",
            displayName: "Java",
            fileExtensions: ["java"]
        )
        var createdSessions: [DeferredInspectionDebugSession] = []
        let manager = DebugAdapterSessionManager(providers: [descriptor]) { _, _ in
            let session = DeferredInspectionDebugSession()
            createdSessions.append(session)
            return session
        }
        let feature = GenericDebugFeatureModel(sessions: manager)
        let root = URL(fileURLWithPath: "/tmp/java-debug-feature-sessions", isDirectory: true)
        let source = root.appendingPathComponent("src/Main.java")
        let firstConfiguration = DebugLaunchConfiguration(
            name: "First",
            request: .launch,
            arguments: ["mainClass": .string("example.First")]
        )
        let secondConfiguration = DebugLaunchConfiguration(
            name: "Second",
            request: .launch,
            arguments: ["mainClass": .string("example.Second")]
        )

        #expect(feature.start(
            fileURL: source,
            rootURL: root,
            configuration: firstConfiguration
        ))
        let first = try #require(createdSessions.first)
        let firstID = try #require(feature.activeSessionID)
        first.emit(.output(category: "stdout", output: "first\n"))

        #expect(feature.startAdditional(
            fileURL: source,
            rootURL: root,
            configuration: secondConfiguration
        ))
        let second = try #require(createdSessions.dropFirst().first)
        let secondID = try #require(feature.activeSessionID)
        #expect(firstID != secondID)
        second.emit(.output(category: "stdout", output: "second\n"))
        first.emit(.output(category: "stdout", output: "first-late\n"))
        #expect(feature.output == "second\n")

        #expect(feature.selectSession(firstID))
        #expect(feature.output == "first\nfirst-late\n")
        #expect(feature.targetTitle == "First")
        #expect(feature.activeSessionID == firstID)

        #expect(feature.selectSession(secondID))
        #expect(feature.output == "second\n")
        #expect(feature.targetTitle == "Second")
        #expect(feature.activeSessionID == secondID)

        feature.stopSession(firstID)
        #expect(feature.sessionSummaries.map(\.id) == [secondID])
        feature.stop()
        #expect(feature.sessionSummaries.isEmpty)
    }

    @Test
    func additionalSessionLaunchFailureRestoresTheOriginalActiveSession() throws {
        let descriptor = DebugProviderDescriptor(
            id: "java",
            displayName: "Java",
            fileExtensions: ["java"]
        )
        var createdSessions: [DeferredInspectionDebugSession] = []
        let manager = DebugAdapterSessionManager(providers: [descriptor]) { _, _ in
            let session = DeferredInspectionDebugSession()
            if createdSessions.count == 1 {
                session.failNextLaunch = true
            }
            createdSessions.append(session)
            return session
        }
        let feature = GenericDebugFeatureModel(sessions: manager)
        let root = URL(fileURLWithPath: "/tmp/java-debug-additional-failure", isDirectory: true)
        let source = root.appendingPathComponent("src/Main.java")
        let firstConfiguration = DebugLaunchConfiguration(
            name: "First",
            request: .launch,
            arguments: ["mainClass": .string("example.First")]
        )
        let secondConfiguration = DebugLaunchConfiguration(
            name: "Second",
            request: .launch,
            arguments: ["mainClass": .string("example.Second")]
        )

        #expect(feature.start(fileURL: source, rootURL: root, configuration: firstConfiguration))
        let first = try #require(createdSessions.first)
        let firstID = try #require(feature.activeSessionID)
        first.emit(.output(category: "stdout", output: "first\n"))

        #expect(!feature.startAdditional(
            fileURL: source,
            rootURL: root,
            configuration: secondConfiguration
        ))
        #expect(createdSessions.count == 2)
        #expect(feature.activeSessionID == firstID)
        #expect(feature.targetTitle == "First")
        #expect(feature.output == "first\n")
        #expect(feature.outputPresentation.text == "first\n")
        #expect(feature.state == .paused)
        #expect(feature.errorMessage == nil)
        #expect(manager.activeSessionIDs == [firstID])

        feature.stop()
    }

    @Test
    func stoppingActiveSessionPromotesTheMostRecentRemainingSession() throws {
        let descriptor = DebugProviderDescriptor(
            id: "java",
            displayName: "Java",
            fileExtensions: ["java"]
        )
        var createdSessions: [DeferredInspectionDebugSession] = []
        let manager = DebugAdapterSessionManager(providers: [descriptor]) { _, _ in
            let session = DeferredInspectionDebugSession()
            createdSessions.append(session)
            return session
        }
        let feature = GenericDebugFeatureModel(sessions: manager)
        let root = URL(fileURLWithPath: "/tmp/java-debug-stop-promotion", isDirectory: true)
        let source = root.appendingPathComponent("src/Main.java")
        let firstConfiguration = DebugLaunchConfiguration(
            name: "First",
            request: .launch,
            arguments: ["mainClass": .string("example.First")]
        )
        let secondConfiguration = DebugLaunchConfiguration(
            name: "Second",
            request: .launch,
            arguments: ["mainClass": .string("example.Second")]
        )

        #expect(feature.start(fileURL: source, rootURL: root, configuration: firstConfiguration))
        let firstID = try #require(feature.activeSessionID)
        let first = try #require(createdSessions.first)
        first.emit(.output(category: "stdout", output: "first\n"))
        #expect(feature.startAdditional(
            fileURL: source,
            rootURL: root,
            configuration: secondConfiguration
        ))
        let secondID = try #require(feature.activeSessionID)
        #expect(secondID != firstID)
        let second = try #require(createdSessions.dropFirst().first)
        second.emit(.output(category: "stdout", output: "second\n"))

        feature.stop()

        #expect(feature.activeSessionID == firstID)
        #expect(feature.targetTitle == "First")
        #expect(feature.output == "first\n")
        #expect(feature.state == .paused)
        #expect(manager.activeSessionIDs == [firstID])
        #expect(second.isRunning == false)

        feature.stop()
    }

    @Test
    func coreProtocolSessionReportsTheCapabilitiesAPluginDisabled() throws {
        let transport = RecordingTransport()
        let core = RecordingDebugProtocolCore()
        let session = CoreDebugAdapterProtocolSession(
            adapterID: "lldb",
            disabledCapabilities: ["supportsStepBack", "supportsRestartRequest"],
            transport: transport,
            core: core,
            sessionID: "lldb-session",
            deadlineScheduler: RecordingDebugDeadlineScheduler()
        )
        defer { session.stop() }

        try session.start(rootURL: URL(fileURLWithPath: "/tmp/lldb-core", isDirectory: true))

        #expect(core.lastDisabledCapabilities == ["supportsStepBack", "supportsRestartRequest"])
    }

    @Test
    func coreProtocolSessionProjectsRustUpdatesThroughInjectedTransport() throws {
        let transport = RecordingTransport()
        let core = RecordingDebugProtocolCore()
        let deadlines = RecordingDebugDeadlineScheduler()
        let session = CoreDebugAdapterProtocolSession(
            adapterID: "java",
            transport: transport,
            core: core,
            sessionID: "java-session",
            deadlineScheduler: deadlines
        )

        try session.start(rootURL: URL(fileURLWithPath: "/tmp/java-core", isDirectory: true))

        #expect(session.state == .initializing)
        #expect(transport.sentData == [Data("initialize-frame".utf8)])
        core.enqueueReceive(state: "ready", events: [[
            "sequence": 2,
            "type": "stateChanged",
            "state": "ready"
        ], [
            "sequence": 3,
            "type": "capabilities",
            "capabilities": [
                "supportsConfigurationDone": true,
                "supportsConditionalBreakpoints": true,
                "supportsHitConditionalBreakpoints": true,
                "supportsLogPoints": true,
                "supportsFunctionBreakpoints": true,
                "supportsDataBreakpoints": true,
                "supportsExceptionOptions": true,
                "supportsExceptionFilterOptions": true,
                "supportsSetVariable": true,
                "supportsCancelRequest": true,
                "supportsSingleThreadExecutionRequests": true,
                "supportsRestartRequest": true,
                "supportsTerminateRequest": true,
                "supportsStepBack": true,
                "supportsExceptionInfoRequest": true,
                "supportsStepInTargetsRequest": true,
                "supportsGotoTargetsRequest": true,
                "supportsCompletionsRequest": true,
                "exceptionBreakpointFilters": [[
                    "filter": "caught",
                    "label": "Caught Exceptions",
                    "default": false,
                    "supportsCondition": true
                ]]
            ]
        ]])
        transport.emitData(Data("initialize-response".utf8))
        #expect(session.state == .ready)
        #expect(session.capabilities.negotiated)
        #expect(session.capabilities.supportsConditionalBreakpoints)
        #expect(session.capabilities.supportsFunctionBreakpoints)
        #expect(session.capabilities.supportsDataBreakpoints)
        #expect(session.capabilities.supportsExceptionInfoRequest)
        #expect(session.capabilities.exceptionBreakpointFilters.first?.filter == "caught")

        var dataInfoResult: Result<DebugDataBreakpointInfo, Error>?
        session.requestDataBreakpointInfo(
            name: "count",
            variablesReference: 42,
            frameID: 7
        ) { dataInfoResult = $0 }
        let dataOperationID = try #require(core.lastDataBreakpointInfoOperationID)
        core.enqueueReceive(state: "paused", events: [[
            "sequence": 4,
            "type": "operationCompleted",
            "operationId": dataOperationID,
            "result": [
                "kind": "dataBreakpointInfo",
                "dataId": "field:count",
                "description": "Main.count",
                "accessTypes": ["read", "write"],
                "canPersist": true
            ]
        ]])
        transport.emitData(Data("data-info-response".utf8))
        #expect(try dataInfoResult?.get() == DebugDataBreakpointInfo(
            dataID: "field:count",
            description: "Main.count",
            accessTypes: ["read", "write"],
            canPersist: true
        ))

        var setVariableResult: Result<DebugVariable, Error>?
        session.setVariable(
            variablesReference: 42,
            name: "count",
            value: "7"
        ) { setVariableResult = $0 }
        let setVariableOperationID = try #require(core.lastSetVariableOperationID)
        core.enqueueReceive(state: "paused", events: [[
            "sequence": 5,
            "type": "operationCompleted",
            "operationId": setVariableOperationID,
            "result": [
                "kind": "setVariable",
                "variable": [
                    "name": "count",
                    "value": "7",
                    "type": "int",
                    "variablesReference": 0
                ]
            ]
        ]])
        transport.emitData(Data("set-variable-response".utf8))
        #expect(try setVariableResult?.get().value == "7")
        #expect(try setVariableResult?.get().containerReference == 42)

        var threadsResult: Result<[DebugThread], Error>?
        session.requestThreads { threadsResult = $0 }
        let operationID = try #require(core.lastInspectionOperationID)
        core.enqueueReceive(state: "paused", events: [[
            "sequence": 5,
            "type": "operationCompleted",
            "operationId": operationID,
            "result": [
                "kind": "threads",
                "threads": [["id": 7, "name": "main"]]
            ]
        ]])
        transport.emitData(Data("threads-response".utf8))

        #expect(try threadsResult?.get() == [DebugThread(id: 7, name: "main")])

        var exceptionInfoResult: Result<DebugExceptionInfo, Error>?
        session.requestExceptionInfo(threadID: 7) { exceptionInfoResult = $0 }
        let exceptionOperationID = try #require(core.lastInspectionOperationID)
        core.enqueueReceive(state: "paused", events: [[
            "sequence": 6,
            "type": "operationCompleted",
            "operationId": exceptionOperationID,
            "result": [
                "kind": "exceptionInfo",
                "exceptionInfo": [
                    "exceptionId": "java.lang.IllegalStateException",
                    "description": "java.lang.IllegalStateException: session expired",
                    "breakMode": "always",
                    "details": [
                        "message": "session expired",
                        "typeName": "IllegalStateException",
                        "fullTypeName": "java.lang.IllegalStateException",
                        "evaluateName": "exception",
                        "stackTrace": "at example.Main.run(Main.java:12)",
                        "innerExceptions": [[
                            "message": "token expired",
                            "typeName": "TokenExpiredException",
                            "fullTypeName": "example.TokenExpiredException",
                            "innerExceptions": []
                        ]]
                    ]
                ]
            ]
        ]])
        transport.emitData(Data("exception-info-response".utf8))
        #expect(try exceptionInfoResult?.get() == DebugExceptionInfo(
            exceptionID: "java.lang.IllegalStateException",
            description: "java.lang.IllegalStateException: session expired",
            breakMode: "always",
            details: DebugExceptionDetails(
                message: "session expired",
                typeName: "IllegalStateException",
                fullTypeName: "java.lang.IllegalStateException",
                evaluateName: "exception",
                stackTrace: "at example.Main.run(Main.java:12)",
                innerExceptions: [DebugExceptionDetails(
                    message: "token expired",
                    typeName: "TokenExpiredException",
                    fullTypeName: "example.TokenExpiredException",
                    evaluateName: nil,
                    stackTrace: nil
                )]
            )
        ))

        var stepTargetsResult: Result<[DebugStepInTarget], Error>?
        session.requestStepInTargets(frameID: 7) { stepTargetsResult = $0 }
        let stepTargetsOperationID = try #require(core.lastInspectionOperationID)
        core.enqueueReceive(state: "paused", events: [[
            "sequence": 6,
            "type": "operationCompleted",
            "operationId": stepTargetsOperationID,
            "result": [
                "kind": "stepInTargets",
                "targets": [["id": 21, "label": "service.load()", "line": 12]]
            ]
        ]])
        transport.emitData(Data("step-targets-response".utf8))
        #expect(try stepTargetsResult?.get().first?.label == "service.load()")

        var gotoTargetsResult: Result<[DebugGotoTarget], Error>?
        session.requestGotoTargets(
            fileURL: URL(fileURLWithPath: "/tmp/Main.java"),
            line: 20,
            column: 5
        ) { gotoTargetsResult = $0 }
        let gotoTargetsOperationID = try #require(core.lastInspectionOperationID)
        core.enqueueReceive(state: "paused", events: [[
            "sequence": 7,
            "type": "operationCompleted",
            "operationId": gotoTargetsOperationID,
            "result": [
                "kind": "gotoTargets",
                "targets": [["id": 31, "label": "Main.java:20", "line": 20]]
            ]
        ]])
        transport.emitData(Data("goto-targets-response".utf8))
        #expect(try gotoTargetsResult?.get().first?.line == 20)
        session.execute(
            .continueExecution,
            threadID: 7,
            targetID: nil,
            singleThread: true
        )
        #expect(core.lastExecutionSingleThread == true)
        #expect(core.lastExecutionThreadID == 7)

        var timedOutResult: Result<[DebugThread], Error>?
        session.requestThreads { timedOutResult = $0 }
        deadlines.fireLast()
        #expect(core.cancelledOperationReasons.last == "timedOut")
        #expect(throws: (any Error).self) { try timedOutResult?.get() }
        session.stop()
        #expect(session.state == .idle)
        #expect(core.destroyedSessionIDs == ["java-session"])
        #expect(transport.stopCalls == 1)
    }

    @Test
    func coreProtocolSessionRequestsConsoleCompletionsAtTheCaret() throws {
        let transport = RecordingTransport()
        let core = RecordingDebugProtocolCore()
        let session = CoreDebugAdapterProtocolSession(
            adapterID: "lldb-dap",
            consoleCommands: [DebugConsoleCommand(name: "frame variable", detail: "Show locals")],
            transport: transport,
            core: core,
            sessionID: "lldb-completions",
            deadlineScheduler: RecordingDebugDeadlineScheduler()
        )
        try session.start(rootURL: URL(fileURLWithPath: "/tmp/lldb-completions", isDirectory: true))
        core.enqueueReceive(sessionID: "lldb-completions", state: "ready", events: [[
            "sequence": 2,
            "type": "stateChanged",
            "state": "ready"
        ], [
            "sequence": 3,
            "type": "capabilities",
            "capabilities": [
                "supportsConfigurationDone": false,
                "supportsConditionalBreakpoints": false,
                "supportsHitConditionalBreakpoints": false,
                "supportsLogPoints": false,
                "supportsFunctionBreakpoints": false,
                "supportsDataBreakpoints": false,
                "supportsExceptionOptions": false,
                "supportsExceptionFilterOptions": false,
                "supportsSetVariable": false,
                "supportsCancelRequest": false,
                "supportsSingleThreadExecutionRequests": false,
                "supportsRestartRequest": false,
                "supportsTerminateRequest": false,
                "supportsStepBack": false,
                "supportsExceptionInfoRequest": false,
                "supportsStepInTargetsRequest": false,
                "supportsGotoTargetsRequest": false,
                "supportsCompletionsRequest": true,
                "exceptionBreakpointFilters": []
            ]
        ]])
        transport.emitData(Data("initialize-response".utf8))
        #expect(session.capabilities.supportsCompletionsRequest)
        #expect(session.consoleCommands.map(\.name) == ["frame variable"])

        var result: Result<[DebugCompletionItem], Error>?
        session.requestCompletions("fra", column: 3, frameID: 7) { result = $0 }
        let request = try #require(core.inspectionRequests.last)
        #expect(request.kind == "completions")
        #expect(request.frameID == 7)
        #expect(request.expression == "fra")
        // The wire column counts from 1, the caret from 0.
        #expect(request.column == 4)
        core.enqueueReceive(sessionID: "lldb-completions", state: "paused", events: [[
            "sequence": 4,
            "type": "operationCompleted",
            "operationId": request.operationID,
            "result": [
                "kind": "completions",
                "items": [["label": "frame -- Select frames", "text": "frame", "start": 0, "length": 3]]
            ]
        ]])
        transport.emitData(Data("completions-response".utf8))
        let item = try #require(try result?.get().first)
        #expect(item.label == "frame -- Select frames")
        #expect(item.text == "frame")
        #expect(item.start == 0)
        #expect(item.length == 3)
        session.stop()
    }

    @Test
    func consoleCompletionsMergeAdapterProposalsWithDeclaredCommands() throws {
        let session = DeferredInspectionDebugSession(
            capabilities: DebugAdapterCapabilities(negotiated: true, supportsCompletionsRequest: true)
        )
        session.consoleCommands = [
            DebugConsoleCommand(name: "frame variable", detail: "Show locals"),
            DebugConsoleCommand(name: "breakpoint set", detail: nil)
        ]
        let feature = makeDeferredFeature(session: session, rootPath: "/workspace/console-completions")
        defer { feature.stop() }
        session.emit(.stopped(reason: "breakpoint", threadID: 1, description: nil))

        var suggestions: [DebugConsoleCompletion.Suggestion]?
        feature.requestConsoleCompletions(text: "fra", caret: 3) { suggestions = $0 }
        #expect(session.completionRequests.map(\.text) == ["fra"])
        #expect(session.completionRequests.map(\.column) == [3])
        session.completeCompletions(at: 0, with: [DebugCompletionItem(label: "frame", text: "frame")])
        #expect(suggestions?.map(\.insertion) == ["frame", "frame variable"])
        #expect(suggestions?.last?.detail == "Show locals")
    }

    @Test
    func consoleCompletionsAskTheAdapterForCommandsWhenThePluginDeclaredAPrefix() throws {
        let session = DeferredInspectionDebugSession(
            capabilities: DebugAdapterCapabilities(negotiated: true, supportsCompletionsRequest: true)
        )
        session.consoleCommandPrefix = "`"
        let feature = makeDeferredFeature(session: session, rootPath: "/workspace/console-completions-prefix")
        defer { feature.stop() }
        session.emit(.stopped(reason: "breakpoint", threadID: 1, description: nil))

        var suggestions: [DebugConsoleCompletion.Suggestion]?
        feature.requestConsoleCompletions(text: "fr", caret: 2) { suggestions = $0 }
        // The adapter reads the line as a command; the caret moves with the prefix.
        #expect(session.completionRequests.map(\.text) == ["`fr"])
        #expect(session.completionRequests.map(\.column) == [3])
        session.completeCompletions(at: 0, with: [DebugCompletionItem(label: "frame -- Commands for frames", text: "frame")])
        // The user's own line never contains the prefix, so the proposal replaces `fr`.
        let suggestion = try #require(suggestions?.first)
        #expect(suggestion.insertion == "frame")
        #expect(DebugConsoleCompletion.apply(suggestion, to: "fr").text == "frame")
    }

    @Test
    func consoleCompletionsDropRepliesMadeStaleByNewerTyping() {
        let session = DeferredInspectionDebugSession(
            capabilities: DebugAdapterCapabilities(negotiated: true, supportsCompletionsRequest: true)
        )
        let feature = makeDeferredFeature(session: session, rootPath: "/workspace/console-completions-stale")
        defer { feature.stop() }
        session.emit(.stopped(reason: "breakpoint", threadID: 1, description: nil))

        var delivered: [[String]] = []
        feature.requestConsoleCompletions(text: "f", caret: 1) { delivered.append($0.map(\.insertion)) }
        feature.requestConsoleCompletions(text: "fr", caret: 2) { delivered.append($0.map(\.insertion)) }
        session.completeCompletions(at: 0, with: [DebugCompletionItem(label: "finish", text: "finish")])
        #expect(delivered.isEmpty)
        session.completeCompletions(at: 1, with: [DebugCompletionItem(label: "frame", text: "frame")])
        #expect(delivered == [["frame"]])
    }

    @Test
    func consoleCompletionsFallBackToDeclaredCommandsWithoutAdapterSupport() {
        let session = DeferredInspectionDebugSession()
        session.consoleCommands = [DebugConsoleCommand(name: "frame variable", detail: nil)]
        let feature = makeDeferredFeature(session: session, rootPath: "/workspace/console-completions-declared")
        defer { feature.stop() }

        session.transition(to: .running)
        var beforePause: [DebugConsoleCompletion.Suggestion]?
        feature.requestConsoleCompletions(text: "fra", caret: 3) { beforePause = $0 }
        #expect(beforePause?.isEmpty == true)

        session.transition(to: .paused)
        var declared: [DebugConsoleCompletion.Suggestion]?
        feature.requestConsoleCompletions(text: "fra", caret: 3) { declared = $0 }
        #expect(session.completionRequests.isEmpty)
        #expect(declared?.map(\.insertion) == ["frame variable"])

        var blank: [DebugConsoleCompletion.Suggestion]?
        feature.requestConsoleCompletions(text: "  ", caret: 2) { blank = $0 }
        #expect(blank?.isEmpty == true)
    }

    @Test
    func coreProtocolSessionLaunchesRunInTerminalAndReturnsProcessID() throws {
        let transport = RecordingTransport()
        let core = RecordingDebugProtocolCore()
        let session = CoreDebugAdapterProtocolSession(
            adapterID: "java",
            transport: transport,
            core: core,
            sessionID: "java-run-in-terminal",
            deadlineScheduler: RecordingDebugDeadlineScheduler()
        )
        var receivedRequest: DebugRunInTerminalRequest?
        session.onRunInTerminalRequest = { request, completion in
            receivedRequest = request
            completion(.success(DebugRunInTerminalResponse(processID: 4242)))
        }

        try session.start(rootURL: URL(fileURLWithPath: "/tmp/java-run-in-terminal"))
        defer { session.stop() }
        #expect(core.lastSupportsRunInTerminalRequest == true)
        core.enqueueReceive(sessionID: "java-run-in-terminal", state: "launching", events: [[
            "sequence": 2,
            "type": "runInTerminalRequested",
            "requestId": "runInTerminal-44",
            "request": [
                "kind": "integrated",
                "title": "Debug Main",
                "cwd": "/tmp/java-run-in-terminal",
                "args": ["/opt/jdk/bin/java", "example.Main"],
                "environment": [["name": "JAVA_HOME", "value": "/opt/jdk"]],
                "argsCanBeInterpretedByShell": false
            ]
        ]])

        transport.emitData(Data("run-in-terminal-request".utf8))

        #expect(receivedRequest?.args == ["/opt/jdk/bin/java", "example.Main"])
        #expect(core.runInTerminalCompletions == [RecordingRunInTerminalCompletion(
            requestID: "runInTerminal-44",
            response: DebugRunInTerminalResponse(processID: 4242),
            errorDescription: nil
        )])
        #expect(transport.sentData.contains(Data("run-in-terminal-response".utf8)))
    }

    @Test
    func stoppingCoreProtocolSessionFailsPendingTerminalRequestAndIgnoresLateCompletion() throws {
        let transport = RecordingTransport()
        let core = RecordingDebugProtocolCore()
        let session = CoreDebugAdapterProtocolSession(
            adapterID: "java",
            transport: transport,
            core: core,
            sessionID: "java-run-in-terminal-stop",
            deadlineScheduler: RecordingDebugDeadlineScheduler()
        )
        var pendingCompletion: DebugRunInTerminalCompletion?
        session.onRunInTerminalRequest = { _, completion in
            pendingCompletion = completion
        }
        try session.start(rootURL: URL(fileURLWithPath: "/tmp/java-run-in-terminal-stop"))
        core.enqueueReceive(sessionID: "java-run-in-terminal-stop", state: "launching", events: [[
            "sequence": 2,
            "type": "runInTerminalRequested",
            "requestId": "runInTerminal-45",
            "request": [
                "kind": "integrated",
                "cwd": "/tmp/java-run-in-terminal-stop",
                "args": ["/opt/jdk/bin/java"],
                "environment": [],
                "argsCanBeInterpretedByShell": false
            ]
        ]])
        transport.emitData(Data("run-in-terminal-request".utf8))

        session.stop()
        #expect(core.runInTerminalCompletions.count == 1)
        #expect(core.runInTerminalCompletions[0].requestID == "runInTerminal-45")
        #expect(core.runInTerminalCompletions[0].errorDescription != nil)

        pendingCompletion?(.success(DebugRunInTerminalResponse(processID: 4242)))
        #expect(core.runInTerminalCompletions.count == 1)
    }

    @Test
    func sharedProjectionV2FixturesDecodeAndRejectOnTheSameTerms() throws {
        // 夹具在仓库根的 shared/ 下，按本文件位置定位，不依赖 swift test 的工作目录。
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("shared/fixtures/debug/projection-v2-examples.json")
        let root = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        func decode(_ entry: Any) throws -> DebugProjectionV2 {
            let value = try #require((entry as? [String: Any])?["value"])
            return try JSONDecoder().decode(
                DebugProjectionV2.self,
                from: JSONSerialization.data(withJSONObject: value)
            )
        }
        let accepted = try #require(root["accept"] as? [Any])
        let rejected = try #require(root["reject"] as? [Any])
        #expect(!accepted.isEmpty && !rejected.isEmpty)
        for entry in accepted { _ = try decode(entry) }
        for entry in rejected {
            #expect(throws: (any Error).self, "\((entry as? [String: Any])?["name"] ?? "")") {
                try decode(entry)
            }
        }
        guard case .stackTrace(_, let frames) = try decode(accepted[0]).projection else {
            Issue.record("first example must be a stack trace")
            return
        }
        #expect(frames[1].source == nil)
        #expect(frames[1].instructionPointerReference == "0xffffffff81002a10")
    }

    @Test
    func coreProtocolSessionGatesOptionalFeaturesOnNegotiatedCapabilities() throws {
        let transport = RecordingTransport()
        let core = RecordingDebugProtocolCore()
        let session = CoreDebugAdapterProtocolSession(
            adapterID: "java",
            transport: transport,
            core: core,
            sessionID: "java-no-capabilities",
            deadlineScheduler: RecordingDebugDeadlineScheduler()
        )
        try session.start(rootURL: URL(fileURLWithPath: "/tmp/java-no-capabilities"))
        defer { session.stop() }

        var dataResult: Result<DebugDataBreakpointInfo, Error>?
        session.requestDataBreakpointInfo(name: "count", variablesReference: 1, frameID: 1) {
            dataResult = $0
        }
        var exceptionResult: Result<DebugExceptionInfo, Error>?
        session.requestExceptionInfo(threadID: 1) { exceptionResult = $0 }

        #expect(throws: DebugAdapterCapabilityError.self) { try dataResult?.get() }
        #expect(throws: DebugAdapterCapabilityError.self) { try exceptionResult?.get() }
        #expect(core.lastDataBreakpointInfoOperationID == nil)
    }

    @Test
    func coreProtocolSessionDelegatesStartDebuggingAndReportsTheOutcome() throws {
        let transport = RecordingTransport()
        let core = RecordingDebugProtocolCore()
        let session = CoreDebugAdapterProtocolSession(
            adapterID: "node",
            transport: transport,
            core: core,
            sessionID: "node-start-debugging",
            deadlineScheduler: RecordingDebugDeadlineScheduler()
        )
        var received: DebugStartDebuggingRequest?
        session.onStartDebuggingRequest = { request, completion in
            received = request
            completion(.success(()))
        }
        try session.start(rootURL: URL(fileURLWithPath: "/tmp/node-start-debugging"))
        defer { session.stop() }
        #expect(core.lastSupportsStartDebuggingRequest == true)
        core.enqueueReceive(sessionID: "node-start-debugging", state: "running", events: [[
            "sequence": 2,
            "type": "startDebuggingRequested",
            "requestId": "startDebugging-61",
            "request": [
                "request": "attach",
                "configuration": ["type": "pwa-node", "port": 9230]
            ]
        ]])

        transport.emitData(Data("start-debugging-request".utf8))

        #expect(received?.request == .attach)
        #expect(received?.configuration["type"] == .string("pwa-node"))
        #expect(core.startDebuggingResults.map(\.requestID) == ["startDebugging-61"])
        #expect(core.startDebuggingResults.map(\.succeeded) == [true])
    }

    @Test
    func coreProtocolSessionRejectsStartDebuggingWithoutAHostHandler() throws {
        let transport = RecordingTransport()
        let core = RecordingDebugProtocolCore()
        let session = CoreDebugAdapterProtocolSession(
            adapterID: "node",
            transport: transport,
            core: core,
            sessionID: "node-no-child-host",
            deadlineScheduler: RecordingDebugDeadlineScheduler()
        )
        try session.start(rootURL: URL(fileURLWithPath: "/tmp/node-no-child-host"))
        defer { session.stop() }
        #expect(core.lastSupportsStartDebuggingRequest == false)
        core.enqueueReceive(sessionID: "node-no-child-host", state: "running", events: [[
            "sequence": 2,
            "type": "startDebuggingRequested",
            "requestId": "startDebugging-62",
            "request": ["request": "launch", "configuration": [:]]
        ]])

        transport.emitData(Data("start-debugging-request".utf8))

        #expect(core.startDebuggingResults.map(\.succeeded) == [false])
    }

    /// Builds a manager whose parent and child sessions share one recording core.
    private func makeChildCapableManager(
        core: RecordingDebugProtocolCore,
        parentTransport: RecordingTransport,
        childFactory: Bool = true
    ) -> (DebugAdapterSessionManager, () -> [CoreDebugAdapterProtocolSession]) {
        let descriptor = DebugProviderDescriptor(id: "node", displayName: "Node", fileExtensions: ["js"])
        var created: [CoreDebugAdapterProtocolSession] = []
        let manager = DebugAdapterSessionManager(providers: [descriptor]) { _, _ in
            let session = CoreDebugAdapterProtocolSession(
                adapterID: "node",
                transport: parentTransport,
                core: core,
                sessionID: "node-parent",
                deadlineScheduler: RecordingDebugDeadlineScheduler()
            )
            created.append(session)
            return session
        }
        if childFactory {
            manager.makeChildSession = { _, _, _ in
                let session = CoreDebugAdapterProtocolSession(
                    adapterID: "node",
                    transport: RecordingTransport(),
                    core: core,
                    sessionID: "node-child-\(created.count)",
                    deadlineScheduler: RecordingDebugDeadlineScheduler()
                )
                created.append(session)
                return session
            }
        }
        return (manager, { created })
    }

    private func requestChild(_ core: RecordingDebugProtocolCore, _ transport: RecordingTransport) {
        core.enqueueReceive(sessionID: "node-parent", state: "running", events: [[
            "sequence": 2,
            "type": "startDebuggingRequested",
            "requestId": "startDebugging-70",
            "request": ["request": "attach", "configuration": ["name": "Worker", "port": 9230]]
        ]])
        transport.emitData(Data("start-debugging-request".utf8))
    }

    @Test
    func startDebuggingOpensALinkedChildWithoutStealingTheProviderSelection() throws {
        let core = RecordingDebugProtocolCore()
        let transport = RecordingTransport()
        let (manager, created) = makeChildCapableManager(core: core, parentTransport: transport)
        defer { manager.stopAll() }
        let root = URL(fileURLWithPath: "/tmp/multi-child")
        let handle = try manager.activateNew(for: root.appendingPathComponent("a.js"), rootURL: root)

        requestChild(core, transport)

        let summaries = manager.sessionSummaries
        #expect(summaries.count == 2)
        let child = try #require(summaries.first { $0.id != handle.id })
        #expect(child.parentID == handle.id)
        #expect(child.targetTitle == "Worker")
        #expect(core.lastParentSessionID == "node-parent")
        #expect(core.lastLaunchConfiguration?.request == .attach)
        #expect(core.startDebuggingResults.map(\.succeeded) == [true])
        #expect(created().count == 2)
        let selected = try #require(manager.session(providerID: "node") as? CoreDebugAdapterProtocolSession)
        let parentSession = try #require(handle.session as? CoreDebugAdapterProtocolSession)
        #expect(selected === parentSession)
    }

    @Test
    func childSessionReplaysBreakpointsSavedBeforeItWasCreated() throws {
        let core = RecordingDebugProtocolCore()
        let transport = RecordingTransport()
        let (manager, _) = makeChildCapableManager(core: core, parentTransport: transport)
        defer { manager.stopAll() }
        let root = URL(fileURLWithPath: "/tmp/multi-child")
        let file = root.appendingPathComponent("a.js")
        try manager.activateNew(for: file, rootURL: root)
        try manager.setBreakpoints([DebugSourceBreakpoint(line: 7, condition: "ready")], in: file)
        let before = core.breakpointUpdates.count

        requestChild(core, transport)

        #expect(core.startDebuggingResults.map(\.succeeded) == [true])
        let replayed = Array(core.breakpointUpdates.dropFirst(before))
        #expect(replayed == [[DebugSourceBreakpoint(line: 7, condition: "ready")]])
    }

    @Test
    func childSessionIsNeverPromotedOverARootSession() throws {
        let core = RecordingDebugProtocolCore()
        let transport = RecordingTransport()
        let (manager, _) = makeChildCapableManager(core: core, parentTransport: transport)
        defer { manager.stopAll() }
        let root = URL(fileURLWithPath: "/tmp/multi-child")
        let file = root.appendingPathComponent("a.js")
        let first = try manager.activateNew(for: file, rootURL: root)
        requestChild(core, transport)
        let second = try manager.activateNew(for: file, rootURL: root)
        let secondChild = try #require(manager.sessionSummaries.first { $0.parentID == nil && $0.id != first.id })
        #expect(secondChild.id == second.id)

        manager.stop(sessionID: second.id)

        let selected = try #require(manager.session(providerID: "node") as? CoreDebugAdapterProtocolSession)
        let firstSession = try #require(first.session as? CoreDebugAdapterProtocolSession)
        #expect(selected === firstSession)
    }

    @Test
    func stoppingAParentStopsItsChildren() throws {
        let core = RecordingDebugProtocolCore()
        let transport = RecordingTransport()
        let (manager, _) = makeChildCapableManager(core: core, parentTransport: transport)
        defer { manager.stopAll() }
        let root = URL(fileURLWithPath: "/tmp/multi-stop")
        let handle = try manager.activateNew(for: root.appendingPathComponent("a.js"), rootURL: root)
        requestChild(core, transport)
        #expect(manager.childSessionIDs(of: handle.id).count == 1)

        manager.stop(sessionID: handle.id)

        #expect(manager.sessionSummaries.isEmpty)
        #expect(core.destroyedSessionIDs.contains("node-parent"))
        #expect(core.destroyedSessionIDs.count == 2)
    }

    @Test
    func featureModelDropsChildrenWithTheirParentAndSelectsARemainingSession() throws {
        let core = RecordingDebugProtocolCore()
        let transport = RecordingTransport()
        let (manager, _) = makeChildCapableManager(core: core, parentTransport: transport)
        let feature = GenericDebugFeatureModel(sessions: manager)
        defer { feature.reset() }
        var stopped: [DebugSessionID] = []
        feature.onSessionStopped = { stopped.append($0) }
        let root = URL(fileURLWithPath: "/tmp/multi-feature")
        let configuration = DebugLaunchConfiguration(name: "Main", request: .launch, arguments: [:])
        #expect(feature.start(
            fileURL: root.appendingPathComponent("a.js"), rootURL: root, configuration: configuration
        ))
        let parentID = try #require(feature.activeSessionID)
        requestChild(core, transport)
        let childID = try #require(feature.sessionSummaries.first { $0.parentID == parentID }?.id)
        #expect(feature.selectSession(childID))

        feature.stopSession(parentID)

        #expect(feature.sessionSummaries.isEmpty)
        #expect(feature.activeSessionID == nil)
        #expect(Set(stopped) == [parentID, childID])
    }

    @Test
    func startDebuggingFallsBackToTheProviderSessionFactory() throws {
        let core = RecordingDebugProtocolCore()
        let transport = RecordingTransport()
        let (manager, created) = makeChildCapableManager(
            core: core, parentTransport: transport, childFactory: false
        )
        defer { manager.stopAll() }
        let root = URL(fileURLWithPath: "/tmp/multi-default")
        let handle = try manager.activateNew(for: root.appendingPathComponent("a.js"), rootURL: root)
        #expect(core.lastSupportsStartDebuggingRequest == true)

        requestChild(core, transport)

        #expect(created().count == 2)
        #expect(manager.sessionSummaries.contains { $0.parentID == handle.id })
    }

    @Test
    func coreProtocolSessionForwardsVariablePagingAndChildCounts() throws {
        let transport = RecordingTransport()
        let core = RecordingDebugProtocolCore()
        let session = CoreDebugAdapterProtocolSession(
            adapterID: "java",
            transport: transport,
            core: core,
            sessionID: "java-variable-paging",
            deadlineScheduler: RecordingDebugDeadlineScheduler()
        )
        try session.start(rootURL: URL(fileURLWithPath: "/tmp/java-variable-paging"))
        defer { session.stop() }

        var result: Result<[DebugVariable], Error>?
        session.requestVariables(
            reference: 700,
            filter: .indexed,
            start: 100,
            count: 2
        ) { result = $0 }

        #expect(core.inspectionRequests.last?.variablesReference == 700)
        #expect(core.inspectionRequests.last?.variableFilter == .indexed)
        #expect(core.inspectionRequests.last?.start == 100)
        #expect(core.inspectionRequests.last?.count == 2)

        let operationID = try #require(core.lastInspectionOperationID)
        core.enqueueReceive(sessionID: "java-variable-paging", state: "paused", events: [[
            "sequence": 2,
            "type": "operationCompleted",
            "operationId": operationID,
            "result": [
                "kind": "variables",
                "variables": [[
                    "name": "[100]",
                    "value": "Customer@100",
                    "type": "example.Customer",
                    "evaluateName": "customers[100]",
                    "variablesReference": 701,
                    "namedVariables": 4,
                    "indexedVariables": 5
                ]]
            ]
        ]])
        transport.emitData(Data("variables-response".utf8))

        let variable = try #require(try result?.get().first)
        #expect(variable.id == "customers[100]")
        #expect(variable.containerReference == 700)
        #expect(variable.namedVariables == 4)
        #expect(variable.indexedVariables == 5)
    }

    @Test
    func stoppedEventLoadsThreadStackScopeAndVariablesInOrder() throws {
        let transport = RecordingTransport()
        let core = RecordingDebugProtocolCore()
        let descriptor = DebugProviderDescriptor(
            id: "java",
            displayName: "Java",
            fileExtensions: ["java"]
        )
        let manager = DebugAdapterSessionManager(providers: [descriptor]) { _, _ in
            CoreDebugAdapterProtocolSession(
                adapterID: "java",
                transport: transport,
                core: core,
                sessionID: "java-stopped-context",
                deadlineScheduler: RecordingDebugDeadlineScheduler()
            )
        }
        let feature = GenericDebugFeatureModel(sessions: manager)
        let root = URL(fileURLWithPath: "/tmp/java-stopped-context", isDirectory: true)
        let source = root.appendingPathComponent("src/Main.java")
        var stoppedLocation: (URL, Int, Int)?
        feature.onStoppedLocation = { stoppedLocation = ($0, $1, $2) }
        #expect(feature.start(
            fileURL: source,
            rootURL: root,
            configuration: DebugLaunchConfiguration(
                name: "Main",
                request: .launch,
                arguments: ["mainClass": .string("example.Main")]
            )
        ))
        defer { feature.stop() }

        core.enqueueReceive(sessionID: "java-stopped-context", state: "paused", events: [[
            "sequence": 1,
            "type": "capabilities",
            "capabilities": [
                "supportsConfigurationDone": false,
                "supportsConditionalBreakpoints": false,
                "supportsHitConditionalBreakpoints": false,
                "supportsLogPoints": false,
                "supportsFunctionBreakpoints": false,
                "supportsDataBreakpoints": false,
                "supportsExceptionOptions": false,
                "supportsExceptionFilterOptions": false,
                "supportsSetVariable": false,
                "supportsCancelRequest": false,
                "supportsSingleThreadExecutionRequests": false,
                "supportsRestartRequest": false,
                "supportsTerminateRequest": false,
                "supportsStepBack": false,
                "supportsExceptionInfoRequest": true,
                "supportsStepInTargetsRequest": false,
                "supportsGotoTargetsRequest": false,
                "supportsCompletionsRequest": false,
                "exceptionBreakpointFilters": []
            ]
        ], [
            "sequence": 2,
            "type": "stopped",
            "reason": "exception",
            "threadId": 13,
            "description": "java.lang.IllegalStateException: session expired"
        ]])
        transport.emitData(Data("stopped-event".utf8))
        #expect(core.inspectionRequests.map(\.kind) == ["exceptionInfo", "threads"])

        let threadsOperationID = try #require(
            core.inspectionRequests.first(where: { $0.kind == "threads" })?.operationID
        )
        core.enqueueReceive(sessionID: "java-stopped-context", state: "paused", events: [[
            "sequence": 2,
            "type": "operationCompleted",
            "operationId": threadsOperationID,
            "result": [
                "kind": "threads",
                "threads": [
                    ["id": 2, "name": "Reference Handler"],
                    ["id": 13, "name": "http-nio-exec-1"]
                ]
            ]
        ]])
        transport.emitData(Data("threads-response".utf8))
        #expect(core.inspectionRequests.map(\.kind) == [
            "exceptionInfo", "threads", "stackTrace"
        ])
        #expect(core.inspectionRequests.last?.threadID == 13)

        let stackOperationID = try #require(
            core.inspectionRequests.first(where: { $0.kind == "stackTrace" })?.operationID
        )
        core.enqueueReceive(sessionID: "java-stopped-context", state: "paused", events: [[
            "sequence": 3,
            "type": "operationCompleted",
            "operationId": stackOperationID,
            "result": [
                "kind": "stackTrace",
                "stackFrames": [[
                    "id": 70,
                    "name": "example.Main.run",
                    "sourcePath": source.path,
                    "line": 12,
                    "column": 5
                ]]
            ]
        ]])
        transport.emitData(Data("stack-response".utf8))
        #expect(core.inspectionRequests.map(\.kind) == [
            "exceptionInfo", "threads", "stackTrace", "scopes"
        ])
        #expect(core.inspectionRequests.last?.frameID == 70)

        let scopesOperationID = try #require(
            core.inspectionRequests.first(where: { $0.kind == "scopes" })?.operationID
        )
        core.enqueueReceive(sessionID: "java-stopped-context", state: "paused", events: [[
            "sequence": 4,
            "type": "operationCompleted",
            "operationId": scopesOperationID,
            "result": [
                "kind": "scopes",
                "scopes": [[
                    "name": "Locals",
                    "variablesReference": 200,
                    "expensive": false
                ], [
                    "name": "Fields",
                    "variablesReference": 201,
                    "expensive": true
                ]]
            ]
        ]])
        transport.emitData(Data("scopes-response".utf8))
        #expect(core.inspectionRequests.map(\.kind) == [
            "exceptionInfo", "threads", "stackTrace", "scopes", "variables"
        ])
        #expect(core.inspectionRequests.last?.variablesReference == 200)
        #expect(feature.selectedScopeID == feature.scopes.first?.id)

        let fieldsScope = try #require(feature.scopes.last)
        feature.selectScope(fieldsScope)
        #expect(core.inspectionRequests.last?.kind == "variables")
        #expect(core.inspectionRequests.last?.variablesReference == 201)

        let variablesOperationID = try #require(
            core.inspectionRequests.first(where: { $0.kind == "variables" })?.operationID
        )
        core.enqueueReceive(sessionID: "java-stopped-context", state: "paused", events: [[
            "sequence": 5,
            "type": "operationCompleted",
            "operationId": variablesOperationID,
            "result": [
                "kind": "variables",
                "variables": [[
                    "name": "count",
                    "value": "7",
                    "type": "int",
                    "variablesReference": 0
                ]]
            ]
        ]])
        transport.emitData(Data("variables-response".utf8))

        #expect(feature.selectedThreadID == 13)
        #expect(feature.stoppedThreadIDs == [13])
        #expect(feature.threads.map(\.id) == [2, 13])
        #expect(feature.selectedFrame?.id == 70)
        #expect(feature.selectedFrame?.isFiltered == false)
        #expect(feature.scopes.first?.variablesReference == 200)
        #expect(feature.variables.first?.value == "7")
        #expect(stoppedLocation?.0 == source.standardizedFileURL)
        #expect(stoppedLocation?.1 == 12)
        #expect(stoppedLocation?.2 == 5)

        let exceptionOperationID = try #require(
            core.inspectionRequests.first(where: { $0.kind == "exceptionInfo" })?.operationID
        )
        core.enqueueReceive(sessionID: "java-stopped-context", state: "paused", events: [[
            "sequence": 6,
            "type": "operationCompleted",
            "operationId": exceptionOperationID,
            "result": [
                "kind": "exceptionInfo",
                "exceptionInfo": [
                    "exceptionId": "java.lang.IllegalStateException",
                    "description": "java.lang.IllegalStateException: session expired",
                    "breakMode": "always"
                ]
            ]
        ]])
        transport.emitData(Data("late-exception-response".utf8))
        #expect(feature.exceptionInfo?.exceptionID == "java.lang.IllegalStateException")

        core.enqueueReceive(sessionID: "java-stopped-context", state: "running", events: [[
            "sequence": 7,
            "type": "continued",
            "threadId": 13
        ]])
        transport.emitData(Data("continued-event".utf8))
        #expect(feature.stoppedThreadIDs.isEmpty)
    }

    @Test
    func javaSteppingFiltersLoadDefaultsAndPersistNormalizedOverrides() {
        let defaults = DebugSteppingFilters(
            classNameFilters: ["$JDK", "org.junit.*"],
            skipSynthetics: true,
            skipStaticInitializers: true,
            skipConstructors: false,
            hideFilteredStackFrames: true
        )
        let normalized = DebugSteppingFilters(
            classNameFilters: ["$JDK", "org.mockito.*"],
            skipSynthetics: true,
            skipStaticInitializers: false,
            skipConstructors: true,
            hideFilteredStackFrames: true
        )
        let resolver = RecordingDebugSteppingFilterResolver(
            defaults: defaults,
            normalizedOverride: normalized
        )
        let persistence = RecordingDebugSteppingFilterPersistence()
        let manager = DebugAdapterSessionManager(providers: []) { _, _ in nil }
        let feature = GenericDebugFeatureModel(
            sessions: manager,
            steppingFilterResolver: resolver,
            steppingFilterPersistence: persistence
        )

        #expect(feature.javaSteppingFilters == defaults)
        #expect(resolver.requests == [RecordingDebugSteppingFilterResolution(
            adapterID: "java",
            filters: nil
        )])

        let override = DebugSteppingFilters(
            classNameFilters: [" org.mockito.* ", "$JDK", "org.mockito.*", ""],
            skipSynthetics: true,
            skipStaticInitializers: false,
            skipConstructors: true,
            hideFilteredStackFrames: true
        )
        feature.updateJavaSteppingFilters(override)

        #expect(resolver.requests.last == RecordingDebugSteppingFilterResolution(
            adapterID: "java",
            filters: override
        ))
        #expect(feature.javaSteppingFilters == normalized)
        #expect(persistence.filtersByAdapterID["java"] == normalized)
    }

    @Test
    func javaSteppingFiltersFallBackToDefaultsWhenPersistenceCannotBeRead() {
        let defaults = DebugSteppingFilters(
            classNameFilters: ["$JDK", "org.junit.*"],
            skipSynthetics: true,
            skipStaticInitializers: true,
            skipConstructors: false,
            hideFilteredStackFrames: true
        )
        let resolver = RecordingDebugSteppingFilterResolver(
            defaults: defaults,
            normalizedOverride: defaults
        )
        let manager = DebugAdapterSessionManager(providers: []) { _, _ in nil }
        let feature = GenericDebugFeatureModel(
            sessions: manager,
            steppingFilterResolver: resolver,
            steppingFilterPersistence: FailingDebugSteppingFilterPersistence()
        )

        #expect(feature.javaSteppingFilters == defaults)
        #expect(feature.errorMessage != nil)
        #expect(resolver.requests == [RecordingDebugSteppingFilterResolution(
            adapterID: "java",
            filters: nil
        )])
    }

    @Test
    func javaLaunchAppliesResolvedSteppingFilters() throws {
        let transport = RecordingTransport()
        let core = RecordingDebugProtocolCore()
        let descriptor = DebugProviderDescriptor(
            id: "java",
            displayName: "Java",
            fileExtensions: ["java"]
        )
        let manager = DebugAdapterSessionManager(providers: [descriptor]) { _, _ in
            CoreDebugAdapterProtocolSession(
                adapterID: "java",
                transport: transport,
                core: core,
                sessionID: "java-stepping-launch",
                deadlineScheduler: RecordingDebugDeadlineScheduler()
            )
        }
        let feature = GenericDebugFeatureModel(
            sessions: manager,
            steppingFilterResolver: core
        )
        let root = URL(fileURLWithPath: "/tmp/java-stepping-launch", isDirectory: true)
        let source = root.appendingPathComponent("src/Main.java")

        #expect(feature.start(
            fileURL: source,
            rootURL: root,
            configuration: DebugLaunchConfiguration(
                name: "Main",
                request: .launch,
                arguments: ["mainClass": .string("example.Main")]
            )
        ))
        defer { feature.stop() }

        #expect(feature.javaSteppingFilters == core.defaultSteppingFilters)
        #expect(core.lastLaunchConfiguration?.steppingFilters == core.defaultSteppingFilters)
    }

    @Test
    func emptyStateFollowsRetainedContentRatherThanRunningStateOrOutput() {
        let session = DeferredInspectionDebugSession()
        let manager = DebugAdapterSessionManager(providers: [
            DebugProviderDescriptor(id: "java", displayName: "Java", fileExtensions: ["java"])
        ]) { _, _ in session }
        let feature = GenericDebugFeatureModel(sessions: manager)
        defer { feature.reset() }
        let root = URL(fileURLWithPath: "/workspace/debug-empty-state", isDirectory: true)
        let source = root.appendingPathComponent("Main.java")
        let configuration = DebugLaunchConfiguration(
            name: "Main", request: .launch, arguments: ["mainClass": .string("Main")]
        )

        #expect(feature.showsEmptyState)
        #expect(feature.start(fileURL: source, rootURL: root, configuration: configuration))
        #expect(!feature.showsEmptyState)
        session.transition(to: .terminated)
        #expect(!feature.isSessionActive)
        #expect(!feature.hasOutput)
        #expect(!feature.showsEmptyState, "A silent terminated session still owns visible content")
        feature.appendDebuggeeOutput("retained output")
        feature.stop()
        #expect(feature.hasOutput)
        #expect(!feature.showsEmptyState, "Stopping the last session must preserve access to retained output")

        session.failNextLaunch = true
        #expect(!feature.start(fileURL: source, rootURL: root, configuration: configuration))
        #expect(feature.sessionSummaries.isEmpty)
        #expect(feature.state == .failed)
        #expect(feature.canRetry)
        #expect(!feature.showsEmptyState, "Failed launch diagnostics must remain accessible")
        feature.stop()
        feature.clearOutput()
        #expect(feature.state == .idle)
        #expect(feature.errorMessage != nil)
        #expect(!feature.showsEmptyState, "Retained errors remain accessible even without output or a session")
        #expect(feature.retry())
        #expect(!feature.showsEmptyState)
        feature.reset()
        #expect(feature.showsEmptyState)
    }

    @Test
    func stoppingTheLastRunningSessionKeepsConsoleOutputUntilItIsCleared() {
        let session = DeferredInspectionDebugSession()
        let feature = makeDeferredFeature(session: session, rootPath: "/workspace/stop-console")
        defer { feature.reset() }
        session.transition(to: .running)
        feature.appendDebuggeeOutput("retained console output\n")
        let output = feature.output
        feature.stop()
        #expect(feature.sessionSummaries.isEmpty)
        #expect(feature.state == .idle)
        #expect(feature.hasOutput)
        #expect(feature.output == output)
        #expect(feature.outputPresentation.text == output)
        #expect(!feature.showsEmptyState)
        feature.clearOutput()
        #expect(feature.showsEmptyState)
    }

    @Test
    func failedSessionCanRetryUsingTheLastLaunchRequest() throws {
        let session = DeferredInspectionDebugSession()
        let descriptor = DebugProviderDescriptor(
            id: "java",
            displayName: "Java",
            fileExtensions: ["java"]
        )
        let manager = DebugAdapterSessionManager(providers: [descriptor]) { _, _ in session }
        let feature = GenericDebugFeatureModel(sessions: manager)
        let root = URL(fileURLWithPath: "/tmp/java-debug-retry", isDirectory: true)
        let source = root.appendingPathComponent("src/Main.java")
        let configuration = DebugLaunchConfiguration(
            name: "Retry Main",
            request: .launch,
            arguments: ["mainClass": .string("example.Main")]
        )

        #expect(feature.start(fileURL: source, rootURL: root, configuration: configuration))
        session.fail()
        #expect(feature.state == .failed)
        #expect(feature.canRetry)
        #expect(feature.retry())
        #expect(session.startCount == 2)
        #expect(session.launchConfigurations == [configuration, configuration])

        feature.stop()
    }

    @Test
    func restartFallsBackToRelaunchWhenAdapterDoesNotAdvertiseRestart() throws {
        let session = DeferredInspectionDebugSession()
        let descriptor = DebugProviderDescriptor(
            id: "java",
            displayName: "Java",
            fileExtensions: ["java"]
        )
        let manager = DebugAdapterSessionManager(providers: [descriptor]) { _, _ in session }
        let feature = GenericDebugFeatureModel(sessions: manager)
        let root = URL(fileURLWithPath: "/tmp/java-debug-restart-fallback", isDirectory: true)
        let source = root.appendingPathComponent("src/Main.java")
        let configuration = DebugLaunchConfiguration(
            name: "Restart Main",
            request: .launch,
            arguments: ["mainClass": .string("example.Main")]
        )

        #expect(feature.start(fileURL: source, rootURL: root, configuration: configuration))
        #expect(feature.state == .paused)
        #expect(!feature.capabilities.supportsRestartRequest)
        #expect(feature.canRestart)

        feature.execute(.restart)

        #expect(session.startCount == 2)
        #expect(session.launchConfigurations == [configuration, configuration])
        feature.stop()
    }

    @Test
    func executionControlsIgnoreOverlappingRequestsUntilSessionLeavesPausedState() throws {
        let session = DeferredInspectionDebugSession()
        let descriptor = DebugProviderDescriptor(
            id: "java",
            displayName: "Java",
            fileExtensions: ["java"]
        )
        let manager = DebugAdapterSessionManager(providers: [descriptor]) { _, _ in session }
        let feature = GenericDebugFeatureModel(sessions: manager)
        let root = URL(fileURLWithPath: "/tmp/java-debug-execution-lock", isDirectory: true)
        let source = root.appendingPathComponent("src/Main.java")
        let configuration = DebugLaunchConfiguration(
            name: "Execution lock",
            request: .launch,
            arguments: ["mainClass": .string("example.Main")]
        )

        #expect(feature.start(fileURL: source, rootURL: root, configuration: configuration))
        feature.execute(.continueExecution)
        feature.execute(.continueExecution)
        #expect(session.executionCommands == [.continueExecution])
        #expect(feature.isExecutionRequestPending)

        session.transition(to: .running)
        #expect(!feature.isExecutionRequestPending)
        session.transition(to: .paused)
        feature.execute(.continueExecution)
        #expect(session.executionCommands == [.continueExecution, .continueExecution])

        feature.stop()
    }

    @Test
    func filteredStackFramesCollapseByConsecutiveRunsAndRestoreOrder() {
        let session = DeferredInspectionDebugSession()
        let descriptor = DebugProviderDescriptor(
            id: "java",
            displayName: "Java",
            fileExtensions: ["java"]
        )
        let manager = DebugAdapterSessionManager(providers: [descriptor]) { _, _ in session }
        let defaults = DebugSteppingFilters(
            classNameFilters: ["$JDK"],
            skipSynthetics: true,
            skipStaticInitializers: true,
            skipConstructors: false,
            hideFilteredStackFrames: true
        )
        let feature = GenericDebugFeatureModel(
            sessions: manager,
            steppingFilterResolver: RecordingDebugSteppingFilterResolver(
                defaults: defaults,
                normalizedOverride: defaults
            )
        )
        let root = URL(fileURLWithPath: "/tmp/java-filtered-stack", isDirectory: true)
        let source = root.appendingPathComponent("src/Main.java")
        #expect(feature.start(
            fileURL: source,
            rootURL: root,
            configuration: DebugLaunchConfiguration(
                name: "Main",
                request: .launch,
                arguments: ["mainClass": .string("example.Main")]
            )
        ))
        defer { feature.stop() }

        feature.selectThread(DebugThread(id: 7, name: "main"))
        session.completeStackTrace(at: 0, with: [
            DebugStackFrame(
                id: 1,
                name: "example.LoginController.login",
                sourceURL: source,
                line: 20,
                column: 5
            ),
            DebugStackFrame(
                id: 2,
                name: "java.lang.reflect.Method.invoke",
                sourceURL: nil,
                line: 1,
                column: 1,
                isFiltered: true
            ),
            DebugStackFrame(
                id: 3,
                name: "org.springframework.cglib.Proxy.invoke",
                sourceURL: nil,
                line: 1,
                column: 1,
                isFiltered: true
            ),
            DebugStackFrame(
                id: 4,
                name: "example.Dispatcher.dispatch",
                sourceURL: source,
                line: 42,
                column: 3
            ),
            DebugStackFrame(
                id: 5,
                name: "jdk.proxy1.$Proxy0.invoke",
                sourceURL: nil,
                line: 1,
                column: 1,
                isFiltered: true
            )
        ])

        #expect(feature.hiddenStackFrameCount == 3)
        #expect(feature.visibleStackFrameRows.map(\.id) == [
            "frame-1", "filtered-2", "frame-4", "filtered-5"
        ])
        #expect(feature.visibleStackFrameRows.map(\.hiddenFrameCount) == [0, 2, 0, 1])

        feature.expandFilteredStackFrames()
        #expect(feature.visibleStackFrameRows.compactMap(\.frame?.id) == [1, 2, 3, 4, 5])
        #expect(feature.visibleStackFrameRows.allSatisfy { !$0.isHiddenGroup })

        feature.collapseFilteredStackFrames()
        #expect(feature.visibleStackFrameRows.map(\.id) == [
            "frame-1", "filtered-2", "frame-4", "filtered-5"
        ])
    }

    @Test
    func stoppedStackPrefersTheFirstSourceBackedUnfilteredFrame() throws {
        let session = DeferredInspectionDebugSession()
        let descriptor = DebugProviderDescriptor(
            id: "java",
            displayName: "Java",
            fileExtensions: ["java"]
        )
        let manager = DebugAdapterSessionManager(providers: [descriptor]) { _, _ in session }
        let feature = GenericDebugFeatureModel(sessions: manager)
        let root = URL(fileURLWithPath: "/tmp/java-preferred-frame", isDirectory: true)
        let source = root.appendingPathComponent("src/UserService.java")
        #expect(feature.start(
            fileURL: source,
            rootURL: root,
            configuration: DebugLaunchConfiguration(
                name: "Main",
                request: .launch,
                arguments: ["mainClass": .string("example.Main")]
            )
        ))
        defer { feature.stop() }

        // Java adapters can report a synthetic method-handle frame above the
        // actual application frame. The initial inspection must land on the
        // application source while retaining the synthetic frame in the list.
        feature.selectThread(DebugThread(id: 7, name: "http-worker"))
        let synthetic = DebugStackFrame(
            id: 1,
            name: "java.lang.invoke.MethodHandle.invokeVirtual",
            sourceURL: nil,
            line: 1,
            column: 1,
            isFiltered: true
        )
        let application = DebugStackFrame(
            id: 2,
            name: "example.UserService.listUsers",
            sourceURL: source,
            line: 18,
            column: 5
        )
        session.completeStackTrace(at: 0, with: [synthetic, application])

        #expect(feature.stackFrames.map(\.id) == [1, 2])
        #expect(feature.selectedFrameID == 2)
        #expect(feature.selectedFrame?.sourceURL == source)
        #expect(session.scopeFrameIDs == [2])
    }

    @Test
    func rapidInspectionSelectionDiscardsOutOfOrderResults() throws {
        let session = DeferredInspectionDebugSession()
        let descriptor = DebugProviderDescriptor(
            id: "java",
            displayName: "Java",
            fileExtensions: ["java"]
        )
        let manager = DebugAdapterSessionManager(providers: [descriptor]) { _, _ in session }
        let feature = GenericDebugFeatureModel(sessions: manager)
        let root = URL(fileURLWithPath: "/tmp/java-inspection-selection", isDirectory: true)
        let source = root.appendingPathComponent("src/Main.java")
        #expect(feature.start(
            fileURL: source,
            rootURL: root,
            configuration: DebugLaunchConfiguration(
                name: "Main",
                request: .launch,
                arguments: ["mainClass": .string("example.Main")]
            )
        ))
        defer { feature.stop() }

        let firstThread = DebugThread(id: 1, name: "worker-1")
        let secondThread = DebugThread(id: 2, name: "worker-2")
        let staleFrame = DebugStackFrame(
            id: 10,
            name: "stale",
            sourceURL: source,
            line: 10,
            column: 1
        )
        let firstFrame = DebugStackFrame(
            id: 20,
            name: "first",
            sourceURL: source,
            line: 20,
            column: 1
        )
        let secondFrame = DebugStackFrame(
            id: 21,
            name: "second",
            sourceURL: source,
            line: 21,
            column: 1
        )

        // The older thread response arrives after the newer selection has
        // already loaded its frames. It must not replace the active stack.
        feature.selectThread(firstThread)
        feature.selectThread(secondThread)
        #expect(session.stackTraceThreadIDs == [1, 2])
        session.completeStackTrace(at: 1, with: [firstFrame, secondFrame])
        session.completeStackTrace(at: 0, with: [staleFrame])

        #expect(feature.selectedThreadID == 2)
        #expect(feature.stackFrames.map(\.id) == [20, 21])
        #expect(feature.selectedFrameID == 20)
        #expect(session.scopeFrameIDs == [20])

        // The first frame's scope response arrives after the second frame was
        // selected. It must not start a stale variables request.
        feature.selectFrame(secondFrame)
        #expect(session.scopeFrameIDs == [20, 21])
        session.completeScopes(
            at: 1,
            with: [DebugScope(id: 210, name: "Locals", variablesReference: 210, expensive: false)]
        )
        session.completeScopes(
            at: 0,
            with: [DebugScope(id: 200, name: "Locals", variablesReference: 200, expensive: false)]
        )

        #expect(feature.selectedFrameID == 21)
        #expect(feature.scopes.map(\.variablesReference) == [210])
        #expect(session.variableReferences == [210])

        // A variables response from the previously selected frame must not
        // overwrite the variables that belong to the current frame.
        feature.selectFrame(firstFrame)
        session.completeScopes(
            at: 2,
            with: [DebugScope(id: 200, name: "Locals", variablesReference: 200, expensive: false)]
        )
        let currentVariable = DebugVariable(
            id: "user",
            name: "user",
            value: "CurrentUser@1",
            type: "CurrentUser",
            evaluateName: "user",
            variablesReference: 300
        )
        session.completeVariables(at: 1, with: [currentVariable])
        session.completeVariables(at: 0, with: [
            DebugVariable(
                id: "stale",
                name: "stale",
                value: "OldUser@1",
                type: "OldUser",
                evaluateName: "stale",
                variablesReference: 0
            )
        ])
        #expect(feature.variables == [currentVariable])

        // Child-variable loading is also scoped to the selected frame.
        feature.toggleVariableExpansion(currentVariable)
        #expect(session.variableReferences == [210, 200, 300])
        feature.selectFrame(secondFrame)
        session.completeVariables(at: 2, with: [
            DebugVariable(
                id: "name",
                name: "name",
                value: "stale child",
                type: "String",
                evaluateName: "user.name",
                variablesReference: 0
            )
        ])
        #expect(feature.variables.isEmpty)
        #expect(feature.variableChildren.isEmpty)
        #expect(feature.loadingVariableIDs.isEmpty)

        session.emit(.continued(threadID: secondThread.id))
        #expect(feature.selectedThreadID == nil)
        #expect(feature.selectedFrameID == nil)
        #expect(feature.stackFrames.isEmpty)
        #expect(feature.scopes.isEmpty)
    }

    @Test
    func runningStateClearsStoppedInspectionBeforeContinuedEvent() throws {
        let session = DeferredInspectionDebugSession()
        let feature = makeDeferredFeature(
            session: session,
            rootPath: "/tmp/java-running-inspection-reset"
        )
        defer { feature.stop() }
        let thread = DebugThread(id: 7, name: "http-worker")
        let frame = DebugStackFrame(
            id: 70,
            name: "UserController.list()",
            sourceURL: URL(fileURLWithPath: "/tmp/java-running-inspection-reset/src/UserController.java"),
            line: 23,
            column: 1
        )
        let service = DebugVariable(
            id: "service",
            name: "service",
            value: "UserService@72",
            type: "UserService",
            evaluateName: "service",
            variablesReference: 0
        )

        feature.selectThread(thread)
        session.completeStackTrace(at: 0, with: [frame])
        session.completeScopes(
            at: 0,
            with: [DebugScope(id: 700, name: "Locals", variablesReference: 700, expensive: false)]
        )
        session.completeVariables(at: 0, with: [service])
        feature.requestAutomaticVariables(["service"])
        session.completeEvaluation(at: 0, with: .success(service))

        #expect(feature.selectedThreadID == thread.id)
        #expect(feature.selectedFrameID == frame.id)
        #expect(feature.selectedScopeID == 700)
        #expect(feature.presentedVariables == [service])

        // The adapter commonly confirms the request before sending its
        // continued event. Running state must not expose the old pause.
        session.transition(to: .running)

        #expect(feature.state == .running)
        #expect(feature.selectedThreadID == nil)
        #expect(feature.selectedFrameID == nil)
        #expect(feature.selectedScopeID == nil)
        #expect(feature.stackFrames.isEmpty)
        #expect(feature.scopes.isEmpty)
        #expect(feature.variables.isEmpty)
        #expect(feature.automaticVariables.isEmpty)
        #expect(feature.presentedVariables.isEmpty)
    }

    @Test
    func automaticVariableInspectionRunsAfterFrameResetAndFallsBackToJavaField() {
        let session = DeferredInspectionDebugSession()
        let feature = makeDeferredFeature(
            session: session,
            rootPath: "/tmp/java-automatic-variable-inspection"
        )
        defer { feature.stop() }
        let frame = DebugStackFrame(
            id: 31,
            name: "UserController.list()",
            sourceURL: URL(fileURLWithPath: "/tmp/java-automatic-variable-inspection/src/UserController.java"),
            line: 23,
            column: 1
        )
        var requestedFrameID: Int?
        feature.onAutomaticVariableInspectionRequest = { selectedFrame in
            requestedFrameID = selectedFrame.id
            feature.requestAutomaticVariables(["service"])
        }

        #expect(feature.state == .paused)
        #expect(feature.providerID == "java")
        feature.selectFrame(frame)
        #expect(requestedFrameID == frame.id)
        #expect(session.evaluateExpressions == ["service"])
        #expect(session.evaluateFrameIDs == [frame.id])

        guard session.evaluateExpressions.count == 1 else { return }
        session.completeEvaluation(at: 0, with: .failure(DeferredDebugSessionError.launchFailed))
        #expect(session.evaluateExpressions == ["service", "this.service"])

        let service = DebugVariable(
            id: "service",
            name: "this.service",
            value: "UserService@72",
            type: "UserService",
            evaluateName: "this.service",
            variablesReference: 72
        )
        guard session.evaluateExpressions.count == 2 else { return }
        session.completeEvaluation(at: 1, with: .success(service))

        #expect(feature.automaticVariables.map(\.name) == ["service"])
        #expect(feature.automaticVariables.map(\.value) == ["UserService@72"])
    }

    @Test
    func largeIndexedVariableCollectionsLoadInBoundedPages() throws {
        let session = DeferredInspectionDebugSession()
        let feature = makeDeferredFeature(
            session: session,
            rootPath: "/tmp/java-large-variable-pages"
        )
        defer { feature.stop() }
        let frame = DebugStackFrame(id: 70, name: "main", sourceURL: nil, line: 12, column: 1)

        feature.selectFrame(frame)
        session.completeScopes(at: 0, with: [DebugScope(
            id: 70,
            name: "Locals",
            variablesReference: 700,
            expensive: false,
            indexedVariables: 250
        )])
        #expect(session.variablePageRequests == [RecordingDebugVariablePageRequest(
            reference: 700,
            filter: .indexed,
            start: 0,
            count: 100
        )])

        session.completeVariables(at: 0, with: indexedVariables(0..<100))
        #expect(feature.variables.count == 100)
        #expect(feature.visibleVariableRows.last?.content == .loadMore(
            parentVariableID: nil,
            nextCount: 100,
            remainingCount: 150
        ))

        feature.loadMoreVariables(parentVariableID: nil)
        #expect(session.variablePageRequests.last == RecordingDebugVariablePageRequest(
            reference: 700,
            filter: .indexed,
            start: 100,
            count: 100
        ))
        session.completeVariables(at: 1, with: indexedVariables(100..<200))
        #expect(feature.visibleVariableRows.last?.content == .loadMore(
            parentVariableID: nil,
            nextCount: 50,
            remainingCount: 50
        ))

        feature.loadMoreVariables(parentVariableID: nil)
        #expect(session.variablePageRequests.last == RecordingDebugVariablePageRequest(
            reference: 700,
            filter: .indexed,
            start: 200,
            count: 50
        ))
        session.completeVariables(at: 2, with: indexedVariables(200..<250))

        #expect(feature.variables.count == 250)
        #expect(feature.variables.first?.name == "[0]")
        #expect(feature.variables.last?.name == "[249]")
        #expect(feature.visibleVariableRows.count == 250)
    }

    @Test
    func namedAndIndexedVariableSegmentsLoadInProtocolOrder() throws {
        let session = DeferredInspectionDebugSession()
        let feature = makeDeferredFeature(
            session: session,
            rootPath: "/tmp/java-named-indexed-pages"
        )
        defer { feature.stop() }
        let frame = DebugStackFrame(id: 71, name: "main", sourceURL: nil, line: 12, column: 1)

        feature.selectFrame(frame)
        session.completeScopes(at: 0, with: [DebugScope(
            id: 71,
            name: "Locals",
            variablesReference: 710,
            expensive: false,
            namedVariables: 2,
            indexedVariables: 3
        )])
        #expect(session.variablePageRequests.last == RecordingDebugVariablePageRequest(
            reference: 710,
            filter: .named,
            start: 0,
            count: 2
        ))
        session.completeVariables(at: 0, with: [
            DebugVariable(id: "size", name: "size", value: "3", type: "int", evaluateName: "items.size", variablesReference: 0),
            DebugVariable(id: "empty", name: "empty", value: "false", type: "boolean", evaluateName: "items.empty", variablesReference: 0)
        ])
        #expect(feature.visibleVariableRows.last?.content == .loadMore(
            parentVariableID: nil,
            nextCount: 3,
            remainingCount: 3
        ))

        feature.loadMoreVariables(parentVariableID: nil)
        #expect(session.variablePageRequests.last == RecordingDebugVariablePageRequest(
            reference: 710,
            filter: .indexed,
            start: 0,
            count: 3
        ))
        session.completeVariables(at: 1, with: indexedVariables(0..<3))

        #expect(feature.variables.map(\.name) == ["size", "empty", "[0]", "[1]", "[2]"])
        #expect(feature.visibleVariableRows.count == 5)
    }

    @Test
    func repeatedVariablePageStopsWhenAdapterIgnoresStart() throws {
        let session = DeferredInspectionDebugSession()
        let feature = makeDeferredFeature(
            session: session,
            rootPath: "/tmp/java-ignored-variable-paging"
        )
        defer { feature.stop() }
        let frame = DebugStackFrame(id: 72, name: "main", sourceURL: nil, line: 12, column: 1)

        feature.selectFrame(frame)
        session.completeScopes(at: 0, with: [DebugScope(
            id: 72,
            name: "Locals",
            variablesReference: 720,
            expensive: false,
            indexedVariables: 250
        )])
        session.completeVariables(
            at: 0,
            with: indexedVariables(0..<100, idPrefix: "page-zero")
        )
        feature.loadMoreVariables(parentVariableID: nil)
        #expect(session.variablePageRequests.last?.start == 100)

        session.completeVariables(
            at: 1,
            with: indexedVariables(0..<100, idPrefix: "page-one")
        )

        #expect(feature.variables.count == 100)
        #expect(feature.visibleVariableRows.count == 100)
        feature.loadMoreVariables(parentVariableID: nil)
        #expect(session.variablePageRequests.count == 2)
    }

    @Test
    func staleVariablePageDoesNotEnterNewStackFrame() throws {
        let session = DeferredInspectionDebugSession()
        let feature = makeDeferredFeature(
            session: session,
            rootPath: "/tmp/java-stale-variable-page"
        )
        defer { feature.stop() }
        let firstFrame = DebugStackFrame(id: 80, name: "first", sourceURL: nil, line: 12, column: 1)
        let secondFrame = DebugStackFrame(id: 81, name: "second", sourceURL: nil, line: 20, column: 1)

        feature.selectFrame(firstFrame)
        session.completeScopes(at: 0, with: [DebugScope(
            id: 80,
            name: "Locals",
            variablesReference: 800,
            expensive: false,
            indexedVariables: 250
        )])
        session.completeVariables(at: 0, with: indexedVariables(0..<100))
        feature.loadMoreVariables(parentVariableID: nil)

        feature.selectFrame(secondFrame)
        session.completeScopes(at: 1, with: [DebugScope(
            id: 81,
            name: "Locals",
            variablesReference: 810,
            expensive: false,
            indexedVariables: 1
        )])
        let current = DebugVariable(
            id: "current",
            name: "current",
            value: "true",
            type: "boolean",
            evaluateName: "current",
            variablesReference: 0
        )
        session.completeVariables(at: 2, with: [current])
        session.completeVariables(at: 1, with: indexedVariables(100..<200))

        #expect(feature.selectedFrameID == 81)
        #expect(feature.variables == [current])
        #expect(feature.visibleVariableRows.map(\.variable) == [current])
    }

    @Test
    func exceptionStopsLoadCurrentMetadataAndDiscardStaleResponses() throws {
        let capabilities = DebugAdapterCapabilities(
            negotiated: true,
            supportsExceptionInfoRequest: true
        )
        let session = DeferredInspectionDebugSession(capabilities: capabilities)
        let descriptor = DebugProviderDescriptor(
            id: "java",
            displayName: "Java",
            fileExtensions: ["java"]
        )
        let manager = DebugAdapterSessionManager(providers: [descriptor]) { _, _ in session }
        let feature = GenericDebugFeatureModel(sessions: manager)
        let root = URL(fileURLWithPath: "/tmp/java-exception-info", isDirectory: true)
        let source = root.appendingPathComponent("src/Main.java")
        #expect(feature.start(
            fileURL: source,
            rootURL: root,
            configuration: DebugLaunchConfiguration(
                name: "Main",
                request: .launch,
                arguments: ["mainClass": .string("example.Main")]
            )
        ))
        defer { feature.stop() }
        session.emit(.capabilities(capabilities))

        let staleInfo = DebugExceptionInfo(
            exceptionID: "example.StaleException",
            description: "stale",
            breakMode: "always",
            details: nil
        )
        let currentInfo = DebugExceptionInfo(
            exceptionID: "example.LoginException",
            description: "Login failed",
            breakMode: "userUnhandled",
            details: nil
        )

        session.emit(.stopped(reason: "exception", threadID: 1, description: "stale stop"))
        #expect(session.exceptionInfoThreadIDs == [1])
        session.emit(.stopped(reason: "breakpoint", threadID: 2, description: nil))
        session.completeExceptionInfo(at: 0, with: staleInfo)
        #expect(feature.exceptionInfo == nil)

        session.emit(.stopped(reason: "exception", threadID: 3, description: "Login failed"))
        #expect(session.exceptionInfoThreadIDs == [1, 3])
        session.completeExceptionInfo(at: 1, with: currentInfo)
        #expect(feature.exceptionInfo == currentInfo)

        session.emit(.continued(threadID: 3))
        #expect(feature.exceptionInfo == nil)
        session.emit(.capabilities(.unknown))
        session.emit(.stopped(reason: "exception", threadID: 4, description: nil))
        #expect(session.exceptionInfoThreadIDs == [1, 3])

        session.emit(.capabilities(capabilities))
        session.emit(.stopped(reason: "exception", threadID: 5, description: nil))
        session.completeExceptionInfo(at: 2, with: currentInfo)
        #expect(feature.exceptionInfo == currentInfo)
        session.emit(.terminated(exitCode: 1))
        #expect(feature.exceptionInfo == nil)
    }

    @Test
    func expandingSelfReferentialVariableDoesNotRecurseForever() throws {
        let session = DeferredInspectionDebugSession()
        let feature = makeDeferredFeature(
            session: session,
            rootPath: "/tmp/java-self-referential-variable"
        )
        defer { feature.stop() }

        session.emit(.stopped(reason: "breakpoint", threadID: 1, description: nil))
        feature.loadVariables(reference: 100)
        session.completeVariables(at: 0, with: [DebugVariable(
            id: "self",
            name: "self",
            value: "Node@1",
            type: "Node",
            evaluateName: "self",
            variablesReference: 101,
            containerReference: 100,
            namedVariables: 1,
            indexedVariables: 0
        )])

        let root = try #require(feature.variables.first)
        feature.toggleVariableExpansion(root)
        session.completeVariables(at: 1, with: [DebugVariable(
            id: "self",
            name: "self",
            value: "Node@1",
            type: "Node",
            evaluateName: "self",
            variablesReference: 101,
            containerReference: 101,
            namedVariables: 1,
            indexedVariables: 0
        )])

        #expect(feature.visibleVariableRows.map(\.depth) == [0, 1])
        #expect(feature.visibleVariableRows.compactMap { $0.variable?.name } == ["self", "self"])
    }

    @Test
    func genericBreakpointsPreserveAdvancedOptionsAcrossMuteAndClear() throws {
        let transport = RecordingTransport()
        let core = RecordingDebugProtocolCore()
        let descriptor = DebugProviderDescriptor(
            id: "java",
            displayName: "Java",
            fileExtensions: ["java"]
        )
        let manager = DebugAdapterSessionManager(providers: [descriptor]) { _, _ in
            CoreDebugAdapterProtocolSession(
                adapterID: "java",
                transport: transport,
                core: core,
                sessionID: "java-breakpoints",
                deadlineScheduler: RecordingDebugDeadlineScheduler()
            )
        }
        let feature = GenericDebugFeatureModel(sessions: manager)
        let root = URL(fileURLWithPath: "/tmp/java-breakpoints", isDirectory: true)
        let source = root.appendingPathComponent("Main.java")

        feature.toggleBreakpoint(fileURL: source, line: 12)
        feature.updateBreakpoint(
            fileURL: source,
            line: 12,
            enabled: true,
            condition: "value > 1",
            hitCondition: "3",
            logMessage: "value = {value}"
        )
        feature.toggleBreakpointMute()

        #expect(feature.breakpoints.count == 1)
        #expect(feature.breakpoints[0].condition == "value > 1")
        #expect(feature.breakpoints[0].hitCondition == "3")
        #expect(feature.breakpoints[0].logMessage == "value = {value}")
        #expect(feature.areBreakpointsMuted)
        #expect(feature.start(
            fileURL: source,
            rootURL: root,
            configuration: DebugLaunchConfiguration(
                name: "Main",
                request: .launch,
                arguments: ["mainClass": .string("example.Main")]
            )
        ))
        #expect(core.breakpointUpdates.last == [DebugSourceBreakpoint(
            line: 12,
            enabled: false,
            condition: "value > 1",
            hitCondition: "3",
            logMessage: "value = {value}"
        )])

        core.enqueueReceive(sessionID: "java-breakpoints", state: "ready", events: [[
            "sequence": 2,
            "type": "capabilities",
            "capabilities": [
                "supportsConfigurationDone": true,
                "supportsConditionalBreakpoints": true,
                "supportsHitConditionalBreakpoints": true,
                "supportsLogPoints": true,
                "supportsFunctionBreakpoints": true,
                "supportsDataBreakpoints": true,
                "supportsExceptionOptions": false,
                "supportsExceptionFilterOptions": true,
                "supportsSetVariable": false,
                "supportsCancelRequest": false,
                "supportsSingleThreadExecutionRequests": false,
                "supportsRestartRequest": false,
                "supportsTerminateRequest": false,
                "supportsStepBack": false,
                "supportsExceptionInfoRequest": false,
                "supportsStepInTargetsRequest": false,
                "supportsGotoTargetsRequest": false,
                "supportsCompletionsRequest": false,
                "exceptionBreakpointFilters": [[
                    "filter": "caught",
                    "label": "Caught Exceptions",
                    "description": "Pause when an exception is caught.",
                    "default": false,
                    "supportsCondition": true,
                    "conditionDescription": "Exception class pattern"
                ], [
                    "filter": "uncaught",
                    "label": "Uncaught Exceptions",
                    "default": true,
                    "supportsCondition": false
                ]]
            ]
        ]])
        transport.emitData(Data("capabilities-response".utf8))
        #expect(feature.exceptionBreakpoints.map(\.filter) == ["caught", "uncaught"])
        #expect(feature.exceptionBreakpoints.last?.enabled == true)
        feature.updateExceptionBreakpoint(
            try #require(feature.exceptionBreakpoints.first),
            enabled: true,
            condition: "example.CustomException"
        )
        #expect(core.exceptionBreakpointUpdates.last == [
            DebugExceptionBreakpoint(
                filter: "caught",
                enabled: true,
                condition: "example.CustomException"
            ),
            DebugExceptionBreakpoint(filter: "uncaught", enabled: true)
        ])
        feature.addFunctionBreakpoint(
            name: " example.Main.run ",
            condition: "ready",
            hitCondition: "2"
        )
        #expect(feature.functionBreakpoints.first?.name == "example.Main.run")
        #expect(core.functionBreakpointUpdates.last == [
            DebugFunctionBreakpoint(
                name: "example.Main.run",
                enabled: true,
                condition: "ready",
                hitCondition: "2"
            )
        ])
        core.enqueueReceive(sessionID: "java-breakpoints", state: "ready", events: [[
            "sequence": 3,
            "type": "breakpoint",
            "breakpoint": [
                "id": 8,
                "verified": true,
                "functionName": "example.Main.run"
            ]
        ]])
        transport.emitData(Data("function-breakpoint-response".utf8))
        #expect(feature.functionBreakpoints.first?.verified == true)

        core.enqueueReceive(sessionID: "java-breakpoints", state: "paused", events: [[
            "sequence": 4,
            "type": "stopped",
            "reason": "breakpoint"
        ]])
        transport.emitData(Data("stopped-event".utf8))
        feature.addWatch(" count ")
        let staleWatchOperationID = try #require(core.lastInspectionOperationID)
        feature.updateWatch(try #require(feature.watches.first), expression: "count + 1")
        let watchOperationID = try #require(core.lastInspectionOperationID)
        core.enqueueReceive(sessionID: "java-breakpoints", state: "paused", events: [[
            "sequence": 5,
            "type": "operationCompleted",
            "operationId": staleWatchOperationID,
            "result": [
                "kind": "evaluate",
                "variable": [
                    "name": "count",
                    "value": "7",
                    "type": "int",
                    "variablesReference": 0
                ]
            ]
        ]])
        transport.emitData(Data("stale-watch-response".utf8))
        #expect(feature.watches.first?.expression == "count + 1")
        #expect(feature.watches.first?.value == nil)
        core.enqueueReceive(sessionID: "java-breakpoints", state: "paused", events: [[
            "sequence": 6,
            "type": "operationCompleted",
            "operationId": watchOperationID,
            "result": [
                "kind": "evaluate",
                "variable": [
                    "name": "count + 1",
                    "value": "8",
                    "type": "int",
                    "variablesReference": 0
                ]
            ]
        ]])
        transport.emitData(Data("watch-response".utf8))
        #expect(feature.watches.first?.value == "8")

        var hoverValue: DebugVariable?
        feature.evaluateForHover("count") { hoverValue = $0 }
        let hoverOperationID = try #require(core.lastInspectionOperationID)
        core.enqueueReceive(sessionID: "java-breakpoints", state: "paused", events: [[
            "sequence": 7,
            "type": "operationCompleted",
            "operationId": hoverOperationID,
            "result": [
                "kind": "evaluate",
                "variable": [
                    "name": "count",
                    "value": "7",
                    "type": "int",
                    "variablesReference": 0
                ]
            ]
        ]])
        transport.emitData(Data("hover-response".utf8))
        #expect(hoverValue?.value == "7")

        var staleHoverValue: DebugVariable?
        feature.evaluateForHover("count") { staleHoverValue = $0 }
        let staleHoverOperationID = try #require(core.lastInspectionOperationID)
        core.enqueueReceive(sessionID: "java-breakpoints", state: "running", events: [[
            "sequence": 8,
            "type": "stateChanged",
            "state": "running"
        ], [
            "sequence": 9,
            "type": "operationCompleted",
            "operationId": staleHoverOperationID,
            "result": [
                "kind": "evaluate",
                "variable": [
                    "name": "count",
                    "value": "8",
                    "type": "int",
                    "variablesReference": 0
                ]
            ]
        ]])
        transport.emitData(Data("stale-hover-response".utf8))
        #expect(staleHoverValue == nil)
        core.enqueueReceive(sessionID: "java-breakpoints", state: "paused", events: [[
            "sequence": 10,
            "type": "stopped",
            "reason": "breakpoint"
        ]])
        transport.emitData(Data("next-stopped-event".utf8))

        feature.requestDataBreakpoint(for: DebugVariable(
            id: "count",
            name: "count",
            value: "1",
            type: "int",
            evaluateName: "this.count",
            variablesReference: 0,
            containerReference: 42
        ))
        let dataOperationID = try #require(core.lastDataBreakpointInfoOperationID)
        core.enqueueReceive(sessionID: "java-breakpoints", state: "paused", events: [[
            "sequence": 5,
            "type": "operationCompleted",
            "operationId": dataOperationID,
            "result": [
                "kind": "dataBreakpointInfo",
                "dataId": "field:count",
                "description": "Main.count",
                "accessTypes": ["read", "write"],
                "canPersist": true
            ]
        ]])
        transport.emitData(Data("data-info-response".utf8))
        #expect(feature.dataBreakpoints.first?.accessType == "write")
        #expect(core.dataBreakpointUpdates.last == [DebugDataBreakpoint(
            dataID: "field:count",
            label: "Main.count",
            accessType: "write"
        )])

        feature.loadVariables(reference: 100)
        let rootVariablesOperationID = try #require(core.lastInspectionOperationID)
        core.enqueueReceive(sessionID: "java-breakpoints", state: "paused", events: [[
            "sequence": 7,
            "type": "operationCompleted",
            "operationId": rootVariablesOperationID,
            "result": [
                "kind": "variables",
                "variables": [[
                    "name": "user",
                    "value": "User@1",
                    "type": "User",
                    "variablesReference": 101
                ]]
            ]
        ]])
        transport.emitData(Data("root-variables-response".utf8))
        let user = try #require(feature.variables.first)
        feature.toggleVariableExpansion(user)
        let childVariablesOperationID = try #require(core.lastInspectionOperationID)
        core.enqueueReceive(sessionID: "java-breakpoints", state: "paused", events: [[
            "sequence": 8,
            "type": "operationCompleted",
            "operationId": childVariablesOperationID,
            "result": [
                "kind": "variables",
                "variables": [[
                    "name": "name",
                    "value": "Ada",
                    "type": "String",
                    "variablesReference": 0
                ]]
            ]
        ]])
        transport.emitData(Data("child-variables-response".utf8))
        #expect(feature.visibleVariableRows.compactMap { $0.variable?.name } == ["user", "name"])
        #expect(feature.visibleVariableRows.map(\.depth) == [0, 1])
        feature.toggleVariableExpansion(user)
        #expect(feature.visibleVariableRows.compactMap { $0.variable?.name } == ["user"])
        #expect(feature.variables.first?.name == "user")

        feature.toggleBreakpointMute()
        #expect(core.breakpointUpdates.last?.first?.enabled == true)
        feature.removeAllBreakpoints()
        #expect(feature.breakpoints.isEmpty)
        #expect(core.breakpointUpdates.last?.isEmpty == true)

        feature.stop()
        #expect(feature.watches.first?.expression == "count + 1")
        #expect(feature.watches.first?.value == nil)
    }

    @Test
    func projectBreakpointsPersistWithRelativePathsAndRestoreDeterministically() throws {
        let descriptor = DebugProviderDescriptor(
            id: "java",
            displayName: "Java",
            fileExtensions: ["java"]
        )
        let persistence = RecordingBreakpointPersistence()
        let root = URL(fileURLWithPath: "/tmp/persisted-java-breakpoints", isDirectory: true)
        let main = root.appendingPathComponent("src/Main.java")
        let service = root.appendingPathComponent("src/Service.java")
        let manager = DebugAdapterSessionManager(providers: [descriptor]) { _, _ in nil }
        let feature = GenericDebugFeatureModel(
            sessions: manager,
            breakpointPersistence: persistence
        )

        feature.openWorkspace(at: root)
        feature.toggleBreakpoint(fileURL: service, line: 21)
        feature.toggleBreakpoint(fileURL: main, line: 8)
        feature.updateBreakpoint(
            fileURL: main,
            line: 8,
            enabled: false,
            condition: "ready",
            hitCondition: "3",
            logMessage: "ready = {ready}"
        )
        feature.toggleBreakpointMute()

        let saved = try #require(persistence.snapshots[root.standardizedFileURL])
        #expect(saved.areBreakpointsMuted)
        #expect(saved.breakpoints.map(\.relativePath) == ["src/Main.java", "src/Service.java"])
        #expect(saved.breakpoints.first == PersistedDebugBreakpoint(
            relativePath: "src/Main.java",
            line: 8,
            enabled: false,
            condition: "ready",
            hitCondition: "3",
            logMessage: "ready = {ready}"
        ))

        let restored = GenericDebugFeatureModel(
            sessions: DebugAdapterSessionManager(providers: [descriptor]) { _, _ in nil },
            breakpointPersistence: persistence
        )
        restored.openWorkspace(at: root)

        #expect(restored.areBreakpointsMuted)
        #expect(restored.breakpoints.map(\.fileURL) == [main, service])
        #expect(restored.breakpoints.map(\.line) == [8, 21])
        #expect(restored.breakpoints.first?.enabled == false)
        #expect(restored.breakpoints.first?.verified == false)
    }

    @Test
    func sourceEditRelocatesPersistsAndResynchronizesBreakpoints() throws {
        let descriptor = DebugProviderDescriptor(
            id: "java",
            displayName: "Java",
            fileExtensions: ["java"]
        )
        let session = DeferredInspectionDebugSession()
        let manager = DebugAdapterSessionManager(providers: [descriptor]) { _, _ in session }
        let persistence = RecordingBreakpointPersistence()
        let relocator = RecordingBreakpointRelocator(result: [
            DebugSourceBreakpoint(line: 3, condition: "ready")
        ])
        let root = URL(fileURLWithPath: "/tmp/relocated-java-breakpoints", isDirectory: true)
        let sourceURL = root.appendingPathComponent("src/Main.java")
        let feature = GenericDebugFeatureModel(
            sessions: manager,
            breakpointPersistence: persistence,
            breakpointRelocator: relocator
        )
        feature.openWorkspace(at: root)
        feature.toggleBreakpoint(fileURL: sourceURL, line: 2)
        feature.updateBreakpoint(
            fileURL: sourceURL,
            line: 2,
            enabled: true,
            condition: "ready",
            hitCondition: nil,
            logMessage: nil
        )
        #expect(feature.start(
            fileURL: sourceURL,
            rootURL: root,
            configuration: DebugLaunchConfiguration(
                name: "Main",
                request: .launch,
                arguments: ["mainClass": .string("example.Main")]
            )
        ))
        defer { feature.stop() }

        let source = "class Main {\n    void run() {}\n}\n"
        feature.applySourceEdit(
            fileURL: sourceURL,
            source: source,
            edit: DebugSourceEdit(
                startUTF16Offset: 13,
                endUTF16Offset: 13,
                replacement: "\n"
            )
        )

        #expect(relocator.requests == [RecordingBreakpointRelocationRequest(
            source: source,
            edit: DebugSourceEdit(
                startUTF16Offset: 13,
                endUTF16Offset: 13,
                replacement: "\n"
            ),
            breakpoints: [DebugSourceBreakpoint(line: 2, condition: "ready")]
        )])
        #expect(feature.breakpoints.map(\.line) == [3])
        #expect(session.breakpointUpdates.last == [
            DebugSourceBreakpoint(line: 3, condition: "ready")
        ])
        #expect(persistence.snapshots[root.standardizedFileURL]?.breakpoints.map(\.line) == [3])
    }

    @Test
    func inlineEditSkipsRelocationForLineOnlyBreakpoints() {
        let descriptor = DebugProviderDescriptor(
            id: "java",
            displayName: "Java",
            fileExtensions: ["java"]
        )
        let relocator = RecordingBreakpointRelocator(result: [])
        let root = URL(fileURLWithPath: "/tmp/inline-java-breakpoint-edit", isDirectory: true)
        let sourceURL = root.appendingPathComponent("src/Main.java")
        let feature = GenericDebugFeatureModel(
            sessions: DebugAdapterSessionManager(providers: [descriptor]) { _, _ in nil },
            breakpointRelocator: relocator
        )
        feature.openWorkspace(at: root)
        feature.toggleBreakpoint(fileURL: sourceURL, line: 2)
        let source = "class Main {\n    void run() {}\n}\n"
        let editOffset = (source as NSString).range(of: "run").location + 3

        feature.applySourceEdit(
            fileURL: sourceURL,
            source: source,
            edit: DebugSourceEdit(
                startUTF16Offset: editOffset,
                endUTF16Offset: editOffset,
                replacement: "Now"
            )
        )

        #expect(relocator.requests.isEmpty)
        #expect(feature.breakpoints.map(\.line) == [2])
    }

    @Test
    func projectBreakpointRestoreRejectsPathsOutsideTheWorkspace() {
        let root = URL(fileURLWithPath: "/tmp/safe-java-breakpoints", isDirectory: true)
        let persistence = RecordingBreakpointPersistence()
        persistence.snapshots[root.standardizedFileURL] = DebugBreakpointSnapshot(breakpoints: [
            PersistedDebugBreakpoint(relativePath: "../Outside.java", line: 4),
            PersistedDebugBreakpoint(relativePath: "/tmp/Absolute.java", line: 5),
            PersistedDebugBreakpoint(relativePath: "src/Main.java", line: 6)
        ])
        let manager = DebugAdapterSessionManager(
            providers: [DebugProviderDescriptor(
                id: "java",
                displayName: "Java",
                fileExtensions: ["java"]
            )]
        ) { _, _ in nil }
        let feature = GenericDebugFeatureModel(
            sessions: manager,
            breakpointPersistence: persistence
        )

        feature.openWorkspace(at: root)

        #expect(feature.breakpoints.map(\.fileURL) == [root.appendingPathComponent("src/Main.java")])
        #expect(feature.breakpoints.map(\.line) == [6])
    }

    @Test
    func disabledDebugDoesNotConstructGraph() async throws {
        let recorder = Recorder()
        let runtime = ModuleRuntime()
        try runtime.register(workspaceFactory())
        try runtime.register(languageFactory())
        try runtime.register(executionFactory())
        try runtime.register(ModuleFactory(manifest: DebugModule.moduleManifest, contributions: DebugModule.moduleContributions) {
            recorder.factoryCalls += 1
            return DebugModule(makeGraph: {
                recorder.graphCalls += 1
                return TestGraph()
            })
        }, enabled: false)

        await #expect(throws: ModuleRuntimeError.moduleDisabled(.debug)) {
            _ = try await runtime.activateCapability(.debugWorkspace)
        }
        #expect(recorder.factoryCalls == 0)
        #expect(recorder.graphCalls == 0)
    }

    @Test
    func sleepReleasesDebugGraphAndWakeCreatesNewOne() async throws {
        let recorder = Recorder()
        let runtime = ModuleRuntime()
        try runtime.register(workspaceFactory())
        try runtime.register(languageFactory())
        try runtime.register(executionFactory())
        try runtime.register(ModuleFactory(manifest: DebugModule.moduleManifest, contributions: DebugModule.moduleContributions) {
            recorder.factoryCalls += 1
            return DebugModule(makeGraph: {
                recorder.graphCalls += 1
                let graph = TestGraph()
                recorder.latestGraph = graph
                return graph
            })
        })

        let first = try #require(
            try await runtime.activateCapability(.debugWorkspace) as? DebugModuleCapability
        )
        let firstFeatureID = ObjectIdentifier(first.genericFeature)
        weak var released = recorder.latestGraph
        try await runtime.sleep(.debug)

        #expect(released == nil)
        #expect(runtime.capability(.debugWorkspace) == nil)
        #expect(try runtime.snapshot(for: .debug).activity.activeResourceCount == 0)

        let second = try #require(
            try await runtime.activateCapability(.debugWorkspace) as? DebugModuleCapability
        )
        #expect(ObjectIdentifier(second.genericFeature) != firstFeatureID)
        #expect(recorder.factoryCalls == 2)
        #expect(recorder.graphCalls == 2)
    }

    // MARK: - Disassembly, instruction stepping, instruction breakpoints and memory

    private static let disassemblyCapabilities = DebugAdapterCapabilities(
        negotiated: true,
        supportsDisassembleRequest: true,
        supportsSteppingGranularity: true,
        supportsInstructionBreakpoints: true,
        supportsReadMemoryRequest: true
    )

    /// A Core capability snapshot with everything off except the given flags.
    private static func coreCapabilities(_ enabled: [String: Bool]) -> [String: Any] {
        var snapshot: [String: Any] = [
            "supportsConfigurationDone": false,
            "supportsConditionalBreakpoints": false,
            "supportsHitConditionalBreakpoints": false,
            "supportsLogPoints": false,
            "supportsFunctionBreakpoints": false,
            "supportsDataBreakpoints": false,
            "supportsExceptionOptions": false,
            "supportsExceptionFilterOptions": false,
            "supportsSetVariable": false,
            "supportsCancelRequest": false,
            "supportsSingleThreadExecutionRequests": false,
            "supportsRestartRequest": false,
            "supportsTerminateRequest": false,
            "supportsStepBack": false,
            "supportsExceptionInfoRequest": false,
            "supportsStepInTargetsRequest": false,
            "supportsGotoTargetsRequest": false,
            "supportsCompletionsRequest": false,
            "exceptionBreakpointFilters": [[String: Any]]()
        ]
        for (key, value) in enabled { snapshot[key] = value }
        return snapshot
    }

    private func instruction(
        _ address: String,
        _ text: String,
        symbol: String? = nil
    ) -> DebugDisassembledInstruction {
        DebugDisassembledInstruction(
            address: address,
            instructionBytes: nil,
            instruction: text,
            symbol: symbol
        )
    }

    /// A started feature that has received the capabilities the adapter negotiated, as it does
    /// right after `initialize` in a real session.
    private func makeDisassemblyFeature(
        session: DeferredInspectionDebugSession,
        rootPath: String
    ) -> GenericDebugFeatureModel {
        let feature = makeDeferredFeature(session: session, rootPath: rootPath)
        session.emit(.capabilities(session.capabilities))
        return feature
    }

    /// A feature stopped in a frame that has no source, as in a program built without debug info.
    private func makeSourcelessStop(
        session: DeferredInspectionDebugSession,
        rootPath: String,
        address: String = "0x19b5f2a4c"
    ) -> (feature: GenericDebugFeatureModel, frame: DebugStackFrame) {
        let feature = makeDisassemblyFeature(session: session, rootPath: rootPath)
        let frame = DebugStackFrame(
            id: 5,
            name: "__pthread_kill",
            sourceURL: nil,
            line: 0,
            column: 0,
            instructionPointerReference: address
        )
        feature.selectThread(DebugThread(id: 1, name: "main"))
        session.completeStackTrace(at: 0, with: [frame])
        return (feature, frame)
    }

    @Test
    func instructionAddressesAreComparedAsTextWithoutArithmetic() {
        #expect(DebugAddressText.canonical("0x0000000100003F50") == "100003f50")
        #expect(DebugAddressText.canonical("0X0") == "0")
        #expect(DebugAddressText.canonical("0x0000") == "0")
        #expect(DebugAddressText.areEqual("0x100003f50", "0x0000000100003F50"))
        #expect(!DebugAddressText.areEqual("0x100003f50", "0x100003f51"))
        // A 64-bit pointer that an Int or a JSON number would round or wrap stays distinct.
        #expect(!DebugAddressText.areEqual("0xffffffffffffffff", "0xfffffffffffffffe"))
        #expect(
            DebugAddressText.firstHexLiteral(in: "0x000000016fdff8a0 -> 0x1")
                == "0x000000016fdff8a0"
        )
        #expect(DebugAddressText.firstHexLiteral(in: "no pointer here") == nil)
        #expect(DebugAddressText.isHexLiteral(" 0xdeadBEEF "))
        #expect(!DebugAddressText.isHexLiteral("rsp"))
        #expect(!DebugAddressText.isHexLiteral("0x"))
    }

    @Test
    func memoryDisplayRowsShowHexBytesAndMaskNonPrintableCharacters() {
        let bytes = Array("Hello, lldb!".utf8) + [0x00, 0x7f, 0xff, 0x0a, 0x41]

        let rows = GenericDebugMemoryDisplay.standard.rows(of: Data(bytes))
        #expect(rows.map(\.index) == [0, 16])
        #expect(rows[0].cells.map(\.text).joined(separator: " ") == "48 65 6c 6c 6f 2c 20 6c 6c 64 62 21 00 7f ff 0a")
        #expect(rows[0].text == "Hello, lldb!....")
        #expect(rows[1].cells.map(\.text) == ["41"])
        #expect(rows[1].text == "A")
        #expect(GenericDebugMemoryDisplay.standard.rows(of: Data()).isEmpty)
    }

    @Test
    func memoryDisplayGroupsBytesIntoValuesOfTheChosenBaseSizeAndOrder() {
        let data = Data([0x01, 0x02, 0x03, 0x04, 0xff, 0xff, 0xff, 0xfe])

        let words = GenericDebugMemoryDisplay(unitSize: 4, bytesPerRow: 8)
        #expect(words.rows(of: data)[0].cells.map(\.text) == ["04030201", "feffffff"])
        let bigEndian = GenericDebugMemoryDisplay(unitSize: 4, bytesPerRow: 8, byteOrder: .big)
        #expect(bigEndian.rows(of: data)[0].cells.map(\.text) == ["01020304", "fffffffe"])

        let signed = GenericDebugMemoryDisplay(radix: .signedDecimal, unitSize: 4, bytesPerRow: 8, byteOrder: .big)
        #expect(signed.rows(of: data)[0].cells.map { $0.text.trimmingCharacters(in: .whitespaces) } == ["16909060", "-2"])
        let unsigned = GenericDebugMemoryDisplay(radix: .unsignedDecimal, unitSize: 1, bytesPerRow: 8)
        #expect(unsigned.rows(of: data)[0].cells.map { $0.text.trimmingCharacters(in: .whitespaces) }
            == ["1", "2", "3", "4", "255", "255", "255", "254"])
        let octal = GenericDebugMemoryDisplay(radix: .octal, unitSize: 1, bytesPerRow: 8)
        #expect(octal.rows(of: data)[0].cells.map(\.text).prefix(2) == ["001", "002"])
        let binary = GenericDebugMemoryDisplay(radix: .binary, unitSize: 1, bytesPerRow: 8)
        #expect(binary.rows(of: data)[0].cells.map(\.text).prefix(2) == ["00000001", "00000010"])
        let float = GenericDebugMemoryDisplay(radix: .floatingPoint, unitSize: 4, bytesPerRow: 8, byteOrder: .big)
        #expect(float.rows(of: Data([0x3f, 0x80, 0x00, 0x00, 0xc0, 0x00, 0x00, 0x00]))[0].cells
            .map { $0.text.trimmingCharacters(in: .whitespaces) } == ["1", "-2"])
        let double = GenericDebugMemoryDisplay(radix: .floatingPoint, unitSize: 8, bytesPerRow: 8)
        #expect(double.rows(of: Data([0, 0, 0, 0, 0, 0, 0xf8, 0x3f]))[0].cells[0].text
            .trimmingCharacters(in: .whitespaces) == "1.5")
    }

    @Test
    func memoryDisplayRowsHaveAFixedWidthAndShowAnIncompleteTrailingValueAsUnknown() {
        let display = GenericDebugMemoryDisplay(unitSize: 4, bytesPerRow: 16)
        let rows = display.rows(of: Data(repeating: 0xab, count: 22))
        #expect(rows.map(\.index) == [0, 16])
        #expect(rows[0].cells.map(\.index) == [0, 4, 8, 12])
        #expect(rows[1].cells.map(\.text) == ["abababab", "????????"])
        #expect(rows[1].cells.last?.byteCount == 2)
        #expect(display.rowTextWidth == 4 * 8 + 3)
        #expect(rows[0].cells.map(\.text.count) == [8, 8, 8, 8])

        for radix in GenericDebugMemoryDisplay.Radix.allCases {
            for unitSize in GenericDebugMemoryDisplay.unitSizes
            where radix != .floatingPoint || GenericDebugMemoryDisplay.supportsFloatingPoint(unitSize: unitSize) {
                let sample = GenericDebugMemoryDisplay(radix: radix, unitSize: unitSize, bytesPerRow: 8)
                // The widest values must still fit the column, or rows would drift out of line.
                let widest = sample.rows(of: Data(repeating: 0xff, count: 8))[0].cells.map(\.text.count)
                let narrowest = sample.rows(of: Data(repeating: 0x00, count: 8))[0].cells.map(\.text.count)
                #expect(widest.allSatisfy { $0 == sample.cellWidth })
                #expect(narrowest.allSatisfy { $0 == sample.cellWidth })
            }
        }
    }

    @Test
    func memoryDisplayChoicesStayConsistentAndSurviveStorage() {
        // Floating point has no 1 or 2 byte form, so choosing it widens the value.
        let float = GenericDebugMemoryDisplay.standard.selecting(radix: .floatingPoint)
        #expect(float.radix == .floatingPoint)
        #expect(float.unitSize == 4)
        // Narrowing a float afterwards falls back to a base that has such a value.
        #expect(float.selecting(unitSize: 2).radix == .hexadecimal)
        #expect(float.selecting(unitSize: 8).radix == .floatingPoint)

        let unusual = GenericDebugMemoryDisplay(radix: .octal, unitSize: 3, bytesPerRow: 12, byteOrder: .big, showsText: false)
        let repaired = unusual.normalized()
        #expect(repaired.unitSize == 1)
        #expect(repaired.bytesPerRow == 16)
        #expect(repaired.byteOrder == .big)
        #expect(!repaired.showsText)

        let chosen = GenericDebugMemoryDisplay(radix: .signedDecimal, unitSize: 8, bytesPerRow: 32, byteOrder: .big, showsText: false)
        #expect(GenericDebugMemoryDisplay(storedText: chosen.storedText) == chosen)
        #expect(GenericDebugMemoryDisplay(storedText: "") == .standard)
        #expect(GenericDebugMemoryDisplay(storedText: "{not json") == .standard)
        #expect(GenericDebugMemoryDisplay(storedText: "{\"radix\":\"decimal-from-the-future\"}") == .standard)
    }

    @Test
    func memoryDumpKnowsWhereTheRequestedAddressIs() {
        func dump(pageOffset: Int, count: Int) -> GenericDebugMemoryDump {
            GenericDebugMemoryDump(
                reference: "0x1000",
                pageOffset: pageOffset,
                address: "0x0fc0",
                unreadableBytes: 0,
                data: Data(repeating: 0, count: count)
            )
        }
        #expect(dump(pageOffset: -64, count: 256).targetIndex == 64)
        #expect(dump(pageOffset: 0, count: 256).targetIndex == 0)
        // A page that lies entirely after or before the address does not contain it.
        #expect(dump(pageOffset: 256, count: 256).targetIndex == nil)
        #expect(dump(pageOffset: -320, count: 256).targetIndex == nil)
        // The adapter may return fewer bytes than the page size.
        #expect(dump(pageOffset: -64, count: 32).targetIndex == nil)
    }

    @Test
    func coreProtocolSessionRequestsDisassemblyAndMemoryOnlyAfterNegotiation() throws {
        let transport = RecordingTransport()
        let core = RecordingDebugProtocolCore()
        let session = CoreDebugAdapterProtocolSession(
            adapterID: "lldb",
            transport: transport,
            core: core,
            sessionID: "lldb-memory",
            deadlineScheduler: RecordingDebugDeadlineScheduler()
        )
        try session.start(rootURL: URL(fileURLWithPath: "/tmp/lldb-memory", isDirectory: true))
        defer { session.stop() }

        var early: Result<[DebugDisassembledInstruction], Error>?
        session.requestDisassembly(
            memoryReference: "0x100003f50",
            instructionOffset: -4,
            instructionCount: 8
        ) { early = $0 }
        var earlyMemory: Result<DebugMemoryRead, Error>?
        session.requestReadMemory(memoryReference: "0x100003f50", offset: 0, count: 16) {
            earlyMemory = $0
        }
        #expect(throws: DebugAdapterCapabilityError.self) { try early?.get() }
        #expect(throws: DebugAdapterCapabilityError.self) { try earlyMemory?.get() }
        #expect(core.inspectionRequests.isEmpty)

        core.enqueueReceive(sessionID: "lldb-memory", state: "ready", events: [[
            "sequence": 2,
            "type": "capabilities",
            "capabilities": Self.coreCapabilities([
                "supportsDisassembleRequest": true,
                "supportsReadMemoryRequest": true,
                "supportsSteppingGranularity": true,
                "supportsInstructionBreakpoints": true
            ])
        ]])
        transport.emitData(Data("initialize-response".utf8))
        #expect(session.capabilities.supportsDisassembleRequest)
        #expect(session.capabilities.supportsReadMemoryRequest)
        #expect(session.capabilities.supportsSteppingGranularity)
        #expect(session.capabilities.supportsInstructionBreakpoints)

        var instructions: Result<[DebugDisassembledInstruction], Error>?
        session.requestDisassembly(
            memoryReference: "0x100003f50",
            instructionOffset: -4,
            instructionCount: 8
        ) { instructions = $0 }
        #expect(core.inspectionRequests.last?.kind == "disassemble")
        #expect(core.inspectionRequests.last?.memory == DebugCoreMemoryQuery(
            reference: "0x100003f50",
            instructionOffset: -4,
            instructionCount: 8,
            resolveSymbols: true
        ))
        let disassembleID = try #require(core.lastInspectionOperationID)
        core.enqueueReceive(sessionID: "lldb-memory", state: "paused", events: [[
            "sequence": 3,
            "type": "operationCompleted",
            "operationId": disassembleID,
            "result": [
                "kind": "disassemble",
                "instructions": [[
                    "address": "0x100003f48",
                    "instructionBytes": "fd 7b bf a9",
                    "instruction": "stp x29, x30, [sp, #-0x10]!",
                    "symbol": "main"
                ], [
                    "address": "0x100003f4c",
                    "instruction": "mov x29, sp",
                    "sourcePath": "/tmp/lldb-memory/main.c",
                    "line": 4
                ]]
            ]
        ]])
        transport.emitData(Data("disassemble-response".utf8))
        let rows = try #require(try instructions?.get())
        #expect(rows.map(\.address) == ["0x100003f48", "0x100003f4c"])
        #expect(rows[0].instructionBytes == "fd 7b bf a9")
        #expect(rows[0].symbol == "main")
        #expect(rows[1].instructionBytes == nil)
        #expect(rows[1].sourceURL?.lastPathComponent == "main.c")
        #expect(rows[1].line == 4)

        var memory: Result<DebugMemoryRead, Error>?
        session.requestReadMemory(memoryReference: "0x100003f50", offset: 16, count: 4) {
            memory = $0
        }
        #expect(core.inspectionRequests.last?.kind == "readMemory")
        #expect(core.inspectionRequests.last?.count == 4)
        #expect(core.inspectionRequests.last?.memory == DebugCoreMemoryQuery(
            reference: "0x100003f50",
            offset: 16
        ))
        let readID = try #require(core.lastInspectionOperationID)
        core.enqueueReceive(sessionID: "lldb-memory", state: "paused", events: [[
            "sequence": 4,
            "type": "operationCompleted",
            "operationId": readID,
            "result": [
                "kind": "readMemory",
                "address": "0x100003f60",
                "unreadableBytes": 2,
                "dataBase64": Data([1, 2, 3, 4]).base64EncodedString()
            ]
        ]])
        transport.emitData(Data("read-memory-response".utf8))
        let read = try #require(try memory?.get())
        #expect(read.address == "0x100003f60")
        #expect(read.unreadableBytes == 2)
        #expect(read.data == Data([1, 2, 3, 4]))
    }

    @Test
    func coreProtocolSessionForwardsInstructionBreakpointsAndSteppingGranularity() throws {
        let transport = RecordingTransport()
        let core = RecordingDebugProtocolCore()
        let session = CoreDebugAdapterProtocolSession(
            adapterID: "lldb",
            transport: transport,
            core: core,
            sessionID: "lldb-instruction-steps",
            deadlineScheduler: RecordingDebugDeadlineScheduler()
        )
        try session.start(rootURL: URL(fileURLWithPath: "/tmp/lldb-steps", isDirectory: true))
        defer { session.stop() }

        session.setInstructionBreakpoints([
            DebugInstructionBreakpoint(instructionReference: "0x100003f50")
        ])
        #expect(core.instructionBreakpointUpdates.map { $0.map(\.instructionReference) } == [
            ["0x100003f50"]
        ])

        session.execute(.next, threadID: 1, granularity: .instruction)
        #expect(core.lastExecutionGranularity == .instruction)
        session.execute(.next, threadID: 1)
        #expect(core.lastExecutionGranularity == nil)
    }

    @Test
    func coreProtocolSessionMapsSourcelessFramesAndRegisterScopes() throws {
        let transport = RecordingTransport()
        let core = RecordingDebugProtocolCore()
        let session = CoreDebugAdapterProtocolSession(
            adapterID: "lldb",
            transport: transport,
            core: core,
            sessionID: "lldb-sourceless",
            deadlineScheduler: RecordingDebugDeadlineScheduler()
        )
        try session.start(rootURL: URL(fileURLWithPath: "/tmp/lldb-sourceless", isDirectory: true))
        defer { session.stop() }

        var frames: Result<[DebugStackFrame], Error>?
        session.requestStackTrace(threadID: 1) { frames = $0 }
        let stackID = try #require(core.lastInspectionOperationID)
        core.enqueueReceive(sessionID: "lldb-sourceless", state: "paused", events: [[
            "sequence": 2,
            "type": "operationCompleted",
            "operationId": stackID,
            "result": [
                "kind": "stackTrace",
                "stackFrames": [[
                    "id": 1,
                    "name": "__pthread_kill",
                    "line": 0,
                    "column": 0,
                    "instructionPointerReference": "0x19b5f2a4c"
                ], [
                    // lldb-dap serves code without debug info as a synthetic source.
                    "id": 3,
                    "name": "raise",
                    "sourcePath": "/usr/lib/system/libsystem_c.dylib`raise",
                    "sourceReference": 4,
                    "line": 12,
                    "column": 1,
                    "instructionPointerReference": "0x19b5f2b00"
                ], [
                    "id": 2,
                    "name": "main",
                    "sourcePath": "/tmp/lldb-sourceless/main.c",
                    "line": 3,
                    "column": 1
                ]]
            ]
        ]])
        transport.emitData(Data("stack-response".utf8))
        let stack = try #require(try frames?.get())
        #expect(stack[0].isSourceless)
        #expect(stack[0].sourceURL == nil)
        #expect(stack[0].instructionPointerReference == "0x19b5f2a4c")
        #expect(stack[1].isSourceless)
        #expect(stack[1].sourceURL == nil)
        #expect(stack[1].instructionPointerReference == "0x19b5f2b00")
        #expect(!stack[2].isSourceless)
        #expect(stack[2].instructionPointerReference == nil)

        var scopes: Result<[DebugScope], Error>?
        session.requestScopes(frameID: 1) { scopes = $0 }
        let scopesID = try #require(core.lastInspectionOperationID)
        core.enqueueReceive(sessionID: "lldb-sourceless", state: "paused", events: [[
            "sequence": 3,
            "type": "operationCompleted",
            "operationId": scopesID,
            "result": [
                "kind": "scopes",
                "scopes": [[
                    "name": "Variables",
                    "variablesReference": 9,
                    "expensive": false
                ], [
                    "name": "Registers",
                    "variablesReference": 10,
                    "expensive": true,
                    "presentationHint": "registers"
                ]]
            ]
        ]])
        transport.emitData(Data("scopes-response".utf8))
        let mapped = try #require(try scopes?.get())
        #expect(mapped.map(\.isRegisters) == [false, true])
    }

    @Test
    func sourcelessFrameOpensTheDisassemblyAndASourceFrameClosesItAgain() throws {
        let session = DeferredInspectionDebugSession(capabilities: Self.disassemblyCapabilities)
        let feature = makeDisassemblyFeature(session: session, rootPath: "/tmp/lldb-disassembly-follow")
        defer { feature.stop() }
        let source = URL(fileURLWithPath: "/tmp/lldb-disassembly-follow/src/main.c")
        let library = DebugStackFrame(
            id: 1,
            name: "__pthread_kill",
            sourceURL: nil,
            line: 0,
            column: 0,
            instructionPointerReference: "0x19b5f2a4c"
        )
        let user = DebugStackFrame(
            id: 2,
            name: "main",
            sourceURL: source,
            line: 4,
            column: 1,
            instructionPointerReference: "0x100003f50"
        )

        feature.selectThread(DebugThread(id: 1, name: "main"))
        session.completeStackTrace(at: 0, with: [library, user])
        // The first frame with source is preferred, so the view stays closed.
        #expect(feature.selectedFrameID == 2)
        #expect(!feature.disassembly.isPresented)
        #expect(session.disassemblyReferences.isEmpty)

        feature.selectFrame(library)
        #expect(feature.disassembly.isPresented)
        #expect(feature.disassembly.currentAddress == "0x19b5f2a4c")
        #expect(feature.disassembly.isLoading)
        #expect(session.disassemblyReferences == ["0x19b5f2a4c"])
        #expect(session.disassemblyOffsets == [-GenericDebugDisassemblyModel.instructionsBefore])

        let rows = [
            instruction("0x19b5f2a48", "mov x16, #0x148", symbol: "__pthread_kill"),
            instruction("0x19b5f2a4c", "svc #0x80")
        ]
        session.completeDisassembly(at: 0, with: .success(rows))
        #expect(feature.disassembly.rows == rows)
        #expect(!feature.disassembly.isLoading)
        #expect(feature.disassembly.isCurrent(rows[1]))
        #expect(!feature.disassembly.isCurrent(rows[0]))

        // A frame with source returns to the editor, so the view that opened itself closes.
        feature.selectFrame(user)
        #expect(!feature.disassembly.isPresented)
        #expect(feature.disassembly.rows.isEmpty)

        // Opened by hand, the view stays while other frames are selected.
        feature.disassembly.present()
        #expect(session.disassemblyReferences == ["0x19b5f2a4c", "0x100003f50"])
        feature.selectFrame(library)
        feature.selectFrame(user)
        #expect(feature.disassembly.isPresented)
    }

    @Test
    func disassemblyStartsAtTheInstructionPointerWhenTheAdapterRefusesNegativeOffsets() throws {
        let session = DeferredInspectionDebugSession(capabilities: Self.disassemblyCapabilities)
        let (feature, _) = makeSourcelessStop(session: session, rootPath: "/tmp/lldb-no-negative")
        defer { feature.stop() }

        #expect(feature.disassembly.isPresented)
        #expect(session.disassemblyOffsets == [-GenericDebugDisassemblyModel.instructionsBefore])
        session.completeDisassembly(at: 0, with: .failure(DeferredDebugSessionError.launchFailed))
        #expect(session.disassemblyOffsets == [-GenericDebugDisassemblyModel.instructionsBefore, 0])
        #expect(feature.disassembly.isLoading)
        #expect(feature.disassembly.loadFailure == nil)

        let rows = [instruction("0x19b5f2a4c", "svc #0x80")]
        session.completeDisassembly(at: 1, with: .success(rows))
        #expect(feature.disassembly.rows == rows)
        #expect(!feature.disassembly.isLoading)

        // A failure of a request that was not the first window is reported, not retried.
        feature.disassembly.loadMore(.after)
        #expect(session.disassemblyReferences.last == "0x19b5f2a4c")
        #expect(session.disassemblyOffsets.last == 1)
        session.completeDisassembly(at: 2, with: .failure(DeferredDebugSessionError.launchFailed))
        #expect(feature.disassembly.loadFailure != nil)
        #expect(!feature.disassembly.isLoading)
        #expect(feature.disassembly.rows == rows)
        #expect(session.disassemblyOffsets.count == 3)
    }

    @Test
    func loadingMoreInstructionsAddsOnlyAddressesNotListedYet() throws {
        let session = DeferredInspectionDebugSession(capabilities: Self.disassemblyCapabilities)
        let (feature, _) = makeSourcelessStop(session: session, rootPath: "/tmp/lldb-load-more")
        defer { feature.stop() }

        let first = instruction("0x19b5f2a48", "mov x16, #0x148")
        let second = instruction("0x19b5f2a4c", "svc #0x80")
        session.completeDisassembly(at: 0, with: .success([first, second]))

        feature.disassembly.loadMore(.before)
        #expect(session.disassemblyReferences.last == "0x19b5f2a48")
        #expect(session.disassemblyOffsets.last == -GenericDebugDisassemblyModel.pageInstructionCount)
        let older = instruction("0x19b5f2a44", "nop")
        // The adapter may repeat the edge; the same address in a different spelling is the same row.
        let repeated = instruction("0x0000000019b5f2a48", "mov x16, #0x148")
        session.completeDisassembly(at: 1, with: .success([older, repeated]))
        #expect(feature.disassembly.rows == [older, first, second])

        feature.disassembly.loadMore(.after)
        #expect(session.disassemblyReferences.last == "0x19b5f2a4c")
        #expect(session.disassemblyOffsets.last == 1)
        let newer = instruction("0x19b5f2a50", "ret")
        session.completeDisassembly(at: 2, with: .success([newer]))
        #expect(feature.disassembly.rows == [older, first, second, newer])
    }

    @Test
    func disassemblyReplyAfterTheDebuggeeResumedIsDropped() throws {
        let session = DeferredInspectionDebugSession(capabilities: Self.disassemblyCapabilities)
        let (feature, _) = makeSourcelessStop(session: session, rootPath: "/tmp/lldb-stale-disassembly")
        defer { feature.stop() }
        #expect(feature.disassembly.isLoading)

        session.emit(.continued(threadID: 1))
        #expect(!feature.disassembly.isLoading)
        #expect(feature.disassembly.currentAddress == nil)

        // Addresses of the previous stop mean nothing now, even if the reply still arrives.
        session.completeDisassembly(at: 0, with: .success([instruction("0x19b5f2a4c", "svc #0x80")]))
        #expect(feature.disassembly.rows.isEmpty)
        #expect(feature.disassembly.loadFailure == nil)
    }

    @Test
    func steppingMovesOneInstructionWhileTheDisassemblyIsOpenAndTheAdapterCan() throws {
        let session = DeferredInspectionDebugSession(capabilities: Self.disassemblyCapabilities)
        let feature = makeDisassemblyFeature(session: session, rootPath: "/tmp/lldb-instruction-step")
        defer { feature.stop() }
        func resume() {
            session.transition(to: .running)
            session.transition(to: .paused)
        }

        feature.execute(.next)
        #expect(session.executionCommands == [.next])
        #expect(session.steppingGranularities.isEmpty)
        resume()

        feature.disassembly.present()
        feature.execute(.next)
        resume()
        feature.execute(.stepIn)
        resume()
        // Leaving the function is not an instruction-sized move.
        feature.execute(.stepOut)
        resume()
        #expect(session.executionCommands == [.next, .next, .stepIn, .stepOut])
        #expect(session.steppingGranularities == [.instruction, .instruction])

        feature.disassembly.dismiss()
        feature.execute(.next)
        #expect(session.steppingGranularities == [.instruction, .instruction])
        #expect(session.executionCommands.count == 5)

        let plain = DeferredInspectionDebugSession(
            capabilities: DebugAdapterCapabilities(negotiated: true, supportsDisassembleRequest: true)
        )
        let plainFeature = makeDisassemblyFeature(session: plain, rootPath: "/tmp/lldb-no-granularity")
        defer { plainFeature.stop() }
        plainFeature.disassembly.present()
        plainFeature.execute(.next)
        #expect(plain.executionCommands == [.next])
        #expect(plain.steppingGranularities.isEmpty)
    }

    @Test
    func instructionBreakpointsAreSetThroughTheSessionAndMatchedByAddressText() throws {
        let session = DeferredInspectionDebugSession(capabilities: Self.disassemblyCapabilities)
        let feature = makeDisassemblyFeature(session: session, rootPath: "/tmp/lldb-instruction-breakpoints")
        defer { feature.stop() }

        feature.disassembly.toggleBreakpoint(at: "0x100003f50")
        #expect(session.instructionBreakpointUpdates.map { $0.map(\.instructionReference) } == [
            ["0x100003f50"]
        ])
        #expect(feature.disassembly.breakpoint(at: "0x0000000100003F50") != nil)
        #expect(feature.disassembly.breakpoints.first?.verified == false)

        // The adapter may spell the address differently from the one that was requested.
        session.emit(.breakpoint(DebugBreakpoint(
            id: 1,
            verified: true,
            message: nil,
            sourceURL: nil,
            line: nil,
            column: nil,
            instructionReference: "0x0000000100003f50"
        )))
        #expect(feature.disassembly.breakpoint(at: "0x100003f50")?.verified == true)

        session.emit(.breakpoint(DebugBreakpoint(
            id: 1,
            verified: false,
            message: "no code at this address",
            sourceURL: nil,
            line: nil,
            column: nil,
            instructionReference: "0x100003f50"
        )))
        #expect(feature.disassembly.breakpoint(at: "0x100003f50")?.verified == false)
        #expect(feature.disassembly.breakpoint(at: "0x100003f50")?.message == "no code at this address")

        // Clicking the address again clears it, whichever way the address is spelled.
        feature.disassembly.toggleBreakpoint(at: "0x0000000100003F50")
        #expect(feature.disassembly.breakpoints.isEmpty)
        #expect(session.instructionBreakpointUpdates.last?.isEmpty == true)
        #expect(session.instructionBreakpointUpdates.count == 2)
    }

    @Test
    func instructionBreakpointsBelongToOneSessionAndAreForgottenWithIt() {
        final class Sink {
            var sessions: [DebugSessionID] = []
        }
        let sink = Sink()
        let model = GenericDebugDisassemblyModel()
        model.environment = GenericDebugDisassemblyModel.Environment(
            session: { nil },
            capabilities: { Self.disassemblyCapabilities },
            selectedFrameID: { nil },
            breakpointsChanged: { id, _ in sink.sessions.append(id) }
        )
        let first = DebugSessionID()
        let second = DebugSessionID()

        model.activate(sessionID: first)
        model.toggleBreakpoint(at: "0x10")
        model.activate(sessionID: second)
        #expect(model.breakpoints.isEmpty)
        model.toggleBreakpoint(at: "0x20")
        #expect(sink.sessions == [first, second])

        // ASLR gives the next run other addresses, so nothing outlives its session.
        model.activate(sessionID: first)
        #expect(model.breakpoints.map(\.address) == ["0x10"])
        model.forget(sessionID: first)
        #expect(model.breakpoints.isEmpty)
        model.activate(sessionID: second)
        model.activate(sessionID: first)
        #expect(model.breakpoints.isEmpty)
    }

    @Test
    func disassemblyActionsAreInertWithoutTheMatchingAdapterCapability() throws {
        let session = DeferredInspectionDebugSession()
        let (feature, _) = makeSourcelessStop(session: session, rootPath: "/tmp/lldb-no-capabilities")
        defer { feature.stop() }

        #expect(!feature.disassembly.isPresented)
        feature.disassembly.present()
        feature.disassembly.toggleBreakpoint(at: "0x10")
        feature.disassembly.readMemory(from: "0x1000")
        #expect(session.disassemblyReferences.isEmpty)
        #expect(session.instructionBreakpointUpdates.isEmpty)
        #expect(session.memoryReferences.isEmpty)
        #expect(feature.disassembly.breakpoints.isEmpty)
        #expect(!feature.disassembly.canDisassemble)
        #expect(!feature.disassembly.canReadMemory)
        #expect(!feature.disassembly.stepsByInstruction)
    }

    @Test
    func memoryReadsAcceptAnAddressOrAnExpressionAndPageByOffset() throws {
        let session = DeferredInspectionDebugSession(capabilities: Self.disassemblyCapabilities)
        let (feature, frame) = makeSourcelessStop(session: session, rootPath: "/tmp/lldb-read-memory")
        defer { feature.stop() }
        let page = GenericDebugMemoryDump.pageSize
        let context = GenericDebugMemoryDump.contextBytes

        // The page starts before the address, so the address is not the first thing on it.
        feature.disassembly.readMemory(from: " 0x1000 ")
        #expect(session.memoryReferences == ["0x1000"])
        #expect(session.memoryOffsets == [-context])
        #expect(feature.disassembly.isLoadingMemory)
        let revealBefore = feature.disassembly.memoryRevealToken
        session.completeMemory(at: 0, with: .success(DebugMemoryRead(
            address: "0x0fc0",
            unreadableBytes: 0,
            data: Data(repeating: 0x41, count: page)
        )))
        #expect(!feature.disassembly.isLoadingMemory)
        #expect(feature.disassembly.memory?.pageOffset == -context)
        #expect(feature.disassembly.memory?.targetIndex == context)
        #expect(feature.disassembly.memoryRevealToken == revealBefore + 1)

        feature.disassembly.showMemoryPage(.after)
        #expect(session.memoryReferences == ["0x1000", "0x1000"])
        #expect(session.memoryOffsets == [-context, -context + page])
        session.completeMemory(at: 1, with: .success(DebugMemoryRead(
            address: "0x10c0",
            unreadableBytes: 16,
            data: Data(repeating: 0x42, count: 8)
        )))
        #expect(feature.disassembly.memory?.pageOffset == -context + page)
        #expect(feature.disassembly.memory?.unreadableBytes == 16)
        #expect(feature.disassembly.memory?.targetIndex == nil)
        feature.disassembly.showMemoryPage(.before)
        #expect(session.memoryOffsets.last == -context)
        session.completeMemory(at: 2, with: .failure(DeferredDebugSessionError.launchFailed))
        #expect(feature.disassembly.memoryFailure != nil)

        // A register or any other expression is evaluated in the selected frame first.
        feature.disassembly.readMemory(from: "$sp")
        #expect(session.evaluateExpressions == ["$sp"])
        #expect(session.evaluateFrameIDs == [frame.id])
        session.completeEvaluation(at: 0, with: .success(DebugVariable(
            id: "$sp",
            name: "$sp",
            value: "0x000000016fdff8a0",
            type: "unsigned long",
            evaluateName: "$sp",
            variablesReference: 0
        )))
        #expect(session.memoryReferences.last == "0x000000016fdff8a0")
        #expect(session.memoryOffsets.last == -context)
        // Nothing is readable before the start of a mapping; the page then starts at the address.
        session.completeMemory(at: 3, with: .failure(DeferredDebugSessionError.launchFailed))
        #expect(session.memoryOffsets.last == 0)
        #expect(feature.disassembly.memoryFailure == nil)
        #expect(feature.disassembly.isLoadingMemory)
        session.completeMemory(at: 4, with: .success(DebugMemoryRead(
            address: "0x000000016fdff8a0",
            unreadableBytes: 0,
            data: Data(repeating: 0, count: page)
        )))
        #expect(feature.disassembly.memory?.targetIndex == 0)
        #expect(!feature.disassembly.isLoadingMemory)

        // A value that holds no address is reported instead of guessed at.
        feature.disassembly.readMemory(from: "argc")
        session.completeEvaluation(at: 1, with: .success(DebugVariable(
            id: "argc",
            name: "argc",
            value: "3",
            type: "int",
            evaluateName: "argc",
            variablesReference: 0
        )))
        #expect(feature.disassembly.memoryFailure == .unresolvedAddress)
        #expect(!feature.disassembly.isLoadingMemory)
        // Five reads so far: first page, next, previous, `$sp` with context, and its retry from the address.
        // The unresolved `argc` adds none.
        #expect(session.memoryReferences.count == 5)
    }

    @Test
    func selectingAnotherFrameDropsMemoryOfThePreviousOne() throws {
        let session = DeferredInspectionDebugSession(capabilities: Self.disassemblyCapabilities)
        let (feature, frame) = makeSourcelessStop(session: session, rootPath: "/tmp/lldb-memory-frame")
        defer { feature.stop() }

        feature.disassembly.readMemory(from: "0x1000")
        feature.selectFrame(frame)
        // The reply of the read started before the selection belongs to the old frame.
        session.completeMemory(at: 0, with: .success(DebugMemoryRead(
            address: "0x1000",
            unreadableBytes: 0,
            data: Data([1, 2, 3])
        )))
        #expect(feature.disassembly.memory == nil)
        #expect(!feature.disassembly.isLoadingMemory)

        feature.disassembly.readMemory(from: "0x2000")
        session.completeMemory(at: 1, with: .success(DebugMemoryRead(
            address: "0x2000",
            unreadableBytes: 0,
            data: Data([4])
        )))
        #expect(feature.disassembly.memory?.address == "0x2000")
        feature.selectFrame(frame)
        #expect(feature.disassembly.memory == nil)
    }

    // MARK: - Stepping refreshes the panels in place

    /// A feature stopped once in `main`, with `point` expanded next to `count`, ready for a step.
    private func makeSteppableStop(
        session: DeferredInspectionDebugSession,
        rootPath: String
    ) -> (feature: GenericDebugFeatureModel, point: DebugVariable) {
        let feature = makeDeferredFeature(session: session, rootPath: rootPath)
        let frame = DebugStackFrame(
            id: 70,
            name: "main",
            sourceURL: URL(fileURLWithPath: "\(rootPath)/src/Main.java"),
            line: 10,
            column: 1
        )
        let point = DebugVariable(
            id: "locals/point", name: "point", value: "{x=1, y=2}", type: "Point",
            evaluateName: "point", variablesReference: 71
        )
        let count = DebugVariable(
            id: "locals/count", name: "count", value: "1", type: "int",
            evaluateName: "count", variablesReference: 0
        )
        feature.selectThread(DebugThread(id: 1, name: "main"))
        session.completeStackTrace(at: 0, with: [frame])
        session.completeScopes(
            at: 0,
            with: [DebugScope(id: 700, name: "Locals", variablesReference: 700, expensive: false)]
        )
        session.completeVariables(at: 0, with: [point, count])
        feature.toggleVariableExpansion(point)
        session.completeVariables(at: 1, with: [
            DebugVariable(id: "point/x", name: "x", value: "1", type: "int", evaluateName: "point.x", variablesReference: 0),
            DebugVariable(id: "point/y", name: "y", value: "2", type: "int", evaluateName: "point.y", variablesReference: 0)
        ])
        return (feature, point)
    }

    /// The adapter reports a step: it resumes, stops in the same thread, then pauses.
    private func landStep(_ session: DeferredInspectionDebugSession) {
        session.emit(.stopped(reason: "step", threadID: 1, description: nil))
        session.transition(to: .paused)
    }

    @Test
    func steppingKeepsTheVariableTreeAndSwapsItInPlaceAtTheNextStop() throws {
        let session = DeferredInspectionDebugSession()
        let (feature, point) = makeSteppableStop(session: session, rootPath: "/tmp/debug-step-in-place")
        defer { feature.stop() }
        #expect(feature.isVariableExpanded(point))
        #expect(feature.children(of: point).map(\.name) == ["x", "y"])
        let before = feature.presentedVariables

        feature.execute(.next)
        session.transition(to: .running)

        // The step is in flight: nothing was cleared, the panels are only marked as outdated.
        #expect(feature.isInspectionStale)
        #expect(feature.stackFrames.count == 1)
        #expect(feature.presentedVariables == before)
        #expect(feature.isVariableExpanded(point))
        #expect(feature.children(of: point).map(\.name) == ["x", "y"])

        landStep(session)
        #expect(!feature.isInspectionStale)
        #expect(feature.stackFrames.count == 1, "The previous stack stays until the new one arrives")
        #expect(feature.presentedVariables == before)

        session.completeThreads(at: 0, with: [DebugThread(id: 1, name: "main")])
        session.completeStackTrace(at: 1, with: [
            DebugStackFrame(
                id: 80,
                name: "main",
                sourceURL: URL(fileURLWithPath: "/tmp/debug-step-in-place/src/Main.java"),
                line: 11,
                column: 1
            )
        ])
        #expect(feature.selectedFrameID == 80)
        #expect(feature.presentedVariables == before)
        session.completeScopes(
            at: 1,
            with: [DebugScope(id: 800, name: "Locals", variablesReference: 800, expensive: false)]
        )
        #expect(feature.isRefreshingVariables)
        #expect(session.variableReferences.last == 800)
        #expect(feature.presentedVariables == before)

        // The new root page arrives behind the old tree, which is still what the view shows.
        let newPoint = DebugVariable(
            id: "locals2/point", name: "point", value: "{x=5, y=2}", type: "Point",
            evaluateName: "point", variablesReference: 81
        )
        let newCount = DebugVariable(
            id: "locals2/count", name: "count", value: "2", type: "int",
            evaluateName: "count", variablesReference: 0
        )
        session.completeVariables(at: 2, with: [newPoint, newCount])
        #expect(feature.isRefreshingVariables, "`point` was expanded, so its children are fetched again")
        #expect(session.variableReferences.last == 81)
        #expect(feature.presentedVariables == before)

        session.completeVariables(at: 3, with: [
            DebugVariable(id: "point2/x", name: "x", value: "5", type: "int", evaluateName: "point.x", variablesReference: 0),
            DebugVariable(id: "point2/y", name: "y", value: "2", type: "int", evaluateName: "point.y", variablesReference: 0)
        ])
        #expect(!feature.isRefreshingVariables)
        #expect(feature.presentedVariables == [newPoint, newCount])
        #expect(feature.isVariableExpanded(newPoint), "Expansion survives by name path, not by the adapter's ids")
        #expect(feature.children(of: newPoint).map(\.value) == ["5", "2"])
    }

    @Test
    func theVariableTreeCannotBeEditedWhileItIsBeingReplaced() async throws {
        let session = DeferredInspectionDebugSession()
        let (feature, point) = makeSteppableStop(session: session, rootPath: "/tmp/debug-step-readonly")
        defer { feature.stop() }
        let requestsBefore = session.variableReferences.count

        feature.execute(.next)
        session.transition(to: .running)
        feature.toggleVariableExpansion(point)
        feature.loadMoreVariables(parentVariableID: nil)
        #expect(feature.isVariableExpanded(point), "A click on the frozen tree must not collapse it")
        #expect(session.variableReferences.count == requestsBefore)

        // A JSON snapshot of a tree the debuggee already left would show values that no longer exist.
        await #expect(throws: CancellationError.self) {
            _ = try await feature.variableJSONSnapshot()
        }
    }

    @Test
    func continuingStillClearsTheStoppedInspection() throws {
        let session = DeferredInspectionDebugSession()
        let (feature, _) = makeSteppableStop(session: session, rootPath: "/tmp/debug-step-continue")
        defer { feature.stop() }

        // Continue can end anywhere, so it keeps the full reset instead of the in-place swap.
        feature.execute(.continueExecution)
        session.transition(to: .running)

        #expect(!feature.isInspectionStale)
        #expect(feature.stackFrames.isEmpty)
        #expect(feature.presentedVariables.isEmpty)
        #expect(feature.selectedFrameID == nil)
    }

    @Test
    func terminatingWhileSteppingClearsThePanels() throws {
        let session = DeferredInspectionDebugSession()
        let (feature, _) = makeSteppableStop(session: session, rootPath: "/tmp/debug-step-terminated")
        defer { feature.stop() }

        feature.execute(.stepIn)
        session.transition(to: .running)
        #expect(feature.isInspectionStale)
        session.emit(.terminated(exitCode: 0))
        session.transition(to: .terminated)

        #expect(!feature.isInspectionStale)
        #expect(!feature.isRefreshingVariables)
        #expect(feature.stackFrames.isEmpty)
        #expect(feature.presentedVariables.isEmpty)
    }

    @Test
    func aStopWithoutFramesDoesNotLeaveTheOldStackOnScreen() throws {
        let session = DeferredInspectionDebugSession()
        let (feature, _) = makeSteppableStop(session: session, rootPath: "/tmp/debug-step-empty-stack")
        defer { feature.stop() }

        feature.execute(.next)
        session.transition(to: .running)
        landStep(session)
        session.completeThreads(at: 0, with: [DebugThread(id: 1, name: "main")])
        session.completeStackTrace(at: 1, with: [])

        // Nothing replaces the kept panels, so they must not pretend to describe this stop.
        #expect(feature.selectedFrameID == nil)
        #expect(feature.stackFrames.isEmpty)
        #expect(feature.presentedVariables.isEmpty)
        #expect(!feature.isRefreshingVariables)
    }

    @Test
    func aStopThatReportsNoThreadFallsBackToAFullReset() throws {
        let session = DeferredInspectionDebugSession()
        let (feature, _) = makeSteppableStop(session: session, rootPath: "/tmp/debug-step-no-threads")
        defer { feature.stop() }

        feature.execute(.next)
        session.transition(to: .running)
        session.emit(.stopped(reason: "step", threadID: nil, description: nil))
        session.transition(to: .paused)
        session.completeThreads(at: 0, with: [])

        #expect(feature.stackFrames.isEmpty)
        #expect(feature.presentedVariables.isEmpty)
        #expect(!feature.isInspectionStale)
    }

    @Test
    func automaticVariablesKeepTheirOldValuesUntilEachOneIsEvaluatedAgain() throws {
        let session = DeferredInspectionDebugSession()
        let feature = makeDeferredFeature(session: session, rootPath: "/tmp/debug-step-automatic")
        defer { feature.stop() }
        feature.onAutomaticVariableInspectionRequest = { [weak feature] _ in
            feature?.requestAutomaticVariables(["total"])
        }
        func frame(_ id: Int, line: Int) -> DebugStackFrame {
            DebugStackFrame(
                id: id,
                name: "main",
                sourceURL: URL(fileURLWithPath: "/tmp/debug-step-automatic/src/Main.java"),
                line: line,
                column: 1
            )
        }
        func total(_ value: String) -> DebugVariable {
            DebugVariable(
                id: "total", name: "total", value: value, type: "int",
                evaluateName: "total", variablesReference: 0
            )
        }

        feature.selectThread(DebugThread(id: 1, name: "main"))
        session.completeStackTrace(at: 0, with: [frame(1, line: 5)])
        session.completeEvaluation(at: 0, with: .success(total("3")))
        #expect(feature.automaticVariables.map(\.value) == ["3"])

        feature.execute(.next)
        session.transition(to: .running)
        landStep(session)
        session.completeThreads(at: 0, with: [DebugThread(id: 1, name: "main")])
        session.completeStackTrace(at: 1, with: [frame(2, line: 6)])

        // The expression is asked again for the new frame while the old value stays visible.
        #expect(session.evaluateFrameIDs.last == 2)
        #expect(feature.automaticVariables.map(\.value) == ["3"])
        session.completeEvaluation(at: 1, with: .success(total("4")))
        #expect(feature.automaticVariables.map(\.value) == ["4"])
    }

    // MARK: - Stepping in the disassembly view

    @Test
    func stepButtonsKnowWhetherTheyMoveByInstruction() throws {
        let session = DeferredInspectionDebugSession(capabilities: Self.disassemblyCapabilities)
        let feature = makeDisassemblyFeature(session: session, rootPath: "/tmp/lldb-step-granularity-flags")
        defer { feature.stop() }

        #expect(feature.disassembly.canStepByInstruction)
        #expect(!feature.disassembly.stepsByInstruction, "Closed view: a step still moves by source line")
        feature.disassembly.present()
        #expect(feature.disassembly.stepsByInstruction)
        feature.disassembly.dismiss()
        #expect(!feature.disassembly.stepsByInstruction)

        let plain = DeferredInspectionDebugSession(
            capabilities: DebugAdapterCapabilities(negotiated: true, supportsDisassembleRequest: true)
        )
        let plainFeature = makeDisassemblyFeature(session: plain, rootPath: "/tmp/lldb-step-granularity-missing")
        defer { plainFeature.stop() }
        plainFeature.disassembly.present()
        // The header warns about this case, so it has to be distinguishable from the supported one.
        #expect(plainFeature.disassembly.isPresented)
        #expect(!plainFeature.disassembly.canStepByInstruction)
        #expect(!plainFeature.disassembly.stepsByInstruction)
    }

    @Test
    func steppingInsideTheListedRangeOnlyMovesTheCurrentInstructionMarker() throws {
        let session = DeferredInspectionDebugSession(capabilities: Self.disassemblyCapabilities)
        let (feature, _) = makeSourcelessStop(session: session, rootPath: "/tmp/lldb-step-keeps-listing")
        defer { feature.stop() }
        let rows = (0..<20).map { instruction("0x\(String(0x1000 + $0 * 4, radix: 16))", "nop") }
        session.completeDisassembly(at: 0, with: .success(rows))
        let requestsBefore = session.disassemblyReferences.count

        let next = DebugStackFrame(
            id: 6, name: "__pthread_kill", sourceURL: nil, line: 0, column: 0,
            instructionPointerReference: rows[4].address
        )
        feature.disassembly.frameSelected(next, preservingView: true)

        #expect(feature.disassembly.currentAddress == rows[4].address)
        #expect(feature.disassembly.rows == rows, "The listing must not blink away for one step")
        #expect(feature.disassembly.isCurrent(rows[4]))
        #expect(!feature.disassembly.isLoading)
        #expect(session.disassemblyReferences.count == requestsBefore)
    }

    @Test
    func steppingOutOfTheListedRangeReadsTheListingAgain() throws {
        let session = DeferredInspectionDebugSession(capabilities: Self.disassemblyCapabilities)
        let (feature, _) = makeSourcelessStop(session: session, rootPath: "/tmp/lldb-step-leaves-listing")
        defer { feature.stop() }
        session.completeDisassembly(at: 0, with: .success([instruction("0x1000", "nop"), instruction("0x1004", "ret")]))

        let far = DebugStackFrame(
            id: 6, name: "elsewhere", sourceURL: nil, line: 0, column: 0,
            instructionPointerReference: "0x9000"
        )
        feature.disassembly.frameSelected(far, preservingView: true)

        #expect(feature.disassembly.isLoading)
        #expect(session.disassemblyReferences.last == "0x9000")
        #expect(session.disassemblyOffsets.last == -GenericDebugDisassemblyModel.instructionsBefore)
    }

    @Test
    func steppingTowardsTheEndOfTheListingExtendsItBeforeTheMarkerRunsOff() throws {
        let session = DeferredInspectionDebugSession(capabilities: Self.disassemblyCapabilities)
        let (feature, _) = makeSourcelessStop(session: session, rootPath: "/tmp/lldb-step-extends-listing")
        defer { feature.stop() }
        let rows = (0..<12).map { instruction("0x\(String(0x2000 + $0 * 4, radix: 16))", "nop") }
        session.completeDisassembly(at: 0, with: .success(rows))
        let requestsBefore = session.disassemblyReferences.count

        let near = DebugStackFrame(
            id: 6, name: "__pthread_kill", sourceURL: nil, line: 0, column: 0,
            instructionPointerReference: rows[8].address
        )
        feature.disassembly.frameSelected(near, preservingView: true)

        #expect(feature.disassembly.rows == rows)
        #expect(session.disassemblyReferences.count == requestsBefore + 1)
        #expect(session.disassemblyReferences.last == rows[11].address)
        #expect(session.disassemblyOffsets.last == 1)
    }

    // MARK: - Memory refresh while stepping

    @Test
    func aStepReadsTheMemoryPageAgainQuietlyAndMarksTheBytesThatChanged() throws {
        let session = DeferredInspectionDebugSession(capabilities: Self.disassemblyCapabilities)
        let (feature, frame) = makeSourcelessStop(session: session, rootPath: "/tmp/lldb-memory-changed")
        defer { feature.stop() }

        // The first read asks for the context before the address; this double refuses it, so the
        // model falls back to the page that starts at the address.
        feature.disassembly.readMemory(from: "0x1000")
        session.completeMemory(at: 0, with: .failure(DeferredDebugSessionError.launchFailed))
        session.completeMemory(at: 1, with: .success(DebugMemoryRead(
            address: "0x1000", unreadableBytes: 0, data: Data([1, 2, 3, 4])
        )))
        let revealed = feature.disassembly.memoryRevealToken
        #expect(feature.disassembly.memory?.data == Data([1, 2, 3, 4]))
        #expect(feature.disassembly.memoryChangedIndices.isEmpty)

        let next = DebugStackFrame(
            id: frame.id, name: frame.name, sourceURL: nil, line: 0, column: 0,
            instructionPointerReference: "0x19b5f2a50"
        )
        feature.disassembly.frameSelected(next, preservingView: true)
        // The page on screen is kept while the new bytes are fetched behind it.
        #expect(feature.disassembly.memory?.data == Data([1, 2, 3, 4]))
        #expect(!feature.disassembly.isLoadingMemory)
        session.completeMemory(at: session.memoryOffsets.count - 1, with: .success(DebugMemoryRead(
            address: "0x1000", unreadableBytes: 0, data: Data([1, 9, 3, 7])
        )))

        #expect(feature.disassembly.memory?.data == Data([1, 9, 3, 7]))
        #expect(feature.disassembly.memoryChangedIndices == [1, 3])
        #expect(feature.disassembly.memoryRevealToken == revealed, "A refresh must not scroll the page")

        // Resuming makes every address stale, marks included.
        feature.disassembly.invalidate()
        #expect(feature.disassembly.memory == nil)
        #expect(feature.disassembly.memoryChangedIndices.isEmpty)
    }

    private func workspaceFactory() -> ModuleFactory {
        ModuleFactory(manifest: ModuleManifest(id: .workspace, displayName: "Workspace", scope: .workspace)) {
            EmptyModule(id: .workspace, name: "Workspace")
        }
    }

    private func languageFactory() -> ModuleFactory {
        ModuleFactory(manifest: ModuleManifest(id: .languageIntelligence, displayName: "Language", scope: .workspace)) {
            EmptyModule(id: .languageIntelligence, name: "Language")
        }
    }

    private func executionFactory() -> ModuleFactory {
        ModuleFactory(manifest: ModuleManifest(id: .execution, displayName: "Execution", scope: .workspace)) {
            EmptyModule(id: .execution, name: "Execution")
        }
    }

    private func makeDeferredFeature(
        session: DeferredInspectionDebugSession,
        rootPath: String
    ) -> GenericDebugFeatureModel {
        let descriptor = DebugProviderDescriptor(
            id: "java",
            displayName: "Java",
            fileExtensions: ["java"]
        )
        let manager = DebugAdapterSessionManager(providers: [descriptor]) { _, _ in session }
        let feature = GenericDebugFeatureModel(sessions: manager)
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let source = root.appendingPathComponent("src/Main.java")
        precondition(feature.start(
            fileURL: source,
            rootURL: root,
            configuration: DebugLaunchConfiguration(
                name: "Main",
                request: .launch,
                arguments: ["mainClass": .string("example.Main")]
            )
        ))
        return feature
    }

    private func indexedVariables(
        _ range: Range<Int>,
        idPrefix: String = "item"
    ) -> [DebugVariable] {
        range.map { index in
            DebugVariable(
                id: "\(idPrefix)-\(index)",
                name: "[\(index)]",
                value: "Item@\(index)",
                type: "example.Item",
                evaluateName: nil,
                variablesReference: 0
            )
        }
    }
}

@MainActor
private final class RecordingTransport: DebugAdapterTransport {
    private(set) var isRunning = false
    var onData: ((Data) -> Void)?
    var onErrorOutput: ((Data) -> Void)?
    var onTermination: ((Int) -> Void)?
    private(set) var sentData: [Data] = []
    private(set) var stopCalls = 0

    func start(rootURL: URL) throws {
        isRunning = true
    }

    func send(_ data: Data) throws {
        sentData.append(data)
    }

    func stop() {
        stopCalls += 1
        isRunning = false
    }

    func terminate(_ exitCode: Int) {
        isRunning = false
        onTermination?(exitCode)
    }

    func emitJSON(_ object: [String: Any]) {
        let body = try! JSONSerialization.data(withJSONObject: object)
        var frame = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        frame.append(body)
        onData?(frame)
    }

    func emitData(_ data: Data) {
        onData?(data)
    }

    func emitErrorOutput(_ data: Data) {
        onErrorOutput?(data)
    }

    func request(named command: String) -> [String: Any]? {
        messages.first {
            $0["type"] as? String == "request" && $0["command"] as? String == command
        }
    }

    func response(to requestSequence: Int) -> [String: Any]? {
        messages.first {
            $0["type"] as? String == "response"
                && $0["request_seq"] as? Int == requestSequence
        }
    }

    private var messages: [[String: Any]] {
        sentData.compactMap { data in
            guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            return try? JSONSerialization.jsonObject(
                with: data.subdata(in: separator.upperBound..<data.endIndex)
            ) as? [String: Any]
        }
    }
}

private final class RecordingBreakpointPersistence: DebugBreakpointPersisting, @unchecked Sendable {
    var snapshots: [URL: DebugBreakpointSnapshot] = [:]

    func loadBreakpoints(for workspaceURL: URL) throws -> DebugBreakpointSnapshot? {
        snapshots[workspaceURL.standardizedFileURL]
    }

    func saveBreakpoints(_ snapshot: DebugBreakpointSnapshot, for workspaceURL: URL) throws {
        snapshots[workspaceURL.standardizedFileURL] = snapshot
    }
}

private struct RecordingBreakpointRelocationRequest: Equatable {
    let source: String
    let edit: DebugSourceEdit
    let breakpoints: [DebugSourceBreakpoint]
}

@MainActor
private final class RecordingBreakpointRelocator: DebugBreakpointRelocating {
    let result: [DebugSourceBreakpoint]
    private(set) var requests: [RecordingBreakpointRelocationRequest] = []

    init(result: [DebugSourceBreakpoint]) {
        self.result = result
    }

    func relocateDebugBreakpoints(
        source: String,
        edit: DebugSourceEdit,
        breakpoints: [DebugSourceBreakpoint]
    ) throws -> [DebugSourceBreakpoint] {
        requests.append(RecordingBreakpointRelocationRequest(
            source: source,
            edit: edit,
            breakpoints: breakpoints
        ))
        return result
    }
}

private struct RecordingDebugSteppingFilterResolution: Equatable {
    let adapterID: String
    let filters: DebugSteppingFilters?
}

@MainActor
private final class RecordingDebugSteppingFilterResolver: DebugSteppingFilterResolving {
    let defaults: DebugSteppingFilters
    let normalizedOverride: DebugSteppingFilters
    private(set) var requests: [RecordingDebugSteppingFilterResolution] = []

    init(defaults: DebugSteppingFilters, normalizedOverride: DebugSteppingFilters) {
        self.defaults = defaults
        self.normalizedOverride = normalizedOverride
    }

    func resolveDebugSteppingFilters(
        adapterID: String,
        filters: DebugSteppingFilters?
    ) throws -> DebugSteppingFilters {
        requests.append(RecordingDebugSteppingFilterResolution(
            adapterID: adapterID,
            filters: filters
        ))
        return filters == nil ? defaults : normalizedOverride
    }
}

private final class RecordingDebugSteppingFilterPersistence:
    DebugSteppingFilterPersisting,
    @unchecked Sendable
{
    var filtersByAdapterID: [String: DebugSteppingFilters] = [:]

    func loadSteppingFilters(adapterID: String) throws -> DebugSteppingFilters? {
        filtersByAdapterID[adapterID]
    }

    func saveSteppingFilters(_ filters: DebugSteppingFilters, adapterID: String) throws {
        filtersByAdapterID[adapterID] = filters
    }
}

private enum DebugSteppingFilterPersistenceTestError: Error {
    case unreadable
}

private enum DeferredDebugSessionError: Error {
    case launchFailed
}

private final class FailingDebugSteppingFilterPersistence:
    DebugSteppingFilterPersisting,
    @unchecked Sendable
{
    func loadSteppingFilters(adapterID _: String) throws -> DebugSteppingFilters? {
        throw DebugSteppingFilterPersistenceTestError.unreadable
    }

    func saveSteppingFilters(_: DebugSteppingFilters, adapterID _: String) throws {}
}

private struct RecordingDebugInspectionRequest: Equatable {
    let operationID: String
    let kind: String
    let threadID: Int?
    let frameID: Int?
    let variablesReference: Int?
    let variableFilter: DebugVariableFilter?
    let start: Int?
    let count: Int?
    let expression: String?
    let column: Int?
    var memory: DebugCoreMemoryQuery?
}

private struct RecordingDebugVariablePageRequest: Equatable {
    let reference: Int
    let filter: DebugVariableFilter?
    let start: Int?
    let count: Int?
}

@MainActor
private final class DeferredInspectionDebugSession: DebugAdapterControllingSession, DebugAdapterRunInTerminalSession {
    private(set) var redefineCount = 0
    func redefineClasses(_ completion: @escaping (Result<[String], Error>) -> Void) {
        redefineCount += 1
        completion(.success(["example.Main"]))
    }
    let capabilities: DebugAdapterCapabilities
    private(set) var isRunning = false
    private(set) var state: DebugAdapterState = .idle
    private(set) var startCount = 0
    private(set) var launchConfigurations: [DebugLaunchConfiguration] = []
    private(set) var breakpointUpdates: [[DebugSourceBreakpoint]] = []
    private(set) var executionCommands: [DebugExecutionCommand] = []
    private(set) var steppingGranularities: [DebugSteppingGranularity] = []
    private(set) var instructionBreakpointUpdates: [[DebugInstructionBreakpoint]] = []
    var failNextLaunch = false
    var consoleCommands: [DebugConsoleCommand] = []
    var consoleCommandPrefix: String?
    private(set) var completionRequests: [(
        text: String,
        column: Int?,
        completion: (Result<[DebugCompletionItem], Error>) -> Void
    )] = []
    var onStateChange: ((DebugAdapterState) -> Void)?
    var onEvent: ((DebugAdapterEvent) -> Void)?
    var onRunInTerminalRequest: DebugRunInTerminalRequestHandler?

    private var threadRequests: [(Result<[DebugThread], Error>) -> Void] = []
    private var stackTraceRequests: [(
        threadID: Int,
        completion: (Result<[DebugStackFrame], Error>) -> Void
    )] = []
    private var scopeRequests: [(
        frameID: Int,
        completion: (Result<[DebugScope], Error>) -> Void
    )] = []
    private var variableRequests: [(
        reference: Int,
        filter: DebugVariableFilter?,
        start: Int?,
        count: Int?,
        completion: (Result<[DebugVariable], Error>) -> Void
    )] = []
    private var exceptionInfoRequests: [(
        threadID: Int,
        completion: (Result<DebugExceptionInfo, Error>) -> Void
    )] = []
    private var evaluateRequests: [(
        expression: String,
        frameID: Int?,
        completion: (Result<DebugVariable, Error>) -> Void
    )] = []
    private var disassemblyRequests: [(
        reference: String,
        offset: Int,
        count: Int,
        completion: (Result<[DebugDisassembledInstruction], Error>) -> Void
    )] = []
    private var memoryRequests: [(
        reference: String,
        offset: Int,
        count: Int,
        completion: (Result<DebugMemoryRead, Error>) -> Void
    )] = []

    var disassemblyReferences: [String] { disassemblyRequests.map(\.reference) }
    var disassemblyOffsets: [Int] { disassemblyRequests.map(\.offset) }
    var memoryReferences: [String] { memoryRequests.map(\.reference) }
    var memoryOffsets: [Int] { memoryRequests.map(\.offset) }
    var stackTraceThreadIDs: [Int] { stackTraceRequests.map(\.threadID) }
    var scopeFrameIDs: [Int] { scopeRequests.map(\.frameID) }
    var variableReferences: [Int] { variableRequests.map(\.reference) }
    var variablePageRequests: [RecordingDebugVariablePageRequest] {
        variableRequests.map {
            RecordingDebugVariablePageRequest(
                reference: $0.reference,
                filter: $0.filter,
                start: $0.start,
                count: $0.count
            )
        }
    }
    var exceptionInfoThreadIDs: [Int] { exceptionInfoRequests.map(\.threadID) }
    var evaluateExpressions: [String] { evaluateRequests.map(\.expression) }
    var evaluateFrameIDs: [Int?] { evaluateRequests.map(\.frameID) }

    init(capabilities: DebugAdapterCapabilities = .unknown) {
        self.capabilities = capabilities
    }

    func start(rootURL _: URL) throws {
        startCount += 1
        isRunning = true
        state = .ready
    }

    func stop() {
        isRunning = false
        state = .idle
    }

    func launch(_ configuration: DebugLaunchConfiguration) throws {
        launchConfigurations.append(configuration)
        if failNextLaunch {
            failNextLaunch = false
            throw DeferredDebugSessionError.launchFailed
        }
        state = .paused
        onStateChange?(.paused)
    }

    func fail() {
        isRunning = false
        state = .failed
        onStateChange?(.failed)
    }

    func transition(to state: DebugAdapterState) {
        self.state = state
        onStateChange?(state)
    }

    func setBreakpoints(_ breakpoints: [DebugSourceBreakpoint], in _: URL) {
        breakpointUpdates.append(breakpoints)
    }
    func execute(_ command: DebugExecutionCommand, threadID _: Int?) {
        executionCommands.append(command)
    }
    func execute(
        _ command: DebugExecutionCommand,
        threadID _: Int?,
        granularity: DebugSteppingGranularity
    ) {
        executionCommands.append(command)
        steppingGranularities.append(granularity)
    }
    func setInstructionBreakpoints(_ breakpoints: [DebugInstructionBreakpoint]) {
        instructionBreakpointUpdates.append(breakpoints)
    }
    func requestDisassembly(
        memoryReference: String,
        instructionOffset: Int,
        instructionCount: Int,
        completion: @escaping (Result<[DebugDisassembledInstruction], Error>) -> Void
    ) {
        disassemblyRequests.append((memoryReference, instructionOffset, instructionCount, completion))
    }
    func requestReadMemory(
        memoryReference: String,
        offset: Int,
        count: Int,
        completion: @escaping (Result<DebugMemoryRead, Error>) -> Void
    ) {
        memoryRequests.append((memoryReference, offset, count, completion))
    }
    func completeDisassembly(at index: Int, with result: Result<[DebugDisassembledInstruction], Error>) {
        disassemblyRequests[index].completion(result)
    }
    func completeMemory(at index: Int, with result: Result<DebugMemoryRead, Error>) {
        memoryRequests[index].completion(result)
    }
    func requestThreads(_ completion: @escaping (Result<[DebugThread], Error>) -> Void) {
        threadRequests.append(completion)
    }
    func completeThreads(at index: Int, with threads: [DebugThread]) {
        threadRequests[index](.success(threads))
    }

    func requestExceptionInfo(
        threadID: Int,
        completion: @escaping (Result<DebugExceptionInfo, Error>) -> Void
    ) {
        exceptionInfoRequests.append((threadID, completion))
    }

    func requestStackTrace(
        threadID: Int,
        completion: @escaping (Result<[DebugStackFrame], Error>) -> Void
    ) {
        stackTraceRequests.append((threadID, completion))
    }

    func requestScopes(
        frameID: Int,
        completion: @escaping (Result<[DebugScope], Error>) -> Void
    ) {
        scopeRequests.append((frameID, completion))
    }

    func requestVariables(
        reference: Int,
        completion: @escaping (Result<[DebugVariable], Error>) -> Void
    ) {
        requestVariables(
            reference: reference,
            filter: nil,
            start: nil,
            count: nil,
            completion: completion
        )
    }

    func requestVariables(
        reference: Int,
        filter: DebugVariableFilter?,
        start: Int?,
        count: Int?,
        completion: @escaping (Result<[DebugVariable], Error>) -> Void
    ) {
        variableRequests.append((reference, filter, start, count, completion))
    }

    func evaluate(
        _ expression: String,
        frameID: Int?,
        completion: @escaping (Result<DebugVariable, Error>) -> Void
    ) {
        evaluateRequests.append((expression, frameID, completion))
    }

    func requestCompletions(
        _ text: String,
        column: Int?,
        frameID _: Int?,
        completion: @escaping (Result<[DebugCompletionItem], Error>) -> Void
    ) {
        completionRequests.append((text, column, completion))
    }

    func completeCompletions(at index: Int, with items: [DebugCompletionItem]) {
        completionRequests[index].completion(.success(items))
    }

    // This double deliberately delivers responses after cancellation to model
    // adapters and callback queues that cannot retract an already-sent result.
    func cancelPendingOperations() {}

    func emit(_ event: DebugAdapterEvent) {
        onEvent?(event)
    }

    func emitRunInTerminalRequest(_ request: DebugRunInTerminalRequest) {
        onRunInTerminalRequest?(request) { _ in }
    }

    func completeStackTrace(at index: Int, with frames: [DebugStackFrame]) {
        stackTraceRequests[index].completion(.success(frames))
    }

    func completeScopes(at index: Int, with scopes: [DebugScope]) {
        scopeRequests[index].completion(.success(scopes))
    }

    func completeVariables(at index: Int, with variables: [DebugVariable]) {
        variableRequests[index].completion(.success(variables))
    }

    func completeExceptionInfo(at index: Int, with info: DebugExceptionInfo) {
        exceptionInfoRequests[index].completion(.success(info))
    }

    func completeEvaluation(at index: Int, with result: Result<DebugVariable, Error>) {
        evaluateRequests[index].completion(result)
    }
}

@MainActor
private final class RecordingDebugProtocolCore: DebugProtocolCore {
    private var receiveUpdates: [DebugCoreUpdate] = []
    private(set) var lastInspectionOperationID: String?
    private(set) var lastDataBreakpointInfoOperationID: String?
    private(set) var lastSetVariableOperationID: String?
    private(set) var destroyedSessionIDs: [String] = []
    private(set) var breakpointUpdates: [[DebugSourceBreakpoint]] = []
    private(set) var exceptionBreakpointUpdates: [[DebugExceptionBreakpoint]] = []
    private(set) var functionBreakpointUpdates: [[DebugFunctionBreakpoint]] = []
    private(set) var instructionBreakpointUpdates: [[DebugInstructionBreakpoint]] = []
    private(set) var lastExecutionGranularity: DebugSteppingGranularity?
    private(set) var dataBreakpointUpdates: [[DebugDataBreakpoint]] = []
    private(set) var cancelledOperationReasons: [String] = []
    private(set) var lastExecutionSingleThread: Bool?
    private(set) var lastExecutionThreadID: Int?
    private(set) var inspectionRequests: [RecordingDebugInspectionRequest] = []
    private(set) var lastLaunchConfiguration: DebugLaunchConfiguration?
    private(set) var lastSupportsRunInTerminalRequest: Bool?
    private(set) var lastSupportsStartDebuggingRequest: Bool?
    private(set) var lastParentSessionID: String?
    private(set) var lastDisabledCapabilities: [String] = []
    private(set) var startDebuggingResults: [(requestID: String, succeeded: Bool)] = []
    private(set) var runInTerminalCompletions: [RecordingRunInTerminalCompletion] = []
    let defaultSteppingFilters = DebugSteppingFilters(
        classNameFilters: ["$JDK", "org.junit.*"],
        skipSynthetics: true,
        skipStaticInitializers: true,
        skipConstructors: false,
        hideFilteredStackFrames: true
    )

    func resolveDebugSteppingFilters(
        adapterID _: String,
        filters: DebugSteppingFilters?
    ) throws -> DebugSteppingFilters {
        filters ?? defaultSteppingFilters
    }

    func createDebugSession(
        sessionID: String,
        adapterID _: String,
        rootPath _: String,
        supportsRunInTerminalRequest: Bool,
        supportsStartDebuggingRequest: Bool,
        disabledCapabilities: [String],
        parentSessionID: String?
    ) throws -> DebugCoreUpdate {
        lastDisabledCapabilities = disabledCapabilities
        lastParentSessionID = parentSessionID
        lastSupportsRunInTerminalRequest = supportsRunInTerminalRequest
        lastSupportsStartDebuggingRequest = supportsStartDebuggingRequest
        return update(
            sessionID: sessionID,
            state: "initializing",
            frames: [Data("initialize-frame".utf8)]
        )
    }

    func launchDebugSession(
        sessionID: String,
        operationID _: String,
        configuration: DebugLaunchConfiguration
    ) throws -> DebugCoreUpdate {
        lastLaunchConfiguration = configuration
        return update(sessionID: sessionID, state: "launching")
    }

    func setDebugBreakpoints(
        sessionID: String,
        sourcePath _: String,
        breakpoints: [DebugSourceBreakpoint]
    ) throws -> DebugCoreUpdate {
        breakpointUpdates.append(breakpoints)
        return update(sessionID: sessionID, state: "ready")
    }

    func setDebugExceptionBreakpoints(
        sessionID: String,
        breakpoints: [DebugExceptionBreakpoint]
    ) throws -> DebugCoreUpdate {
        exceptionBreakpointUpdates.append(breakpoints)
        return update(sessionID: sessionID, state: "ready")
    }

    func setDebugFunctionBreakpoints(
        sessionID: String,
        breakpoints: [DebugFunctionBreakpoint]
    ) throws -> DebugCoreUpdate {
        functionBreakpointUpdates.append(breakpoints)
        return update(sessionID: sessionID, state: "ready")
    }

    func setDebugInstructionBreakpoints(
        sessionID: String,
        breakpoints: [DebugInstructionBreakpoint]
    ) throws -> DebugCoreUpdate {
        instructionBreakpointUpdates.append(breakpoints)
        return update(sessionID: sessionID, state: "ready")
    }

    func debugDataBreakpointInfo(
        sessionID: String,
        operationID: String,
        name _: String,
        variablesReference _: Int?,
        frameID _: Int?
    ) throws -> DebugCoreUpdate {
        lastDataBreakpointInfoOperationID = operationID
        return update(sessionID: sessionID, state: "paused")
    }

    func setDebugDataBreakpoints(
        sessionID: String,
        breakpoints: [DebugDataBreakpoint]
    ) throws -> DebugCoreUpdate {
        dataBreakpointUpdates.append(breakpoints)
        return update(sessionID: sessionID, state: "paused")
    }

    func setDebugVariable(
        sessionID: String,
        operationID: String,
        variablesReference _: Int,
        name _: String,
        value _: String
    ) throws -> DebugCoreUpdate {
        lastSetVariableOperationID = operationID
        return update(sessionID: sessionID, state: "paused")
    }

    func cancelDebugOperation(
        sessionID: String,
        operationID: String,
        reason: String
    ) throws -> DebugCoreUpdate {
        cancelledOperationReasons.append(reason)
        return update(sessionID: sessionID, state: "paused", events: [[
            "sequence": 90,
            "type": "operationFailed",
            "operationId": operationID,
            "command": "threads",
            "code": reason,
            "message": reason == "timedOut"
                ? "Debug operation timed out."
                : "Debug operation was cancelled."
        ]])
    }

    func executeDebugCommand(
        sessionID: String,
        operationID _: String,
        command _: DebugExecutionCommand,
        threadID: Int?,
        targetID _: Int?,
        singleThread: Bool,
        granularity: DebugSteppingGranularity?
    ) throws -> DebugCoreUpdate {
        lastExecutionThreadID = threadID
        lastExecutionSingleThread = singleThread
        lastExecutionGranularity = granularity
        return update(sessionID: sessionID, state: "running")
    }

    func inspectDebugSession(
        sessionID: String,
        operationID: String,
        kind: String,
        threadID: Int?,
        frameID: Int?,
        variablesReference: Int?,
        variableFilter: DebugVariableFilter?,
        start: Int?,
        count: Int?,
        expression: String?,
        context _: String?,
        sourcePath _: String?,
        line _: Int?,
        column: Int?,
        memory: DebugCoreMemoryQuery?
    ) throws -> DebugCoreUpdate {
        lastInspectionOperationID = operationID
        inspectionRequests.append(RecordingDebugInspectionRequest(
            operationID: operationID,
            kind: kind,
            threadID: threadID,
            frameID: frameID,
            variablesReference: variablesReference,
            variableFilter: variableFilter,
            start: start,
            count: count,
            expression: expression,
            column: column,
            memory: memory
        ))
        return update(sessionID: sessionID, state: "paused")
    }

    func receiveDebugData(sessionID _: String, data _: Data) throws -> DebugCoreUpdate {
        receiveUpdates.removeFirst()
    }

    func completeDebugRunInTerminalRequest(
        sessionID: String,
        requestID: String,
        result: Result<DebugRunInTerminalResponse, Error>
    ) throws -> DebugCoreUpdate {
        switch result {
        case .success(let response):
            runInTerminalCompletions.append(RecordingRunInTerminalCompletion(
                requestID: requestID,
                response: response,
                errorDescription: nil
            ))
        case .failure(let error):
            runInTerminalCompletions.append(RecordingRunInTerminalCompletion(
                requestID: requestID,
                response: nil,
                errorDescription: error.localizedDescription
            ))
        }
        return update(
            sessionID: sessionID,
            state: "launching",
            frames: [Data("run-in-terminal-response".utf8)]
        )
    }

    func completeDebugStartDebuggingRequest(
        sessionID: String,
        requestID: String,
        result: Result<Void, Error>
    ) throws -> DebugCoreUpdate {
        if case .success = result {
            startDebuggingResults.append((requestID, true))
        } else {
            startDebuggingResults.append((requestID, false))
        }
        return update(sessionID: sessionID, state: "running")
    }

    func disconnectDebugSession(sessionID: String) throws -> DebugCoreUpdate {
        update(sessionID: sessionID, state: "terminating")
    }

    func destroyDebugSession(sessionID: String) {
        destroyedSessionIDs.append(sessionID)
    }

    func enqueueReceive(
        sessionID: String = "java-session",
        state: String,
        events: [[String: Any]]
    ) {
        receiveUpdates.append(update(
            sessionID: sessionID,
            state: state,
            events: events
        ))
    }

    private func update(
        sessionID: String,
        state: String,
        frames: [Data] = [],
        events: [[String: Any]] = []
    ) -> DebugCoreUpdate {
        let object: [String: Any] = [
            "sessionId": sessionID,
            "state": state,
            "outboundFrames": frames.map { $0.base64EncodedString() },
            "events": events
        ]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return try! JSONDecoder().decode(DebugCoreUpdate.self, from: data)
    }
}

private struct RecordingRunInTerminalCompletion: Equatable {
    let requestID: String
    let response: DebugRunInTerminalResponse?
    let errorDescription: String?
}

@MainActor
private final class RecordingDebugDeadlineScheduler: DebugOperationDeadlineScheduling {
    private var deadlines: [RecordingDebugDeadline] = []

    func schedule(
        afterMilliseconds _: Int,
        action: @escaping @MainActor () -> Void
    ) -> any DebugOperationDeadline {
        let deadline = RecordingDebugDeadline(action: action)
        deadlines.append(deadline)
        return deadline
    }

    func fireLast() {
        deadlines.last?.fire()
    }
}

@MainActor
private final class RecordingDebugDeadline: DebugOperationDeadline {
    private var action: (@MainActor () -> Void)?

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    func cancel() {
        action = nil
    }

    func fire() {
        let action = action
        self.action = nil
        action?()
    }
}

@MainActor private final class Recorder {
    var factoryCalls = 0
    var graphCalls = 0
    weak var latestGraph: TestGraph?
}

@MainActor private final class TestGraph: DebugServiceGraph {
    let genericFeatureTarget: any GenericDebugFeatureTarget = TestGenericDebugFeatureTarget()
    var hasActiveDebugWork = false
    func activate(context: ModuleContext) {}
    func prepareForSleep() async throws {}
    func stop() async {}
}

@MainActor private final class TestGenericDebugFeatureTarget: GenericDebugFeatureTarget {}

@MainActor private final class EmptyModule: LitheModule {
    let manifest: ModuleManifest
    init(id: ModuleID, name: String) {
        manifest = ModuleManifest(id: id, displayName: name, scope: .workspace)
    }
    func activate(context: ModuleContext) async throws {}
    func prepareForSleep() async throws {}
    func sleep() async {}
    func shutdown() async {}
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] { [:] }
}
