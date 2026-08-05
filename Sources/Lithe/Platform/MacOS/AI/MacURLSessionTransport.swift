import Foundation
import Network

struct MacURLSessionTransport: AIHTTPTransport {
    func send(_ request: AIHTTPRequest) async throws -> AIHTTPResponse {
        switch request.url.scheme?.lowercased() {
        case "http":
            guard request.allowsInsecureHTTP else {
                throw AIHTTPTransportError.insecureHTTPNotAllowed
            }
            return try await MacPlainHTTPTransport(request: request).send()
        default:
            var urlRequest = URLRequest(url: request.url)
            urlRequest.httpMethod = "POST"
            urlRequest.httpBody = request.body
            urlRequest.timeoutInterval = request.timeout
            request.headers.forEach { key, value in
                urlRequest.setValue(value, forHTTPHeaderField: key)
            }

            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AIHTTPTransportError.invalidResponse
            }
            return AIHTTPResponse(statusCode: httpResponse.statusCode, body: data)
        }
    }
}

private final class MacPlainHTTPTransport: @unchecked Sendable {
    private let request: AIHTTPRequest

    init(request: AIHTTPRequest) {
        self.request = request
    }

    func send() async throws -> AIHTTPResponse {
        let connection = MacPlainHTTPConnection(request: request)
        return try await connection.send()
    }
}

private final class MacPlainHTTPConnection: @unchecked Sendable {
    private let request: AIHTTPRequest
    private let connection: NWConnection
    private let requestData: Data
    private let lock = NSLock()
    private var responseData = Data()
    private var continuation: CheckedContinuation<AIHTTPResponse, Error>?
    private var timeoutWorkItem: DispatchWorkItem?
    private var hasFinished = false

