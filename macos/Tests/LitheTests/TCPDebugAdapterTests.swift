import Foundation
import LitheCoreContracts
import LitheDebugModule
import Network
import Testing
@testable import Lithe

@Suite("TCP debug adapter lifecycle")
@MainActor
struct TCPDebugAdapterTests {
    private let root = URL(fileURLWithPath: "/tcp-debug-test", isDirectory: true)
    private let endpoint = DebugAdapterEndpoint(host: "debug.example.org", port: 5678)

    @Test
    func aCancelledDrainDeadlineCannotCloseTheReplacementConnection() async throws {
        let first = ControlledDebugSocket()
        let second = ControlledDebugSocket()
        let scheduler = TCPTestScheduler()
        var sockets = [first, second]
        let transport = MacTCPDebugAdapterTransport(
            endpointResolver: { _ in endpoint }, deadlineScheduler: scheduler,
            socketFactory: { _ in sockets.removeFirst() }
        )
        defer { transport.stop() }
        try transport.start(rootURL: root)
        #expect(await first.started.wait(timeout: .seconds(5)))
        first.onReady?()
        try transport.send(Data([1]))
        transport.finishSendingAndStop()
        let lateDrain = try #require(scheduler.deadlines.last).action
        try transport.start(rootURL: root)
        #expect(await second.started.wait(timeout: .seconds(5)))
        lateDrain()
        #expect(transport.isRunning)
        #expect(second.stopCount == 0)
    }

    @Test(arguments: [false, true])
    func gracefulStopDrainsInOrderOrClosesAtItsOwnDeadline(stalled: Bool) async throws {
        let socket = ControlledDebugSocket()
        let scheduler = TCPTestScheduler()
        let transport = make(socket: socket, scheduler: scheduler)
        defer { transport.stop() }
        transport.onTermination = { _ in Issue.record("Drain notified a stopped session") }
        try transport.start(rootURL: root)
        #expect(await socket.started.wait(timeout: .seconds(5)))
        socket.onReady?()
        try transport.send(Data([1]))
        try transport.send(Data([2]))
        transport.finishSendingAndStop()
        #expect(!transport.isRunning)
        #expect(throws: MacTCPDebugAdapterTransport.TransportError.stopped) { try transport.send(Data([3])) }
        #expect(socket.stopCount == 0)
        if stalled {
            scheduler.deadlines.last?.fire()
        } else {
            let second = TCPTestEvent()
            socket.onWrite = { second.fire() }
            socket.completeWrite(.success(()))
            #expect(await second.wait(timeout: .seconds(5)))
            #expect(socket.writes == [Data([1]), Data([2])])
            socket.completeWrite(.success(()))
        }
        #expect(socket.stopCount == 1)
        #expect(scheduler.deadlines.allSatisfy { $0.cancelled })
    }

    @Test(arguments: [false, true])
    func aDrainReleasesItsTemporaryOwnershipOnCompletionOrTimeout(stalled: Bool) async throws {
        let socket = ControlledDebugSocket()
        let scheduler = TCPTestScheduler()
        var transport: MacTCPDebugAdapterTransport? = make(socket: socket, scheduler: scheduler)
        weak var released = transport
        defer { transport?.stop(); released?.stop() }
        try transport?.start(rootURL: root)
        #expect(await socket.started.wait(timeout: .seconds(5)))
        socket.onReady?()
        try transport?.send(Data([1]))
        transport?.finishSendingAndStop()
        transport = nil
        #expect(released != nil)
        if stalled { scheduler.deadlines.last?.fire() }
        else { socket.completeWrite(.success(())) }
        #expect(released == nil)
        #expect(socket.stopCount == 1)
    }

