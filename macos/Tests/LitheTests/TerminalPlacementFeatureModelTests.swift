import AppKit
import SwiftUI
import WebKit
import Foundation
import LitheModuleAPI
import LitheApplicationKernel
import LitheDebugModule
import LitheCoreContracts
import LitheTerminalModule
import Testing
@testable import Lithe

@Suite("Terminal tab placement")
@MainActor
struct TerminalPlacementFeatureModelTests {
    @Test
    func debugStandardInputNeverFallsBackToAnotherActiveSessionsTerminal() async throws {
        let runtime = ModuleRuntime()
        for id in [ModuleID.workspace, .languageIntelligence, .execution] {
            let manifest = ModuleManifest(id: id, displayName: id.rawValue, scope: .workspace)
            try runtime.register(ModuleFactory(manifest: manifest) { InputTestDependency(manifest: manifest) })
        }
        let sessions = DebugAdapterSessionManager(providers: [
            DebugProviderDescriptor(id: "java", displayName: "Java", fileExtensions: ["java"])
        ]) { _, _ in InputTestDebugSession() }
        let feature = GenericDebugFeatureModel(sessions: sessions)
        let graph = InputTestDebugGraph(feature: feature)
        try runtime.register(ModuleFactory(manifest: DebugModule.moduleManifest, contributions: DebugModule.moduleContributions) { DebugModule(makeGraph: { graph }) })
        let store = TerminalPlacementTestStore()
        let settings = AppSettings(store: store)
        let model = AppModel(settings: settings,
            services: MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode).services)
        let aTransport = PlacementTestTerminalTransport(), bTransport = PlacementTestTerminalTransport()
        var created = 0
        let terminals = TerminalFeatureModel(terminalFactory: {
            defer { created += 1 }
            return created == 0 ? aTransport : bTransport
        })
        defer { terminals.stopAllSessions(); feature.reset() }
        do {
            _ = try await runtime.activate(.debug)
            let capability = runtime.capability(.debugWorkspace) as? DebugModuleCapability
            model.cacheModuleCapability(try #require(capability), id: .debugWorkspace, moduleID: .debug)
            model.cacheModuleCapability(TerminalModuleCapability(feature: terminals), id: .terminalWorkspace, moduleID: .terminal)
            let root = URL(fileURLWithPath: "/workspace/debug-input")
            let source = root.appendingPathComponent("Main.java")
            let a = try sessions.activateNew(for: source, rootURL: root).id
            let b = try sessions.activateNew(for: source, rootURL: root).id
            let aTerminal = terminals.createSession(in: root, shellPath: "/bin/zsh")
            let bTerminal = terminals.createSession(in: root, shellPath: "/bin/zsh")
            model.debugTerminalSessionIDs = [aTerminal.id, bTerminal.id]
            model.activeDebugTerminalSessionID = bTerminal.id
            model.debugTerminalSessionIDsByDebugSession = [a: [aTerminal.id], b: [bTerminal.id]]
            model.activeDebugTerminalSessionIDsByDebugSession = [a: aTerminal.id, b: bTerminal.id]
            aTerminal.stop()
            #expect(feature.selectSession(a))
            #expect(!model.isDebugStandardInputAvailable)
            #expect(!model.sendDebugStandardInput("must not reach B"))
            #expect(aTransport.sentInputs.isEmpty && bTransport.sentInputs.isEmpty)
            // A missing binding also cannot fall back to the globally selected B.
            model.debugTerminalSessionIDsByDebugSession[a] = nil
            model.activeDebugTerminalSessionIDsByDebugSession[a] = nil
            #expect(!model.isDebugStandardInputAvailable)
            #expect(!model.sendDebugStandardInput("still A"))
            #expect(bTransport.sentInputs.isEmpty)
            #expect(feature.selectSession(b))
            #expect(model.isDebugStandardInputAvailable)
            #expect(model.sendDebugStandardInput("for B"))
            #expect(bTransport.sentInputs == ["for B\n"])
            #expect(aTransport.sentInputs.isEmpty)
        } catch {
            await runtime.shutdownAll()
            throw error
        }
        await runtime.shutdownAll()
    }

