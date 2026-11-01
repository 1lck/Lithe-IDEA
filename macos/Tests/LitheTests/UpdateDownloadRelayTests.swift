import Foundation
import Sparkle
import Testing
@testable import Lithe

@Suite("Update download relay", .serialized)
struct UpdateDownloadRelayTests {
    @Test
    func freshDownloadStreamsEverythingAndRemovesThePartial() async throws {
        let fixture = try RelayFixture()
        defer { fixture.cleanUp() }
        fixture.script([.respond(status: 200, headers: ["ETag": "\"v1\"", "Content-Length": "10"],
                                 chunks: ["abcde", "fghij"], failure: nil)])
        let result = try await fixture.run()
        #expect(result.outcome == .completed)
        #expect(result.body == "abcdefghij")
        #expect(result.head.contains("Content-Length: 10"))
        #expect(!FileManager.default.fileExists(atPath: fixture.entry.data.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.entry.metadata.path))
    }

    @Test
    func rejectsEncodedArchivesAndRequestsIdentity() async throws {
        let fixture = try RelayFixture()
        defer { fixture.cleanUp() }
        fixture.script([.respond(status: 200, headers: ["Content-Encoding": "gzip"], chunks: ["bad"], failure: nil)])
        let result = try await fixture.run()
        #expect(result.outcome == .failed(.invalidResponse))
        #expect(result.head.isEmpty)
        #expect(fixture.requests().first?.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
    }

    @Test
    func unknownLengthFailureDoesNotTerminateChunkedBody() async throws {
        let fixture = try RelayFixture(policy: .init(noProgressBudget: 45, retryDelays: [0], requestTimeout: 1))
        defer { fixture.cleanUp() }
        fixture.script([
            .respond(status: 200, headers: ["ETag": "v1"], chunks: ["hello"], failure: URLError(.timedOut)),
            .fail(URLError(.timedOut)),
        ])
        let result = try await fixture.run()
        #expect(result.outcome == .failed(.timedOut))
        #expect(result.head.contains("Transfer-Encoding: chunked"))
        #expect(result.body == "5\r\nhello\r\n")
    }

    @Test
    func unknownLengthCanResumeWhenRangeRevealsTotal() async throws {
        let fixture = try RelayFixture()
        defer { fixture.cleanUp() }
        fixture.script([
            .respond(status: 200, headers: ["ETag": "v1"], chunks: ["hello"], failure: URLError(.networkConnectionLost)),
            .respond(status: 206, headers: ["ETag": "v1", "Content-Range": "bytes 5-9/10"], chunks: ["world"], failure: nil),
        ])
        let result = try await fixture.run()
        #expect(result.outcome == .completed)
        #expect(result.head.contains("Transfer-Encoding: chunked"))
        #expect(result.body == "5\r\nhello\r\n5\r\nworld\r\n0\r\n\r\n")
    }

    @Test
    func droppedConnectionResumesWithRangeAndValidator() async throws {
        let fixture = try RelayFixture()
        defer { fixture.cleanUp() }
        fixture.script([
            .respond(status: 200, headers: ["ETag": "\"v1\"", "Content-Length": "10"],
                     chunks: ["abcde"], failure: URLError(.networkConnectionLost)),
            .respond(status: 206, headers: ["ETag": "\"v1\"", "Content-Range": "bytes 5-9/10", "Content-Length": "5"],
                     chunks: ["fghij"], failure: nil),
        ])
        let result = try await fixture.run()
        #expect(result.outcome == .completed)
        #expect(result.body == "abcdefghij")
        let requests = fixture.requests()
        #expect(requests.count == 2)
        #expect(requests.last?.value(forHTTPHeaderField: "Range") == "bytes=5-")
        #expect(requests.last?.value(forHTTPHeaderField: "If-Range") == "\"v1\"")
    }

    @Test
    func exhaustedRetriesKeepThePartialForTheNextAttempt() async throws {
        let fixture = try RelayFixture(policy: .init(noProgressBudget: 45, retryDelays: [0], requestTimeout: 1))
        defer { fixture.cleanUp() }
        fixture.script([
            .respond(status: 200, headers: ["ETag": "\"v1\"", "Content-Length": "10"],
                     chunks: ["abcde"], failure: URLError(.timedOut)),
            .fail(URLError(.timedOut)),
        ])
        let first = try await fixture.run()
        #expect(first.outcome == .failed(.timedOut))
        #expect(first.failure == .timedOut)
        #expect(try Data(contentsOf: fixture.entry.data) == Data("abcde".utf8))

        fixture.script([.respond(status: 206, headers: ["ETag": "\"v1\"", "Content-Range": "bytes 5-9/10"],
                                 chunks: ["fghij"], failure: nil)])
        let second = try await fixture.run()
        #expect(second.outcome == .completed)
        // The stored prefix is replayed from disk before the resumed bytes.
        #expect(second.body == "abcdefghij")
        #expect(second.head.contains("Content-Length: 10"))
        #expect(fixture.requests().last?.value(forHTTPHeaderField: "Range") == "bytes=5-")
    }

