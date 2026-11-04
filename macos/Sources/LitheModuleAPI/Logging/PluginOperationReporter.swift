import Foundation

// A declarative contribution has no plugin process to call `lithe/log`, so the
// host records its attempts on the plugin's behalf. Every contribution uses the
// same types: an attempt begins where the host starts the work, moves through
// stages, and ends exactly once. Core's contribution table maps the operation
// and the failure stage to the event, channel and `host.*` code; the host sends
// no message text and never maps codes itself.

/// The point at which a declarative contribution attempt failed.
public enum PluginOperationStage: String, Encodable, Sendable, Equatable {
    /// The declaration could not be turned into a command.
    case plan
    /// The declared executable or tool could not be found or prepared.
    case resolve
    /// The process could not be started.
    case launch
    /// The process started but its protocol handshake failed.
    case initialize
    /// The host's deadline elapsed.
    case timeout
    /// The process exited early, or exited with a failure status.
    case exit
    /// The command's output could not be read or decoded.
    case decode
}

/// A contribution in Core's contribution table, spelled as in the plugin
/// contract. Add a constant only together with the row in Core's table.
public struct PluginOperationKind: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let languageServerStart = Self(rawValue: "languageServer/start")
    public static let debugAdapterStart = Self(rawValue: "debugAdapter/start")
    public static let buildModel = Self(rawValue: "lithe/build/model")
    public static let buildDependencies = Self(rawValue: "lithe/build/dependencies")
}

/// The payload of `diagnostics.recordPluginOperation`.
public struct PluginOperationObservation: Encodable, Sendable, Equatable {
    public let pluginId: String
    public let operation: String
    public let outcome: String
    /// Present exactly when the attempt failed.
    public let stage: PluginOperationStage?
    public let durationMs: UInt64
    public let operationId: String

    public init(
        pluginID: String, operation: PluginOperationKind, failure: PluginOperationStage?,
        durationMs: UInt64, operationID: String
    ) {
        pluginId = pluginID
        self.operation = operation.rawValue
        outcome = failure == nil ? "finished" : "failed"
        stage = failure
        self.durationMs = durationMs
        operationId = operationID
    }
}

/// An attempt passed to Core with the request that starts the process. Core
/// then records its result, adding its own time to `elapsedMs`.
public struct PluginOperationHandoff: Encodable, Sendable, Equatable {
    /// Named here because a plugin API 1 server starts with no plugin identity.
    public let pluginId: String
    public let operationId: String
    public let elapsedMs: UInt64
}

/// Begins declarative contribution attempts and delivers their results.
/// `disabled` records nothing and hands nothing off.
public struct PluginOperationReporter: Sendable {
    public typealias Record = @MainActor @Sendable (PluginOperationObservation) -> Void
    public typealias Clock = @MainActor @Sendable () -> UInt64

    fileprivate let record: Record?
    fileprivate let clock: Clock

    public static let disabled = PluginOperationReporter(recording: nil, clock: { 0 })

    /// `clock` returns monotonic milliseconds; durations never use wall-clock time.
    public init(record: @escaping Record, clock: @escaping Clock = { PluginOperationReporter.uptimeMilliseconds() }) {
        self.init(recording: record, clock: clock)
    }

    private init(recording: Record?, clock: @escaping Clock) {
        record = recording
        self.clock = clock
    }

    public static func uptimeMilliseconds() -> UInt64 { DispatchTime.now().uptimeNanoseconds / 1_000_000 }

    /// Starts timing one attempt. `stage` is where a failure is attributed until
    /// the attempt advances.
    @MainActor
    public func begin(
        pluginID: String, operation: PluginOperationKind, at stage: PluginOperationStage,
        operationID: String = UUID().uuidString
    ) -> PluginOperationAttempt {
        PluginOperationAttempt(
            reporter: self, pluginID: pluginID, operation: operation, stage: stage, operationID: operationID
        )
    }
}

/// One attempt of one declarative contribution. The first terminal call wins
/// and later ones do nothing, so each failure path may end the attempt without
/// knowing whether another path already did. Cancellation records nothing.
@MainActor
public final class PluginOperationAttempt {
    public let pluginID: String
    public let operation: PluginOperationKind
    public let operationID: String
    /// Where a failure without an explicit stage is attributed.
    public private(set) var stage: PluginOperationStage
    public private(set) var isEnded = false
    private let reporter: PluginOperationReporter
    private let started: UInt64

    fileprivate init(
        reporter: PluginOperationReporter, pluginID: String, operation: PluginOperationKind,
        stage: PluginOperationStage, operationID: String
    ) {
        self.reporter = reporter
        self.pluginID = pluginID
        self.operation = operation
        self.stage = stage
        self.operationID = operationID
        started = reporter.clock()
    }

    public var elapsedMilliseconds: UInt64 {
        let now = reporter.clock()
        return now >= started ? now - started : 0
    }

    public func advance(to stage: PluginOperationStage) {
        guard !isEnded else { return }
        self.stage = stage
    }

    public func succeed() { end(failure: nil) }

    /// Fails at `stage`, or at the current stage when it is nil.
    public func fail(_ stage: PluginOperationStage? = nil) { end(failure: stage ?? self.stage) }

    /// Ends the attempt for a thrown error: cancellation records nothing,
    /// any other error fails at the current stage.
    public func end(throwing error: any Error) {
        if error is CancellationError || Task.isCancelled { cancel() } else { fail() }
    }

    public func cancel() { isEnded = true }

    /// Ends the attempt here and returns it for Core to finish; nil when it
    /// already ended or nothing records it.
    public func handOff() -> PluginOperationHandoff? {
        guard !isEnded else { return nil }
        isEnded = true
        guard reporter.record != nil else { return nil }
        return PluginOperationHandoff(pluginId: pluginID, operationId: operationID, elapsedMs: elapsedMilliseconds)
    }

    private func end(failure: PluginOperationStage?) {
        guard !isEnded else { return }
        isEnded = true
        reporter.record?(PluginOperationObservation(
            pluginID: pluginID, operation: operation, failure: failure,
            durationMs: elapsedMilliseconds, operationID: operationID
        ))
    }
}
