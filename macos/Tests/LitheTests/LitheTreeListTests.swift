import AppKit
import LitheCoreContracts
import LitheExecutionModule
import SwiftUI
import Testing

@testable import Lithe

@MainActor
@Suite("Complete shared tree/list", .serialized)
struct LitheTreeListTests {
    @Test func selectionPreservesRangeAnchorAndCommandUnion() {
        let rows = ["a", "b", "c", "d"]
        #expect(
            LitheTreeListSelection.select("d", in: rows, selected: ["a"], anchor: "b", extending: true, toggling: false)
                == ["b", "c", "d"])
        #expect(
            LitheTreeListSelection.select(
                "b", in: rows, selected: ["b", "c", "d"], anchor: "b", extending: true, toggling: false) == ["b"])
        #expect(
            LitheTreeListSelection.select("d", in: rows, selected: ["a"], anchor: "c", extending: true, toggling: true)
                == ["a", "c", "d"])
        #expect(
            LitheTreeListSelection.select(
                "a", in: rows, selected: ["a", "d"], anchor: "a", extending: false, toggling: true) == ["d"])
        #expect(
            LitheTreeListSelection.select(
                "b", in: rows, selected: ["a"], anchor: "removed", extending: true, toggling: false) == ["b"])
        #expect(
            LitheTreeListSelection.select(
                "removed", in: rows, selected: ["a"], anchor: "a", extending: false, toggling: false) == ["a"])
    }

    @Test func growingRangesRevealTheCursorRatherThanTheirAnchor() {
        let visible = ["a", "b", "c", "d"]
        #expect(
            LitheTreeListSelection.revealTarget(cursor: "d", selected: ["a", "b", "c", "d"], visible: visible) == "d")
        #expect(LitheTreeListSelection.revealTarget(cursor: "a", selected: ["c"], visible: visible) == "c")
        #expect(
            LitheTreeListSelection.revealTarget(cursor: "removed", selected: ["removed", "c"], visible: visible) == "c")
        #expect(LitheTreeListSelection.revealTarget(cursor: "a", selected: [], visible: visible) == nil)
    }

    @Test func navigationUsesVisibleHierarchyAndStopsAtBounds() {
        let rows: [LitheTreeListHierarchy] = [
            .init(isBranch: true, isExpanded: true), .init(depth: 1),
            .init(depth: 1, isBranch: true), .init(),
        ]
        #expect(LitheTreeListNavigation.resolve(.up, current: nil, rows: rows) == .select(3))
        #expect(LitheTreeListNavigation.resolve(.down, current: nil, rows: rows) == .select(0))
        #expect(LitheTreeListNavigation.resolve(.up, current: 0, rows: rows) == .select(0))
        #expect(LitheTreeListNavigation.resolve(.down, current: 3, rows: rows) == .select(3))
        #expect(LitheTreeListNavigation.resolve(.right, current: 0, rows: rows) == .select(1))
        #expect(LitheTreeListNavigation.resolve(.left, current: 2, rows: rows) == .select(0))
        #expect(LitheTreeListNavigation.resolve(.right, current: 2, rows: rows) == .expand(2, true))
        #expect(LitheTreeListNavigation.resolve(.left, current: 0, rows: rows) == .expand(0, false))
        #expect(LitheTreeListNavigation.resolve(.right, current: 1, rows: rows) == nil)
        #expect(LitheTreeListNavigation.resolve(.down, current: 0, rows: []) == nil)
    }

    @Test func branchActivationExpandsWhileLeavesKeepTheirAction() {
        var expansions: [Bool] = []
        var activations = 0
        let expand: (Bool) -> Void = { expansions.append($0) }
        let activate = { activations += 1 }
        LitheTreeListHierarchy(isBranch: true).activate(onExpansion: expand, onActivate: activate)
        LitheTreeListHierarchy(isBranch: true, isExpanded: true)
            .activate(onExpansion: expand, onActivate: activate)
        #expect(expansions == [true, false])
        #expect(activations == 0)
        LitheTreeListHierarchy().activate(onExpansion: expand, onActivate: activate)
        #expect(expansions == [true, false])
        #expect(activations == 1)
        LitheTreeListHierarchy(isBranch: true).activate(onExpansion: nil, onActivate: activate)
        #expect(activations == 2)
    }

    @Test func collapsedBranchesDoNotBuildHiddenDescendants() {
        var childBuilds = 0
        let closed = LitheTreeListNode(id: "root", isExpanded: false) {
            Text("Root")
        } children: {
            childBuilds += 1
            return [LitheTreeListNode(id: "child") { Text("Child") }]
        }
        #expect(LitheTreeListNode.visible([closed]).map(\.id) == ["root"])
        #expect(childBuilds == 0)
        var opened = closed
        opened.isExpanded = true
        let visible = LitheTreeListNode.visible([opened])
        #expect(visible.map(\.id) == ["root", "child"])
        #expect(visible.map(\.depth) == [0, 1])
        #expect(childBuilds == 1)
    }

    @Test func navigationSkipsPlainHeadersButKeepsExpandableBranches() {
        let rows: [LitheTreeListHierarchy] = [
            .init(isSelectable: false), .init(depth: 1), .init(isSelectable: false),
            .init(depth: 1), .init(isBranch: true, isSelectable: false), .init(depth: 1),
            .init(isSelectable: false),
        ]
        #expect(LitheTreeListNavigation.resolve(.down, current: 1, rows: rows) == .select(3))
        #expect(LitheTreeListNavigation.resolve(.up, current: 3, rows: rows) == .select(1))
        #expect(LitheTreeListNavigation.resolve(.down, current: 3, rows: rows) == .select(4))
        #expect(LitheTreeListNavigation.resolve(.right, current: 4, rows: rows) == .expand(4, true))
        #expect(LitheTreeListNavigation.resolve(.down, current: nil, rows: rows) == .select(1))
        #expect(LitheTreeListNavigation.resolve(.up, current: nil, rows: rows) == .select(5))
        #expect(LitheTreeListNavigation.resolve(.down, current: 5, rows: rows) == .select(5))
        #expect(LitheTreeListNavigation.resolve(.down, current: nil, rows: [.init(isSelectable: false)]) == nil)
    }

    @Test func externalSelectionRetargetsMountedKeyboardAndPreservesShiftAnchor() async throws {
        let app = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = (app.accessibilityAttributeValue(attribute) as? Bool) ?? false
        app.accessibilitySetValue(true, forAttribute: attribute)
        defer { app.accessibilitySetValue(previous, forAttribute: attribute) }
        let state = TreeListInteractionState()
        let host = NSHostingView(rootView: TreeKeyboardFixture(state: state))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.makeFirstResponder(nil); window.contentView = nil; window.close() }
        #expect(try #require(await keyboardRow(in: host, text: "a")).accessibilityPerformPress?() == true)
        #expect(await keyboardSettled(host) { state.selected == ["a"] })
        state.selected = ["c"]
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        try sendTreeKey(36, window: window)
        #expect(await keyboardSettled(host) { state.activated.last == "c" })
        try sendTreeKey(125, window: window)
        #expect(await keyboardSettled(host) { state.selected == ["d"] })
        state.selected = ["c"]
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        try sendTreeKey(126, window: window, modifiers: .shift)
        #expect(await keyboardSettled(host) { state.selected == ["b", "c"] }, "Selected: \(state.selected)")
        try sendTreeKey(126, window: window, modifiers: .shift)
        #expect(await keyboardSettled(host) { state.selected == ["a", "b", "c"] }, "Selected: \(state.selected)")
        try sendTreeKey(125, window: window, modifiers: .shift)
        #expect(await keyboardSettled(host) { state.selected == ["b", "c"] }, "Selected: \(state.selected)")
        try sendTreeKey(36, window: window)
        #expect(await keyboardSettled(host) { state.activated.last == "b" })
    }

    @Test func problemsKeyboardCrossesFileHeaderAndOpensTheNextDiagnostic() async throws {
        let app = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = (app.accessibilityAttributeValue(attribute) as? Bool) ?? false
        app.accessibilitySetValue(true, forAttribute: attribute)
        defer { app.accessibilitySetValue(previous, forAttribute: attribute) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Lithe.ProblemsKeyboard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("A.java"), second = directory.appendingPathComponent("B.java")
        for file in [first, second] { try "class Test {}\n\n\n".write(to: file, atomically: true, encoding: .utf8) }
        let domain = "Lithe.ProblemsKeyboard.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = MacUserDefaultsStore(defaults: defaults), settings = AppSettings(store: store)
        let model = AppModel(settings: settings,
            services: MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode).services)
        model.openProjectDirectly(directory)
        defer { model.workspaceFeature.reset() }
        let diagnostics = EditorDiagnosticsStore()
        func diagnostic(_ file: URL, line: Int, message: String) -> EditorDiagnostic {
            .init(id: file.lastPathComponent, fileURL: file, line: line, utf16Column: 1,
                  endLine: line, endUTF16Column: 2, severity: .error, message: message,
                  source: "test", code: nil, tags: [], relatedInformation: [])
        }
        diagnostics.replace([first: [diagnostic(first, line: 0, message: "A problem")],
                             second: [diagnostic(second, line: 2, message: "B problem")]])
        let host = NSHostingView(rootView: ProblemsView(initialScope: .projectErrors)
            .environmentObject(model).environmentObject(diagnostics))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.makeFirstResponder(nil); window.contentView = nil; window.close() }
        #expect(await keyboardSettled(host) { model.projectFiles.contains(first) })
        #expect(try #require(await keyboardRow(in: host, text: "A problem")).accessibilityPerformPress?() == true)
        #expect(await keyboardSettled(host) { model.activeDocument?.url.resolvingSymlinksInPath() == first.resolvingSymlinksInPath() }, "Opened: \(String(describing: model.activeDocument?.url))")
        try sendTreeKey(125, window: window)
        try sendTreeKey(36, window: window)
        #expect(await keyboardSettled(host) { model.activeDocument?.url.resolvingSymlinksInPath() == second.resolvingSymlinksInPath() }, "Opened: \(String(describing: model.activeDocument?.url))")
        #expect(model.editorNavigationTarget?.url == second)
        #expect(model.editorNavigationTarget?.line == 2)
        #expect(model.editorNavigationTarget?.utf16Column == 1)
    }

    private func keyboardSettled(_ host: NSView, until predicate: () -> Bool) async -> Bool {
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(2))
        repeat {
            host.layoutSubtreeIfNeeded()
            if predicate() { return true }
            await Task.yield()
        } while clock.now < deadline
        return predicate()
    }

    private func keyboardRow(in host: NSView, text: String) async -> AnyObject? {
        func contains(_ value: Any) -> Bool {
            let item = value as AnyObject
            let string: String? = item.accessibilityValue?()
            return string == text || (item.accessibilityLabel?() ?? "").contains(text)
                || (item.accessibilityChildren?() ?? []).contains(where: contains)
        }
        func find(_ value: Any) -> AnyObject? {
            let item = value as AnyObject
            if item.accessibilityRole?() == .button, contains(item) { return item }
            return (item.accessibilityChildren?() ?? []).lazy.compactMap(find).first
        }
        var result: AnyObject?
        _ = await keyboardSettled(host) { result = find(host); return result != nil }
        return result
    }

    private func sendTreeKey(_ code: UInt16, window: NSWindow, modifiers: NSEvent.ModifierFlags = []) throws {
        let text = code == 36 ? "\r" : code == 125 ? "\u{F701}" : "\u{F700}"
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: text,
            charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        NSApp.sendEvent(event)
    }

    @Test func mountedListExposesSelectionAndPreservesEmbeddedActions() async throws {
        let application = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = (application.accessibilityAttributeValue(attribute) as? Bool) ?? false
        application.accessibilitySetValue(true, forAttribute: attribute)
        defer { application.accessibilitySetValue(previous, forAttribute: attribute) }
        let domain = "Lithe.TreeAccessibility.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = MacUserDefaultsStore(defaults: defaults)
        let settings = AppSettings(store: store)
        let model = AppModel(settings: settings,
            services: MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode).services)
        let resultRoot = try #require(URL(string: "lithe-fixture://results/"))
        let state = TreeListInteractionState()
        let host = NSHostingView(
            rootView: LitheTreeList(
                ["a", "b", "c", "d"], id: \.self,
                selection: Binding(get: { state.selected }, set: { state.selected = $0 }),
                onActivate: {
                    state.activated.append($0)
                    model.documentFeature.openVirtualDocument(resultRoot.appendingPathComponent($0 + ".java"),
                                                              text: "class Result {}", displayPath: nil)
                }
            ) { value in
                HStack {
                    Text(value).accessibilityIdentifier("row-label-" + value)
                    if value == "a" {
                        Button("Refresh") { state.activated.append("refresh") }
                            .accessibilityIdentifier("embedded-refresh")
                    }
                }
            }
            .frame(width: 260, height: 180).background(LitheTheme.editor))
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 260, height: 180),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        func find(_ value: Any, id: String? = nil, containingText text: String? = nil) -> AnyObject? {
            let accessible = value as AnyObject
            let children = accessible.accessibilityChildren?() ?? []
            if let id, accessible.accessibilityIdentifier?() == id { return accessible }
            if let text, accessible.accessibilityRole?() == .button,
                children.contains(where: {
                    ($0 as AnyObject).accessibilityIdentifier?() == "row-label-" + text
                })
            {
                return accessible
            }
            return children.lazy.compactMap { find($0, id: id, containingText: text) }.first
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        var row: AnyObject?
        repeat {
            host.layoutSubtreeIfNeeded()
            row = find(host, containingText: "b")
            if row != nil { break }
            await Task.yield()
        } while clock.now < deadline
        let selected = try #require(row)
        #expect(selected.accessibilityPerformPress?() == true)
        #expect(state.selected == ["b"])
        let refresh = try #require(find(host, id: "embedded-refresh"))
        #expect(refresh.accessibilityPerformPress?() == true)
        #expect(state.activated == ["b", "refresh"])
        #expect(model.activeDocument?.url == resultRoot.appendingPathComponent("b.java"))
        #expect(state.selected == ["b"])

    }

    @Test(arguments: [false, true], ["Run", "Exclude from dependency tree"])
    func emptyNodeMenuPreservesEmbeddedBusinessMenu(multiple: Bool, title: String) async throws {
        let app = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = (app.accessibilityAttributeValue(attribute) as? Bool) ?? false
        app.accessibilitySetValue(true, forAttribute: attribute)
        defer { app.accessibilitySetValue(previous, forAttribute: attribute) }
        var executions = 0
        let node = LitheTreeListNode(id: "row") {
            Text("Business row").frame(maxWidth: .infinity, alignment: .leading)
                .litheContextMenu { [.action(title, localizesTitle: false) { executions += 1 }] }
        }
        var single: String?
        var selected: Set<String> = []
        let content: AnyView = multiple
            ? AnyView(LitheTreeList(nodes: [node], selection: Binding(get: { selected }, set: { selected = $0 })))
            : AnyView(LitheTreeList(nodes: [node], selection: Binding(get: { single }, set: { single = $0 })))
        let host = NSHostingView(rootView: content.frame(width: 300, height: 160))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 160),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { LitheContextMenuPresenter.shared.dismiss(); window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        let point = NSPoint(x: 120, y: host.isFlipped ? 16 : host.bounds.height - 16)
        let rightClick = try #require(NSEvent.mouseEvent(with: .rightMouseDown,
            location: host.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let captures = views(host).filter { String(describing: type(of: $0)) == "LitheRightClickCaptureView" }
        #expect(captures.count == 1, "An empty node menu must not install a second capture above the business menu")
        let capture = try #require(captures.first)
        // Invoke the actual AppKit event boundary; do not run a nested application event loop.
        capture.rightMouseDown(with: rightClick)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        func menu() -> NSPanel? { NSApp.windows.compactMap { $0 as? NSPanel }.first { $0.isVisible } }
        while menu() == nil && clock.now < deadline { await Task.yield(); host.layoutSubtreeIfNeeded() }
        let popup = try #require(menu(), "An absent node menu must leave Run/Edit/Pin and dependency menus reachable")
        func find(_ value: Any) -> AnyObject? {
            let item = value as AnyObject
            if item.accessibilityRole?() == .button, item.accessibilityLabel?() == title { return item }
            return (item.accessibilityChildren?() ?? []).lazy.compactMap(find).first
        }
        let contentView = try #require(popup.contentView)
        let action = try #require(find(contentView))
        #expect(action.accessibilityPerformPress?() == true)
        #expect(executions == 1)
    }

    @Test func realDependencySidebarMenuExcludesTheConfiguredPath() async throws {
        let app = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = (app.accessibilityAttributeValue(attribute) as? Bool) ?? false
        app.accessibilitySetValue(true, forAttribute: attribute)
        defer { app.accessibilitySetValue(previous, forAttribute: attribute) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("acceptance-library"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let domain = "Lithe.DependencyMenuAcceptance.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = MacUserDefaultsStore(defaults: defaults)
        let settings = AppSettings(store: store)
        let model = AppModel(settings: settings,
            services: MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .normal).services)
        do {
            let access = try #require(await model.activateExecutionModule())
            let feature = access.runFeature
            await feature.loadProject(at: root, files: [], mavenProject: nil)
            // Use a registered source with an explicit local path, isolating UI dispatch
            // from language-server startup while exercising the real dependency feature.
            feature.registerDependencySource(languageID: "acceptance", displayName: "Acceptance dependencies")
            feature.updateDependencyPaths(DependencyPathConfiguration(sourcePaths: ["acceptance-library"]),
                                          serviceID: "language:acceptance")
            let host = NSHostingView(rootView: DependencySidebarView(refreshRevision: 0)
                .environmentObject(model).environmentObject(settings).frame(width: 400, height: 500))
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 500),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer { LitheContextMenuPresenter.shared.dismiss(); window.contentView = nil; window.close() }
            func hasText(_ value: Any, _ text: String) -> Bool {
                let item = value as AnyObject
                let stringValue: String? = item.accessibilityValue?()
                if stringValue == text || item.accessibilityLabel?() == text { return true }
                return (item.accessibilityChildren?() ?? []).contains { hasText($0, text) }
            }
            func row(_ value: Any, _ text: String) -> AnyObject? {
                let item = value as AnyObject
                if item.accessibilityRole?() == .button, hasText(item, text) { return item }
                return (item.accessibilityChildren?() ?? []).lazy.compactMap { row($0, text) }.first
            }
            func waitForRow(_ text: String) async -> AnyObject? {
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: .seconds(2))
                repeat {
                    host.layoutSubtreeIfNeeded()
                    if let found = row(host, text) { return found }
                    await Task.yield()
                } while clock.now < deadline
                return nil
            }
            let service = try #require(await waitForRow("Acceptance dependencies"))
            #expect(service.accessibilityPerformPress?() == true)
            let sources = try #require(await waitForRow("Source Code"))
            #expect(sources.accessibilityPerformPress?() == true)
            let library = try #require(await waitForRow("acceptance-library"))
            let rect = try #require(library.accessibilityFrame?())
            let point = window.convertPoint(fromScreen: NSPoint(x: rect.midX, y: rect.midY))
            func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
            let capture = try #require(views(host).filter {
                String(describing: type(of: $0)) == "LitheRightClickCaptureView"
                    && $0.convert($0.bounds, to: nil).contains(point)
            }.min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height })
            capture.rightMouseDown(with: try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: point,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1)))
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(2))
            func menu() -> NSPanel? { NSApp.windows.compactMap { $0 as? NSPanel }.first { $0.isVisible } }
            while menu() == nil && clock.now < deadline { await Task.yield() }
            let popup = try #require(menu())
            let content = try #require(popup.contentView)
            let action = try #require(row(content, "Exclude from dependency tree"))
            #expect(action.accessibilityPerformPress?() == true)
            #expect(feature.dependencyPaths(for: "language:acceptance").excludedPaths == ["acceptance-library"])
            let graph = try #require(try await feature.resolveDependencies(serviceID: "language:acceptance"))
            #expect(graph.roots.first?.children.first?.children.isEmpty == true)
        } catch { await model.shutdownProjectSession(); throw error }
        await model.shutdownProjectSession()
    }

    @Test func productRowsCannotUseTheRetiredStyleRecipe() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Lithe")
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var failures: [String] = []
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            if source.contains(".litheTreeRow(") || source.contains(".litheSelectionRow(") {
                failures.append(file.lastPathComponent)
            }
            if file.lastPathComponent != "LitheTreeList.swift", source.contains("LitheTreeListRowSurface(") {
                failures.append(file.lastPathComponent)
            }
        }
        #expect(failures.isEmpty, "Tree/list callers must use LitheTreeList: \(failures)")
    }
}

