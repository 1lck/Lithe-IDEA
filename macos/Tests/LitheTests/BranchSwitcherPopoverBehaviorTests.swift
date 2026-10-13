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
    func scrollingTransfersHoverToTheRowUnderTheStationaryPointer() throws {
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
            row.render = { _, selected in
                highlighted[index] = selected
                return AnyView(Text("Branch \(index)"))
            }
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
            for index in rows.indices {
                let row = rows[index]
                #expect(highlighted[index] == (index == Int(offset / 24)),
                        "row \(index) frame \(row.frame) visible \(row.visibleRect) pointer \(row.convert(window.pointer, from: nil))")
            }
        }
        rows[1].isPresented = true
        rows[1].refresh()
        window.pointer = NSPoint(x: -100, y: -100)
        rows.forEach { $0.updateTrackingAreas() }
        #expect(highlighted[1] == true, "An open row action menu keeps its active highlight")
        #expect(highlighted[2] == false, "Leaving the viewport clears the last hover")
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
        let selected = try #require(row.subviews.first)
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
            actions.contains(".disabled(!reference.isCurrent)"),
            "Only the current local branch can be updated."
        )
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
