import AppKit
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

    @MainActor @Test
    func wideEditorKeepsScrollbarAtEdgeAndNavigationPreservesHistory() async throws {
        try await verifyReplay(browsingHistory: true, navigating: true,
            testName: "wideEditorKeepsScrollbarAtEdgeAndNavigationPreservesHistory")
    }

    @MainActor @Test
    func aViewportFrameChangeKeepsFollowingWithoutABoundsNotification() async throws {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let document = TranscriptTestDocument(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let probe = AgentTranscriptScrollAnchor.Probe(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        document.addSubview(probe)
        scroll.documentView = document
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { probe.detach(); window.contentView = nil; window.close() }
        probe.update(sessionID: "fixture", enabled: true, revision: .init(lastMessageID: "reply", lastText: "reply",
            lastUserMessageID: "prompt", messageCount: 2, completedTurns: 1, permissionID: nil, isResponding: false))
        func waitForBottom() async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while abs(scroll.contentView.bounds.maxY - document.frame.maxY) >= 2 {
                try #require(ContinuousClock.now < deadline, "Viewport frame changes must follow the resized document")
                await withCheckedContinuation { gate in
                    DispatchQueue.main.async {
                        CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0, true)
                        gate.resume()
                    }
                }
            }
        }
        try await waitForBottom()
        // Flipped coordinates match SwiftUI's document. Finish the initial
        // follow before frame-only resizing, so it cannot satisfy this check.
        scroll.contentView.postsBoundsChangedNotifications = false
        document.frame.size.height = 400
        scroll.contentView.frame.size.width = 280
        try await waitForBottom()
    }

    @MainActor private func verifyReplay(browsingHistory: Bool, navigating: Bool = false, testName: String) async throws {
        if let path = ProcessInfo.processInfo.environment["LITHE_TRANSCRIPT_REPLAY_PHASE"] {
            let application = NSApplication.shared
            let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            let previousAccessibility = (application.accessibilityAttributeValue(attribute) as? Bool) ?? false
            if navigating { application.accessibilitySetValue(true, forAttribute: attribute) }
            defer {
                if navigating { application.accessibilitySetValue(previousAccessibility, forAttribute: attribute) }
            }
            try await TranscriptReplay(phaseURL: URL(fileURLWithPath: path), editorLayout: navigating)
                .perform(browsingHistory: browsingHistory, navigating: navigating)
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
        var environment = ProcessInfo.processInfo.environment
        environment["LITHE_TRANSCRIPT_REPLAY_PHASE"] = phase.path
        let arguments = ["--test-bundle-path", testImage.path, "--testing-library", "swift-testing", "--filter",
            "AgentTranscriptScrollTests.*\(testName)"]
        do {
            let result = try await TestProcess.run(executableURL: URL(fileURLWithPath: CommandLine.arguments[0]),
                arguments: arguments, currentDirectoryURL: directory, environment: environment, timeout: .seconds(8))
            try #require(result.terminationStatus == 0,
                "Native transcript replay failed: \(String(decoding: result.output, as: UTF8.self))")
            #expect(try String(contentsOf: phase, encoding: .utf8) == "finished")
        } catch let error as TestProcessError {
            let lastPhase = (try? String(contentsOf: phase, encoding: .utf8)) ?? "before renderer startup"
            Issue.record("Native transcript layout did not finish; last phase: \(lastPhase). \(error)")
        }
    }
}

private final class TranscriptReplayBundleMarker: NSObject {}

@MainActor
private final class TranscriptTestDocument: NSView {
    override var isFlipped: Bool { true }
}
