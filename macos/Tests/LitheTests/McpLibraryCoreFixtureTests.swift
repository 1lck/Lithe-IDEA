import Foundation
import Testing
@testable import Lithe

/// Runs the shared MCP library fixture through the macOS Core bridge, so the
/// Swift payloads and decoders match the cases Core itself is tested against.
/// Pure Core calls: no files, processes, network, clocks or persistent state.
@MainActor
struct McpLibraryCoreFixtureTests {
    private struct Fixture: Decodable {
        struct File: Decodable {
            let id: String
            let source: String
            let scope: String
            let projectPath: String?
            let path: String
            let content: String?
        }

        struct DraftCase: Decodable {
            struct Draft: Decodable {
                let name: String
                let transport: McpTransport
                let command: String
                let url: String
                let arguments: [String]
                let env: [McpKeyValue]
                let headers: [McpKeyValue]
                let enabledAgents: [String]
                let setup: String?
            }

            let `case`: String
            let draft: Draft
            let issues: [McpDraftIssue]
        }

        struct Snapshot: Decodable {
            struct Row: Decodable {
                let name: String
                let hasDefinitionConflict: Bool
            }

            let files: [String]
            let expectedRows: [Row]
        }

        let files: [String: File]
        let snapshot: Snapshot
        let validateDraft: [DraftCase]
    }

    private let store = MacAgentMcpConfigurationStore(core: RustCoreBridge(), storage: MacFileStorage())

    private func fixture() throws -> Fixture {
        let url = DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/fixtures/mcp/library-v1.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    @Test func draftIssuesMatchSharedFixture() throws {
        for item in try fixture().validateDraft {
            let draft = item.draft
            let validation = try store.validateDraft(McpDraftPayload(
                name: draft.name, transport: draft.transport, command: draft.command, url: draft.url,
                arguments: draft.arguments, env: draft.env, headers: draft.headers,
                enabledAgents: draft.enabledAgents, setup: draft.setup
            ))
            #expect(validation.issues == item.issues, "\(item.case)")
            #expect((validation.definition == nil) == !item.issues.isEmpty, "\(item.case)")
        }
    }

    @Test func everyIssueCodeHasADistinctLocalizedMessage() throws {
        let codes = Set(try fixture().validateDraft.flatMap(\.issues).map(\.code))
        let messages = codes.map { McpServerLibraryFeatureModel.message(for: McpDraftIssue(field: "", code: $0)) }
        let fallback = McpServerLibraryFeatureModel.message(for: McpDraftIssue(field: "", code: "unknown"))
        #expect(Set(messages).count == codes.count)
        #expect(!messages.contains(fallback))
    }

    @Test func snapshotOrderAndConflictsMatchSharedFixture() throws {
        let fixture = try fixture()
        let inputs = fixture.snapshot.files.compactMap { fixture.files[$0] }.map {
            McpLibraryFileInput(
                id: $0.id, source: $0.source, scope: $0.scope, projectPath: $0.projectPath,
                path: $0.path, content: $0.content, owned: []
            )
        }
        let snapshot = try store.librarySnapshot(inputs)
        #expect(snapshot.rows.map(\.definition.name) == fixture.snapshot.expectedRows.map(\.name))
        #expect(snapshot.rows.map(\.hasDefinitionConflict) == fixture.snapshot.expectedRows.map(\.hasDefinitionConflict))
        #expect(snapshot.failures.isEmpty)
    }
}
