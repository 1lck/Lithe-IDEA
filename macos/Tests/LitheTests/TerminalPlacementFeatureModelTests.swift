import Foundation
import LitheModuleAPI
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
    func cancelingRunningTerminalCloseKeepsTheSessionAlive() {
        let context = makeTerminalCloseContext()

        #expect(context.model.requestCloseActiveWorkbenchItem())
        #expect(context.model.pendingTerminalCloseSessionID == context.session.id)
        #expect(context.model.terminalSessions.contains { $0.id == context.session.id })
        #expect(context.transport.stopCount == 0)

        context.model.cancelTerminalClose()

        #expect(context.model.pendingTerminalCloseSessionID == nil)
        #expect(context.model.terminalSessions.contains { $0.id == context.session.id })
        #expect(context.session.isRunning)
        #expect(context.transport.stopCount == 0)
    }

    @Test
    func confirmingRunningTerminalCloseStopsAndRemovesTheSession() {
        let context = makeTerminalCloseContext()

        #expect(context.model.requestCloseActiveWorkbenchItem())
        #expect(context.model.pendingTerminalCloseSessionID == context.session.id)
        #expect(context.transport.stopCount == 0)

        context.model.confirmTerminalClose()

        #expect(context.model.pendingTerminalCloseSessionID == nil)
        #expect(!context.model.terminalSessions.contains { $0.id == context.session.id })
        #expect(context.model.activeEditorTerminalSession == nil)
        #expect(!context.session.isRunning)
        #expect(context.transport.stopCount == 1)
    }

    private func makeTerminalCloseContext() -> (
        model: AppModel,
        session: TerminalSession,
        transport: PlacementTestTerminalTransport
    ) {
        let store = TerminalPlacementTestStore()
        let settings = AppSettings(store: store)
        let services = MacServiceContainer(
            store: store,
            settings: settings,
            moduleLaunchMode: .safeMode
        ).services
        let model = AppModel(settings: settings, services: services)
        let transport = PlacementTestTerminalTransport()
        let feature = TerminalFeatureModel(terminalFactory: { transport })
        model.cacheModuleCapability(
            TerminalModuleCapability(feature: feature),
            id: .terminalWorkspace,
            moduleID: .terminal
        )
        let session = feature.createSession(
            in: URL(fileURLWithPath: "/tmp/lithe-terminal-close-tests"),
            shellPath: "/bin/zsh"
        )
        model.terminalPlacementFeature.registerSession(session.id)
        model.terminalPlacementFeature.moveToEditor(session.id)
        return (model, session, transport)
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

private final class TerminalPlacementTestStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