    @Test(arguments: [false, true])
    func remountDoesNotStealTerminalFocus(switchBeforeAttach: Bool) async throws {
        let context = makeTerminalCloseContext(), owner = UUID()
        let model = context.model
        do {
            model.documentFeature.openVirtualDocument(URL(string: "lithe-test://remount/A.swift")!, text: "A", displayPath: nil)
            let document = try #require(model.openDocuments.first)
            model.selectEditorDocument(document)
            let group = try #require(model.editorTabOrderFeature.groupLayout.groups.first)
            model.editorTabOrderFeature.moveToEnd(.terminal(context.session.id))
            #expect(model.editorTabOrderFeature.drop(.terminal(context.session.id), into: group, side: .right))
            let session = MonacoWorkbenchSession.forModel(UUID(), documentID: document.id)
            let container = session.makeContainer(ownerID: owner, isPreview: false)
            let webView = try #require(container.subviews.first as? WKWebView)
            session.update(ownerID: owner, document: document, secondaryDocument: nil, preview: nil,
                markdownScrollPosition: nil, model: model, fontSize: 14, fontFamily: "monospace",
                theme: .init(colorTheme: .lithe, isDark: true, revealsWorkbenchBackground: false),
                wrap: false, minimap: false, markers: [], secondaryMarkers: [])
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { session.detachView(ownerID: owner); webView.stopLoading(); window.close() }
            let root = try #require(window.contentView)
            let terminal = try #require(context.transport.nativeView as? NSTextView)
            root.addSubview(terminal)
            #expect(window.makeFirstResponder(terminal))
            if switchBeforeAttach { model.selectEditorTerminalSession(context.session) }
            root.addSubview(container)
            if !switchBeforeAttach { model.selectEditorTerminalSession(context.session) }
            // FIFO main-queue barrier observes the production post-attach callback.
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            #expect(model.activeDocumentID == document.id)
            #expect(window.firstResponder === terminal)
            model.selectEditorDocument(document)
            container.removeFromSuperview(); root.addSubview(container)
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            #expect(window.firstResponder === webView)
        } catch { await model.shutdownProjectSession(); throw error }
        await model.shutdownProjectSession()
    }

