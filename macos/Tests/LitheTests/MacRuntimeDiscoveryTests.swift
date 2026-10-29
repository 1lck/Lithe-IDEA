import Foundation
import Testing
@testable import Lithe

@Suite("macOS runtime discovery")
struct MacRuntimeDiscoveryTests {
    @Test
    func resolvesJavaHomeFromPathSymlinkWithoutLaunchingIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("custom-jdk", isDirectory: true)
        try createExecutableJava(at: home)
        let bin = root.appendingPathComponent("path-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("java"), withDestinationURL: home.appendingPathComponent("bin/java"))
        let environment = ["PATH": bin.path]
        let resolved = MacRuntimeDiscovery.javaHomeOnPath(in: environment, systemJavaHome: { nil })
        #expect(resolved?.resolvingSymlinksInPath().path == home.resolvingSymlinksInPath().path)
    }

    @Test
    func skipsSystemJavaLauncherForLaterPathJDKAndOtherwiseResolvesItsDefault() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-java-launcher-\(UUID().uuidString)", isDirectory: true)
        defer { removeFixture(root) }
        let shellHome = root.appendingPathComponent("mise/installs/java/21", isDirectory: true)
        let defaultHome = root.appendingPathComponent("default-jdk", isDirectory: true)
        try createExecutableJava(at: shellHome)
        try createExecutableJava(at: defaultHome)
        let launcherDirectory = "/usr/bin"
        try #require(FileManager.default.isExecutableFile(atPath: launcherDirectory + "/java"))

        // A launcher that is not inside a JDK home must not end the scan.
        let shim = root.appendingPathComponent("shims", isDirectory: true)
        try FileManager.default.createDirectory(at: shim, withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: shim.appendingPathComponent("java").path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.appendingPathComponent("java").path)

        // A Finder/Dock PATH puts Apple's launcher before the login shell's JDK.
        let guiThenShell = ["PATH": [launcherDirectory, shim.path, shellHome.appendingPathComponent("bin").path].joined(separator: ":")]
        let shellResult = MacRuntimeDiscovery.javaHomeOnPath(in: guiThenShell, systemJavaHome: { defaultHome.path })
        #expect(shellResult?.resolvingSymlinksInPath() == shellHome.resolvingSymlinksInPath())

