import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Typed `remote.*` commands. Rust Core runs OpenSSH and
/// relays its questions; this adapter only translates payloads and events.
struct RustRemoteConnectionOperations: RemoteConnectionProbing, RemoteSessionConnecting, RemoteWorkspaceTransport, RemoteTerminalConnecting {
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

    /// Closes every open connection and waits for their OpenSSH trees to end.
    /// Application exit calls this; it blocks, so it never runs on a UI path.
    func closeAllBlocking() {
        struct Closed: Decodable { let closed: Int }
        let _: Result<Closed, RustCoreBridge.CoreCallError> = core.executeResult(
            command: "remote.closeAll", payload: [String: String]()
        )
    }

    /// Runs one blocking Core command off the caller's thread. Cancelling
    /// the calling task cancels the command.
    func run<Payload: Encodable & Sendable, Value: Decodable & Sendable>(
        _ command: String,
        payload: Payload,
        onPrompt: @escaping @Sendable (RemoteAuthenticationPrompt) -> Void,
        onEvent: @escaping @Sendable (String) -> Void = { _ in }
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
                            onEvent(event)
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

    func mutate(_ mutation: RemoteFileMutation, session: String) throws {
        let method: String
        let params: [String: ToolingJSONValue]
        switch mutation {
        case .createDirectory(let path, let recursive):
            method = "fs.createDir"
            params = ["path": .string(path), "recursive": .bool(recursive)]
        case .copy(let from, let to):
            method = "fs.copy"
            params = ["from": .string(from), "to": .string(to), "recursive": .bool(true)]
        case .move(let from, let to):
            method = "fs.rename"
            params = ["from": .string(from), "to": .string(to)]
        case .remove(let path):
            method = "fs.remove"
            params = ["path": .string(path), "recursive": .bool(true)]
        case .trash(let path):
            method = "fs.trash"
            params = ["path": .string(path)]
        }
        let value: ToolingJSONValue = try blocking(
            "remote.hostRequest", payload: HostPayload(sessionId: session, method: method, params: params)
        )
        if case .object(let result) = value,
           case .number(let skipped) = result["skippedSpecialFiles"], skipped > 0 {
            throw RemoteProbeFailure(code: "copy_incomplete", message: L10n.string("Some special files could not be copied"))
        }
    }

    func watch(
        root: String, session: String,
        onEvent: @escaping @Sendable (RemoteWatchEvent) -> Void
    ) async throws {
        struct Parameters: Encodable, Sendable { let root: String }
        struct Payload: Encodable, Sendable { let sessionId: String; let params: Parameters }
        struct Event: Decodable {
            struct Parameters: Decodable {
                struct Change: Decodable { let path: String }
                let changes: [Change]?
                let overflow: Bool?
                let code: String?
            }
            let type: String
            let event: String?
            let params: Parameters?
        }
        let result: Result<ToolingJSONValue, RemoteProbeFailure> = await run(
            "remote.runWatch", payload: Payload(sessionId: session, params: Parameters(root: root)),
            onPrompt: { _ in }, onEvent: { raw in
                guard let event = try? JSONDecoder().decode(Event.self, from: Data(raw.utf8)),
                      event.type == "remote" else { return }
                switch event.event {
                case "watch.started": onEvent(.started)
                case "watch.changed":
                    onEvent(.changed(paths: event.params?.changes?.map(\.path) ?? [], overflow: event.params?.overflow ?? true))
                case "watch.error": onEvent(.invalidated(rootRemoved: event.params?.code == "ROOT_REMOVED"))
                default: break
                }
            }
        )
        _ = try result.get()
    }

    func runTerminal(
        _ request: RemoteTerminalRequest, session: String,
        onEvent: @escaping @Sendable (RemoteTerminalEvent) -> Void
    ) async -> Result<Void, RemoteProbeFailure> {
        struct Payload: Encodable, Sendable { let sessionId: String; let params: RemoteTerminalRequest }
        struct Exit: Decodable, Sendable { let exitCode: Int32? }
        struct Event: Decodable {
            struct Parameters: Decodable {
                let terminalId: UInt64?
                let pid: Int32?
                let data: String?
                let exitCode: Int32?
            }
            let type: String
            let event: String?
            let params: Parameters?
        }
        let result: Result<Exit, RemoteProbeFailure> = await run(
            "remote.runTerminal", payload: Payload(sessionId: session, params: request),
            onPrompt: { _ in }, onEvent: { raw in
                guard let event = try? JSONDecoder().decode(Event.self, from: Data(raw.utf8)),
                      event.type == "remote", let params = event.params else { return }
                switch event.event {
                case "terminal.started":
                    if let id = params.terminalId, let pid = params.pid { onEvent(.started(id: id, pid: pid)) }
                case "terminal.output":
                    if let encoded = params.data, let data = Data(base64Encoded: encoded) { onEvent(.output(data)) }
                case "terminal.exit": onEvent(.exited(params.exitCode))
                default: break
                }
            }
        )
        return result.map { _ in () }
    }

    func writeTerminal(_ data: Data, id: UInt64, session: String) async throws {
        struct Parameters: Encodable, Sendable { let terminalId: UInt64; let data: String }
        try await terminalControl("terminal.write", params: Parameters(terminalId: id, data: data.base64EncodedString()), session: session)
    }

    func resizeTerminal(id: UInt64, columns: UInt16, rows: UInt16, session: String) async throws {
        struct Parameters: Encodable, Sendable { let terminalId: UInt64; let columns: UInt16; let rows: UInt16 }
        try await terminalControl("terminal.resize", params: Parameters(terminalId: id, columns: columns, rows: rows), session: session)
    }

    private struct HostPayload<Parameters: Encodable & Sendable>: Encodable, Sendable {
        let sessionId: String
        let method: String
        let params: Parameters
    }

    private func terminalControl<Parameters: Encodable & Sendable>(
        _ method: String, params: Parameters, session: String
    ) async throws {
        // Control methods return JSON null; the JSON value decoder preserves
        // this successful response without requiring a synthetic data object.
        let payload = HostPayload(sessionId: session, method: method, params: params)
        let result: Result<ToolingJSONValue, RemoteProbeFailure> = await run(
            "remote.hostRequest", payload: payload, onPrompt: { _ in }
        )
        _ = try result.get()
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
