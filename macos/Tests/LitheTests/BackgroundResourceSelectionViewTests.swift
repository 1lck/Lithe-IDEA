import AppKit
import LitheModuleAPI
import Testing
@testable import Lithe

@Suite("Background resource selection", .serialized)
@MainActor
struct BackgroundResourceSelectionViewTests {
    @Test func longCommandsWrapAndManyResourcesScrollWithinTheAlert() throws {
        let command = "java " + String(repeating: "--add-opens=java.base/java.lang=ALL-UNNAMED ", count: 40)
        let resources = (0..<12).map { resource("service-\($0)", detail: command + String(repeating: "x", count: 200)) }
        let view = BackgroundResourceSelectionView(resources: resources)
        view.layoutSubtreeIfNeeded()
        let document = try #require(view.scrollView.documentView as? NSTextView)
        let manager = try #require(document.layoutManager)
        let container = try #require(document.textContainer)
        let storage = try #require(document.textStorage)
        #expect(document.isSelectable && !document.isEditable)
        #expect(document.string.contains(resources[0].detail))
        #expect(view.scrollView.frame.height == BackgroundResourceSelectionView.maximumListHeight)
        #expect(document.frame.height > view.scrollView.contentSize.height)
        #expect(!view.scrollView.hasHorizontalScroller)
        let initialSize = container.containerSize
        for step in 0...8 {
            let y = document.frame.height * CGFloat(step) / 8
            document.scroll(NSPoint(x: 0, y: y))
            #expect(descendants(document).compactMap { $0 as? NSButton }.count < resources.count)
            #expect(document.textStorage === storage)
            #expect(document.layoutManager === manager)
            #expect(container.containerSize == initialSize)
        }
        #expect(view.scrollView.documentVisibleRect.maxY >= document.bounds.maxY - 1)
        #expect(view.frame.width == BackgroundResourceSelectionView.contentWidth)
        let range = (document.string as NSString).range(of: resources[0].detail)
        document.setSelectedRange(range)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(document.writeSelection(to: pasteboard, types: document.writablePasteboardTypes))
        #expect(pasteboard.string(forType: .string) == resources[0].detail)
    }

    @Test func bulkSelectionAndIndividualCheckboxesKeepResourceIdentity() throws {
        let view = BackgroundResourceSelectionView(resources: [resource("first"), resource("second")])
        #expect(view.selectedIDs == ["first", "second"])
        #expect(!view.selectAllButton.isEnabled && view.deselectAllButton.isEnabled)
        view.deselectAllButton.performClick(nil)
        #expect(view.selectedIDs.isEmpty)
        #expect(view.selectAllButton.isEnabled && !view.deselectAllButton.isEnabled)
        let document = try #require(view.scrollView.documentView)
        let checkbox = try #require(descendants(document).compactMap { $0 as? NSButton }.first { $0.tag == 0 })
        checkbox.performClick(nil)
        #expect(view.selectedIDs == ["first"])
        #expect(view.selectionLabel.stringValue == String(format: L10n.string("%lld of %lld services selected"), 1, 2))
        view.selectAllButton.performClick(nil)
        #expect(view.selectedIDs == ["first", "second"])
    }

    @Test func offscreenCheckboxesAreVirtualizedAndKeepSelectionsByResourceID() throws {
        let resources = (0..<200).map { resource("service-\($0)") }
        let view = BackgroundResourceSelectionView(resources: resources)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.frame.size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        view.layoutSubtreeIfNeeded()
        let document = try #require(view.scrollView.documentView)
        let first = try #require(descendants(document).compactMap { $0 as? NSButton }.first { $0.tag == 0 })
        first.performClick(nil)
        #expect(!view.selectedIDs.contains(resources[0].id))
        document.scroll(NSPoint(x: 0, y: document.frame.height))
        let bottom = descendants(document).compactMap { $0 as? NSButton }
        #expect(bottom.count < 20)
        #expect(!bottom.contains { $0.tag == 0 })
        let last = try #require(bottom.first { $0.tag == resources.count - 1 })
        last.performClick(nil)
        #expect(!view.selectedIDs.contains(resources.last!.id))
        let previous = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\t",
            charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        last.keyDown(with: previous)
        #expect((window.firstResponder as? NSButton)?.tag == resources.count - 2)
        view.deselectAllButton.performClick(nil)
        #expect(view.selectedIDs.isEmpty)
        view.selectAllButton.performClick(nil)
        #expect(view.selectedIDs == Set(resources.map(\.id)))
        document.scroll(.zero)
        let restored = try #require(descendants(document).compactMap { $0 as? NSButton }.first { $0.tag == 0 })
        #expect(restored.state == .on)
        #expect(descendants(document).compactMap { $0 as? NSButton }.count < 20)
        let accessible = (document.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
            .filter { $0.accessibilityRole() == .checkBox }
        #expect(accessible.count == resources.count)
        let lastAccessible = try #require(accessible.last)
        #expect(lastAccessible.accessibilityPerformPress())
        #expect(!view.selectedIDs.contains(resources.last!.id))
        #expect(view.scrollView.documentVisibleRect.minY > 0)
    }

    @Test func rememberChoiceOnlyAppearsForRecognizedServicesAndStartsOff() {
        let unknown = BackgroundResourceSelectionView(resources: [resource("unknown")])
        #expect(unknown.rememberCheckbox.superview == nil)
        let recognized = BackgroundResourceSelectionView(resources: [resource("known", recognizer: "fixture")])
        #expect(recognized.rememberCheckbox.superview != nil)
        #expect(recognized.rememberCheckbox.state == .off)
    }

    @Test func shortAndEmptyListsDoNotReserveTheMaximumHeight() {
        for resources in [[], [resource("single")]] {
            let view = BackgroundResourceSelectionView(resources: resources)
            #expect(view.scrollView.frame.height < BackgroundResourceSelectionView.maximumListHeight)
            #expect(view.scrollView.frame.height > 0)
        }
    }

    @Test func nativeAlertFitsInDarkAndLightAppearances() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let alert = NSAlert()
            alert.messageText = "Background services started in Lithe are still running"
            alert.informativeText = "Checked services end when Lithe quits; unchecked services keep running."
            alert.accessoryView = BackgroundResourceSelectionView(resources: [resource("first"), resource("second", recognizer: "fixture")])
            alert.addButton(withTitle: "Quit with Selection")
            alert.addButton(withTitle: "End All and Quit")
            alert.addButton(withTitle: "Cancel Quit")
            alert.window.appearance = NSAppearance(named: appearance)
            defer { alert.window.orderOut(nil); alert.window.close() }
            alert.layout()
            let accessory = try #require(alert.accessoryView)
            #expect(alert.window.frame.height < 700)
            #expect(accessory.frame.width == BackgroundResourceSelectionView.contentWidth)
            if let directory = ProcessInfo.processInfo.environment["LITHE_PROCESS_EXIT_SCREENSHOTS"],
               let content = alert.window.contentView,
               let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try data.write(to: url.appendingPathComponent("background-services-\(appearance.rawValue).png"))
            }
        }
    }

    private func resource(_ id: String, name: String = "java service", detail: String = "java --add-opens=java.base/java.lang=ALL-UNNAMED --module-path=example.jar", recognizer: String? = nil) -> BackgroundResourceCandidate {
        BackgroundResourceCandidate(id: id, name: name, detail: detail, processIDs: [20, 21], listeningPorts: [8080], startedAt: nil, recognizerID: recognizer, recognizedPolicy: nil, kind: .daemon)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
