import Foundation
import Testing
@testable import Lithe

@Suite("Spring feature model")
@MainActor
struct SpringFeatureModelTests {
    @Test
    func configurationCompletionHoverDiagnosticsAndNavigationUseTheSharedIndex() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let configURL = root.appendingPathComponent("src/main/resources/application.yml")
        let sourceURL = root.appendingPathComponent("src/main/java/demo/DemoProperties.java")
        let valueReferenceURL = root.appendingPathComponent("src/main/java/demo/RetryService.java")
        let result = SpringIndexResult(
            properties: [SpringProperty(
                name: "demo.retry-count",
                typeName: "int",
                documentation: "Maximum retry count.",
                defaultValue: "3",
                sourceURL: sourceURL,
                sourceLine: 5,
                sourceColumn: 15
            )],
            values: [SpringConfigurationValue(
                key: "demo.retry-count",
                value: "5",
                url: configURL,
                line: 2,
                column: 3,
                profile: "dev",
                overridesBaseValue: true,
                targetURL: sourceURL,
                targetLine: 5,
                targetColumn: 15
            )],
            propertyReferences: [SpringPropertyReference(
                key: "demo.retry-count",
                url: valueReferenceURL,
                line: 9,
                column: 14
            )],
            diagnostics: [SpringDiagnostic(
                url: configURL,
                line: 2,
                column: 3,
                severity: "warning",
                message: "Example warning"
            )],
            beans: [],
            injections: [],
            endpoints: []
        )
        let feature = SpringFeatureModel(operations: SpringTestOperations(result: result))
        await feature.load(workspaceURL: root, files: [configURL, sourceURL])
        let document = EditorDocument(
            url: configURL,
            text: "demo:\n  ret",
            modificationDate: nil
        )

        let completions = feature.completions(document: document, line: 1, utf16Column: 5)
        let completion = try #require(completions.first)
        #expect(completion.label == "demo.retry-count")
        #expect(completion.textEdit?.newText == "retry-count")
        #expect(feature.hover(for: configURL, line: 1)?.contents.contains("Maximum retry count") == true)
        #expect(feature.languageDiagnostics[configURL]?.first?.severity == 2)
        let location = try #require(feature.navigationLocations(for: configURL, line: 1).first)
        #expect(location.url == sourceURL)
        #expect(location.range.start.line == 4)
        #expect(location.range.start.utf16Column == 14)
        let referenceLocation = try #require(
            feature.navigationLocations(for: valueReferenceURL, line: 8).first
        )
        #expect(referenceLocation.url == configURL)
        #expect(referenceLocation.range.start.line == 1)
    }

    @Test
    func injectionNavigationReturnsEveryMatchingBean() async {
        let root = URL(fileURLWithPath: "/workspace")
        let injectionURL = root.appendingPathComponent("Controller.java")
        let firstURL = root.appendingPathComponent("FirstService.java")
        let secondURL = root.appendingPathComponent("SecondService.java")
        let beans = [
            SpringBean(id: "first", name: "first", typeName: "Service", url: firstURL, line: 3, column: 7, kind: "component"),
            SpringBean(id: "second", name: "second", typeName: "Service", url: secondURL, line: 4, column: 7, kind: "component")
        ]
        let result = SpringIndexResult(
            properties: [], values: [], propertyReferences: [], diagnostics: [], beans: beans,
            injections: [SpringInjection(
                url: injectionURL, line: 8, column: 11,
                typeName: "Service", qualifier: nil, beanIDs: ["first", "second"]
            )],
            endpoints: []
        )
        let feature = SpringFeatureModel(operations: SpringTestOperations(result: result))
        await feature.load(workspaceURL: root, files: [injectionURL, firstURL, secondURL])

        let locations = feature.navigationLocations(for: injectionURL, line: 7)
        #expect(locations.map(\.url) == [firstURL, secondURL])
    }

    /// Opening a workspace must not wait for Spring indexing, which scales with
    /// the number of Java sources.
    @Test
    func scheduleLoadDefersIndexingAndPublishesTheResult() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let beanURL = root.appendingPathComponent("Service.java")
        let operations = SpringTestOperations(result: componentIndex(at: beanURL))
        let feature = SpringFeatureModel(operations: operations)
        defer { feature.reset() }

        feature.scheduleLoad(workspaceURL: root, files: [beanURL])

        // The schedule owns a MainActor task, which cannot run before this test
        // suspends. Reaching these assertions proves the caller was not blocked.
        #expect(feature.beans.isEmpty)
        #expect(operations.requestedFiles.isEmpty)

        let published = await awaitChange(on: feature) {
            !feature.isIndexing && !feature.beans.isEmpty
        }
        #expect(published, "the scheduled index never published a result")
        #expect(feature.beans.map(\.id) == ["Service.java"])
        #expect(operations.requestedFiles == [[beanURL]])
    }

    /// A newer schedule supersedes the pending one so a burst of reloads cannot
    /// publish a stale index.
    @Test
    func scheduleLoadReplacesAPendingSchedule() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let staleURL = root.appendingPathComponent("Stale.java")
        let freshURL = root.appendingPathComponent("Fresh.java")
        let operations = SpringTestOperations { files in
            files.first.map(componentIndex(at:)) ?? .empty
        }
        let feature = SpringFeatureModel(operations: operations)
        defer { feature.reset() }

        feature.scheduleLoad(workspaceURL: root, files: [staleURL])
        feature.scheduleLoad(workspaceURL: root, files: [freshURL])

        let published = await awaitChange(on: feature) {
            !feature.isIndexing && !feature.beans.isEmpty
        }
        #expect(published, "the replacement schedule never published a result")
        // A schedule superseded before it started must not run a second full
        // workspace index, which the generation token would only discard.
        #expect(operations.requestedFiles == [[freshURL]])
        #expect(feature.beans.map(\.id) == ["Fresh.java"])
    }
}

private func componentIndex(at url: URL) -> SpringIndexResult {
    SpringIndexResult(
        properties: [],
        values: [],
        propertyReferences: [],
        diagnostics: [],
        beans: [SpringBean(
            id: url.lastPathComponent,
            name: "service",
            typeName: "Service",
            url: url,
            line: 3,
            column: 7,
            kind: "component"
        )],
        injections: [],
        endpoints: []
    )
}

private final class SpringTestOperations: JavaMavenOperations, @unchecked Sendable {
    private let makeResult: @Sendable ([URL]) -> SpringIndexResult
    private let lock = NSLock()
    private var requested: [[URL]] = []

    /// Every set of files handed to the index, in call order. An empty value
    /// proves the double was never reached.
    var requestedFiles: [[URL]] {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    init(result: SpringIndexResult) {
        makeResult = { _ in result }
    }

    init(resultForFiles: @escaping @Sendable ([URL]) -> SpringIndexResult) {
        makeResult = resultForFiles
    }

    func springIndex(
        at rootURL: URL,
        files: [URL],
        textOverrides: [URL: String],
        refreshDependencyMetadata: Bool
    ) -> SpringIndexResult? {
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
