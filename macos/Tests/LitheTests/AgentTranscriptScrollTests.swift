import Foundation
import Testing
@testable import Lithe

@Suite("Agent transcript scrolling", .serialized)
struct AgentTranscriptScrollTests {
    @MainActor @Test
    func permissionTransitionsInOverflowingHistoryKeepTheNativeLayoutResponsive() async throws {
        try await verifyReplay(browsingHistory: true,
            testName: "permissionTransitionsInOverflowingHistoryKeepTheNativeLayoutResponsive")
    }

    @MainActor @Test
    func liveToolsPermissionsAndResizingKeepFollowingTheLatestReply() async throws {
        try await verifyReplay(browsingHistory: false,
            testName: "liveToolsPermissionsAndResizingKeepFollowingTheLatestReply")
    }

    @MainActor private func verifyReplay(browsingHistory: Bool, testName: String) async throws {
        if let path = ProcessInfo.processInfo.environment["LITHE_TRANSCRIPT_REPLAY_PHASE"] {
            try await TranscriptReplay(phaseURL: URL(fileURLWithPath: path)).perform(browsingHistory: browsingHistory)
            return
        }
        // A hung SwiftUI transaction cannot observe an in-process async timeout.
        // Run the native conversation view under the existing bounded process owner.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let phase = directory.appendingPathComponent("phase.txt")
        let bundle = Bundle(for: TranscriptReplayBundleMarker.self)
        let testImage = try #require(bundle.executableURL)
        let arguments = ["LITHE_TRANSCRIPT_REPLAY_PHASE=\(phase.path)", CommandLine.arguments[0],
            "--test-bundle-path", testImage.path, "--testing-library", "swift-testing", "--filter",
            "AgentTranscriptScrollTests.*\(testName)"]
        do {
            let result = try await TestProcess.run(executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: arguments, currentDirectoryURL: directory, timeout: .seconds(8))
            #expect(result.terminationStatus == 0,
                "Native transcript replay failed: \(String(decoding: result.output, as: UTF8.self))")
            #expect(try String(contentsOf: phase, encoding: .utf8) == "finished")
        } catch let error as TestProcessError {
            let lastPhase = (try? String(contentsOf: phase, encoding: .utf8)) ?? "before renderer startup"
            Issue.record("Native transcript layout did not finish; last phase: \(lastPhase). \(error)")
        }
    }
}

private final class TranscriptReplayBundleMarker: NSObject {}