    @Test
    func changedArchiveRestartsFromTheBeginning() async throws {
        let fixture = try RelayFixture(policy: .init(noProgressBudget: 45, retryDelays: [0], requestTimeout: 1))
        defer { fixture.cleanUp() }
        fixture.script([
            .respond(status: 200, headers: ["ETag": "\"v1\"", "Content-Length": "10"],
                     chunks: ["abcde"], failure: URLError(.timedOut)),
            .fail(URLError(.timedOut)),
        ])
        _ = try await fixture.run()
        // If-Range no longer matches, so the server sends the whole new archive.
        fixture.script([.respond(status: 200, headers: ["ETag": "\"v2\"", "Content-Length": "6"],
                                 chunks: ["NEWZIP"], failure: nil)])
        let result = try await fixture.run()
        #expect(result.outcome == .completed)
        #expect(result.body == "NEWZIP")
        #expect(result.head.contains("Content-Length: 6"))
    }

    @Test
    func rangeResponseForAReuploadedArchiveIsNotSpliced() async throws {
        let fixture = try RelayFixture(policy: .init(noProgressBudget: 45, retryDelays: [0], requestTimeout: 1))
        defer { fixture.cleanUp() }
        fixture.script([
            .respond(status: 200, headers: ["ETag": "\"v1\"", "Content-Length": "10"],
                     chunks: ["abcde"], failure: URLError(.timedOut)),
            .fail(URLError(.timedOut)),
        ])
        _ = try await fixture.run()
        // Like GitHub's CDN, the server ignores the stale If-Range and still answers 206.
        fixture.script([
            .respond(status: 206, headers: ["ETag": "\"v2\"", "Content-Range": "bytes 5-9/10", "Content-Length": "5"],
                     chunks: ["VWXYZ"], failure: nil),
            .respond(status: 200, headers: ["ETag": "\"v2\"", "Content-Length": "10"],
                     chunks: ["QRSTUVWXYZ"], failure: nil),
        ])
        let result = try await fixture.run()
        #expect(result.outcome == .completed)
        #expect(result.body == "QRSTUVWXYZ")
        #expect(fixture.requests().last?.value(forHTTPHeaderField: "Range") == nil)
    }

    @Test
    func clientErrorsAreReportedWithoutRetrying() async throws {
        let fixture = try RelayFixture()
        defer { fixture.cleanUp() }
        fixture.script([.respond(status: 404, headers: [:], chunks: [], failure: nil)])
        let result = try await fixture.run()
        #expect(result.outcome == .failed(.httpStatus(404)))
        #expect(fixture.requests().count == 1)
        #expect(result.head.isEmpty)
    }

    @Test
    func serverErrorsAreRetried() async throws {
        let fixture = try RelayFixture()
        defer { fixture.cleanUp() }
        fixture.script([
            .respond(status: 503, headers: [:], chunks: [], failure: nil),
            .respond(status: 200, headers: ["ETag": "\"v1\"", "Content-Length": "2"], chunks: ["ok"], failure: nil),
        ])
        let result = try await fixture.run()
        #expect(result.outcome == .completed)
        #expect(result.body == "ok")
    }

    @Test
    func failuresAreClassifiedByNetworkCause() {
        #expect(UpdateDownloadFailure(URLError(.timedOut)) == .timedOut)
        #expect(UpdateDownloadFailure(URLError(.cannotConnectToHost)) == .connectionFailed)
        #expect(UpdateDownloadFailure(URLError(.networkConnectionLost)) == .connectionFailed)
        #expect(UpdateDownloadFailure(URLError(.serverCertificateUntrusted)) == .tlsOrProxyFailure)
        #expect(UpdateDownloadFailure(URLError(.cancelled)) == nil)
        #expect(UpdateDownloadFailure.httpStatus(503).isRetryable)
        #expect(!UpdateDownloadFailure.httpStatus(404).isRetryable)
        #expect(UpdateDownloadFailure.httpStatus(503).checkError.code == .httpStatus)
    }

    @Test
    func requestParsingAcceptsOnlyTokenPaths() {
        let token = String(repeating: "ab", count: 16)
        let parsed = UpdateDownloadRelay.parseRequest(Data(
            "GET /\(token)/Lithe.dmg HTTP/1.1\r\nHost: 127.0.0.1\r\nUser-Agent: Lithe/1 Sparkle/2".utf8))
        #expect(parsed == .init(method: "GET", token: token, userAgent: "Lithe/1 Sparkle/2"))
        #expect(UpdateDownloadRelay.parseRequest(Data("GET /nope/Lithe.dmg HTTP/1.1".utf8)) == nil)
        #expect(UpdateDownloadRelay.parseRequest(Data("GET /\(token)".utf8)) == nil)
        #expect(UpdateDownloadTransfer.contentRange("bytes 5-9/10")! == (5, 10))
        #expect(UpdateDownloadTransfer.contentRange("bytes */10") == nil)
    }

