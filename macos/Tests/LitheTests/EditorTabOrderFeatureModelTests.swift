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
            window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil)
            defer { window.contentView = nil; window.close() }
            hosting.layoutSubtreeIfNeeded(); await Task.yield(); hosting.layoutSubtreeIfNeeded()
            if let directory = ProcessInfo.processInfo.environment["LITHE_DIFF_CAPTURE_DIR"] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                    URL(fileURLWithPath: directory).appendingPathComponent("repository-diff-tabs.png"))
            }
            // Drag the file icon across the Diff tab and another file using window events.
            for (index, x) in [20.0, 40.0, 220.0, 460.0, 460.0].enumerated() {
                let type: NSEvent.EventType = index == 0 ? .leftMouseDown : index == 4 ? .leftMouseUp : .leftMouseDragged
                window.sendEvent(try #require(NSEvent.mouseEvent(with: type,
                    location: hosting.convert(NSPoint(x: x, y: 18), to: nil), modifierFlags: [],
                    timestamp: Double(index), windowNumber: window.windowNumber, context: nil,
                    eventNumber: index, clickCount: 1, pressure: index == 4 ? 0 : 1)))
                await Task.yield(); hosting.layoutSubtreeIfNeeded()
            }
            #expect(model.editorTabItems == [.repositoryDiff, .document(second.id), .document(first.id)])
            #expect(model.activeDocumentID == first.id)
            model.moveEditorTab(.document(first.id), before: .repositoryDiff)
            model.selectRepositoryDiffTab()
            await Task.yield(); hosting.layoutSubtreeIfNeeded()
            // Close through the production settings menu, not only AppModel's tab command.
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type,
                    location: hosting.convert(NSPoint(x: 880, y: 59), to: nil), modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                window.sendEvent(event)
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            while window.childWindows?.isEmpty != false, ContinuousClock.now < deadline {
                hosting.layoutSubtreeIfNeeded(); await Task.yield()
            }
            let menu = try #require(window.childWindows?.first)
            for key: UInt16 in [125, 125, 36] {
                menu.sendEvent(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: [], timestamp: 0, windowNumber: menu.windowNumber, context: nil,
                    characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: key)))
            }

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

    @Test(arguments: [EditorTabLayoutMode.singleLine, .multipleRows], [true, false])
    func fileAndDiffTabsCanReorder(layout: EditorTabLayoutMode, dragDiff: Bool) async throws {
        let store = EditorTabOrderTestStore()
        let settings = AppSettings(store: store)
        settings.editorTabLayoutMode = layout
        let model = AppModel(settings: settings, services: MacServiceContainer(
            store: store, settings: settings, moduleLaunchMode: .safeMode).services)
        model.documentFeature.openVirtualDocument(URL(string: "lithe-test://documents/.gitignore")!, text: ".DS_Store", displayPath: nil)
        do {
            let document = try #require(model.openDocuments.first)
            if dragDiff {
                model.editorTabOrderFeature.moveToEnd(.repositoryDiff)
                model.selectRepositoryDiffTab()
            } else {
                model.editorTabOrderFeature.move(.repositoryDiff, before: .document(document.id))
            }
            let host = NSHostingView(rootView: EditorAreaView().environmentObject(model)
                .environmentObject(settings).environmentObject(model.editorChrome)
                .environment(\.colorScheme, dragDiff ? .dark : .light))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: layout == .singleLine ? 500 : 250, height: 220),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dragDiff ? .darkAqua : .aqua)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            defer { window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded(); await Task.yield(); host.layoutSubtreeIfNeeded()
            var points: [NSPoint] = layout == .singleLine
                ? [NSPoint(x: dragDiff ? 150 : 180, y: 18), NSPoint(x: dragDiff ? 120 : 160, y: 18), NSPoint(x: 80, y: 18), NSPoint(x: 10, y: 18), NSPoint(x: 10, y: 18)]
                : [NSPoint(x: 20, y: 58), NSPoint(x: 20, y: 48), NSPoint(x: 20, y: 30), NSPoint(x: 10, y: 18), NSPoint(x: 10, y: 18)]
            // Leave the strip in both layouts, then return and reorder. The
            // source gesture stays alive while its slot becomes a placeholder.
            points.insert(NSPoint(x: points[0].x + 15, y: 110), at: 2)
            // A grab below the tab's midpoint can finish near the strip's top
            // while the dragged card's center is already outside the strip.
            points[0].y += 10
            points[points.count - 2].y = 8
            points[points.count - 1].y = 8
            let originalItems = model.editorTabItems
            var eventNumber = 0
            func drag(_ points: [NSPoint], cancel: Bool = false) async throws {
                for (index, point) in points.enumerated() {
                    let type: NSEvent.EventType = index == 0 ? .leftMouseDown : index == points.count - 1 ? .leftMouseUp : .leftMouseDragged
                    window.sendEvent(try #require(NSEvent.mouseEvent(with: type,
                        location: host.convert(point, to: nil), modifierFlags: [],
                        timestamp: Double(eventNumber), windowNumber: window.windowNumber, context: nil,
                        eventNumber: eventNumber, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)))
                    eventNumber += 1
                    await Task.yield(); host.layoutSubtreeIfNeeded()
                    if cancel && index == 2 {
                        NSApp.sendEvent(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                            timestamp: Double(eventNumber), windowNumber: window.windowNumber, context: nil,
                            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)))
                        await Task.yield(); host.layoutSubtreeIfNeeded()
                    }
                    if cancel && index >= 2 {
                        #expect(window.childWindows?.contains { $0.identifier?.rawValue == "lithe.editor-tab-drag-preview" } != true)
                        #expect(model.editorTabItems == originalItems)
                    } else if type == .leftMouseDragged {
                        let preview = try #require(window.childWindows?.first {
                            $0.identifier?.rawValue == "lithe.editor-tab-drag-preview"
                        })
                        #expect(preview.isVisible && preview.ignoresMouseEvents)
                        #expect(preview.alphaValue == 0.9)
                        #expect(preview.animationBehavior == .none)
                        #expect(model.editorTabItems == originalItems, "Only commit order on drop")
                        if point.y == 110 {
                            #expect(preview.frame.maxY < window.frame.maxY - 60,
                                    "The floating preview must follow the pointer below the tab strip")
                            if let directory = ProcessInfo.processInfo.environment["LITHE_DIFF_CAPTURE_DIR"],
                               let view = preview.contentView {
                                let url = URL(fileURLWithPath: directory)
                                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                                view.cacheDisplay(in: view.bounds, to: bitmap)
                                try #require(bitmap.representation(using: .png, properties: [:]))
                                    .write(to: url.appendingPathComponent("tab-preview-\(layout)-\(dragDiff).png"))
                            }
                        }
                    }
                }
            }
            try await drag(points, cancel: true)
            #expect(model.editorTabItems == originalItems)
            try await drag(points)
            #expect(window.childWindows?.contains { $0.identifier?.rawValue == "lithe.editor-tab-drag-preview" } != true)
            #expect(model.editorTabItems == (dragDiff
                ? [.repositoryDiff, .document(document.id)] : [.document(document.id), .repositoryDiff]))
            #expect(model.isRepositoryDiffSelected == dragDiff)
        } catch { await model.shutdownProjectSession(); throw error }
        await model.shutdownProjectSession()
    }

    @Test
    func floatingPreviewCancelsWithoutTakingFocus() async throws {
        let preview = EditorTabDragPreviewStore()
        let host = NSHostingView(rootView: Text("Repository Diff: Example.swift")
            .frame(width: 230, height: 36)
            .background(EditorTabDragPreviewAnchor(item: .repositoryDiff, store: preview)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 230, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { preview.finish(); window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded(); await Task.yield(); host.layoutSubtreeIfNeeded()
        var cancelled = false
        let responder = window.firstResponder
        preview.begin(.repositoryDiff) { cancelled = true; preview.finish() }
        let panel = try #require(preview.panel)
        let origin = panel.frame.origin
        preview.move(by: CGSize(width: 300, height: 120))
        #expect(panel.frame.origin == CGPoint(x: origin.x + 300, y: origin.y - 120))
        #expect(window.firstResponder === responder)
        NSApp.sendEvent(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 1, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)))
        #expect(cancelled)
        #expect(preview.panel == nil && !panel.isVisible && panel.parent == nil)
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
