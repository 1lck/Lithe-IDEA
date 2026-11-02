import Foundation
import Testing
@testable import Lithe

/// A Lithe started from Finder inherits launchd's minimal environment; these cover
/// reading the login shell instead (#1514, #1455). The shell is a stand-in script
/// that sources `rc` and runs the IDE's `-ilc` command, so no user rc file runs.
@Suite("macOS login shell environment")
struct MacLoginShellEnvironmentTests {
    /// Bounds a stand-in shell that should finish at once; generous so a loaded CI
    /// host does not turn a slow process start into a false failure.
    static let shellTimeout: TimeInterval = 30

    @Test
    func readsTheLoginEnvironmentWithoutShellBookkeeping() throws {
        let fixture = try ShellFixture()
        defer { fixture.remove() }
        try fixture.writeRC("""
        echo 'Welcome back'
        printf '\\377 legacy-encoded motd\\n'
        echo 'rc warning' >&2
        export LITHE_TEST_RC='two words'
        export PATH=/fixture/mise/shims:$PATH
        """)

        let environment = try #require(MacLoginShellEnvironment.read(shell: fixture.shell, timeout: Self.shellTimeout))

        #expect(environment["LITHE_TEST_RC"] == "two words")
        #expect(environment["PATH"]?.hasPrefix("/fixture/mise/shims:") == true)
        #expect(environment["PWD"] == nil)
        #expect(environment["SHLVL"] == nil)
    }

    @Test
    func aShellThatHangsTimesOut() throws {
        let fixture = try ShellFixture()
        defer { fixture.remove() }
        // The hang is in a job the rc file started, which holds the output pipe open;
        // the timeout ends the whole process group, not only the shell.
        try fixture.writeRC("sleep 30 &\nwait")

        #expect(MacLoginShellEnvironment.read(shell: fixture.shell, timeout: 0.2) == nil)
    }

    @Test
    func parsingIgnoresGreetingsAndRequiresBothMarkers() {
        let marker = "__LITHE_LOGIN_ENV__"
        let output = Data("motd\n\(marker)A=1\u{0}B=x=y\u{0}_=/usr/bin/env\u{0}\(marker)bye".utf8)
        #expect(MacLoginShellEnvironment.parse(output) == ["A": "1", "B": "x=y"])
        #expect(MacLoginShellEnvironment.parse(Data("\(marker)A=1".utf8)) == nil)
    }

    @Test
    func loginPathLeadsAndInheritedEntriesAreKept() {
        let path = MacLoginShellEnvironment.mergedPath(
            login: "/opt/homebrew/bin:/usr/bin:/bin",
            inherited: "/usr/bin:/bin:/venv/bin"
        )
        #expect(path == "/opt/homebrew/bin:/usr/bin:/bin:/venv/bin")
    }

    @Test
    func theProcessEnvironmentWinsOverTheLoginShell() {
        let shell = MacLoginShellEnvironment(overlay: ["JAVA_HOME": "/login/jdk", "MAVEN_HOME": "/login/maven"])
        let merged = shell.merged(["JAVA_HOME": "/explicit/jdk"])
        #expect(merged["JAVA_HOME"] == "/explicit/jdk")
        #expect(merged["MAVEN_HOME"] == "/login/maven")
    }

