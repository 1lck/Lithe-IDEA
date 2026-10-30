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
final class MacLoginShellEnvironment: @unchecked Sendable {
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
        var fields = [
            "shell": URL(fileURLWithPath: shell).lastPathComponent,
            "source": source,
            "duration": String(describing: started.duration(to: .now))
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
        guard environment[skipVariable] == nil else { return nil }
        let shell = loginShell(environment: environment)
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
        applyPath(mergedPath(login: loginPath, inherited: environment["PATH"]))
        guard cachedPath?.isEmpty == false else { return nil }
        return {
            let started = ContinuousClock.now
            let login = read(shell: shell, timeout: shellTimeout ?? refreshTimeout)
            shared.recordRead(login, shell: shell, source: "refresh", started: started)
            guard let login else { return }
            shared.replaceOverlay(login)
            if let path = login["PATH"], !path.isEmpty {
                writeCache(path, to: cacheURL)
            }
        }
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
