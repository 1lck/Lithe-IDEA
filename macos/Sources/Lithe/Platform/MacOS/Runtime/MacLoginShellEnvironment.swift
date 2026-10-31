import Foundation

// Portions derived from OpenIDEA `crates/ide-host/src/shell_env.rs`
// (https://github.com/l0ng-ai/openidea, Apache-2.0), translated to Swift and modified
// for Lithe. See the repository NOTICE.
// Note: 取舍见 .agents/notes/implemented/bug-fix/2026-10-30-login-shell-environment-and-jdk-selection.md

/// The environment of the user's interactive login shell, for an app started from
/// Finder or the Dock.
///
/// launchd gives such an app only `/usr/bin:/bin:/usr/sbin:/sbin`, so Maven, JDKs,
/// Node.js and Gradle installed through Homebrew, mise, SDKMAN, asdf or fnm are
/// invisible to discovery and to every child process. Patching each tool's lookup
/// fixed one tool at a time; reading the shell once fixes all of them.
///
/// Starting an interactive login shell costs about a second with typical rc files,
/// so only `PATH` is cached (in Caches, never in the bundle): a warm start applies the
/// cached value immediately and refreshes it in the background for the next launch.
/// The rest of the shell's environment may hold secrets, so it stays in memory and
/// only fills variables the process does not already define.
final class MacLoginShellEnvironment: LoginShellEnvironmentInspecting, @unchecked Sendable {
    static let shared = MacLoginShellEnvironment()

    /// Opt-out for tests and for users whose rc files must not run unattended.
    static let skipVariable = "LITHE_SKIP_SHELL_ENV"
    static let coldStartTimeout: TimeInterval = 3
    static let refreshTimeout: TimeInterval = 10

    /// Variables the shell sets for itself or for its terminal rather than the
    /// user's configuration; children launched by Lithe are not in that terminal.
    static let shellOwnVariables: Set<String> = [
        "PWD", "OLDPWD", "SHLVL", "_", "TERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID"
    ]

    private static let marker = "__LITHE_LOGIN_ENV__"

    private let lock = NSLock()
    private var overlay: [String: String] = [:]
    private var logging: (any ApplicationLogging)?
    /// Outcomes from before the log writer exists; startup runs ahead of it.
    private var pendingRecords: [(level: String, message: String, fields: [String: String])] = []
    /// Startup facts and the latest outcome, for the settings page; never variable values.
    private var launch = Launch()
    private var lastRead: (date: Date, duration: Duration, variables: Int?)?
    private var latestLoginPath: [String]?
    private var isReading = false
    private var completedReads = 0
    /// Held for a whole read, so a second request waits for the first shell.
    private let readLock = NSLock()

    private struct Launch {
        var shell: String?
        var cacheURL: URL?
        var disabled = false
        var fromCache = false
        var loginPath: [String] = []
        var processPath: [String] = []
    }

    init(overlay: [String: String] = [:]) {
        self.overlay = overlay
    }

    /// `base` plus the login shell's variables it lacks. `base` wins, so a value
    /// set by the launching process or by Lithe itself is never replaced.
    func merged(_ base: [String: String]) -> [String: String] {
        let overlay = lock.withLock { self.overlay }
        return base.merging(overlay) { current, _ in current }
    }

    /// Sends the startup outcome, and every later refresh, to the application log.
    /// Records carry the shell's name, timing and counts, never variable values.
    func attach(logging: any ApplicationLogging) {
        let pending = lock.withLock {
            self.logging = logging
            defer { pendingRecords.removeAll() }
            return pendingRecords
        }
        for record in pending {
            logging.record(level: record.level, scope: "application", message: record.message, fields: record.fields)
        }
    }

    private func record(level: String, message: String, fields: [String: String]) {
        let logging = lock.withLock {
            if self.logging == nil { pendingRecords.append((level, message, fields)) }
            return self.logging
        }
        logging?.record(level: level, scope: "application", message: message, fields: fields)
    }

    private func recordRead(
        _ environment: [String: String]?, shell: String, source: String, started: ContinuousClock.Instant
    ) {
        let duration = started.duration(to: .now)
        lock.withLock {
            lastRead = (Date(), duration, environment?.count)
            if let path = environment?["PATH"], !path.isEmpty { latestLoginPath = Self.entries(path) }
            completedReads += 1
        }
        var fields = [
            "shell": URL(fileURLWithPath: shell).lastPathComponent,
            "source": source,
            "duration": String(describing: duration)
        ]
        if let environment {
            fields["variables"] = String(environment.count)
            record(level: "info", message: "login shell environment read", fields: fields)
        } else {
            record(level: "warning", message: "login shell environment unavailable", fields: fields)
        }
    }

