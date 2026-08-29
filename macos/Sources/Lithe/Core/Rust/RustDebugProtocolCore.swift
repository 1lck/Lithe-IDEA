import Foundation
import LitheCoreContracts

extension RustCoreBridge: DebugProtocolCore {
    func resolveDebugSteppingFilters(
        adapterID: String,
        filters: DebugSteppingFilters?
    ) throws -> DebugSteppingFilters {
        try executeResult(
            command: "debug.steppingFilters",
            payload: DebugSteppingFiltersPayload(adapterID: adapterID, filters: filters)
        ).get()
    }

    func createDebugSession(
        sessionID: String,
        adapterID: String,
        rootPath: String
    ) throws -> DebugCoreUpdate {
        try executeResult(
            command: "debug.createSession",
            payload: DebugCreateSessionPayload(
                sessionID: sessionID,
                adapterID: adapterID,
                rootPath: rootPath
            )
        ).get()
    }

    func launchDebugSession(
        sessionID: String,
        operationID: String,
        configuration: DebugLaunchConfiguration
    ) throws -> DebugCoreUpdate {
        try executeResult(
            command: "debug.launch",
            payload: DebugLaunchPayload(
                sessionID: sessionID,
                operationID: operationID,
                configuration: configuration
            ),
            operationID: operationID
        ).get()
    }

    func setDebugBreakpoints(
        sessionID: String,
        sourcePath: String,
        breakpoints: [DebugSourceBreakpoint]
    ) throws -> DebugCoreUpdate {
        try executeResult(
            command: "debug.setBreakpoints",
            payload: DebugBreakpointsPayload(
                sessionID: sessionID,
                sourcePath: sourcePath,
                breakpoints: breakpoints
            )
        ).get()
    }

    func setDebugExceptionBreakpoints(
        sessionID: String,
        breakpoints: [DebugExceptionBreakpoint]
    ) throws -> DebugCoreUpdate {
        try executeResult(
            command: "debug.setExceptionBreakpoints",
            payload: DebugExceptionBreakpointsPayload(
                sessionID: sessionID,
                breakpoints: breakpoints
            )
        ).get()
    }

    func setDebugFunctionBreakpoints(
        sessionID: String,
        breakpoints: [DebugFunctionBreakpoint]
    ) throws -> DebugCoreUpdate {
        try executeResult(
            command: "debug.setFunctionBreakpoints",
            payload: DebugFunctionBreakpointsPayload(
                sessionID: sessionID,
                breakpoints: breakpoints
            )
        ).get()
    }

    func debugDataBreakpointInfo(
        sessionID: String,
        operationID: String,
        name: String,
        variablesReference: Int?,
        frameID: Int?
    ) throws -> DebugCoreUpdate {
        try executeResult(
            command: "debug.dataBreakpointInfo",
            payload: DebugDataBreakpointInfoPayload(
                sessionID: sessionID,
                operationID: operationID,
                name: name,
                variablesReference: variablesReference,
                frameID: frameID
            ),
            operationID: operationID
        ).get()
    }

    func setDebugDataBreakpoints(
        sessionID: String,
        breakpoints: [DebugDataBreakpoint]
    ) throws -> DebugCoreUpdate {
        try executeResult(
            command: "debug.setDataBreakpoints",
            payload: DebugDataBreakpointsPayload(
                sessionID: sessionID,
                breakpoints: breakpoints
            )
        ).get()
    }

    func setDebugVariable(
        sessionID: String,
        operationID: String,
        variablesReference: Int,
        name: String,
        value: String
    ) throws -> DebugCoreUpdate {
        try executeResult(
            command: "debug.setVariable",
            payload: DebugSetVariablePayload(
                sessionID: sessionID,
                operationID: operationID,
                variablesReference: variablesReference,
                name: name,
                value: value
            ),
            operationID: operationID
        ).get()
    }

    func cancelDebugOperation(
        sessionID: String,
        operationID: String,
        reason: String
    ) throws -> DebugCoreUpdate {
        try executeResult(
            command: "debug.cancelOperation",
            payload: DebugCancelOperationPayload(
                sessionID: sessionID,
                operationID: operationID,
                reason: reason
            ),
            operationID: operationID
        ).get()
    }