    @Test(arguments: [false, true])
    func documentFocusRestoresSelectionAfterTerminalOrDatabase(database: Bool) async throws {
        let context = makeTerminalCloseContext()
        let model = context.model
        do {
            model.documentFeature.openVirtualDocument(URL(string: "lithe-test://focus/A.swift")!, text: "A", displayPath: nil)
            let document = try #require(model.openDocuments.first)
            model.selectEditorDocument(document)
            let group = try #require(model.editorTabOrderFeature.groupLayout.groups.first)
            model.editorTabOrderFeature.moveToEnd(.terminal(context.session.id))
            #expect(model.editorTabOrderFeature.drop(.terminal(context.session.id), into: group, side: .right))
            model.selectEditorTerminalSession(context.session)
            if database {
                model.editorTabOrderFeature.moveToEnd(.database(nil))
                model.editorTabOrderFeature.databaseSelected = true
                model.editorTabOrderFeature.focus(.database(nil))
            }
            #expect(model.activeDocumentID == document.id)
            model.editorDidFocus(document)
            #expect(model.activeEditorTerminalSession == nil)
            #expect(!model.isDatabaseWorkspaceSelected)
            #expect(model.editorTabOrderFeature.selectedItem(in: group) == .document(document.id))
            model.showFindBar()
            #expect(model.isFindBarVisible)
            #expect(model.requestCloseActiveWorkbenchItem())
            #expect(!model.openDocuments.contains { $0.id == document.id })
            #expect(model.editorTerminalSessions.contains { $0.id == context.session.id })
            if database { #expect(model.editorTabItems.contains(.database(nil))) }
        } catch { await model.shutdownProjectSession(); throw error }
        await model.shutdownProjectSession()
    }

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
    func closingRunningTerminalImmediatelyStopsAndRemovesIt() {
        let context = makeTerminalCloseContext()
        defer { context.model.terminalFeature?.stopAllSessions() }

        #expect(context.model.requestCloseActiveWorkbenchItem())
        #expect(!context.model.terminalSessions.contains { $0.id == context.session.id })
        #expect(context.model.activeEditorTerminalSession == nil)
        #expect(!context.session.isRunning)
        #expect(context.transport.stopCount == 1)
        context.model.requestCloseTerminalSession(context.session)
        #expect(context.transport.stopCount == 1)
    }

    @Test
    func closingLastToolTerminalHidesPanelAndPreservesEditorSession() throws {
        let context = makeTerminalCloseContext()
        let feature = try #require(context.model.terminalFeature)
        defer { feature.stopAllSessions() }
        let toolSession = feature.createSession(
            in: URL(fileURLWithPath: "/tmp/lithe-terminal-close-tests"), shellPath: "/bin/zsh"
        )
        context.model.terminalPlacementFeature.registerSession(toolSession.id)
        context.model.workbenchFeature.setVisibility(.terminal, isVisible: true)

        context.model.requestCloseTerminalSession(toolSession)

        #expect(context.model.toolTerminalSessions.isEmpty)
        #expect(!context.model.workbenchFeature.isVisible(.terminal))
        #expect(context.model.terminalSessions.contains { $0.id == context.session.id })
        #expect(context.session.isRunning)
        #expect(!toolSession.isRunning)
    }

    @Test(arguments: [ColorScheme.dark, .light])
    func retainedTerminalRestoresFocusAndWallpaperWithoutRecreatingItsSurface(scheme: ColorScheme) async throws {
        let context = makeTerminalCloseContext(), state = RetainedTerminalReviewState()
        let model = context.model
        model.terminalPlacementFeature.moveToTool(context.session.id)
        do {
            let feature = try #require(model.terminalFeature)
            let store = WorkbenchToolContentStore()
            let host = NSHostingView(rootView: RetainedTerminalReviewHost(state: state, store: store,
                model: model, feature: feature).environment(\.colorScheme, scheme))
            host.sizingOptions = []
            host.frame = NSRect(x: 0, y: 0, width: 480, height: 400)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 440),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.contentView = nil; window.close() }
            let root = try #require(window.contentView)
            root.addSubview(host)
            let editor = NSTextView(frame: NSRect(x: 0, y: 400, width: 480, height: 40))
            root.addSubview(editor)
            let terminal = try #require(context.session.nativeView as? NSView)
            let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(3))
            while (terminal.window !== window || window.firstResponder !== terminal) && clock.now < deadline {
                host.layoutSubtreeIfNeeded()
                await Task.yield()
            }
            try #require(window.firstResponder === terminal)
            let retainedHost = try #require(store.entries[.terminal]?.host)
            func sample(_ y: CGFloat) throws -> NSColor {
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
                return try #require(bitmap.colorAt(x: Int(2 * scale), y: Int(y * scale))?.usingColorSpace(.sRGB))
            }
            let solid = try [sample(16), sample(200)]
            state.hasImage = true
            host.layoutSubtreeIfNeeded()
            let image = try [sample(16), sample(200)]
            #expect(image[0] == image[1], "Real terminal header and body must expose the same backing image")
            #expect(image[0] != solid[0] && image[1] != solid[1])
            state.hasImage = false
            host.layoutSubtreeIfNeeded()
            #expect(try [sample(16), sample(200)] == solid)
            state.visible = false
            host.layoutSubtreeIfNeeded()
            #expect(terminal.isHiddenOrHasHiddenAncestor)
            #expect(window.makeFirstResponder(editor))
            state.visible = true
            host.layoutSubtreeIfNeeded()
            // FIFO observes the single production activation scheduled after layout.
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            #expect(window.firstResponder === terminal)
            #expect(store.entries[.terminal]?.host === retainedHost)
            #expect(ObjectIdentifier(context.session.nativeView) == ObjectIdentifier(terminal))
            #expect(window.makeFirstResponder(editor))
            for width: CGFloat in [460, 440, 480] {
                host.frame.size.width = width
                host.layoutSubtreeIfNeeded()
                store.refresh()
            }
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            #expect(window.firstResponder === editor, "Resizing a visible terminal must not steal focus")
            // Hide before queued activation is delivered: the editor keeps focus.
            state.visible = false; host.layoutSubtreeIfNeeded()
            state.visible = true; host.layoutSubtreeIfNeeded()
            state.visible = false; host.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            #expect(window.firstResponder === editor)
        } catch { await model.shutdownProjectSession(); throw error }
        await model.shutdownProjectSession()
    }

    @Test
    func hiddenToolSessionRemountCannotTakeFocusFromEditorTerminal() async throws {
        let context = makeTerminalCloseContext(), state = RetainedTerminalReviewState()
        let model = context.model
        model.terminalPlacementFeature.moveToTool(context.session.id)
        do {
            let feature = try #require(model.terminalFeature)
            let b = feature.createSession(in: URL(fileURLWithPath: "/workspace/focus"), shellPath: "/bin/zsh")
            let c = feature.createSession(in: URL(fileURLWithPath: "/workspace/focus"), shellPath: "/bin/zsh")
            model.terminalPlacementFeature.registerSession(b.id)
            model.terminalPlacementFeature.registerSession(c.id)
            model.terminalPlacementFeature.moveToEditor(c.id)
            model.selectTerminalSession(b)
            let store = WorkbenchToolContentStore()
            let host = NSHostingView(rootView: VStack(spacing: 0) {
                TerminalSurfaceView(session: c).environmentObject(model).frame(height: 160)
                RetainedTerminalReviewHost(state: state, store: store, model: model, feature: feature)
            })
            host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 440),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            let aView = try #require(context.session.nativeView as? NSView)
            let bView = try #require(b.nativeView as? NSView)
            let cView = try #require(c.nativeView as? NSView)
            let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(3))
            while (bView.window !== window || cView.window !== window) && clock.now < deadline {
                host.layoutSubtreeIfNeeded()
                await Task.yield()
            }
            try #require(bView.window === window && cView.window === window)
            state.visible = false
            host.layoutSubtreeIfNeeded()
            try #require(bView.isHiddenOrHasHiddenAncestor)
            #expect(window.makeFirstResponder(cView))
            let requests = context.transport.focusCount
            // Selecting C changes the hidden tool canvas from B back to A.
            model.selectEditorTerminalSession(c)
            let mountDeadline = clock.now.advanced(by: .seconds(3))
            while aView.window !== window && clock.now < mountDeadline {
                host.layoutSubtreeIfNeeded()
                await Task.yield()
            }
            try #require(aView.window === window)
            try #require(aView.isHiddenOrHasHiddenAncestor)
            // Observe the native update callback and SwiftUI appearance task.
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            await Task.yield()
            #expect(context.transport.focusCount == requests, "Hidden appearance must not request session focus")
            #expect(window.firstResponder === cView, "Hidden native callbacks must not steal the editor terminal's focus")
            state.visible = true
            host.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            #expect(window.firstResponder === aView, "Reopening must explicitly activate the current tool session")
        } catch { await model.shutdownProjectSession(); throw error }
        await model.shutdownProjectSession()
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
        var isFirstTransport = true
        let feature = TerminalFeatureModel(terminalFactory: {
            defer { isFirstTransport = false }
            return isFirstTransport ? transport : PlacementTestTerminalTransport()
        })
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
    let nativeView: AnyObject = NSTextView()
    var isRunning = false
    var processID: Int32? { isRunning ? 1234 : nil }
    var shellName = "Shell"
    var onTermination: ((Int32?) -> Void)?
    var onOutput: ((Data) -> Void)?
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

    var sentInputs: [String] = []
    func send(_ input: Data) throws { sentInputs.append(String(decoding: input, as: UTF8.self)) }
    func interrupt() throws {}
    var focusCount = 0
    func focus() {
        focusCount += 1
        (nativeView as? NSView)?.window?.makeFirstResponder(nativeView as? NSView)
    }
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

