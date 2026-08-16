import Foundation
import LitheCoreContracts
import Network

struct ServerDebugAdapterProcessLaunch {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
}

@MainActor
protocol DebugAdapterSocketConnection: AnyObject {
    var onReady: (() -> Void)? { get set }
    var onData: ((Data) -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }
    var onComplete: (() -> Void)? { get set }
    func start()
    func send(_ data: Data)
    func stop()
}

/// Compatibility name for the first TCP adapter implementation and its tests.
typealias DlvSocketConnection = DebugAdapterSocketConnection

@MainActor
private final class NetworkDebugAdapterSocketConnection: DebugAdapterSocketConnection {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "app.lithe.debug.adapter-tcp")
    var onReady: (() -> Void)?
    var onData: ((Data) -> Void)?
    var onFailure: ((Error) -> Void)?
    var onComplete: (() -> Void)?

    init(host: String, port: UInt16) {
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready: self.onReady?()
                case .failed(let error): self.onFailure?(error)
                case .cancelled: break
                default: break
                }
            }
        }
    }

    func start() {
        connection.start(queue: queue)
        receiveNext()
    }

    func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in self?.onFailure?(error) }
        })
    }

    func stop() { connection.cancel() }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let data, !data.isEmpty { self.onData?(data) }
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

/// Reusable transport for adapters that expose DAP on a TCP server started by
/// a child process. Adapter-specific code supplies only process discovery and
/// how to parse its listening-address announcement.
@MainActor
class MacServerDebugAdapterTransport: DebugAdapterTransport, DebugAdapterChildTransportProviding {
    enum TransportError: LocalizedError {
        case launchUnavailable(String)
        case connectionFailed(String)

        var errorDescription: String? {
            switch self {
            case .launchUnavailable(let value): value
            case .connectionFailed(let value): "Could not connect to the Debug Adapter: \(value)"
            }
        }
    }

    typealias Endpoint = (host: String, port: UInt16)
    typealias LaunchResolver = @MainActor (URL) throws -> ServerDebugAdapterProcessLaunch
    typealias EndpointParser = (String) -> Endpoint?

    private let process: any RawProcessSession
    private let launchResolver: LaunchResolver
    private let endpointParser: EndpointParser
    private let socketFactory: @MainActor (String, UInt16) -> any DebugAdapterSocketConnection
    private var socket: (any DebugAdapterSocketConnection)?
    private var pendingWrites: [Data] = []
    private var announcementBuffer = ""
    private var isSocketReady = false
    private var didTerminate = false
    private var activeEndpoint: Endpoint?

    var onData: ((Data) -> Void)?
    var onErrorOutput: ((Data) -> Void)?
    var onTermination: ((Int) -> Void)?

    init(
        process: any RawProcessSession,
        launchResolver: @escaping LaunchResolver,
        endpointParser: @escaping EndpointParser,
        socketFactory: @escaping @MainActor (String, UInt16) -> any DebugAdapterSocketConnection = {
            NetworkDebugAdapterSocketConnection(host: $0, port: $1)
        }
    ) {
        self.process = process
        self.launchResolver = launchResolver
        self.endpointParser = endpointParser
        self.socketFactory = socketFactory
        process.onOutput = { [weak self] data in
            Task { @MainActor [weak self] in self?.consumeAnnouncement(data) }
        }
        process.onError = { [weak self] data in
            Task { @MainActor [weak self] in self?.consumeAnnouncement(data) }
        }
        process.onTermination = { [weak self] code in
            Task { @MainActor [weak self] in self?.terminate(Int(code)) }
        }
    }

    var isRunning: Bool { process.isRunning }

    func start(rootURL: URL) throws {
        guard !process.isRunning else { return }
        didTerminate = false
        isSocketReady = false
        pendingWrites = []
        announcementBuffer = ""
        activeEndpoint = nil
        let launch = try launchResolver(rootURL.standardizedFileURL)
        try process.start(ProcessRequest(
            operationID: UUID().uuidString,
            executablePath: launch.executableURL.path,
            arguments: launch.arguments,
            workingDirectory: rootURL.standardizedFileURL.path,
            environment: launch.environment,
            keepsStandardInputOpen: false
        ))
    }

    func send(_ data: Data) throws {
        guard isSocketReady, let socket else {
            pendingWrites.append(data)
            return
        }
        socket.send(data)
    }

    func stop() {
        socket?.stop()
        socket = nil
        isSocketReady = false
        pendingWrites = []
        activeEndpoint = nil
        process.stop()
    }

    private func consumeAnnouncement(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
        announcementBuffer += text
        onErrorOutput?(data)
        guard socket == nil, let endpoint = endpointParser(announcementBuffer) else { return }
        activeEndpoint = endpoint
        let socket = socketFactory(endpoint.host, endpoint.port)
        self.socket = socket
        socket.onReady = { [weak self] in self?.socketDidBecomeReady() }
        socket.onData = { [weak self] in self?.onData?($0) }
        socket.onFailure = { [weak self] error in
            self?.report(TransportError.connectionFailed(error.localizedDescription))
        }
        socket.onComplete = { [weak self] in self?.terminate(0) }
        socket.start()
    }

