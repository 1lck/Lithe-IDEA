import Foundation

/// Typed `remote.*` commands. Rust Core runs OpenSSH and
/// relays its questions; this adapter only translates payloads and events.
struct RustRemoteConnectionOperations: RemoteConnectionProbing, RemoteSessionConnecting, RemoteWorkspaceTransport {
    let core: RustCoreBridge

    func probe(
        _ target: RemoteSSHTarget,
        onPrompt: @escaping @Sendable (RemoteAuthenticationPrompt) -> Void
    ) async -> Result<RemoteProbeResult, RemoteProbeFailure> {
        await run("remote.probe", payload: ProbePayload(connection: target), onPrompt: onPrompt)
    }

    func connect(
        _ target: RemoteSSHTarget,
        servers: RemoteServerBundle,
        onPrompt: @escaping @Sendable (RemoteAuthenticationPrompt) -> Void
    ) async -> Result<RemoteConnectResult, RemoteProbeFailure> {
        await run(
            "remote.connect",
            payload: ConnectPayload(connection: target, servers: servers.builds, serverVersion: servers.version),
            onPrompt: onPrompt
        )
    }

    func readDirectory(_ path: String, session id: String) async -> Result<[RemoteDirectoryEntry], RemoteProbeFailure> {
        struct Listing: Decodable { let entries: [RemoteDirectoryEntry] }
        let result: Result<Listing, RemoteProbeFailure> = await run(
            "remote.readDir", payload: ["sessionId": id, "path": path], onPrompt: { _ in }
        )
        return result.map(\.entries)
    }

    func disconnect(session id: String) async {
        struct Closed: Decodable { let closed: Bool }
        let _: Result<Closed, RemoteProbeFailure> = await run(
            "remote.disconnect", payload: ["sessionId": id], onPrompt: { _ in }
        )
    }

    /// Runs one blocking Core command off the caller's thread. Cancelling
    /// the calling task cancels the command.
    private func run<Payload: Encodable & Sendable, Value: Decodable & Sendable>(
        _ command: String,
        payload: Payload,
        onPrompt: @escaping @Sendable (RemoteAuthenticationPrompt) -> Void
    ) async -> Result<Value, RemoteProbeFailure> {
        let operationID = UUID().uuidString
        let cancellation = RustCoreCancellation(core: core, operationID: operationID)
        let core = core
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // The C call blocks until OpenSSH is done, which includes the
                // time the user takes to answer prompts.
                DispatchQueue.global(qos: .userInitiated).async {
                    let result: Result<Value, RustCoreBridge.CoreCallError> = core.executeResult(
                        command: command,
                        payload: payload,
                        operationID: operationID,
                        onEvent: { event in
                            cancellation.receive(event)
                            if let prompt = Self.prompt(from: event) { onPrompt(prompt) }
                        }
                    )
                    continuation.resume(returning: result.mapError {
                        RemoteProbeFailure(code: $0.code, message: $0.message)
                    })
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    func answer(_ requestID: String, with answer: String?) -> Bool {
        let result: Result<Accepted, RustCoreBridge.CoreCallError> = core.executeResult(
            command: "remote.authRespond",
            payload: Reply(requestId: requestID, answer: answer)
        )
        return (try? result.get().accepted) ?? false
    }

    // MARK: Workspace transport

    func listDirectory(_ path: String, session id: String) throws -> [RemoteDirectoryEntry] {
        struct Listing: Decodable { let entries: [RemoteDirectoryEntry] }
        let listing: Listing = try blocking("remote.readDir", payload: ["sessionId": id, "path": path])
        return listing.entries
    }

    func readFile(_ path: String, session id: String) throws -> (data: Data, version: RemoteFileVersion) {
        struct Content: Decodable { let data: String; let size: Int64; let modifiedMs: Int64? }
        let content: Content = try blocking("remote.readFile", payload: ["sessionId": id, "path": path])
        guard let data = Data(base64Encoded: content.data) else {
            throw RemoteProbeFailure(code: "invalidResponse", message: "The host sent unreadable file content.")
        }
        return (data, RemoteFileVersion(size: content.size, modifiedMs: content.modifiedMs))
    }

    func writeFile(
        _ data: Data, to path: String, expected: RemoteFileVersion?, session id: String
    ) throws -> RemoteWriteOutcome {
        struct Payload: Encodable {
            let sessionId: String
            let path: String
            let data: String
            let expected: RemoteFileVersion?
        }
        struct Result: Decodable { let status: String; let size: Int64?; let modifiedMs: Int64? }
        let result: Result = try blocking(
            "remote.writeFile",
            payload: Payload(sessionId: id, path: path, data: data.base64EncodedString(), expected: expected)
        )
        guard result.status == "saved", let size = result.size else { return .conflict }
        return .saved(RemoteFileVersion(size: size, modifiedMs: result.modifiedMs))
    }

    private func blocking<Payload: Encodable, Value: Decodable>(_ command: String, payload: Payload) throws -> Value {
        let result: Result<Value, RustCoreBridge.CoreCallError> = core.executeResult(command: command, payload: payload)
        return try result.mapError { RemoteProbeFailure(code: $0.code, message: $0.message) }.get()
    }

    private static func prompt(from event: String) -> RemoteAuthenticationPrompt? {
        struct Envelope: Decodable { let type: String }
        let data = Data(event.utf8)
        guard (try? JSONDecoder().decode(Envelope.self, from: data))?.type == "authentication" else { return nil }
        return try? JSONDecoder().decode(RemoteAuthenticationPrompt.self, from: data)
    }

    private struct ProbePayload: Encodable, Sendable { let connection: RemoteSSHTarget }

    private struct ConnectPayload: Encodable, Sendable {
        let connection: RemoteSSHTarget
        let servers: [RemoteServerBuild]
        let serverVersion: String
    }

    private struct Reply: Encodable {
        let requestId: String
        let answer: String?

        // `null` is the explicit "decline" answer; it must not be omitted.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(requestId, forKey: .requestId)
            try container.encode(answer, forKey: .answer)
        }

        private enum CodingKeys: String, CodingKey { case requestId, answer }
    }

    private struct Accepted: Decodable { let accepted: Bool }
}
