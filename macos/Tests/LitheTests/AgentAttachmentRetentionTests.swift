import Foundation
import Testing
@testable import Lithe

@Suite("Agent attachment retention")
struct AgentAttachmentRetentionTests {
    /// Retention rules are Core's; the shared fixture is the contract both platforms follow.
    @Test(.enabled(if: RustCoreBridge().isAvailable, "Requires the linked Rust Core integration library"))
    func bridgeReturnsTheSharedRetentionPlans() throws {
        struct Fixture: Decodable {
            struct Case: Decodable {
                struct Request: Decodable {
                    struct Entry: Decodable { let path: String; let modifiedMs: Int64?; let abandoned: Bool? }
                    let nowMs: Int64
                    let entries: [Entry]
                    let acceptedReferences: [String]?
                    let caseInsensitive: Bool?
                }
                let name: String
                let request: Request
                let expected: RustCoreBridge.AgentAttachmentRetentionPlan
            }
            let cases: [Case]
        }
        let url = DeclarativePluginTestSupport.repositoryRoot.appendingPathComponent("shared/fixtures/agent/attachment-retention-v1.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        for item in fixture.cases where item.request.caseInsensitive != true {
            let plan = try RustCoreBridge().agentAttachmentRetentionPlan(
                nowMs: item.request.nowMs,
                entries: item.request.entries.map { .init(path: $0.path, modifiedMs: $0.modifiedMs, abandoned: $0.abandoned ?? false) },
                acceptedReferences: item.request.acceptedReferences ?? [])
            #expect(plan.delete.map(\.path) == item.expected.delete.map(\.path), "\(item.name)")
            #expect(plan.delete.map(\.reason) == item.expected.delete.map(\.reason), "\(item.name)")
            #expect(plan.keep.map(\.path) == item.expected.keep.map(\.path), "\(item.name)")
            #expect(plan.keep.map(\.reason) == item.expected.keep.map(\.reason), "\(item.name)")
        }
    }
}
