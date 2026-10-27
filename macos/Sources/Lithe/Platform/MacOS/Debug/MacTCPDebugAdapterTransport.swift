import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Establishes a byte stream, not a DAP session. Future network routes implement
/// this seam and return an owned, cancellable connection; direct TCP is the only
/// implementation today. Credentials and tunnel processes do not belong here.
@MainActor
protocol DebugAdapterConnectionProviding {
    func makeConnection(to endpoint: DebugAdapterEndpoint) throws -> any DebugAdapterSocketConnection
}

@MainActor
struct DirectDebugAdapterConnectionProvider: DebugAdapterConnectionProviding {
    func makeConnection(to endpoint: DebugAdapterEndpoint) throws -> any DebugAdapterSocketConnection {
        NetworkDebugAdapterSocketConnection(host: endpoint.host, port: UInt16(endpoint.port))
    }
}

/// One owned TCP stream. The lifecycle rules live in Rust Core: this adapter
/// reports what the socket, the resolver and the system timers observed, then runs
/// the effects Core returns. It owns the socket, the pending frames' bytes, the
/// timer handles and nothing that decides when to give up. DAP framing, requests
/// and their deadlines stay in Core as well.
// Note: .agents/notes/implemented/architecture/2026-10-27-debug-tcp-transport-lifecycle.md
@MainActor
final class MacTCPDebugAdapterTransport: DebugAdapterDrainingTransport {
    enum TransportError: LocalizedError, Equatable {
        case stopped, startupTimedOut, writeTimedOut, bufferLimit, invalidEndpoint, connectionDeclined

        var errorDescription: String? {
            switch self {
            case .stopped: return L10n.string("The debug adapter connection is stopped.")
            case .startupTimedOut: return L10n.string("The debug adapter connection timed out.")
            case .writeTimedOut: return L10n.string("The debug adapter did not accept outgoing data in time.")
            case .bufferLimit: return L10n.string("The debug adapter outgoing buffer is full.")
            case .invalidEndpoint: return L10n.string("Enter a valid debug adapter host and a port between 1 and 65535.")
            case .connectionDeclined: return L10n.string("The debug adapter connection was not approved.")
            }
        }
    }

    /// Per-transport overrides of Core's deadline and queue defaults.
    typealias Limits = DebugTransportLimitOverrides

    typealias EndpointResolver = @MainActor (URL) async throws -> DebugAdapterEndpoint
    private let resolveEndpoint: EndpointResolver
    private let makeSocket: @MainActor (DebugAdapterEndpoint) throws -> any DebugAdapterSocketConnection
    private let scheduler: any DebugOperationDeadlineScheduling
    private let core: any DebugTransportLifecycleCore
    private let limits: Limits
    private var transportID = UUID().uuidString
    private var rootURL: URL?
    private var startupTask: Task<Void, Never>?
    private var socket: (any DebugAdapterSocketConnection)?
    /// Frames Core has budgeted but not yet told us to write. Core never sees the bytes.
    private var writes: [Data] = []
    /// System timers Core armed, keyed by Core's timer id.
    private var timers: [UInt64: any DebugOperationDeadline] = [:]
    /// Mirrors of Core's last answer; Core stays the authority.
    private var generation: UInt64 = 0
    private var phase = DebugTransportPhase.stopped
    /// Nonzero while effects run, so an inline callback does not recurse into Core.
    private var effectDepth = 0
    var isRunning: Bool {
        switch phase {
        case .discovering, .connecting, .ready: return true
        case .stopped, .draining: return false
        }
    }

    var onData: ((Data) -> Void)?
    var onErrorOutput: ((Data) -> Void)?
    var onTermination: ((Int) -> Void)?

    init(
        endpointResolver: @escaping EndpointResolver,
        core: any DebugTransportLifecycleCore,
        connectionProvider: (any DebugAdapterConnectionProviding)? = nil,
        deadlineScheduler: (any DebugOperationDeadlineScheduling)? = nil,
        limits: Limits = Limits(),
        socketFactory: (@MainActor (DebugAdapterEndpoint) throws -> any DebugAdapterSocketConnection)? = nil
    ) {
        resolveEndpoint = endpointResolver
        let provider = connectionProvider ?? DirectDebugAdapterConnectionProvider()
        makeSocket = socketFactory ?? { try provider.makeConnection(to: $0) }
        scheduler = deadlineScheduler ?? MacDebugOperationDeadlineScheduler()
        self.core = core
        self.limits = limits
    }

