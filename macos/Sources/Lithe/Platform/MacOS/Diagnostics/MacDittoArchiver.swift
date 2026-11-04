import LitheModuleAPI
import Darwin
import Foundation

/// Packages a staged directory into a zip using the macOS `ditto` tool. The
/// repository does not vendor a third-party zip library, so shelling out to
/// this system utility through the existing process-running port is the
/// established zero-dependency approach for macOS.
struct MacDittoArchiver: DiagnosticsArchiving {
    private static let executablePath = "/usr/bin/ditto"

    private let processRunner: any ProcessRunner

    private let logSink: (any LogSink)?

    init(processRunner: any ProcessRunner, logSink: (any LogSink)? = nil) {
        self.logSink = logSink
        self.processRunner = processRunner
    }

    func archive(directoryURL: URL, toZipURL destinationURL: URL) throws {
        let temporaryURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".lithe-diagnostics-\(UUID().uuidString).zip")
        defer {
            do { try FileManager.default.removeItem(at: temporaryURL) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { /* Published or never created. */ }
            catch { logSink?.emit(AppStorageMaintenanceFailed(error: error, stage: "archive-remove", operationID: "diagnostics.export.archive")) }
        }
        let result = processRunner.run(ProcessRequest(
            operationID: "diagnostics.export.archive",
            executablePath: Self.executablePath,
            arguments: [
                "-c", "-k", "--sequesterRsrc", "--keepParent",
                directoryURL.path, temporaryURL.path
            ],
            timeoutMilliseconds: 30_000
        ))
        guard result.succeeded else {
            throw DiagnosticsArchivingError.dittoFailed(exitCode: result.exitCode, output: result.output)
        }
        // Publish on the destination volume only after compression succeeds;
        // failure must preserve an archive the user already has there.
        guard Darwin.rename(temporaryURL.path, destinationURL.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

enum DiagnosticsArchivingError: LocalizedError {
    case dittoFailed(exitCode: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case .dittoFailed(let exitCode, let output):
            return L10n.string("ditto exited with code \(String(exitCode)): \(output)")
        }
    }
}
