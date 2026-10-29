import LitheModuleAPI
import Foundation
import LitheCoreContracts
import Network

@MainActor
protocol DebugAdapterSocketConnection: AnyObject {
    var onReady: (() -> Void)? { get set }
    var onData: ((Data) -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }
    var onComplete: (() -> Void)? { get set }
    func start()
    func send(_ data: Data, completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void)
    func stop()
}

/// NWError renders as an opaque "Network.NWError error 1"; carry the OS reason users act on.
struct DebugAdapterConnectError: LocalizedError {
    let reason: String

    init(_ error: NWError) {
        if case .posix(let code) = error { reason = String(cString: strerror(code.rawValue)) }
        else { reason = error.localizedDescription }
    }

    var errorDescription: String? {
        L10n.string("Could not connect to the Debug Adapter: \(reason)")
    }
}

@MainActor
final class NetworkDebugAdapterSocketConnection: DebugAdapterSocketConnection {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "app.lithe.debug.adapter-tcp")
    var onReady: (() -> Void)?
    var onData: ((Data) -> Void)?
    var onFailure: ((Error) -> Void)?
    var onComplete: (() -> Void)?
    private var stopped = false
    private var reachedReady = false

    init(host: String, port: UInt16) {
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                switch state {
                case .ready:
                    self.reachedReady = true
                    self.onReady?()
                case .waiting(let error) where Self.isDefinitive(error):
                    // Network.framework parks a refused or unreachable connect in
                    // .waiting and retries on path changes. A debugger gains
                    // nothing from silent retries, so report the cause now. Other
                    // causes (for example a pending Local Network prompt) keep
                    // waiting until the transport's connect deadline.
                    self.fail(error)
                case .failed(let error): self.fail(error)
                default: break
                }
            }
        }
    }

    deinit { connection.cancel() }

    private static func isDefinitive(_ error: NWError) -> Bool {
        guard case .posix(let code) = error else { return false }
        return [.ECONNREFUSED, .EHOSTUNREACH, .ENETUNREACH].contains(code)
    }

    private func fail(_ error: NWError) {
        // Only a failed connect is a "could not connect"; later I/O errors stay raw.
        onFailure?(reachedReady ? error : DebugAdapterConnectError(error))
    }

    func start() {
        guard !stopped else { return }
        connection.start(queue: queue)
        receiveNext()
    }

    func send(_ data: Data, completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void) {
        guard !stopped else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                if let error { completion(.failure(error)) }
                else { completion(.success(())) }
            }
        })
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        connection.stateUpdateHandler = nil
        onReady = nil
        onData = nil
        onFailure = nil
        onComplete = nil
        connection.cancel()
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                if let data, !data.isEmpty { self.onData?(data) }
                guard !self.stopped else { return }
                if let error {
                    self.onFailure?(error)
                } else if complete {
                    self.onComplete?()
                } else {
                    self.receiveNext()
                }
            }
        }
    }
}