    @Test
    func pruningKeepsTheActiveDownloadAndRecentEntries() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-relay-prune-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UpdateDownloadPartialStore(directory: directory, maximumAge: 100, maximumEntries: 2)
        try store.prepareDirectory()
        let now = Date(timeIntervalSince1970: 10_000)
        let urls = (0..<4).map { URL(string: "https://example.invalid/\($0).dmg")! }
        for (index, url) in urls.enumerated() {
            let entry = store.entry(for: url)
            try Data("x".utf8).write(to: entry.data)
            let age = index == 3 ? 500.0 : Double(index)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)],
                                                  ofItemAtPath: entry.data.path)
        }
        store.prune(keeping: urls[2], now: now)
        let remaining = urls.map { FileManager.default.fileExists(atPath: store.entry(for: $0).data.path) }
        // Active entry stays; one other recent entry fits; the rest and the expired one go.
        #expect(remaining == [true, false, true, false])
    }

    @Test
    func loopbackListenerServesRegisteredDownloadsAndRejectsOthers() async throws {
        let fixture = try RelayFixture()
        defer { fixture.cleanUp() }
        fixture.script([.respond(status: 200, headers: ["ETag": "\"v1\"", "Content-Length": "5"],
                                 chunks: ["hello"], failure: nil)])
        let relay = UpdateDownloadRelay(store: fixture.store, configuration: fixture.configuration,
                                        diagnosticSink: { _ in })
        defer { relay.stop() }
        let relayed = try #require(relay.relayURL(for: fixture.upstream))
        #expect(relayed.host == "127.0.0.1")
        #expect(relayed.lastPathComponent == fixture.upstream.lastPathComponent)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: relayed)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == "hello")
        #expect(relay.lastFailure == nil)

        var forged = URLComponents(url: relayed, resolvingAgainstBaseURL: false)!
        forged.path = "/" + String(repeating: "0", count: 32) + "/Lithe.dmg"
        let (_, rejected) = try await session.data(from: forged.url!)
        #expect((rejected as? HTTPURLResponse)?.statusCode == 404)
    }

    @MainActor
    @Test
    func sparkleDownloadErrorsUseTheObservedCause() {
        let checker = UpdateChecker(bundle: .main, preferences: UserDefaults(suiteName: "relay-\(UUID().uuidString)")!,
            downloadRelay: UpdateDownloadRelay(store: .init(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("lithe-relay-unused-\(UUID().uuidString)"))))
        func sparkleError(_ underlying: URLError) -> NSError {
            NSError(domain: SUSparkleErrorDomain, code: Int(SUError.downloadError.rawValue),
                    userInfo: [NSUnderlyingErrorKey: underlying])
        }
        let remote = URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://github.com/a.dmg")!])
        let loopback = URLError(.networkConnectionLost,
                                userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "http://127.0.0.1:9/a.dmg")!])
        #expect(checker.downloadFailure(for: sparkleError(remote)) == .timedOut)
        #expect(checker.downloadFailure(for: sparkleError(loopback)) == nil)
        #expect(checker.downloadFailure(for: NSError(domain: SUSparkleErrorDomain, code: 1)) == nil)
        #expect(UpdateChecker.downloadFailureMessage(.timedOut)
            .hasPrefix(UpdateCheckError.timedOut.userMessage))
    }
}

private struct RelayResult {
    let outcome: UpdateDownloadTransfer.Outcome
    let failure: UpdateDownloadFailure?
    let head: String
    let body: String
}

private final class RelayFixture: @unchecked Sendable {
    let host = "relay-\(UUID().uuidString.lowercased()).invalid"
    let directory: URL
    let store: UpdateDownloadPartialStore
    let configuration: URLSessionConfiguration
    let policy: UpdateDownloadTransfer.Policy
    var upstream: URL { URL(string: "https://\(host)/releases/Lithe-1.dmg")! }
    var entry: UpdateDownloadPartialStore.Entry { store.entry(for: upstream) }

