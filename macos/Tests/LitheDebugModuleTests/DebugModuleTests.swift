import Foundation
import LitheApplicationKernel
import LitheCoreContracts
@testable import LitheDebugModule
import LitheModuleAPI
import Testing

@MainActor
struct DebugModuleTests {
    @Test
    func debuggeeOutputIsMirroredIntoConsoleWithoutTerminalControlSequences() {
        let manager = DebugAdapterSessionManager(providers: []) { _, _ in nil }
        let feature = GenericDebugFeatureModel(sessions: manager)

        feature.appendDebuggeeOutput("\u{001B}[31mready\u{001B}[0m\r\n")

        #expect(feature.output == "ready\n")
    }

    @Test
    func debuggeeOutputNormalizationPreservesStateAcrossOutputChunks() {
        let manager = DebugAdapterSessionManager(providers: []) { _, _ in nil }
        let feature = GenericDebugFeatureModel(sessions: manager)

        feature.appendDebuggeeOutput("\u{001B}")
        feature.appendDebuggeeOutput("[31mready\u{001B}[0m\r")
        feature.appendDebuggeeOutput("\nnext\n")

        #expect(feature.output == "ready\nnext\n")
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
        #expect(feature.state == .paused)
        #expect(feature.errorMessage == nil)
        #expect(manager.activeSessionIDs == [firstID])

        feature.stop()
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
                ]]
            ]
        ]])
        transport.emitData(Data("scopes-response".utf8))
        #expect(core.inspectionRequests.map(\.kind) == [
            "exceptionInfo", "threads", "stackTrace", "scopes", "variables"
        ])
        #expect(core.inspectionRequests.last?.variablesReference == 200)

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
    func protocolSessionInitializesAndStopsThroughInjectedTransport() throws {
        let transport = RecordingTransport()
        let session = DebugAdapterProtocolSession(
            adapterID: "test-adapter",
            transport: transport
        )

        try session.start(rootURL: URL(fileURLWithPath: "/tmp/debug-module"))

        #expect(session.state == .initializing)
        #expect(transport.isRunning)
        let initialize = try #require(transport.request(named: "initialize"))
        transport.emitJSON([
            "seq": 2,
            "type": "response",
            "request_seq": initialize["seq"] as! Int,
            "success": true,
            "command": "initialize",
            "body": [
                "supportsConfigurationDoneRequest": true,
                "supportsFunctionBreakpoints": true,
                "supportsDataBreakpoints": true,
                "supportsSetVariable": true,
                "supportsStepBack": true,
                "supportsExceptionInfoRequest": false,
                "supportsStepInTargetsRequest": true,
                "supportsGotoTargetsRequest": true,
                "supportsRestartRequest": true,
                "supportsTerminateRequest": true
            ]
        ])
        #expect(session.state == .ready)
        session.setExceptionBreakpoints([
            DebugExceptionBreakpoint(filter: "uncaught", enabled: true),
            DebugExceptionBreakpoint(filter: "caught", enabled: false)
        ])
        session.setFunctionBreakpoints([
            DebugFunctionBreakpoint(
                name: "example.Main.run",
                enabled: true,
                condition: "ready",
                hitCondition: "2"
            ),
            DebugFunctionBreakpoint(name: "example.Main.skip", enabled: false)
        ])
        session.setDataBreakpoints([
            DebugDataBreakpoint(
                dataID: "field:count",
                label: "Main.count",
                accessType: "write",
                condition: "count > 1"
            )
        ])
        transport.emitJSON([
            "seq": 3,
            "type": "event",
            "event": "initialized"
        ])
        let exceptionRequest = try #require(transport.request(named: "setExceptionBreakpoints"))
        let exceptionArguments = try #require(exceptionRequest["arguments"] as? [String: Any])
        #expect(exceptionArguments["filters"] as? [String] == ["uncaught"])
        let functionRequest = try #require(transport.request(named: "setFunctionBreakpoints"))
        let functionArguments = try #require(functionRequest["arguments"] as? [String: Any])
        let functionValues = try #require(functionArguments["breakpoints"] as? [[String: Any]])
        #expect(functionValues.count == 1)
        #expect(functionValues.first?["name"] as? String == "example.Main.run")
        #expect(functionValues.first?["condition"] as? String == "ready")
        #expect(functionValues.first?["hitCondition"] as? String == "2")
        let dataRequest = try #require(transport.request(named: "setDataBreakpoints"))
        let dataArguments = try #require(dataRequest["arguments"] as? [String: Any])
        let dataValues = try #require(dataArguments["breakpoints"] as? [[String: Any]])
        #expect(dataValues.first?["dataId"] as? String == "field:count")
        #expect(dataValues.first?["accessType"] as? String == "write")
        var dataInfo: Result<DebugDataBreakpointInfo, Error>?
        session.requestDataBreakpointInfo(
            name: "count",
            variablesReference: 42,
            frameID: 7
        ) { dataInfo = $0 }
        let dataInfoRequest = try #require(transport.request(named: "dataBreakpointInfo"))
        transport.emitJSON([
            "seq": 8,
            "type": "response",
            "request_seq": dataInfoRequest["seq"] as! Int,
            "success": true,
            "command": "dataBreakpointInfo",
            "body": [
                "dataId": "field:count",
                "description": "Main.count",
                "accessTypes": ["write"],
                "canPersist": false
            ]
        ])
        #expect(try dataInfo?.get().dataID == "field:count")
        #expect(transport.request(named: "configurationDone") != nil)

        transport.emitJSON([
            "seq": 9,
            "type": "event",
            "event": "stopped",
            "body": ["reason": "breakpoint", "threadId": 11]
        ])
        var setVariable: Result<DebugVariable, Error>?
        session.setVariable(
            variablesReference: 42,
            name: "count",
            value: "7"
        ) { setVariable = $0 }
        let setVariableRequest = try #require(transport.request(named: "setVariable"))
        let setVariableArguments = try #require(setVariableRequest["arguments"] as? [String: Any])
        #expect(setVariableArguments["variablesReference"] as? Int == 42)
        #expect(setVariableArguments["name"] as? String == "count")
        #expect(setVariableArguments["value"] as? String == "7")
        transport.emitJSON([
            "seq": 10,
            "type": "response",
            "request_seq": setVariableRequest["seq"] as! Int,
            "success": true,
            "command": "setVariable",
            "body": ["value": "7", "type": "int", "variablesReference": 0]
        ])
        #expect(try setVariable?.get().value == "7")
        var stepTargets: Result<[DebugStepInTarget], Error>?
        session.requestStepInTargets(frameID: 7) { stepTargets = $0 }
        let stepTargetsRequest = try #require(transport.request(named: "stepInTargets"))
        transport.emitJSON([
            "seq": 10,
            "type": "response",
            "request_seq": stepTargetsRequest["seq"] as! Int,
            "success": true,
            "command": "stepInTargets",
            "body": ["targets": [["id": 21, "label": "service.load()", "line": 12]]]
        ])
        #expect(try stepTargets?.get().first?.id == 21)
        var gotoTargets: Result<[DebugGotoTarget], Error>?
        session.requestGotoTargets(
            fileURL: URL(fileURLWithPath: "/tmp/Main.java"),
            line: 20,
            column: 5
        ) { gotoTargets = $0 }
        let gotoTargetsRequest = try #require(transport.request(named: "gotoTargets"))
        transport.emitJSON([
            "seq": 11,
            "type": "response",
            "request_seq": gotoTargetsRequest["seq"] as! Int,
            "success": true,
            "command": "gotoTargets",
            "body": ["targets": [["id": 31, "label": "Main.java:20", "line": 20]]]
        ])
        #expect(try gotoTargets?.get().first?.id == 31)
        session.execute(.stepIn, threadID: 11, targetID: 21)
        session.execute(.goto, threadID: 11, targetID: 31)
        session.execute(.stepBack, threadID: 11)
        session.execute(.restart, threadID: 11)
        session.execute(.terminate, threadID: 11)
        let stepBack = try #require(transport.request(named: "stepBack"))
        let stepBackArguments = try #require(stepBack["arguments"] as? [String: Any])
        #expect(stepBackArguments["threadId"] as? Int == 11)
        #expect(stepBackArguments["singleThread"] as? Bool == false)
        let smartStep = try #require(transport.request(named: "stepIn"))
        #expect((smartStep["arguments"] as? [String: Any])?["targetId"] as? Int == 21)
        let goto = try #require(transport.request(named: "goto"))
        #expect((goto["arguments"] as? [String: Any])?["targetId"] as? Int == 31)
        let restart = try #require(transport.request(named: "restart"))
        #expect((restart["arguments"] as? [String: Any])?["threadId"] == nil)
        let terminate = try #require(transport.request(named: "terminate"))
        #expect((terminate["arguments"] as? [String: Any])?["threadId"] == nil)

        session.stop()

        #expect(!transport.isRunning)
        #expect(session.state == .idle)
        #expect(transport.stopCalls == 1)
    }

    @Test
    func protocolSessionDisconnectTerminatesOnlyLaunchedDebuggees() throws {
        let launchArguments = try disconnectArguments(for: .launch)
        #expect(launchArguments["restart"] as? Bool == false)
        #expect(launchArguments["terminateDebuggee"] as? Bool == true)

        let attachArguments = try disconnectArguments(for: .attach)
        #expect(attachArguments["restart"] as? Bool == false)
        #expect(attachArguments["terminateDebuggee"] as? Bool == false)

        let unstartedArguments = try disconnectArguments(for: nil)
        #expect(unstartedArguments["restart"] as? Bool == false)
        #expect(unstartedArguments["terminateDebuggee"] as? Bool == false)
    }

    @Test
    func protocolSessionCreatesAndStopsChildTransport() throws {
        let parent = RecordingTransport()
        let session = DebugAdapterProtocolSession(adapterID: "test-adapter", transport: parent)
        let root = URL(fileURLWithPath: "/tmp/debug-child", isDirectory: true)

        try session.start(rootURL: root)
        let initialize = try #require(parent.request(named: "initialize"))
        parent.emitJSON([
            "seq": 2,
            "type": "response",
            "request_seq": initialize["seq"] as! Int,
            "success": true,
            "command": "initialize",
            "body": [:]
        ])
        parent.emitJSON([
            "seq": 3,
            "type": "request",
            "command": "startDebugging",
            "arguments": [
                "configuration": [
                    "name": "Child",
                    "request": "launch",
                    "program": root.appendingPathComponent("main.js").path
                ]
            ]
        ])

        let child = try #require(parent.children.first)
        #expect(child.isRunning)
        #expect(child.request(named: "initialize") != nil)
        #expect(parent.response(to: 3)?["success"] as? Bool == true)

        session.stop()

        #expect(!child.isRunning)
        #expect(child.stopCalls == 1)
    }

    @Test
    func protocolSessionRemovesFinishedChildTransport() throws {
        let parent = RecordingTransport()
        let session = DebugAdapterProtocolSession(adapterID: "test-adapter", transport: parent)
        let root = URL(fileURLWithPath: "/tmp/debug-child-cleanup", isDirectory: true)

        try session.start(rootURL: root)
        let initialize = try #require(parent.request(named: "initialize"))
        parent.emitJSON([
            "seq": 2,
            "type": "response",
            "request_seq": initialize["seq"] as! Int,
            "success": true,
            "command": "initialize",
            "body": [:]
        ])
        parent.emitJSON([
            "seq": 3,
            "type": "request",
            "command": "startDebugging",
            "arguments": [
                "configuration": [
                    "name": "Child",
                    "request": "launch",
                    "program": root.appendingPathComponent("main.js").path
                ]
            ]
        ])

        let child = try #require(parent.children.first)
        child.terminate(0)
        #expect(!child.isRunning)

        session.stop()

        // A terminated child is removed immediately, so parent shutdown does
        // not retain or stop the same transport a second time.
        #expect(child.stopCalls == 0)
    }

    @Test
    func protocolSessionReportsLaunchFailureInDebugOutput() throws {
        let transport = RecordingTransport()
        let session = DebugAdapterProtocolSession(
            adapterID: "test-adapter",
            transport: transport
        )
        var events: [DebugAdapterEvent] = []
        session.onEvent = { events.append($0) }

        try session.start(rootURL: URL(fileURLWithPath: "/tmp/debug-launch-failure"))
        let initialize = try #require(transport.request(named: "initialize"))
        transport.emitJSON([
            "seq": 2,
            "type": "response",
            "request_seq": initialize["seq"] as! Int,
            "success": true,
            "command": "initialize",
            "body": [:]
        ])
        try session.launch(DebugLaunchConfiguration(
            name: "Broken Main",
            request: .launch,
            arguments: ["program": .string("/tmp/missing-main")]
        ))
        let launch = try #require(transport.request(named: "launch"))
        transport.emitJSON([
            "seq": 3,
            "type": "response",
            "request_seq": launch["seq"] as! Int,
            "success": false,
            "command": "launch",
            "message": "main class was not found"
        ])

        #expect(session.state == .failed)
        #expect(events.contains(.output(
            category: "stderr",
            output: "Debug launch failed: launch failed: main class was not found\n"
        )))
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

    private func disconnectArguments(
        for requestKind: DebugRequestKind?
    ) throws -> [String: Any] {
        let transport = RecordingTransport()
        let session = DebugAdapterProtocolSession(
            adapterID: "test-adapter",
            transport: transport
        )
        try session.start(rootURL: URL(fileURLWithPath: "/tmp/debug-disconnect"))
        defer {
            if session.isRunning { session.stop() }
        }
        let initialize = try #require(transport.request(named: "initialize"))
        transport.emitJSON([
            "seq": 2,
            "type": "response",
            "request_seq": initialize["seq"] as! Int,
            "success": true,
            "command": "initialize",
            "body": [:]
        ])
        if let requestKind {
            try session.launch(DebugLaunchConfiguration(
                name: "Disconnect Policy",
                request: requestKind,
                arguments: [:]
            ))
        }
        session.stop()
        let disconnect = try #require(transport.request(named: "disconnect"))
        return try #require(disconnect["arguments"] as? [String: Any])
    }
}

