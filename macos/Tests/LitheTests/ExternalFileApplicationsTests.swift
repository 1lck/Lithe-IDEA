import AppKit
import Foundation
import Testing
@testable import Lithe

@Suite("External file applications", .serialized)
@MainActor
struct ExternalFileApplicationsTests {
    /// Integration with this Mac's real Launch Services database; no application
    /// is launched and the file is owned and removed by this test.
    @Test func systemApplicationsMatchLaunchServicesAndCarryRealIcons() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Open With 中文.txt")
        try Data("Open With integration".utf8).write(to: file)
        let applications = MacExternalFileApplications.applications(toOpen: file)
        let workspace = NSWorkspace.shared
        let defaultURL = workspace.urlForApplication(toOpen: file)?.standardizedFileURL
        let expected = Set(workspace.urlsForApplications(toOpen: file).map(\.standardizedFileURL))
            .union(defaultURL.map { [$0] } ?? [])
        #expect(Set(applications.map(\.url)) == expected)
        #expect(applications.count == expected.count)
        if let defaultURL {
            #expect(applications.first?.url == defaultURL)
            #expect(applications.first?.isDefault == true)
        }
        #expect(applications.filter(\.isDefault).count == (defaultURL == nil ? 0 : 1))
        for application in applications {
            #expect(application.name == FileManager.default.displayName(atPath: application.url.path))
            #expect(application.iconData.flatMap { NSImage(data: $0) } != nil)
        }
        #expect(MacExternalFileApplications.applications(toOpen: root).isEmpty)
        #expect(MacExternalFileApplications.applications(toOpen: root.appendingPathComponent("missing.txt")).isEmpty)
    }

    @Test func systemRendererPreservesNestedActionsAndDoesNotInvokeWhileBuilding() throws {
        var invoked: [String] = []
        var disabled = LitheContextMenuItem.action("Disabled", localizesTitle: false, isEnabled: false) {
            invoked.append("disabled")
        }
        disabled.isChecked = true
        let menu = LitheSystemContextMenu.makeMenu(items: [
            .action("Copy", localizesTitle: false, shortcut: "⌘C") { invoked.append("copy") },
            .separator,
            .submenu("Open With", items: [
                .action("Current application", localizesTitle: false) { invoked.append("open") },
                disabled
            ])
        ])
        #expect(invoked.isEmpty)
        #expect(!menu.autoenablesItems)
        #expect(menu.items[0].keyEquivalent == "c")
        #expect(menu.items[0].keyEquivalentModifierMask == .command)
        #expect(menu.items[1].isSeparatorItem)
        let submenu = try #require(menu.items[2].submenu)
        #expect(submenu.items[1].isEnabled == false)
        #expect(submenu.items[1].state == .on)
        for item in [submenu.items[0], menu.items[0]] {
            let action = try #require(item.action)
            #expect(NSApplication.shared.sendAction(action, to: item.target, from: item))
        }
        #expect(invoked == ["open", "copy"])
    }

    @Test func systemRendererCopiesIconsWithoutMutatingTheirOwner() throws {
        let image = try #require(NSImage(systemSymbolName: "doc", accessibilityDescription: nil))
        let originalSize = image.size
        var item = LitheContextMenuItem.action("Application", localizesTitle: false, action: {})
        item.nativeImage = image
        let menu = LitheSystemContextMenu.makeMenu(items: [item])
        let rendered = try #require(menu.items.first?.image)
        #expect(rendered !== image)
        #expect(rendered.size == NSSize(width: 16, height: 16))
        #expect(image.size == originalSize)
    }

    @Test func systemRendererKeepsConversationIdentifiersVisible() throws {
        let menu = LitheSystemContextMenu.makeMenu(items: [
            .action("Conversation", localizesTitle: false, description: "1234abcd") {},
            .action("Conversation", localizesTitle: false, description: "5678abcd") {}
        ])
        if #available(macOS 14.4, *) {
            #expect(menu.items.map(\.subtitle) == ["1234abcd", "5678abcd"])
        } else {
            #expect(menu.items[0].title.contains("1234abcd"))
            #expect(menu.items[1].title.contains("5678abcd"))
        }
    }

    @Test func presenterDismissesTheTrackingSystemMenuExactlyOnce() throws {
        let presenter = LitheContextMenuPresenter()
        var item = LitheContextMenuItem.action("Open", action: {})
        item.usesSystemMenu = true
        let state = SystemMenuTrackingState(presenter: presenter)
        // popUp owns a synchronous AppKit tracking loop; bound it locally even
        // if the presenter regresses and no longer cancels the native menu.
        let watchdog = Timer(timeInterval: 2, repeats: false) { _ in
            MainActor.assumeIsolated {
                state.timedOut = true
                state.menu?.cancelTrackingWithoutAnimation()
            }
        }
        RunLoop.main.add(watchdog, forMode: .eventTracking)
        NotificationCenter.default.addObserver(state, selector: #selector(SystemMenuTrackingState.menuBegan(_:)),
            name: NSMenu.didBeginTrackingNotification, object: nil)
        defer {
            watchdog.invalidate()
            NotificationCenter.default.removeObserver(state)
            presenter.dismiss()
            state.menu?.cancelTrackingWithoutAnimation()
        }
        let screen = try #require(NSScreen.main)
        presenter.show(items: [item], at: NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY),
            appearance: nil, locale: Locale(identifier: "en"), onDismiss: { state.dismissals += 1 })
        #expect(state.didTrack)
        #expect(!state.timedOut)
        #expect(state.dismissedDuringTracking)
        #expect(state.dismissals == 1)
        presenter.dismiss()
        #expect(state.dismissals == 1)
    }

    @Test func projectMenuUsesRealSystemApplicationsAndHidesAfterWorkspaceCloses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Document.txt")
        try Data("Saved document".utf8).write(to: file)
        let suite = "lithe-open-with-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacUserDefaultsStore(defaults: defaults)
        let settings = AppSettings(store: store, logDirectoryProvider: MacServiceContainer.makeLogDirectoryProvider())
        let services = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode).services
        let model = AppModel(settings: settings, services: services)
        model.workspaceSessionCoordinator.beginWorkspace(at: root)
        let items = ProjectFileOpenWithMenu.items(model: model, url: file)
        let applications = MacExternalFileApplications.applications(toOpen: file)
        let menu = LitheSystemContextMenu.makeMenu(items: items)
        // Shut down before throwing assertions so a failure cannot retain services.
        await model.shutdownProjectSession()
        #expect(items.count == 1)
        #expect(items.first?.usesSystemMenu == true)
        let submenu = try #require(menu.items.first?.submenu)
        let actions = submenu.items.filter { !$0.isSeparatorItem }
        #expect(actions.count == applications.count + 2)
        for (item, application) in zip(actions, applications) {
            #expect(item.title.contains(application.name))
            #expect(item.image != nil)
        }
        if applications.count > 1, applications.first?.isDefault == true {
            #expect(submenu.items[1].isSeparatorItem)
        }
        #expect(try Data(contentsOf: file) == Data("Saved document".utf8))
        #expect(ProjectFileOpenWithMenu.items(model: model, url: file).isEmpty)
    }
}

@MainActor
private final class SystemMenuTrackingState: NSObject {
    let presenter: LitheContextMenuPresenter
    var menu: NSMenu?
    var dismissals = 0
    var didTrack = false
    var dismissedDuringTracking = false
    var timedOut = false

    init(presenter: LitheContextMenuPresenter) { self.presenter = presenter }

    // AppKit posts tracking notifications synchronously on its main-thread
    // tracking loop. Keep their non-Sendable payload in this native callback.
    @objc func menuBegan(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        self.menu = menu
        didTrack = true
        RunLoop.main.perform(inModes: [.eventTracking]) { [self] in
            MainActor.assumeIsolated {
                presenter.dismiss()
                dismissedDuringTracking = dismissals == 1
            }
        }
    }
}
