import AppKit
import LitheCoreContracts
import SwiftUI
import Testing
@testable import LitheGitModule
@testable import Lithe

@Suite("Diff synchronized viewers", .serialized)
@MainActor
struct DiffScrollSynchronizationTests {
    private func rows() -> [DiffRow] {
        var result = (0..<80).map {
            DiffRow(oldLine: $0 + 1, newLine: $0 + 1, left: "let value = \($0)", right: nil, kind: .context, sequence: $0)
        }
        for i in 0..<3 {
            result.append(DiffRow(oldLine: nil, newLine: 81 + i, left: nil, right: "added\(i)()", kind: .addition, sequence: 80 + i))
        }
        for i in 80..<180 {
            result.append(DiffRow(oldLine: i + 1, newLine: i + 4, left: "let value = \(i)",
                right: i == 84 ? "let value = 184" : nil, kind: i == 84 ? .changed : .context, sequence: i + 3))
        }
        return result
    }

    @Test
    func workingChangesUseNativeSharedPaneForModifiedAddedAndDeletedFiles() async throws {
        let suite = "lithe-working-diff-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacUserDefaultsStore(defaults: defaults)
        let settings = AppSettings(store: store)
        let model = AppModel(settings: settings, services: MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode).services)
        let root = URL(fileURLWithPath: "/workspace")
        let patch = "diff --git a/a.swift b/a.swift\n--- a/a.swift\n+++ b/a.swift\n@@ -1 +1 @@\n-old\n+new\n"
        let feature = GitFeatureModel(service: GitService(operations: DiffToolbarGitOperations(root: root)),
            diffDocumentProvider: { _, _ in DiffParser.parseDocument(patch) })
        defer { feature.reset() }
        for status: Character in ["M", "A", "D"] {
            let change = GitChange(repositoryRoot: root, path: "a.swift", originalPath: nil,
                indexStatus: status == "A" ? "A" : " ", workTreeStatus: status == "A" ? " " : status)
            await feature.selectChange(change)
            let host = NSHostingView(rootView: RepositoryDiffView(feature: feature, change: change,
                onClose: { feature.closeWorkingTreeDiff() }, onOpenFile: {}).environmentObject(model))
            host.frame = NSRect(x: 0, y: 0, width: 1000, height: 300)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            defer { window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded(); await Task.yield(); host.layoutSubtreeIfNeeded()
            let editors = descendants(host).compactMap { $0 as? DiffNativeTextView }
            #expect(editors.count == (status == "M" ? 2 : 1))
            #expect(!descendants(host).compactMap { $0 as? DiffStripeScroller }.isEmpty)
            #expect(editors.contains { $0.column?.lines.isEmpty == false })
        }
        await model.shutdownProjectSession()
    }

    @Test
    func switchingFilesRefreshesMountedStripesWithoutRecreatingThem() {
        let sync = DiffScrollSynchronization()
        let left = DiffStripeScroller(frame: NSRect(x: 0, y: 0, width: 14, height: 200))
        let right = DiffStripeScroller(frame: left.frame)
        let leftScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let rightScroll = NSScrollView(frame: leftScroll.frame)
        sync.leftStripe = left
        sync.rightStripe = right
        sync.attach(leftScroll, side: .left)
        sync.attach(rightScroll, side: .right)
        defer { sync.detach(side: .left); sync.detach(side: .right) }
        let first = rows()
        let second = [DiffRow(oldLine: 1, newLine: nil, left: "removed", right: nil, kind: .removal, sequence: 0)]
        for source in [first, second, []] {
            let layout = DiffSplitLayout.plan(
                displayRows: source.enumerated().map { .row($0.element, index: $0.offset) },
                kinds: source.map(\.kind))
            sync.configure(layout)
            for stripe in [left, right] {
                #expect(stripe.transitions.map(\.kind) == layout.transitions.map(\.kind))
                #expect(stripe.transitions.map(\.leftRange) == layout.transitions.map(\.leftRange))
                #expect(stripe.transitions.map(\.rightRange) == layout.transitions.map(\.rightRange))
            }
            #expect(left.sourceHeight == max(1, layout.leftHeight))
            #expect(right.sourceHeight == max(1, layout.rightHeight))
        }
    }