        // With only the launcher on PATH, use the JDK it would launch.
        let launcherOnly = ["PATH": launcherDirectory]
        let defaultResult = MacRuntimeDiscovery.javaHomeOnPath(in: launcherOnly, systemJavaHome: { defaultHome.path })
        #expect(defaultResult?.resolvingSymlinksInPath() == defaultHome.resolvingSymlinksInPath())
        #expect(MacRuntimeDiscovery.javaHomeOnPath(in: launcherOnly, systemJavaHome: { nil }) == nil)
    }

    @Test
    func readsAtMostTheLimitOfManagedInstallationEntries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-managed-bound-\(UUID().uuidString)", isDirectory: true)
        defer { removeFixture(root) }
        for index in 0..<5 {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("v\(index)", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        #expect(MacRuntimeDiscovery.boundedDirectoryNames(at: root.path, limit: 3).count == 3)
        #expect(MacRuntimeDiscovery.boundedDirectoryNames(at: root.path, limit: 10).count == 5)
        #expect(MacRuntimeDiscovery.boundedDirectoryNames(at: root.appendingPathComponent("missing").path, limit: 3).isEmpty)
    }

    @Test
    func parsesOnlyBoundedLoginShellEnvironmentAfterMarker() {
        let marker = "\0__LITHE_LOGIN_SHELL_ENVIRONMENT__\0"
        let noisyStartup = "rc warning PATH=/bogus\0"
        let parsed = MacRuntimeDiscovery.parseLoginShellEnvironment(
            noisyStartup + marker + "PATH=/shell/bin:/usr/bin\0JAVA_HOME=/jdk\0=broken\0bad-name=1\0"
        )
        #expect(parsed == ["PATH": "/shell/bin:/usr/bin", "JAVA_HOME": "/jdk"])
        #expect(MacRuntimeDiscovery.parseLoginShellEnvironment("PATH=/no/marker\0").isEmpty)

        let oversized = marker + "PATH=" + String(repeating: "a", count: 256 * 1_024)
        #expect(MacRuntimeDiscovery.parseLoginShellEnvironment(oversized).isEmpty)
        let tooMany = marker + (0...1_024).map { "V\($0)=1\0" }.joined()
        #expect(MacRuntimeDiscovery.parseLoginShellEnvironment(tooMany).isEmpty)
    }

    @Test
    func discoversSDKMANJavaCandidatesFromDefaultDirectory() throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-sdkman-runtime-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let javaRoot = testRoot.appendingPathComponent(".sdkman/candidates/java", isDirectory: true)
        let javaHome = javaRoot.appendingPathComponent("25.0.1-zulu", isDirectory: true)
        try createExecutableJava(at: javaHome)
        try FileManager.default.createSymbolicLink(
            at: javaRoot.appendingPathComponent("current"),
            withDestinationURL: javaHome
        )

        let homes = MacRuntimeDiscovery.discoverJavaHomes(
            environment: [:],
            homeDirectory: testRoot.path,
            javaHomePaths: [],
            directoryEntries: try directoryEntries(in: javaRoot)
        )

        #expect(homes.count == 1)
        #expect(homes.first?.resolvingSymlinksInPath() == javaHome.resolvingSymlinksInPath())
    }

    @Test
    func honorsCustomSDKMANDirectoryAndIgnoresInvalidCandidates() throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-sdkman-custom-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let sdkmanRoot = testRoot.appendingPathComponent("sdkman", isDirectory: true)
        let javaRoot = sdkmanRoot.appendingPathComponent("candidates/java", isDirectory: true)
        let javaHome = javaRoot.appendingPathComponent("21.0.8-tem", isDirectory: true)
        try createExecutableJava(at: javaHome)
        try FileManager.default.createDirectory(
            at: javaRoot.appendingPathComponent("incomplete"),
            withIntermediateDirectories: true
        )

        let homes = MacRuntimeDiscovery.discoverJavaHomes(
            environment: ["SDKMAN_DIR": sdkmanRoot.path],
            homeDirectory: testRoot.appendingPathComponent("home").path,
            javaHomePaths: [],
            directoryEntries: try directoryEntries(in: javaRoot)
        )

        #expect(homes == [javaHome.standardizedFileURL])
    }

    @Test
    func discoversManagedJavaAndMavenRootsAndPreservesInheritedEnvironmentPriority() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-managed-runtimes-\(UUID().uuidString)", isDirectory: true)
        defer { removeFixture(root) }

        let miseJavaHome = root.appendingPathComponent("mise/installs/java/21")
        let asdfJavaHome = root.appendingPathComponent("asdf/installs/java/17")
        try createExecutableJava(at: miseJavaHome)
        try createExecutableJava(at: asdfJavaHome)

        let miseMavenHome = root.appendingPathComponent("mise/installs/maven/3.9.9")
        let mavenExecutable = miseMavenHome.appendingPathComponent("bin/mvn")
        try FileManager.default.createDirectory(at: mavenExecutable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: mavenExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mavenExecutable.path)
        try FileManager.default.createSymbolicLink(
            at: miseMavenHome.deletingLastPathComponent().appendingPathComponent("current"),
            withDestinationURL: miseMavenHome
        )

        let shellEnvironment = [
            "PATH": root.appendingPathComponent("shell/bin").path,
            "MISE_DATA_DIR": root.appendingPathComponent("mise").path,
            "ASDF_DATA_DIR": root.appendingPathComponent("asdf").path
        ]
        let merged = MacRuntimeDiscovery.mergeEnvironment(
            ["PATH": "/fixture/bin", "JAVA_HOME": "/explicit"],
            shellEnvironment: shellEnvironment
        )
        #expect(merged["PATH"] == "/fixture/bin:" + shellEnvironment["PATH"]!)
        #expect(merged["JAVA_HOME"] == "/explicit")

        let homes = MacRuntimeDiscovery.discoverJavaHomes(
            environment: merged,
            homeDirectory: root.path,
            javaHomePaths: [],
            directoryEntries: { path in
                guard path.hasPrefix(root.path) else { return [] }
                return (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            }
        )
        #expect(homes.count == 2)
        #expect(homes.contains { $0.resolvingSymlinksInPath() == miseJavaHome.resolvingSymlinksInPath() })
        let maven = MacRuntimeDiscovery.discoverMavenExecutables(
            environment: merged,
            isExecutable: { $0.resolvingSymlinksInPath().path == mavenExecutable.resolvingSymlinksInPath().path }
        )
        #expect(maven == [mavenExecutable.standardizedFileURL])
    }

    @Test
    func discoversMvndWithoutProbingAndPreservesMavenPriority() {
        func discover(_ environment: [String: String], files: Set<String>) -> [String] {
            MacRuntimeDiscovery.discoverMavenExecutables(
                environment: environment, isExecutable: { files.contains($0.path) }
            ).map(\.path)
        }
        let daemon = "/fixture/daemon/bin/mvnd"
        let pathDaemon = "/fixture/path/mvnd"
        let maven = "/fixture/maven/bin/mvn"
        #expect(discover(["MVND_HOME": "/fixture/daemon"], files: [daemon]) == [daemon])
        #expect(discover(["PATH": "/fixture/path"], files: [pathDaemon]) == [pathDaemon])
        #expect(discover(["MVND_HOME": "/missing", "PATH": "/fixture/path"], files: [pathDaemon]) == [pathDaemon])
        #expect(discover(
            ["MAVEN_HOME": "/fixture/maven", "MVND_HOME": "/fixture/daemon", "PATH": "/fixture/path"],
            files: [daemon, pathDaemon, maven]
        ) == [maven, daemon, pathDaemon])
        #expect(discover(
            ["PATH": "/fixture/path:/fixture/maven/bin:/fixture/path"], files: [pathDaemon, maven]
        ) == [maven, pathDaemon])
        #expect(discover(["M2_HOME": "/fixture/maven"], files: [maven]) == [maven])
        #expect(discover(["MVND_HOME": "/missing"], files: []) == [])
        #expect(discover([:], files: ["/opt/homebrew/bin/mvnd"]) == ["/opt/homebrew/bin/mvnd"])
        #expect(discover([:], files: ["/usr/local/bin/mvn", "/opt/homebrew/bin/mvnd"])
            == ["/usr/local/bin/mvn", "/opt/homebrew/bin/mvnd"])
    }

    @Test
    func explicitDaemonHomeNeverFallsBackToEmbeddedMaven() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let embedded = root.appendingPathComponent("mvn/bin/mvn")
        try FileManager.default.createDirectory(at: embedded.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: embedded)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: embedded.path)
        #expect(MacRuntimeDiscovery.mavenExecutable(forHomePath: root.path) == nil)
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        // Traversable directories named like launchers are not executable files.
        try FileManager.default.createDirectory(at: bin.appendingPathComponent("mvnd"), withIntermediateDirectories: true)
        #expect(MacRuntimeDiscovery.mavenExecutable(forHomePath: root.path) == nil)
    }

    @Test
    func mavenVersionsMatchSharedContract() throws {
        struct Fixture: Decodable {
            struct Case: Decodable { let output: String; let version: String? }
            let cases: [Case]
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf:
            root.appendingPathComponent("shared/fixtures/execution/maven-runtime-versions.json")))
        for example in fixture.cases {
            #expect(MacRuntimeDiscovery.mavenVersion(in: example.output) == example.version)
        }
    }

    @Test
    func shellEnvironmentCacheOnlyAnswersForTheEnvironmentItWasReadFor() {
        let cache = MacShellEnvironmentCache()
        let gui = ["PATH": "/usr/bin:/bin"]
        #expect(cache.shellEnvironment(for: gui) == nil)
        #expect(cache.systemJavaHome() == nil)
        cache.store(["JAVA_HOME": "/managed/jdk"], for: gui)
        cache.storeSystemJavaHome("/default/jdk")
        #expect(cache.shellEnvironment(for: gui) == ["JAVA_HOME": "/managed/jdk"])
        #expect(cache.shellEnvironment(for: ["PATH": "/other"]) == nil)
        #expect(cache.systemJavaHome() == "/default/jdk")
    }

    @Test
    func selectionEnvironmentNeverStartsALoginShellBeforeDiscovery() {
        // No discovery has read a shell for this environment, so selection
        // must return it unchanged instead of launching one synchronously.
        let environment = ["PATH": "/usr/bin:/bin", "LITHE_TEST_MARKER": UUID().uuidString]
        #expect(MacRuntimeDiscovery.cachedEnrichedEnvironment(environment) == environment)
    }

    private func removeFixture(_ root: URL) {
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Runtime discovery fixture cleanup failed at \(root.path): \(error)") }
    }

    private func createExecutableJava(at home: URL) throws {
        let executable = home.appendingPathComponent("bin/java")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        #expect(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
    }

    private func directoryEntries(in fixtureRoot: URL) throws -> (String) -> [String] {
        let fixturePath = fixtureRoot.standardizedFileURL.path
        let entries = try FileManager.default.contentsOfDirectory(atPath: fixturePath)
        // Discovery also asks for system and Homebrew directories. Only expose
        // this fixture so installed JDKs cannot affect either test's assertions.
        return { path in path == fixturePath ? entries : [] }
    }
}
