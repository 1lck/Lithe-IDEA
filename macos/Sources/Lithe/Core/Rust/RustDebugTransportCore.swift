import Foundation

/// Rust Core's lifecycle rules for one IDE-to-adapter byte stream: state
/// transitions, generation tokens, deadlines, queue budgets and the single
/// in-flight write. The platform reports what happened and runs the effects Core
/// returns; Core never opens a socket, reads a clock or sees the bytes.
// Note: .agents/notes/implemented/architecture/2026-10-27-debug-tcp-transport-lifecycle.md
protocol DebugTransportLifecycleCore: Sendable {
    func debugTransportPolicy() throws -> DebugTransportPolicy
    func handleDebugTransportEvent(transportID: String, event: DebugTransportEvent) throws -> DebugTransportStep
    func releaseDebugTransport(transportID: String) throws
}

/// Per-transport overrides; a `nil` field keeps Core's default.
struct DebugTransportLimitOverrides: Encodable, Equatable, Sendable {
    var discoveryMilliseconds: Int?
    var connectMilliseconds: Int?
    var writeMilliseconds: Int?
    var bufferedBytes: Int?
    var bufferedWrites: Int?
    var drainMilliseconds: Int?
}

struct DebugTransportLimits: Decodable, Equatable, Sendable {
    let discoveryMilliseconds: Int
    let connectMilliseconds: Int
    let writeMilliseconds: Int
    let bufferedBytes: Int
    let bufferedWrites: Int
    let drainMilliseconds: Int
}

struct DebugTransportPolicy: Decodable, Equatable, Sendable {
    let limits: DebugTransportLimits
    /// The window a DAP `initialize` round trip gets, so a session never gives up before its transport does.
    let initializationMilliseconds: Int
}

enum DebugTransportPhase: String, Decodable, Equatable, Sendable {
    case stopped, discovering, connecting, ready, draining
}

enum DebugTransportOutcome: String, Decodable, Equatable, Sendable {
    case applied, ignored, rejectedNotRunning, rejectedBufferLimit
}

enum DebugTransportTimerPurpose: String, Decodable, Equatable, Sendable {
    case discovery, connect, write, drain
}

enum DebugTransportFailureReason: String, Decodable, Equatable, Sendable {
    case startupTimedOut, writeTimedOut, bufferLimit, invalidEndpoint, host
}

/// What the platform reports or asks for. Callback events carry the `generation`
/// the platform captured when it started the work they answer.
enum DebugTransportEvent: Encodable, Equatable, Sendable {
    case start(DebugTransportLimitOverrides)
    case send(bytes: Int)
    case stop
    case finishSendingAndStop
    case endpointResolved(generation: UInt64, host: String, port: Int)
    case connectionReady(generation: UInt64)
    case dataReceived(generation: UInt64)
    case peerClosed(generation: UInt64)
    case failed(generation: UInt64, message: String)
    case writeCompleted(generation: UInt64, writeID: UInt64)
    case timerFired(generation: UInt64, timerID: UInt64)

    private enum CodingKeys: String, CodingKey {
        case type, limits, bytes, generation, host, port, message
        case writeID = "writeId"
        case timerID = "timerId"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .start(let limits):
            try container.encode("start", forKey: .type)
            try container.encode(limits, forKey: .limits)
        case .send(let bytes):
            try container.encode("send", forKey: .type)
            try container.encode(bytes, forKey: .bytes)
        case .stop:
            try container.encode("stop", forKey: .type)
        case .finishSendingAndStop:
            try container.encode("finishSendingAndStop", forKey: .type)
        case .endpointResolved(let generation, let host, let port):
            try container.encode("endpointResolved", forKey: .type)
            try container.encode(generation, forKey: .generation)
            try container.encode(host, forKey: .host)
            try container.encode(port, forKey: .port)
        case .connectionReady(let generation):
            try container.encode("connectionReady", forKey: .type)
            try container.encode(generation, forKey: .generation)
        case .dataReceived(let generation):
            try container.encode("dataReceived", forKey: .type)
            try container.encode(generation, forKey: .generation)
        case .peerClosed(let generation):
            try container.encode("peerClosed", forKey: .type)
            try container.encode(generation, forKey: .generation)
        case .failed(let generation, let message):
            try container.encode("failed", forKey: .type)
            try container.encode(generation, forKey: .generation)
            try container.encode(message, forKey: .message)
        case .writeCompleted(let generation, let writeID):
            try container.encode("writeCompleted", forKey: .type)
            try container.encode(generation, forKey: .generation)
            try container.encode(writeID, forKey: .writeID)
        case .timerFired(let generation, let timerID):
            try container.encode("timerFired", forKey: .type)
            try container.encode(generation, forKey: .generation)
            try container.encode(timerID, forKey: .timerID)
        }
    }
}

