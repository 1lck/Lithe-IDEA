import Foundation
import LitheCoreContracts

/// Connects the macOS product to the Java Debug Server hosted inside JDT LS.
/// JDT LS activation stays in the language module and DAP state stays in Core;
/// this adapter owns only asynchronous port discovery and the native TCP socket.
@MainActor
final class MacJavaDebugAdapterTransport: DebugAdapterTransport {
    enum TransportError: LocalizedError {
        case languageIntelligenceUnavailable
        case connectionFailed(String)
        case stopped

        var errorDescription: String? {
            switch self {
            case .languageIntelligenceUnavailable:
                return "The Java language service is unavailable."
            case .connectionFailed(let message):
                return "Could not connect to the Java Debug Server: \(message)"
            case .stopped:
                return "The Java Debug Server connection is stopped."
            }
        }
    }

    typealias PortResolver = @MainActor (URL) async throws -> UInt16

    private let portResolver: PortResolver
    private let socketFactory: @MainActor (String, UInt16) -> any DebugAdapterSocketConnection
    private var startupTask: Task<Void, Never>?
    private var socket: (any DebugAdapterSocketConnection)?
    private var pendingWrites: [Data] = []
    private var isSocketReady = false
    private var generation = UUID()
    private(set) var isRunning = false

    var onData: ((Data) -> Void)?
    var onErrorOutput: ((Data) -> Void)?
    var onTermination: ((Int) -> Void)?

    init(
        portResolver: @escaping PortResolver,
        socketFactory: @escaping @MainActor (String, UInt16) -> any DebugAdapterSocketConnection = {
            NetworkDebugAdapterSocketConnection(host: $0, port: $1)
        }
    ) {
        self.portResolver = portResolver
        self.socketFactory = socketFactory
    }

    func start(rootURL: URL) throws {
        guard !isRunning else { return }
        isRunning = true
        isSocketReady = false
        pendingWrites = []
        generation = UUID()
        let currentGeneration = generation
        let portResolver = portResolver
        startupTask = Task { @MainActor [weak self] in
            do {
                let port = try await portResolver(rootURL.standardizedFileURL)
                try Task.checkCancellation()
                guard let self else { return }
                guard isRunning, generation == currentGeneration else { return }
                connect(port: port, generation: currentGeneration)
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                guard isRunning, generation == currentGeneration else { return }
                fail(error)
            }
        }
    }

    func send(_ data: Data) throws {
        guard isRunning else { throw TransportError.stopped }
        guard isSocketReady, let socket else {
            pendingWrites.append(data)
            return
        }
        socket.send(data)
    }

    func stop() {
        generation = UUID()
        startupTask?.cancel()
        startupTask = nil
        socket?.stop()
        socket = nil
        pendingWrites = []
        isSocketReady = false
        isRunning = false
    }

    private func connect(port: UInt16, generation: UUID) {
        let socket = socketFactory("127.0.0.1", port)
        self.socket = socket
        socket.onReady = { [weak self] in
            guard let self, self.generation == generation else { return }
            self.socketDidBecomeReady()
        }
        socket.onData = { [weak self] data in
            guard let self, self.generation == generation else { return }
            self.onData?(data)
        }
        socket.onFailure = { [weak self] error in
            guard let self, self.generation == generation else { return }
            self.fail(TransportError.connectionFailed(error.localizedDescription))
        }
        socket.onComplete = { [weak self] in
            guard let self, self.generation == generation else { return }
            self.terminate(exitCode: 0)
        }
        socket.start()
    }

    private func socketDidBecomeReady() {
        guard let socket, isRunning else { return }
        isSocketReady = true
        let writes = pendingWrites
        pendingWrites = []
        writes.forEach(socket.send)
    }

    private func fail(_ error: Error) {
        onErrorOutput?(Data((error.localizedDescription + "\n").utf8))
        terminate(exitCode: 1)
    }

    private func terminate(exitCode: Int) {
        guard isRunning else { return }
        startupTask?.cancel()
        startupTask = nil
        socket?.stop()
        socket = nil
        pendingWrites = []
        isSocketReady = false
        isRunning = false
        onTermination?(exitCode)
    }
}
