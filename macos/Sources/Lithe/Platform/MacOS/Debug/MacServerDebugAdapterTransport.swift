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

@MainActor
final class NetworkDebugAdapterSocketConnection: DebugAdapterSocketConnection {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "app.lithe.debug.adapter-tcp")
    var onReady: (() -> Void)?
    var onData: ((Data) -> Void)?
    var onFailure: ((Error) -> Void)?
    var onComplete: (() -> Void)?
    private var stopped = false

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
                case .ready: self.onReady?()
                case .failed(let error): self.onFailure?(error)
                case .cancelled: break
                default: break
                }
            }
        }
    }

    deinit { connection.cancel() }

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
