import Foundation
import LitheCoreContracts

/// The platform owns process creation, ordered pipe writes and process-tree cleanup.
@MainActor
package protocol ExtensionHostTransport: AnyObject {
    func send(_ data: Data) async throws
}

package struct ExtensionHostFailure: Error, Codable, Sendable, Equatable {
    package let code: String
    package let message: String
    package let details: ToolingJSONValue

    package init(_ code: String, _ message: String, details: ToolingJSONValue = .null) {
        self.code = code
        self.message = message
        self.details = details
    }
}

/// Lithe's side of the v1 NDJSON connection. Theia types never cross this boundary.
/// Feed stdout bytes in order, including partial UTF-8 sequences; stderr is separate.
@MainActor
package final class ExtensionHostConnection {
    package typealias RequestHandler = @MainActor (String, ToolingJSONValue) async throws -> ToolingJSONValue
    package var onRequest: RequestHandler?
    package var onNotification: (@MainActor (String, ToolingJSONValue) -> Void)?
    package var onDiagnostic: (@MainActor (String) -> Void)?

    private struct Envelope: Codable {
        let kind: String
        var id: Int?
        var method: String?
        var params: ToolingJSONValue?
        var result: ToolingJSONValue?
        var error: ExtensionHostFailure?
    }

    private struct Pending {
        let continuation: CheckedContinuation<ToolingJSONValue, Error>
        let deadline: Task<Void, Never>
    }

    package var onClosed: (() -> Void)?

    private let transport: any ExtensionHostTransport
    private var nextID = 1
    private var buffered = Data()
    private var pending: [Int: Pending] = [:]
    private var incoming: [Int: Task<Void, Never>] = [:]
    private var closed = false

    package init(transport: any ExtensionHostTransport) {
        self.transport = transport
    }

    package func request(
        _ method: String,
        params: ToolingJSONValue = .null,
        timeout: Duration = .seconds(30)
    ) async throws -> ToolingJSONValue {
        try Task.checkCancellation()
        guard !closed else { throw ExtensionHostFailure("shuttingDown", "Extension host connection is closed.") }
        let id = nextID
        nextID += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let deadline = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    await self?.cancelOutgoing(id, code: "timeout")
                }
                pending[id] = Pending(continuation: continuation, deadline: deadline)
                Task { [weak self] in
                    guard let self, self.pending[id] != nil else { return }
                    do {
                        try await self.send(Envelope(kind: "request", id: id, method: method, params: params))
                    } catch {
                        self.finish(id, result: .failure(error))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in await self?.cancelOutgoing(id, code: "cancelled") }
        }
    }

    package func notify(_ method: String, params: ToolingJSONValue) async throws {
        try await send(Envelope(kind: "notification", method: method, params: params))
    }

    package func receive(_ data: Data) {
        guard !closed else { return }
        buffered.append(data)
        while let newline = buffered.firstIndex(of: 10) {
            let line = buffered[..<newline]
            buffered.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            do {
                let envelope = try JSONDecoder().decode(Envelope.self, from: line)
                dispatch(envelope)
            } catch {
                onDiagnostic?("Discarded malformed extension host protocol message.")
            }
        }
    }

    /// The owner calls this on EOF, process failure, module disable or workspace close.
    /// Pending callers fail immediately; cancelled handlers cannot publish late results.
    package func close() {
        closeWithError(ExtensionHostFailure("shuttingDown", "Extension host connection closed."))
    }

    private func closeWithError(_ error: Error) {
        guard !closed else { return }
        closed = true
        onClosed?()
        buffered.removeAll()
        let requests = pending
        pending.removeAll()
        for value in requests.values {
            value.deadline.cancel()
            value.continuation.resume(throwing: error)
        }
        let handlers = incoming
        incoming.removeAll()
        for task in handlers.values { task.cancel() }
    }

    private func dispatch(_ message: Envelope) {
        switch message.kind {
        case "response":
            guard let id = message.id else { return }
            if let error = message.error { finish(id, result: .failure(error)) }
            else { finish(id, result: .success(message.result ?? .null)) }
        case "notification":
            guard let method = message.method else { return }
            onNotification?(method, message.params ?? .null)
        case "request":
            guard let id = message.id, id > 0, let method = message.method else { return }
            guard incoming[id] == nil else {
                onDiagnostic?("Discarded duplicate extension host request ID.")
                return
            }
            incoming[id] = Task { [weak self] in
                guard let self else { return }
                let response: Envelope
                do {
                    guard let handler = self.onRequest else {
                        throw ExtensionHostFailure("methodNotFound", "Lithe does not implement \(method).")
                    }
                    let result = try await handler(method, message.params ?? .null)
                    response = Envelope(kind: "response", id: id, result: result)
                } catch {
                    let failure = error as? ExtensionHostFailure
                        ?? ExtensionHostFailure("internalError", error.localizedDescription)
                    response = Envelope(kind: "response", id: id, error: failure)
                }
                // Cancellation removes the entry before cancelling its task.
                guard !Task.isCancelled, self.incoming.removeValue(forKey: id) != nil else { return }
                await self.sendResponse(response)
            }
        case "cancel":
            guard let id = message.id, let task = incoming.removeValue(forKey: id) else { return }
            task.cancel()
            Task { [weak self] in
                await self?.sendResponse(Envelope(kind: "response", id: id,
                    error: ExtensionHostFailure("cancelled", "Extension host cancelled the request.")))
            }
        default:
            onDiagnostic?("Discarded unknown extension host message kind.")
        }
    }

    private func finish(_ id: Int, result: Result<ToolingJSONValue, Error>) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.deadline.cancel()
        request.continuation.resume(with: result)
    }

    private func cancelOutgoing(_ id: Int, code: String) async {
        guard pending[id] != nil else { return }
        finish(id, result: .failure(ExtensionHostFailure(code, "Extension host request \(code).")))
        await sendResponse(Envelope(kind: "cancel", id: id))
    }

    private func sendResponse(_ envelope: Envelope) async {
        guard !closed else { return }
        do { try await send(envelope) }
        catch {
            onDiagnostic?("Extension host transport write failed: \(error.localizedDescription)")
            close()
        }
    }

    private func send(_ envelope: Envelope) async throws {
        guard !closed else { throw ExtensionHostFailure("shuttingDown", "Extension host connection is closed.") }
        var data = try JSONEncoder().encode(envelope)
        data.append(10)
        do { try await transport.send(data) }
        catch {
            // A broken pipe invalidates every outstanding request and document mirror.
            closeWithError(error)
            throw error
        }
    }
}
