import Darwin
import Foundation
import LitheLanguageIntelligenceModule

/// Owns the Node process group and its pipes. Each instance is a single host generation.
/// Note: .agents/notes/proposed/architecture/2026-09-19-vscode-extension-host.md
@MainActor
final class MacExtensionHostTransport: ExtensionHostProcessTransport {
    var onOutput: ((Data) -> Void)?
    var onDiagnostic: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?

    private var process: MacManagedProcess?
    private var input: Pipe?
    private var output: Pipe?
    private var diagnostic: Pipe?
    private let writes = DispatchQueue(label: "dev.lithe.extension-host.stdin", qos: .utility)
    private var started = false
    private var openHandles: [FileHandle] = []

    var isRunning: Bool { process?.isRunning == true }

    func start(_ configuration: ExtensionHostLaunchConfiguration) throws {
        try start(node: configuration.node, entrypoint: configuration.entrypoint,
                  workspace: configuration.workspace, environment: configuration.environment)
    }

    func start(node: URL, entrypoint: URL, workspace: URL, environment: [String: String]) throws {
        guard !started else { throw CocoaError(.executableLoad) }
        started = true
        let input = Pipe()
        let output = Pipe()
        let diagnostic = Pipe()
        let descriptor = input.fileHandleForWriting.fileDescriptor
        guard fcntl(descriptor, F_SETNOSIGPIPE, 1) != -1,
              fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else {
            throw POSIXError(.EIO)
        }
        let process = MacManagedProcess(
            executableURL: node, arguments: [entrypoint.path],
            currentDirectoryURL: workspace, environment: environment,
            standardInput: input.fileHandleForReading,
            standardOutput: output.fileHandleForWriting,
            standardError: diagnostic.fileHandleForWriting
        )
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { [weak self] in self?.onOutput?(data) }
        }
        diagnostic.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { [weak self] in self?.onDiagnostic?(data) }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            DispatchQueue.main.async { [weak self] in self?.onExit?(status) }
        }
        self.input = input
        self.output = output
        self.diagnostic = diagnostic
        self.process = process
        openHandles = [input, output, diagnostic].flatMap { [$0.fileHandleForReading, $0.fileHandleForWriting] }
        do {
            try process.run()
            for handle in [input.fileHandleForReading, output.fileHandleForWriting, diagnostic.fileHandleForWriting] {
                try handle.close()
                openHandles.removeAll { $0 === handle }
            }
        } catch {
            _ = process.terminate()
            closePipes()
            self.process = nil
            throw error
        }
    }

    func send(_ data: Data) async throws {
        guard let input, process?.isRunning == true else { throw POSIXError(.EPIPE) }
        // A private descriptor avoids reuse races with shutdown while the worker writes.
        let descriptor = dup(input.fileHandleForWriting.fileDescriptor)
        guard descriptor >= 0 else { throw POSIXError(.EBADF) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writes.async {
                defer { Darwin.close(descriptor) }
                do {
                    try Self.write(data, descriptor: descriptor)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Call after the protocol shutdown handshake, or immediately after a crash.
    /// Completion means the group cleanup deadline has elapsed, not just SIGTERM sent.
    func stop() async -> Bool {
        let ownedProcess = process
        closePipes()
        guard let cleanup = ownedProcess?.terminate() else {
            process = nil
            return true
        }
        let stopped = await cleanup.value
        if stopped { process = nil }
        return stopped
    }

    private func closePipes() {
        output?.fileHandleForReading.readabilityHandler = nil
        diagnostic?.fileHandleForReading.readabilityHandler = nil
        for handle in openHandles {
            do { try handle.close() }
            catch {
                onDiagnostic?(Data("Extension host pipe close failed: \(error.localizedDescription)\n".utf8))
            }
        }
        openHandles.removeAll()
        input = nil
        output = nil
        diagnostic = nil
    }

    private nonisolated static func write(_ data: Data, descriptor: Int32) throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard clock.now < deadline else { throw POSIXError(.ETIMEDOUT) }
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0, errno == EINTR { continue }
                guard count < 0, errno == EAGAIN else { throw POSIXError(.EPIPE) }
                var descriptorState = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                // Bounded native polling runs only on the private I/O queue.
                let result = Darwin.poll(&descriptorState, 1, 50)
                if result < 0, errno != EINTR { throw POSIXError(.EIO) }
            }
        }
    }
}