@MainActor
private final class InputTestDebugSession: DebugAdapterSession {
    var isRunning = false
    var state: DebugAdapterState { isRunning ? .running : .idle }
    func start(rootURL: URL) throws { isRunning = true }
    func stop() { isRunning = false }
}

@MainActor
private final class InputTestDebugGraph: DebugServiceGraph {
    let feature: GenericDebugFeatureModel
    init(feature: GenericDebugFeatureModel) { self.feature = feature }
    var genericFeatureTarget: any GenericDebugFeatureTarget { feature }
    var hasActiveDebugWork: Bool { feature.isSessionActive }
    func activate(context: ModuleContext) {}
    func prepareForSleep() async throws {}
    func stop() async { feature.reset() }
}

@MainActor
private final class InputTestDependency: LitheModule {
    let manifest: ModuleManifest
    init(manifest: ModuleManifest) { self.manifest = manifest }
    func activate(context: ModuleContext) async throws {}
    func prepareForSleep() async throws {}
    func sleep() async {}
    func shutdown() async {}
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] { [:] }
}

@MainActor
private final class RetainedTerminalReviewState: ObservableObject {
    @Published var visible = true
    @Published var hasImage = false
}

private struct RetainedTerminalReviewHost: View {
    @ObservedObject var state: RetainedTerminalReviewState
    let store: WorkbenchToolContentStore
    let model: AppModel
    let feature: TerminalFeatureModel
    var body: some View {
        ZStack {
            Color(nsColor: NSColor(srgbRed: 0.8, green: 0.1, blue: 0.6, alpha: 1))
            if state.visible {
                RetainedWorkbenchToolContent(store: store, tool: .terminal,
                    content: TerminalView(feature: feature).environmentObject(model),
                    onActivate: { model.activeToolTerminalSession?.focus() })
                    .environment(\.workbenchHasBackgroundImage, state.hasImage)
            }
        }
        .overlay { WorkbenchToolContentSurface(store: store) }
    }
}