    func executeDebugCommand(
        sessionID: String,
        operationID: String,
        command: DebugExecutionCommand,
        threadID: Int?,
        targetID: Int?,
        singleThread: Bool
    ) throws -> DebugCoreUpdate {
        try executeResult(
            command: "debug.execute",
            payload: DebugExecutePayload(
                sessionID: sessionID,
                operationID: operationID,
                command: command.rawValue,
                threadID: threadID,
                targetID: targetID,
                singleThread: singleThread
            ),
            operationID: operationID
        ).get()
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
        sourcePath: String?,
        line: Int?,
        column: Int?
    ) throws -> DebugCoreUpdate {
        try executeResult(
            command: "debug.inspect",
            payload: DebugInspectPayload(
                sessionID: sessionID,
                operationID: operationID,
                kind: kind,
                threadID: threadID,
                frameID: frameID,
                variablesReference: variablesReference,
                variableFilter: variableFilter,
                start: start,
                count: count,
                expression: expression,
                sourcePath: sourcePath,
                line: line,
                column: column
            ),
            operationID: operationID
        ).get()
    }

    func receiveDebugData(sessionID: String, data: Data) throws -> DebugCoreUpdate {
        try executeResult(
            command: "debug.receive",
            payload: DebugReceivePayload(
                sessionID: sessionID,
                dataBase64: data.base64EncodedString()
            )
        ).get()
    }

    func disconnectDebugSession(sessionID: String) throws -> DebugCoreUpdate {
        try executeResult(
            command: "debug.disconnect",
            payload: DebugSessionPayload(sessionID: sessionID)
        ).get()
    }

    func destroyDebugSession(sessionID: String) {
        let result: Result<ToolingJSONValue, CoreCallError> = executeResult(
            command: "debug.destroySession",
            payload: DebugSessionPayload(sessionID: sessionID)
        )
        _ = result
    }
}

private struct DebugCreateSessionPayload: Encodable {
    let sessionID: String
    let adapterID: String
    let rootPath: String

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case adapterID = "adapterId"
        case rootPath
    }
}

private struct DebugSteppingFiltersPayload: Encodable {
    let adapterID: String
    let filters: DebugSteppingFilters?

    private enum CodingKeys: String, CodingKey {
        case adapterID = "adapterId"
        case filters
    }
}

private struct DebugSessionPayload: Encodable {
    let sessionID: String

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
    }
}

private struct DebugLaunchPayload: Encodable {
    let sessionID: String
    let operationID: String
    let configuration: DebugLaunchConfiguration

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case operationID = "operationId"
        case configuration
    }
}

private struct DebugBreakpointsPayload: Encodable {
    let sessionID: String
    let sourcePath: String
    let breakpoints: [DebugSourceBreakpoint]

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case sourcePath
        case breakpoints
    }
}

private struct DebugExceptionBreakpointsPayload: Encodable {
    let sessionID: String
    let breakpoints: [DebugExceptionBreakpoint]

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case breakpoints
    }
}

private struct DebugFunctionBreakpointsPayload: Encodable {
    let sessionID: String
    let breakpoints: [DebugFunctionBreakpoint]

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case breakpoints
    }
}

private struct DebugDataBreakpointInfoPayload: Encodable {
    let sessionID: String
    let operationID: String
    let name: String
    let variablesReference: Int?
    let frameID: Int?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case operationID = "operationId"
        case name, variablesReference
        case frameID = "frameId"
    }
}

private struct DebugDataBreakpointsPayload: Encodable {
    let sessionID: String
    let breakpoints: [DebugDataBreakpoint]

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case breakpoints
    }
}

private struct DebugSetVariablePayload: Encodable {
    let sessionID: String
    let operationID: String
    let variablesReference: Int
    let name: String
    let value: String

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case operationID = "operationId"
        case variablesReference, name, value
    }
}

private struct DebugCancelOperationPayload: Encodable {
    let sessionID: String
    let operationID: String
    let reason: String

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case operationID = "operationId"
        case reason
    }
}

private struct DebugExecutePayload: Encodable {
    let sessionID: String
    let operationID: String
    let command: String
    let threadID: Int?
    let targetID: Int?
    let singleThread: Bool

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case operationID = "operationId"
        case command
        case threadID = "threadId"
        case targetID = "targetId"
        case singleThread
    }
}

private struct DebugInspectPayload: Encodable {
    let sessionID: String
    let operationID: String
    let kind: String
    let threadID: Int?
    let frameID: Int?
    let variablesReference: Int?
    let variableFilter: DebugVariableFilter?
    let start: Int?
    let count: Int?
    let expression: String?
    let sourcePath: String?
    let line: Int?
    let column: Int?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case operationID = "operationId"
        case kind
        case threadID = "threadId"
        case frameID = "frameId"
        case variablesReference
        case variableFilter, start, count
        case expression
        case sourcePath, line, column
    }
}

private struct DebugReceivePayload: Encodable {
    let sessionID: String
    let dataBase64: String

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case dataBase64
    }
}
