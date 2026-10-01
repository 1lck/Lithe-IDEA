import Foundation
import AppKit
import SwiftUI
@testable import LitheGitModule
import Testing
@testable import Lithe

@Suite("Editor tab order")
@MainActor
struct EditorTabOrderFeatureModelTests {
    @Test(arguments: [true, false], [true, false])
    func sharedTabPaintsActiveBlueAndInactiveGray(dark: Bool, active: Bool) async throws {
        let hosting = NSHostingView(rootView: Text("Example.swift").font(LitheTheme.uiFont(size: 13))
            .frame(width: 180).modifier(LitheToolWindowTabStyle(isSelected: true, isActive: active))
            .padding(4).environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.controlActiveState, .key))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 188, height: 36),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defer { window.contentView = nil; window.close() }
        hosting.layoutSubtreeIfNeeded(); await Task.yield(); hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / hosting.bounds.width
        let pixel = try #require(bitmap.colorAt(x: Int(12 * scale), y: Int(18 * scale)))
        #expect(active ? pixel.blueComponent > pixel.redComponent + 0.05
            : abs(pixel.blueComponent - pixel.redComponent) < 0.04)
        if let directory = ProcessInfo.processInfo.environment["LITHE_DIFF_CAPTURE_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                URL(fileURLWithPath: directory).appendingPathComponent("tab-dark-\(dark)-active-\(active).png"))
        }
    }

    @Test
    func tabActivityFollowsNativeKeyboardFocusAcrossRegions() throws {
        var active = false
        let coordinator = LitheToolWindowActivityTracker.Coordinator(isActive: Binding(get: { active }, set: { active = $0 }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { coordinator.stopObservingFocus(); window.close() }
        let host = try #require(window.contentView)
        let region = NSView(frame: NSRect(x: 0, y: 100, width: 400, height: 100))
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        let scroll = NSScrollView(frame: region.bounds)
        scroll.documentView = editor
        region.addSubview(scroll); host.addSubview(region)
        let other = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        host.addSubview(other)
        var otherActive = false
        let otherCoordinator = LitheToolWindowActivityTracker.Coordinator(
            isActive: Binding(get: { otherActive }, set: { otherActive = $0 }))
        otherCoordinator.view = other; otherCoordinator.observeFocus()
        defer { otherCoordinator.stopObservingFocus() }
        coordinator.view = region; coordinator.observeFocus()
        for (responder, expected) in [(editor, true), (other, false), (editor, true)] {
            #expect(window.makeFirstResponder(responder))
            NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
            #expect(active == expected, "Focus rect: \(region.convert(responder.visibleRect, from: responder)); region: \(region.bounds); responder frame: \(responder.frame)")
            #expect(otherActive != expected, "Offscreen document bounds must not activate a neighboring region")
        }
        coordinator.stopObservingFocus()
        #expect(window.makeFirstResponder(other))
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        #expect(active, "Unmounted trackers must stop changing tab activity")
    }

    @Test
    func repositoryDiffSharesOrderAndSurvivesDocumentSelection() async throws {
        let store = EditorTabOrderTestStore()
        let settings = AppSettings(store: store)
        let model = AppModel(settings: settings, services: MacServiceContainer(
            store: store, settings: settings, moduleLaunchMode: .safeMode).services)
        let feature = GitFeatureModel(service: GitService(operations: RustGitOperations(core: RustCoreBridge())))
        model.moduleCapabilityStore.cache(GitModuleCapability(feature: feature), id: .gitWorkspace, moduleID: .git)
        let context = GitCommitDiffContext(repositoryRoot: FileManager.default.temporaryDirectory,
            commit: GitCommit(hash: "abc123", shortHash: "abc123", parentHashes: ["def456"],
                authorName: "Test", authorEmail: "test@example.invalid", date: "", subject: "Test", decorations: ""),
            file: GitCommitFile(status: "M", path: "Sources/Example.swift"))
        feature.selectedGitCommitDiffContext = context
        model.documentFeature.openVirtualDocument(URL(string: "lithe-test://documents/First.swift")!, text: "first", displayPath: nil)
        model.documentFeature.openVirtualDocument(URL(string: "lithe-test://documents/Second.swift")!, text: "second", displayPath: nil)
        do {
            let documents = model.openDocuments
            let first = try #require(documents.first), second = try #require(documents.last)
            model.editorTabOrderFeature.moveToEnd(.repositoryDiff)
            model.selectRepositoryDiffTab()
            #expect(model.isRepositoryDiffSelected)
            #expect(model.activeDocument == nil, "Diff must not leave hidden file save/edit commands active")
            model.moveEditorTab(.repositoryDiff, before: .document(second.id))
            #expect(model.editorTabItems == [.document(first.id), .repositoryDiff, .document(second.id)])
            model.selectEditorDocument(first)
            #expect(!model.isRepositoryDiffSelected)
            #expect(feature.selectedGitCommitDiffContext?.id == context.id)
            model.selectRepositoryDiffTab()
            #expect(model.isRepositoryDiffSelected)
            let hosting = NSHostingView(rootView: EditorAreaView().environmentObject(model).environmentObject(settings).environmentObject(model.editorChrome))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 220),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = hosting
            defer { window.contentView = nil; window.close() }
            hosting.layoutSubtreeIfNeeded(); await Task.yield(); hosting.layoutSubtreeIfNeeded()
            if let directory = ProcessInfo.processInfo.environment["LITHE_DIFF_CAPTURE_DIR"] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                    URL(fileURLWithPath: directory).appendingPathComponent("repository-diff-tabs.png"))
            }
            #expect(model.requestCloseActiveWorkbenchItem())
            #expect(feature.selectedGitCommitDiffContext == nil)
            #expect(model.editorTabItems == [.document(first.id), .document(second.id)])
            #expect(model.activeDocumentID == first.id)
            model.showGitCommitDiff(for: context.file)
            #expect(model.editorTabItems.contains(.repositoryDiff), "Loading previews are still closable tabs")
            #expect(model.requestCloseActiveWorkbenchItem())
            await Task.yield()
            #expect(!model.editorTabItems.contains(.repositoryDiff))
            #expect(model.editorTabOrderFeature.repositoryDiffRequestID == nil)
            #expect(model.activeDocumentID == first.id)
        } catch { await model.shutdownProjectSession(); throw error }
        await model.shutdownProjectSession()
    }

    @Test
    func documentReconciliationPreservesRepositoryDiffSlot() {
        let model = EditorTabOrderFeatureModel()
        let first = UUID(), second = UUID()
        model.reconcileDocuments(orderedIDs: [first, second])
        model.move(.repositoryDiff, before: .document(second))
        model.reconcileDocuments(orderedIDs: [second, first])
        #expect(model.items == [.document(second), .repositoryDiff, .document(first)])
    }

    @Test
    func mixesDocumentsAndTerminalsInOneOrder() {
        let model = EditorTabOrderFeatureModel()
        let firstDocument = UUID()
        let secondDocument = UUID()
        let terminal = UUID()
        model.reconcileDocuments(orderedIDs: [firstDocument, secondDocument])

        model.move(.terminal(terminal), before: .document(secondDocument))

        #expect(model.items == [
            .document(firstDocument),
            .terminal(terminal),
            .document(secondDocument)
        ])
    }

    @Test
    func documentReconciliationPreservesTerminalSlots() {
        let model = EditorTabOrderFeatureModel()
        let firstDocument = UUID()
        let secondDocument = UUID()
        let terminal = UUID()
        model.reconcileDocuments(orderedIDs: [firstDocument, secondDocument])
        model.move(.terminal(terminal), before: .document(secondDocument))

        model.reconcileDocuments(orderedIDs: [secondDocument, firstDocument])

        #expect(model.items == [
            .document(secondDocument),
            .terminal(terminal),
            .document(firstDocument)
        ])
    }

    @Test
    func documentReconciliationPreservesMediaSlots() {
        let model = EditorTabOrderFeatureModel()
        let firstDocument = UUID()
        let secondDocument = UUID()
        let media = UUID()
        model.reconcileDocuments(orderedIDs: [firstDocument, secondDocument])
        model.move(.media(media), before: .document(secondDocument))

        model.reconcileDocuments(orderedIDs: [secondDocument, firstDocument])

        #expect(model.items == [
            .document(secondDocument),
            .media(media),
            .document(firstDocument)
        ])
    }

    @Test
    func mediaReconciliationPreservesDocumentAndTerminalSlots() {
        let model = EditorTabOrderFeatureModel()
        let document = UUID()
        let firstMedia = UUID()
        let secondMedia = UUID()
        let terminal = UUID()
        model.reconcileDocuments(orderedIDs: [document])
        model.reconcileMedia(orderedIDs: [firstMedia, secondMedia])
        model.move(.terminal(terminal), before: .media(secondMedia))

        model.reconcileMedia(orderedIDs: [secondMedia, firstMedia])

        #expect(model.items == [
            .document(document),
            .media(secondMedia),
            .terminal(terminal),
            .media(firstMedia)
        ])
    }

    @Test
    func removingTerminalsLeavesDocumentOrderUntouched() {
        let model = EditorTabOrderFeatureModel()
        let firstDocument = UUID()
        let secondDocument = UUID()
        model.reconcileDocuments(orderedIDs: [firstDocument, secondDocument])
        model.move(.terminal(UUID()), before: .document(secondDocument))

        model.removeAllTerminals()

        #expect(model.items == [.document(firstDocument), .document(secondDocument)])
    }

    @Test
    func movingADocumentTabActivatesItsContent() throws {
        let store = EditorTabOrderTestStore()
        let settings = AppSettings(store: store)
        let services = MacServiceContainer(
            store: store,
            settings: settings,
            moduleLaunchMode: .safeMode
        ).services
        let appModel = AppModel(settings: settings, services: services)
        let firstURL = try #require(URL(string: "lithe-test://documents/First.swift"))
        let secondURL = try #require(URL(string: "lithe-test://documents/Second.swift"))
        appModel.documentFeature.openVirtualDocument(firstURL, text: "first", displayPath: nil)
        appModel.documentFeature.openVirtualDocument(secondURL, text: "second", displayPath: nil)
        let firstDocument = try #require(
            appModel.openDocuments.first(where: { $0.url == firstURL })
        )
        let secondDocument = try #require(
            appModel.openDocuments.first(where: { $0.url == secondURL })
        )
        appModel.selectEditorDocument(secondDocument)

        appModel.moveEditorTab(
            .document(firstDocument.id),
            after: .document(secondDocument.id)
        )

        #expect(appModel.editorTabItems == [
            .document(secondDocument.id),
            .document(firstDocument.id)
        ])
        #expect(appModel.activeDocumentID == firstDocument.id)
        #expect(appModel.activeEditorTerminalSession == nil)
    }
}

private final class EditorTabOrderTestStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
