import CryptoKit
import Darwin
import Foundation
import LitheModuleAPI

/// Why the upstream update download stopped. Sparkle only sees the loopback
/// connection, so the relay keeps the real cause for the error message.
enum UpdateDownloadFailure: Equatable, Sendable {
    case timedOut
    case connectionFailed
    case tlsOrProxyFailure
    case httpStatus(Int)
    case invalidResponse

    init?(_ error: Error) {
        guard let error = error as? URLError else { return nil }
        switch error.code {
        case .timedOut:
            self = .timedOut
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .clientCertificateRejected, .clientCertificateRequired:
            self = .tlsOrProxyFailure
        case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed,
             .notConnectedToInternet, .internationalRoamingOff, .dataNotAllowed,
             .cannotLoadFromNetwork, .callIsActive:
            self = .connectionFailed
        default:
            return nil
        }
    }

    var checkError: UpdateCheckError {
        switch self {
        case .timedOut: return .timedOut
        case .connectionFailed: return .connectionFailed
        case .tlsOrProxyFailure: return .tlsOrProxyFailure
        case .httpStatus(let status): return .httpStatus(status)
        case .invalidResponse: return .invalidResponse
        }
    }

    /// Names `host` for network causes when the person chose a mirror; the
    /// official source keeps the GitHub wording.
    func message(host: String?) -> String {
        guard let host else { return checkError.userMessage }
        switch self {
        case .timedOut:
            return String(format: L10n.string("The connection to %@ timed out. Check your proxy or VPN connection and try again."), host)
        case .connectionFailed:
            return String(format: L10n.string("%@ could not be reached. Check your internet, proxy, or VPN connection and try again."), host)
        case .tlsOrProxyFailure:
            return String(format: L10n.string("A secure connection to %@ could not be established. Check TLS inspection, proxy, VPN, or system certificate settings."), host)
        case .httpStatus(let status):
            return String(format: L10n.string("%@ returned HTTP %@."), host, String(status))
        case .invalidResponse:
            return String(format: L10n.string("%@ returned an unexpected response."), host)
        }
    }

    /// Server errors and rate limits are usually temporary; other client
    /// errors (404, 403) will not change by asking again.
    var isRetryable: Bool {
        switch self {
        case .httpStatus(let status): return status == 408 || status == 429 || status >= 500
        case .invalidResponse: return false
        default: return true
        }
    }
}

/// Partial update archives kept between attempts.
///
/// Lifecycle: one `.part` file plus `.json` validator per upstream URL under the
/// platform cache directory (`<Caches>/Lithe/UpdateDownloads`). A completed
/// transfer deletes its pair; registering a new download prunes entries older
/// than `maximumAge` and keeps at most `maximumEntries`. Nothing is written into
/// the app bundle, so code signing and Sparkle delta baselines are unaffected.
struct UpdateDownloadPartialStore: Sendable {
    struct Metadata: Codable, Equatable, Sendable {
        var url: String
        var validator: String?
        var totalBytes: Int64?
        var contentType: String?
        var contentDisposition: String?
    }

    struct Entry: Sendable {
        let data: URL
        let metadata: URL
    }

    let directory: URL
    var maximumAge: TimeInterval = 7 * 24 * 60 * 60
    var maximumEntries = 3

    static func key(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func entry(for url: URL) -> Entry {
        let key = Self.key(for: url)
        return Entry(data: directory.appendingPathComponent("\(key).part"),
                     metadata: directory.appendingPathComponent("\(key).json"))
    }

    func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    /// Removes abandoned archives, never the entry about to be downloaded.
    func prune(keeping url: URL, now: Date = Date()) {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles) else { return }
        let keep = Self.key(for: url)
        var groups: [String: Date] = [:]
        for file in files where ["part", "json"].contains(file.pathExtension) {
            let key = file.deletingPathExtension().lastPathComponent
            guard key != keep else { continue }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            groups[key] = max(groups[key] ?? .distantPast, modified)
        }
        let ordered = groups.sorted { $0.value > $1.value }
        for (index, group) in ordered.enumerated()
        where index >= maximumEntries - 1 || now.timeIntervalSince(group.value) > maximumAge {
            try? manager.removeItem(at: directory.appendingPathComponent("\(group.key).part"))
            try? manager.removeItem(at: directory.appendingPathComponent("\(group.key).json"))
        }
    }
}