    private func replaceOverlay(_ environment: [String: String]) {
        var values = environment
        values.removeValue(forKey: "PATH")
        lock.withLock { overlay = values }
    }

    /// Applies the login shell's `PATH` to this process. Must run at startup before
    /// any other thread reads the environment, because `setenv` is not thread-safe.
    /// Returns the background refresh to start afterwards, if any.
    @discardableResult
    static func activate(
        cacheURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        shared: MacLoginShellEnvironment = .shared,
        shellTimeout: TimeInterval? = nil,
        applyPath: (String) -> Void = { setenv("PATH", $0, 1) }
    ) -> (@Sendable () -> Void)? {
        let shell = loginShell(environment: environment)
        shared.prepare(shell: shell, cacheURL: cacheURL, environment: environment)
        guard environment[skipVariable] == nil else { return nil }
        let cachedPath = (try? String(contentsOf: cacheURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let loginPath: String
        if let cachedPath, !cachedPath.isEmpty {
            loginPath = cachedPath
        } else {
            // A slow rc file must not delay the first start indefinitely.
            let started = ContinuousClock.now
            let login = read(shell: shell, timeout: shellTimeout ?? coldStartTimeout)
            shared.recordRead(login, shell: shell, source: "startup", started: started)
            guard let login, let path = login["PATH"], !path.isEmpty else { return nil }
            shared.replaceOverlay(login)
            writeCache(path, to: cacheURL)
            loginPath = path
        }
        let processPath = mergedPath(login: loginPath, inherited: environment["PATH"])
        applyPath(processPath)
        shared.lock.withLock {
            shared.launch.fromCache = cachedPath?.isEmpty == false
            shared.launch.loginPath = entries(loginPath)
            shared.launch.processPath = entries(processPath)
        }
        guard cachedPath?.isEmpty == false else { return nil }
        // Marked before the closure runs, so a settings page opened meanwhile joins this read.
        shared.lock.withLock { shared.isReading = true }
        return { shared.refresh(source: "refresh", timeout: shellTimeout ?? refreshTimeout, joining: false) }
    }

    /// Records the shell and the inherited `PATH` before anything is applied, so an
    /// inspector can describe a process that skipped or failed the startup read.
    func prepare(shell: String, cacheURL: URL?, environment: [String: String]) {
        lock.withLock {
            launch = Launch(shell: shell, cacheURL: cacheURL, disabled: environment[Self.skipVariable] != nil,
                            processPath: Self.entries(environment["PATH"] ?? ""))
        }
    }

    /// Reads the shell again for children's non-`PATH` variables and the next launch's
    /// cached `PATH`. This process keeps its `PATH`: `setenv` is unsafe once threads run.
    func rereadSynchronously(timeout: TimeInterval = MacLoginShellEnvironment.refreshTimeout) -> LoginShellEnvironmentSnapshot {
        refresh(source: "manual", timeout: timeout, joining: true)
        return inspect()
    }

    func reread() async -> LoginShellEnvironmentSnapshot {
        // The read blocks on a semaphore for up to the timeout; keep it off the cooperative pool.
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: self.rereadSynchronously()) }
        }
    }

    private func refresh(source: String, timeout: TimeInterval, joining: Bool) {
        let (shell, cacheURL, disabled, requested) = lock.withLock {
            (launch.shell, launch.cacheURL, launch.disabled, completedReads)
        }
        guard let shell, !disabled else { return }
        readLock.withLock {
            // A read that finished while this request waited already answers it.
            if joining, lock.withLock({ completedReads > requested }) { return }
            lock.withLock { isReading = true }
            defer { lock.withLock { isReading = false } }
            let started = ContinuousClock.now
            let login = Self.read(shell: shell, timeout: timeout)
            recordRead(login, shell: shell, source: source, started: started)
            guard let login else { return }
            replaceOverlay(login)
            if let cacheURL, let path = login["PATH"], !path.isEmpty {
                Self.writeCache(path, to: cacheURL)
            }
        }
    }

    func inspect() -> LoginShellEnvironmentSnapshot {
        lock.withLock {
            var snapshot = LoginShellEnvironmentSnapshot(shell: launch.shell ?? "")
            if launch.disabled { snapshot.state = .disabled }
            else if isReading { snapshot.state = .reading }
            else if let lastRead { snapshot.state = lastRead.variables == nil ? .failed : .read }
            if let lastRead {
                snapshot.readAt = lastRead.date
                snapshot.variableCount = lastRead.variables
                let (seconds, attoseconds) = lastRead.duration.components
                snapshot.durationMilliseconds = Int(seconds) * 1_000 + Int(attoseconds / 1_000_000_000_000_000)
            }
            snapshot.startedFromCache = launch.fromCache
            let login = Set(launch.loginPath)
            snapshot.processPath = launch.processPath.map {
                .init(path: $0, origin: login.contains($0) ? .loginShell : .inherited)
            }
            if let latestLoginPath, !launch.disabled {
                snapshot.pathChangedSinceLaunch = latestLoginPath != launch.loginPath
            }
            return snapshot
        }
    }

    private static func entries(_ path: String) -> [String] {
        var seen = Set<String>()
        return path.split(separator: ":").map(String.init).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The login shell's entries first, as in a terminal; then inherited entries it
    /// lacks, so a Lithe started from a terminal keeps that session's additions.
    static func mergedPath(login: String, inherited: String?) -> String {
        var seen = Set<String>()
        let entries = (login.split(separator: ":") + (inherited ?? "").split(separator: ":"))
            .map(String.init)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return entries.joined(separator: ":")
    }

    static func loginShell(environment: [String: String]) -> String {
        if let shell = environment["SHELL"], shell.hasPrefix("/") { return shell }
        return "/bin/zsh"
    }

    /// The environment of `shell` started as an interactive login shell, or `nil`
    /// when it fails or does not finish within `timeout`.
    static func read(shell: String, timeout: TimeInterval) -> [String: String]? {
        // Keep this read from looping back into itself through a shell that starts Lithe.
        var environment = ProcessInfo.processInfo.environment
        environment[skipVariable] = "1"
        // stdout stays raw bytes: one non-UTF-8 greeting or value must not discard the
        // rest, and stderr is not mixed in between the markers.
        // `FileHandle.nullDevice` has no descriptor posix_spawn can duplicate.
        guard let discardedErrors = FileHandle(forWritingAtPath: "/dev/null") else { return nil }
        let output = Pipe()
        let process = MacManagedProcess(
            executableURL: URL(fileURLWithPath: shell),
            arguments: ["-ilc", "printf '\(marker)'; /usr/bin/env -0; printf '\(marker)'"],
            environment: environment,
            standardInput: FileHandle.nullDevice,
            standardOutput: output.fileHandleForWriting,
            standardError: discardedErrors
        )
        let finished = DispatchSemaphore(value: 0)
        let collected = OutputBox()
        // Drain while waiting: a large environment would otherwise fill the pipe
        // and stall the shell until the timeout.
        DispatchQueue.global(qos: .utility).async {
            collected.set(output.fileHandleForReading.readDataToEndOfFile())
            finished.signal()
        }
        do {
            try process.run()
        } catch {
            try? output.fileHandleForWriting.close()
            try? discardedErrors.close()
            return nil
        }
        try? output.fileHandleForWriting.close()
        try? discardedErrors.close()
        guard finished.wait(timeout: .now() + timeout) == .success else {
            // Ends the shell and every job its rc file left in the process group, so
            // nothing outlives the read and the pipe reaches end-of-file.
            process.terminateAndWait()
            return nil
        }
        // Both markers prove the output is complete, whatever the shell's exit status.
        return parse(collected.get())
    }

    static func parse(_ data: Data) -> [String: String]? {
        let marker = Data(self.marker.utf8)
        guard let start = data.range(of: marker),
              let end = data.range(of: marker, in: start.upperBound..<data.endIndex) else { return nil }
        var result: [String: String] = [:]
        for entry in data[start.upperBound..<end.lowerBound].split(separator: 0) {
            guard let equals = entry.firstIndex(of: UInt8(ascii: "=")),
                  let key = String(data: entry[entry.startIndex..<equals], encoding: .utf8),
                  let value = String(data: entry[(equals + 1)...], encoding: .utf8),
                  !key.isEmpty, !shellOwnVariables.contains(key) else { continue }
            result[key] = value
        }
        return result
    }

    private static func writeCache(_ path: String, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? path.write(to: url, atomically: true, encoding: .utf8)
    }

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ value: Data) { lock.withLock { data = value } }
        func get() -> Data { lock.withLock { data } }
    }
}
