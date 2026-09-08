import Foundation

/// Packages a staged directory into a zip using the macOS `ditto` tool. The
/// repository does not vendor a third-party zip library, so shelling out to
/// this system utility through the existing process-running port is the
/// established zero-dependency approach for macOS.
struct MacDittoArchiver: DiagnosticsArchiving {
    private static let executablePath = "/usr/bin/ditto"

    private let processRunner: any ProcessRunner

    init(processRunner: any ProcessRunner) {
        self.processRunner = processRunner
    }

    func archive(directoryURL: URL, toZipURL destinationURL: URL) throws {
        try? FileManager.default.removeItem(at: destinationURL)
        let result = processRunner.run(ProcessRequest(
            operationID: "diagnostics.export.archive",
            executablePath: Self.executablePath,
            arguments: [
                "-c", "-k", "--sequesterRsrc", "--keepParent",
                directoryURL.path, destinationURL.path
            ],
            timeoutMilliseconds: 30_000
        ))
        guard result.succeeded else {
            throw DiagnosticsArchivingError.dittoFailed(exitCode: result.exitCode, output: result.output)
        }
    }
}

enum DiagnosticsArchivingError: LocalizedError {
    case dittoFailed(exitCode: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case .dittoFailed(let exitCode, let output):
            return "ditto exited with code \(exitCode): \(output)"
        }
    }
}