/// Destination of relayed bytes: the loopback socket in production, a buffer in tests.
protocol UpdateRelayClient: AnyObject, Sendable {
    /// Returns false once the reader is gone.
    func send(_ data: Data) -> Bool
    func close()
}

/// One loopback request: streams the stored prefix, then resumes the upstream
/// download with `Range`/`If-Range`, retrying transient failures while the
/// client is still inside its own idle timeout.
///
/// All mutable state is confined to `queue`; URLSession delivers delegate
/// callbacks on the same queue.
final class UpdateDownloadTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Policy: Sendable {
        /// Sparkle's loopback request fails after 60 seconds without data; give
        /// up first so the next attempt starts promptly and resumes.
        var noProgressBudget: TimeInterval = 45
        var retryDelays: [TimeInterval] = [1, 2, 4, 8]
        var requestTimeout: TimeInterval = 15
    }

    enum Outcome: Equatable, Sendable {
        case completed
        case failed(UpdateDownloadFailure?)
        case cancelled
    }

    typealias Scheduler = @Sendable (TimeInterval, DispatchQueue, @escaping @Sendable () -> Void) -> Void

    static let defaultScheduler: Scheduler = { delay, queue, work in
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private let upstream: URL
    private let userAgent: String?
    private let entry: UpdateDownloadPartialStore.Entry
    private let client: UpdateRelayClient
    private let policy: Policy
    private let now: @Sendable () -> TimeInterval
    private let schedule: Scheduler
    private let finished: @Sendable (Outcome, UpdateDownloadFailure?) -> Void
    let queue = DispatchQueue(label: "app.lithe.updates.relay.transfer")
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var file: FileHandle?
    private var metadata: UpdateDownloadPartialStore.Metadata
    private var storedBytes: Int64 = 0
    private var sentBytes: Int64 = 0
    private var headersSent = false
    private var failures = 0
    private var lastProgress: TimeInterval = 0
    private var lastFailure: UpdateDownloadFailure?
    private var done = false
    private var afterCancel: (() -> Void)?

    init(upstream: URL, userAgent: String?, entry: UpdateDownloadPartialStore.Entry,
         client: UpdateRelayClient, configuration: URLSessionConfiguration, policy: Policy = Policy(),
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         schedule: @escaping Scheduler = UpdateDownloadTransfer.defaultScheduler,
         finished: @escaping @Sendable (Outcome, UpdateDownloadFailure?) -> Void) {
        self.upstream = upstream
        self.userAgent = userAgent
        self.entry = entry
        self.client = client
        self.policy = policy
        self.now = now
        self.schedule = schedule
        self.finished = finished
        metadata = .init(url: upstream.absoluteString)
        super.init()
        let operations = OperationQueue()
        operations.maxConcurrentOperationCount = 1
        operations.underlyingQueue = queue
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.timeoutIntervalForRequest = policy.requestTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: operations)
    }

    func start() {
        queue.async { [self] in
            lastProgress = now()
            do {
                if let data = try? Data(contentsOf: entry.metadata),
                   let saved = try? JSONDecoder().decode(UpdateDownloadPartialStore.Metadata.self, from: data),
                   saved.url == upstream.absoluteString, saved.validator != nil {
                    metadata = saved
                } else {
                    try? FileManager.default.removeItem(at: entry.data)
                }
                if !FileManager.default.fileExists(atPath: entry.data.path) {
                    FileManager.default.createFile(atPath: entry.data.path, contents: nil,
                                                   attributes: [.posixPermissions: 0o600])
                }
                let handle = try FileHandle(forUpdating: entry.data)
                storedBytes = Int64(try handle.seekToEnd())
                if let total = metadata.totalBytes, storedBytes > total { try truncate(handle) }
                file = handle
            } catch {
                finish(.failed(nil))
                return
            }
            request()
        }
    }

    /// Stops the transfer and keeps the partial file. Safe from any queue except `queue`.
    func cancel() {
        queue.sync { if !done { finish(.cancelled) } }
    }

    private func request() {
        guard !done else { return }
        var request = URLRequest(url: upstream, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: policy.requestTimeout)
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        if storedBytes > 0 {
            guard let validator = metadata.validator else {
                guard sentBytes == 0, (try? file.map(truncate)) != nil else { return finish(.failed(lastFailure)) }
                return self.request()
            }
            request.setValue("bytes=\(storedBytes)-", forHTTPHeaderField: "Range")
            request.setValue(validator, forHTTPHeaderField: "If-Range")
        }
        task = session?.dataTask(with: request)
        task?.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard !done, dataTask === task else { return completionHandler(.cancel) }
        guard let http = response as? HTTPURLResponse else {
            lastFailure = .invalidResponse
            return cancelTask(completionHandler) { self.finish(.failed(self.lastFailure)) }
        }
        var total: Int64?
        switch http.statusCode {
        case 206:
            guard let range = Self.contentRange(http.value(forHTTPHeaderField: "Content-Range")),
                  range.start == storedBytes else {
                // The server ignored our offset; restart only if nothing was sent yet.
                return cancelTask(completionHandler) { self.restartFromZero() }
            }
            // Some CDNs (GitHub release assets among them) answer 206 even when If-Range
            // no longer matches, so a re-uploaded archive must be caught here.
            if Self.validator(of: http) != metadata.validator {
                guard sentBytes == 0 else {
                    try? file.map(truncate)
                    lastFailure = .invalidResponse
                    return cancelTask(completionHandler) { self.finish(.failed(self.lastFailure)) }
                }
                return cancelTask(completionHandler) { self.restartFromZero() }
            }
            total = range.total
        case 200..<300:
            if storedBytes > 0 {
                // A full response means the validator no longer matches.
                guard sentBytes == 0, (try? file.map(truncate)) != nil else {
                    try? file.map(truncate)
                    lastFailure = .invalidResponse
                    return cancelTask(completionHandler) { self.finish(.failed(self.lastFailure)) }
                }
            }
            total = http.expectedContentLength >= 0 ? storedBytes + http.expectedContentLength : nil
        case 416:
            return cancelTask(completionHandler) { self.restartFromZero() }
        default:
            let failure = UpdateDownloadFailure.httpStatus(http.statusCode)
            lastFailure = failure
            return cancelTask(completionHandler) {
                if failure.isRetryable { self.retry() } else { self.finish(.failed(failure)) }
            }
        }
        if headersSent, total != metadata.totalBytes {
            lastFailure = .invalidResponse
            return cancelTask(completionHandler) { self.finish(.failed(self.lastFailure)) }
        }
        metadata.validator = Self.validator(of: http)
        metadata.totalBytes = total
        if let type = http.value(forHTTPHeaderField: "Content-Type") { metadata.contentType = type }
        if let disposition = http.value(forHTTPHeaderField: "Content-Disposition") { metadata.contentDisposition = disposition }
        if let data = try? JSONEncoder().encode(metadata) { try? data.write(to: entry.metadata, options: .atomic) }
        if !headersSent {
            guard sendHeaders(), replayStoredBytes() else {
                return cancelTask(completionHandler) { self.finish(.cancelled) }
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !done, dataTask === task, let file else { return }
        do { try file.write(contentsOf: data) } catch {
            dataTask.cancel()
            return finish(.failed(nil))
        }
        storedBytes += Int64(data.count)
        lastProgress = now()
        failures = 0
        guard client.send(data) else {
            dataTask.cancel()
            return finish(.cancelled)
        }
        sentBytes += Int64(data.count)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !done, task === self.task else { return }
        self.task = nil
        if let afterCancel {
            self.afterCancel = nil
            return afterCancel()
        }
        if error == nil {
            if let total = metadata.totalBytes, storedBytes < total {
                lastFailure = .connectionFailed
                return retry()
            }
            return finish(.completed)
        }
        let failure = error.flatMap(UpdateDownloadFailure.init) ?? .connectionFailed
        lastFailure = failure
        failure.isRetryable ? retry() : finish(.failed(failure))
    }

    private func cancelTask(_ completionHandler: @Sendable (URLSession.ResponseDisposition) -> Void,
                            then next: @escaping () -> Void) {
        afterCancel = next
        completionHandler(.cancel)
    }

    private func restartFromZero() {
        guard sentBytes == 0, (try? file.map(truncate)) != nil else {
            lastFailure = .invalidResponse
            return finish(.failed(lastFailure))
        }
        failures += 1
        failures > policy.retryDelays.count ? finish(.failed(lastFailure ?? .invalidResponse)) : request()
    }

    private func retry() {
        failures += 1
        let delay = policy.retryDelays[min(failures, policy.retryDelays.count) - 1]
        guard failures <= policy.retryDelays.count,
              now() - lastProgress + delay + policy.requestTimeout <= policy.noProgressBudget else {
            return finish(.failed(lastFailure))
        }
        schedule(delay, queue) { [self] in request() }
    }

    private func truncate(_ handle: FileHandle) throws {
        try handle.truncate(atOffset: 0)
        storedBytes = 0
        metadata = .init(url: upstream.absoluteString)
        try? FileManager.default.removeItem(at: entry.metadata)
    }

    private func sendHeaders() -> Bool {
        var lines = ["HTTP/1.1 200 OK", "Connection: close", "Cache-Control: no-store"]
        if let total = metadata.totalBytes { lines.append("Content-Length: \(total)") }
        lines.append("Content-Type: \(metadata.contentType ?? "application/octet-stream")")
        if let disposition = metadata.contentDisposition { lines.append("Content-Disposition: \(disposition)") }
        headersSent = true
        return client.send(Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8))
    }

    private func replayStoredBytes() -> Bool {
        guard storedBytes > 0, let file else { return true }
        do {
            try file.seek(toOffset: 0)
            while sentBytes < storedBytes {
                let count = Int(min(storedBytes - sentBytes, 1 << 18))
                guard let chunk = try file.read(upToCount: count), !chunk.isEmpty else { return false }
                guard client.send(chunk) else { return false }
                sentBytes += Int64(chunk.count)
            }
            try file.seekToEnd()
            return true
        } catch { return false }
    }

    private func finish(_ outcome: Outcome) {
        guard !done else { return }
        done = true
        task?.cancel()
        task = nil
        try? file?.close()
        file = nil
        if outcome == .completed {
            try? FileManager.default.removeItem(at: entry.data)
            try? FileManager.default.removeItem(at: entry.metadata)
        }
        session?.invalidateAndCancel()
        session = nil
        // Record the cause before the client observes the closed connection.
        finished(outcome, outcome == .completed ? nil : lastFailure)
        client.close()
    }

    static func validator(of response: HTTPURLResponse) -> String? {
        response.value(forHTTPHeaderField: "ETag") ?? response.value(forHTTPHeaderField: "Last-Modified")
    }

    static func contentRange(_ value: String?) -> (start: Int64, total: Int64?)? {
        guard let value, value.lowercased().hasPrefix("bytes ") else { return nil }
        let spec = value.dropFirst(6).split(separator: "/", maxSplits: 1)
        guard spec.count == 2, let start = spec[0].split(separator: "-").first.flatMap({ Int64($0) }) else { return nil }
        return (start, Int64(spec[1]))
    }
}

