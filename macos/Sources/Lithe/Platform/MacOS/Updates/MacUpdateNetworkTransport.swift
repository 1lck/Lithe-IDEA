import Foundation

struct UpdateHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    func header(named name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

protocol UpdateNetworkTransport: Sendable {
    func fetch(_ request: URLRequest) async throws -> UpdateHTTPResponse
    /// Returns a temporary file whose ownership transfers to the caller.
    func download(
        _ request: URLRequest,
        progress: @escaping @Sendable (UpdateDownloadProgress) async -> Void
    ) async throws -> URL
}

enum UpdateTransportError: Error {
    case invalidResponse
}

final class MacUpdateNetworkTransport: UpdateNetworkTransport, @unchecked Sendable {
    private let session: URLSession
    private let fileManager: FileManager

    init(session: URLSession = .shared, fileManager: FileManager = .default) {
        self.session = session
        self.fileManager = fileManager
    }

    func fetch(_ request: URLRequest) async throws -> UpdateHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw UpdateTransportError.invalidResponse
        }
        return UpdateHTTPResponse(
            statusCode: response.statusCode,
            headers: response.allHeaderFields.reduce(into: [:]) { headers, entry in
                headers[String(describing: entry.key)] = String(describing: entry.value)
            },
            body: data
        )
    }

    func download(
        _ request: URLRequest,
        progress: @escaping @Sendable (UpdateDownloadProgress) async -> Void
    ) async throws -> URL {
        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateTransportError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw UpdateCheckError.httpStatus(httpResponse.statusCode)
        }

        let totalBytes = response.expectedContentLength > 0
            ? response.expectedContentLength
            : nil
        let destination = fileManager.temporaryDirectory
            .appendingPathComponent("lithe-update-\(UUID().uuidString).dmg")
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw UpdateCheckError.downloadFailed
        }

        do {
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }

            var buffer = Data()
            buffer.reserveCapacity(64 * 1024)
            var downloadedBytes: Int64 = 0
            var lastProgressUpdate = Date.distantPast

            for try await byte in bytes {
                buffer.append(byte)
                downloadedBytes += 1

                if buffer.count >= 64 * 1024 {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                    let now = Date()
                    if now.timeIntervalSince(lastProgressUpdate) >= 0.05 {
                        lastProgressUpdate = now
                        await progress(UpdateDownloadProgress(
                            downloadedBytes: downloadedBytes,
                            totalBytes: totalBytes
                        ))
                    }
                }
            }

            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
            }
            await progress(UpdateDownloadProgress(
                downloadedBytes: downloadedBytes,
                totalBytes: totalBytes
            ))
            return destination
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }
}