@MainActor
private struct TreeKeyboardFixture: View {
    @ObservedObject var state: TreeListInteractionState

    var body: some View {
        LitheTreeList(["a", "b", "c", "d"], id: \.self,
            selection: Binding(get: { state.selected }, set: { state.selected = $0 }),
            onActivate: { state.activated.append($0) }) { Text($0) }
    }
}

@MainActor
private final class TreeListInteractionState: ObservableObject {
    @Published var selected: Set<String> = []
    var activated: [String] = []
}

@MainActor
struct DependencyTreePresentationTests {
    @Test func cancelledServiceCannotOverwriteANewerLoadOrUnmount() async throws {
        let state = DependencyTreePresentation()
        let started = TestGate()
        let release = TestGate()
        defer {
            started.open()
            release.open()
            state.close()
        }
        state.update("service") {
            $0.expanded = true
            $0.expandedNodeIDs = ["dependency"]
        }
        let oldGeneration = state.begin("service")
        var wasCancelled = false
        let oldTask = Task { @MainActor in
            started.open()
            _ = await release.waitUntilOpen()
            wasCancelled = Task.isCancelled
        }
        defer { oldTask.cancel() }
        state.retain(oldTask, for: "service")
        #expect(await started.waitUntilOpen())
        let nextGeneration = state.begin("service")
        state.finish("service", generation: oldGeneration, graph: nil, error: "stale")
        #expect(state.state(for: "service").resolving)
        #expect(state.state(for: "service").error == nil)
        state.finish("service", generation: nextGeneration, graph: nil, error: "current")
        #expect(state.state(for: "service").error == "current")
        state.close()
        state.finish("service", generation: nextGeneration, graph: nil, error: "late")
        #expect(state.state(for: "service").error == "current")
        #expect(state.state(for: "service").expanded)
        state.invalidate()
        #expect(state.state(for: "service").error == nil)
        #expect(state.state(for: "service").expandedNodeIDs == ["dependency"])
        release.open()
        await oldTask.value
        #expect(wasCancelled)
        state.retainServices([])
        #expect(!state.state(for: "service").expanded)
    }
}