    isolated deinit {
        // Core's state for this transport goes with it; no event is needed.
        closeConnection()
        try? core.releaseDebugTransport(transportID: transportID)
    }

    func start(rootURL: URL) throws {
        let step = try core.handleDebugTransportEvent(transportID: transportID, event: .start(limits))
        if step.outcome == .applied { self.rootURL = rootURL.standardizedFileURL }
        apply(step)
    }

    func send(_ data: Data) throws {
        // The effect that writes this frame can arrive in the same step.
        if !data.isEmpty { writes.append(data) }
        let step: DebugTransportStep
        do {
            step = try core.handleDebugTransportEvent(transportID: transportID, event: .send(bytes: data.count))
        } catch {
            if !data.isEmpty { writes.removeLast() }
            abort(after: error)
            throw error
        }
        switch step.outcome {
        case .rejectedNotRunning:
            if !data.isEmpty { writes.removeLast() }
            throw TransportError.stopped
        case .rejectedBufferLimit:
            // The step fails the stream, reports it and clears the queue.
            apply(step)
            throw TransportError.bufferLimit
        case .applied, .ignored:
            apply(step)
        }
    }

    func stop() { dispatch(.stop) }

    func finishSendingAndStop() { dispatch(.finishSendingAndStop) }

    /// Reports an event to Core and runs the answer. A Core failure is a bridge
    /// fault, not a lifecycle outcome, so it fails the stream locally.
    private func dispatch(_ event: DebugTransportEvent, inbound: Data? = nil, registrationID: String? = nil) {
        guard registrationID == nil || registrationID == transportID else { return }
        do {
            apply(try core.handleDebugTransportEvent(transportID: transportID, event: event), inbound: inbound)
        } catch {
            abort(after: error)
        }
    }

    private func apply(_ step: DebugTransportStep, inbound: Data? = nil) {
        let registrationID = transportID
        generation = step.generation
        phase = step.phase
        effectDepth += 1
        defer { effectDepth -= 1 }
        for effect in step.effects {
            // A callback or an observer may have stopped or restarted the stream
            // while an earlier effect ran; the rest of this step is stale.
            guard transportID == registrationID, generation == step.generation else { return }
            run(effect, generation: step.generation, inbound: inbound)
        }
    }

    private func run(_ effect: DebugTransportEffect, generation: UInt64, inbound: Data?) {
        switch effect {
        case .discoverEndpoint:
            discoverEndpoint(generation: generation)
        case .armTimer(let timerID, let purpose, let afterMilliseconds):
            armTimer(timerID, purpose: purpose, afterMilliseconds: afterMilliseconds, generation: generation)
        case .cancelTimer(let timerID):
            timers.removeValue(forKey: timerID)?.cancel()
        case .connect(let host, let port):
            connect(DebugAdapterEndpoint(host: host, port: Int(port)), generation: generation)
        case .write(let writeID, let bytes):
            write(writeID, bytes: bytes, generation: generation)
        case .deliverData:
            if let inbound { onData?(inbound) }
        case .close:
            closeConnection()
        case .reportFailure(let reason, let message):
            onErrorOutput?(Data((failureText(reason, message: message) + "\n").utf8))
        case .notifyTermination(let exitCode):
            onTermination?(exitCode)
        }
    }

    private func failureText(_ reason: DebugTransportFailureReason, message: String?) -> String {
        switch reason {
        case .startupTimedOut: return TransportError.startupTimedOut.localizedDescription
        case .writeTimedOut: return TransportError.writeTimedOut.localizedDescription
        case .bufferLimit: return TransportError.bufferLimit.localizedDescription
        case .invalidEndpoint: return TransportError.invalidEndpoint.localizedDescription
        case .host: return message ?? ""
        }
    }

    private func discoverEndpoint(generation: UInt64) {
        guard let rootURL else { return }
        let resolveEndpoint = resolveEndpoint
        let registrationID = transportID
        startupTask = Task { @MainActor [weak self] in
            do {
                let endpoint = try await resolveEndpoint(rootURL)
                try Task.checkCancellation()
                self?.dispatch(.endpointResolved(generation: generation, host: endpoint.host, port: endpoint.port), registrationID: registrationID)
            } catch {
                guard !Task.isCancelled else { return }
                self?.dispatch(.failed(generation: generation, message: error.localizedDescription), registrationID: registrationID)
            }
        }
    }