    @Test
    func aConnectedNonDAPPeerCannotLeaveTheSessionInitializingForever() async throws {
        let socket = ControlledDebugSocket()
        let deadlines = TCPTestScheduler()
        let transport = make(socket: socket)
        let session = CoreDebugAdapterProtocolSession(
            adapterID: "python", transport: transport, core: RustCoreBridge(),
            deadlineScheduler: deadlines, initializationTimeoutMilliseconds: 100
        )
        defer { session.stop() }
        try session.start(rootURL: root)
        #expect(await socket.started.wait(timeout: .seconds(5)))
        socket.onReady?()
        socket.completeWrite(.success(()))
        #expect(session.state == .initializing)
        deadlines.deadlines[0].fire()
        #expect(session.state == .failed)
        #expect(!transport.isRunning)
        #expect(socket.stopCount == 1)
        #expect(deadlines.deadlines.allSatisfy { $0.cancelled })
    }

    @Test
    func errorObserverRestartDoesNotReceiveTheOldTermination() async throws {
        let first = ControlledDebugSocket()
        let second = ControlledDebugSocket()
        var sockets = [first, second]
        let transport = MacTCPDebugAdapterTransport(
            endpointResolver: { _ in endpoint }, socketFactory: { _ in sockets.removeFirst() }
        )
        defer { transport.onErrorOutput = nil; transport.stop() }
        transport.onErrorOutput = { _ in
            do { try transport.start(rootURL: root) }
            catch { Issue.record("Restart failed: \(error)") }
        }
        transport.onTermination = { _ in Issue.record("Old termination entered restarted lifecycle") }
        try transport.start(rootURL: root)
        #expect(await first.started.wait(timeout: .seconds(5)))
        first.onFailure?(TCPTestError.failed)
        #expect(await second.started.wait(timeout: .seconds(5)))
        #expect(transport.isRunning)
    }

    @Test
    func releasingTheTransportCancelsItsOwnedConnection() async throws {
        let socket = ControlledDebugSocket()
        var transport: MacTCPDebugAdapterTransport? = make(socket: socket)
        defer { transport?.stop() }
        weak var released = transport
        try transport?.start(rootURL: root)
        #expect(await socket.started.wait(timeout: .seconds(5)))
        transport = nil
        #expect(released == nil)
        #expect(socket.stopCount == 1)
        #expect(socket.onReady == nil)
    }