@MainActor
struct LitheTreeListViewportTests {
    @Test func nativePointerAdapterKeepsShortTreesAtTheTop() throws {
        let probe = TreeListViewportProbeStore()
        let host = NSHostingView(
            rootView: LitheTreeList(
                ["first", "second"], id: \.self,
                selection: .constant(Set<String>()),
                native: LitheTreeListNativeInteraction(
                    copy: {}, paste: {}, selectAll: {}, navigate: { _, _ in nil }, isSelected: { _ in false })
            ) { value in
                Text(value).background { if value == "first" { TreeListViewportProbe(store: probe) } }
            }.frame(width: 300, height: 400))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        let firstRow = try #require(probe.view)
        let frame = host.convert(firstRow.bounds, from: firstRow)
        let top = host.isFlipped ? frame.minY : host.bounds.maxY - frame.maxY
        #expect(top >= LitheTheme.Tree.verticalInset)
        #expect(top < LitheTheme.Tree.rowHeight, "A short two-axis tree must not center its rows in the viewport")
    }

    @Test func latestOutsidePointerReleasesFocusButUnmountedCallbacksCannot() {
        var active = false
        var ownsFocus = true
        var scheduled: [() -> Void] = []
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        let coordinator = LitheToolWindowActivityTracker.Coordinator(
            isActive: Binding(get: { active }, set: { active = $0 }),
            onPointerActivity: { if !$0 { ownsFocus = false } }, schedule: { scheduled.append($0) })
        coordinator.view = view
        defer {
            coordinator.stopObservingFocus()
            window.contentView = nil
            window.close()
        }
        func drain() {
            let callbacks = scheduled
            scheduled.removeAll()
            callbacks.forEach { $0() }
        }
        coordinator.queuePointerActivity(false)
        #expect(ownsFocus, "Focus changes must be deferred out of the native callback")
        drain()
        #expect(!ownsFocus)
        ownsFocus = true
        coordinator.queuePointerActivity(false)
        coordinator.queuePointerActivity(true)
        drain()
        #expect(ownsFocus, "An older outside click must not override the latest click inside")
        coordinator.queuePointerActivity(false)
        coordinator.stopObservingFocus()
        drain()
        #expect(ownsFocus, "Unmount invalidates deferred pointer ownership along with activity")
    }
}

@MainActor
private final class TreeListViewportProbeStore {
    weak var view: NSView?
}

private struct TreeListViewportProbe: NSViewRepresentable {
    let store: TreeListViewportProbeStore
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        store.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}