/// Serves Sparkle's update archive downloads from 127.0.0.1 so interrupted
/// downloads resume instead of restarting, and so failures keep their cause.
///
/// Each registration gets an unguessable path token; the listener binds only to
/// the loopback interface and answers unknown paths with 404.
final class UpdateDownloadRelay: @unchecked Sendable {
    private let store: UpdateDownloadPartialStore
    private let configuration: URLSessionConfiguration
    private let policy: UpdateDownloadTransfer.Policy
    private let diagnosticSink: @Sendable (String) -> Void
    private let lock = NSLock()
    private let acceptQueue = DispatchQueue(label: "app.lithe.updates.relay.accept")
    private var listener: Int32 = -1
    private var port: UInt16 = 0
    private var acceptSource: DispatchSourceRead?
    private var routes: [(token: String, upstream: URL)] = []
    private var transfers: [String: (id: UUID, transfer: UpdateDownloadTransfer)] = [:]
    private var failure: UpdateDownloadFailure?

    init(store: UpdateDownloadPartialStore, configuration: URLSessionConfiguration = .default,
         policy: UpdateDownloadTransfer.Policy = .init(),
         diagnosticSink: @escaping @Sendable (String) -> Void = { NSLog("%@", $0) }) {
        self.store = store
        self.configuration = configuration
        self.policy = policy
        self.diagnosticSink = diagnosticSink
    }

