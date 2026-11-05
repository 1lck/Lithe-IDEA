import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@Suite("Git metadata classification")
struct GitMetadataClassificationTests {
    private struct Fixture: Decodable {
        struct Context: Decodable {
            let workspaceRoot: String
            let repositoryRoot: String
            let gitDirectory: String
            let gitCommonDirectory: String
        }
        struct Case: Decodable {
            let name: String
            let context: String
            let path: String
            let kind: String
            let indexOnly: Bool
        }
        let contexts: [String: Context]
        let cases: [Case]
    }

    @Test
    func sharedFixtureAndBoundedPagesUseTheSameCoreRules() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixtureURL = repository.appendingPathComponent("shared/fixtures/git/metadata-classification-v1.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))
        let root = URL(fileURLWithPath: "/in-memory/lithe-watch-shared-fixture")
        let classifier = RustGitMetadataClassifier(core: RustCoreBridge())
        for (name, context) in fixture.contexts {
            let configuration = DirectoryWatchConfiguration(
                workspaceRoot: root.appendingPathComponent(context.workspaceRoot),
                gitContext: GitWatchContext(
                    repositoryRoot: root.appendingPathComponent(context.repositoryRoot),
                    gitDirectory: root.appendingPathComponent(context.gitDirectory),
                    gitCommonDirectory: root.appendingPathComponent(context.gitCommonDirectory)))
            let cases = fixture.cases.filter { $0.context == name }
            // More than one bridge page, including a partial final page.
            let repeated = Array(repeating: cases, count: 40).flatMap { $0 }
            let actual = try classifier.classify(
                paths: repeated.map { root.appendingPathComponent($0.path).path }, configuration: configuration).get()
            #expect(actual.count == repeated.count)
            for (event, expected) in zip(actual, repeated) {
                #expect(event.kind.rawValue == expected.kind, Comment(rawValue: expected.name))
                #expect(event.indexOnly == expected.indexOnly, Comment(rawValue: expected.name))
            }
        }
    }
}
