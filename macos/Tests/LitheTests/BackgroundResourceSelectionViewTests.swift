import AppKit
import Testing
@testable import Lithe

@Suite("Background resource selection", .serialized)
@MainActor
struct BackgroundResourceSelectionViewTests {
    @Test func longCommandsWrapAndManyResourcesScrollWithinTheAlert() throws {
        let command = "java " + String(repeating: "--add-opens=java.base/java.lang=ALL-UNNAMED ", count: 40)
        let resources = (0..<12).map { resource("service-\($0)", name: command, detail: "workspace/service-\($0)") }
        let view = BackgroundResourceSelectionView(resources: resources)
        view.layoutSubtreeIfNeeded()
        let document = try #require(view.scrollView.documentView)
        let labels = descendants(document).compactMap { $0 as? NSTextField }
        let commandLabel = try #require(labels.first { $0.stringValue == command })
        #expect(commandLabel.maximumNumberOfLines == 0)
        #expect(commandLabel.frame.height > 40)
        #expect(commandLabel.isSelectable)
        #expect(view.scrollView.frame.height == BackgroundResourceSelectionView.maximumListHeight)
        #expect(document.frame.height > view.scrollView.contentSize.height)
        #expect(!view.scrollView.hasHorizontalScroller)
        #expect(labels.allSatisfy { document.bounds.contains($0.frame) })
        document.scroll(NSPoint(x: 0, y: document.frame.height))
        #expect(view.scrollView.documentVisibleRect.maxY >= document.bounds.maxY - 1)
        #expect(view.frame.width == BackgroundResourceSelectionView.contentWidth)
    }

    @Test func bulkSelectionAndIndividualCheckboxesKeepResourceIdentity() throws {
        let view = BackgroundResourceSelectionView(resources: [resource("first"), resource("second")])
        #expect(view.selectedIDs == ["first", "second"])
        #expect(!view.selectAllButton.isEnabled && view.deselectAllButton.isEnabled)
        view.deselectAllButton.performClick(nil)
        #expect(view.selectedIDs.isEmpty)
        #expect(view.selectAllButton.isEnabled && !view.deselectAllButton.isEnabled)
        let document = try #require(view.scrollView.documentView)
        let checkbox = try #require(descendants(document).compactMap { $0 as? NSButton }.first)
        checkbox.performClick(nil)
        #expect(view.selectedIDs == ["first"])
        #expect(view.selectionLabel.stringValue == String(format: String(localized: "%lld of %lld services selected"), 1, 2))
        view.selectAllButton.performClick(nil)
        #expect(view.selectedIDs == ["first", "second"])
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