@MainActor
private final class RecordingTransport: DebugAdapterTransport, DebugAdapterChildTransportProviding {
    private(set) var isRunning = false
    var onData: ((Data) -> Void)?
    var onErrorOutput: ((Data) -> Void)?
    var onTermination: ((Int) -> Void)?
    private(set) var sentData: [Data] = []
    private(set) var children: [RecordingTransport] = []
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

    func makeChildTransport() -> (any DebugAdapterTransport)? {
        let child = RecordingTransport()
        children.append(child)
        return child
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
}

private struct RecordingDebugVariablePageRequest: Equatable {
    let reference: Int
    let filter: DebugVariableFilter?
    let start: Int?
    let count: Int?
}

@MainActor
private final class DeferredInspectionDebugSession: DebugAdapterControllingSession {
    let capabilities: DebugAdapterCapabilities
    private(set) var isRunning = false
    private(set) var state: DebugAdapterState = .idle
    private(set) var startCount = 0
    private(set) var launchConfigurations: [DebugLaunchConfiguration] = []
    private(set) var breakpointUpdates: [[DebugSourceBreakpoint]] = []
    var failNextLaunch = false
    var onStateChange: ((DebugAdapterState) -> Void)?
    var onEvent: ((DebugAdapterEvent) -> Void)?

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