/// Work the platform performs, in order, after a step.
enum DebugTransportEffect: Decodable, Equatable, Sendable {
    case discoverEndpoint
    case armTimer(timerID: UInt64, purpose: DebugTransportTimerPurpose, afterMilliseconds: Int)
    case cancelTimer(timerID: UInt64)
    case connect(host: String, port: UInt16)
    /// Send the oldest queued frame, which is `bytes` long.
    case write(writeID: UInt64, bytes: Int)
    case deliverData
    case close
    case reportFailure(reason: DebugTransportFailureReason, message: String?)
    case notifyTermination(exitCode: Int)

    private enum CodingKeys: String, CodingKey {
        case kind, purpose, host, port, bytes, reason, message, exitCode, afterMilliseconds
        case timerID = "timerId"
        case writeID = "writeId"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "discoverEndpoint":
            self = .discoverEndpoint
        case "armTimer":
            self = .armTimer(
                timerID: try container.decode(UInt64.self, forKey: .timerID),
                purpose: try container.decode(DebugTransportTimerPurpose.self, forKey: .purpose),
                afterMilliseconds: try container.decode(Int.self, forKey: .afterMilliseconds)
            )
        case "cancelTimer":
            self = .cancelTimer(timerID: try container.decode(UInt64.self, forKey: .timerID))
        case "connect":
            self = .connect(
                host: try container.decode(String.self, forKey: .host),
                port: try container.decode(UInt16.self, forKey: .port)
            )
        case "write":
            self = .write(
                writeID: try container.decode(UInt64.self, forKey: .writeID),
                bytes: try container.decode(Int.self, forKey: .bytes)
            )
        case "deliverData":
            self = .deliverData
        case "close":
            self = .close
        case "reportFailure":
            self = .reportFailure(
                reason: try container.decode(DebugTransportFailureReason.self, forKey: .reason),
                message: try container.decodeIfPresent(String.self, forKey: .message)
            )
        case "notifyTermination":
            self = .notifyTermination(exitCode: try container.decode(Int.self, forKey: .exitCode))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container,
                debugDescription: "Unknown debug transport effect \(kind)"
            )
        }
    }
}

/// Core's answer to one event.
struct DebugTransportStep: Decodable, Equatable, Sendable {
    /// Generation after the step; callbacks of the work it starts must carry it.
    let generation: UInt64
    let phase: DebugTransportPhase
    let outcome: DebugTransportOutcome
    let effects: [DebugTransportEffect]
}

private struct DebugTransportPolicyPayload: Encodable {}

private struct DebugTransportEventPayload: Encodable {
    let transportID: String
    let event: DebugTransportEvent

    private enum CodingKeys: String, CodingKey {
        case transportID = "transportId"
        case event
    }
}

private struct DebugTransportReleasePayload: Encodable {
    let transportID: String

    private enum CodingKeys: String, CodingKey {
        case transportID = "transportId"
    }
}

private struct DebugTransportReleaseResult: Decodable {
    let released: Bool
}

extension RustCoreBridge: DebugTransportLifecycleCore {
    func debugTransportPolicy() throws -> DebugTransportPolicy {
        try executeResult(command: "debug.transport.policy", payload: DebugTransportPolicyPayload()).get()
    }

    func handleDebugTransportEvent(
        transportID: String,
        event: DebugTransportEvent
    ) throws -> DebugTransportStep {
        try executeResult(
            command: "debug.transport.handle",
            payload: DebugTransportEventPayload(transportID: transportID, event: event)
        ).get()
    }

    func releaseDebugTransport(transportID: String) throws {
        let _: DebugTransportReleaseResult = try executeResult(
            command: "debug.transport.release",
            payload: DebugTransportReleasePayload(transportID: transportID)
        ).get()
    }
}
