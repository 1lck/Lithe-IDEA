import Foundation
import Testing
@testable import Lithe

/// Language-server jumps that leave the workspace go through the AppModel
/// navigation entry point; a refused target must not touch history.
@Suite("External navigation")
@MainActor
struct ExternalNavigationTests {
    @Test
    func refusedExternalJumpLeavesHistoryAndTargetUntouched() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-external-navigation-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("project", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let main = workspace.appendingPathComponent("main.go")
        try Data("package main\n".utf8).write(to: main)
        let credentials = outside.appendingPathComponent("credentials.json")
        try Data("{}\n".utf8).write(to: credentials)
        let disguised = workspace.appendingPathComponent("secret.go")
        try FileManager.default.createSymbolicLink(at: disguised, withDestinationURL: credentials)

        let store = ExternalNavigationTestStore()
        let settings = AppSettings(store: store)
        let services = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode).services
        let model = AppModel(settings: settings, services: services)
        model.workspaceSessionCoordinator.beginWorkspace(at: workspace)
        await model.documentFeature.openFileAsync(main, isReadOnly: false, displayPath: nil, activateWhenReady: true)
        do {
            let document = try #require(model.documentFeature.editorDocuments.first)
            model.editorDidFocus(document)

            for target in [credentials, disguised] {
                var failed = false
                model.navigate(
                    to: EditorNavigationLocation(
                        url: target,
                        line: 0,
                        utf16Column: 0,
                        isReadOnly: false,
                        displayPath: nil,
                        virtualProviderID: nil,
                        selectsWholeLine: false
                    ),
                    recordsHistory: true,
                    onFailure: { failed = true }
                )
                #expect(failed)
            }

            #expect(!model.canNavigateBack)
            #expect(model.editorNavigationTarget == nil)
            #expect(model.documentFeature.editorDocuments.map(\.url) == [main.standardizedFileURL])
            await model.shutdownProjectSession()
        } catch {
            await model.shutdownProjectSession()
            throw error
        }
    }
}

private final class ExternalNavigationTestStore: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { lock.withLock { values[key] as? Data } }
    func object(forKey key: String) -> Any? { lock.withLock { values[key] } }
    func string(forKey key: String) -> String? { lock.withLock { values[key] as? String } }
    func stringArray(forKey key: String) -> [String]? { lock.withLock { values[key] as? [String] } }
    func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value } }
}
