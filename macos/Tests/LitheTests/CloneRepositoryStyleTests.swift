import AppKit
import SwiftUI
import Testing
@testable import Lithe

@MainActor
@Suite(.serialized)
struct CloneRepositoryStyleTests {
    @Test(arguments: [ColorScheme.dark, .light])
    func sharedInputsFitAndPreserveFolderSuggestion(scheme: ColorScheme) async throws {
        let suite = "Lithe.CloneStyle.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacUserDefaultsStore(defaults: defaults)
        let settings = AppSettings(store: store)
        let container = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode)
        defer { container.moduleLifecycleCoordinator.stop() }
        let model = AppModel(settings: settings, services: container.services)
        let controller = NSHostingController(rootView: CloneRepositoryView().environmentObject(model).environment(\.colorScheme, scheme))
        let host = controller.view
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 650),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        let presenter = LitheCenteredPopupPresenter()
        presenter.resizesToContent = true
        model.workbenchFeature.isCloneRepositoryPresented = true
        presenter.show(contentController: controller, parent: parent, dialogTitle: "Clone Repository") {
            model.workbenchFeature.isCloneRepositoryPresented = false
        }
        defer { presenter.close(); parent.close() }
        let window = try #require(host.window)
        #expect(window.parent === parent && parent.attachedSheet == nil)
        #expect(window.styleMask.contains(.titled))
        #expect(window.animationBehavior == .none)
        try await WorkbenchTestScope.withCleanup({ await model.shutdownProjectSession() }) { _ in
            host.layoutSubtreeIfNeeded()
            window.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            func inputs(_ view: NSView) -> [NSTextField] {
                if let field = view as? NSTextField, field.isEditable { return [field] }
                return view.subviews.flatMap(inputs)
            }
            let fields = inputs(host).sorted { $0.convert($0.bounds, to: host).minY < $1.convert($1.bounds, to: host).minY }
            #expect(fields.count == 3)
            let remote = try #require(fields.first), folder = try #require(fields.last)
            for field in fields {
                let frame = field.convert(field.bounds, to: host)
                #expect(host.bounds.contains(frame))
                #expect(frame.width > 250)
                #expect(abs(try #require(field.font).pointSize - 13) < 0.1)
            }
            #expect(window.makeFirstResponder(remote))
            let editor = try #require(remote.currentEditor() as? NSTextView)
            editor.insertText("https://example.com/sample.git", replacementRange: NSRange(location: 0, length: 0))
            let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while folder.stringValue != "sample", clock.now < deadline { await Task.yield() }
            #expect(folder.stringValue == "sample")
            if let path = ProcessInfo.processInfo.environment["LITHE_WELCOME_LAYOUT_SCREENSHOTS"] {
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                    URL(fileURLWithPath: path).appendingPathComponent("clone-\(scheme == .dark ? "dark" : "light").png"))
            }
            window.performClose(nil)
            #expect(!model.workbenchFeature.isCloneRepositoryPresented)
        }
    }
}