    func setBreakpoints(_ breakpoints: [DebugSourceBreakpoint], in _: URL) {
        breakpointUpdates.append(breakpoints)
    }
    func execute(_: DebugExecutionCommand, threadID _: Int?) {}
    func requestThreads(_: @escaping (Result<[DebugThread], Error>) -> Void) {}

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
        _: String,
        frameID _: Int?,
        completion _: @escaping (Result<DebugVariable, Error>) -> Void
    ) {}

    // This double deliberately delivers responses after cancellation to model
    // adapters and callback queues that cannot retract an already-sent result.
    func cancelPendingOperations() {}

    func emit(_ event: DebugAdapterEvent) {
        onEvent?(event)
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
    private(set) var dataBreakpointUpdates: [[DebugDataBreakpoint]] = []
    private(set) var cancelledOperationReasons: [String] = []
    private(set) var lastExecutionSingleThread: Bool?
    private(set) var lastExecutionThreadID: Int?
    private(set) var inspectionRequests: [RecordingDebugInspectionRequest] = []
    private(set) var lastLaunchConfiguration: DebugLaunchConfiguration?
    private(set) var lastSupportsRunInTerminalRequest: Bool?
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
        supportsRunInTerminalRequest: Bool
    ) throws -> DebugCoreUpdate {
        lastSupportsRunInTerminalRequest = supportsRunInTerminalRequest
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
        singleThread: Bool
    ) throws -> DebugCoreUpdate {
        lastExecutionThreadID = threadID
        lastExecutionSingleThread = singleThread
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
        expression _: String?,
        sourcePath _: String?,
        line _: Int?,
        column _: Int?
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
            count: count
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
