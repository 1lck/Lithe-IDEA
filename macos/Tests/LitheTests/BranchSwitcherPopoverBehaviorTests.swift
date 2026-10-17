import AppKit
import SwiftUI
import LitheGitModule
import Testing
@testable import Lithe

/// Source checks protect explicit checkout/menu routing; the native expansion
/// check exercises row drawing, mouse delivery and accessibility in both themes.
@Suite("Branch switcher popover behavior")
struct BranchSwitcherPopoverBehaviorTests {
    private static func source(at relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private static func popoverSource() throws -> String {
        try source(at: "Sources/Lithe/Views/Git/BranchSwitcherPopover.swift")
    }

    private static func workbenchSource() throws -> String {
        try source(at: "Sources/Lithe/Views/Workbench/WorkbenchView.swift")
    }

    @Test
    func branchRowsOpenAnActionMenuInsteadOfCheckingOutOnClick() throws {
        let source = try Self.popoverSource()

        #expect(
            source.contains("BranchActionMenuRow("),
            "Branch rows must route through BranchActionMenuRow so a click opens the action menu."
        )
        #expect(
            source.contains("private func branchActionMenu(for reference: GitReference)"),
            "The per-reference action list must exist for the menu to present."
        )
    }

    @Test
    func checkoutIsReachableOnlyAsAnExplicitMenuEntry() throws {
        let source = try Self.popoverSource()

        // The single permitted checkout call site is the menu's Checkout entry.
        let checkoutCallSites = source.components(separatedBy: "feature.checkoutReference(").count - 1
        #expect(
            checkoutCallSites == 1,
            "Checkout must have exactly one call site, the explicit Checkout menu entry."
        )

        guard let checkoutRange = source.range(of: "feature.checkoutReference(") else {
            Issue.record("Expected a checkout call site in the branch popup.")
            return
        }
        let precedingSource = source[source.startIndex..<checkoutRange.lowerBound]
        guard let buttonRange = precedingSource.range(of: "LitheContextMenuItem.action(\"Checkout\")", options: .backwards) else {
            Issue.record("Checkout must be invoked from the explicit shared Checkout action.")
            return
        }
        // Nothing but the dismiss-and-run wrapper may sit between the button and
        // the checkout call, which keeps the call attached to that menu entry.
        let between = precedingSource[buttonRange.upperBound...]
        #expect(
            between.contains("dismissAndRun"),
            "The Checkout menu entry must dismiss the popup before checking out."
        )
        #expect(
            !between.contains("LitheContextMenuItem.action("),
            "No other menu action may sit between the Checkout entry and the checkout call."
        )
    }

    @Test
    func branchHoverIsInlineAndToolbarKeepsItsArrowCursor() throws {
        let popover = try Self.popoverSource()
        let workbench = try Self.workbenchSource()
        let start = try #require(workbench.range(of: "private var topBar: some View"))
        let end = try #require(workbench.range(of: "private var projectSwitcherContent:"))
        let toolbar = workbench[start.lowerBound..<end.lowerBound]
        #expect(popover.contains("BranchPopupRowView(isPresented:"))
        #expect(!popover.contains(".help(Text(verbatim: branchRowTooltip(reference)))"))
        #expect(!toolbar.contains("workbenchHoverHelp"))
        #expect(!toolbar.contains("lithePointer"))
    }

    @Test(arguments: [true, false])
    @MainActor
    func referenceDecodingPreservesTrackingForHistoryAndRecentRows(hasCounts: Bool) throws {
        let counts = hasCounts ? #", "ahead":2, "behind":1"# : ""
        let reference = #"{"fullName":"refs/heads/feature","shortName":"feature","kind":"local","peelsToCommit":true,"isCurrent":false,"upstreamShortName":"origin/feature""# + counts + "}"
        let data = Data((#"{"references":["# + reference + #"],"recentReferences":["# + reference + #"],"commits":[],"hasMore":false}"#).utf8)
        let history = try JSONDecoder().decode(RustCoreBridge.GitHistoryPayload.self, from: data).makeSnapshot()
        let references = try JSONDecoder().decode(RustCoreBridge.GitReferencesPayload.self, from: data).makeSnapshot()
        for row in history.references + history.recentReferences + references.references + references.recentReferences {
            #expect(row.upstreamShortName == "origin/feature")
            #expect(row.ahead == (hasCounts ? 2 : 0))
            #expect(row.behind == (hasCounts ? 1 : 0))
        }
    }

    @Test
    @MainActor
    func actionsAndBranchesShareScrollingWhileSearchStaysFixed() throws {
        let feature = GitFeatureModel(service: GitService(operations: RustGitOperations(core: RustCoreBridge())))
        let host = NSHostingView(rootView: BranchSwitcherPopover(feature: feature, isPresented: .constant(true),
            onCommit: {}, onPush: { _ in }, onDelete: { _ in }, onNewBranch: { _ in },
            onCheckoutRevision: {}, onManageBranches: {}, onCompareWithWorkingTree: { _ in },
            onCompareReferences: { _, _ in }))
        // A short viewport forces scrolling even with just actions and the empty branch row.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 375, height: 170),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        let views = descendants(host)
        let scrolls = views.compactMap { $0 as? NSScrollView }
        #expect(scrolls.count == 1)
        let scroll = try #require(scrolls.first)
        let document = try #require(scroll.documentView)
        let search = try #require(views.compactMap { $0 as? NSTextField }.first(where: { $0.isEditable }))
        let searchFrame = search.convert(search.bounds, to: host)
        #expect(document.bounds.height > scroll.contentView.bounds.height,
                "Actions must contribute to the scroll document, not sit above a branch-only viewport")
        let before = document.convert(document.bounds, to: host).origin
        let initialY = scroll.contentView.bounds.minY
        let nextY = initialY > 0 ? max(0, initialY - 24) : min(24, document.bounds.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: nextY))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(document.convert(document.bounds, to: host).origin != before)
        #expect(search.convert(search.bounds, to: host) == searchFrame)
    }

    @Test
    @MainActor
    func scrollingTransfersHoverToTheRowUnderTheStationaryPointer() async throws {
        let window = BranchHoverTestWindow(contentRect: NSRect(x: 100, y: 100, width: 375, height: 48),
                                           styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 375, height: 48))
        let document = BranchHoverTestDocument(frame: NSRect(x: 0, y: 0, width: 375, height: 96))
        scroll.documentView = document
        window.contentView = scroll
        var highlighted: [Int: Bool] = [:]
        let rows = (0..<4).map { index in
            let row = BranchPopupRowControl()
            row.frame = NSRect(x: 0, y: CGFloat(index) * 24, width: 375, height: 24)
            highlighted[index] = false
            row.onHoverChange = { highlighted[index] = $0 }
            row.renderExpansion = { AnyView(Text("Branch \(index)")) }
            document.addSubview(row)
            row.refresh()
            return row
        }
        window.pointer = rows[0].convert(NSPoint(x: 20, y: 12), to: nil)
        rows[0].mouseEntered(with: try #require(NSEvent.enterExitEvent(with: .mouseEntered,
            location: window.pointer, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)))
        #expect(highlighted[0] == true)
        for offset in [24.0, 48.0] {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scroll.reflectScrolledClipView(scroll.contentView)
            // AppKit rebuilds tracking regions as the clip bounds move. No
            // mouseExited is guaranteed when the old region is removed.
            rows.forEach { $0.updateTrackingAreas() }
            // Tracking areas are rebuilt during layout; hover renders after the pass.
            await Self.drainMainQueue()
            for index in rows.indices {
                let row = rows[index]
                #expect(highlighted[index] == (index == Int(offset / 24)),
                        "row \(index) frame \(row.frame) visible \(row.visibleRect) pointer \(row.convert(window.pointer, from: nil))")
            }
        }
        window.pointer = NSPoint(x: -100, y: -100)
        rows.forEach { $0.updateTrackingAreas() }
        await Self.drainMainQueue()
        #expect(highlighted.values.allSatisfy { !$0 }, "Leaving the viewport clears the last hover")
    }

    @Test(arguments: [ColorScheme.light, .dark])
    @MainActor
    func branchExpansionPreservesTheRowAndClickAction(scheme: ColorScheme) throws {
        let name = "codex/a-long-local-branch-name"
        let upstream = "origin/codex/a-long-upstream-branch-name"
        var presses = 0
        let host = NSHostingView(rootView: BranchPopupRowView(isPresented: false, accessibilityTitle: name,
            onPress: { presses += 1 }, label: { expanded, _ in
                HStack(spacing: 8) {
                    Text(verbatim: name).lineLimit(1).fixedSize(horizontal: expanded, vertical: true)
                    Spacer(minLength: 10)
                    Text(verbatim: upstream).lineLimit(1).fixedSize(horizontal: expanded, vertical: true)
                }.frame(height: LitheDropdownMetrics.rowHeight)
            }).environment(\.colorScheme, scheme))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 375, height: 24),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        func control(in view: NSView) -> BranchPopupRowControl? {
            (view as? BranchPopupRowControl) ?? view.subviews.lazy.compactMap { control(in: $0) }.first
        }
        let row = try #require(control(in: host))
        let enter = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil))
        row.mouseEntered(with: enter)
        let originalFrame = row.frame
        // Hover must show an actual child window without any click or direct drawing call.
        let expansion = try #require(window.childWindows?.first(where: { $0.isVisible }))
        let screenRow = window.convertToScreen(row.convert(row.bounds, to: nil))
        #expect(!expansion.isKeyWindow, "Showing a full name must not steal keyboard focus")
        #expect(expansion.frame.width > row.bounds.width)
        #expect(expansion.frame.height == row.bounds.height)
        #expect(expansion.frame.origin == screenRow.origin)
        #expect(row.frame == originalFrame, "Hover expansion must not resize the popup or shift the row")
        let expandedView = try #require(expansion.contentView)
        expandedView.layoutSubtreeIfNeeded()
        let pixels = try #require(expandedView.bitmapImageRepForCachingDisplay(in: expandedView.bounds))
        expandedView.cacheDisplay(in: expandedView.bounds, to: pixels)
        let image = NSImage(size: expandedView.bounds.size)
        image.lockFocus()
        pixels.draw(in: expandedView.bounds)
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let color = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 3)?.usingColorSpace(.sRGB))
        // Compare the actual selected row through the same AppKit drawing path;
        // the display's ICC profile must not be mistaken for a theme change.
        #expect(row.subviews.isEmpty, "Rows draw inline; the control must not host a view per row")
        // The hover highlight reaches the inline SwiftUI row on its next update.
        let selected = host
        selected.layoutSubtreeIfNeeded()
        let selectedBitmap = try #require(selected.bitmapImageRepForCachingDisplay(in: selected.bounds))
        selected.cacheDisplay(in: selected.bounds, to: selectedBitmap)
        let selectedImage = NSImage(size: selected.bounds.size)
        selectedImage.lockFocus()
        selectedBitmap.draw(in: selected.bounds)
        selectedImage.unlockFocus()
        let selectedTIFF = try #require(selectedImage.tiffRepresentation)
        let selectedPixels = try #require(NSBitmapImageRep(data: selectedTIFF))
        let expected = try #require(selectedPixels.colorAt(x: selectedPixels.pixelsWide / 2, y: 3)?.usingColorSpace(.sRGB))
        #expect(zip([color.redComponent, color.greenComponent, color.blueComponent],
                    [expected.redComponent, expected.greenComponent, expected.blueComponent])
            .allSatisfy { abs($0 - $1) < 0.01 }, "Expansion must retain the actual selected-row fill")
        if let directory = ProcessInfo.processInfo.environment["LITHE_BRANCH_EXPANSION_CAPTURE_DIR"] {
            let root = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                root.appendingPathComponent("branch-expanded-\(scheme == .dark ? "dark" : "light").png"))
        }
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
            location: row.convert(NSPoint(x: 20, y: 12), to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(host.hitTest(row.convert(NSPoint(x: 20, y: 12), to: host)) === row,
                "The native expansion control must own row mouse events")
        expansion.sendEvent(try #require(NSEvent.mouseEvent(with: .leftMouseDown,
            location: NSPoint(x: 20, y: 12), modifierFlags: [], timestamp: 0,
            windowNumber: expansion.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        #expect(presses == 1, "Clicking the expanded row must reach the action-menu trigger")
        #expect(!expansion.isVisible)
        window.sendEvent(click)
        #expect(presses == 2)
        #expect(row.accessibilityPerformPress())
        #expect(presses == 3)
        row.isPresented = true
        row.refresh()
        #expect(window.childWindows?.contains(where: { $0.isVisible }) != true)
        row.isPresented = false
        row.refresh()
        row.frame.size.width = expansion.frame.width + 1
        row.refresh()
        #expect(window.childWindows?.contains(where: { $0.isVisible }) != true, "Fully visible names need no expansion")
        row.isEnabled = false
        row.refresh()
        #expect(!row.accessibilityPerformPress())
        #expect(presses == 3)
        row.isEnabled = true
        row.frame = originalFrame
        row.refresh()
        let closingExpansion = try #require(window.childWindows?.first(where: { $0.isVisible }))
        window.close()
        #expect(!closingExpansion.isVisible)
        #expect(window.childWindows?.isEmpty != false, "Closing the popup must release its expanded row")
    }

    /// Issue 1277: activating or deactivating the app while the popup is open lets
    /// SwiftUI's FocusBridge re-enter updateNSView inside the window layout pass.
    /// Touching the hosting view or the hover expansion there makes AppKit abort
    /// the constraint pass, so the row must wait for layout to finish and then
    /// render the coalesced state exactly once.
    @Test
    @MainActor
    func layoutReentrantUpdatesDeferHoveredExpansionRendering() async throws {
        let name = "codex/a-long-local-branch-name-that-needs-hover-expansion"
        let upstream = "origin/codex/a-long-upstream-branch-name"
        let container = BranchLayoutReentryContainer(frame: NSRect(x: 0, y: 0, width: 375, height: 24))
        var renders: [(expanded: Bool, highlighted: Bool)] = []
        var rendersDuringLayout = 0
        func rowView(title: String) -> AnyView {
            AnyView(BranchPopupRowView(isPresented: false, accessibilityTitle: title, onPress: {},
                label: { expanded, highlighted in
                    let _ = renders.append((expanded, highlighted))
                    // The inline row is SwiftUI's own update; only the AppKit-hosted
                    // expansion would re-mark the window for constraint updates.
                    let _ = container.isInLayout && expanded ? rendersDuringLayout += 1 : ()
                    HStack(spacing: 8) {
                        Text(verbatim: name).lineLimit(1).fixedSize(horizontal: expanded, vertical: true)
                        Spacer(minLength: 10)
                        Text(verbatim: upstream).lineLimit(1).fixedSize(horizontal: expanded, vertical: true)
                    }.frame(height: LitheDropdownMetrics.rowHeight)
                }))
        }
        let host = NSHostingView(rootView: rowView(title: name))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        // Tracking areas are rebuilt inside layout and reconcile hover against the
        // pointer, so pin it inside the row instead of reading the machine's mouse.
        let window = BranchHoverTestWindow(contentRect: NSRect(x: 100, y: 100, width: 375, height: 24),
                                           styleMask: [.borderless], backing: .buffered, defer: false)
        window.pointer = NSPoint(x: 20, y: 12)
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.orderFrontRegardless()
        defer { container.onLayout = nil; window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        func control(in view: NSView) -> BranchPopupRowControl? {
            (view as? BranchPopupRowControl) ?? view.subviews.lazy.compactMap { control(in: $0) }.first
        }
        let row = try #require(control(in: host))
        row.mouseEntered(with: try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil)))
        let expansion = try #require(window.childWindows?.first(where: { $0.isVisible }),
                                     "The long hovered name must start expanded")
        host.layoutSubtreeIfNeeded()
        renders.removeAll()
        rendersDuringLayout = 0

        // Each pass changes the row title, as a fetch updating ahead/behind counts
        // would, and synchronously drives SwiftUI into updateNSView mid-layout.
        var passes = 0
        container.onLayout = {
            passes += 1
            host.rootView = rowView(title: "\(name) ↑\(passes)")
            host.layoutSubtreeIfNeeded()
        }
        for _ in 0..<3 {
            container.needsLayout = true
            window.layoutIfNeeded()
        }
        container.onLayout = nil
        #expect(passes == 3)
        #expect(row.accessibilityLabel() == "\(name) ↑3", "updateNSView must have run inside layout")
        #expect(rendersDuringLayout == 0, "Hosting the expansion inside layout re-marks the window for constraint updates")
        #expect(renders.filter(\.expanded).isEmpty)
        #expect(renders.map(\.highlighted) == renders.map { _ in true }, "The hovered inline row stays highlighted")

        await Self.drainMainQueue()
        #expect(renders.filter(\.expanded).count == 1, "Three updates coalesce into one expansion render")
        #expect(expansion.isVisible, "The hovered long name stays expanded after the deferred render")
        #expect(window.childWindows?.filter { $0.isVisible }.count == 1)

        // Presenting the action menu must not leave a clickable expansion for a turn.
        row.update(BranchPopupRowControl.RenderState(title: name, content: 0, isPresented: true, isEnabled: true,
                                                     environment: EnvironmentValues()))
        #expect(!expansion.isVisible, "Presenting the row closes its expansion before the deferred render")
    }

    /// Scrolling moves rows under a stationary pointer, and AppKit rebuilds their
    /// tracking areas inside the window layout pass. The hover transfer and the
    /// expansion reposition must wait for that pass instead of re-hosting views.
    @Test
    @MainActor
    func trackingAreaRebuildsDuringLayoutDeferHoverRendering() async throws {
        let window = BranchHoverTestWindow(contentRect: NSRect(x: 100, y: 100, width: 120, height: 48),
                                           styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = BranchLayoutReentryContainer(frame: NSRect(x: 0, y: 0, width: 120, height: 48))
        window.contentView = container
        window.orderFrontRegardless()
        defer { container.onLayout = nil; window.contentView = nil; window.close() }
        var hovers: [(row: Int, hovered: Bool)] = []
        var expansions: [Int] = []
        var rendersDuringLayout = 0
        let rows = (0..<2).map { index in
            let row = BranchPopupRowControl()
            row.frame = NSRect(x: 0, y: CGFloat(index) * 24, width: 120, height: 24)
            row.onHoverChange = { hovered in
                hovers.append((index, hovered))
                if container.isInLayout { rendersDuringLayout += 1 }
            }
            row.renderExpansion = {
                expansions.append(index)
                if container.isInLayout { rendersDuringLayout += 1 }
                return AnyView(Text(verbatim: "codex/a-long-branch-name-\(index)-that-needs-expansion")
                    .lineLimit(1).fixedSize()
                    .frame(height: LitheDropdownMetrics.rowHeight))
            }
            container.addSubview(row)
            row.refresh()
            return row
        }
        window.pointer = rows[0].convert(NSPoint(x: 20, y: 12), to: nil)
        rows[0].mouseEntered(with: try #require(NSEvent.enterExitEvent(with: .mouseEntered,
            location: window.pointer, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)))
        #expect(window.childWindows?.filter { $0.isVisible }.count == 1, "The long hovered name must start expanded")
        hovers.removeAll()
        expansions.removeAll()

        // The pointer stays put while the rows move under it, as during scrolling.
        window.pointer = rows[1].convert(NSPoint(x: 20, y: 12), to: nil)
        container.onLayout = { rows.forEach { $0.updateTrackingAreas() } }
        for _ in 0..<3 {
            container.needsLayout = true
            window.layoutIfNeeded()
        }
        container.onLayout = nil
        #expect(rendersDuringLayout == 0, "Hover and expansion changes during layout re-mark the window")
        #expect(hovers.isEmpty && expansions.isEmpty)

        await Self.drainMainQueue()
        #expect(hovers.filter { $0.row == 0 }.map(\.hovered) == [false], "The old row clears its hover once")
        #expect(hovers.filter { $0.row == 1 }.map(\.hovered) == [true], "The new row takes the hover once")
        #expect(expansions == [1], "Only the new row expands, once")
        #expect(window.childWindows?.filter { $0.isVisible }.count == 1, "Only the hovered row stays expanded")
    }

    /// A pending refresh belongs to the window the row was in. Leaving it cancels
    /// the refresh; joining another window refreshes the latest state there.
    @Test
    @MainActor
    func pendingRefreshFollowsTheRowAcrossWindows() async throws {
        func makeWindow() -> NSWindow {
            // Joining a window rebuilds tracking areas, which reconcile hover against
            // the pointer; keep it on the row so the real mouse cannot clear the hover.
            let window = BranchHoverTestWindow(contentRect: NSRect(x: 100, y: 100, width: 120, height: 24),
                                               styleMask: [.borderless], backing: .buffered, defer: false)
            window.pointer = NSPoint(x: 20, y: 12)
            window.isReleasedWhenClosed = false
            window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
            return window
        }
        let first = makeWindow()
        let second = makeWindow()
        defer { first.close(); second.close() }
        var titles: [String] = []
        let row = BranchPopupRowControl()
        row.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        func update(_ title: String, content: AnyHashable = 0) {
            row.renderExpansion = {
                titles.append(title)
                return AnyView(Text(verbatim: "\(title) codex/a-long-branch-name-that-needs-expansion").fixedSize())
            }
            row.update(BranchPopupRowControl.RenderState(title: title, content: content, isPresented: false,
                                                         isEnabled: true, environment: EnvironmentValues()))
        }
        first.contentView?.addSubview(row)
        update("first")
        #expect(titles.isEmpty, "A row nobody hovers has no expansion to build")
        row.mouseEntered(with: try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: first.windowNumber, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil)))
        #expect(titles == ["first"])

        update("second")
        #expect(titles == ["first"])
        row.removeFromSuperview()
        await Self.drainMainQueue()
        #expect(titles == ["first"], "A detached row drops the refresh queued for its old window")

        second.contentView?.addSubview(row)
        await Self.drainMainQueue()
        #expect(titles == ["first", "second"], "Joining a window refreshes the latest state once")
        update("second")
        // AppKit rebuilds tracking areas whenever it likes after a window change;
        // that only repositions the open expansion.
        row.updateTrackingAreas()
        await Self.drainMainQueue()
        #expect(titles == ["first", "second"], "Unchanged state does not re-render")
        // Selection or current-branch changes keep the title but alter the label.
        update("second", content: ["current"])
        await Self.drainMainQueue()
        #expect(titles == ["first", "second", "second"], "A content key change re-renders the expansion")
    }

    /// A row that SwiftUI inserts into a window already on screen, as a lazy list
    /// does while scrolling, must have content before the next display.
    @Test
    @MainActor
    func rowInsertedIntoAVisibleWindowRendersImmediately() throws {
        var renders = 0
        func list(rows: Int) -> AnyView {
            AnyView(VStack(spacing: 0) {
                ForEach(0..<rows, id: \.self) { index in
                    BranchPopupRowView(isPresented: false, accessibilityTitle: "branch-\(index)", onPress: {},
                        label: { _, _ in
                            let _ = renders += 1
                            Text(verbatim: "branch-\(index)")
                        })
                        .frame(height: LitheDropdownMetrics.rowHeight)
                }
            })
        }
        let host = NSHostingView(rootView: list(rows: 1))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 200, height: 48),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        let initial = renders
        #expect(initial >= 1)
        host.rootView = list(rows: 2)
        host.layoutSubtreeIfNeeded()
        #expect(renders > initial, "The inserted row renders without waiting for another run loop turn")
    }

    @MainActor
    private static func drainMainQueue() async {
        // Deferred row renders are queued on the main queue before this hop resumes.
        await withCheckedContinuation { gate in DispatchQueue.main.async { gate.resume() } }
    }

    @Test
    func updateAndPushAreLimitedToSupportedLocalBranches() throws {
        let source = try Self.popoverSource()

        guard let localActions = source.range(of: "if reference.kind == .local {") else {
            Issue.record("Update and Push must be grouped under a local-branch capability check.")
            return
        }
        let actions = source[localActions.lowerBound...]
        #expect(actions.contains("LitheContextMenuItem.action(\"Update\")"))
        #expect(
            actions.contains(".disabled(!reference.isCurrent && reference.upstreamShortName == nil)"),
            "The current branch pulls; another local branch needs an upstream to fast-forward from."
        )
        #expect(actions.contains("feature.updateBranch(reference)"),
                "Update routes through the dispatcher that handles non-current branches.")
        #expect(actions.contains("LitheContextMenuItem.action(\"Push…\")"))
    }

    @Test
    func deleteUsesTheWorkbenchConfirmationFlow() throws {
        let popover = try Self.popoverSource()
        let workbench = try Self.workbenchSource()

        #expect(popover.contains("dismissAndRun { onDelete(reference) }"))
        #expect(
            !popover.contains("model.deleteBranch(reference)")
                && !popover.contains("feature.deleteBranch(reference)"),
            "The popover must not delete a branch before the user confirms."
        )
        #expect(workbench.contains("Button(\"Delete\", role: .destructive)"))
        #expect(workbench.contains("Task { await model.deleteBranch(reference) }"))
    }

    @Test
    func popupUsesScopedGitStateAndExplicitComparisonNavigation() throws {
        let source = try Self.popoverSource()
        #expect(!source.contains("AppModel"))
        #expect(source.contains("@ObservedObject var feature: GitFeatureModel"))
        #expect(source.contains("await onCompareWithWorkingTree(reference)"))
        #expect(source.contains("await onCompareReferences(reference, current)"))
    }
}

@MainActor
private final class BranchHoverTestWindow: NSWindow {
    var pointer = NSPoint.zero
    override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
}

@MainActor
private final class BranchHoverTestDocument: NSView {
    override var isFlipped: Bool { true }
}

/// Runs a callback from inside AppKit's layout pass, where FocusBridge re-enters SwiftUI.
@MainActor
private final class BranchLayoutReentryContainer: NSView {
    var onLayout: (() -> Void)?
    private(set) var isInLayout = false

    override func layout() {
        super.layout()
        isInLayout = true
        defer { isInLayout = false }
        onLayout?()
    }
}
