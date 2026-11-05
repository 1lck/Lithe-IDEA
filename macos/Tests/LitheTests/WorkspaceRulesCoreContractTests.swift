import Foundation
import Testing
import LitheCoreContracts
@testable import Lithe

/// Replays the shared Rust Core fixtures through the macOS bridge, so Swift sends the
/// requests Core expects and decodes its answers without a second copy of the rules.
@Suite("Workspace rules Core contract")
struct WorkspaceRulesCoreContractTests {
    private static func fixture(_ path: String) throws -> [String: Any] {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: repository.appendingPathComponent("shared/fixtures/" + path))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private let operations = RustWorkspaceOperations(core: RustCoreBridge())

    @Test
    func copyNamesMatchTheSharedFixture() throws {
        let fixture = try Self.fixture("workspace/file-copy-names-v1.json")
        for item in try #require(fixture["duplicate"] as? [[String: Any]]) {
            let request = try #require(item["request"] as? [String: Any])
            guard request["caseInsensitive"] == nil else { continue } // macOS probes the volume instead
            #expect(operations.copyName(
                for: request["name"] as! String, isDirectory: request["isDirectory"] as! Bool,
                existing: request["existing"] as? [String] ?? [], duplicate: true
            ) == item["name"] as? String, "\(item["id"] ?? "")")
        }
        for item in try #require(fixture["paste"] as? [[String: Any]]) {
            let request = try #require(item["request"] as? [String: Any])
            let items = try #require(request["items"] as? [[String: Any]])
            guard items.count == 1, request["caseInsensitive"] == nil else { continue }
            #expect(operations.copyName(
                for: items[0]["name"] as! String, isDirectory: items[0]["isDirectory"] as! Bool,
                existing: request["existing"] as? [String] ?? [], duplicate: false
            ) == (item["names"] as? [String])?.first, "\(item["id"] ?? "")")
        }
    }

    @Test
    func historyEventsMatchTheSharedFixture() throws {
        let fixture = try Self.fixture("history/event-plan-v1.json")
        let core = RustCoreBridge()
        for item in try #require(fixture["events"] as? [[String: Any]]) {
            let event = try #require(LocalHistoryEvent(rawValue: item["event"] as! String))
            let expected = (item["snapshots"] as! [[String: String]]).map {
                LocalHistorySnapshotPlan(
                    source: LocalHistorySnapshotPlan.Source(rawValue: $0["source"]!)!,
                    reason: LocalHistoryReason(rawValue: $0["reason"]!)!
                )
            }
            #expect(core.historyPlanEvent(event) == expected, "\(event)")
        }
    }

    private func rules(_ value: [String: Any]?) throws -> WorkspaceDirectoryRules {
        let data = try JSONSerialization.data(withJSONObject: value ?? [:])
        struct Partial: Decodable {
            var marks: [String: WorkspaceDirectoryMark] = [:]
            var includedDirectories: [String] = []
            var previousRoles: [String: WorkspaceDirectoryMark] = [:]
            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: Keys.self)
                marks = try container.decodeIfPresent([String: WorkspaceDirectoryMark].self, forKey: .marks) ?? [:]
                includedDirectories = try container.decodeIfPresent([String].self, forKey: .includedDirectories) ?? []
                previousRoles = try container.decodeIfPresent([String: WorkspaceDirectoryMark].self, forKey: .previousRoles) ?? [:]
            }
            enum Keys: String, CodingKey { case marks, includedDirectories, previousRoles }
        }
        let partial = try JSONDecoder().decode(Partial.self, from: data)
        return WorkspaceDirectoryRules(
            marks: partial.marks, includedDirectories: partial.includedDirectories, previousRoles: partial.previousRoles
        )
    }

    @Test
    func directoryRulesMatchTheSharedFixture() throws {
        let fixture = try Self.fixture("workspace/directory-rules-v1.json")
        for item in try #require(fixture["reduce"] as? [[String: Any]]) {
            let request = try #require(item["request"] as? [String: Any])
            // macOS compares paths exactly; the case-insensitive cases belong to Windows.
            guard request["caseInsensitive"] == nil else { continue }
            let action = try #require(request["action"] as? [String: Any])
            let wire: WorkspaceDirectoryAction
            switch action["kind"] as! String {
            case "exclude": wire = .exclude
            case "cancelExclusion": wire = .cancelExclusion
            default: wire = .setRole(WorkspaceDirectoryMark(rawValue: action["role"] as! String)!)
            }
            let reduction = try #require(operations.reduceDirectoryAction(
                wire, at: request["path"] as! String, rules: try rules(request["rules"] as? [String: Any])
            ), "\(item["id"] ?? "")")
            let response = try #require(item["response"] as? [String: Any])
            #expect(reduction.changed == response["changed"] as? Bool, "\(item["id"] ?? "")")
            let expected = try rules(response["rules"] as? [String: Any])
            #expect(reduction.rules.marks == expected.marks, "\(item["id"] ?? "")")
            #expect(Set(reduction.rules.includedDirectories) == Set(expected.includedDirectories), "\(item["id"] ?? "")")
            #expect(reduction.rules.previousRoles == expected.previousRoles, "\(item["id"] ?? "")")
        }
        for item in try #require(fixture["relocate"] as? [[String: Any]]) {
            let request = try #require(item["request"] as? [String: Any])
            guard request["caseInsensitive"] == nil, request["target"] == nil else { continue }
            let migrated = try #require(operations.relocateDirectoryRules(
                try rules(request["rules"] as? [String: Any]),
                moving: request["source"] as! String, to: request["destination"] as? String
            ), "\(item["id"] ?? "")")
            let response = try #require(item["response"] as? [String: Any])
            let expected = try rules(response["rules"] as? [String: Any])
            #expect(migrated.marks == expected.marks, "\(item["id"] ?? "")")
            #expect(Set(migrated.includedDirectories) == Set(expected.includedDirectories), "\(item["id"] ?? "")")
            #expect(migrated.previousRoles == expected.previousRoles, "\(item["id"] ?? "")")
        }
    }
}
