import Foundation

/// Core-owned paging cursor of one variable container (`debug.planVariablePage`).
///
/// The host keeps the cursor for each loaded container and echoes it back with
/// every page; only `next` is meant to be read. The other fields round-trip
/// unchanged so Core, not the host, decides when a container is exhausted.
public struct DebugVariablePageCursor: Codable, Equatable, Sendable {
    /// The `variables` request to send next.
    public struct Request: Codable, Equatable, Sendable {
        public let filter: DebugVariableFilter?
        public let start: Int
        public let count: Int
        /// Children still to load across every remaining kind, when the adapter reported counts.
        public let remainingCount: Int?
    }

    public struct Segment: Codable, Equatable, Sendable {
        public let filter: DebugVariableFilter?
        public let nextStart: Int
        public let totalCount: Int?
    }

    public let variablesReference: Int
    public let pageSize: Int
    public let segments: [Segment]
    public let loadedPages: [String]
    /// Absent once the container is exhausted.
    public let next: Request?
}

/// Identity fields of one returned child; Core fingerprints them to detect repeated pages.
public struct DebugVariablePageItem: Codable, Equatable, Sendable {
    public let name: String
    public let value: String
    public let type: String?
    public let evaluateName: String?
    public let variablesReference: Int

    public init(_ variable: DebugVariable) {
        name = variable.name
        value = variable.value
        type = variable.type
        evaluateName = variable.evaluateName
        variablesReference = variable.variablesReference
    }
}

/// Result of merging one page: whether to show it, and the cursor that follows.
public struct DebugVariablePageReduction: Codable, Equatable, Sendable {
    public let accept: Bool
    public let state: DebugVariablePageCursor
}

/// One direction a disassembly fetch extends the listing.
public enum DebugDisassemblyDirection: String, Codable, Equatable, Sendable {
    case around, before, after
}

/// Core-owned cursor of one bounded disassembly request sequence
/// (`debug.planDisassemblyWindow`). Hosts send `request` and echo the fetch with the reply.
public struct DebugDisassemblyFetch: Codable, Equatable, Sendable {
    public struct Request: Codable, Equatable, Sendable {
        public let memoryReference: String
        public let instructionOffset: Int
        public let instructionCount: Int
    }

    public let direction: DebugDisassemblyDirection
    public let reference: String
    public let phase: String
    public let count: Int
    public let instructionsBefore: Int
    public let windowFailure: String?
    public let request: Request
}

/// What the adapter answered to a fetch's request.
public enum DebugDisassemblyReply: Equatable, Sendable {
    case instructions([DebugDisassembledInstruction])
    /// The adapter answered `disassemble` with `success: false`.
    case rejected(String)
    /// Transport failure, timeout or cancellation.
    case failed(String)
}

/// The next step of a disassembly fetch.
public enum DebugDisassemblyStep: Equatable, Sendable {
    case request(DebugDisassemblyFetch)
    /// `keep` indexes the reply's instructions to list, in order.
    case page(keep: [Int], exhausted: Bool)
    case failed(String)
}

/// Shared paging rules for the variables tree and the disassembly listing.
///
/// Core owns when to ask for more, how to recover from refused windows and when
/// a direction or container is exhausted; hosts keep page sizes, rows,
/// expansion, viewport and scroll anchors.
public protocol DebugPagingPlanning: Sendable {
    func planVariablePage(
        variablesReference: Int,
        namedVariables: Int,
        indexedVariables: Int,
        pageSize: Int
    ) throws -> DebugVariablePageCursor
    func reduceVariablePage(
        _ state: DebugVariablePageCursor,
        requested: DebugVariablePageCursor.Request,
        page: [DebugVariablePageItem],
        newItemCount: Int
    ) throws -> DebugVariablePageReduction
    func planDisassemblyWindow(
        direction: DebugDisassemblyDirection,
        reference: String,
        count: Int,
        instructionsBefore: Int
    ) throws -> DebugDisassemblyFetch
    func reduceDisassemblyPage(
        _ fetch: DebugDisassemblyFetch,
        reply: DebugDisassemblyReply,
        knownAddresses: [String]
    ) throws -> DebugDisassemblyStep
}

/// A JSON command transport to Rust Core, shared by the app bridge and tests
/// that link the same Core library.
public protocol DebugPagingCoreCommandExecuting: DebugPagingPlanning {
    func executeDebugPagingCommand<Payload: Encodable, Response: Decodable>(
        _ command: String,
        payload: Payload
    ) throws -> Response
}

