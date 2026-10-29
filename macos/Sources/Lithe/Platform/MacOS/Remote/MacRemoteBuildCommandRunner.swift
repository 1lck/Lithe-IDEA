import Foundation
import LitheCoreContracts

/// Keeps build orchestration and decoders intact, selecting process I/O from
/// the command's working directory rather than the currently displayed project.
struct MacRemoteBuildCommandRunner: BuildCommandRunning {
    let local: any BuildCommandRunning
    let registry: RemoteWorkspaceRegistry
    let host: any RemoteProcessRunning

    func run(
        _ request: BuildCommandRequest,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> BuildCommandResult {
        guard let resolved = registry.resolve(request.workingDirectory) else {
            return try await local.run(request, onOutput: onOutput)
        }
        let executable = registry.resolve(request.executableURL)
        if let executable, executable.binding.sessionID != resolved.binding.sessionID {
            throw CocoaError(.featureUnsupported)
        }
        let capture = RemoteBuildOutput(capturesStandardOutput: request.capturesStandardOutput, onOutput: onOutput)
        defer { capture.finish() }
        do {
            let result = try await host.runProcess(
                RemoteProcessRequest(argv: [executable?.remotePath ?? request.executableURL.path] + request.arguments,
                                     cwd: resolved.remotePath, env: request.environment),
                session: resolved.binding.sessionID, timeout: request.timeout,
                onEvent: capture.receive
            )
            capture.finish()
            let status = result.exitCode ?? (128 + (result.signal ?? 1))
            return BuildCommandResult(termination: .exited(status), standardOutput: capture.standardOutput)
        } catch let failure as RemoteProbeFailure where failure.code == "timed_out" {
            return BuildCommandResult(termination: .timedOut, standardOutput: capture.standardOutput)
        }
    }
}

private final class RemoteBuildOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let captures: Bool
    private let onOutput: @Sendable (String) -> Void
    private var stdout = Data()
    private var overflowed = false
    private var stdoutDecoder = StreamingUTF8Decoder()
    private var stderrDecoder = StreamingUTF8Decoder()
    private var finished = false

    init(capturesStandardOutput: Bool, onOutput: @escaping @Sendable (String) -> Void) {
        captures = capturesStandardOutput
        self.onOutput = onOutput
    }

    func receive(_ event: RemoteProcessEvent) {
        lock.withLock {
            guard !finished else { return }
            if case .output(let bytes, let standardError) = event {
                if captures && !standardError {
                    guard !overflowed else { return }
                    if stdout.count + bytes.count > MacBuildCommandRunner.standardOutputLimit {
                        overflowed = true
                        stdout.removeAll()
                    } else { stdout.append(bytes) }
                } else {
                    let text = standardError ? stderrDecoder.decode(bytes) : stdoutDecoder.decode(bytes)
                    if !text.isEmpty { onOutput(text) }
                }
            }
        }
    }

    func finish() {
        lock.withLock {
            guard !finished else { return }
            finished = true
            let text = stdoutDecoder.finish() + stderrDecoder.finish()
            if !text.isEmpty { onOutput(text) }
        }
    }

    var standardOutput: String? {
        lock.withLock { captures && !overflowed ? String(data: stdout, encoding: .utf8) : nil }
    }
}
