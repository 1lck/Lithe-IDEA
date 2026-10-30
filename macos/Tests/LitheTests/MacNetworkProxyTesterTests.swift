import Foundation
import Testing
@testable import Lithe

@Suite("Proxy connection check cancellation", .serialized)
struct MacNetworkProxyTesterTests {
    @Test
    func cancellationStopsTheOwnedRequestBeforeReturning() async throws {
        var candidate = NetworkProxyConfiguration()
        candidate.mode = .custom
        candidate.host = "proxy.example"
        candidate.port = 3128
        let tester = MacNetworkProxyTester(sessionFactory: { configuration, _ in
            configuration.protocolClasses = [PendingProxyCheckProtocol.self]
            return MacNetworkSessionProvider.makeSession(configuration: configuration, plan: nil)
        }, policyResolver: { RustCoreBridge().networkProxyPolicy(from: $0) })
        let configuration = candidate
        let finished = TestGate()
        let task = Task {
            defer { finished.open() }
            return await tester.check(configuration: configuration)
        }
        defer { task.cancel() }
        let started = await PendingProxyCheckProtocol.started.waitUntilOpen()
        task.cancel()
        let completed = await finished.waitUntilOpen()
        let stopped = await PendingProxyCheckProtocol.stopped.waitUntilOpen()
        #expect(started)
        #expect(stopped)
        try #require(completed, "Cancelled proxy check must finish within the local deadline")
        let outcome = await task.value
        #expect(!outcome.succeeded)
    }
}

/// Never contacts a socket; cancellation is observed through URLProtocol's
/// stopLoading callback, not inferred from elapsed wall-clock time.
private final class PendingProxyCheckProtocol: URLProtocol, @unchecked Sendable {
    static let started = TestGate()
    static let stopped = TestGate()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.started.open() }
    override func stopLoading() { Self.stopped.open() }
}