    private func armTimer(
        _ timerID: UInt64,
        purpose: DebugTransportTimerPurpose,
        afterMilliseconds: Int,
        generation: UInt64
    ) {
        // The bounded drain owns the transport: the session manager can release it
        // right after asking to finish, and the queued disconnect still gets its window.
        let registrationID = transportID
        let fire: @MainActor () -> Void = purpose == .drain
            ? { [self] in timerFired(timerID, generation: generation, registrationID: registrationID) }
            : { [weak self] in self?.timerFired(timerID, generation: generation, registrationID: registrationID) }
        timers[timerID] = scheduler.schedule(afterMilliseconds: afterMilliseconds, action: fire)
    }

    private func timerFired(_ timerID: UInt64, generation: UInt64, registrationID: String) {
        guard registrationID == transportID, self.generation == generation else { return }
        // Core takes the fired timer's slot itself; only the handle is ours to drop.
        // Cancelling a timer that already fired is a no-op that releases whatever
        // the handle still retains, such as the drain timer's strong owner.
        let handle = timers.removeValue(forKey: timerID)
        dispatch(.timerFired(generation: generation, timerID: timerID))
        handle?.cancel()
    }

    private func connect(_ endpoint: DebugAdapterEndpoint, generation: UInt64) {
        startupTask = nil
        let registrationID = transportID
        let connection: any DebugAdapterSocketConnection
        do {
            connection = try makeSocket(endpoint)
        } catch {
            dispatch(.failed(generation: generation, message: error.localizedDescription))
            return
        }
        socket = connection
        connection.onReady = { [weak self] in
            self?.dispatch(.connectionReady(generation: generation), registrationID: registrationID)
        }
        connection.onData = { [weak self] data in
            self?.dispatch(.dataReceived(generation: generation), inbound: data, registrationID: registrationID)
        }
        connection.onFailure = { [weak self] error in
            self?.dispatch(.failed(generation: generation, message: error.localizedDescription), registrationID: registrationID)
        }
        connection.onComplete = { [weak self] in
            self?.dispatch(.peerClosed(generation: generation), registrationID: registrationID)
        }
        connection.start()
    }

    private func write(_ writeID: UInt64, bytes: Int, generation: UInt64) {
        guard let socket, !writes.isEmpty else {
            assertionFailure("Core asked for a write the adapter has no frame or socket for")
            return
        }
        let data = writes.removeFirst()
        let registrationID = transportID
        assert(data.count == bytes, "Core's frame size disagrees with the queued frame")
        socket.send(data) { [weak self] result in
            guard let self else { return }
            let event: DebugTransportEvent
            switch result {
            case .success: event = .writeCompleted(generation: generation, writeID: writeID)
            case .failure(let error): event = .failed(generation: generation, message: error.localizedDescription)
            }
            // A provider may complete inline; never recurse through the queue.
            if effectDepth > 0 {
                Task { @MainActor [weak self] in self?.dispatch(event, registrationID: registrationID) }
            } else {
                dispatch(event, registrationID: registrationID)
            }
        }
    }

    /// Releases the socket, the discovery task, the queued frames and every timer
    /// still armed. Detach the callbacks first: native stop can reenter.
    private func closeConnection() {
        startupTask?.cancel()
        startupTask = nil
        for deadline in timers.values { deadline.cancel() }
        timers.removeAll()
        let connection = socket
        socket = nil
        connection?.onReady = nil
        connection?.onData = nil
        connection?.onFailure = nil
        connection?.onComplete = nil
        connection?.stop()
        writes = []
    }

    /// Core could not be reached. Fall back to a local, silent-to-Core teardown so
    /// the socket and timers do not outlive the failure, then tell the owner once.
    private func abort(after error: Error) {
        let wasRunning = isRunning
        phase = .stopped
        generation &+= 1
        closeConnection()
        try? core.releaseDebugTransport(transportID: transportID)
        // Releasing Core state resets its counters. Use a new registration so
        // old callbacks cannot match the replacement's generation or timer ids.
        transportID = UUID().uuidString
        let registrationID = transportID
        guard wasRunning else { return }
        onErrorOutput?(Data((error.localizedDescription + "\n").utf8))
        guard transportID == registrationID, phase == .stopped else { return }
        onTermination?(1)
    }
}
