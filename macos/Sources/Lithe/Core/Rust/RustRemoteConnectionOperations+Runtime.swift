import CryptoKit
import Foundation
import LitheCoreContracts

extension RustRemoteConnectionOperations: RemoteRuntimeProbing, RemoteShellProbing, RemoteBuildFileProbing, RemoteBuildStateAccess {
    private struct HostProbe<Parameters: Encodable>: Encodable {
        let sessionId: String
        let method: String
        let params: Parameters
    }

    private func runtimeRequest<Parameters: Encodable, Value: Decodable>(
        _ method: String, params: Parameters, session: String
    ) throws -> Value {
        let result: Result<Value, RustCoreBridge.CoreCallError> = core.executeResult(
            command: "remote.hostRequest", payload: HostProbe(sessionId: session, method: method, params: params),
            timeoutMilliseconds: 15_000
        )
        return try result.get()
    }

    func runtimeEnvironment(session: String) throws -> [String: String] {
        struct Environment: Decodable { let environment: [String: String] }
        let value: Environment = try runtimeRequest("environment.resolve", params: [String: String](), session: session)
        return value.environment
    }

    func shellEnvironment(session: String) throws -> [String: String] {
        struct Environment: Decodable { let environment: [String: String] }
        let value: Environment = try runtimeRequest("environment.resolve", params: ["refresh": true], session: session)
        return value.environment
    }

    func registeredShells(session: String) throws -> String {
        struct Content: Decodable { let data: String; let eof: Bool }
        struct Parameters: Encodable { let path = "/etc/shells"; let length = 65_536 }
        do {
            let value: Content = try runtimeRequest("fs.readFile", params: Parameters(), session: session)
            guard value.eof, let bytes = Data(base64Encoded: value.data), bytes.count <= 65_536,
                  let text = String(data: bytes, encoding: .utf8) else {
                throw RustCoreBridge.CoreCallError(code: "parse_failed", message: "Invalid registered shells snapshot", details: nil)
            }
            return text
        } catch let error as RustCoreBridge.CoreCallError where error.code == "workspace_not_found" {
            return ""
        }
    }

    func runtimeRequirements(_ root: String, session: String) throws -> ToolingJSONValue {
        struct Parameters: Encodable { let path: String; let length = 262_144 }
        struct Content: Decodable {
            struct Metadata: Decodable { let size: Int }
            let data: String
            let metadata: Metadata
            let eof: Bool
        }
        do {
            let value: Content = try runtimeRequest(
                "fs.readFile", params: Parameters(path: root + "/.lithe/toolchains/requirements.json"), session: session
            )
            guard value.eof, value.metadata.size <= 262_144, let data = Data(base64Encoded: value.data) else {
                throw RustCoreBridge.CoreCallError(code: "parse_failed", message: "Invalid toolchain requirements snapshot", details: nil)
            }
            return try JSONDecoder().decode(ToolingJSONValue.self, from: data)
        } catch let error as RustCoreBridge.CoreCallError where error.code == "workspace_not_found" {
            return .object(["version": .integer(1), "toolchains": .object([:])])
        }
    }

    func runtimeDirectory(_ path: String, session: String) throws -> [RemoteDirectoryEntry] {
        struct Listing: Decodable { let entries: [RemoteDirectoryEntry] }
        let value: Listing = try runtimeRequest("fs.readDir", params: ["path": path], session: session)
        return value.entries
    }

    func runtimeRealPath(_ path: String, session: String) throws -> String {
        struct Resolved: Decodable { let path: String }
        let value: Resolved = try runtimeRequest("fs.realPath", params: ["path": path], session: session)
        return value.path
    }

    func runtimeExecutable(_ path: String, session: String) throws -> Bool {
        struct Metadata: Decodable { let kind: String; let mode: UInt32 }
        let resolved = try runtimeRealPath(path, session: session)
        let value: Metadata = try runtimeRequest("fs.stat", params: ["path": resolved], session: session)
        return value.kind == "file" && value.mode & 0o111 != 0
    }

    func buildFileMetadata(_ path: String, session: String) throws -> RemoteBuildFileMetadata? {
        struct Metadata: Decodable { let kind: String; let mode: UInt32 }
        do {
            let resolved = try runtimeRealPath(path, session: session)
            let value: Metadata = try runtimeRequest("fs.stat", params: ["path": resolved], session: session)
            return RemoteBuildFileMetadata(isExecutable: value.kind == "file" && value.mode & 0o111 != 0)
        } catch let error as RustCoreBridge.CoreCallError where error.code == "workspace_not_found" {
            return nil
        }
    }

    func prepareBuildState(pluginID: String, buildSystemID: String, workspacePath: String, session: String) throws -> String {
        let environment = try runtimeEnvironment(session: session)
        guard let home = environment["HOME"], home.hasPrefix("/"), !home.contains("\0") else {
            throw CocoaError(.fileNoSuchFile)
        }
        func digest(_ value: String) -> String {
            SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let path = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".lithe-server/state/plugins")
            .appendingPathComponent(digest(pluginID))
            .appendingPathComponent("build-systems")
            .appendingPathComponent(digest(buildSystemID))
            .appendingPathComponent("workspaces")
            .appendingPathComponent(digest(workspacePath)).path
        let _: ToolingJSONValue = try runtimeRequest("fs.createDir", params: ["path": ToolingJSONValue.string(path), "recursive": .bool(true), "mode": .integer(0o700)], session: session)
        return path
    }

    func removeBuildOutputFile(_ path: String, session: String) throws {
        do {
            let _: ToolingJSONValue = try runtimeRequest("fs.remove", params: ["path": ToolingJSONValue.string(path), "recursive": .bool(false)], session: session)
        } catch let error as RustCoreBridge.CoreCallError where error.code == "workspace_not_found" {
            // A command may finish without writing its optional output file.
        }
    }

    func runtimeVersion(_ executable: String, session: String) throws -> String {
        struct Spawn: Encodable {
            let processId = 0
            let argv: [String]
            let environment = "login"
        }
        struct Capture: Encodable {
            let sessionId: String
            let params: Spawn
            let timeoutMilliseconds = 5_000
            let maxOutputBytes = 262_144
        }
        struct Output: Decodable { let stdout: String; let stderr: String; let exitCode: Int? }
        let result: Result<Output, RustCoreBridge.CoreCallError> = core.executeResult(
            command: "remote.captureProcess",
            payload: Capture(sessionId: session, params: Spawn(argv: [executable, "-version"])),
            timeoutMilliseconds: 7_000
        )
        let value = try result.get()
        guard value.exitCode == 0, let stdout = Data(base64Encoded: value.stdout),
              let stderr = Data(base64Encoded: value.stderr) else { return "" }
        return String(decoding: stdout, as: UTF8.self) + "\n" + String(decoding: stderr, as: UTF8.self)
    }
}