    private func socketDidBecomeReady() {
        guard let socket else { return }
        isSocketReady = true
        let writes = pendingWrites
        pendingWrites = []
        for data in writes { socket.send(data) }
    }

    private func report(_ error: Error) {
        if let data = (error.localizedDescription + "\n").data(using: .utf8) {
            onErrorOutput?(data)
        }
        terminate(1)
    }

    private func terminate(_ code: Int) {
        guard !didTerminate else { return }
        didTerminate = true
        isSocketReady = false
        socket?.stop()
        socket = nil
        activeEndpoint = nil
        onTermination?(code)
    }

    func makeChildTransport() -> (any DebugAdapterTransport)? {
        guard let endpoint = activeEndpoint else { return nil }
        return MacSocketDebugAdapterTransport(
            host: endpoint.host,
            port: endpoint.port,
            socketFactory: socketFactory
        )
    }

    static func announcedEndpoint(after marker: String, in output: String) -> Endpoint? {
        guard let markerRange = output.range(of: marker, options: .backwards) else { return nil }
        let address = output[markerRange.upperBound...]
            .split(whereSeparator: \Character.isWhitespace)
            .first
            .map(String.init) ?? ""
        guard let separator = address.lastIndex(of: ":"),
              let port = UInt16(address[address.index(after: separator)...]) else { return nil }
        var host = String(address[..<separator])
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.isEmpty || host == "::" { host = "127.0.0.1" }
        return (host, port)
    }
}

/// A child connection to an adapter server already owned by a parent
/// `MacServerDebugAdapterTransport`. It has no process lifecycle of its own.
@MainActor
private final class MacSocketDebugAdapterTransport: DebugAdapterTransport, DebugAdapterChildTransportProviding {
    private let host: String
    private let port: UInt16
    private let socketFactory: @MainActor (String, UInt16) -> any DebugAdapterSocketConnection
    private var socket: (any DebugAdapterSocketConnection)?
    private var pendingWrites: [Data] = []
    private(set) var isRunning = false
    private var isReady = false

    var onData: ((Data) -> Void)?
    var onErrorOutput: ((Data) -> Void)?
    var onTermination: ((Int) -> Void)?

    init(
        host: String,
        port: UInt16,
        socketFactory: @escaping @MainActor (String, UInt16) -> any DebugAdapterSocketConnection
    ) {
        self.host = host
        self.port = port
        self.socketFactory = socketFactory
    }

    func start(rootURL: URL) throws {
        guard !isRunning else { return }
        isRunning = true
        isReady = false
        pendingWrites = []
        let socket = socketFactory(host, port)
        self.socket = socket
        socket.onReady = { [weak self] in self?.socketReady() }
        socket.onData = { [weak self] in self?.onData?($0) }
        socket.onFailure = { [weak self] error in self?.fail(error) }
        socket.onComplete = { [weak self] in self?.terminate(0) }
        socket.start()
    }

    func send(_ data: Data) throws {
        guard isReady, let socket else {
            pendingWrites.append(data)
            return
        }
        socket.send(data)
    }

    func stop() {
        socket?.stop()
        socket = nil
        pendingWrites = []
        isReady = false
        isRunning = false
    }

    func makeChildTransport() -> (any DebugAdapterTransport)? {
        MacSocketDebugAdapterTransport(
            host: host,
            port: port,
            socketFactory: socketFactory
        )
    }

    private func socketReady() {
        guard let socket else { return }
        isReady = true
        let writes = pendingWrites
        pendingWrites = []
        writes.forEach(socket.send)
    }

    private func fail(_ error: Error) {
        onErrorOutput?(Data((error.localizedDescription + "\n").utf8))
        terminate(1)
    }

    private func terminate(_ code: Int) {
        guard isRunning else { return }
        isRunning = false
        isReady = false
        socket?.stop()
        socket = nil
        onTermination?(code)
    }
}

/// Delve-specific composition over the shared child-process TCP transport.
@MainActor
final class MacDlvDebugAdapterTransport: MacServerDebugAdapterTransport {
    init(
        executableURL: URL,
        environment: [String: String],
        process: any RawProcessSession,
        socketFactory: @escaping @MainActor (String, UInt16) -> any DlvSocketConnection = {
            NetworkDebugAdapterSocketConnection(host: $0, port: $1)
        }
    ) {
        super.init(
            process: process,
            launchResolver: { _ in
                ServerDebugAdapterProcessLaunch(
                    executableURL: executableURL,
                    arguments: ["dap", "--listen=127.0.0.1:0"],
                    environment: environment
                )
            },
            endpointParser: {
                Self.announcedEndpoint(after: "DAP server listening at:", in: $0)
            },
            socketFactory: socketFactory
        )
    }
}