    @Test
    func externalDraftKeepsEndpointOutsideDAPArgumentsAndSurvivesEncoding() throws {
        let configuration = try ExternalDebugAdapterConfiguration.make(
            host: endpoint.host, port: endpoint.port, request: .attach,
            argumentsJSON: #"{"connect":{"host":"target.example.org","port":9000}}"#
        )
        #expect(configuration.adapterEndpoint == endpoint)
        #expect(configuration.arguments["adapterEndpoint"] == nil)
        #expect(configuration.arguments["connect"] == .object(["host": .string("target.example.org"), "port": .integer(9000)]))
        let encoded = try JSONEncoder().encode(configuration)
        #expect(try JSONDecoder().decode(DebugLaunchConfiguration.self, from: encoded) == configuration)
        let filters = DebugSteppingFilters(classNameFilters: [], skipSynthetics: false,
            skipStaticInitializers: false, skipConstructors: false, hideFilteredStackFrames: false)
        #expect(configuration.applying(steppingFilters: filters).adapterEndpoint == endpoint)
        for input in ["[]", "null", "{", String(repeating: " ", count: ExternalDebugAdapterConfiguration.maximumArgumentBytes + 1)] {
            #expect(throws: ExternalDebugAdapterConfiguration.ValidationError.self) {
                _ = try ExternalDebugAdapterConfiguration.make(host: "localhost", port: 5678, request: .launch, argumentsJSON: input)
            }
        }
    }

    @Test(arguments: [false, true])
    func explicitStopCancelsResolutionOrConnectionWithoutTerminalCallbacks(connecting: Bool) async throws {
        let gate = TCPEndpointGate()
        let socket = ControlledDebugSocket()
        let transport = MacTCPDebugAdapterTransport(
            endpointResolver: { _ in connecting ? endpoint : try await gate.resolve() },
            socketFactory: { _ in socket }
        )
        defer { transport.stop(); gate.finish(endpoint) }
        transport.onTermination = { _ in Issue.record("Explicit stop notified termination") }
        try transport.start(rootURL: root)
        if connecting { #expect(await socket.started.wait(timeout: .seconds(5))) }
        else { #expect(await gate.requested.wait(timeout: .seconds(5))) }
        let lateReady = socket.onReady
        transport.stop()
        lateReady?()
        if !connecting {
            gate.finish(endpoint)
            #expect(await gate.returned.wait(timeout: .seconds(5)))
        }
        #expect(!transport.isRunning)
        #expect(socket.stopCount == (connecting ? 1 : 0))
    }

    @Test
    func connectionProviderFailureEndsOnceAndCancelsStartup() async throws {
        let scheduler = TCPTestScheduler()
        let ended = TCPTestEvent()
        let transport = MacTCPDebugAdapterTransport(
            endpointResolver: { _ in endpoint }, deadlineScheduler: scheduler,
            socketFactory: { _ in throw TCPTestError.failed }
        )
        defer { transport.stop() }
        var codes: [Int] = []
        transport.onTermination = { codes.append($0); ended.fire() }
        try transport.start(rootURL: root)
        #expect(await ended.wait(timeout: .seconds(5)))
        #expect(codes == [1])
        #expect(!transport.isRunning)
        #expect(scheduler.deadlines.allSatisfy { $0.cancelled })
    }

    @Test
    func loopbackEndpointNeedsNoRemoteApproval() async throws {
        let provider = TCPTestConnectionProvider()
        let transport = try MacExternalDebugAdapterTransport.make(
            endpoint: .init(host: "127.0.0.1", port: 5678),
            validate: { .init(host: $0.host, port: $0.port, remote: false) },
            confirm: { _ in Issue.record("Loopback prompted for remote consent"); return false },
            connectionProvider: provider
        )
        defer { transport.stop() }
        try transport.start(rootURL: root)
        #expect(await provider.socket.started.wait(timeout: .seconds(5)))
        #expect(provider.endpoints == [.init(host: "127.0.0.1", port: 5678)])
    }

    @Test
    func queuesInOrderAndKeepsOnlyOneNativeWriteInFlight() async throws {
        let socket = ControlledDebugSocket()
        let scheduler = TCPTestScheduler()
        let transport = make(socket: socket, scheduler: scheduler)
        defer { transport.stop() }
        try transport.start(rootURL: root)
        try transport.send(Data([1]))
        try transport.send(Data([2]))
        #expect(await socket.started.wait(timeout: .seconds(5)))
        #expect(socket.writes.isEmpty)
        socket.onReady?()
        #expect(socket.writes == [Data([1])])
        #expect(scheduler.deadlines[0].cancelled)
        let secondWrite = TCPTestEvent()
        socket.onWrite = { secondWrite.fire() }
        socket.completeWrite(.success(()))
        #expect(await secondWrite.wait(timeout: .seconds(5)))
        #expect(socket.writes == [Data([1]), Data([2])])
        socket.completeWrite(.success(()))
        #expect(scheduler.deadlines.allSatisfy { $0.cancelled })
    }

    @Test(arguments: [false, true])
    func bufferLimitIncludesQueuedAndInFlightBytes(ready: Bool) async throws {
        let socket = ControlledDebugSocket()
        let scheduler = TCPTestScheduler()
        let transport = make(socket: socket, scheduler: scheduler,
                             limits: .init(bufferedBytes: 3, bufferedWrites: 2))
        var codes: [Int] = []
        transport.onTermination = { codes.append($0) }
        defer { transport.stop() }
        try transport.start(rootURL: root)
        #expect(await socket.started.wait(timeout: .seconds(5)))
        if ready { socket.onReady?() }
        try transport.send(Data([1, 2]))
        try transport.send(Data([3]))
        #expect(throws: MacTCPDebugAdapterTransport.TransportError.bufferLimit) {
            try transport.send(Data([4]))
        }
        #expect(codes == [1])
        #expect(socket.stopCount == 1)
        #expect(!transport.isRunning)
        #expect(scheduler.deadlines.allSatisfy { $0.cancelled })
    }

    @Test
    func writeCountIsBoundedEvenForSmallMessages() async throws {
        let socket = ControlledDebugSocket()
        let transport = make(socket: socket, limits: .init(bufferedBytes: 100, bufferedWrites: 1))
        defer { transport.stop() }
        try transport.start(rootURL: root)
        try transport.send(Data([1]))
        #expect(throws: MacTCPDebugAdapterTransport.TransportError.bufferLimit) {
            try transport.send(Data([2]))
        }
        #expect(!transport.isRunning)
    }

    @Test
    func startupDeadlineCancelsResolutionAndRejectsItsLateEndpoint() async throws {
        let gate = TCPEndpointGate()
        let scheduler = TCPTestScheduler()
        var opened = 0
        let transport = MacTCPDebugAdapterTransport(
            endpointResolver: { _ in try await gate.resolve() },
            deadlineScheduler: scheduler,
            socketFactory: { _ in opened += 1; return ControlledDebugSocket() }
        )
        defer { transport.stop(); gate.finish(endpoint) }
        var codes: [Int] = []
        transport.onTermination = { codes.append($0) }
        try transport.start(rootURL: root)
        #expect(await gate.requested.wait(timeout: .seconds(5)))
        scheduler.deadlines[0].fire()
        gate.finish(endpoint)
        #expect(await gate.returned.wait(timeout: .seconds(5)))
        #expect(opened == 0)
        #expect(codes == [1])
        #expect(!transport.isRunning)
    }

    @Test
    func connectionAndWriteDeadlinesDoNotLimitAnIdleConnectedSession() async throws {
        let socket = ControlledDebugSocket()
        let scheduler = TCPTestScheduler()
        let transport = make(socket: socket, scheduler: scheduler)
        defer { transport.stop() }
        var codes: [Int] = []
        transport.onTermination = { codes.append($0) }
        try transport.start(rootURL: root)
        #expect(await socket.started.wait(timeout: .seconds(5)))
        let expiredStartup = scheduler.deadlines[0].action
        socket.onReady?()
        expiredStartup()
        #expect(transport.isRunning)
        #expect(scheduler.deadlines.count == 1)
        try transport.send(Data([1]))
        scheduler.deadlines[1].fire()
        #expect(codes == [1])
        #expect(socket.stopCount == 1)
    }

    @Test
    func aSocketThatNeverBecomesReadyHitsTheStartupDeadline() async throws {
        let socket = ControlledDebugSocket()
        let scheduler = TCPTestScheduler()
        let transport = make(socket: socket, scheduler: scheduler)
        defer { transport.stop() }
        try transport.start(rootURL: root)
        #expect(await socket.started.wait(timeout: .seconds(5)))
        scheduler.deadlines[0].fire()
        #expect(!transport.isRunning)
        #expect(socket.stopCount == 1)
    }

    @Test(arguments: ["eof", "read", "write"])
    func terminalEventsCleanUpExactlyOnceAndRevokeCallbacks(kind: String) async throws {
        let socket = ControlledDebugSocket()
        let scheduler = TCPTestScheduler()
        let transport = make(socket: socket, scheduler: scheduler)
        defer { transport.stop() }
        var codes: [Int] = []
        var received = Data()
        transport.onTermination = { codes.append($0) }
        transport.onData = { received.append($0) }
        try transport.start(rootURL: root)
        #expect(await socket.started.wait(timeout: .seconds(5)))
        socket.onReady?()
        let lateReady = socket.onReady
        let lateData = socket.onData
        let lateError = socket.onFailure
        let lateEOF = socket.onComplete
        socket.onData?(Data([7]))
        switch kind {
        case "eof": socket.onComplete?()
        case "read": socket.onFailure?(TCPTestError.failed)
        default:
            try transport.send(Data([1]))
            socket.completeWrite(.failure(TCPTestError.failed))
        }
        lateReady?()
        lateData?(Data([8]))
        lateError?(TCPTestError.failed)
        lateEOF?()
        transport.stop()
        transport.stop()
        #expect(codes == [kind == "eof" ? 0 : 1])
        #expect(received == Data([7]))
        #expect(socket.stopCount == 1)
        #expect(socket.onData == nil && socket.onFailure == nil && socket.onReady == nil && socket.onComplete == nil)
        #expect(scheduler.deadlines.allSatisfy { $0.cancelled })
    }

    @Test
    func restartRejectsOldSocketCallbacksAndWriteCompletions() async throws {
        let first = ControlledDebugSocket()
        let second = ControlledDebugSocket()
        var sockets = [first, second]
        let transport = MacTCPDebugAdapterTransport(
            endpointResolver: { _ in endpoint },
            socketFactory: { _ in sockets.removeFirst() }
        )
        defer { transport.stop() }
        var received = Data()
        var codes: [Int] = []
        transport.onData = { received.append($0) }
        transport.onTermination = { codes.append($0) }
        try transport.start(rootURL: root)
        #expect(await first.started.wait(timeout: .seconds(5)))
        first.onReady?()
        try transport.send(Data([1]))
        let oldData = first.onData
        let oldFailure = first.onFailure
        let oldReady = first.onReady
        transport.stop()
        try transport.start(rootURL: root)
        #expect(await second.started.wait(timeout: .seconds(5)))
        second.onReady?()
        try transport.send(Data([2]))
        first.completeWrite(.failure(TCPTestError.failed))
        oldData?(Data([9]))
        oldFailure?(TCPTestError.failed)
        oldReady?()
        second.onData?(Data([3]))
        #expect(received == Data([3]))
        #expect(codes.isEmpty)
        #expect(second.writes == [Data([2])])
        #expect(transport.isRunning)
    }

    @Test(arguments: [false, true])
    func externalEndpointIsValidatedAndConfirmedBeforeAnyConnection(approved: Bool) async throws {
        let provider = TCPTestConnectionProvider()
        var order: [String] = []
        let makeTransport = {
            try MacExternalDebugAdapterTransport.make(
                endpoint: endpoint,
                validate: { input in
                    order.append("validate")
                    #expect(input == endpoint)
                    return .init(host: input.host, port: input.port, remote: true)
                },
                confirm: { input in
                    order.append("confirm")
                    #expect(input == endpoint)
                    return approved
                },
                connectionProvider: provider
            )
        }
        if approved {
            let transport = try makeTransport()
            defer { transport.stop() }
            try transport.start(rootURL: root)
            #expect(await provider.socket.started.wait(timeout: .seconds(5)))
            #expect(provider.endpoints == [endpoint])
            transport.stop()
            #expect(provider.socket.stopCount == 1)
        } else {
            #expect(throws: MacTCPDebugAdapterTransport.TransportError.connectionDeclined) {
                _ = try makeTransport()
            }
            #expect(provider.endpoints.isEmpty)
        }
        #expect(order == ["validate", "confirm"])
    }

    @Test
    func anInvalidExternalEndpointNeverAsksConsentOrOpensASocket() throws {
        let provider = TCPTestConnectionProvider()
        #expect(throws: TCPTestError.self) {
            _ = try MacExternalDebugAdapterTransport.make(
                endpoint: endpoint,
                validate: { _ in throw TCPTestError.failed },
                confirm: { _ in Issue.record("Invalid endpoint reached consent"); return true },
                connectionProvider: provider
            )
        }
        #expect(provider.endpoints.isEmpty)
    }

    @Test
    func realTCPStreamsBytesBothWaysAndStopDoesNotStopTheExternalListener() async throws {
        let server = try TCPTestServer()
        defer { server.stop() }
        #expect(await server.ready.wait(timeout: .seconds(5)))
        let port = try #require(server.port)
        let transport = MacTCPDebugAdapterTransport(endpointResolver: { _ in
            DebugAdapterEndpoint(host: "127.0.0.1", port: Int(port))
        })
        defer { transport.stop() }
        let received = TCPTestEvent()
        var bytes = Data()
        transport.onData = { bytes.append($0); if bytes.count >= 4 { received.fire() } }
        try transport.start(rootURL: root)
        try transport.send(Data([1, 2, 3, 4]))
        #expect(await received.wait(timeout: .seconds(5)))
        #expect(bytes == Data([1, 2, 3, 4]))
        transport.stop()
        #expect(server.isReady)
        #expect(!transport.isRunning)
    }

    @Test
    func realTCPRunsCoreInitializeAndAttachWithFragmentedDAPResponses() async throws {
        let server = try TCPTestServer()
        defer { server.stop() }
        #expect(await server.ready.wait(timeout: .seconds(5)))
        let port = try #require(server.port)
        let transport = MacTCPDebugAdapterTransport(endpointResolver: { _ in
            DebugAdapterEndpoint(host: "127.0.0.1", port: Int(port))
        })
        defer { transport.stop() }
        let session = CoreDebugAdapterProtocolSession(
            adapterID: "python", transport: transport, core: RustCoreBridge(),
            deadlineScheduler: MacDebugOperationDeadlineScheduler()
        )
        defer { session.stop() }
        let attached = TCPTestEvent()
        let disconnected = TCPTestEvent()
        var commands: [String] = []
        var incoming = Data()
        server.onData = { data, connection in
            incoming.append(data)
            while let boundary = incoming.range(of: Data("\r\n\r\n".utf8)),
                  let header = String(data: incoming[..<boundary.lowerBound], encoding: .utf8),
                  let length = Int(header.dropFirst("Content-Length: ".count)),
                  incoming.endIndex >= boundary.upperBound + length {
                let body = incoming[boundary.upperBound..<(boundary.upperBound + length)]
                incoming = Data(incoming[(boundary.upperBound + length)...])
                guard let request = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let command = request["command"] as? String, let sequence = request["seq"] as? Int else {
                    Issue.record("Malformed DAP request"); return
                }
                commands.append(command)
                if command == "attach" {
                    let args = request["arguments"] as? [String: Any]
                    #expect(args?["justMyCode"] as? Bool == true)
                    #expect(args?["adapterEndpoint"] == nil)
                }
                if command == "disconnect" {
                    let args = request["arguments"] as? [String: Any]
                    #expect(args?["terminateDebuggee"] as? Bool == false)
                    disconnected.fire()
                }
                let response: [String: Any] = ["seq": sequence + 100, "type": "response", "request_seq": sequence,
                    "command": command, "success": true, "body": [:]]
                guard let payload = try? JSONSerialization.data(withJSONObject: response) else { return }
                // Exercise Core's incremental framing through the real socket.
                connection.send(content: Data("Content-Length: \(payload.count)\r\n".utf8), completion: .contentProcessed { _ in })
                connection.send(content: Data("\r\n".utf8) + payload, completion: .contentProcessed { _ in })
                if command == "initialize" {
                    let event = Data(#"{"seq":200,"type":"event","event":"initialized"}"#.utf8)
                    connection.send(content: Data("Content-Length: \(event.count)\r\n\r\n".utf8) + event, completion: .contentProcessed { _ in })
                }
            }
        }
        session.onStateChange = { state in if state == .running { attached.fire() } }
        try session.start(rootURL: root)
        try session.launch(.init(name: "TCP", request: .attach, arguments: ["justMyCode": .bool(true)],
                                 adapterEndpoint: .init(host: "127.0.0.1", port: Int(port))))
        #expect(await attached.wait(timeout: .seconds(5)))
        #expect(commands.first == "initialize")
        #expect(commands.contains("attach"))
        #expect(!commands.contains("launch"))
        session.stop()
        #expect(await disconnected.wait(timeout: .seconds(5)))
        #expect(!transport.isRunning)
        #expect(server.isReady)
    }

    private func make(
        socket: ControlledDebugSocket,
        scheduler: TCPTestScheduler? = nil,
        limits: MacTCPDebugAdapterTransport.Limits = .init()
    ) -> MacTCPDebugAdapterTransport {
        MacTCPDebugAdapterTransport(
            endpointResolver: { _ in endpoint }, deadlineScheduler: scheduler,
            limits: limits, socketFactory: { _ in socket }
        )
    }
}

