import Foundation
import LitheCoreContracts

/// Typed `run.decodeStart`, `debug.decodeBackendConfiguration`, `outputLinks.match` and
/// `outputLinks.decodeResolution` operations. Rust Core decides what a plugin backend may
/// start and which console text links where for both products; this adapter only
/// translates payloads and outcomes.
struct RustPluginRunOperations: PluginRunStartDecoding, PluginOutputLinkMatching {
    let core: RustCoreBridge

    // MARK: Run and debug starts

    func decodeRunStart(manifest: Data, workspaceRoot: URL, temporaryDirectory: URL?,
                        params: ToolingJSONValue) throws -> PluginRunStart {
        let result: RunStartResult = try executeRejecting("run.decodeStart", payload: RunStartPayload(
            manifest: try Self.json(manifest), workspaceRoot: workspaceRoot.path,
            temporaryDirectory: temporaryDirectory?.path, params: params))
        return result.start.value
    }

    func decodeDebugStart(manifest: Data, params: ToolingJSONValue) throws -> PluginDebugStart {
        let result: DebugStartResult = try executeRejecting("debug.decodeBackendConfiguration", payload: DebugStartPayload(
            manifest: try Self.json(manifest), params: params))
        return result.start.value
    }

    // MARK: Console links

    func links(scope: String, workspaceRoots: [String], sources: [PluginOutputLinkSource],
               lines: [String]) throws -> [PluginOutputLink] {
        let payload = LinkPayload(scope: scope, platform: "macos", workspaceRoots: workspaceRoots,
                                  sources: sources.map(LinkPayload.Source.init), lines: lines)
        let result: LinkResult = try executeFailing("outputLinks.match", payload: payload)
        return result.links.map(\.value)
    }

    func location(ofResolution reply: ToolingJSONValue) throws -> PluginOutputLinkLocation? {
        struct Payload: Encodable { let reply: ToolingJSONValue }
        struct Location: Decodable { let path: String; let line: Int?; let column: Int? }
        let found: Location? = try core.executeNullableResult(
            command: "outputLinks.decodeResolution", payload: Payload(reply: reply)).get()
        return found.map { PluginOutputLinkLocation(path: $0.path, line: $0.line, column: $0.column) }
    }

    // MARK: Execution

    /// For commands whose refusal is an answer, `{status: "rejected", error}`, not a failure.
    private func executeRejecting<Payload: Encodable, Value: Decodable>(_ command: String, payload: Payload) throws -> Value {
        let outcome: Outcome<Value> = try executeFailing(command, payload: payload)
        if let rejection = outcome.error {
            throw DeclarativePluginRejection(code: rejection.code, message: rejection.message, field: rejection.field)
        }
        return outcome.value
    }

    private func executeFailing<Payload: Encodable, Value: Decodable>(_ command: String, payload: Payload) throws -> Value {
        do {
            return try core.executeResult(command: command, payload: payload).get()
        } catch {
            throw DeclarativePluginRejection(code: "plugin.core.failed", message: error.localizedDescription)
        }
    }

    private static func json(_ manifest: Data) throws -> ToolingJSONValue {
        do {
            return try JSONDecoder().decode(ToolingJSONValue.self, from: manifest)
        } catch {
            throw DeclarativePluginRejection(code: "plugin.manifest.invalid", message: "plugin.json is not valid JSON.")
        }
    }

    // MARK: Wire types

    private struct RunStartPayload: Encodable {
        let manifest: ToolingJSONValue
        let workspaceRoot: String
        let temporaryDirectory: String?
        let params: ToolingJSONValue
    }

    private struct DebugStartPayload: Encodable {
        let manifest: ToolingJSONValue
        let params: ToolingJSONValue
    }

    private struct LinkPayload: Encodable {
        struct Matcher: Encodable {
            struct Resolve: Encodable { let function: String }
            let id: String
            let pattern: String
            let scope: String?
            let resolve: Resolve?
        }