    init(request: AIHTTPRequest) {
        self.request = request
        let port = UInt16(request.url.port ?? 80)
        let host = request.url.host ?? ""
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? .http,
            using: .tcp
        )
        requestData = Self.makeRequestData(request)
    }

    func send() async throws -> AIHTTPResponse {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                start(continuation)
            }
        }, onCancel: {
            finish(.failure(CancellationError()))
        })
    }

    private func start(_ continuation: CheckedContinuation<AIHTTPResponse, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendRequest()
            case .failed:
                self.finish(.failure(AIHTTPTransportError.connectionFailed))
            case .cancelled:
                self.finish(.failure(CancellationError()))
            default:
                break
            }
        }

        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.finish(.failure(AIHTTPTransportError.timedOut))
        }
        lock.lock()
        self.timeoutWorkItem = timeoutWorkItem
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + request.timeout,
            execute: timeoutWorkItem
        )
        connection.start(queue: DispatchQueue.global(qos: .userInitiated))
    }

    private func sendRequest() {
        connection.send(content: requestData, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                self.finish(.failure(AIHTTPTransportError.connectionFailed))
                return
            }
            self.receiveResponse()
        })
    }

    private func receiveResponse() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                self.finish(.failure(AIHTTPTransportError.connectionFailed))
                return
            }
            if let data {
                self.responseData.append(data)
            }

            do {
                if let response = try self.parseResponse(isComplete: isComplete) {
                    self.finish(.success(response))
                    return
                }
            } catch {
                self.finish(.failure(error))
                return
            }

            if isComplete {
                self.finish(.failure(AIHTTPTransportError.invalidResponse))
            } else {
                self.receiveResponse()
            }
        }
    }

    private func parseResponse(isComplete: Bool) throws -> AIHTTPResponse? {
        let bytes = [UInt8](responseData)
        guard let headerRange = Self.firstRange(
            of: [13, 10, 13, 10],
            in: bytes
        ) else {
            return nil
        }

        let headerText = String(decoding: bytes[..<headerRange.lowerBound], as: UTF8.self)
        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first,
              let statusCode = statusLine.split(separator: " ").dropFirst().first,
              let status = Int(statusCode) else {
            throw AIHTTPTransportError.malformedResponse
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let bodyStart = headerRange.upperBound
        let bodyBytes = Array(bytes.dropFirst(bodyStart))
        if let contentLength = headers["content-length"].flatMap({ Int($0) }) {
            guard bodyBytes.count >= contentLength else { return nil }
            return AIHTTPResponse(
                statusCode: status,
                body: Data(bodyBytes.prefix(contentLength))
            )
        }

        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let body = Self.decodeChunkedBody(bodyBytes) else { return nil }
            return AIHTTPResponse(statusCode: status, body: body)
        }

        guard isComplete else { return nil }
        return AIHTTPResponse(statusCode: status, body: Data(bodyBytes))
    }

    private func finish(_ result: Result<AIHTTPResponse, Error>) {
        lock.lock()
        guard !hasFinished else {
            lock.unlock()
            return
        }
        hasFinished = true
        let continuation = self.continuation
        let timeoutWorkItem = self.timeoutWorkItem
        self.continuation = nil
        lock.unlock()

        timeoutWorkItem?.cancel()
        connection.cancel()
        continuation?.resume(with: result)
    }

    private static func makeRequestData(_ request: AIHTTPRequest) -> Data {
        let url = request.url
        let path = url.path.isEmpty ? "/" : url.path
        let target = url.query.map { "\(path)?\($0)" } ?? path
        let rawHost = url.host ?? ""
        let host = rawHost.contains(":") ? "[\(rawHost)]" : rawHost
        let hostHeader = url.port.map { "\(host):\($0)" } ?? host

        var lines = [
            "POST \(target) HTTP/1.1",
            "Host: \(hostHeader)",
            "Connection: close",
            "Content-Length: \(request.body.count)"
        ]
        for (name, value) in request.headers {
            let lowercasedName = name.lowercased()
            if lowercasedName == "host"
                || lowercasedName == "connection"
                || lowercasedName == "content-length" {
                continue
            }
            lines.append("\(name): \(value)")
        }

        var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        data.append(request.body)
        return data
    }

    private static func decodeChunkedBody(_ bytes: [UInt8]) -> Data? {
        var cursor = 0
        var body = Data()

        while true {
            guard let lineEnd = firstRange(of: [13, 10], in: bytes, from: cursor) else {
                return nil
            }
            let sizeText = String(decoding: bytes[cursor..<lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
                .first
            guard let sizeText,
                  let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else {
                return nil
            }
            cursor = lineEnd.upperBound

            if size == 0 {
                if firstRange(of: [13, 10], in: bytes, from: cursor)?.lowerBound == cursor {
                    return body
                }
                return firstRange(of: [13, 10, 13, 10], in: bytes, from: cursor) == nil ? nil : body
            }

            guard bytes.count >= cursor + size + 2,
                  Array(bytes[(cursor + size)..<(cursor + size + 2)]) == [13, 10] else {
                return nil
            }
            body.append(contentsOf: bytes[cursor..<(cursor + size)])
            cursor += size + 2
        }
    }

    private static func firstRange(
        of needle: [UInt8],
        in bytes: [UInt8],
        from start: Int = 0
    ) -> Range<Int>? {
        guard !needle.isEmpty, bytes.count >= needle.count else { return nil }
        let end = bytes.count - needle.count
        guard start <= end else { return nil }
        for index in start...end where Array(bytes[index..<(index + needle.count)]) == needle {
            return index..<(index + needle.count)
        }
        return nil
    }
}

enum AIHTTPTransportError: LocalizedError, Sendable {
    case invalidResponse
    case insecureHTTPNotAllowed
    case connectionFailed
    case timedOut
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The AI service returned an invalid HTTP response."
        case .insecureHTTPNotAllowed:
            return "HTTP requests are disabled for this AI provider."
        case .connectionFailed:
            return "The AI service connection failed."
        case .timedOut:
            return "The AI service request timed out."
        case .malformedResponse:
            return "The AI service returned a malformed HTTP response."
        }
    }
}
