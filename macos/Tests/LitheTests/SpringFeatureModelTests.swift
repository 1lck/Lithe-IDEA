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
}

private struct SpringTestOperations: JavaMavenOperations {
    let result: SpringIndexResult

    func springIndex(
        at rootURL: URL,
        files: [URL],
        textOverrides: [URL: String],
        refreshDependencyMetadata: Bool
    ) -> SpringIndexResult? { result }
    func scanMavenProject(at rootURL: URL, files: [URL]) -> MavenProject? { nil }
    func mavenDiagnostics(output: String, projectRoot: URL) -> [MavenBuildIssue] { [] }
    func codeVision(at rootURL: URL, targetPath: String, paths: [String]) -> [JavaCodeVisionValue] { [] }
    func className(source: String, simpleName: String) -> String? { nil }
    func sourceDefinition(source: String, declarationName: String, memberName: String?) -> (line: Int, utf16Column: Int)? { nil }
    func serverPort(content: String, fileExtension: String) -> Int? { nil }
    func scanRunConfigurations(at rootURL: URL, files: [URL], mavenProject: MavenProject?) -> [JavaRunConfiguration] { [] }
    func structure(source: String, declarationSources: [String]) -> JavaStructureResult? { nil }
}