    @Test
    func boundaryMappingPreservesMatchingLinesAndClampsInsertions() {
        let rows = rows()
        let layout = DiffSplitLayout.plan(displayRows: rows.enumerated().map { .row($0.element, index: $0.offset) }, kinds: rows.map(\.kind))
        let map = DiffScrollMapping(layout: layout)
        #expect(map.transfer(1_700, from: .left) == 1_700)
        #expect(map.transfer(1_780, from: .right) == 1_760)
        #expect(map.transfer(1_826, from: .right) == 1_760)
        #expect(map.transfer(1_850, from: .right) == 1_784)
        #expect(map.transfer(2_000, from: .left) == 2_066)
        #expect(map.transfer(4_000, from: .right) == 3_934)
    }

    @Test
    func nativeClipsSynchronizeFlattenConnectorsAndNavigateFromStripes() async throws {
        let rows = rows()
        let display = rows.enumerated().map { DiffDisplayRow.row($0.element, index: $0.offset) }
        let layout = DiffSplitLayout.plan(displayRows: display, kinds: rows.map(\.kind))
        let hosting = NSHostingView(rootView: ScrollViewReader { _ in
            DiffSplitPaneView(displayRows: display, kinds: rows.map(\.kind), layout: layout,
                fileExtension: "swift", contentWidth: 1_100, viewportWidth: 900,
                header: { _ in AnyView(Color.clear.frame(height: LitheTheme.Diff.titleHeight)) }, onExpand: { _ in })
        })
        hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 250)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        hosting.layoutSubtreeIfNeeded(); await Task.yield(); hosting.layoutSubtreeIfNeeded()
        let stripes = descendants(hosting).compactMap { $0 as? DiffStripeScroller }
        let left = try #require(stripes.first { $0.side == .left })
        let right = try #require(stripes.first { $0.side == .right })
        #expect(left.bounds.height == 250 - LitheTheme.Diff.titleHeight && right.bounds.height == left.bounds.height,
                "Version headers reserve space above the native scroll viewports")
        let sync = try #require(left.synchronization)
        let oldClip = try #require(sync.scrollView(.left)?.contentView)
        let newClip = try #require(sync.scrollView(.right)?.contentView)
        let ribbon = try #require(descendants(hosting).compactMap { $0 as? DiffNativeTransitionsView }.first)
        let editors = descendants(hosting).compactMap { $0 as? DiffNativeTextView }
        #expect(editors.count == 2)
        let revisions = editors.map(\.appliedRevision)
        func checkConnectorCoordinates() throws {
            for side in [DiffSide.left, .right] {
                let editor = try #require(editors.first { $0.accessibilityLabel() == (side == .left ? "Original diff code" : "Modified diff code") })
                let edge = try #require(ribbon.transitions.first { $0.kind == .changed })
                let sourceY = side == .left ? edge.leftRange.lowerBound : edge.rightRange.lowerBound
                let offset = side == .left ? ribbon.leftOffset : ribbon.rightOffset
                let nativeY = ribbon.convert(NSPoint(x: 0, y: sourceY), from: editor).y
                #expect(abs(nativeY - (sourceY - offset)) < 0.5,
                    "Connector must touch the actual code row, including version header layout: native=\(nativeY), ribbon=\(sourceY - offset)")
            }
        }
        try checkConnectorCoordinates()
        sync.scroll(.left, to: 1_650)
        try checkConnectorCoordinates()
        #expect(abs(oldClip.bounds.minY - newClip.bounds.minY) < 0.1)
        sync.scroll(.left, to: 1_700)
        #expect(abs(newClip.bounds.minY - oldClip.bounds.minY - 66) < 0.1)
        let change = try #require(ribbon.transitions.first { $0.kind == .changed })
        #expect(abs(change.leftRange.lowerBound - ribbon.leftOffset
            - (change.rightRange.lowerBound - ribbon.rightOffset)) < 0.1,
            "Matched changes flatten after the insertion passes the one-third viewport anchor")
        #expect(left.knobProportion > 0 && left.knobProportion < 1)
        #expect(left.knobRect.isEmpty, "The left rail retains markers without a duplicate thumb")
        #expect(left.transitions.contains { $0.kind == .addition })
        #expect(right.transitions.contains { $0.kind == .changed })
        sync.scroll(.right, to: 0)
        window.orderFront(nil)
        let knob = right.knobRect
        #expect(!knob.isEmpty)
        let knobPoint = right.convert(NSPoint(x: knob.midX, y: knob.midY), to: nil)
        #expect(hosting.hitTest(hosting.convert(knobPoint, from: nil)) === right)
        for (type, delta) in [(NSEvent.EventType.leftMouseDown, CGFloat(0)), (.leftMouseDragged, 40), (.leftMouseUp, 40)] {
            let event = try #require(NSEvent.mouseEvent(with: type,
                location: NSPoint(x: knobPoint.x, y: knobPoint.y - delta), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1))
            window.sendEvent(event)
        }
        #expect(newClip.bounds.minY > 100, "Dragging the visible thumb must move the native document")
        #expect(oldClip.bounds.minY > 100, "The other source column follows thumb scrolling")
        sync.scroll(.right, to: 0)
        #expect(right.isAccessibilityElement() && right.accessibilityRole() == .scrollBar)
        #expect(right.accessibilityPerformIncrement())
        #expect(newClip.bounds.minY == DiffLayoutMetrics.rowHeight)
        #expect(right.accessibilityPerformDecrement())
        #expect(newClip.bounds.minY == 0)
        let marker = right.markerRect(change)
        let point = NSPoint(x: marker.midX, y: marker.midY)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
            location: right.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        right.mouseDown(with: event)
        #expect(abs(newClip.bounds.minY - (change.rightRange.lowerBound - newClip.bounds.height / 3)) < 0.1)
        #expect(editors.map(\.appliedRevision) == revisions, "Scrolling and stripe clicks never replace prepared text")
        let bitmap = try nativeSRGBCapture(hosting)
        let scale = CGFloat(bitmap.pixelsWide) / hosting.bounds.width
        for (kind, expected) in [(DiffRowKind.addition, LitheTheme.Diff.insertedStripe),
                                 (.changed, LitheTheme.Diff.modifiedStripe)] {
            let transition = try #require(right.transitions.first { $0.kind == kind })
            let rect = right.markerRect(transition)
            let point = hosting.convert(NSPoint(x: rect.minX + 0.5, y: rect.midY), from: right)
            let pixel = try nativeSRGBPixel(bitmap, x: Int(point.x * scale), y: Int(point.y * scale))
            var resolved: NSColor?
            right.effectiveAppearance.performAsCurrentDrawingAppearance {
                resolved = NSColor(expected).usingColorSpace(.sRGB)
            }
            let color = try #require(resolved)
            #expect(abs(pixel.redComponent - color.redComponent) < 0.04
                && abs(pixel.greenComponent - color.greenComponent) < 0.04
                && abs(pixel.blueComponent - color.blueComponent) < 0.04,
                "Native stripe \(kind) must paint its color: pixel=\(pixel), expected=\(color), appearance=\(right.effectiveAppearance)")
        }
        if let directory = ProcessInfo.processInfo.environment["LITHE_DIFF_CAPTURE_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                URL(fileURLWithPath: directory).appendingPathComponent("diff-synchronized.png"))
        }
        window.contentView = nil
        #expect(sync.scrollView(.left) == nil && sync.scrollView(.right) == nil, "Unmounting removes clip observers")
    }

    @Test
    func collapsedDiffHandleKeepsEventsInsideWorkbenchAndCanReopen() async throws {
        let rows = rows()
        let display = rows.enumerated().map { DiffDisplayRow.row($0.element, index: $0.offset) }
        let layout = DiffSplitLayout.plan(displayRows: display, kinds: rows.map(\.kind))
        var outerDrags = 0
        let hosting = NSHostingView(rootView: HStack(spacing: 0) {
            Color(red: 1, green: 0, blue: 0).frame(width: 80)
            SplitHandleView(axis: .horizontal, onDragStarted: { outerDrags += 1 }, onDragChanged: { _ in }, onDragEnded: { _ in })
            DiffSplitPaneView(displayRows: display, kinds: rows.map(\.kind), layout: layout,
                fileExtension: "swift", contentWidth: 1_600, viewportWidth: 900,
                header: { _ in AnyView(Color(red: 1, green: 0, blue: 0).frame(height: 29)) }, onExpand: { _ in }).frame(width: 900)
            SplitHandleView(axis: .horizontal, onDragStarted: { outerDrags += 1 }, onDragChanged: { _ in }, onDragEnded: { _ in })
            Color(red: 1, green: 0, blue: 0).frame(width: 80)
        })
        hosting.frame = NSRect(x: 0, y: 0, width: 1_070, height: 250)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        hosting.layoutSubtreeIfNeeded(); await Task.yield(); hosting.layoutSubtreeIfNeeded()
        let handles = descendants(hosting).compactMap { $0 as? SplitHandleInteractionView }
            .sorted { $0.convert(.zero, to: hosting).x < $1.convert(.zero, to: hosting).x }
        #expect(handles.count == 3)
        let handle = try #require(handles.dropFirst().first)
        let ribbon = try #require(descendants(hosting).compactMap { $0 as? DiffNativeTransitionsView }.first)
        let stripe = try #require(descendants(hosting).compactMap { $0 as? DiffStripeScroller }.first)
        stripe.synchronization?.scroll(.right, to: 1_900)
        let before = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: before)
        let sentinel = try #require(before.colorAt(x: 20, y: 20))
        for target in [CGFloat(-100), 300, 1_000, 450] {
            let origin = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
            #expect(hosting.hitTest(hosting.convert(origin, from: nil)) === handle,
                "At a collapsed edge the actual hit must still belong to Diff, not its adjacent workbench handle")
            let diffOrigin = ribbon.convert(.zero, to: nil).x
            for (type, x) in [(NSEvent.EventType.leftMouseDown, origin.x), (.leftMouseDragged, diffOrigin + target), (.leftMouseUp, diffOrigin + target)] {
                window.sendEvent(try #require(NSEvent.mouseEvent(with: type,
                    location: NSPoint(x: x, y: origin.y), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .leftMouseUp ? 0 : 1)))
            }
            await Task.yield(); hosting.layoutSubtreeIfNeeded()
            #expect(outerDrags == 0)
            let rect = handle.convert(handle.bounds, to: ribbon)
            #expect(rect.minX >= -0.5 && rect.maxX <= 900.5, "The complete native hit surface stays in Diff")
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            if let directory = ProcessInfo.processInfo.environment["LITHE_DIFF_CAPTURE_DIR"] {
                try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                    URL(fileURLWithPath: directory).appendingPathComponent("workbench-edge-\(Int(target)).png"))
            }
            let scale = CGFloat(bitmap.pixelsWide) / hosting.bounds.width
            for point in [NSPoint(x: 90, y: 12), NSPoint(x: 535, y: 12), NSPoint(x: 980, y: 12),
                          NSPoint(x: 50, y: 120), NSPoint(x: 1_020, y: 120)] {
                let pixel = try #require(bitmap.colorAt(x: Int(point.x * scale), y: Int(point.y * scale)))
                #expect(abs(pixel.redComponent - sentinel.redComponent) < 0.01
                    && abs(pixel.greenComponent - sentinel.greenComponent) < 0.01
                    && abs(pixel.blueComponent - sentinel.blueComponent) < 0.01,
                    "Offscreen ribbons and collapsed content cannot paint the title or neighboring sidebar: \(point), \(pixel)")
            }
        }
        let editors = descendants(hosting).compactMap { $0 as? DiffNativeTextView }
        let initialX = editors.map { $0.convert(.zero, to: hosting).x }
        for (type, x) in [(NSEvent.EventType.leftMouseDown, CGFloat(165)), (.leftMouseDragged, 265), (.leftMouseUp, 265)] {
            let point = hosting.convert(NSPoint(x: x, y: 243), to: nil)
            window.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1)))
            await Task.yield(); hosting.layoutSubtreeIfNeeded()
        }
        for (index, editor) in editors.enumerated() {
            #expect(editor.convert(.zero, to: hosting).x < initialX[index] - 10,
                "Dragging the horizontal thumb scrolls both code surfaces")
        }
        #expect(outerDrags == 0)
    }

    @Test
    func unifiedViewerShowsBothSourceVersionsAndSelectsOnlyCode() async throws {
        let rows = [DiffRow(oldLine: nil, newLine: nil, left: "@@ -1,2 +1,2 @@", right: nil, kind: .information, sequence: 0),
                    DiffRow(oldLine: 1, newLine: 1, left: "let unchanged = 0", right: nil, kind: .context, sequence: 1),
                    DiffRow(oldLine: 2, newLine: 2, left: "let value = 1", right: "let value = 2", kind: .changed, sequence: 2)]
        let layout = DiffUnifiedLayout(rows: rows)
        #expect(layout.items.map(\.kind) == [.context, .removal, .addition])
        #expect(layout.items.map(\.isScrollAnchor) == [true, true, false])
        let hosting = NSHostingView(rootView: ScrollViewReader { _ in
            DiffUnifiedPaneView(layout: layout, fileExtension: "swift", contentWidth: 700,
                highlightsWords: true, selectedRowIDs: [])
        })
        hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 250)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        hosting.layoutSubtreeIfNeeded(); await Task.yield(); hosting.layoutSubtreeIfNeeded()
        let editors = descendants(hosting).compactMap { $0 as? DiffNativeTextView }
        #expect(editors.count == 1)
        let editor = try #require(editors.first)
        #expect(editor.string == "let unchanged = 0\nlet value = 1\nlet value = 2\n")
        let column = try #require(editor.column)
        #expect(column.lines.map(\.sourceNumber) == [1, 2, 2])
        #expect(descendants(hosting).compactMap { $0 as? DiffNativeGutterView }.first?.showsBothNumbers == true)
        #expect(column.selectedSource(in: NSRange(location: 0, length: editor.string.utf16.count)) == editor.string)
        #expect(!editor.isEditable && editor.isSelectable)
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        if let directory = ProcessInfo.processInfo.environment["LITHE_DIFF_CAPTURE_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                URL(fileURLWithPath: directory).appendingPathComponent("diff-unified.png"))
        }
    }

    @Test(arguments: [true, false])
    func commitHeadersSwitchBetweenTwoColumnsAndStackedVersions(dark: Bool) async throws {
        let feature = GitFeatureModel(service: GitService(operations: RustGitOperations(core: RustCoreBridge())))
        let context = GitCommitDiffContext(repositoryRoot: FileManager.default.temporaryDirectory,
            commit: GitCommit(hash: "3162dee9", shortHash: "3162dee9", parentHashes: ["8e12be9b"],
                authorName: "Test", authorEmail: "test@example.invalid", date: "", subject: "Test", decorations: ""),
            file: GitCommitFile(status: "M", path: "macos/Sources/Lithe/Views/Workbench/SplitHandleView.swift"))
        let suite = "lithe-diff-header-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacUserDefaultsStore(defaults: defaults)
        let settings = AppSettings(store: store)
        let model = AppModel(settings: settings, services:
            MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode).services)
        do {
            let hosting = NSHostingView(rootView: RepositoryDiffView(feature: feature, context: context, onClose: { model.closeGitCommitDiff() }, onOpenFile: {}, onOpenCommitDiff: { _ in }).environmentObject(model).environment(\.colorScheme, dark ? .dark : .light))
            hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 250)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = hosting
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.orderFront(nil)
            defer { window.contentView = nil; window.close() }
            hosting.layoutSubtreeIfNeeded(); await Task.yield(); hosting.layoutSubtreeIfNeeded()
            func snapshot() throws -> NSBitmapImageRep {
                let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                return bitmap
            }
            func ink(_ bitmap: NSBitmapImageRep, x: Range<Int>, y: Range<Int>) -> Int {
                let scale = CGFloat(bitmap.pixelsWide) / 900
                return x.reduce(0) { count, x in count + y.filter { y in
                    guard let color = bitmap.colorAt(x: Int(CGFloat(x) * scale), y: Int(CGFloat(y) * scale)) else { return false }
                    return dark ? color.redComponent > 0.6 && color.greenComponent > 0.6 && color.blueComponent > 0.6
                                : color.redComponent < 0.4 && color.greenComponent < 0.4 && color.blueComponent < 0.4
                }.count }
            }
            func matches(_ bitmap: NSBitmapImageRep, x: Int, y: Int, rgb: UInt32) throws -> Bool {
                let scale = CGFloat(bitmap.pixelsWide) / 900
                let color = try #require(bitmap.colorAt(x: Int(CGFloat(x) * scale), y: Int(CGFloat(y) * scale)))
                return abs(color.redComponent - CGFloat((rgb >> 16) & 255) / 255) < 0.02
                    && abs(color.greenComponent - CGFloat((rgb >> 8) & 255) / 255) < 0.02
                    && abs(color.blueComponent - CGFloat(rgb & 255) / 255) < 0.02
            }
            let toolbarBottom = Int(LitheTheme.Diff.toolbarHeight + LitheTheme.Diff.toolbarTopInset)
            let titleBottom = toolbarBottom + Int(LitheTheme.Diff.titleHeight)
            let before = try snapshot()
            #expect(try matches(before, x: 0, y: 20, rgb: dark ? 0x191A1C : 0xFFFFFF), "The toolbar leaves editor background at the outer inset")
            #expect(try matches(before, x: 200, y: 20, rgb: dark ? 0x212326 : 0xF7F8F9), "The toolbar paints its own island layer")
            #expect(try matches(before, x: 200, y: titleBottom - 1, rgb: dark ? 0x555555 : 0xD4D4D4), "Version titles use the inherited editor tearline")
            #expect(try matches(before, x: 200, y: titleBottom, rgb: dark ? 0x191A1C : 0xFFFFFF), "The tearline is one point, not a second header border")
            #expect(try matches(before, x: 820, y: 8, rgb: dark ? 0x40434A : 0xD1D3D9), "One parent outline surrounds both viewer buttons")
            #expect(try matches(before, x: 820, y: 9, rgb: dark ? 0x212326 : 0xF7F8F9), "The unselected outline does not paint a second inner stroke")
            let pathPixels = try (100..<400).reduce(0) { count, x in
                count + (try ((toolbarBottom + 6)..<(toolbarBottom + 22)).filter { y in
                    try matches(before, x: x, y: y, rgb: 0x73767C)
                }).count
            }
            #expect(pathPixels > 20, "The path uses ContextHelp/Label.infoForeground, not the generic secondary text palette")
            #expect(ink(before, x: 472..<545, y: (toolbarBottom + 6)..<(toolbarBottom + 22)) > 20, "Current commit is in the right version column")
            let point = hosting.convert(NSPoint(x: 835, y: 22), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: point,
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                window.sendEvent(event)
            }
            await Task.yield(); hosting.layoutSubtreeIfNeeded()
            let after = try snapshot()
            #expect(ink(after, x: 472..<545, y: (toolbarBottom + 6)..<(toolbarBottom + 22)) == 0, "Unified mode clears the right version column")
            #expect(ink(after, x: 22..<95, y: (toolbarBottom + 28)..<(toolbarBottom + 44)) > 20, "Current commit is the second stacked version")
            if let directory = ProcessInfo.processInfo.environment["LITHE_DIFF_CAPTURE_DIR"] {
                let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                    URL(fileURLWithPath: directory).appendingPathComponent(dark ? "diff-toolbar-unified.png" : "diff-toolbar-unified-light.png"))
                try #require(before.representation(using: .png, properties: [:])).write(to:
                    URL(fileURLWithPath: directory).appendingPathComponent(dark ? "diff-toolbar-split.png" : "diff-toolbar-split-light.png"))
            }
        } catch {
            await model.shutdownProjectSession()
            throw error
        }
        await model.shutdownProjectSession()
    }

    @Test
    func commitToolbarRoutesExistingActionsAndFoldsBothViewers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-diff-actions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Toolbar behavior needs stable commit data, not a real Git executable or
        // repository setup whose process deadline can expire on a loaded runner.
        let operations = DiffToolbarGitOperations(root: root)
        let commit = operations.commitValue
        let feature = GitFeatureModel(service: GitService(operations: operations))
        defer { feature.reset() }
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false }, notify: { _ in }, onStateRefreshed: {})
        await feature.refreshGit()
        await feature.selectGitCommit(commit)
        let files = feature.selectedGitCommitFiles
        try #require(files.count == 2)
        await feature.showGitCommitDiff(for: files[0])
        var context = try #require(feature.selectedGitCommitDiffContext)
        try #require(feature.diffRows.count > 30)
        var openedFile = false
        var requestedFile: GitCommitFile?
        let suite = "lithe-diff-actions-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacUserDefaultsStore(defaults: defaults)
        let settings = AppSettings(store: store)
        let model = AppModel(settings: settings, services: MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode).services)
        func content() -> AnyView {
            AnyView(RepositoryDiffView(feature: feature, context: context, onClose: { model.closeGitCommitDiff() },
                onOpenFile: { openedFile = true }, onOpenCommitDiff: { requestedFile = $0 }).environmentObject(model))
        }
        let host = NSHostingView(rootView: content())
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 280)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        do {
            host.layoutSubtreeIfNeeded(); await Task.yield(); host.layoutSubtreeIfNeeded()
            func press(x: CGFloat) throws {
                let point = host.convert(NSPoint(x: x, y: 22), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                        timestamp: 0, windowNumber: window.windowNumber, context: nil,
                        eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                    window.sendEvent(event)
                }
            }
            // Real pointer events hit the shared 22pt toolbar slots. At the
            // first file Previous must not invoke navigation; Next requests b.
            try press(x: 123)
            #expect(requestedFile == nil)
            try press(x: 86)
            #expect(openedFile)
            try press(x: 191)
            #expect(requestedFile?.id == files[1].id)
            let originalCount = descendants(host).compactMap { $0 as? DiffNativeTextView }.first?.column?.lines.count
            try press(x: 231)
            await Task.yield(); host.layoutSubtreeIfNeeded()
            let folded = try #require(descendants(host).compactMap { $0 as? DiffNativeTextView }.first?.column)
            #expect(folded.lines.count < (originalCount ?? 0))
            #expect(folded.lines.contains { if case .collapsed = $0.item.displayRow { return true }; return false })
            try press(x: 835)
            await Task.yield(); host.layoutSubtreeIfNeeded()
            let unified = try #require(descendants(host).compactMap { $0 as? DiffNativeTextView }.first?.column)
            #expect(unified.lines.contains { if case .collapsed = $0.item.displayRow { return true }; return false })
            try press(x: 231)
            await Task.yield(); host.layoutSubtreeIfNeeded()
            #expect(!unified.lines.contains { if case .collapsed = $0.item.displayRow { return true }; return false })
            await feature.showGitCommitDiff(for: try #require(requestedFile))
            context = try #require(feature.selectedGitCommitDiffContext)
            host.rootView = content()
            await Task.yield(); host.layoutSubtreeIfNeeded()
            requestedFile = nil
            try press(x: 191)
            #expect(requestedFile == nil, "Next is disabled at the final file")
            try press(x: 123)
            #expect(requestedFile?.id == files[0].id)
        } catch {
            await model.shutdownProjectSession()
            throw error
        }
        await model.shutdownProjectSession()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHE_VERIFY_IDEA_RESOURCES"] == "1"))
    func bundledToolbarAssetsResolveWithAndWithoutSVGExtension() throws {
        for path in ["expui/general/up", "expui/general/down", "expui/general/locked",
                     "expui/general/settings", "expui/general/edit", "expui/general/left",
                     "expui/general/right", "expui/general/collapseAll", "expui/diff/sideBySide", "expui/diff/unified"] {
            #expect(try #require(LitheIcons.ideaImage(resourcePath: path)).size ==
                    #require(LitheIcons.ideaImage(resourcePath: path + ".svg")).size)
            #expect(LitheIcons.ideaImage(resourcePath: LitheIcons.darkIdeaAssetPath(for: path)) != nil)
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
}

/// Supplies the same two modified files and foldable context through the normal
/// service boundary, leaving native rendering and feature actions under test.
private struct DiffToolbarGitOperations: GitOperations {
    let root: URL
    let commitValue = GitCommit(hash: "aaaaaaaa", shortHash: "aaaaaaaa", parentHashes: ["bbbbbbbb"],
        authorName: "Test", authorEmail: "test@example.invalid", date: "", subject: "change", decorations: "")
    let filesValue = [GitCommitFile(status: "M", path: "a.swift"), GitCommitFile(status: "M", path: "b.swift")]

    func snapshot(at rootURL: URL) -> GitSnapshot? {
        rootURL == root ? GitSnapshot(repositoryRoot: root, branch: "fixture", changes: []) : nil
    }
    func files(in commit: GitCommit, at rootURL: URL) -> [GitCommitFile]? {
        rootURL == root && commit.hash == commitValue.hash ? filesValue : nil
    }
    func commitDiffDocument(at rootURL: URL, commit: String, pathspecs: [String], whitespace: GitDiffWhitespaceMode) -> DiffDocument? {
        guard rootURL == root, commit == commitValue.hash,
              pathspecs.count == 1, filesValue.contains(where: { $0.path == pathspecs[0] }) else { return nil }
        var rows = (1...40).map {
            DiffRow(oldLine: $0, newLine: $0, left: "let value\($0) = \($0)", right: nil, kind: .context, sequence: $0 - 1)
        }
        rows.append(DiffRow(oldLine: nil, newLine: 41, left: nil, right: "added()", kind: .addition, sequence: 40))
        return DiffDocument(rows: rows, hunks: [])
    }
    func run(arguments: [String], workingDirectory: String, input: String?) -> GitProcessResult {
        Issue.record("The Diff toolbar fixture must not execute Git commands")
        return GitProcessResult(output: "Unexpected fixture command", exitCode: 1)
    }
    func watchContext(at rootURL: URL) -> GitWatchContext? { nil }
    func worktrees(at rootURL: URL) -> [GitWorktree]? { [] }
    func diffDocument(at rootURL: URL, pathspecs: [String], staged: Bool, untracked: Bool, whitespace: GitDiffWhitespaceMode) -> DiffDocument? { nil }
    func diffPatch(at rootURL: URL, pathspecs: [String], staged: Bool, untracked: Bool, whitespace: GitDiffWhitespaceMode) -> String? { nil }
    func comparisonDiffDocument(at rootURL: URL, reference: String, pathspecs: [String], whitespace: GitDiffWhitespaceMode) -> DiffDocument? { nil }
    func comparisonDiffDocument(at rootURL: URL, reference: GitReference, targetReference: GitReference?, pathspecs: [String], whitespace: GitDiffWhitespaceMode) -> DiffDocument? { nil }
    func applyPatch(_ patch: String, at rootURL: URL, mode: String) -> GitProcessResult? { nil }
    func history(at rootURL: URL, reference: GitReference?, limit: Int) -> GitHistorySnapshot? { nil }
    func commit(at rootURL: URL, hash: String) -> GitCommit? { nil }
    func comparison(for reference: GitReference, at rootURL: URL) -> GitBranchComparison? { nil }
    func comparison(from reference: GitReference, to target: GitReference, at rootURL: URL) -> GitBranchComparison? { nil }
    func stashes(at rootURL: URL) -> [GitStash]? { [] }
    func blame(at rootURL: URL, relativePath: String) -> [GitBlameLine]? { nil }
    func stage(_ change: GitChange) -> GitProcessResult? { nil }
    func unstage(_ change: GitChange) -> GitProcessResult? { nil }
    func discard(_ change: GitChange) -> GitProcessResult? { nil }
    func discardAll(_ change: GitChange) -> GitProcessResult? { nil }
    func commit(at rootURL: URL, message: String, amend: Bool) -> GitProcessResult? { nil }
    func cherryPick(_ hash: String, at rootURL: URL) -> GitProcessResult? { nil }
    func revert(_ hash: String, at rootURL: URL) -> GitProcessResult? { nil }
    func resetCurrentBranch(to hash: String, mode: String, at rootURL: URL) -> GitProcessResult? { nil }
    func createBranch(named name: String, from reference: GitReference, checkout: Bool, at rootURL: URL) -> GitProcessResult? { nil }
    func createWorktree(named name: String, from reference: GitReference, revision: String?, at destination: URL, repositoryRoot: URL) -> GitProcessResult? { nil }
    func removeWorktree(_ worktree: GitWorktree, force: Bool, at rootURL: URL) -> GitProcessResult? { nil }
    func lockWorktree(_ worktree: GitWorktree, at rootURL: URL) -> GitProcessResult? { nil }
    func unlockWorktree(_ worktree: GitWorktree, at rootURL: URL) -> GitProcessResult? { nil }
    func repairWorktrees(at rootURL: URL) -> GitProcessResult? { nil }
    func pruneWorktrees(at rootURL: URL) -> GitProcessResult? { nil }
    func renameBranch(_ reference: GitReference, to name: String, at rootURL: URL) -> GitProcessResult? { nil }
    func deleteBranch(_ reference: GitReference, at rootURL: URL) -> GitProcessResult? { nil }
    func mergeBranch(_ reference: GitReference, at rootURL: URL) -> GitProcessResult? { nil }
    func rebaseCurrentBranch(onto reference: GitReference, at rootURL: URL) -> GitProcessResult? { nil }
    func checkoutAndRebase(_ reference: GitReference, at rootURL: URL) -> GitProcessResult? { nil }
    func updateCurrentBranch(at rootURL: URL, strategy: GitPullStrategy) -> GitProcessResult? { nil }
    func pullRemoteReference(_ reference: GitReference, strategy: GitPullStrategy, at rootURL: URL) -> GitProcessResult? { nil }
    func pullPreflight(at rootURL: URL) -> GitPullPreflightState? { nil }
    func conflictMarkerPaths(at rootURL: URL) -> [String] { [] }
    func integrationPreflight(for target: GitIntegrationTarget, operation: GitIntegrationOperation, at rootURL: URL) -> GitIntegrationPreflightState? { nil }
    func fetch(at rootURL: URL) -> GitProcessResult? { nil }
    func checkout(_ reference: GitReference, at rootURL: URL, force: Bool, autoStash: Bool) -> GitProcessResult? { nil }
    func checkoutBlockingPaths(for reference: GitReference, at rootURL: URL) -> [String] { [] }
    func operationState(at rootURL: URL) -> GitOperationState? { nil }
    func continueOperation(at rootURL: URL) -> GitProcessResult? { nil }
    func abortOperation(at rootURL: URL) -> GitProcessResult? { nil }
    func skipOperationStep(at rootURL: URL) -> GitProcessResult? { nil }
    func checkoutRevision(_ revision: String, at rootURL: URL) -> GitProcessResult? { nil }
    func push(_ reference: GitReference, at rootURL: URL) -> GitProcessResult? { nil }
    func cloneRepository(from remote: String, to destination: URL) -> GitProcessResult? { nil }
    func stash(message: String, includeUntracked: Bool, at rootURL: URL) -> GitProcessResult? { nil }
    func applyStash(_ stash: GitStash, at rootURL: URL) -> GitProcessResult? { nil }
    func popStash(_ stash: GitStash, at rootURL: URL) -> GitProcessResult? { nil }
    func dropStash(_ stash: GitStash, at rootURL: URL) -> GitProcessResult? { nil }
    func stageAll(at rootURL: URL) -> GitProcessResult? { nil }
    func createTag(named name: String, at revision: String, message: String?, rootURL: URL) -> GitProcessResult? { nil }
    func deleteTag(named name: String, rootURL: URL) -> GitProcessResult? { nil }
}
