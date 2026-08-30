import Foundation
import LitheTerminalModule
import Testing
@testable import Lithe

@Suite("Terminal tab placement")
@MainActor
struct TerminalPlacementFeatureModelTests {
    @Test
    func reordersTerminalToolTabs() {
        let model = TerminalPlacementFeatureModel()
        let first = UUID()
        let second = UUID()
        let third = UUID()
        [first, second, third].forEach(model.registerSession)

        model.moveToTool(first, after: third)
        #expect(model.toolSessionIDs == [second, third, first])

        model.moveToTool(first, before: second)
        #expect(model.toolSessionIDs == [first, second, third])
        #expect(model.editorSessionIDs.isEmpty)
    }

    @Test
    func movesAUniqueSessionBetweenToolAndEditor() {
        let model = TerminalPlacementFeatureModel()
        let sessionID = UUID()
        model.registerSession(sessionID)

        model.moveToEditor(sessionID)
        #expect(model.toolSessionIDs.isEmpty)
        #expect(model.editorSessionIDs == [sessionID])
        #expect(model.activeEditorSessionID == sessionID)

        model.moveToTool(sessionID)
        #expect(model.toolSessionIDs == [sessionID])
        #expect(model.editorSessionIDs.isEmpty)
        #expect(model.activeEditorSessionID == nil)
    }

    @Test
    func reordersEditorTerminalTabsAndSelectsTheMovedSession() {
        let model = TerminalPlacementFeatureModel()
        let first = UUID()
        let second = UUID()
        let third = UUID()
        [first, second, third].forEach(model.registerSession)
        [first, second, third].forEach(model.moveToEditor)

        model.moveToEditor(first, after: third)

        #expect(model.editorSessionIDs == [second, third, first])
        #expect(model.activeEditorSessionID == first)
        #expect(model.toolSessionIDs.isEmpty)
    }

    @Test
    func reconcilesEditorTerminalOrderWithTheMixedTabProjection() {
        let model = TerminalPlacementFeatureModel()
        let first = UUID()
        let second = UUID()
        let third = UUID()
        [first, second, third].forEach(model.registerSession)
        [first, second, third].forEach(model.moveToEditor)

        model.reorderEditorSessions(orderedIDs: [third, first, second])

        #expect(model.editorSessionIDs == [third, first, second])
        #expect(model.activeEditorSessionID == third)
    }

    @Test
    func movingPresentationNeverStopsOrRecreatesTheTerminalTransport() {
        let transport = PlacementTestTerminalTransport()
        let terminalFeature = TerminalFeatureModel(terminalFactory: { transport })
        let placement = TerminalPlacementFeatureModel()
        let session = terminalFeature.createSession(
            in: URL(fileURLWithPath: "/tmp/lithe-terminal-placement-tests"),
            shellPath: "/bin/zsh"
        )
        let nativeViewID = ObjectIdentifier(session.nativeView)
        placement.registerSession(session.id)

        placement.moveToEditor(session.id)
        placement.moveToTool(session.id)

        #expect(transport.startCount == 1)
        #expect(transport.stopCount == 0)
        #expect(session.isRunning)
        #expect(ObjectIdentifier(session.nativeView) == nativeViewID)

        terminalFeature.stopAllSessions()
        #expect(transport.stopCount == 1)
    }
}

@MainActor
private final class PlacementTestTerminalTransport: TerminalTransport {
    let nativeView: AnyObject = NSObject()
    var isRunning = false
    var processID: Int32? { isRunning ? 1234 : nil }
    var shellName = "Shell"
    var onTermination: ((Int32?) -> Void)?
    var onTitle: ((String) -> Void)?
    var onDirectoryUpdate: ((String?) -> Void)?
    var onLink: ((String, [String: String]) -> Void)?
    var startCount = 0
    var stopCount = 0

    func defaultShellPath() -> String { "/bin/zsh" }
    func defaultEnvironment() -> [String: String] { [:] }

    func start(
        workingDirectory: String,
        shellPath: String,
        environment: [String: String]
    ) throws {
        startCount += 1
        isRunning = true
    }

    func startProcess(
        _ launch: TerminalProcessLaunch,
        environment: [String: String]
    ) throws -> Int32 {
        startCount += 1
        isRunning = true
        return 1234
    }

    func send(_ input: Data) throws {}
    func interrupt() throws {}
    func focus() {}
    func clear() {}

    func stop() {
        guard isRunning else { return }
        stopCount += 1
        isRunning = false
    }
}