    init(policy: UpdateDownloadTransfer.Policy = .init(noProgressBudget: 45, retryDelays: [0, 0], requestTimeout: 1)) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-relay-\(UUID().uuidString)", isDirectory: true)
        store = UpdateDownloadPartialStore(directory: directory)
        try store.prepareDirectory()
        configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedUpstreamProtocol.self]
        self.policy = policy
    }

    func script(_ steps: [ScriptedUpstreamProtocol.Step]) { ScriptedUpstreamProtocol.script(host: host, steps) }
    func requests() -> [URLRequest] { ScriptedUpstreamProtocol.requests(host: host) }

    func cleanUp() {
        ScriptedUpstreamProtocol.reset(host: host)
        try? FileManager.default.removeItem(at: directory)
    }

    func run() async throws -> RelayResult {
        let delivered = TestGate()
        ScriptedUpstreamProtocol.setDeliveryGate(host: host, delivered)
        let client = BufferedRelayClient(delivered: delivered)
        let finished = TestGate()
        let box = OutcomeBox()
        let transfer = UpdateDownloadTransfer(upstream: upstream, userAgent: "Test", entry: entry, client: client,
            configuration: configuration, policy: policy, now: { 0 },
            schedule: { _, queue, work in queue.async(execute: work) }) { outcome, failure in
            box.set(outcome, failure)
            finished.open()
        }
        transfer.start()
        let completed = await finished.waitUntilOpen(timeout: .seconds(5))
        try #require(completed, "Relay transfer must finish within the local deadline")
        let (outcome, failure) = try #require(box.value)
        let (head, body) = client.split()
        return RelayResult(outcome: outcome, failure: failure, head: head, body: body)
    }
}

private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (UpdateDownloadTransfer.Outcome, UpdateDownloadFailure?)?
    var value: (UpdateDownloadTransfer.Outcome, UpdateDownloadFailure?)? { lock.withLock { stored } }
    func set(_ outcome: UpdateDownloadTransfer.Outcome, _ failure: UpdateDownloadFailure?) {
        lock.withLock { stored = (outcome, failure) }
    }
}

private final class BufferedRelayClient: UpdateRelayClient, @unchecked Sendable {
    private let lock = NSLock()
    private let delivered: TestGate
    private var data = Data()
    private var sends = 0

    init(delivered: TestGate) { self.delivered = delivered }

    func send(_ chunk: Data) -> Bool {
        let bodyArrived = lock.withLock { () -> Bool in
            data.append(chunk)
            sends += 1
            return sends > 1
        }
        // The first send is the response head; later sends carry upstream bytes.
        if bodyArrived { delivered.open() }
        return true
    }

    func close() {}

    func split() -> (String, String) {
        let text = lock.withLock { String(decoding: data, as: UTF8.self) }
        guard let range = text.range(of: "\r\n\r\n") else { return (text, "") }
        return (String(text[..<range.lowerBound]), String(text[range.upperBound...]))
    }
}

/// Serves scripted responses per host; never opens a socket.
final class ScriptedUpstreamProtocol: URLProtocol, @unchecked Sendable {
    enum Step {
        case respond(status: Int, headers: [String: String], chunks: [String], failure: URLError?)
        case fail(URLError)
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var steps: [String: [Step]] = [:]
    private nonisolated(unsafe) static var received: [String: [URLRequest]] = [:]
    private nonisolated(unsafe) static var gates: [String: TestGate] = [:]

    static func setDeliveryGate(host: String, _ gate: TestGate) { lock.withLock { gates[host] = gate } }

    static func script(host: String, _ script: [Step]) { lock.withLock { steps[host] = script } }
    static func requests(host: String) -> [URLRequest] { lock.withLock { received[host] ?? [] } }
    static func reset(host: String) {
        lock.withLock {
            steps[host] = nil
            received[host] = nil
            gates[host] = nil
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        let step = Self.lock.withLock { () -> Step? in
            Self.received[host, default: []].append(request)
            guard var queue = Self.steps[host], !queue.isEmpty else { return nil }
            let step = queue.removeFirst()
            Self.steps[host] = queue
            return step
        }
        switch step {
        case .none:
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        case .fail(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .respond(let status, let headers, let chunks, let failure):
            // An explicit type keeps URLSession from buffering bytes for MIME sniffing.
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: headers.merging(["Content-Type": "application/octet-stream"]) { current, _ in current })!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks { client?.urlProtocol(self, didLoad: Data(chunk.utf8)) }
            guard let failure else { return client?.urlProtocolDidFinishLoading(self) ?? () }
            guard !chunks.isEmpty, let gate = Self.lock.withLock({ Self.gates[host] }) else {
                return client?.urlProtocol(self, didFailWithError: failure) ?? ()
            }
            // A failure reported in the same turn as the bytes makes URLSession
            // drop them. Drop the connection only after the relay forwarded
            // them, as a real network would, and report it on the loading run loop.
            let runLoop = CFRunLoopGetCurrent()
            DispatchQueue.global().async { [self] in
                _ = gate.waitSynchronously(timeout: 5)
                CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
                    self.client?.urlProtocol(self, didFailWithError: failure)
                }
                CFRunLoopWakeUp(runLoop)
            }
        }
    }

    override func stopLoading() {}
}
