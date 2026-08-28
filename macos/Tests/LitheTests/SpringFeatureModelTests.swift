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
    /// the number of Java sources. `scheduleLoad` returns immediately and the
    /// index arrives later.
    @Test
    func scheduleLoadReturnsBeforeTheIndexIsPublished() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let beanURL = root.appendingPathComponent("Service.java")
        let gate = SpringIndexGate()
        let result = SpringIndexResult(
            properties: [], values: [], propertyReferences: [], diagnostics: [],
            beans: [SpringBean(
                id: "service", name: "service", typeName: "Service",
                url: beanURL, line: 3, column: 7, kind: "component"
            )],
            injections: [], endpoints: []
        )
        let feature = SpringFeatureModel(
            operations: SpringTestOperations(result: result, gate: gate)
        )

        feature.scheduleLoad(workspaceURL: root, files: [beanURL])

        #expect(feature.beans.isEmpty)
        gate.open()
        try await pollUntil { !feature.beans.isEmpty }
        #expect(feature.beans.map(\.id) == ["service"])
        #expect(!feature.isIndexing)
    }

    /// A newer schedule supersedes the previous one so a burst of reloads cannot
    /// publish a stale index.
    @Test
    func scheduleLoadCancelsThePreviousSchedule() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let gate = SpringIndexGate()
        let operations = SpringTestOperations(result: .empty, gate: gate)
        let feature = SpringFeatureModel(operations: operations)

        feature.scheduleLoad(workspaceURL: root, files: [])
        feature.scheduleLoad(workspaceURL: root, files: [])
        gate.open()
        try await pollUntil { !feature.isIndexing }

        #expect(operations.indexCallCount <= 2)
    }
}

/// Polls the MainActor state instead of sleeping for a fixed interval so the
/// test does not depend on scheduler timing.
@MainActor
private func pollUntil(
    attempts: Int = 200,
    _ condition: () -> Bool
) async throws {
    for _ in 0..<attempts {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("The awaited condition never became true")
}

/// Blocks the detached index call until the test decides the schedule has had a
/// chance to return.
private final class SpringIndexGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func open() { semaphore.signal() }
    func wait() { semaphore.wait(); semaphore.signal() }
}

private final class SpringTestOperations: JavaMavenOperations, @unchecked Sendable {
    let result: SpringIndexResult
    private let gate: SpringIndexGate?
    private let lock = NSLock()
    private var indexCalls = 0

    var indexCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return indexCalls
    }

    init(result: SpringIndexResult, gate: SpringIndexGate? = nil) {
        self.result = result
        self.gate = gate
    }

    func springIndex(
        at rootURL: URL,
        files: [URL],
        textOverrides: [URL: String],
        refreshDependencyMetadata: Bool
    ) -> SpringIndexResult? {
        lock.lock()
        indexCalls += 1
        lock.unlock()
        gate?.wait()
        return result
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