private enum TCPTestError: Error { case failed }

@MainActor
private final class ControlledDebugSocket: DebugAdapterSocketConnection {
    var onReady: (() -> Void)?
    var onData: ((Data) -> Void)?
    var onFailure: ((Error) -> Void)?
    var onComplete: (() -> Void)?
    var onWrite: (() -> Void)?
    let started = TCPTestEvent()
    private(set) var stopCount = 0
    private(set) var writes: [Data] = []
    private var completions: [@MainActor @Sendable (Result<Void, Error>) -> Void] = []
    func start() { started.fire() }
    func send(_ data: Data, completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void) {
        writes.append(data)
        completions.append(completion)
        onWrite?()
    }
    func completeWrite(_ result: Result<Void, Error>) {
        guard !completions.isEmpty else { Issue.record("No pending socket write"); return }
        completions.removeFirst()(result)
    }
    func stop() { stopCount += 1 }
}

@MainActor
private final class TCPTestConnectionProvider: DebugAdapterConnectionProviding {
    let socket = ControlledDebugSocket()
    var endpoints: [DebugAdapterEndpoint] = []
    func makeConnection(to endpoint: DebugAdapterEndpoint) throws -> any DebugAdapterSocketConnection {
        endpoints.append(endpoint)
        return socket
    }
}

