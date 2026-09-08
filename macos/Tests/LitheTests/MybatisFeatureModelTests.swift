import Foundation
import Testing
@testable import Lithe

@Suite("MyBatis feature model")
@MainActor
struct MybatisFeatureModelTests {
    @Test
    func mapperMethodNavigationJumpsToTheXmlStatement() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let javaURL = root.appendingPathComponent("src/main/java/demo/UserMapper.java")
        let xmlURL = root.appendingPathComponent("src/main/resources/mapper/UserMapper.xml")
        let feature = MybatisFeatureModel(operations: MybatisTestOperations(result: index(
            javaURL: javaURL,
            xmlURL: xmlURL
        )))
        await feature.load(workspaceURL: root, files: [javaURL, xmlURL])

        let location = try #require(feature.navigationLocations(for: javaURL, line: 8).first)
        #expect(location.url == xmlURL)
        #expect(location.range.start.line == 4)
        #expect(location.range.start.utf16Column == 16)
        #expect(feature.handles(javaURL))
        #expect(feature.handles(xmlURL))
    }

    @Test
    func xmlStatementNavigationJumpsToTheMapperMethod() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let javaURL = root.appendingPathComponent("UserMapper.java")
        let xmlURL = root.appendingPathComponent("UserMapper.xml")
        let feature = MybatisFeatureModel(operations: MybatisTestOperations(result: index(
            javaURL: javaURL,
            xmlURL: xmlURL
        )))
        await feature.load(workspaceURL: root, files: [javaURL, xmlURL])

        let location = try #require(feature.navigationLocations(for: xmlURL, line: 4).first)
        #expect(location.url == javaURL)
        #expect(location.range.start.line == 8)
        #expect(location.range.start.utf16Column == 9)
    }

    @Test
    func multilineMapperSignatureStillNavigatesFromLaterLines() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let javaURL = root.appendingPathComponent("UserMapper.java")
        let xmlURL = root.appendingPathComponent("UserMapper.xml")
        let feature = MybatisFeatureModel(operations: MybatisTestOperations(result: MybatisIndexResult(
            statements: [MybatisStatement(
                id: "selectById",
                namespace: "demo.UserMapper",
                statementID: "selectById",
                kind: "select",
                javaURL: javaURL,
                javaLine: 9,
                javaColumn: 10,
                javaEndLine: 12,
                xmlURL: xmlURL,
                xmlLine: 5,
                xmlColumn: 17
            )]
        )))
        await feature.load(workspaceURL: root, files: [javaURL, xmlURL])

        let location = try #require(feature.navigationLocations(for: javaURL, line: 11).first)
        #expect(location.url == xmlURL)
    }

    /// Opening a workspace must not wait for mapper indexing.
    @Test
    func scheduleLoadDefersIndexingAndPublishesTheResult() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let javaURL = root.appendingPathComponent("UserMapper.java")
        let xmlURL = root.appendingPathComponent("UserMapper.xml")
        let operations = MybatisTestOperations(result: index(javaURL: javaURL, xmlURL: xmlURL))
        let feature = MybatisFeatureModel(operations: operations)
        defer { feature.reset() }

        feature.scheduleLoad(workspaceURL: root, files: [javaURL, xmlURL])

        #expect(feature.statements.isEmpty)
        #expect(operations.requestedFiles.isEmpty)

        let published = await awaitChange(on: feature) {
            !feature.isIndexing && !feature.statements.isEmpty
        }
        #expect(published, "the scheduled index never published a result")
        #expect(feature.statements.map(\.statementID) == ["selectById"])
        #expect(operations.requestedFiles == [[javaURL, xmlURL]])
    }

    /// A newer schedule supersedes the pending one so a burst of reloads cannot
    /// publish a stale index.
    @Test
    func scheduleLoadReplacesAPendingSchedule() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let staleURL = root.appendingPathComponent("StaleMapper.java")
        let freshURL = root.appendingPathComponent("FreshMapper.java")
        let xmlURL = root.appendingPathComponent("UserMapper.xml")
        let operations = MybatisTestOperations { files in
            files.first.map { index(javaURL: $0, xmlURL: xmlURL) } ?? .empty
        }
        let feature = MybatisFeatureModel(operations: operations)
        defer { feature.reset() }

        feature.scheduleLoad(workspaceURL: root, files: [staleURL])
        feature.scheduleLoad(workspaceURL: root, files: [freshURL])

        let published = await awaitChange(on: feature) {
            !feature.isIndexing && !feature.statements.isEmpty
        }
        #expect(published, "the replacement schedule never published a result")
        #expect(operations.requestedFiles == [[freshURL]])
        #expect(feature.statements.map(\.javaURL) == [freshURL])
    }
}

private func index(javaURL: URL, xmlURL: URL) -> MybatisIndexResult {
    MybatisIndexResult(
        statements: [MybatisStatement(
            id: javaURL.lastPathComponent,
            namespace: "demo.UserMapper",
            statementID: "selectById",
            kind: "select",
            javaURL: javaURL,
            javaLine: 9,
            javaColumn: 10,
            javaEndLine: 9,
            xmlURL: xmlURL,
            xmlLine: 5,
            xmlColumn: 17
        )]
    )
}

private final class MybatisTestOperations: JavaMavenOperations, @unchecked Sendable {
    private let makeResult: @Sendable ([URL]) -> MybatisIndexResult
    private let lock = NSLock()
    private var requested: [[URL]] = []

    var requestedFiles: [[URL]] {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    init(result: MybatisIndexResult) {
        makeResult = { _ in result }
    }

    init(resultForFiles: @escaping @Sendable ([URL]) -> MybatisIndexResult) {
        makeResult = resultForFiles
    }

    func mybatisIndex(
        at rootURL: URL,
        files: [URL],
        textOverrides: [URL: String]
    ) -> MybatisIndexResult? {
        lock.lock()
        requested.append(files)
        lock.unlock()
        return makeResult(files)
    }

    func scanMavenProject(at rootURL: URL, files: [URL]) -> MavenProject? { nil }
    func mavenDiagnostics(output: String, projectRoot: URL) -> [MavenBuildIssue] { [] }
    func codeVision(at rootURL: URL, targetPath: String, paths: [String]) -> [JavaCodeVisionValue] { [] }
    func className(source: String, simpleName: String) -> String? { nil }
    func sourceDefinition(source: String, declarationName: String, memberName: String?) -> (line: Int, utf16Column: Int)? { nil }
    func serverPort(content: String, fileExtension: String) -> Int? { nil }
    func scanRunConfigurations(at rootURL: URL, files: [URL], mavenProject: MavenProject?) -> [JavaRunConfiguration] { [] }
    func structure(source: String, declarationSources: [String]) -> JavaStructureResult? { nil }
}