    deinit { stop() }

    /// The cause of the most recent unfinished relayed download, if any.
    var lastFailure: UpdateDownloadFailure? { lock.withLock { failure } }

    /// Returns the loopback URL Sparkle should download instead, or nil when
    /// the relay cannot listen and Sparkle should download directly.
    func relayURL(for upstream: URL) -> URL? {
        guard ["http", "https"].contains(upstream.scheme?.lowercased() ?? "") else { return nil }
        do {
            try store.prepareDirectory()
            store.prune(keeping: upstream)
            let port = try listen()
            var bytes = [UInt8](repeating: 0, count: 16)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
            let token = bytes.map { String(format: "%02x", $0) }.joined()
            lock.withLock {
                failure = nil
                routes.append((token, upstream))
                if routes.count > 8 { routes.removeFirst(routes.count - 8) }
            }
            let name = upstream.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "update"
            return URL(string: "http://127.0.0.1:\(port)/\(token)/\(name)")
        } catch {
            diagnosticSink("Update download relay unavailable: \(error.localizedDescription)\n")
            return nil
        }
    }

    func stop() {
        let (source, active) = lock.withLock { () -> (DispatchSourceRead?, [UpdateDownloadTransfer]) in
            let source = acceptSource
            acceptSource = nil
            listener = -1
            port = 0
            defer { transfers.removeAll() }
            return (source, transfers.values.map(\.transfer))
        }
        source?.cancel()
        active.forEach { $0.cancel() }
    }