@MainActor
private final class TCPTestScheduler: DebugOperationDeadlineScheduling {
    var deadlines: [TCPTestDeadline] = []
    func schedule(afterMilliseconds _: Int, action: @escaping @MainActor () -> Void) -> any DebugOperationDeadline {
        let deadline = TCPTestDeadline(action: action)
        deadlines.append(deadline)
        return deadline
    }
}

@MainActor
private final class TCPTestDeadline: DebugOperationDeadline {
    var action: @MainActor () -> Void
    var cancelled = false
    init(action: @escaping @MainActor () -> Void) { self.action = action }
    func cancel() { cancelled = true; action = {} }
    func fire() { if !cancelled { action() } }
}

/// A monotonic local deadline only bounds failure; the observed event wakes success.
@MainActor
private final class TCPTestEvent {
    private var fired = false
    private var waiter: CheckedContinuation<Bool, Never>?
    private var timeoutItem: DispatchWorkItem?
    func fire() { fired = true; finish(true) }
    func wait(timeout: DispatchTimeInterval) async -> Bool {
        if fired { return true }
        return await withCheckedContinuation { continuation in
            waiter = continuation
            let item = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.finish(false) }
            }
            timeoutItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: item)
        }
    }
    private func finish(_ result: Bool) {
        timeoutItem?.cancel()
        timeoutItem = nil
        let pending = waiter
        waiter = nil
        pending?.resume(returning: result)
    }
}

