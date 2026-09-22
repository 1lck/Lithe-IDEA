import Foundation
import Testing
@testable import Lithe

@Suite("macOS runtime discovery")
struct MacRuntimeDiscoveryTests {
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
