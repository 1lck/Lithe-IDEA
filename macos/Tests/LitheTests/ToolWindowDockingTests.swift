import AppKit
import SwiftUI
import Testing
@testable import Lithe

@Suite("Tool window docking")
@MainActor
struct ToolWindowDockingTests {
    @Test func clippedToolButtonsDoNotCaptureOtherGroupsOrBecomeDropTargets() throws {
        let drag = ToolWindowDragState()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = try #require(window.contentView)
        let clip = NSClipView(frame: CGRect(x: 0, y: 0, width: 40, height: 280))
        let document = NSView(frame: CGRect(x: 0, y: 0, width: 40, height: 400))
        clip.documentView = document; root.addSubview(clip)
        let tools = Array(WorkbenchFeatureModel.ToolWindow.allCases.prefix(10))
        var sources: [ToolWindowDragSource.SourceView] = []
        var clicks = 0, hiddenDragStarts = 0, neighborClicks = 0
        defer { sources.forEach { $0.dismantle() }; window.close() }
        for index in 0..<9 {
            let source = ToolWindowDragSource.SourceView(frame: CGRect(x: 0, y: index * 40, width: 40, height: 40))
            source.tool = tools[index]; source.position = .init(anchor: .left, group: .primary); source.drag = drag
            source.click = { clicks += 1 }
            source.image = { hiddenDragStarts += 1; return nil }
            sources.append(source); document.addSubview(source)
        }
        clip.scroll(to: CGPoint(x: 0, y: 40))
        let neighbor = ToolWindowDragSource.SourceView(frame: CGRect(x: 0, y: 280, width: 40, height: 40))
        neighbor.tool = tools[9]; neighbor.position = .init(anchor: .left, group: .secondary); neighbor.drag = drag
        neighbor.click = { neighborClicks += 1 }
        sources.append(neighbor); root.addSubview(neighbor)
        func send(_ type: NSEvent.EventType, y: CGFloat) throws {
            NSApp.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: 20, y: y),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)))
        }
        try send(.leftMouseDown, y: 295); try send(.leftMouseDragged, y: 305); try send(.leftMouseUp, y: 305)
        #expect(clicks == 0 && hiddenDragStarts == 0 && neighborClicks == 1)
        drag.begin(tools[1])
        #expect(drag.target(at: CGPoint(x: 20, y: 300))?.before == tools[9])
        drag.finish()
        neighbor.isHidden = true
        #expect(drag.target(at: CGPoint(x: 20, y: 300)) == nil)
        // A partly clipped icon only accepts the visible part, including release.
        clip.scroll(to: CGPoint(x: 0, y: 20))
        try send(.leftMouseDown, y: 270); try send(.leftMouseUp, y: 290)
        #expect(clicks == 0)
        try send(.leftMouseDown, y: 270); try send(.leftMouseUp, y: 270)
        #expect(clicks == 1)
        document.isHidden = true
        try send(.leftMouseDown, y: 270); try send(.leftMouseUp, y: 270)
        #expect(clicks == 1)
        #expect(drag.target(at: CGPoint(x: 20, y: 270)) == nil)
    }

    @Test(arguments: [DockAnchor.left, .right, .bottom], [ColorScheme.dark, .light])
    func dockGroupsHaveIndependentRoundedSurfaces(anchor: DockAnchor, scheme: ColorScheme) throws {
        let host = NSHostingView(rootView: WorkbenchDockGroups(
            anchor: anchor, primaryVisible: true, secondaryVisible: true, fraction: 0.5,
            commitFraction: { _ in }, content: { _ in Color.clear }
        ).frame(width: 400, height: 400).background(LitheTheme.titlebar).environment(\.colorScheme, scheme))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        func color(_ x: Int, _ y: Int) throws -> NSColor {
            let point = anchor == .bottom ? (y, x) : (x, y)
            return try #require(bitmap.colorAt(x: point.0 * bitmap.pixelsWide / 400,
                                               y: point.1 * bitmap.pixelsHigh / 400)?.usingColorSpace(.deviceRGB))
        }
        let gap = try color(200, 202)
        for point in [(1, 198), (1, 207)] {
            let corner = try color(point.0, point.1)
            #expect(abs(corner.redComponent - gap.redComponent) < 0.02)
        }
        let panel = try color(200, 250)
        #expect(abs(panel.redComponent - gap.redComponent) > 0.02)
    }

    @Test(arguments: [ColorScheme.dark, .light], [
        (WorkbenchFeatureModel.ToolWindow.gitLog, DockGroup.primary), (.gitLog, .secondary),
        (.terminal, .primary), (.terminal, .secondary)
    ])
    func dropPreviewStaysAboveRetainedPane(scheme: ColorScheme,
                                          target: (WorkbenchFeatureModel.ToolWindow, DockGroup)) async throws {
        let (tool, group) = target
        let state = DockPreviewState()
        let store = WorkbenchToolContentStore()
        let host = NSHostingView(rootView: DockPreviewFixture(state: state, store: store, tool: tool, group: group)
            .environment(\.colorScheme, scheme))
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 360),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        func snapshot() throws -> NSBitmapImageRep {
            host.layoutSubtreeIfNeeded()
            let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
            return image
        }
        func pixels(_ image: NSBitmapImageRep, in rect: CGRect) throws -> [NSColor] {
            let scale = CGFloat(image.pixelsWide) / host.bounds.width
            return try (Int(rect.minY * scale)..<Int(rect.maxY * scale)).flatMap { y in
                try (Int(rect.minX * scale)..<Int(rect.maxX * scale)).map { x in
                    try #require(image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                }
            }
        }
        let targetX: CGFloat = group == .primary ? 30 : 230
        let tint = CGRect(x: targetX + 12, y: 52, width: 8, height: 8)
        let label = CGRect(x: targetX + 10, y: 150, width: 180, height: 40)
        let outside = CGRect(x: group == .primary ? 242 : 42, y: 52, width: 8, height: 8)
        // Reference: the same feedback over the original SwiftUI pane, with no native overlay.
        let plain = try snapshot()
        state.preview = true
        let reference = try snapshot()
        #expect(try !pixels(reference, in: tint).elementsEqual(pixels(plain, in: tint)))
        #expect(try !pixels(reference, in: label).elementsEqual(pixels(plain, in: label)))
        state.retained = true
        _ = try snapshot()
        await Task.yield()
        let actual = try snapshot()
        #expect(try pixels(actual, in: tint).elementsEqual(pixels(reference, in: tint)),
                "Drop area highlight must be above the opaque retained pane")
        #expect(try pixels(actual, in: label).elementsEqual(pixels(reference, in: label)),
                "Position label must be visible above Git Log and Terminal")
        #expect(try pixels(actual, in: outside).elementsEqual(pixels(plain, in: outside)),
                "The preview must stay in workspace coordinates, outside activity bars and padding")
        let entry = try #require(store.entries[tool])
        let center = entry.host.convert(CGPoint(x: entry.host.bounds.midX, y: entry.host.bounds.midY), to: host.superview)
        let previewHit = host.hitTest(center)
        #expect(previewHit?.isDescendant(of: entry.host) == true, "Preview must pass mouse events to retained content")
        state.preview = false
        let cleared = try snapshot()
        #expect(try pixels(cleared, in: tint).elementsEqual(pixels(plain, in: tint)))
        #expect(host.hitTest(center) === previewHit)
        #expect(store.entries[tool]?.host === entry.host, "Preview updates must preserve retained controls")
    }

    @Test func movingVisibleToolPreservesOtherGroupsAndReplacesDestination() {
        let model = WorkbenchFeatureModel()
        model.setVisibility(.terminal, isVisible: true)
        model.setVisibility(.agent, isVisible: true)
        model.move(.agent, to: .init(anchor: .left, group: .primary))
        #expect(model.isVisible(.agent))
        #expect(!model.isVisible(.project))
        #expect(model.isVisible(.terminal))
        #expect(model.activeRightToolWindow == nil)
        model.move(.project, to: .init(anchor: .left, group: .secondary))
        model.setSelectedSidebar(.project)
        #expect(model.isVisible(.project))
        #expect(model.isVisible(.agent))
        model.setVisibility(.project, isVisible: false)
        #expect(model.isVisible(.agent))
    }

    @Test func movingClosedToolAndReorderingDoNotOpenIt() {
        let model = WorkbenchFeatureModel()
        let position = DockPosition(anchor: .right, group: .secondary)
        model.move(.terminal, to: position)
        model.move(.gitLog, to: position, before: .terminal)
        #expect(model.tools(in: position) == [.gitLog, .terminal])
        #expect(!model.isVisible(.terminal))
        model.move(.terminal, to: position, before: .gitLog)
        #expect(model.tools(in: position) == [.terminal, .gitLog])
        let before = model.toolWindowStates
        model.move(.terminal, to: position, before: .terminal)
        #expect(model.toolWindowStates == before)
    }

    @Test func restoringLayoutKeepsAgentClosedUntilExplicitlyOpened() {
        let persistence = WorkbenchLayoutStore(store: DockingTestStore())
        let workspace = URL(fileURLWithPath: "/fixture/docking/agent")
        let model = WorkbenchFeatureModel(layoutStore: persistence)
        model.setVisibility(.agent, isVisible: true)
        model.saveLayout(.init(sidebarWidth: 310, topPaneHeight: nil), for: workspace)
        let restored = WorkbenchFeatureModel(layoutStore: persistence)
        _ = restored.loadLayout(for: workspace)
        #expect(!restored.isVisible(.agent))
        restored.setVisibility(.agent, isVisible: true)
        #expect(restored.isVisible(.agent))
    }

    @Test func layoutRoundTripRestoresPositionsOrderVisibilityAndGroupSizes() {
        let store = DockingTestStore()
        let persistence = WorkbenchLayoutStore(store: store)
        let workspace = URL(fileURLWithPath: "/fixture/docking/project")
        let model = WorkbenchFeatureModel(layoutStore: persistence)
        _ = model.loadLayout(for: workspace)
        let position = DockPosition(anchor: .right, group: .secondary)
        model.move(.project, to: position)
        model.move(.terminal, to: position, before: .project)
        model.setVisibility(.terminal, isVisible: true)
        model.setGroupFraction(0.7, for: .right)
        model.saveLayout(.init(sidebarWidth: 310, topPaneHeight: 280, mavenPaneWidth: 390), for: workspace)
        let restored = WorkbenchFeatureModel(layoutStore: persistence)
        let layout = restored.loadLayout(for: workspace)
        #expect(restored.tools(in: position) == [.terminal, .project])
        #expect(restored.isVisible(.terminal))
        #expect(!restored.isVisible(.project))
        #expect(restored.groupFractions["right"] == 0.7)
        #expect(layout.sidebarWidth == 310)
        #expect(layout.mavenPaneWidth == 390)
        _ = restored.loadLayout(for: URL(fileURLWithPath: "/fixture/docking/other"))
        #expect(restored.state(for: .project).position.anchor == .left)
        #expect(restored.isVisible(.project))
    }

    @Test(arguments: [0.0375, 0.95625])
    func narrowGroupFractionSurvivesCommitAndReload(fraction: Double) {
        let store = DockingTestStore()
        let persistence = WorkbenchLayoutStore(store: store)
        let workspace = URL(fileURLWithPath: "/fixture/docking/narrow")
        let model = WorkbenchFeatureModel(layoutStore: persistence)
        model.setGroupFraction(fraction, for: .left)
        #expect(model.groupFractions["left"] == fraction)
        model.saveLayout(.init(sidebarWidth: 310, topPaneHeight: 280), for: workspace)
        let restored = WorkbenchFeatureModel(layoutStore: persistence)
        _ = restored.loadLayout(for: workspace)
        #expect(restored.groupFractions["left"] == fraction)
    }

    @Test func legacyLayoutAndUnknownOrDuplicateRecordsAreSafe() throws {
        let store = DockingTestStore()
        let persistence = WorkbenchLayoutStore(store: store)
        let workspace = URL(fileURLWithPath: "/fixture/docking/legacy")
        store.set(Data(#"{"sidebarWidth":310,"topPaneHeight":280}"#.utf8), forKey: "lithe.workbench-layout." + workspace.path)
        let model = WorkbenchFeatureModel(layoutStore: persistence)
        #expect(model.loadLayout(for: workspace).sidebarWidth == 310)
        #expect(model.isVisible(.project))
        var layout = WorkbenchLayout(sidebarWidth: 310, topPaneHeight: 280)
        let position = DockPosition(anchor: .left, group: .secondary)
        layout.toolWindows = [
            .init(id: "removed-plugin", position: position, order: 0, isVisible: true),
            .init(id: "terminal", position: position, order: -10, isVisible: true),
            .init(id: "terminal", position: .init(anchor: .right, group: .primary), order: 2, isVisible: true),
            .init(id: "gitLog", position: position, order: 1, isVisible: true)
        ]
        layout.groupFractions = ["right": 42, "left": 0.6, "unknown": 0.5]
        persistence.save(layout, for: workspace)
        _ = model.loadLayout(for: workspace)
        #expect(model.tools(in: position) == [.terminal, .gitLog])
        #expect(model.isVisible(.terminal))
        #expect(!model.isVisible(.gitLog))
        #expect(model.groupFractions == ["left": 0.6])
    }

    @Test func nativeDragSourceHasAHitAreaAndReceivesWindowClicks() throws {
        let drag = ToolWindowDragState()
        var clicks = 0
        let host = NSHostingView(rootView: Button("Terminal") {}.frame(width: 37, height: 40)
            .overlay(ToolWindowDragSource(tool: .terminal, position: .init(anchor: .bottom, group: .primary), drag: drag, image: { nil }, click: { clicks += 1 }, commit: { _, _ in })))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 37, height: 40),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        func source(in view: NSView) -> ToolWindowDragSource.SourceView? {
            if let source = view as? ToolWindowDragSource.SourceView { return source }
            return view.subviews.lazy.compactMap { source(in: $0) }.first
        }
        let native = try #require(source(in: host))
        #expect(native.bounds.width >= 30)
        #expect(native.bounds.height >= 30)
        // Drag capture must not take hover/help hit testing away from the painted button.
        #expect(native.hitTest(NSPoint(x: native.bounds.midX, y: native.bounds.midY)) == nil)
        let point = native.convert(NSPoint(x: native.bounds.midX, y: native.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            NSApp.sendEvent(event)
        }
        #expect(clicks == 1)
        // A replacement entry can receive the release of a press made before it was mounted.
        native.mouseUp(with: try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point,
            modifierFlags: [], timestamp: 2, windowNumber: window.windowNumber, context: nil,
            eventNumber: 2, clickCount: 1, pressure: 0)))
        #expect(clicks == 1)
        native.isEnabled = false
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: 3, windowNumber: window.windowNumber, context: nil, eventNumber: 3, clickCount: 1, pressure: 1)))
        }
        #expect(clicks == 1)
    }

    @Test(arguments: [ColorScheme.dark, .light])
    func nativeWindowDragCommitsOnlyOnReleaseAndClosesItsPreview(scheme: ColorScheme) throws {
        let drag = ToolWindowDragState()
        let model = WorkbenchFeatureModel()
        model.setVisibility(.terminal, isVisible: true)
        let original = model.toolWindowStates
        let host = NSHostingView(rootView: Button {} label: {
            Rectangle().fill(Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1)).frame(width: 20, height: 20)
        }.buttonStyle(LitheActivityBarButtonStyle(isSelected: true))
            .overlay(ToolWindowDragSource(tool: .terminal, position: .init(anchor: .bottom, group: .primary),
                drag: drag, image: {
                    ImageRenderer(content: Rectangle().fill(Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1))
                        .frame(width: 20, height: 20).modifier(LitheToolWindowDragButtonStyle())
                        .environment(\.colorScheme, scheme)).nsImage
                }, click: {}, commit: { model.move($0, to: $1.position, before: $1.before) })))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        drag.workspaceFrame = NSRect(x: 0, y: 0, width: 600, height: 600)
        func source(in view: NSView) -> ToolWindowDragSource.SourceView? {
            if let source = view as? ToolWindowDragSource.SourceView { return source }
            return view.subviews.lazy.compactMap { source(in: $0) }.first
        }
        let native = try #require(source(in: host))
        let start = native.convert(NSPoint(x: native.bounds.midX, y: native.bounds.midY), to: nil)
        func send(_ type: NSEvent.EventType, _ point: NSPoint, _ index: Int) throws {
            NSApp.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: Double(index), windowNumber: window.windowNumber, context: nil, eventNumber: index,
                clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)))
        }
        let panels = NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.nonactivatingPanel) }.count
        try send(.leftMouseDown, start, 0)
        try send(.leftMouseDragged, NSPoint(x: start.x + 15, y: start.y), 1)
        try send(.leftMouseDragged, NSPoint(x: 500, y: 300), 2)
        #expect(drag.source == .terminal)
        // Check the actual floating image, including its normal surface and transparent corners.
        let preview = try #require(NSApp.windows.first { $0.identifier?.rawValue == "lithe.tool-window-drag-preview" && $0.isVisible })
        let image = try #require((preview.contentView as? NSImageView)?.image)
        let tiff = try #require(image.tiffRepresentation)
        let pixels = try #require(NSBitmapImageRep(data: tiff))
        let center = try #require(pixels.colorAt(x: pixels.pixelsWide / 2, y: pixels.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        #expect(center.alphaComponent > 0.9)
        // A selected source must not carry its blue background into the floating glyph.
        let corner = try #require(pixels.colorAt(x: 0, y: 0))
        #expect(corner.alphaComponent < 0.01)
        let background = try #require(pixels.colorAt(x: 2 * pixels.pixelsWide / 30, y: pixels.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        #expect(background.alphaComponent > 0.9)
        // Compare the same color through ImageRenderer so display-profile conversion is identical.
        let referenceImage = try #require(ImageRenderer(content: Rectangle()
            .fill(LitheTheme.toolWindowFloatingButtonBackground(for: scheme)).frame(width: 30, height: 30)).nsImage)
        let referenceTIFF = try #require(referenceImage.tiffRepresentation)
        let referencePixels = try #require(NSBitmapImageRep(data: referenceTIFF))
        let expected = try #require(referencePixels.colorAt(x: referencePixels.pixelsWide / 2,
            y: referencePixels.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        #expect(abs(background.redComponent - expected.redComponent) < 0.01)
        #expect(abs(background.greenComponent - expected.greenComponent) < 0.01)
        #expect(abs(background.blueComponent - expected.blueComponent) < 0.01)
        #expect(center.redComponent > center.greenComponent + 0.5)
        #expect(center.redComponent > center.blueComponent + 0.5)
        #expect(model.toolWindowStates == original)
        #expect(NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.nonactivatingPanel) }.count == panels + 1)
        try send(.leftMouseUp, NSPoint(x: 500, y: 300), 3)
        #expect(model.state(for: .terminal).position == DockPosition(anchor: .right, group: .secondary))
        #expect(model.isVisible(.terminal))
        #expect(drag.source == nil)
        #expect(NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.nonactivatingPanel) }.count == panels)
        let committed = model.toolWindowStates
        try send(.leftMouseDown, start, 4)
        try send(.leftMouseDragged, NSPoint(x: 100, y: 100), 5)
        NSApp.sendEvent(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 6, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)))
        #expect(drag.source == nil)
        try send(.leftMouseDragged, NSPoint(x: 100, y: 110), 7)
        try send(.leftMouseUp, NSPoint(x: 100, y: 110), 8)
        #expect(model.toolWindowStates == committed)
        #expect(NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.nonactivatingPanel) }.count == panels)
    }

    @Test func dropGeometryRejectsCenterAndOffWindowAndFindsFreshStripeFrames() {
        let drag = ToolWindowDragState()
        drag.workspaceFrame = NSRect(x: 40, y: 20, width: 600, height: 600)
        drag.sideWidths = [.left: 120, .right: 120]
        #expect(drag.target(at: NSPoint(x: 340, y: 450)) == nil)
        #expect(drag.target(at: NSPoint(x: 800, y: 450)) == nil)
        #expect(drag.target(at: NSPoint(x: 100, y: 500))?.position == DockPosition(anchor: .left, group: .primary))
        #expect(drag.target(at: NSPoint(x: 600, y: 300))?.position == DockPosition(anchor: .right, group: .secondary))
        #expect(drag.target(at: NSPoint(x: 400, y: 100))?.position == DockPosition(anchor: .bottom, group: .secondary))
        var frame = NSRect(x: 0, y: 100, width: 37, height: 40)
        drag.entries[.project] = ({ frame }, .init(anchor: .left, group: .primary), ObjectIdentifier(drag))
        #expect(drag.target(at: NSPoint(x: 20, y: 120))?.before == .project)
        frame.origin.y = 200
        #expect(drag.target(at: NSPoint(x: 20, y: 220))?.before == .project)
        #expect(drag.target(at: NSPoint(x: 20, y: 120))?.before == nil)
        drag.begin(.terminal)
        frame.origin.y = 300
        // Source compaction changes live button frames; old slots must not remain targets.
        #expect(drag.target(at: NSPoint(x: 20, y: 220))?.before == nil)
        #expect(drag.target(at: NSPoint(x: 20, y: 320))?.before == .project)
        drag.finish()
        #expect(drag.target(at: NSPoint(x: 20, y: 320))?.before == .project)
    }

    @Test func horizontalDragUsesTheBottomPanelHeightAndActualSplitBounds() throws {
        let drag = ToolWindowDragState()
        let bottom = DockPosition(anchor: .bottom, group: .primary)
        let left = DockPosition(anchor: .left, group: .primary)
        let owner = ObjectIdentifier(drag)
        drag.workspaceFrame = CGRect(x: 40, y: 20, width: 1200, height: 800)
        drag.regions[.editor] = (CGRect(x: 280, y: 496, width: 960, height: 324), owner)
        drag.regions[.pane(left)] = (CGRect(x: 40, y: 496, width: 235, height: 324), owner)
        let panel = CGRect(x: 40, y: 20, width: 1200, height: 470)
        drag.regions[.pane(bottom)] = (panel, owner)
        drag.entries[.gitLog] = ({ CGRect(x: 0, y: 250, width: 37, height: 40) }, bottom, owner)
        drag.begin(.gitLog)
        let destination = try #require(drag.target(at: CGPoint(x: 200, y: 270)))
        #expect(destination.position == bottom)
        #expect(drag.previewFrame(for: destination) == CGRect(x: 40, y: 20, width: 600, height: 470))
        let leftTarget = try #require(drag.target(at: CGPoint(x: 100, y: 760)))
        #expect(leftTarget.position == left)
        #expect(drag.previewFrame(for: leftTarget).maxY == 820)
        #expect(drag.target(at: CGPoint(x: 800, y: 700)) == nil)
        drag.finish()
        drag.regions[.pane(bottom)] = (CGRect(x: 40, y: 20, width: 1200, height: 300), owner)
        drag.begin(.gitLog)
        #expect(drag.previewFrame(for: destination).height == 300)
        drag.finish()
        let secondary = DockPosition(anchor: .bottom, group: .secondary)
        drag.regions[.pane(bottom)] = (CGRect(x: 40, y: 20, width: 780, height: 470), owner)
        drag.regions[.pane(secondary)] = (CGRect(x: 826, y: 20, width: 414, height: 470), owner)
        drag.begin(.gitLog)
        let right = try #require(drag.target(at: CGPoint(x: 900, y: 270)))
        #expect(right.position == secondary)
        #expect(drag.previewFrame(for: right) == CGRect(x: 826, y: 20, width: 414, height: 470))
        drag.finish()
    }

    @Test func horizontalContentDragProjectsInsertionOrderInsteadOfAppending() throws {
        let drag = ToolWindowDragState()
        let bottom = DockPosition(anchor: .bottom, group: .primary)
        let owner = ObjectIdentifier(drag)
        drag.workspaceFrame = CGRect(x: 40, y: 0, width: 1200, height: 800)
        drag.regions[.pane(bottom)] = (CGRect(x: 40, y: 0, width: 1200, height: 420), owner)
        for (tool, y) in [(WorkbenchFeatureModel.ToolWindow.run, 300), (.terminal, 260), (.gitLog, 220), (.debug, 180)] {
            drag.entries[tool] = ({ CGRect(x: 0, y: y, width: 37, height: 40) }, bottom, owner)
        }
        drag.begin(.terminal)
        defer { drag.finish() }
        // Same Y, outside the stripe: preserve the middle slot, not the group tail.
        let middle = try #require(drag.target(at: CGPoint(x: 240, y: 280)))
        #expect(middle == .init(position: bottom, before: .gitLog))
        drag.target = middle
        drag.entries[.terminal] = ({ .zero }, bottom, owner)
        drag.regions[.insertion] = (CGRect(x: 0, y: 260, width: 37, height: 40), owner)
        #expect(drag.target(at: CGPoint(x: 480, y: 280)) == middle)
        // Moving along the stripe changes order at button midpoints, even over content.
        #expect(drag.target(at: CGPoint(x: 240, y: 350))?.before == .run)
        #expect(drag.target(at: CGPoint(x: 240, y: 225))?.before == .debug)
        #expect(drag.target(at: CGPoint(x: 240, y: 170))?.before == nil)
        #expect(drag.target(at: CGPoint(x: 20, y: 225))?.before == .debug)
    }

    @Test func insertionSlotRetainsItsTargetWhileButtonsReflow() {
        let drag = ToolWindowDragState()
        let position = DockPosition(anchor: .bottom, group: .primary)
        drag.begin(.terminal)
        drag.target = .init(position: position, before: .gitLog)
        drag.regions[.insertion] = (CGRect(x: 0, y: 80, width: 37, height: 40), ObjectIdentifier(drag))
        drag.entries[.gitLog] = ({ CGRect(x: 0, y: 40, width: 37, height: 40) }, position, ObjectIdentifier(drag))
        #expect(drag.target(at: CGPoint(x: 20, y: 100)) == drag.target)
        drag.finish()
    }

    @Test func draggedStripeEntryClosesItsSlotWithoutUnmountingTheMouseOwner() async throws {
        let drag = ToolWindowDragState()
        let host = NSHostingView(rootView: DockingStripeFixture(drag: drag))
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close(); drag.finish() }
        func layout() { host.layoutSubtreeIfNeeded() }
        layout()
        let before = try #require(drag.entries[.gitLog]?.frame())
        let owner = try #require(drag.entries[.terminal]?.owner)
        drag.begin(.terminal)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while drag.entries[.gitLog]?.frame() == before && clock.now < deadline {
            await Task.yield(); layout()
        }
        let after = try #require(drag.entries[.gitLog]?.frame())
        #expect(abs(after.midY - before.midY) == ActivityBarMetrics.slotHeight)
        #expect(drag.entries[.terminal]?.owner == owner)
        #expect(drag.source == .terminal)
        drag.finish()
        let restoreDeadline = clock.now.advanced(by: .seconds(2))
        while drag.entries[.gitLog]?.frame() != before && clock.now < restoreDeadline {
            await Task.yield(); layout()
        }
        #expect(drag.entries[.gitLog]?.frame() == before)
    }

    @Test func dismantlingOldEntryDoesNotUnregisterItsReplacement() {
        let drag = ToolWindowDragState()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        let old = ToolWindowDragSource.SourceView(frame: NSRect(x: 0, y: 0, width: 37, height: 40))
        let replacement = ToolWindowDragSource.SourceView(frame: NSRect(x: 0, y: 50, width: 37, height: 40))
        for view in [old, replacement] {
            view.tool = .terminal; view.position = .init(anchor: .left, group: .secondary); view.drag = drag
            host.addSubview(view); view.record()
        }
        old.dismantle()
        #expect(drag.target(at: NSPoint(x: 20, y: 70))?.before == .terminal)
        replacement.dismantle()
        #expect(drag.target(at: NSPoint(x: 20, y: 70)) == nil)
    }

    /// Only tools whose renderer opens an editor tab treat the free center band
    /// as a destination; dock bands keep winning near the edges.
    @Test func editorCenterBandAcceptsOnlyEditorCapableTools() {
        let drag = ToolWindowDragState()
        drag.workspaceFrame = NSRect(x: 40, y: 20, width: 600, height: 600)
        drag.sideWidths = [.left: 120, .right: 120]
        drag.editorTools = [.agent]
        drag.begin(.terminal)
        #expect(!drag.isEditorTarget(at: NSPoint(x: 340, y: 450)))
        drag.finish()
        drag.begin(.agent)
        #expect(drag.isEditorTarget(at: NSPoint(x: 340, y: 450)))
        #expect(!drag.isEditorTarget(at: NSPoint(x: 100, y: 450)))
        #expect(!drag.isEditorTarget(at: NSPoint(x: 340, y: 100)))
        #expect(!drag.isEditorTarget(at: NSPoint(x: 800, y: 450)))
        drag.targetsEditor = true
        drag.finish()
        #expect(!drag.targetsEditor)
        #expect(!drag.isEditorTarget(at: NSPoint(x: 340, y: 450)))
    }

    @Test func releasingOverTheEditorOpensTheToolInsteadOfMovingIt() throws {
        let drag = ToolWindowDragState()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = try #require(window.contentView)
        let source = ToolWindowDragSource.SourceView(frame: NSRect(x: 560, y: 500, width: 37, height: 40))
        defer { source.dismantle(); window.contentView = nil; window.close() }
        drag.workspaceFrame = root.bounds
        drag.sideWidths = [.left: 120, .right: 120]
        source.tool = .agent; source.position = .init(anchor: .right, group: .primary); source.drag = drag
        source.image = { NSImage(size: NSSize(width: 20, height: 20)) }
        var opened = 0, moved = 0
        source.openInEditor = { opened += 1 }
        source.commit = { _, _ in moved += 1 }
        root.addSubview(source); source.record()
        #expect(drag.editorTools.contains(.agent))
        func event(_ type: NSEvent.EventType, _ point: NSPoint, _ time: TimeInterval) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: time,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        source.mouseDown(with: try event(.leftMouseDown, NSPoint(x: 578, y: 520), 1))
        source.mouseDragged(with: try event(.leftMouseDragged, NSPoint(x: 300, y: 400), 2))
        #expect(drag.targetsEditor)
        source.mouseUp(with: try event(.leftMouseUp, NSPoint(x: 300, y: 400), 3))
        #expect(opened == 1)
        #expect(moved == 0)
        #expect(drag.source == nil && !drag.targetsEditor)
    }

    @Test func cancellingDragLeavesLayoutUnchangedAndClearsPreview() {
        let model = WorkbenchFeatureModel()
        let original = model.toolWindowStates
        let drag = ToolWindowDragState()
        drag.source = .terminal
        drag.target = .init(position: .init(anchor: .right, group: .secondary), before: nil)
        drag.finish()
        #expect(drag.source == nil)
        #expect(drag.target == nil)
        #expect(model.toolWindowStates == original)
    }
}

