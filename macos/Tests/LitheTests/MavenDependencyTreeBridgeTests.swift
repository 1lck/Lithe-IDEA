import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

/// Plans and reads a dependency-tree file through the linked Rust Core.
///
/// The ordinary Swift unit lane does not link Core, so this suite runs in the
/// Core-linked lane of `scripts/verify-rust-core.sh`.
@Suite("Maven dependency tree through Rust Core")
struct MavenDependencyTreeBridgeTests {
    @Test(.enabled(if: RustCoreBridge().isAvailable, "Requires the linked Rust Core integration library"))
    func mavenDependencyTreeFileIsPlannedAndReadThroughCore() throws {
        try #require(RustCoreBridge().isAvailable)
        let fixture = try MavenDependencyTreeFixture.load()
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-maven-tree-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
        try Data("<project><artifactId>service</artifactId></project>".utf8)
            .write(to: testRoot.appendingPathComponent("pom.xml"))
        let outputFile = testRoot.appendingPathComponent("scratch/tree.txt")
        let operations = RustJavaMavenOperations(core: RustCoreBridge())

        let plan = try operations.mavenDependencyPlan(
            at: testRoot,
            context: MavenLaunchContext(
                reactorPath: ".",
                profiles: [],
                settingsPath: nil,
                skipTests: false,
                mavenExecutablePath: nil,
                javaHomePath: nil
            ),
            module: nil,
            outputFile: outputFile
        )
        #expect(plan.arguments.contains("-DoutputFile=" + outputFile.standardizedFileURL.path))
        #expect(plan.arguments.contains("-N"))

        try Data(fixture.treeFile.utf8).write(to: testRoot.appendingPathComponent("tree.txt"))
        let tree = try operations.mavenDependencies(
            modulePath: fixture.modulePath,
            outputFile: testRoot.appendingPathComponent("tree.txt")
        )
        #expect(tree == (try fixture.expected.makeModel()))

        #expect(throws: MavenOperationError.self) {
            try operations.mavenDependencies(
                modulePath: fixture.modulePath,
                outputFile: testRoot.appendingPathComponent("never-written.txt")
            )
        }
    }
}
