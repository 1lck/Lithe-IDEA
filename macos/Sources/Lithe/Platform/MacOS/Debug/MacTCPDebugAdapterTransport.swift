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

/// One owned TCP stream. DAP framing, requests and their deadlines stay in Core.
/// A startup deadline covers endpoint discovery and connection establishment;
/// write deadlines cover a stalled peer, never the duration of a debug session.
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

    struct Limits {
        var startupMilliseconds = 10_000
        var writeMilliseconds = 10_000
        var bufferedBytes = 8 * 1_024 * 1_024
        var bufferedWrites = 1_024
        var drainMilliseconds = 1_000
    }

    typealias EndpointResolver = @MainActor (URL) async throws -> DebugAdapterEndpoint
    private let resolveEndpoint: EndpointResolver
    private let makeSocket: @MainActor (DebugAdapterEndpoint) throws -> any DebugAdapterSocketConnection
    private let scheduler: any DebugOperationDeadlineScheduling
    private let limits: Limits
    private var startupTask: Task<Void, Never>?
    private var startupDeadline: (any DebugOperationDeadline)?
    private var writeDeadline: (any DebugOperationDeadline)?
    private var drainDeadline: (any DebugOperationDeadline)?
    private var socket: (any DebugAdapterSocketConnection)?
    private var writes: [Data] = []
    private var bufferedBytes = 0
    private var activeWrite: UUID?
    private var generation = UUID()
    private var ready = false
    private var running = false
    private var draining = false
    var isRunning: Bool { running && !draining }

    var onData: ((Data) -> Void)?
    var onErrorOutput: ((Data) -> Void)?
    var onTermination: ((Int) -> Void)?

    init(
        endpointResolver: @escaping EndpointResolver,
        connectionProvider: (any DebugAdapterConnectionProviding)? = nil,
        deadlineScheduler: (any DebugOperationDeadlineScheduling)? = nil,
        limits: Limits = Limits(),
        socketFactory: (@MainActor (DebugAdapterEndpoint) throws -> any DebugAdapterSocketConnection)? = nil
    ) {
        precondition(limits.startupMilliseconds > 0 && limits.writeMilliseconds > 0)
        precondition(limits.bufferedBytes > 0 && limits.bufferedWrites > 0)
        precondition(limits.drainMilliseconds > 0)
        resolveEndpoint = endpointResolver
        let provider = connectionProvider ?? DirectDebugAdapterConnectionProvider()
        makeSocket = socketFactory ?? { try provider.makeConnection(to: $0) }
        scheduler = deadlineScheduler ?? MacDebugOperationDeadlineScheduler()
        self.limits = limits
    }

    isolated deinit { cleanUp() }

    func start(rootURL: URL) throws {
        if draining { cleanUp() }
        guard !isRunning else { return }
        generation = UUID()
        let token = generation
        running = true
        startupDeadline = scheduler.schedule(afterMilliseconds: limits.startupMilliseconds) { [weak self] in
            guard let self, self.isCurrent(token), !self.ready else { return }
            self.finish(error: TransportError.startupTimedOut)
        }
        let resolveEndpoint = resolveEndpoint
        startupTask = Task { @MainActor [weak self] in
            do {
                let endpoint = try await resolveEndpoint(rootURL.standardizedFileURL)
                try Task.checkCancellation()
                guard let self, self.isCurrent(token) else { return }
                // User endpoints are validated by Core before reaching this layer.
                // Keep the native numeric conversion safe for every provider.
                guard !endpoint.host.isEmpty, (1...65_535).contains(endpoint.port) else {
                    throw TransportError.invalidEndpoint
                }
                try self.connect(endpoint, token: token)
            } catch {
                guard let self, self.isCurrent(token) else { return }
                self.finish(error: error)
            }
        }
    }

    func send(_ data: Data) throws {
        guard isRunning else { throw TransportError.stopped }
        guard !data.isEmpty else { return }
        guard writes.count < limits.bufferedWrites,
              data.count <= limits.bufferedBytes - bufferedBytes else {
            finish(error: TransportError.bufferLimit)
            throw TransportError.bufferLimit
        }
        writes.append(data)
        bufferedBytes += data.count
        sendNext(token: generation)
    }

    func stop() { cleanUp() }

    func finishSendingAndStop() {
        guard running, !draining else { return }
        guard ready, !writes.isEmpty else { cleanUp(); return }
        draining = true
        let token = generation
        // The session manager can release its session immediately. The bounded
        // drain owns itself until the queued disconnect is accepted or expires.
        drainDeadline = scheduler.schedule(afterMilliseconds: limits.drainMilliseconds) { [self] in
            guard isCurrent(token), draining else { return }
            cleanUp()
        }
        sendNext(token: generation)
    }

    private func isCurrent(_ token: UUID) -> Bool { running && generation == token }

    private func connect(_ endpoint: DebugAdapterEndpoint, token: UUID) throws {
        let connection = try makeSocket(endpoint)
        socket = connection
        connection.onReady = { [weak self] in
            guard let self, self.isCurrent(token), !self.ready else { return }
            self.ready = true
            self.startupDeadline?.cancel()
            self.startupDeadline = nil
            self.startupTask = nil
            self.sendNext(token: token)
        }
        connection.onData = { [weak self] data in
            guard let self, self.isCurrent(token), !self.draining else { return }
            self.onData?(data)
        }
        connection.onFailure = { [weak self] error in
            guard let self, self.isCurrent(token) else { return }
            self.finish(error: error)
        }
        connection.onComplete = { [weak self] in
            guard let self, self.isCurrent(token) else { return }
            self.finish(error: nil)
        }
        connection.start()
    }

    private func sendNext(token: UUID) {
        guard isCurrent(token), ready, activeWrite == nil,
              let data = writes.first, let socket else { return }
        let writeID = UUID()
        activeWrite = writeID
        writeDeadline = scheduler.schedule(afterMilliseconds: limits.writeMilliseconds) { [weak self] in
            guard let self, self.isCurrent(token), self.activeWrite == writeID else { return }
            self.finish(error: TransportError.writeTimedOut)
        }
        socket.send(data) { [weak self] result in
            guard let self, self.isCurrent(token), self.activeWrite == writeID else { return }
            self.writeDeadline?.cancel()
            self.writeDeadline = nil
            self.activeWrite = nil
            switch result {
            case .success:
                self.bufferedBytes -= self.writes.removeFirst().count
                if self.draining, self.writes.isEmpty { self.cleanUp(); return }
                // Do not recurse if a provider completes writes synchronously.
                Task { @MainActor [weak self] in self?.sendNext(token: token) }
            case .failure(let error): self.finish(error: error)
            }
        }
    }

    private func finish(error: Error?) {
        guard running else { return }
        if draining { cleanUp(); return }
        // Invalidate before calling native stop or client callbacks: both can reenter.
        cleanUp()
        let finishedGeneration = generation
        if let error { onErrorOutput?(Data((error.localizedDescription + "\n").utf8)) }
        // An error observer can stop or restart the owner synchronously. Never
        // deliver the old termination into that replacement lifecycle.
        guard generation == finishedGeneration else { return }
        onTermination?(error == nil ? 0 : 1)
    }

    private func cleanUp() {
        generation = UUID()
        running = false
        draining = false
        drainDeadline?.cancel()
        drainDeadline = nil
        startupDeadline?.cancel()
        startupDeadline = nil
        writeDeadline?.cancel()
        writeDeadline = nil
        startupTask?.cancel()
        startupTask = nil
        let connection = socket
        socket = nil
        connection?.onReady = nil
        connection?.onData = nil
        connection?.onFailure = nil
        connection?.onComplete = nil
        connection?.stop()
        writes = []
        bufferedBytes = 0
        activeWrite = nil
        ready = false
    }
}
