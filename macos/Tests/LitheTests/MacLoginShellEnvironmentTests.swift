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
        // `exec` keeps the hang in the shell's own process, which the timeout kills.
        try fixture.writeRC("exec sleep 30")

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