    @Test
    func coldStartReadsTheShellAndWarmStartUsesTheCachedPath() throws {
        let fixture = try ShellFixture()
        defer { fixture.remove() }
        try fixture.writeRC("""
        export PATH=/fixture/first:$PATH
        export JAVA_HOME=/fixture/jdk
        """)
        let cache = fixture.root.appendingPathComponent("cache/login-path")
        let shared = MacLoginShellEnvironment()
        var applied: [String] = []
        let environment = ["SHELL": fixture.shell, "PATH": "/usr/bin:/bin"]

        let coldRefresh = MacLoginShellEnvironment.activate(
            cacheURL: cache, environment: environment, shared: shared,
            shellTimeout: Self.shellTimeout, applyPath: { applied.append($0) }
        )
        #expect(coldRefresh == nil)
        #expect(applied.last?.hasPrefix("/fixture/first:") == true)
        #expect(try String(contentsOf: cache, encoding: .utf8).hasPrefix("/fixture/first:"))
        #expect(shared.merged([:])["JAVA_HOME"] == "/fixture/jdk")

        try fixture.writeRC("export PATH=/fixture/second:$PATH")
        let warmShared = MacLoginShellEnvironment()
        let warmRefresh = try #require(MacLoginShellEnvironment.activate(
            cacheURL: cache, environment: environment, shared: warmShared,
            shellTimeout: Self.shellTimeout, applyPath: { applied.append($0) }
        ))
        // The cached value applies before the shell is read again.
        #expect(applied.last?.hasPrefix("/fixture/first:") == true)
        warmRefresh()
        #expect(try String(contentsOf: cache, encoding: .utf8).hasPrefix("/fixture/second:"))
        // The refreshed overlay reflects the edited rc file, not the earlier read.
        #expect(warmShared.merged([:])["JAVA_HOME"] != "/fixture/jdk")
    }

    @Test
    func readOutcomesReachTheLogWithoutVariableValues() throws {
        let fixture = try ShellFixture()
        defer { fixture.remove() }
        try fixture.writeRC("export LITHE_TEST_SECRET=hunter2")
        let shared = MacLoginShellEnvironment()
        let environment = ["SHELL": fixture.shell, "PATH": "/usr/bin:/bin"]

        // Startup runs before the log writer exists; its outcome waits for it.
        MacLoginShellEnvironment.activate(
            cacheURL: fixture.root.appendingPathComponent("login-path"),
            environment: environment, shared: shared, applyPath: { _ in }
        )
        let log = RecordingLog()
        shared.attach(logging: log)

        let record = try #require(log.records.first)
        #expect(log.records.count == 1)
        #expect(record.message == "login shell environment read")
        #expect(record.fields["shell"] == "shell")
        #expect(record.fields["source"] == "startup")
        #expect(!record.fields.values.contains { $0.contains("hunter2") })
    }

    @Test
    func theOptOutSkipsTheShell() throws {
        let fixture = try ShellFixture()
        defer { fixture.remove() }
        var applied = false
        let refresh = MacLoginShellEnvironment.activate(
            cacheURL: fixture.root.appendingPathComponent("login-path"),
            environment: ["SHELL": fixture.shell, MacLoginShellEnvironment.skipVariable: "1"],
            shared: MacLoginShellEnvironment(),
            applyPath: { _ in applied = true }
        )
        #expect(refresh == nil)
        #expect(!applied)
    }

    // MARK: Settings inspector

    @Test
    func inspectorMarksWhichPathEntriesCameFromTheLoginShell() throws {
        let fixture = try ShellFixture()
        defer { fixture.remove() }
        try fixture.writeRC("""
        export PATH=/fixture/login/bin:/usr/bin:/bin
        export LITHE_TEST_SECRET=hunter2
        """)
        let shared = MacLoginShellEnvironment()
        MacLoginShellEnvironment.activate(
            cacheURL: fixture.root.appendingPathComponent("login-path"),
            environment: ["SHELL": fixture.shell, "PATH": "/usr/bin:/fixture/launch-only/bin"],
            shared: shared, shellTimeout: Self.shellTimeout, applyPath: { _ in }
        )

        let snapshot = shared.inspect()

        #expect(snapshot.shell == fixture.shell)
        #expect(snapshot.state == .read)
        #expect((snapshot.variableCount ?? 0) > 0)
        #expect(snapshot.durationMilliseconds != nil && snapshot.readAt != nil)
        #expect(!snapshot.startedFromCache && !snapshot.pathChangedSinceLaunch)
        #expect(snapshot.processPath == [
            .init(path: "/fixture/login/bin", origin: .loginShell),
            .init(path: "/usr/bin", origin: .loginShell),
            .init(path: "/bin", origin: .loginShell),
            .init(path: "/fixture/launch-only/bin", origin: .inherited)
        ])
    }

    @Test
    func warmStartIsReadingUntilItsRefreshFinishes() throws {
        let fixture = try ShellFixture()
        defer { fixture.remove() }
        try fixture.writeRC("export PATH=/fixture/cached/bin:/usr/bin")
        let cache = fixture.root.appendingPathComponent("login-path")
        try "/fixture/cached/bin:/usr/bin".write(to: cache, atomically: true, encoding: .utf8)
        let shared = MacLoginShellEnvironment()

        let refresh = try #require(MacLoginShellEnvironment.activate(
            cacheURL: cache, environment: ["SHELL": fixture.shell, "PATH": "/usr/bin"],
            shared: shared, shellTimeout: Self.shellTimeout, applyPath: { _ in }
        ))
        let before = shared.inspect()
        #expect(before.state == .reading && before.startedFromCache)
        #expect(before.variableCount == nil)

        refresh()
        let after = shared.inspect()
        #expect(after.state == .read && after.startedFromCache)
        #expect(!after.pathChangedSinceLaunch)
    }

    @Test
    func rereadKeepsThisProcessPathAndReportsThatTheLoginPathChanged() throws {
        let fixture = try ShellFixture()
        defer { fixture.remove() }
        try fixture.writeRC("export PATH=/fixture/first/bin:/usr/bin")
        let cache = fixture.root.appendingPathComponent("login-path")
        let shared = MacLoginShellEnvironment()
        var applied: [String] = []
        MacLoginShellEnvironment.activate(
            cacheURL: cache, environment: ["SHELL": fixture.shell, "PATH": "/usr/bin"],
            shared: shared, shellTimeout: Self.shellTimeout, applyPath: { applied.append($0) }
        )
        try fixture.writeRC("export PATH=/fixture/second/bin:/usr/bin")

        let snapshot = shared.rereadSynchronously(timeout: Self.shellTimeout)

        #expect(snapshot.state == .read && snapshot.pathChangedSinceLaunch)
        #expect(snapshot.processPath.first?.path == "/fixture/first/bin")
        #expect(applied == ["/fixture/first/bin:/usr/bin"], "A reread must not change this process's PATH")
        #expect(try String(contentsOf: cache, encoding: .utf8).hasPrefix("/fixture/second/bin:"))
    }

    @Test
    func failedReadKeepsTheLaunchPathAndHasNoVariableCount() throws {
        let fixture = try ShellFixture()
        defer { fixture.remove() }
        try fixture.writeRC("exit 3")
        let shared = MacLoginShellEnvironment()
        let refresh = MacLoginShellEnvironment.activate(
            cacheURL: fixture.root.appendingPathComponent("login-path"),
            environment: ["SHELL": fixture.shell, "PATH": "/usr/bin:/bin"],
            shared: shared, shellTimeout: Self.shellTimeout, applyPath: { _ in }
        )

        let snapshot = shared.inspect()

        #expect(refresh == nil)
        #expect(snapshot.state == .failed && snapshot.variableCount == nil)
        #expect(snapshot.processPath == [.init(path: "/usr/bin", origin: .inherited), .init(path: "/bin", origin: .inherited)])
    }

    @Test
    func optOutAndUnreadShellsAreDescribedWithoutRunningTheShell() throws {
        let fixture = try ShellFixture()
        defer { fixture.remove() }
        let ran = fixture.root.appendingPathComponent("ran")
        try fixture.writeRC("touch '\(ran.path)'")

        let prepared = MacLoginShellEnvironment()
        prepared.prepare(shell: fixture.shell, cacheURL: nil, environment: ["PATH": "/usr/bin"])
        #expect(prepared.inspect().state == .notRead)
        #expect(prepared.inspect().processPath == [.init(path: "/usr/bin", origin: .inherited)])

        let disabled = MacLoginShellEnvironment()
        MacLoginShellEnvironment.activate(
            cacheURL: fixture.root.appendingPathComponent("login-path"),
            environment: ["SHELL": fixture.shell, "PATH": "/usr/bin", MacLoginShellEnvironment.skipVariable: "1"],
            shared: disabled, shellTimeout: Self.shellTimeout, applyPath: { _ in }
        )
        #expect(disabled.inspect().state == .disabled)
        #expect(disabled.rereadSynchronously(timeout: Self.shellTimeout).state == .disabled)
        #expect(!FileManager.default.fileExists(atPath: ran.path), "The opt-out must not run the shell, even on reread")
    }
}

private final class RecordingLog: ApplicationLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(message: String, fields: [String: String])] = []

    var records: [(message: String, fields: [String: String])] { lock.withLock { stored } }

    func record(level: String, scope: String, message: String, fields: [String: String]) {
        lock.withLock { stored.append((message, fields)) }
    }

    func collect(query: ApplicationLogQuery) async throws -> ApplicationLogCollection {
        throw CocoaError(.featureUnsupported)
    }

    func configureDiagnostic(category: String?, enabled: Bool) async {}
    func clear() async throws {}
}

private struct ShellFixture {
    let root: URL
    let shell: String
    private let rc: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-login-shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        rc = root.appendingPathComponent("rc")
        let script = root.appendingPathComponent("shell")
        try "#!/bin/sh\n. '\(rc.path)'\nshift\nexec /bin/sh -c \"$1\"\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        shell = script.path
        try writeRC("")
    }

    func writeRC(_ text: String) throws {
        try text.write(to: rc, atomically: true, encoding: .utf8)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
