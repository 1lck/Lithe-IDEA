import Foundation
import Network
import Testing
@testable import Lithe

@Suite("Java test result server")
@MainActor
struct MacJavaTestResultServerTests {
    @Test
    func startReturnsTheListenerPortAndStopCancelsIt() async throws {
        let listener = TestJavaTestResultListener(readyPort: 43_128)
        let server = MacJavaTestResultServer(listenerFactory: { listener })

        #expect(try await server.start() == 43_128)
        #expect(listener.startCount == 1)

        server.stop()

        #expect(listener.cancelCount == 1)
    }

    @Test
    func cancellingStartupStopsThePendingListener() async {
        let started = TestGate()
        let listener = TestJavaTestResultListener(onStart: started.open)
        let server = MacJavaTestResultServer(listenerFactory: { listener })
        let startTask = Task { try await server.start() }
        defer {
            startTask.cancel()
            server.stop()
        }

        #expect(await started.waitUntilOpen())
        startTask.cancel()

        await #expect(throws: CancellationError.self) {
            try await startTask.value
        }
        #expect(listener.cancelCount == 1)
    }
}

private final class TestJavaTestResultListener: MacJavaTestResultListening {
    var onStateChange: ((MacJavaTestResultListenerState) -> Void)?
    var onConnection: ((NWConnection) -> Void)?
    private(set) var startCount = 0
    private(set) var cancelCount = 0

    private let readyPort: UInt16?
    private let onStart: (() -> Void)?

    init(readyPort: UInt16? = nil, onStart: (() -> Void)? = nil) {
        self.readyPort = readyPort
        self.onStart = onStart
    }

    func start(queue _: DispatchQueue) {
        startCount += 1
        onStart?()
        if let readyPort {
            onStateChange?(.ready(port: readyPort))
        }
    }

    func cancel() {
        cancelCount += 1
        onStateChange?(.cancelled)
    }
}