@MainActor
private final class TCPEndpointGate {
    let requested = TCPTestEvent()
    let returned = TCPTestEvent()
    private var pending: CheckedContinuation<DebugAdapterEndpoint, Error>?
    func resolve() async throws -> DebugAdapterEndpoint {
        defer { returned.fire() }
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            requested.fire()
        }
    }
    func finish(_ endpoint: DebugAdapterEndpoint) {
        let continuation = pending
        pending = nil
        continuation?.resume(returning: endpoint)
    }
}

/// Real loopback integration uses an OS-assigned port, no external service or sleep.
@MainActor
private final class TCPTestServer {
    let listener: NWListener
    let ready = TCPTestEvent()
    private(set) var isReady = false
    private var stopped = false
    var onData: ((Data, NWConnection) -> Void)?
    var port: UInt16? { listener.port?.rawValue }
    private var connections: [NWConnection] = []
    private let queue = DispatchQueue(label: "app.lithe.test.dap-tcp")
    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                if case .ready = state { self.isReady = true; self.ready.fire() }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { connection.cancel(); return }
                self.connections.append(connection)
                connection.start(queue: self.queue)
                self.echo(connection)
            }
        }
        listener.start(queue: queue)
    }
    func stop() {
        stopped = true
        onData = nil
        listener.newConnectionHandler = nil
        listener.stateUpdateHandler = nil
        listener.cancel()
        connections.forEach { $0.cancel() }
        connections = []
    }
    private func echo(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                if let data {
                    if let onData = self.onData { onData(data, connection) }
                    else { connection.send(content: data, completion: .contentProcessed { _ in }) }
                }
                if !complete, error == nil { self.echo(connection) }
            }
        }
    }
}
