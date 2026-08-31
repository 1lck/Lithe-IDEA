import Foundation
import Network

enum MacJavaTestResultListenerState {
    case ready(port: UInt16)
    case failed(message: String)
    case cancelled
}

protocol MacJavaTestResultListening: AnyObject {
    var onStateChange: ((MacJavaTestResultListenerState) -> Void)? { get set }
    var onConnection: ((NWConnection) -> Void)? { get set }

    func start(queue: DispatchQueue)
    func cancel()
}

final class MacJavaTestResultNetworkListener: MacJavaTestResultListening {
    var onStateChange: ((MacJavaTestResultListenerState) -> Void)?
    var onConnection: ((NWConnection) -> Void)?

    private let listener: NWListener

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: .any
        )
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let port = listener.port?.rawValue else {
                    onStateChange?(.failed(message: "No listening port was assigned."))
                    return
                }
                onStateChange?(.ready(port: port))
            case .failed(let error):
                onStateChange?(.failed(message: error.localizedDescription))
            case .cancelled:
                onStateChange?(.cancelled)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.onConnection?(connection)
        }
    }

    func start(queue: DispatchQueue) {
        listener.start(queue: queue)
    }

    func cancel() {
        listener.cancel()
    }
}

/// Owns the loopback listener used by one Java test debug launch. The listener
/// is created on demand, accepts one runner connection, drains it, and releases
/// all native resources when the runner exits or the launch is cancelled.
@MainActor
final class MacJavaTestResultServer: JavaTestResultServing {
    enum ServerError: LocalizedError {
        case startupFailed(String)
        case startupTimedOut

        var errorDescription: String? {
            switch self {
            case .startupFailed(let message):
                "Could not start the Java test result listener: \(message)"
            case .startupTimedOut:
                "The Java test result listener did not become ready in time."
            }
        }
    }

    private let queue = DispatchQueue(label: "app.lithe.debug.java-test-results")
    private let startupTimeout: Duration
    private let listenerFactory: () throws -> any MacJavaTestResultListening
    private var listener: (any MacJavaTestResultListening)?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var startupContinuation: CheckedContinuation<UInt16, Error>?
    private var startupDeadlineTask: Task<Void, Never>?
    private var generation = UUID()

    init(
        startupTimeout: Duration = .seconds(5),
        listenerFactory: @escaping () throws -> any MacJavaTestResultListening = {
            try MacJavaTestResultNetworkListener()
        }
    ) {
        self.startupTimeout = startupTimeout
        self.listenerFactory = listenerFactory
    }

    func start() async throws -> UInt16 {
        stop()
        let listener: any MacJavaTestResultListening
        do {
            listener = try listenerFactory()
        } catch {
            throw ServerError.startupFailed(error.localizedDescription)
        }
        self.listener = listener
        generation = UUID()
        let currentGeneration = generation
        listener.onStateChange = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.consume(state, generation: currentGeneration)
            }
        }
        listener.onConnection = { [weak self] connection in
            Task { @MainActor [weak self] in
                self?.accept(connection, generation: currentGeneration)
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startupContinuation = continuation
                listener.start(queue: queue)
                startDeadline(generation: currentGeneration)
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.stop() }
        }
    }

    func stop() {
        generation = UUID()
        startupDeadlineTask?.cancel()
        startupDeadlineTask = nil
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections = [:]
        startupContinuation?.resume(throwing: CancellationError())
        startupContinuation = nil
    }

    private func startDeadline(generation: UUID) {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: startupTimeout)
        startupDeadlineTask = Task { [weak self] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.generation == generation else { return }
                self.failStartup(ServerError.startupTimedOut)
            }
        }
    }

    private func consume(_ state: MacJavaTestResultListenerState, generation: UUID) {
        guard self.generation == generation else { return }
        switch state {
        case .ready(let port):
            startupDeadlineTask?.cancel()
            startupDeadlineTask = nil
            startupContinuation?.resume(returning: port)
            startupContinuation = nil
        case .failed(let message):
            failStartup(ServerError.startupFailed(message))
        case .cancelled:
            break
        }
    }

    private func failStartup(_ error: Error) {
        startupDeadlineTask?.cancel()
        startupDeadlineTask = nil
        listener?.cancel()
        listener = nil
        startupContinuation?.resume(throwing: error)
        startupContinuation = nil
    }

    private func accept(_ connection: NWConnection, generation: UUID) {
        guard self.generation == generation else {
            connection.cancel()
            return
        }
        // One Java test process owns the result channel. Stop accepting new
        // peers after it connects, but keep the accepted socket alive.
        listener?.cancel()
        listener = nil
        let identifier = ObjectIdentifier(connection)
        connections[identifier] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            switch state {
            case .failed, .cancelled:
                Task { @MainActor [weak self] in self?.remove(connection) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveNext(from: connection)
    }

    private func receiveNext(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) {
            [weak self, weak connection] _, _, isComplete, error in
            guard let self, let connection else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if error != nil || isComplete {
                    self.remove(connection)
                } else {
                    self.receiveNext(from: connection)
                }
            }
        }
    }

    private func remove(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = nil
        connection.cancel()
    }
}
