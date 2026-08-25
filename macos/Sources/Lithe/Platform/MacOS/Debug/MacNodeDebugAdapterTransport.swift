import Foundation

struct MacJavaScriptDebugAdapterLocator {
    enum LocatorError: LocalizedError {
        case adapterNotFound

        var errorDescription: String? {
            switch self {
            case .adapterNotFound:
                return "Node.js debugging requires the official vscode-js-debug standalone DAP bundle. Set LITHE_JS_DEBUG_PATH to its dapDebugServer.js file or unpack it under .lithe/toolchains/js-debug."
            }
        }
    }

    private let environment: [String: String]
    private let homeDirectoryURL: URL
    private let fileExists: (URL) -> Bool
    private let isDirectory: (URL) -> Bool
    private let executableOnPath: (String) -> URL?

    init(
        environment: [String: String],
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileExists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        isDirectory: @escaping (URL) -> Bool = {
            var value: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &value) && value.boolValue
        },
        executableOnPath: @escaping (String) -> URL?
    ) {
        self.environment = environment
        self.homeDirectoryURL = homeDirectoryURL
        self.fileExists = fileExists
        self.isDirectory = isDirectory
        self.executableOnPath = executableOnPath
    }

    func resolve(rootURL: URL, nodeExecutableURL: URL) throws -> ServerDebugAdapterProcessLaunch {
        let configuredURL = environment["LITHE_JS_DEBUG_PATH"]
            .flatMap { configuredPath($0, relativeTo: rootURL) }
        let roots = [
            configuredURL,
            rootURL.appendingPathComponent(".lithe/toolchains/js-debug", isDirectory: true),
            homeDirectoryURL.appendingPathComponent("Library/Application Support/Lithe/js-debug", isDirectory: true),
            homeDirectoryURL.appendingPathComponent(".local/share/lithe/js-debug", isDirectory: true)
        ].compactMap { $0 }

        if let script = roots.lazy.compactMap(resolveScript).first {
            return ServerDebugAdapterProcessLaunch(
                executableURL: nodeExecutableURL,
                arguments: [script.path, "0", "127.0.0.1"],
                environment: environment
            )
        }
        if let command = executableOnPath("js-debug-dap") {
            return ServerDebugAdapterProcessLaunch(
                executableURL: command,
                arguments: ["0", "127.0.0.1"],
                environment: environment
            )
        }
        throw LocatorError.adapterNotFound
    }

    private func configuredPath(_ path: String, relativeTo rootURL: URL) -> URL? {
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("/") { return URL(fileURLWithPath: value) }
        return rootURL.appendingPathComponent(value)
    }

    private func resolveScript(_ candidate: URL) -> URL? {
        if !isDirectory(candidate) {
            return fileExists(candidate) ? candidate.standardizedFileURL : nil
        }
        return [
            candidate.appendingPathComponent("src/dapDebugServer.js"),
            candidate.appendingPathComponent("js-debug/src/dapDebugServer.js"),
            candidate.appendingPathComponent("dapDebugServer.js")
        ].first { fileExists($0) }?.standardizedFileURL
    }
}

/// Starts Microsoft's standalone JavaScript DAP server only when a Node debug
/// session is requested, then delegates all protocol bytes to the shared TCP
/// transport and language-neutral DAP state machine.
@MainActor
final class MacNodeDebugAdapterTransport: MacServerDebugAdapterTransport {
    init(
        nodeExecutableURL: URL,
        locator: MacJavaScriptDebugAdapterLocator,
        process: any RawProcessSession
    ) {
        super.init(
            process: process,
            launchResolver: { rootURL in
                try locator.resolve(rootURL: rootURL, nodeExecutableURL: nodeExecutableURL)
            },
            endpointParser: {
                MacServerDebugAdapterTransport.announcedEndpoint(
                    after: "Debug server listening at",
                    in: $0
                )
            }
        )
    }

    init(
        nodeExecutableURL: URL,
        locator: MacJavaScriptDebugAdapterLocator,
        process: any RawProcessSession,
        socketFactory: @escaping @MainActor (String, UInt16) -> any DebugAdapterSocketConnection
    ) {
        super.init(
            process: process,
            launchResolver: { rootURL in
                try locator.resolve(rootURL: rootURL, nodeExecutableURL: nodeExecutableURL)
            },
            endpointParser: {
                MacServerDebugAdapterTransport.announcedEndpoint(
                    after: "Debug server listening at",
                    in: $0
                )
            },
            socketFactory: socketFactory
        )
    }
}
