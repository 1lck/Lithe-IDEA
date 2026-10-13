import AppKit
import SwiftUI
import Testing
import LitheGitModule
@testable import Lithe

@MainActor
@Suite("Git console toolbar", .serialized)
struct GitConsoleToolbarTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHE_VERIFY_IDEA_RESOURCES"] == "1"))
    func nativeConsoleUsesBundledLightAndDarkIcons() async throws {
        for path in ["expui/general/search.svg", "expui/general/softWrap.svg", "expui/general/scrollDown.svg",
                     "expui/run/stop.svg", "expui/general/delete.svg", "expui/general/copy.svg"] {
            for resource in [path, LitheIcons.darkIdeaAssetPath(for: path)] {
                #expect(try #require(LitheIcons.ideaImage(resourcePath: resource)).size == NSSize(width: 16, height: 16))
            }
        }
        let feature = GitFeatureModel(service: GitService(operations: RustGitOperations(core: RustCoreBridge())))
        defer { feature.reset() }
        for dark in [false, true] {
            let hosting = NSHostingView(rootView: GitConsoleView(feature: feature)
                .background(LitheTheme.editor).environment(\.colorScheme, dark ? .dark : .light))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 260),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = hosting
            window.orderFront(nil)
            defer { window.contentView = nil; window.close() }
            hosting.layoutSubtreeIfNeeded()
            await Task.yield()
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / hosting.bounds.width
            let selected = try #require(bitmap.colorAt(x: Int(10 * scale), y: Int(70 * scale)))
            let gap = try #require(bitmap.colorAt(x: Int(10 * scale), y: Int(56 * scale)))
            // The following-output action has a selected surface, separated by
            // the same unpainted 4pt inter-button gap as ActionToolbarImpl.
            #expect(abs(selected.redComponent - gap.redComponent) > 0.02)
            if let directory = ProcessInfo.processInfo.environment["LITHE_DIFF_CAPTURE_DIR"] {
                let url = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: url.appendingPathComponent("console-\(dark ? "dark" : "light").png"))
            }
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type,
                    location: NSPoint(x: 19, y: hosting.bounds.height - 18), modifierFlags: [],
                    timestamp: 1, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 1, clickCount: 1, pressure: 1))
                window.sendEvent(event)
            }
            hosting.layoutSubtreeIfNeeded()
            await Task.yield()
            hosting.layoutSubtreeIfNeeded()
            func editableFields(_ view: NSView) -> [NSTextField] {
                (view as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? view.subviews.flatMap(editableFields)
            }
            #expect(!editableFields(hosting).isEmpty, "Find retains its native click action")
        }
    }
}
