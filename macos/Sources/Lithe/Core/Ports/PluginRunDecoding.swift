import Foundation
import LitheCoreContracts

/// A plugin backend's `lithe/host/run/start`, checked and normalized by Core. Paths are
/// still the plugin's own words: the working directory is workspace-relative, a tool is a
/// definition ID and a packaged executable is a path inside the plugin package.
struct PluginRunStart: Equatable, Sendable {
    enum Executable: Equatable, Sendable {
        case tool(String)
        case packaged(String)
    }

    struct TemporaryFile: Equatable, Sendable {
        /// Final absolute path, inside the directory the host passed to Core.
        let path: String
        let contents: String
    }

    struct Debug: Equatable, Sendable {
        enum Target: Equatable, Sendable {
            /// The process listens on `port` and the host attaches the adapter to it.
            case connection(port: Int)
            /// The adapter starts the process itself.
            case launch
        }

        let configurationType: String
        let target: Target
    }

    /// The backend function that prepares a new `run/start` when the user runs again.
    struct Rerun: Equatable, Sendable {
        let function: String
        let data: ToolingJSONValue
    }

    let label: String
    let executable: Executable
    let arguments: [String]
    let workingDirectory: String
    let environment: [String: String]
    let temporaryFiles: [TemporaryFile]
    let debug: Debug?
    let rerun: Rerun?
}

/// A plugin backend's `lithe/host/debug/start` on one of the plugin's own adapters.
struct PluginDebugStart: Equatable, Sendable {
    /// The qualified `<plugin>/<adapter>` ID.
    let adapterID: String
    /// `launch` or `attach`.
    let request: String
    let label: String
    let configuration: ToolingJSONValue
}

/// Rust Core decides what a backend may start; a refusal is a `DeclarativePluginRejection`
/// whose code is `plugin.run.invalidStart`, `plugin.debug.invalidStart`,
/// `plugin.debug.unknownAdapter`, `plugin.debug.foreignAdapter` or `plugin.debug.limitExceeded`.
protocol PluginRunStartDecoding: Sendable {
    /// `temporaryDirectory` is the directory the host created for this run; it is required
    /// when the start carries temporary files.
    func decodeRunStart(manifest: Data, workspaceRoot: URL, temporaryDirectory: URL?,
                        params: ToolingJSONValue) throws -> PluginRunStart
    func decodeDebugStart(manifest: Data, params: ToolingJSONValue) throws -> PluginDebugStart
}

/// One console link a plugin's matcher found. Positions count UTF-16 code units, the unit
/// `NSRange` uses.
struct PluginOutputLink: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        /// Candidate files in order; the first that exists opens.
        case location(paths: [String], line: Int?, column: Int?)
        /// The plugin's function turns `groups` into a location when the link is clicked.
        case resolve(function: String, groups: [String: String])
    }

    let line: Int
    let start: Int
    let length: Int
    let pluginID: String
    let matcherID: String
    let target: Target
}

struct PluginOutputLinkMatcher: Equatable, Sendable {
    let id: String
    let pattern: String
    /// `run` or `test`; nil applies to both consoles.
    let scope: String?
    let resolveFunction: String?
}

/// The matchers one plugin declares in its manifest.
struct PluginOutputLinkSource: Equatable, Sendable {
    let pluginID: String
    let matchers: [PluginOutputLinkMatcher]
}

/// A file a `resolve` function found; `line` and `column` are 1-based.
struct PluginOutputLinkLocation: Equatable, Sendable {
    let path: String
    let line: Int?
    let column: Int?
}

protocol PluginOutputLinkMatching: Sendable {
    func links(scope: String, workspaceRoots: [String], sources: [PluginOutputLinkSource],
               lines: [String]) throws -> [PluginOutputLink]
    /// The location of a `resolve` function's reply, or nil when it found nothing.
    func location(ofResolution reply: ToolingJSONValue) throws -> PluginOutputLinkLocation?
}