private final class DockingTestStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

private struct DockingStripeFixture: View {
    @ObservedObject var drag: ToolWindowDragState
    var body: some View {
        VStack(spacing: 0) {
            ForEach([WorkbenchFeatureModel.ToolWindow.terminal, .gitLog], id: \.self) { tool in
                Button {} label: { Color.clear.frame(width: 20, height: 20) }
                    .buttonStyle(LitheActivityBarButtonStyle(isDragging: drag.source == tool))
                    .overlay(ToolWindowDragSource(tool: tool, position: .init(anchor: .bottom, group: .primary),
                        drag: drag, image: { nil }, click: {}, commit: { _, _ in }))
            }
            Spacer(minLength: 0)
        }
    }
}

@MainActor
private final class DockPreviewState: ObservableObject {
    @Published var retained = false
    @Published var preview = false
}

private struct DockPreviewFixture: View {
    @ObservedObject var state: DockPreviewState
    let store: WorkbenchToolContentStore
    let tool: WorkbenchFeatureModel.ToolWindow
    let group: DockGroup

    var body: some View {
        Group {
            if state.retained {
                RetainedWorkbenchToolPane(store: store, tool: tool, content: LitheTheme.editor)
            } else {
                LitheTheme.editor
            }
        }
        .frame(width: 400, height: 260)
        .workbenchToolContentLayers(store: store) {
            if state.preview {
                Rectangle().fill(LitheTheme.toolWindowDropArea)
                    .overlay {
                        Text(group == .primary ? "Move to Bottom Left" : "Move to Bottom Right")
                            .font(LitheTheme.uiFont(size: 12))
                            .padding(8).background(LitheTheme.raised).cornerRadius(6)
                    }
                    .frame(width: 200, height: 260)
                    .position(x: group == .primary ? 100 : 300, y: 130)
            }
        }
        .padding(.leading, 30).padding(.top, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