    private func listen() throws -> UInt16 {
        try lock.withLock {
            if listener >= 0 { return port }
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            var enable: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enable, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Bool in
                    bind(fd, pointer, length) == 0 && Darwin.listen(fd, 8) == 0
                        && getsockname(fd, pointer, &length) == 0
                }
            }
            guard bound else {
                let code = errno
                Darwin.close(fd)
                throw POSIXError(.init(rawValue: code) ?? .EIO)
            }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
            source.setEventHandler { [weak self] in self?.acceptPending(fd) }
            source.setCancelHandler { Darwin.close(fd) }
            source.resume()
            listener = fd
            port = UInt16(bigEndian: address.sin_port)
            acceptSource = source
            return port
        }
    }

    private func acceptPending(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { Darwin.close(client); return }
                self.serve(UpdateRelaySocket(client))
            }
        }
    }

    private func serve(_ socket: UpdateRelaySocket) {
        guard let head = socket.readRequestHead(),
              let request = Self.parseRequest(head),
              request.method == "GET",
              let upstream = lock.withLock({ routes.first { $0.token == request.token }?.upstream }) else {
            _ = socket.send(Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            return socket.close()
        }
        let key = UpdateDownloadPartialStore.key(for: upstream)
        // One writer per partial file: a new request replaces an abandoned one.
        lock.withLock { transfers.removeValue(forKey: key) }?.transfer.cancel()
        let id = UUID()
        let transfer = UpdateDownloadTransfer(upstream: upstream, userAgent: request.userAgent,
            entry: store.entry(for: upstream), client: socket, configuration: configuration, policy: policy) {
            [weak self] outcome, failure in
            guard let self else { return }
            self.lock.withLock {
                if outcome != .cancelled { self.failure = failure }
                if self.transfers[key]?.id == id { self.transfers.removeValue(forKey: key) }
            }
            if case .failed = outcome {
                self.diagnosticSink("Update download stopped; partial data kept for resume: \(String(describing: failure))\n")
            }
        }
        lock.withLock { transfers[key] = (id, transfer) }
        transfer.start()
    }

    struct Request: Equatable {
        let method: String
        let token: String
        let userAgent: String?
    }

    static func parseRequest(_ head: Data) -> Request? {
        guard let text = String(data: head, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return nil }
        let segments = parts[1].split(separator: "/", omittingEmptySubsequences: true)
        guard let token = segments.first, token.count == 32,
              token.allSatisfy({ $0.isHexDigit }) else { return nil }
        let agent = lines.dropFirst().first { $0.lowercased().hasPrefix("user-agent:") }
            .map { String($0.dropFirst("user-agent:".count)).trimmingCharacters(in: .whitespaces) }
        return Request(method: String(parts[0]), token: String(token), userAgent: agent)
    }
}

/// Blocking loopback connection. Send and receive timeouts bound every call,
/// so a reader that stops consuming cannot hold a transfer forever.
final class UpdateRelaySocket: UpdateRelayClient, @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false

    init(_ fd: Int32) {
        self.fd = fd
        var enable: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enable, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
    }

    deinit { close() }

    func readRequestHead(limit: Int = 16 * 1024) -> Data? {
        var head = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let terminator = Data("\r\n\r\n".utf8)
        while head.count < limit {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            head.append(contentsOf: buffer[0..<count])
            if let end = head.range(of: terminator) { return head[..<end.lowerBound] }
        }
        return nil
    }

    func send(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.send(fd, base + offset, raw.count - offset, 0)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }

    func close() {
        let shouldClose = lock.withLock { () -> Bool in
            defer { closed = true }
            return !closed
        }
        guard shouldClose else { return }
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }
}
