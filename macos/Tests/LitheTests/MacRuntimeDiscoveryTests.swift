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
        #expect(MacRuntimeDiscovery.javaHomeOnPath(environment: environment)?.resolvingSymlinksInPath().path == home.resolvingSymlinksInPath().path)
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
