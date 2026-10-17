import Darwin
import Foundation
import Testing
@testable import Lithe

@Suite("Recovered application session classification")
struct MacRecoveredSessionTests {
    @Test func originalApplicationSessionSurvivesRecordRoundTrip() throws {
        let record = MacProcessInstanceRecord(
            scope: "recovered-session",
            application: MacProcessIdentity(processID: 100, startTime: 1),
            applicationSessionID: originalSessionID
        )
        let decoded = try JSONDecoder().decode(
            MacProcessInstanceRecord.self, from: JSONEncoder().encode(record)
        )
        #expect(decoded == record)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.applicationSessionID == originalSessionID)
    }

    @Test func recoveryCleansOriginalSessionToolsAndKeepsDetachedServices() throws {
        let reader = fixtureReader()
        var settings = ProcessTerminationSettings()
        settings.backgroundResources = .keep
        // The supervisor runs in a new session. A new launch may also have a
        // different session; neither changes which session the old app owned.
        #expect(originalSessionID != getsid(0))
        for context in [ProcessLifecycleContext.crashRecovery, .startupSweep] {
            let inventory = try reader.inventory(
                scope: "recovered-session", mode: .leftover,
                applicationSessionID: originalSessionID,
                excluded: [], retained: [], context: context,
                settings: settings, snapshot: []
            )
            let tool = try #require(inventory.items.first { $0.name == "build-tool" })
            let daemon = try #require(inventory.items.first { $0.name == "fixture-daemon" })
            let plan = try #require(inventory.plan)
            #expect(tool.category == .other)
            #expect(!tool.detached)
            #expect(plan.action(for: tool.id) == .terminate)
            #expect(daemon.category == .backgroundService)
            #expect(daemon.detached)
            // A crash retains the service. Startup asks before stopping it.
            #expect(plan.action(for: daemon.id) == (context == .crashRecovery ? .retain : .ask))
        }
    }

    @Test func liveInventoryUsesTheInstancesRecordedSession() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-recovered-session-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let instance = MacProcessInstance(
            scope: MacProcessScope(id: "recovered-session"),
            store: MacProcessInstanceRecordStore(directory: directory),
            record: MacProcessInstanceRecord(
                scope: "recovered-session",
                application: MacProcessIdentity(processID: 100, startTime: 1),
                applicationSessionID: originalSessionID
            )
        )
        let inventory = try fixtureReader().live(instance: instance, snapshot: [])
        #expect(inventory.items.first { $0.name == "build-tool" }?.category == .other)
        #expect(inventory.items.first { $0.name == "fixture-daemon" }?.category == .backgroundService)
    }

    @Test func legacyV1RecordDoesNotAuthorizeCleanupUsingTheRecoverySession() throws {
        let data = Data("""
        {
          "schemaVersion": 1,
          "scope": "recovered-session",
          "application": { "processID": 100, "startTime": 1 },
          "retained": [],
          "completedShutdown": false,
          "recoveredAfterCrash": false
        }
        """.utf8)
        let legacy = try JSONDecoder().decode(MacProcessInstanceRecord.self, from: data)
        #expect(legacy.schemaVersion == 1)
        #expect(legacy.applicationSessionID == nil)
        let reader = fixtureReader()
        for context in [ProcessLifecycleContext.crashRecovery, .startupSweep] {
            let inventory = try reader.inventory(
                scope: legacy.scope, mode: .leftover,
                applicationSessionID: legacy.applicationSessionID,
                excluded: [], retained: legacy.retained, context: context,
                snapshot: []
            )
            #expect(!inventory.items.isEmpty)
            // Missing original SID never proves detachment. A startup still
            // offers scoped leftovers; unattended recovery has no kill plan.
            #expect(inventory.items.allSatisfy { $0.category != .backgroundService })
            if context == .crashRecovery {
                #expect(inventory.plan == nil)
            } else {
                let plan = try #require(inventory.plan)
                #expect(plan.decisions.allSatisfy { $0.action == .ask })
            }
        }
    }

    private var originalSessionID: pid_t { getsid(0) == 100 ? 200 : 100 }

    private func fixtureReader() -> MacProcessInventoryReader {
        let rows = [
            row(10_001, sessionID: originalSessionID, name: "build-tool"),
            row(20_001, sessionID: 20_001, name: "fixture-daemon"),
        ]
        return MacProcessInventoryReader(scopedProcesses: { _, _, _ in rows })
    }

    private func row(_ processID: pid_t, sessionID: pid_t, name: String) -> MacScopedProcess {
        MacScopedProcess(
            info: MacProcessInfo(
                identity: MacProcessIdentity(processID: processID, startTime: 1),
                parentProcessID: 1, processGroupID: processID, sessionID: sessionID,
                hasControllingTerminal: false, name: name
            ),
            arguments: MacProcessArguments(
                executablePath: "/fixture/\(name)", arguments: [name],
                environment: [MacProcessScope.environmentKey: "recovered-session"]
            )
        )
    }
}
