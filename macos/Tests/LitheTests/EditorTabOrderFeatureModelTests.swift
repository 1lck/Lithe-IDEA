import Foundation
import AppKit
import SwiftUI
@testable import LitheGitModule
import Testing
import LitheTestDesktopIsolation
@testable import Lithe

@Suite("Editor tab order")
@MainActor
struct EditorTabOrderFeatureModelTests {
    @Test(arguments: [CGFloat(320), 900, 1400], [ColorScheme.dark, .light])
    func editorChatCentersItsContentWhileToolWindowKeepsAvailableWidth(width: CGFloat, scheme: ColorScheme) async throws {
        let store = EditorTabOrderTestStore()
        let settings = AppSettings(store: store)
        settings.preferredConversationAgentID = "codex-acp"
        let model = AppModel(settings: settings, services: MacServiceContainer(
            store: store, settings: settings, moduleLaunchMode: .safeMode).services)
        do {
            for editor in [true, false] {
                let host = NSHostingView(rootView: AgentConversationView(model: model, isEditor: editor)
                    .environment(\.colorScheme, scheme))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                window.contentView = host
                defer { window.contentView = nil; window.close() }
                host.layoutSubtreeIfNeeded()
                let frame = try await AgentNativeControlTestSupport.frame(of: "agent-composer-attach-files", in: host)
                let column = editor ? width * AgentPanelStyle.editorContentWidthFraction : width
                // The attachment action is the toolbar's leading control. Other
                // dropdowns can move without changing the composer's outer edge.
                let composerLeadingEdge = frame.minX - AgentComposerMetrics.toolbarHorizontalInset
                #expect(abs(composerLeadingEdge - ((width - column) / 2 + AgentComposerMetrics.horizontalInset)) < 1,
                        "Footer frame \(frame), editor \(editor), column \(column)")
                #expect(frame.minX >= AgentComposerMetrics.horizontalInset)
                if let folder = ProcessInfo.processInfo.environment["LITHE_AGENT_EDITOR_LAYOUT_SCREENSHOTS"] {
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                        URL(fileURLWithPath: folder).appendingPathComponent("chat-\(editor)-\(Int(width))-\(scheme).png"))
                }
            }
        } catch { await model.shutdownProjectSession(); throw error }
        await model.shutdownProjectSession()
    }

    @Test func agentEditorPageSelectionAndCloseRestoreTheExistingFile() async throws {
        let store = EditorTabOrderTestStore()
        let settings = AppSettings(store: store)
        let model = AppModel(settings: settings, services: MacServiceContainer(
            store: store, settings: settings, moduleLaunchMode: .safeMode).services)
        model.documentFeature.openVirtualDocument(URL(string: "lithe-test://agent/source.swift")!, text: "unsaved", displayPath: nil)
        do {
            let file = try #require(model.editorTabItems.first)
            let document = try #require(model.activeDocument)
            model.showAgentChatsInEditor()
            model.showAgentChatsInEditor()
            #expect(model.editorTabItems == [file, .agentConversation])
            #expect(model.isAgentEditorSelected)
            model.selectEditorTab(file)
            #expect(!model.isAgentEditorSelected && model.agentChatsInEditor)
            model.selectEditorTab(.agentConversation)
            #expect(model.isAgentEditorSelected)
            #expect(model.requestCloseActiveWorkbenchItem())
            #expect(!model.agentChatsInEditor)
            #expect(model.editorTabItems == [file])
            #expect(model.activeDocument === document)
            #expect(document.text == "unsaved")
        } catch { await model.shutdownProjectSession(); throw error }
        await model.shutdownProjectSession()
    }

    @Test func agentPageUsesSharedSelectionReconciliationAndGroupMoves() throws {
        let feature = EditorTabOrderFeatureModel()
        let file = EditorTabItem.document(UUID())
        feature.moveToEnd(file)
        feature.moveToEnd(.agentConversation)
        feature.focus(.agentConversation)
        #expect(feature.focusedItem == .agentConversation)
        feature.reconcileDocuments(orderedIDs: feature.documentIDs)
        #expect(feature.items == [file, .agentConversation])
        let group = try #require(feature.groupLayout.groups.first)
        #expect(feature.drop(.agentConversation, into: group, side: .right))
        feature.focus(.agentConversation)
        #expect(feature.focusedItem == .agentConversation)
        feature.remove(.agentConversation)
        #expect(feature.items == [file])
        #expect(feature.groupLayout.groups.count == 1)
    }

    @Test func splitMenuEligibilityMatchesDropForSingleAndMixedGroups() throws {
        let model = EditorTabOrderFeatureModel()
        let a = EditorTabItem.document(UUID()), b = EditorTabItem.document(UUID())
        model.moveToEnd(a); model.moveToEnd(b)
        let left = try #require(model.groupLayout.groups.first)
        #expect(model.canDrop(b, into: left, side: .right))
        #expect(model.drop(b, into: left, side: .right))
        let right = try #require(model.groupLayout.groups.last)
        #expect(!model.canDrop(b, into: right, side: .right))
        #expect(!model.drop(b, into: right, side: .right))
        model.moveToEnd(.terminal(UUID()))
        #expect(model.canDrop(b, into: right, side: .right))
        #expect(model.drop(b, into: right, side: .right))
        #expect(!model.canDrop(a, into: UUID(), side: .right))
    }

    @Test func closeTargetsRespectGroupsMixedTabsAndReordering() throws {
        let model = EditorTabOrderFeatureModel()
        let a = UUID(), b = UUID(), c = UUID(), terminal = UUID()
        model.reconcileDocuments(orderedIDs: [a, b, c])
        model.moveToEnd(.terminal(terminal))
        let left = try #require(model.groupLayout.groups.first)
        #expect(model.drop(.document(c), into: left, side: .right))
        let right = try #require(model.groupLayout.groups.last)
        let isolated = model.documentCloseTargets(for: c, in: right)
        #expect(isolated.other.isEmpty && isolated.left.isEmpty && isolated.right.isEmpty)
        #expect(model.move(.document(b), before: .document(a)))
        let targets = model.documentCloseTargets(for: a, in: left)
        #expect(targets.other == [b])
        #expect(targets.left == [b])
        #expect(targets.right.isEmpty)
        let first = model.documentCloseTargets(for: b, in: left)
        #expect(first.left.isEmpty && first.right == [a])
        #expect(model.items(in: left).contains(.terminal(terminal)))
        #expect(model.documentCloseTargets(for: c, in: left).other.isEmpty)
    }

    @Test(arguments: [2, 3])
    func nativeMultilineRowReleaseReordersWithoutSplitting(row: Int) async throws {
        let store = EditorTabOrderTestStore()
        let settings = AppSettings(store: store)
        settings.editorTabLayoutMode = .multipleRows
        let model = AppModel(settings: settings, services: MacServiceContainer(
            store: store, settings: settings, moduleLaunchMode: .safeMode).services)
        for index in 1...3 {
            model.documentFeature.openVirtualDocument(
                URL(string: "lithe-test://rows/LongDocumentNameForWrapping\(index).swift")!, text: "row", displayPath: nil)
        }
        do {
            let drag = EditorGroupDragState()
            let original = model.editorTabItems
            let host = NSHostingView(rootView: EditorGroupContainer(feature: model.editorTabOrderFeature, drag: drag)
                .environmentObject(model).environmentObject(settings).environmentObject(model.editorChrome))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            defer { window.contentView = nil; window.close() }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            repeat {
                host.layoutSubtreeIfNeeded()
                if let frame = drag.tabFrames.values.first, frame.height > 72 { break }
                await Task.yield()
            } while ContinuousClock.now < deadline
            let frame = try #require(drag.tabFrames.values.first)
            #expect(frame.height > 72)
            func send(_ type: NSEvent.EventType, y: CGFloat, x: CGFloat) throws {
                NSApp.sendEvent(try #require(NSEvent.mouseEvent(with: type,
                    location: host.convert(CGPoint(x: x, y: y), to: nil), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .leftMouseUp ? 0 : 1)))
            }
            let rowHeight = frame.height / 3
            try send(.leftMouseDown, y: rowHeight / 2, x: 60)
            try send(.leftMouseDragged, y: rowHeight / 2, x: 80)
            await Task.yield(); host.layoutSubtreeIfNeeded()
            try send(.leftMouseDragged, y: (CGFloat(row) - 0.5) * rowHeight, x: 240)
            await Task.yield(); host.layoutSubtreeIfNeeded()
            try send(.leftMouseUp, y: (CGFloat(row) - 0.5) * rowHeight, x: 240)
            host.layoutSubtreeIfNeeded()
            #expect(model.editorTabOrderFeature.groupLayout.groups.count == 1)
            #expect(model.editorTabItems != original)
            #expect(Set(model.editorTabItems) == Set(original))
        } catch { await model.shutdownProjectSession(); throw error }
        await model.shutdownProjectSession()
    }

    @Test func clippedTabsDoNotCaptureAdjacentGroupClicks() throws {
        let hiddenStore = EditorTabDragPreviewStore(), neighborStore = EditorTabDragPreviewStore()
        defer { hiddenStore.stopCapturing(); neighborStore.stopCapturing() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let root = try #require(window.contentView)
        let clip = NSClipView(frame: CGRect(x: 0, y: 0, width: 100, height: 36))
        let document = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 36))
        clip.documentView = document; root.addSubview(clip)
        let hidden = NSView(frame: CGRect(x: 120, y: 0, width: 80, height: 36))
        document.addSubview(hidden)
        let neighbor = NSView(frame: hidden.frame); root.addSubview(neighbor)
        var hiddenClicks = 0, neighborClicks = 0, hiddenDrags = 0
        hiddenStore.register(hidden, for: .document(UUID()), frame: { hidden.frame },
            clicked: { hiddenClicks += 1 }, changed: { _, _ in hiddenDrags += 1 }, ended: { _, _ in })
        func send(_ type: NSEvent.EventType, x: CGFloat) throws {
            NSApp.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: 18),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)))
        }
        #expect(hidden.bounds.intersection(hidden.visibleRect).isEmpty)
        try send(.leftMouseDown, x: 140); try send(.leftMouseUp, x: 140)
        #expect(hiddenClicks == 0)
        neighborStore.register(neighbor, for: .document(UUID()), frame: { neighbor.frame },
            clicked: { neighborClicks += 1 }, changed: { _, _ in }, ended: { _, _ in })
        try send(.leftMouseDown, x: 140); try send(.leftMouseUp, x: 140)
        #expect(hiddenClicks == 0); #expect(neighborClicks == 1)
        try send(.leftMouseDown, x: 140); try send(.leftMouseDragged, x: 155); try send(.leftMouseUp, x: 155)
        #expect(hiddenDrags == 0)
        // A partially visible tab remains clickable only inside the viewport.
        hidden.frame.origin.x = 80
        try send(.leftMouseDown, x: 90); try send(.leftMouseUp, x: 90)
        #expect(hiddenClicks == 1)
        try send(.leftMouseDown, x: 105); try send(.leftMouseUp, x: 105)
        #expect(hiddenClicks == 1)
    }

    @Test(arguments: [CGFloat(58), 94])
    func multilineTabRowsRemainReorderTargets(y: CGFloat) throws {
        let feature = EditorTabOrderFeatureModel()
        let a = EditorTabItem.document(UUID()), b = EditorTabItem.document(UUID())
        feature.moveToEnd(a); feature.moveToEnd(b)
        let group = try #require(feature.groupLayout.groups.first)
        let drag = EditorGroupDragState()
        drag.frames = [group: CGRect(x: 0, y: 0, width: 300, height: 400)]
        drag.tabFrames = [group: CGRect(x: 0, y: 0, width: 300, height: 108)]
        drag.begin(); defer { drag.finish() }
        #expect(drag.destination(at: CGPoint(x: 150, y: y), sourceGroup: group) == nil)
        #expect(feature.move(b, before: a))
        #expect(feature.groupLayout.groups == [group])
        #expect(feature.items == [b, a])
        #expect(drag.destination(at: CGPoint(x: 150, y: 120), sourceGroup: group)?.side == .top)
        #expect(drag.destination(at: CGPoint(x: 290, y: 250), sourceGroup: group)?.side == .right)
    }

    @Test func databaseTabsKeepTheirSharedWorkspaceWhileDocumentsSplit() throws {
        let feature = EditorTabOrderFeatureModel()
        let first = EditorTabItem.document(UUID()), second = EditorTabItem.document(UUID())
        let database = EditorTabItem.database(UUID()), query = EditorTabItem.databaseQuery(profileID: UUID(), queryID: UUID())
        feature.moveToEnd(first); feature.moveToEnd(second); feature.moveToEnd(database)
        let original = try #require(feature.groupLayout.groups.first)
        #expect(feature.drop(second, into: original, side: .right))
        let other = try #require(feature.groupLayout.groups.last)
        feature.moveToEnd(query)
        #expect(feature.items(in: original).contains(query))
        #expect(!feature.drop(database, into: other, side: .center))
        #expect(!feature.move(query, before: second))
        #expect(feature.move(query, before: database))
        #expect(feature.items(in: other) == [second])
    }

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
        var pending: [() -> Void] = []
        func drain() {
            let callbacks = pending
            pending.removeAll()
            callbacks.forEach { $0() }
        }
        let coordinator = LitheToolWindowActivityTracker.Coordinator(
            isActive: Binding(get: { active }, set: { active = $0 }), schedule: { pending.append($0) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { coordinator.stopObservingFocus(); window.close(); drain() }
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
            isActive: Binding(get: { otherActive }, set: { otherActive = $0 }), schedule: { pending.append($0) })
        otherCoordinator.view = other; otherCoordinator.observeFocus()
        defer { otherCoordinator.stopObservingFocus(); drain() }
        coordinator.view = region; coordinator.observeFocus()
        for (responder, expected) in [(editor, true), (other, false), (editor, true)] {
            #expect(window.makeFirstResponder(responder))
            NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
            drain()
            #expect(active == expected, "Focus rect: \(region.convert(responder.visibleRect, from: responder)); region: \(region.bounds); responder frame: \(responder.frame)")
            #expect(otherActive != expected, "Offscreen document bounds must not activate a neighboring region")
        }
        let insideField = NSTextField(frame: NSRect(x: 10, y: 10, width: 120, height: 24))
        let outsideField = NSTextField(frame: NSRect(x: 10, y: 10, width: 120, height: 24))
        region.addSubview(insideField)
        other.addSubview(outsideField)
        for (field, expected) in [(insideField, true), (outsideField, false), (insideField, true)] {
            #expect(window.makeFirstResponder(field))
            #expect((window.firstResponder as? NSTextView)?.isFieldEditor == true)
            NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
            drain()
            #expect(active == expected, "A shared field editor must follow the control being edited")
            #expect(otherActive != expected)
        }
        coordinator.stopObservingFocus()
        #expect(window.makeFirstResponder(other))
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        drain()
        #expect(!active, "Unmounted trackers must invalidate retained activity")
        region.removeFromSuperview()
        host.addSubview(region)
        coordinator.observeFocus()
        drain()
        #expect(!active, "Remounting while details own focus must stay inactive")
        coordinator.stopObservingFocus()
        #expect(window.makeFirstResponder(insideField))
        coordinator.observeFocus()
        drain()
        #expect(active, "Remounting must recover the current focus owner on the next main-queue turn")
    }

    @Test
    func delayedPointerActivityCannotOverrideNewerFocusOrRemount() throws {
        var active = false
        var pending: [() -> Void] = []
        func drain() {
            let callbacks = pending
            pending.removeAll()
            callbacks.forEach { $0() }
        }
        let coordinator = LitheToolWindowActivityTracker.Coordinator(
            isActive: Binding(get: { active }, set: { active = $0 }), schedule: { pending.append($0) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { coordinator.stopObservingFocus(); window.makeFirstResponder(nil); window.close(); drain() }
        let host = try #require(window.contentView)
        let region = NSTextView(frame: NSRect(x: 0, y: 100, width: 400, height: 100))
        let details = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        host.addSubview(region); host.addSubview(details)
        coordinator.view = region
        #expect(window.makeFirstResponder(region))
        coordinator.observeFocus()
        drain()
        #expect(active)
        for notify in [true, false] {
            #expect(window.makeFirstResponder(region))
            NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
            coordinator.queuePointerActivity(true)
            #expect(window.makeFirstResponder(details))
            if notify { NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window) }
            drain()
            #expect(!active, "A deferred click must yield to newer focus even before its notification")
        }
        coordinator.queuePointerActivity(true)
        coordinator.stopObservingFocus()
        coordinator.observeFocus()
        drain()
        #expect(!active, "Callbacks from an earlier mount must not restore stale activity")
        coordinator.queuePointerActivity(true)
        coordinator.queuePointerActivity(false)
        drain()
        #expect(!active, "Only the latest pointer event may publish activity")
    }

    @Test
    func trackerUnmountDefersBindingWritesUntilTheLifecycleCallbackReturns() {
        var active = true
        var pending: [() -> Void] = []
        let coordinator = LitheToolWindowActivityTracker.Coordinator(
            isActive: Binding(get: { active }, set: { active = $0 }), schedule: { pending.append($0) })
        coordinator.stopObservingFocus()
        #expect(active, "Cleanup invalidates callbacks immediately but publishes state next turn")
        let callbacks = pending
        pending.removeAll()
        callbacks.forEach { $0() }
        #expect(!active)
    }

    @Test
    func activityTrackerCanDestroyItsSwiftUIStateOwner() async {
        weak var released: NSView?
        autoreleasepool {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.contentView = nil; window.close() }
            var hosting: NSHostingView<ActivityTrackerLifecycleTestView>? = NSHostingView(
                rootView: ActivityTrackerLifecycleTestView())
            released = hosting
            window.contentView = hosting
            hosting?.layoutSubtreeIfNeeded()
            window.contentView = nil
            hosting = nil
        }
        // Flush the explicitly queued lifecycle publication, without a time-based sleep.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(released == nil, "The real SwiftUI state owner must be released without an access conflict")
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
                NSApp.sendEvent(try #require(NSEvent.mouseEvent(with: type,
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
            if let directory = ProcessInfo.processInfo.environment["LITHE_DIFF_CAPTURE_DIR"] {
                let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                    URL(fileURLWithPath: directory).appendingPathComponent("group-diff-menu.png"))
            }
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
                    NSApp.sendEvent(try #require(NSEvent.mouseEvent(with: type,
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
                        #expect(LitheTestRequestedWindowAlpha(preview) == 0.9)
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

    @Test(arguments: [false, true], [false, true])
    func workingTreeDiffOwnsCloseCommandWhileHistoryTabIsRetained(closeBackgroundTab: Bool, loading: Bool) async throws {
        let store = EditorTabOrderTestStore()
        let settings = AppSettings(store: store)
        let model = AppModel(settings: settings, services: MacServiceContainer(
            store: store, settings: settings, moduleLaunchMode: .safeMode).services)
        let change = GitChange(repositoryRoot: FileManager.default.temporaryDirectory,
            path: "Example.swift", originalPath: nil, indexStatus: " ", workTreeStatus: "M")
        let diff = DiffDocument(patch: "-old\n+new",
            rows: [DiffRow(oldLine: 1, newLine: 1, left: "old", right: "new", kind: .changed, hunkID: "h1")],
            hunks: [DiffHunk(id: "h1", header: "@@ -1 +1 @@", patch: "-old\n+new")])
        let checkClose: @MainActor @Sendable () -> Void = { [weak model] in
            guard let model, let feature = model.gitFeatureIfActive else {
                Issue.record("The working-tree preview must retain its owning feature")
                return
            }
            #expect(!model.isRepositoryDiffSelected)
            #expect(model.activeDocumentID == nil)
            #expect(feature.isLoadingDiff == loading)
            #expect(feature.selectedDiffPatch == (loading ? "" : diff.patch))
            if closeBackgroundTab {
                model.closeGitCommitDiff()
                #expect(feature.selectedChange == change)
                #expect(feature.selectedDiffPatch == (loading ? "" : diff.patch))
                #expect(feature.isLoadingDiff == loading)
                #expect(!model.editorTabItems.contains(.repositoryDiff))
                #expect(model.activeDocumentID == nil, "Closing a hidden tab must not activate its return document")
            } else {
                #expect(model.requestCloseActiveWorkbenchItem())
                #expect(feature.selectedChange == nil, "Close must dismiss the visible working-tree preview")
                #expect(!feature.isLoadingDiff, "Closing the visible preview must clear its loading state immediately")
                #expect(!feature.hasActiveModuleWork, "A closed preview must not block Git module sleep")
                #expect(model.editorTabItems.contains(.repositoryDiff), "The hidden history tab was not the close target")
            }
        }
        let feature = GitFeatureModel(service: GitService(operations: RustGitOperations(core: RustCoreBridge())),
            diffDocumentProvider: { _, _ in
                // Run the close action at the load boundary, before returning
                // the result. No timing assumption or background Git process.
                if loading { await checkClose() }
                return diff
            })
        model.moduleCapabilityStore.cache(GitModuleCapability(feature: feature), id: .gitWorkspace, moduleID: .git)
        model.documentFeature.openVirtualDocument(URL(string: "lithe-test://documents/Example.swift")!,
            text: "example", displayPath: nil)
        do {
            let document = try #require(model.openDocuments.first)
            model.editorTabOrderFeature.moveToEnd(.repositoryDiff)
            model.selectRepositoryDiffTab()
            #expect(model.isRepositoryDiffSelected)

            await feature.selectChange(change)
            if !loading { checkClose() }
            if closeBackgroundTab {
                #expect(feature.selectedDiffPatch == diff.patch)
                #expect(feature.diffRows == diff.rows)
                #expect(feature.diffHunks.map(\.id) == diff.hunks.map(\.id))
                #expect(!feature.isLoadingDiff, "Closing the background tab must let the working-tree load finish")
            } else {
                #expect(feature.selectedChange == nil)
                #expect(feature.selectedDiffPatch.isEmpty && feature.diffRows.isEmpty && feature.diffHunks.isEmpty,
                    "A late result must not repopulate the closed preview")
                #expect(!feature.isLoadingDiff && !feature.hasActiveModuleWork,
                    "The feature must remain idle after the closed preview's load returns")
            }
            #expect(model.openDocuments.contains { $0.id == document.id })
        } catch { await model.shutdownProjectSession(); throw error }
        await model.shutdownProjectSession()
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
    @Test func editorGroupsMoveTabsKeepSelectionAndCollapseEmptySplits() throws {
        let feature = EditorTabOrderFeatureModel()
        let a = UUID(), b = UUID(), c = UUID()
        feature.reconcileDocuments(orderedIDs: [a, b, c])
        let original = try #require(feature.groupLayout.groups.first)
        feature.focus(.document(a))
        #expect(feature.drop(.document(b), into: original, side: .right))
        let right = try #require(feature.groupLayout.groups.last)
        #expect(feature.items(in: original) == [.document(a), .document(c)])
        #expect(feature.selectedItem(in: original) == .document(a))
        #expect(feature.items(in: right) == [.document(b)])
        #expect(feature.selectedItem(in: right) == .document(b))
        #expect(!feature.drop(.document(b), into: right, side: .bottom))
        #expect(feature.drop(.document(c), into: right, side: .bottom))
        #expect(feature.groupLayout.groups.count == 3)
        feature.remove(.document(c))
        #expect(feature.groupLayout.groups == [original, right])
        #expect(feature.drop(.document(b), into: original, side: .center))
        #expect(feature.groupLayout == .group(original))
        #expect(feature.selectedItem(in: original) == .document(b))
        #expect(feature.items == [.document(a), .document(b)])
        // New tabs open in the focused group; closing the final tab leaves one reusable empty group.
        feature.reconcileDocuments(orderedIDs: [a, b, c])
        #expect(feature.items(in: original).count == 3)
        feature.reconcileDocuments(orderedIDs: [])
        #expect(feature.groupLayout.groups.count == 1)
        #expect(feature.selectedItem(in: original) == nil)
    }

    @Test(arguments: [true, false])
    func editorGroupDropWaitsForBufferedInputAndRejectsFailedSynchronization(succeeds: Bool) throws {
        let store = EditorTabOrderTestStore()
        let settings = AppSettings(store: store)
        let model = AppModel(settings: settings, services: MacServiceContainer(
            store: store, settings: settings, moduleLaunchMode: .safeMode).services)
        model.documentFeature.openVirtualDocument(URL(string: "lithe-test://documents/First.swift")!, text: "first", displayPath: nil)
        model.documentFeature.openVirtualDocument(URL(string: "lithe-test://documents/Second.swift")!, text: "old buffer", displayPath: nil)
        let document = try #require(model.openDocuments.last)
        var complete: ((Result<Void, Error>) -> Void)?
        document.synchronizeEditor = { complete = $0 }
        defer { document.synchronizeEditor = nil; complete?(.failure(EditorDocument.DocumentError.editorNotSynchronized)) }
        let layout = model.editorTabOrderFeature.groupLayout
        let group = try #require(layout.groups.first)
        // Only the latest pending drop may commit after the editor drain finishes.
        model.moveEditorTab(.document(document.id), toGroup: group, side: .top)
        model.moveEditorTab(.document(document.id), toGroup: group, side: .bottom)
        #expect(model.editorTabOrderFeature.groupLayout == layout)
        let finish = try #require(complete)
        document.text = "latest drained buffer"
        complete = nil
        finish(succeeds ? .success(()) : .failure(EditorDocument.DocumentError.editorNotSynchronized))
        if succeeds {
            let groups = model.editorTabOrderFeature.groupLayout.groups
            #expect(groups.count == 2)
            let bottom = try #require(groups.last)
            #expect(model.editorTabOrderFeature.items(in: bottom) == [.document(document.id)])
            #expect(model.openDocuments.last === document)
            #expect(document.text == "latest drained buffer")
        } else { #expect(model.editorTabOrderFeature.groupLayout == layout) }
    }

    @Test(arguments: [EditorGroupDropSide.right, .bottom], [true, false])
    func nativeTabDragSplitsOnReleaseAndEscCancels(side: EditorGroupDropSide, injectedState: Bool) async throws {
        let store = EditorTabOrderTestStore()
        let settings = AppSettings(store: store)
        let model = AppModel(settings: settings, services: MacServiceContainer(
            store: store, settings: settings, moduleLaunchMode: .safeMode).services)
        model.documentFeature.openVirtualDocument(URL(string: "lithe-test://documents/First.swift")!, text: "first", displayPath: nil)
        model.documentFeature.openVirtualDocument(URL(string: "lithe-test://documents/Second.swift")!, text: "second", displayPath: nil)
        do {
            let first = try #require(model.openDocuments.first), second = try #require(model.openDocuments.last)
            let drag: EditorGroupDragState? = injectedState ? EditorGroupDragState() : nil
            let host = NSHostingView(rootView: EditorAreaView(groupDrag: drag).environmentObject(model)
                .environmentObject(settings).environmentObject(model.editorChrome))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            defer { window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded(); await Task.yield(); host.layoutSubtreeIfNeeded()
            // Parent reconstruction with unchanged geometry must retain the root-owned drag registry.
            host.rootView = EditorAreaView(groupDrag: drag).environmentObject(model)
                .environmentObject(settings).environmentObject(model.editorChrome)
            host.layoutSubtreeIfNeeded(); await Task.yield(); host.layoutSubtreeIfNeeded()
            func send(_ type: NSEvent.EventType, _ point: NSPoint) throws {
                NSApp.sendEvent(try #require(NSEvent.mouseEvent(with: type,
                    location: host.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .leftMouseUp ? 0 : 1)))
            }
            let start = NSPoint(x: 170, y: 18)
            let destination = side == .right ? NSPoint(x: 760, y: 210) : NSPoint(x: 400, y: 370)
            let original = model.editorTabOrderFeature.groupLayout
            try send(.leftMouseDown, start)
            try send(.leftMouseDragged, NSPoint(x: 185, y: 18))
            await Task.yield(); host.layoutSubtreeIfNeeded()
            try send(.leftMouseDragged, destination)
            await Task.yield(); host.layoutSubtreeIfNeeded()
            if let drag { #expect(drag.target?.side == side) }
            // Crossing the center hides only the split overlay; the same held drag remains alive.
            try send(.leftMouseDragged, NSPoint(x: 400, y: 210))
            await Task.yield(); host.layoutSubtreeIfNeeded()
            #expect(drag?.target == nil)
            #expect(window.childWindows?.contains { $0.identifier?.rawValue == "lithe.editor-tab-drag-preview" } == true)
            try send(.leftMouseDragged, NSPoint(x: 40, y: 210))
            await Task.yield(); host.layoutSubtreeIfNeeded()
            if let drag { #expect(drag.target?.side == .left) }
            #expect(window.childWindows?.contains { $0.identifier?.rawValue == "lithe.editor-tab-drag-preview" } == true)
            #expect(model.editorTabOrderFeature.groupLayout == original)
            NSApp.sendEvent(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)))
            try send(.leftMouseUp, destination)
            await Task.yield(); host.layoutSubtreeIfNeeded()
            #expect(drag?.target == nil)
            #expect(model.editorTabOrderFeature.groupLayout == original)
            try send(.leftMouseDown, start)
            try send(.leftMouseDragged, NSPoint(x: 185, y: 18))
            await Task.yield(); host.layoutSubtreeIfNeeded()
            try send(.leftMouseDragged, destination)
            await Task.yield(); host.layoutSubtreeIfNeeded()
            try send(.leftMouseUp, destination)
            await Task.yield(); host.layoutSubtreeIfNeeded()
            let groups = model.editorTabOrderFeature.groupLayout.groups
            #expect(groups.count == 2)
            let primary = try #require(groups.first), secondary = try #require(groups.last)
            #expect(model.editorTabOrderFeature.items(in: primary) == [.document(first.id)])
            #expect(model.editorTabOrderFeature.items(in: secondary) == [.document(second.id)])
            #expect(model.openDocuments.count == 2)
            #expect(window.childWindows?.contains { $0.identifier?.rawValue == "lithe.editor-tab-drag-preview" } != true)
            model.editorDidFocus(first)
            #expect(model.activeDocumentID == first.id)
            model.editorDidFocus(second)
            #expect(model.activeDocumentID == second.id)
        } catch { await model.shutdownProjectSession(); throw error }
        await model.shutdownProjectSession()
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

private struct ActivityTrackerLifecycleTestView: View {
    @State private var active = true

    var body: some View {
        Text("Activity").background(LitheToolWindowActivityTracker(isActive: $active))
    }
}
