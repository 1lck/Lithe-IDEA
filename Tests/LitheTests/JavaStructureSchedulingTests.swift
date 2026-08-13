import Foundation
import Testing
@testable import Lithe

@Suite("Java structure scheduling")
struct JavaStructureSchedulingTests {
    @Test
    func localStructureFallbackOnlyHandlesJavaFiles() {
        #expect(EditorLocalStructurePolicy.supports(fileExtension: "java"))
        #expect(EditorLocalStructurePolicy.supports(fileExtension: "JAVA"))
        #expect(!EditorLocalStructurePolicy.supports(fileExtension: "rs"))
        #expect(!EditorLocalStructurePolicy.supports(fileExtension: "go"))
        #expect(!EditorLocalStructurePolicy.supports(fileExtension: ""))
    }

    @Test
    @MainActor
    func structureParsingRunsOffTheMainThread() async {
        let operations = StructureThreadRecordingJavaOperations()
        let feature = JavaFeatureModel(
            operations: operations,
            workspaceOperations: StructureTestWorkspaceOperations()
        )

        let result = await feature.structureAsync(source: "class Demo {}")

        #expect(result?.foldRegions.count == 1)
        #expect(operations.structureRanOnMainThread == false)
    }
}

private final class StructureThreadRecordingJavaOperations: JavaMavenOperations, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedStructureRanOnMainThread: Bool?

    var structureRanOnMainThread: Bool? {
        lock.withLock { recordedStructureRanOnMainThread }
    }

    func scanMavenProject(at rootURL: URL) -> MavenProject? { nil }
    func mavenDiagnostics(output: String, projectRoot: URL) -> [MavenBuildIssue] { [] }
    func codeVision(
        at rootURL: URL,
        targetPath: String,
        paths: [String]
    ) -> [JavaCodeVisionValue] { [] }
    func className(source: String, simpleName: String) -> String? { nil }
    func sourceDefinition(
        source: String,
        declarationName: String,
        memberName: String?
    ) -> (line: Int, utf16Column: Int)? { nil }
    func serverPort(content: String, fileExtension: String) -> Int? { nil }
    func scanRunConfigurations(
        at rootURL: URL,
        files: [URL],
        mavenProject: MavenProject?
    ) -> [JavaRunConfiguration] { [] }

    func structure(
        source: String,
        declarationSources: [String]
    ) -> JavaStructureResult? {
        lock.withLock {
            recordedStructureRanOnMainThread = Thread.isMainThread
        }
        return JavaStructureResult(
            foldRegions: [
                JavaFoldRegion(
                    kind: .type,
                    startLine: 0,
                    endLine: 0,
                    hiddenRange: NSRange(location: 0, length: 0)
                )
            ],
            implementationMarkers: [],
            inlayHints: []
        )
    }
}

private struct StructureTestWorkspaceOperations: WorkspaceOperations {
    func snapshot(
        at rootURL: URL,
        visibilityRules: FileVisibilityRules
    ) -> WorkspaceSnapshot? { nil }

    func search(
        at rootURL: URL,
        query: String,
        options: ProjectSearchOptions,
        visibilityRules: FileVisibilityRules
    ) -> [FileSearchResult]? { nil }

    func searchEverywhere(
        at rootURL: URL,
        query: String,
        options: ProjectSearchOptions,
        visibilityRules: FileVisibilityRules
    ) -> SearchEverywhereResults? { nil }

    func previewReplacement(
        at rootURL: URL,
        query: String,
        replacement: String,
        options: ProjectSearchOptions,
        paths: [String],
        textOverrides: [String: String],
        visibilityRules: FileVisibilityRules
    ) -> [ProjectReplacementFile]? { nil }

    func readFile(at rootURL: URL, relativePath: String) -> String? { nil }
    func writeFile(_ text: String, at rootURL: URL, relativePath: String) -> Bool { false }
}
