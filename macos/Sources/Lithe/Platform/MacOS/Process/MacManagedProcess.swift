import Darwin
import Foundation

/// Launches a subprocess in a dedicated process group and reaps its root PID.
///
/// `Foundation.Process` cannot assign a process group before `exec`, leaving a
/// race where a short-lived shell can orphan descendants before cleanup gains
/// ownership. This adapter uses `posix_spawn` so group membership is atomic with
/// launch and remains available after the group leader exits.
final class MacManagedProcess: @unchecked Sendable {
    typealias TerminationHandler = @Sendable (MacManagedProcess) -> Void

    let executableURL: URL
    let arguments: [String]
    let currentDirectoryURL: URL?
    let environment: [String: String]?
    let standardInput: FileHandle
    let standardOutput: FileHandle
    let standardError: FileHandle

    private let lock = NSLock()
    private let terminationQueue = DispatchQueue(
        label: "dev.lithe.managed-process.termination",
        qos: .utility
    )
    private var source: DispatchSourceProcess?
    private var running = false
    private var status: Int32 = 0
    private var pid: pid_t = 0
    private var group: MacProcessGroup?
    private var handler: TerminationHandler?

    init(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        environment: [String: String]? = nil,
        standardInput: FileHandle,
        standardOutput: FileHandle,
        standardError: FileHandle
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.currentDirectoryURL = currentDirectoryURL
        self.environment = environment
        self.standardInput = standardInput
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    var processIdentifier: pid_t {
        lock.withLock { pid }
    }

    var isRunning: Bool {
        lock.withLock { running }
    }

    var terminationStatus: Int32 {
        lock.withLock { status }
    }

    var terminationHandler: TerminationHandler? {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue } }
    }

    func run(onLaunch: (pid_t) -> Void = { _ in }) throws {
        let launchedPID = try Self.spawn(
            executableURL: executableURL,
            arguments: arguments,
            currentDirectoryURL: currentDirectoryURL,
            environment: environment,
            standardInput: standardInput.fileDescriptor,
            standardOutput: standardOutput.fileDescriptor,
            standardError: standardError.fileDescriptor
        )
        let processGroup = MacProcessGroup(processGroupID: launchedPID)
        let processSource = DispatchSource.makeProcessSource(
            identifier: launchedPID,
            eventMask: .exit,
            queue: terminationQueue
        )
        lock.withLock {
            pid = launchedPID
            group = processGroup
            source = processSource
            running = true
        }
        // The source deliberately retains this object until waitpid reaps the
        // child, even when a session releases its reference during stop().
        processSource.setEventHandler { [self] in
            reapRootProcess(processSource)
        }
        // Callers can publish the PID to their registry before an immediately
        // exiting child makes the termination callback observable.
        onLaunch(launchedPID)
        processSource.activate()
    }

    @discardableResult
    func terminate(
        gracePeriod: Duration = .milliseconds(200),
        forcedTerminationTimeout: Duration = .seconds(1)
    ) -> Task<Bool, Never>? {
        lock.withLock {
            group?.terminate(
                gracePeriod: gracePeriod,
                forcedTerminationTimeout: forcedTerminationTimeout
            )
        }
    }

    @discardableResult
    func terminateAndWait(
        gracePeriod: TimeInterval = 0.2,
        forcedTerminationTimeout: TimeInterval = 1
    ) -> Bool {
        guard let processGroup = lock.withLock({ group }) else { return true }
        return processGroup.terminateAndWait(
            gracePeriod: gracePeriod,
            forcedTerminationTimeout: forcedTerminationTimeout
        )
    }

    private func reapRootProcess(_ processSource: DispatchSourceProcess) {
        let processID = processIdentifier
        var waitStatus: Int32 = 0
        var waitResult: pid_t
        repeat {
            waitResult = Darwin.waitpid(processID, &waitStatus, 0)
        } while waitResult == -1 && errno == EINTR

        let processGroup = lock.withLock { group }
        if processGroup?.hasRunningProcesses == true {
            // A normally exiting launcher must not leave background descendants
            // alive merely because they closed or retained inherited pipes.
            _ = processGroup?.terminateAndWait()
        }

        let callback = lock.withLock { () -> TerminationHandler? in
            status = waitResult == processID ? Self.exitCode(from: waitStatus) : 1
            running = false
            source = nil
            group = nil
            return handler
        }
        processSource.cancel()
        callback?(self)
    }

    private static func spawn(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL?,
        environment: [String: String]?,
        standardInput: Int32,
        standardOutput: Int32,
        standardError: Int32
    ) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        var fileActions: posix_spawn_file_actions_t?
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawn_file_actions_init(&fileActions))
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        try check(posix_spawnattr_setflags(&attributes, flags))
        // A pgroup value of zero creates a new group whose ID is the child PID.
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        let resolvedStandardInput: Int32
        if standardInput >= 0 {
            resolvedStandardInput = standardInput
        } else {
            resolvedStandardInput = Darwin.open("/dev/null", O_RDONLY)
            guard resolvedStandardInput >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        defer {
            if resolvedStandardInput != standardInput {
                Darwin.close(resolvedStandardInput)
            }
        }
        try check(posix_spawn_file_actions_adddup2(
            &fileActions,
            resolvedStandardInput,
            STDIN_FILENO
        ))
        try check(posix_spawn_file_actions_adddup2(&fileActions, standardOutput, STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&fileActions, standardError, STDERR_FILENO))
        if let currentDirectoryURL {
            try check(posix_spawn_file_actions_addchdir_np(&fileActions, currentDirectoryURL.path))
        }

        let argumentValues = [executableURL.path] + arguments
        let environmentValues = (environment ?? ProcessInfo.processInfo.environment)
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        var launchedPID: pid_t = 0
        let spawnResult = try withCStringArray(argumentValues) { argumentPointers in
            try withCStringArray(environmentValues) { environmentPointers in
                posix_spawn(
                    &launchedPID,
                    executableURL.path,
                    &fileActions,
                    &attributes,
                    argumentPointers,
                    environmentPointers
                )
            }
        }
        try check(spawnResult)
        return launchedPID
    }

    private static func withCStringArray<ResultValue>(
        _ values: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> ResultValue
    ) throws -> ResultValue {
        var pointers = values.map { strdup($0) }
        guard pointers.allSatisfy({ $0 != nil }) else {
            pointers.forEach { free($0) }
            throw POSIXError(.ENOMEM)
        }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }

    private static func check(_ result: Int32) throws {
        guard result != 0 else { return }
        throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
    }

    private static func exitCode(from waitStatus: Int32) -> Int32 {
        let terminationSignal = waitStatus & 0x7f
        if terminationSignal == 0 {
            return (waitStatus >> 8) & 0xff
        }
        return terminationSignal
    }
}
