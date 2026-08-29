import Foundation
import LitheApplicationKernel
import LitheCoreContracts
@testable import LitheDebugModule
import LitheModuleAPI
import Testing

@MainActor
struct DebugModuleTests {
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
            "type": "stopped",
            "reason": "breakpoint",
            "threadId": 13
        ]])
        transport.emitData(Data("stopped-event".utf8))
        #expect(core.inspectionRequests.map(\.kind) == ["threads"])

        let threadsOperationID = try #require(core.lastInspectionOperationID)
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
        #expect(core.inspectionRequests.map(\.kind) == ["threads", "stackTrace"])
        #expect(core.inspectionRequests.last?.threadID == 13)

        let stackOperationID = try #require(core.lastInspectionOperationID)
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
        #expect(core.inspectionRequests.map(\.kind) == ["threads", "stackTrace", "scopes"])
        #expect(core.inspectionRequests.last?.frameID == 70)

        let scopesOperationID = try #require(core.lastInspectionOperationID)
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
            "threads", "stackTrace", "scopes", "variables"
        ])
        #expect(core.inspectionRequests.last?.variablesReference == 200)

        let variablesOperationID = try #require(core.lastInspectionOperationID)
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
        #expect(feature.scopes.first?.variablesReference == 200)
        #expect(feature.variables.first?.value == "7")
        #expect(stoppedLocation?.0 == source.standardizedFileURL)
        #expect(stoppedLocation?.1 == 12)
        #expect(stoppedLocation?.2 == 5)
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
        #expect(feature.visibleVariableRows.map(\.variable.name) == ["user", "name"])
        #expect(feature.visibleVariableRows.map(\.depth) == [0, 1])
        feature.toggleVariableExpansion(user)
        #expect(feature.visibleVariableRows.map(\.variable.name) == ["user"])
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

private struct RecordingDebugInspectionRequest: Equatable {
    let kind: String
    let threadID: Int?
    let frameID: Int?
    let variablesReference: Int?
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

    func createDebugSession(
        sessionID: String,
        adapterID _: String,
        rootPath _: String
    ) throws -> DebugCoreUpdate {
        update(
            sessionID: sessionID,
            state: "initializing",
            frames: [Data("initialize-frame".utf8)]
        )
    }

    func launchDebugSession(
        sessionID: String,
        operationID _: String,
        configuration _: DebugLaunchConfiguration
    ) throws -> DebugCoreUpdate {
        update(sessionID: sessionID, state: "launching")
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
        expression _: String?,
        sourcePath _: String?,
        line _: Int?,
        column _: Int?
    ) throws -> DebugCoreUpdate {
        lastInspectionOperationID = operationID
        inspectionRequests.append(RecordingDebugInspectionRequest(
            kind: kind,
            threadID: threadID,
            frameID: frameID,
            variablesReference: variablesReference
        ))
        return update(sessionID: sessionID, state: "paused")
    }

    func receiveDebugData(sessionID _: String, data _: Data) throws -> DebugCoreUpdate {
        receiveUpdates.removeFirst()
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