        struct Source: Encodable {
            let pluginID: String
            let matchers: [Matcher]

            init(_ source: PluginOutputLinkSource) {
                pluginID = source.pluginID
                matchers = source.matchers.map {
                    Matcher(id: $0.id, pattern: $0.pattern, scope: $0.scope,
                            resolve: $0.resolveFunction.map(Matcher.Resolve.init))
                }
            }
        }

        let scope: String
        let platform: String
        let workspaceRoots: [String]
        let sources: [Source]
        let lines: [String]
    }

    private struct Rejection: Decodable {
        let code: String
        let message: String
        let field: String?
    }

    /// `{status: "ok", …}` with the operation's value at the top level, or
    /// `{status: "rejected", error}`.
    private struct Outcome<Value: Decodable>: Decodable {
        let error: Rejection?
        private let decodedValue: Value?

        var value: Value { decodedValue! }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if try container.decode(String.self, forKey: .status) == "rejected" {
                error = try container.decode(Rejection.self, forKey: .error)
                decodedValue = nil
            } else {
                error = nil
                decodedValue = try Value(from: decoder)
            }
        }

        private enum CodingKeys: String, CodingKey {
            case status, error
        }
    }

    private struct RunStartResult: Decodable {
        let start: WireRunStart
    }

    private struct DebugStartResult: Decodable {
        let start: WireDebugStart
    }

    private struct LinkResult: Decodable {
        let links: [WireLink]
    }

    private struct WireRunStart: Decodable {
        struct Executable: Decodable {
            let kind: String
            let value: String
        }

        struct File: Decodable {
            let path: String
            let contents: String
        }

        struct Debug: Decodable {
            struct Target: Decodable {
                let kind: String
                let port: Int?
            }

            let configurationType: String
            let target: Target
        }

        struct Rerun: Decodable {
            let function: String
            let data: ToolingJSONValue
        }

        let label: String
        let executable: Executable
        let arguments: [String]
        let workingDirectory: String
        let environment: [String: String]
        let temporaryFiles: [File]
        let debug: Debug?
        let rerun: Rerun?

        var value: PluginRunStart {
            PluginRunStart(
                label: label,
                // Core names a definition ID `toolchain`; the host-facing word is `tool`.
                executable: executable.kind == "packaged" ? .packaged(executable.value) : .tool(executable.value),
                arguments: arguments, workingDirectory: workingDirectory, environment: environment,
                temporaryFiles: temporaryFiles.map { .init(path: $0.path, contents: $0.contents) },
                debug: debug.map {
                    .init(configurationType: $0.configurationType,
                          target: $0.target.port.map { .connection(port: $0) } ?? .launch)
                },
                rerun: rerun.map { .init(function: $0.function, data: $0.data) }
            )
        }
    }

    private struct WireDebugStart: Decodable {
        let adapterID: String
        let request: String
        let label: String
        let configuration: ToolingJSONValue

        var value: PluginDebugStart {
            PluginDebugStart(adapterID: adapterID, request: request, label: label, configuration: configuration)
        }
    }

    private struct WireLink: Decodable {
        struct Location: Decodable {
            let paths: [String]
            let line: Int?
            let column: Int?
        }

        struct Resolve: Decodable {
            let function: String
            let groups: [String: String]
        }

        let line: Int
        let start: Int
        let length: Int
        let pluginID: String
        let matcherID: String
        let location: Location?
        let resolve: Resolve?

        var value: PluginOutputLink {
            let target: PluginOutputLink.Target
            if let resolve {
                target = .resolve(function: resolve.function, groups: resolve.groups)
            } else {
                let location = location ?? Location(paths: [], line: nil, column: nil)
                target = .location(paths: location.paths, line: location.line, column: location.column)
            }
            return PluginOutputLink(line: line, start: start, length: length, pluginID: pluginID,
                                    matcherID: matcherID, target: target)
        }
    }
}