public extension DebugPagingCoreCommandExecuting {
    func planVariablePage(
        variablesReference: Int,
        namedVariables: Int,
        indexedVariables: Int,
        pageSize: Int
    ) throws -> DebugVariablePageCursor {
        return try executeDebugPagingCommand("debug.planVariablePage", payload: PlanVariablePagePayload(
            variablesReference: variablesReference,
            namedVariables: namedVariables,
            indexedVariables: indexedVariables,
            pageSize: pageSize
        ))
    }

    func reduceVariablePage(
        _ state: DebugVariablePageCursor,
        requested: DebugVariablePageCursor.Request,
        page: [DebugVariablePageItem],
        newItemCount: Int
    ) throws -> DebugVariablePageReduction {
        return try executeDebugPagingCommand("debug.reduceVariablePage", payload: ReduceVariablePagePayload(
            state: state,
            requested: requested,
            page: page,
            newItemCount: newItemCount
        ))
    }

    func planDisassemblyWindow(
        direction: DebugDisassemblyDirection,
        reference: String,
        count: Int,
        instructionsBefore: Int
    ) throws -> DebugDisassemblyFetch {
        return try executeDebugPagingCommand("debug.planDisassemblyWindow", payload: PlanDisassemblyWindowPayload(
            direction: direction,
            reference: reference,
            count: count,
            instructionsBefore: instructionsBefore
        ))
    }

    func reduceDisassemblyPage(
        _ fetch: DebugDisassemblyFetch,
        reply: DebugDisassemblyReply,
        knownAddresses: [String]
    ) throws -> DebugDisassemblyStep {
        let encodedReply: ReduceDisassemblyPageReply
        switch reply {
        case .instructions(let instructions):
            encodedReply = ReduceDisassemblyPageReply(kind: "instructions", instructions: instructions.map {
                ReduceDisassemblyPageInstruction(address: $0.address, instruction: $0.instruction, instructionBytes: $0.instructionBytes)
            }, message: nil)
        case .rejected(let message):
            encodedReply = ReduceDisassemblyPageReply(kind: "rejected", instructions: nil, message: message)
        case .failed(let message):
            encodedReply = ReduceDisassemblyPageReply(kind: "failed", instructions: nil, message: message)
        }
        let step: ReduceDisassemblyPageStep = try executeDebugPagingCommand("debug.reduceDisassemblyPage", payload: ReduceDisassemblyPagePayload(
            fetch: fetch,
            reply: encodedReply,
            knownAddresses: knownAddresses
        ))
        switch (step.kind, step.fetch, step.keep, step.exhausted, step.message) {
        case ("request", let fetch?, _, _, _): return .request(fetch)
        case ("page", _, let keep?, let exhausted?, _): return .page(keep: keep, exhausted: exhausted)
        case ("failed", _, _, _, let message?): return .failed(message)
        default: throw DebugPagingCoreError.invalidStep(step.kind)
        }
    }
}

/// A Core reply that does not match the paging contract.
public enum DebugPagingCoreError: Error, Equatable, Sendable {
    case invalidStep(String)
}

private struct PlanVariablePagePayload: Encodable {
    let variablesReference: Int
    let namedVariables: Int
    let indexedVariables: Int
    let pageSize: Int
}

private struct ReduceVariablePagePayload: Encodable {
    let state: DebugVariablePageCursor
    let requested: DebugVariablePageCursor.Request
    let page: [DebugVariablePageItem]
    let newItemCount: Int
}

private struct PlanDisassemblyWindowPayload: Encodable {
    let direction: DebugDisassemblyDirection
    let reference: String
    let count: Int
    let instructionsBefore: Int
}

private struct ReduceDisassemblyPageInstruction: Encodable {
    let address: String
    let instruction: String
    let instructionBytes: String?
}

private struct ReduceDisassemblyPageReply: Encodable {
    let kind: String
    let instructions: [ReduceDisassemblyPageInstruction]?
    let message: String?
}

private struct ReduceDisassemblyPagePayload: Encodable {
    let fetch: DebugDisassemblyFetch
    let reply: ReduceDisassemblyPageReply
    let knownAddresses: [String]
}

private struct ReduceDisassemblyPageStep: Decodable {
    let kind: String
    let fetch: DebugDisassemblyFetch?
    let keep: [Int]?
    let exhausted: Bool?
    let message: String?
}
