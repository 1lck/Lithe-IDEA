import Foundation
import LitheCoreContracts
import LitheModuleAPI

// Note: 构建系统插件契约见 .agents/notes/implemented/architecture/2026-10-17-build-system-plugin-contract.md

/// Runs build-system commands in their own process group. Unlike
/// `MacStreamingProcess`, stdout can be kept apart from stderr, because a
/// model or dependency command prints the document Core decodes there.
final class MacBuildCommandRunner: BuildCommandRunning {
    /// Rust Core refuses larger output, so more is never kept.
    static let standardOutputLimit = 32 * 1024 * 1024

    private let processRegistry: ManagedProcessRegistry?

    init(processRegistry: ManagedProcessRegistry? = nil) {
        self.processRegistry = processRegistry
    }

    func run(
        _ request: BuildCommandRequest,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> BuildCommandResult {
        try Task.checkCancellation()
        let execution = MacBuildCommandExecution(
            request: request,
            processRegistry: processRegistry,
            onOutput: onOutput
        )
        return try await withTaskCancellationHandler {
            try await execution.run()
        } onCancel: {
            execution.cancel()
        }
    }
}

/// One command from launch to the termination callback.
private final class MacBuildCommandExecution: @unchecked Sendable {
    private let request: BuildCommandRequest
    private let processRegistry: ManagedProcessRegistry?
    private let batcher: MacProcessOutputBatcher

    /// Guards the lifecycle fields below.
    private let lock = NSLock()
    private var continuation: CheckedContinuation<BuildCommandResult, Error>?
    private var process: MacManagedProcess?
    private var registeredPID: Int32?
    private var isCancelled = false
    private var didTimeOut = false
    private var timeoutTask: Task<Void, Never>?

    /// Serializes pipe reads with the final drain, as `MacStreamingProcess`
    /// does, so the last bytes are neither lost nor delivered twice.
    private let readLock = NSLock()
    private var streamPipe: Pipe?
    private var capturePipe: Pipe?
    private var decoder = StreamingUTF8Decoder()
    private var captured = Data()
    private var captureOverflowed = false

    init(
        request: BuildCommandRequest,
        processRegistry: ManagedProcessRegistry?,
        onOutput: @escaping @Sendable (String) -> Void
    ) {
        self.request = request
        self.processRegistry = processRegistry
        batcher = MacProcessOutputBatcher(deliver: onOutput)
    }

    func run() async throws -> BuildCommandResult {
        try await withCheckedThrowingContinuation { continuation in
            let cancelledEarly = lock.withLock { () -> Bool in
                guard !isCancelled else { return true }
                self.continuation = continuation
                return false
            }
            if cancelledEarly {
                continuation.resume(throwing: CancellationError())
                return
            }
            do {
                try launch()
            } catch {
                closePipes()
                batcher.finish()
                lock.withLock { () -> CheckedContinuation<BuildCommandResult, Error>? in
                    defer { self.continuation = nil; self.process = nil }
                    return self.continuation
                }?.resume(throwing: error)
            }
        }
    }

    func cancel() {
        let process = lock.withLock { () -> MacManagedProcess? in
            isCancelled = true
            return self.process
        }
        // The termination callback reports the cancellation once the group
        // is gone; a command not launched yet sees the flag in `launch`.
        process?.terminate()
    }

    private func launch() throws {
        let streamPipe = Pipe()
        let capturePipe = request.capturesStandardOutput ? Pipe() : nil
        let process = MacManagedProcess(
            executableURL: request.executableURL,
            arguments: request.arguments,
            currentDirectoryURL: request.workingDirectory,
            environment: request.environment,
            standardInput: FileHandle.nullDevice,
            standardOutput: (capturePipe ?? streamPipe).fileHandleForWriting,
            standardError: streamPipe.fileHandleForWriting
        )
        readLock.withLock {
            self.streamPipe = streamPipe
            self.capturePipe = capturePipe
        }
        streamPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.readStream(handle)
        }
        capturePipe?.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.readCapture(handle)
        }
        process.terminationHandler = { [weak self] process in
            self?.finish(process)
        }
        lock.withLock { self.process = process }
        try process.run { [processRegistry] pid in
            lock.withLock { registeredPID = pid }
            processRegistry?.register(pid: pid, category: .service, moduleID: .execution)
        }
        try? streamPipe.fileHandleForWriting.close()
        try? capturePipe?.fileHandleForWriting.close()
        if lock.withLock({ isCancelled }) {
            process.terminate()
        }
        scheduleTimeout(for: process)
    }

    private func scheduleTimeout(for process: MacManagedProcess) {
        guard let timeout = request.timeout else { return }
        let task = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            let running = lock.withLock { () -> Bool in
                guard self.process === process else { return false }
                self.didTimeOut = true
                return true
            }
            if running { process.terminate() }
        }
        lock.withLock { timeoutTask = task }
    }

    private func readStream(_ handle: FileHandle) {
        readLock.withLock {
            guard handle === streamPipe?.fileHandleForReading else { return }
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            batcher.append(decoder.decode(data))
        }
    }

    private func readCapture(_ handle: FileHandle) {
        readLock.withLock {
            guard handle === capturePipe?.fileHandleForReading else { return }
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            appendCaptured(data)
        }
    }

    /// Called with `readLock` held.
    private func appendCaptured(_ data: Data) {
        guard !captureOverflowed else { return }
        if captured.count + data.count > MacBuildCommandRunner.standardOutputLimit {
            captureOverflowed = true
            captured = Data()
        } else {
            captured.append(data)
        }
    }

    private func finish(_ terminated: MacManagedProcess) {
        let standardOutput = readLock.withLock { () -> String? in
            if let handle = streamPipe?.fileHandleForReading {
                handle.readabilityHandler = nil
                if let remaining = try? handle.readToEnd(), !remaining.isEmpty {
                    batcher.append(decoder.decode(remaining))
                }
            }
            batcher.append(decoder.finish())
            guard let handle = capturePipe?.fileHandleForReading else { return nil }
            handle.readabilityHandler = nil
            if let remaining = try? handle.readToEnd(), !remaining.isEmpty {
                appendCaptured(remaining)
            }
            return captureOverflowed ? nil : String(data: captured, encoding: .utf8)
        }
        batcher.finish()
        closePipes()
        let (continuation, cancelled, timedOut, pid) = lock.withLock {
            defer {
                self.continuation = nil
                process = nil
                registeredPID = nil
                timeoutTask?.cancel()
                timeoutTask = nil
            }
            return (self.continuation, isCancelled, didTimeOut, registeredPID)
        }
        if let pid {
            processRegistry?.unregister(pid: pid, category: .service, moduleID: .execution)
        }
        if cancelled {
            continuation?.resume(throwing: CancellationError())
        } else {
            continuation?.resume(returning: BuildCommandResult(
                termination: timedOut ? .timedOut : .exited(terminated.terminationStatus),
                standardOutput: standardOutput
            ))
        }
    }

    private func closePipes() {
        readLock.withLock {
            for pipe in [streamPipe, capturePipe].compactMap({ $0 }) {
                pipe.fileHandleForReading.readabilityHandler = nil
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
            }
            streamPipe = nil
            capturePipe = nil
        }
    }
}
