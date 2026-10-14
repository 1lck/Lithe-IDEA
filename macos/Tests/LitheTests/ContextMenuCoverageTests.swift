import AppKit
import CoreText
import Testing
import SwiftUI
import LitheGitModule
@testable import Lithe

@Suite("Unified context menus", .serialized)
@MainActor
struct ContextMenuCoverageTests {
    @Test(arguments: [false, true], [ColorScheme.dark, .light])
    func dropdownTriggerClosesItsPopupAndSwitchesToAnother(customContent: Bool, scheme: ColorScheme) async throws {
        let host = NSHostingView(rootView: HStack(spacing: 20) {
            DropdownToggleTestTrigger(title: "First", customContent: customContent)
            DropdownToggleTestTrigger(title: "Second", customContent: customContent)
            Spacer()
        }.frame(width: 450, height: 120, alignment: .topLeading).environment(\.colorScheme, scheme))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 450, height: 120),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()

        func popup() -> NSPanel? {
            window.childWindows?.compactMap { $0 as? NSPanel }.first { $0.isVisible }
        }
        func click(_ point: NSPoint) throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.sendEvent(try #require(NSEvent.mouseEvent(with: type,
                    location: host.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                    clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
            }
            host.layoutSubtreeIfNeeded()
        }
        func waitForPopup(_ condition: (NSPanel?) -> Bool) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(1))
            repeat {
                await Task.yield()
                host.layoutSubtreeIfNeeded()
                if condition(popup()) { return true }
            } while clock.now < deadline
            return false
        }

        try click(NSPoint(x: 80, y: 14))
        #expect(await waitForPopup { $0 != nil })
        let first = try #require(popup())
        try click(NSPoint(x: 80, y: 14))
        #expect(await waitForPopup { $0 == nil }, "The original trigger must close without reopening")
        #expect(!first.isVisible)

        try click(NSPoint(x: 80, y: 14))
        #expect(await waitForPopup { $0 != nil })
        let firstFrame = try #require(popup()?.frame)
        try click(NSPoint(x: 280, y: 14))
        #expect(await waitForPopup { ($0?.frame.minX ?? 0) > firstFrame.minX + 100 },
            "Clicking a different trigger must open it with the same click")
        try click(NSPoint(x: 420, y: 80))
        #expect(await waitForPopup { $0 == nil }, "Outside clicks must still dismiss the popup")
    }

    @Test
    func projectPopupMeasuresContentInsteadOfKeepingA390PointWidth() {
        let short = ProjectSwitcherLayoutMetrics.width(projects: [("Lithe-IDEA", "~/Documents/Lithe-IDEA")],
                                                       locale: Locale(identifier: "en"))
        let long = ProjectSwitcherLayoutMetrics.width(projects: [("Project", String(repeating: "long-directory/", count: 20))],
                                                      locale: Locale(identifier: "en"))
        #expect(short < 300)
        #expect(short >= LitheDropdownMetrics.minimumRootWidth)
        #expect(long > LitheDropdownMetrics.maximumWidth, "Project paths must not inherit the small action-menu cap")
        let branch = ProjectSwitcherLayoutMetrics.width(projects: [("Project", "~/Project")],
            branches: ["topic/" + String(repeating: "long-branch-", count: 12)], locale: Locale(identifier: "en"))
        #expect(branch > LitheDropdownMetrics.maximumWidth)
        #expect(BranchSwitcherPopover.Metrics.popupWidth == 375)
    }

    @Test(arguments: [ColorScheme.dark, .light])
    func topbarDropdownsLeaveToolbarMarginAndRenderRealSharedContent(scheme: ColorScheme) async throws {
        MacBundledFontRegistry.registerFonts()
        let iconRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/IDEAIcons")
        for path in ["expui/general/add.svg", "expui/general/open.svg", "expui/general/vcs.svg",
                     "expui/vcs/update.svg", "expui/vcs/commit.svg", "expui/vcs/push.svg",
                     "expui/vcs/fetch.svg", "expui/general/settings.svg", "expui/nodes/folder.svg",
                     "dvcs/currentBranchLabel.svg", "expui/general/search.svg", "expui/general/chevronRight.svg"] {
            for asset in [path, LitheIcons.darkIdeaAssetPath(for: path)] {
                let image = try #require(NSImage(contentsOf: iconRoot.appendingPathComponent(asset)))
                #expect(image.size == NSSize(width: 16, height: 16))
            }
        }
        let domain = "lithe.topbar-popup-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = MacUserDefaultsStore(defaults: defaults)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-popup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = RecentProjectsStore(store: store).record(root, in: [])
        let settings = AppSettings(store: store)
        let services = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode).services
        let model = AppModel(settings: settings, services: services)
        let sessions = ProjectSessionManager(settings: settings, modelFactory: { model })
        do {
            let feature = GitFeatureModel(service: GitService(operations: RustGitOperations(core: RustCoreBridge())))
            let menus: [(String, CGFloat, AnyView)] = [
                ("project", 30, AnyView(ProjectSwitcherPopover(isPresented: .constant(true),
                    onNewProject: {}, onOpenProject: {}, onCloneRepository: {}, onOpenRecentProject: { _ in })
                    .environmentObject(model).environmentObject(sessions))),
                ("branch", 32, AnyView(BranchSwitcherPopover(feature: feature, isPresented: .constant(true),
                    onCommit: {}, onPush: { _ in }, onDelete: { _ in }, onNewBranch: { _ in },
                    onCheckoutRevision: {}, onManageBranches: {}, onCompareWithWorkingTree: { _ in },
                    onCompareReferences: { _, _ in })))
            ]
            for (name, buttonHeight, content) in menus {
                let probe = DropdownEnvironmentProbe()
                let host = NSHostingView(rootView: TopbarDropdownHarness(probe: probe, buttonHeight: buttonHeight, searchOnTyping: name == "branch",
                    content: content).environment(\.colorScheme, scheme))
                let screen = try #require(NSScreen.main).visibleFrame
                let window = NSWindow(contentRect: NSRect(x: floor(screen.midX), y: floor(screen.midY), width: 180, height: 40),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                // The app may override the system/window appearance. The popup
                // must follow the trigger's SwiftUI theme, including its content.
                window.appearance = NSAppearance(named: scheme == .dark ? .aqua : .darkAqua)
                window.contentView = host
                defer { window.contentView = nil; window.close() }
                host.layoutSubtreeIfNeeded()
                func triggerPixel() throws -> NSColor {
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
                    return try #require(bitmap.colorAt(x: Int(30 * scale), y: Int(20 * scale)))
                }
                let closedColor = try triggerPixel()
                probe.isPresented = true
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: .seconds(2))
                while clock.now < deadline {
                    host.layoutSubtreeIfNeeded()
                    if window.childWindows?.first != nil { break }
                    await Task.yield()
                }
                let popup = try #require(window.childWindows?.first)
                #expect(popup.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == (scheme == .dark ? .darkAqua : .aqua))
                if name == "branch" {
                    let focusDeadline = clock.now.advanced(by: .seconds(1))
                    while popup.firstResponder is NSTextView, clock.now < focusDeadline { await Task.yield() }
                    #expect(!(popup.firstResponder is NSTextView), "Opening the branch tree must not focus the search editor")
                }
                let visibleFrame = try #require(NSScreen.main).visibleFrame.insetBy(dx: 6, dy: 6)
                let spaceBelow = window.frame.minY - visibleFrame.minY
                if popup.frame.height <= spaceBelow {
                    #expect(abs(popup.frame.maxY - window.frame.minY) < 1,
                            "A dropdown with room below stays attached to its lower edge")
                } else {
                    #expect(visibleFrame.contains(popup.frame),
                            "A dropdown near the screen edge remains fully visible")
                }
                #expect((40 - buttonHeight) / 2 >= 4)
                #expect(popup.animationBehavior == .none)
                if name == "branch" {
                    #expect(popup.frame.width <= 375)
                } else {
                    #expect(popup.frame.width > LitheDropdownMetrics.maximumWidth,
                            "Project paths must not be capped at the action menu's 360pt width")
                    #expect(popup.frame.width <= visibleFrame.width)
                }
                let openedColor = try triggerPixel()
                #expect(abs(openedColor.redComponent - closedColor.redComponent) > 0.01,
                        "An open native popup must retain its trigger's hover background")
                if let directory = ProcessInfo.processInfo.environment["LITHE_TOPBAR_CAPTURE_DIR"] {
                    let triggerBitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: triggerBitmap)
                    try #require(triggerBitmap.representation(using: .png, properties: [:])).write(to:
                        URL(fileURLWithPath: directory).appendingPathComponent("\(name)-trigger-\(scheme == .dark ? "dark" : "light").png"))
                }
                popup.contentView?.layoutSubtreeIfNeeded()
                let view = try #require(popup.contentView)
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let directory = ProcessInfo.processInfo.environment["LITHE_TOPBAR_CAPTURE_DIR"] {
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                        URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
                }
                if name == "branch" {
                    let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
                    // Pixel components use the capture's ICC profile even when
                    // colorAt reports calibrated RGB. Compare in that same space.
                    let fieldColor = try #require(bitmap.colorAt(x: Int(280 * scale), y: Int(20 * scale)))
                    let expected = try #require(LitheTheme.nsColor(.popupBackground, isDark: scheme == .dark)
                        .usingColorSpace(bitmap.colorSpace))
                    #expect(abs(fieldColor.redComponent - expected.redComponent) < 0.01)
                    #expect(abs(fieldColor.greenComponent - expected.greenComponent) < 0.01)
                    #expect(abs(fieldColor.blueComponent - expected.blueComponent) < 0.01)
                    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                        modifierFlags: [], timestamp: 0, windowNumber: popup.windowNumber, context: nil,
                        characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
                    popup.sendEvent(event)
                    #expect(try #require(popup.firstResponder as? NSTextView).string == "x")
                }
                probe.isPresented = false
                await Task.yield()
                let restoredColor = try triggerPixel()
                #expect(abs(restoredColor.redComponent - closedColor.redComponent) < 0.01)
                window.contentView = nil
                #expect(!popup.isVisible)
            }
        } catch {
            await model.shutdownProjectSession()
            throw error
        }
        await model.shutdownProjectSession()
    }

    @Test
    func preferredSizeChangesCoalesceWithoutReenteringTheCallback() async {
        let controller = LitheDropdownHostingController(rootView: AnyView(EmptyView()))
        var sizes: [NSSize] = []
        var callbackDepth = 0
        var maximumDepth = 0
        controller.sizeChanged = { [weak controller] in
            guard let controller else { return }
            callbackDepth += 1
            defer { callbackDepth -= 1 }
            maximumDepth = max(maximumDepth, callbackDepth)
            sizes.append(controller.preferredContentSize)
            if sizes.count == 1 {
                // A size measurement caused by resizing must run in a later turn.
                controller.preferredContentSize = NSSize(width: 400, height: 160)
            }
        }
        defer { controller.sizeChanged = nil }

        for width in [200, 240, 300] as [CGFloat] {
            controller.preferredContentSize = NSSize(width: width, height: 120)
        }
        #expect(sizes.isEmpty)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while sizes.count < 2, clock.now < deadline { await Task.yield() }
        #expect(sizes == [NSSize(width: 300, height: 120), NSSize(width: 400, height: 160)],
                "The latest measurement and its resize feedback must both be delivered")
        #expect(maximumDepth == 1)
    }

    @Test
    func closingContentCancelsQueuedSizeFeedback() async {
        let controller = LitheDropdownHostingController(rootView: AnyView(EmptyView()))
        var callbacks = 0
        controller.sizeChanged = { callbacks += 1 }
        defer { controller.sizeChanged = nil }
        controller.preferredContentSize = NSSize(width: 300, height: 120)
        controller.sizeChanged = nil

        // The sentinel proves the queue passed the cancelled notification.
        var queuePassedNotification = false
        DispatchQueue.main.async { queuePassedNotification = true }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !queuePassedNotification, clock.now < deadline { await Task.yield() }
        #expect(queuePassedNotification, "Main queue did not reach the cancellation sentinel")
        #expect(callbacks == 0)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func dropdownPresentationDefersLayoutAndUsesTheLatestContent(scheme: ColorScheme) async throws {
        var isPresented = true
        var width: CGFloat = 300
        let coordinator = LitheDropdownPopover<AnyView>.Coordinator(
            isPresented: Binding(get: { isPresented }, set: { isPresented = $0 })
        ) { AnyView(Text("Latest content").frame(width: width, height: 120)) }
        coordinator.environment.colorScheme = scheme
        let window = NSWindow(contentRect: NSRect(x: 100, y: 400, width: 240, height: 36),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let anchor = LitheDropdownAnchorView(frame: NSRect(x: 0, y: 0, width: 240, height: 36))
        anchor.onDetach = { [weak coordinator] in coordinator?.dismiss() }
        window.contentView = anchor
        defer {
            coordinator.dismiss()
            anchor.onDetach = nil
            window.contentView = nil
            window.close()
        }

        coordinator.present(relativeTo: anchor, in: window)
        width = 480
        coordinator.present(relativeTo: anchor, in: window)
        #expect(window.childWindows?.isEmpty != false,
                "Presenting during updateNSView must not synchronously lay out a child window")
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while window.childWindows?.first == nil, clock.now < deadline { await Task.yield() }
        let popup = try #require(window.childWindows?.first, "Deferred presentation did not open")
        #expect(window.childWindows?.count == 1)
        #expect(popup.frame.width == 480)
        #expect(popup.appearance?.name == (scheme == .dark ? .darkAqua : .aqua))

        // Closing a queued update must not reopen the old panel on the next turn.
        coordinator.present(relativeTo: anchor, in: window)
        window.contentView = nil
        var queuePassedPresentation = false
        DispatchQueue.main.async { queuePassedPresentation = true }
        let cancellationDeadline = clock.now.advanced(by: .seconds(1))
        while !queuePassedPresentation, clock.now < cancellationDeadline { await Task.yield() }
        #expect(queuePassedPresentation, "Main queue did not reach the dismissal sentinel")
        #expect(!popup.isVisible)
        #expect(!isPresented)
        #expect(window.childWindows?.isEmpty != false)

        // Detach before the first presentation is delivered, not just an update.
        isPresented = true
        window.contentView = anchor
        coordinator.present(relativeTo: anchor, in: window)
        window.contentView = nil
        var queuePassedOpening = false
        DispatchQueue.main.async { queuePassedOpening = true }
        let openingDeadline = clock.now.advanced(by: .seconds(1))
        while !queuePassedOpening, clock.now < openingDeadline { await Task.yield() }
        #expect(queuePassedOpening, "Main queue did not reach the cancelled opening sentinel")
        #expect(!isPresented)
        #expect(window.childWindows?.isEmpty != false)
    }

    @Test
    func sharedContentInheritsEnvironmentAndClosesWhenAnchorDetaches() async throws {
        let probe = DropdownEnvironmentProbe()
        let host = NSHostingView(rootView: DropdownEnvironmentHarness(probe: probe))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 220, height: 36),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            probe.isPresented = false
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        probe.isPresented = true
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while probe.renderedLocale == nil, clock.now < deadline {
            host.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        #expect(probe.renderedLocale == "zh-Hans")
        let dropdown = try #require(window.childWindows?.first)
        #expect(dropdown.isVisible)
        #expect(dropdown.animationBehavior == .none)
        // Detaching a still-presented anchor must close its window and release
        // native event monitors, even before SwiftUI destroys the host.
        window.contentView = nil
        #expect(!dropdown.isVisible)
        #expect(!probe.isPresented)
    }

    @Test(arguments: [false, true])
    func nestedDropdownKeepsParentAndRoutesKeysToChild(atRightEdge: Bool) throws {
        let parent = LitheContextMenuPresenter()
        let child = LitheContextMenuPresenter()
        defer { child.dismiss(); parent.dismiss() }
        let screen = try #require(NSScreen.main).visibleFrame
        let controller = LitheDropdownHostingController(rootView: AnyView(
            Text("Branches").frame(width: 300, height: 180).litheContextMenuSurface()
        ))
        var parentDismissals = 0
        parent.show(contentController: controller, at: NSPoint(x: atRightEdge ? screen.maxX - 306 : screen.minX + 40, y: screen.midY),
                    appearance: NSAppearance(named: .darkAqua)) { parentDismissals += 1 }
        let parentWindow = try #require(controller.view.window)
        var chosen = false
        var childDismissals = 0
        let row = NSRect(x: parentWindow.frame.minX, y: parentWindow.frame.maxY - 80,
                         width: parentWindow.frame.width, height: LitheDropdownMetrics.rowHeight)
        child.show(items: [.action("Checkout") { chosen = true }],
                   at: NSPoint(x: parentWindow.frame.maxX, y: parentWindow.frame.maxY),
                   appearance: parentWindow.effectiveAppearance, locale: Locale(identifier: "en"),
                   anchored: true, adjacentTo: row, parentWindow: parentWindow) { childDismissals += 1 }
        let childWindow = try #require(parentWindow.childWindows?.first)
        #expect(abs(childWindow.frame.maxY - row.maxY - LitheDropdownMetrics.popupPadding) < 1)
        if atRightEdge {
            #expect(abs(childWindow.frame.maxX - parentWindow.frame.minX + LitheDropdownMetrics.submenuSpacing) < 1)
        } else {
            #expect(abs(childWindow.frame.minX - parentWindow.frame.maxX - LitheDropdownMetrics.submenuSpacing) < 1)
        }
        #expect(childWindow.isVisible)
        #expect(parentWindow.isVisible)
        #expect(parentDismissals == 0)
        try sendKey(125, to: childWindow)
        try sendKey(36, to: childWindow)
        #expect(chosen)
        #expect(childDismissals == 1)
        #expect(parentDismissals == 0)
        #expect(parentWindow.isVisible)
        try sendKey(53, to: parentWindow)
        #expect(parentDismissals == 1)
    }

    @Test
    func itemBuilderKeepsConditionalActionsDisabledChoicesAndSubmenus() {
        @LitheMenuItemsBuilder func items() -> [LitheContextMenuItem] {
            LitheContextMenuItem.heading("Actions")
            for index in 0..<2 {
                if index == 1 { LitheContextMenuItem.action("Choice", checked: true) {}.disabled(true) }
            }
            LitheContextMenuItem.submenu("More") {
                LitheContextMenuItem.action("Remove", role: .destructive) {}
            }
        }
        let result = items()
        #expect(result.count == 3)
        #expect(!result[0].isEnabled)
        #expect(!result[1].isEnabled)
        #expect(result[1].isChecked)
        guard case .submenu(let children) = result[2].kind else { Issue.record("Lost submenu"); return }
        #expect(children.count == 1)
        #expect(children[0].role == .destructive)
    }

    @Test
    func filterPopoverAnchorLeavesMouseEventsToItsButton() {
        let button = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        let anchor = GitLogPopoverAnchorView(frame: button.bounds)
        button.addSubview(anchor)
        // The overlay is only an anchor; swallowing hit tests broke both the
        // filter label's hover and the button's click before a popup opened.
        for point in [NSPoint(x: 1, y: 1), NSPoint(x: 50, y: 15), NSPoint(x: 99, y: 29)] {
            #expect(anchor.hitTest(point) == nil)
            #expect(button.hitTest(point) === button)
        }
    }

    @Test(arguments: [ColorScheme.dark, .light])
    func searchableFilterContentCannotCoverSharedRoundedCorners(scheme: ColorScheme) throws {
        let menus: [AnyView] = [
            AnyView(GitLogBranchFilterPopover(
                menu: GitLogFilterList.branchMenu(references: []),
                querySections: { GitLogFilterList.branchSections(references: [], query: $0) },
                isItemSelected: { _ in false }, onSelect: { _ in }
            )),
            AnyView(GitLogFilterPopover(
                sectionsForQuery: { GitLogFilterList.authorSections(authors: [], query: $0) },
                searchPlaceholder: "Search users", emptyText: "No matching users",
                isItemSelected: { _ in false }, onSelect: { _ in }
            ))
        ]
        for menu in menus {
            let renderer = ImageRenderer(content: menu.environment(\.colorScheme, scheme))
            let image = try #require(renderer.cgImage)
            let bitmap = NSBitmapImageRep(cgImage: image)
            // The search strip used to paint an opaque rectangle over the shared corner.
            for x in [0, bitmap.pixelsWide - 1] {
                for y in [0, bitmap.pixelsHigh - 1] {
                    #expect(try #require(bitmap.colorAt(x: x, y: y)).alphaComponent < 0.05)
                }
            }
            #expect(try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 12)).alphaComponent > 0.95)
        }
    }

    @Test
    func anchoredActionAndSearchableDropdownsShareTopLeft() throws {
        let presenter = LitheContextMenuPresenter()
        defer { presenter.dismiss() }
        let screen = try #require(NSScreen.main).visibleFrame
        for point in [NSPoint(x: screen.midX, y: floor(screen.midY)),
                      NSPoint(x: screen.maxX - 10, y: screen.minY + 10)] {
            var dismissals = 0
            presenter.show(items: [.action("Any Time", systemImage: "checkmark") {}],
                           at: point, appearance: NSAppearance(named: .darkAqua),
                           locale: Locale(identifier: "en"), anchored: true) { dismissals += 1 }
            let window = try #require(NSApp.windows.first {
                $0.isVisible && String(describing: type(of: $0)).contains("LitheContextMenuPanel")
            })
            let actionFrame = window.frame
            #expect(window.animationBehavior == .none)
            #expect(screen.contains(actionFrame))
            if point.x == screen.midX {
                #expect(actionFrame.minX == point.x)
                #expect(actionFrame.maxY == point.y)
            }
            try sendKey(53, to: window)
            #expect(dismissals == 1)
            let controller = LitheDropdownHostingController(rootView: AnyView(
                Text("Search branches").frame(width: actionFrame.width, height: actionFrame.height)
                    .litheContextMenuSurface()
            ))
            presenter.show(contentController: controller, at: point,
                           appearance: NSAppearance(named: .darkAqua)) { dismissals += 1 }
            let searchableWindow = try #require(controller.view.window)
            #expect(searchableWindow.frame == actionFrame)
            #expect(searchableWindow.animationBehavior == .none)
            presenter.dismiss()
            #expect(dismissals == 2)
        }
    }

    @Test
    func anchoredSearchableDropdownStaysVisibleAndUsesAvailableSide() throws {
        let presenter = LitheContextMenuPresenter()
        defer { presenter.dismiss() }
        let screen = try #require(NSScreen.main).visibleFrame
        let content = LitheDropdownHostingController(rootView: AnyView(
            Text("Search branches").frame(width: 180, height: 160)
                .litheContextMenuSurface()
        ))
        let parent = NSWindow(contentRect: NSRect(x: screen.midX, y: screen.midY,
                                                   width: 180, height: 40),
                              styleMask: .borderless, backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.orderFront(nil)
        defer { parent.close() }

        let centeredPoint = NSPoint(x: screen.midX, y: screen.midY)
        presenter.show(contentController: content, at: centeredPoint,
                       appearance: NSAppearance(named: .darkAqua), parentWindow: parent) {}
        let centered = try #require(content.view.window)
        #expect(abs(centered.frame.maxY - centeredPoint.y) < 1,
                "A dropdown with room below stays attached to its lower edge")
        presenter.dismiss()

        let edgePoint = NSPoint(x: screen.midX, y: screen.minY + 12)
        presenter.show(contentController: content, at: edgePoint,
                       appearance: NSAppearance(named: .darkAqua), parentWindow: parent) {}
        let edge = try #require(content.view.window)
        #expect(screen.insetBy(dx: 6, dy: 6).contains(edge.frame),
                "A dropdown near the screen edge remains fully visible")
    }

    @Test
    func searchableDropdownUsesSharedWindowAndDismissal() throws {
        let presenter = LitheContextMenuPresenter()
        defer { presenter.dismiss() }
        let screen = try #require(NSScreen.main).visibleFrame
        let controller = LitheDropdownHostingController(rootView: AnyView(
            Text("Filter").frame(width: 300, height: 120).litheContextMenuSurface()
        ))
        var dismissals = 0
        presenter.show(contentController: controller,
                       at: NSPoint(x: screen.midX, y: screen.midY),
                       appearance: NSAppearance(named: .darkAqua)) { dismissals += 1 }
        let window = try #require(controller.view.window)
        #expect(window.styleMask.contains(.borderless))
        #expect(controller.view.subviews.compactMap { $0 as? SplitHandleInteractionView }.isEmpty)
        #expect(!window.isOpaque)
        #expect(window.backgroundColor == .clear)
        #expect(window.frame.width == 300)
        #expect(window.frame.height == 120)
        #expect(screen.contains(window.frame))
        // Search/group changes must resize the existing host rather than replace it.
        controller.rootView = AnyView(Text("Flyout").frame(width: 560, height: 200).litheContextMenuSurface())
        controller.view.layoutSubtreeIfNeeded()
        presenter.resize(contentController: controller)
        #expect(controller.view.window === window)
        #expect(window.frame.width == 560)
        #expect(window.frame.height == 200)
        try sendKey(53, to: window)
        #expect(!window.isVisible)
        #expect(dismissals == 1)
        presenter.dismiss()
        #expect(dismissals == 1)
    }

    @Test(arguments: [100.0, 10000.0])
    func resizableDropdownClampsStoredWidthWithoutCommittingIt(width: Double) throws {
        let presenter = LitheContextMenuPresenter()
        defer { presenter.dismiss() }
        let screen = try #require(NSScreen.main).visibleFrame.insetBy(dx: 6, dy: 6)
        let controller = LitheDropdownHostingController(rootView: AnyView(
            Text("Branches").frame(minWidth: 375, maxWidth: .infinity).frame(height: 120)
        ))
        var committed = false
        presenter.show(contentController: controller, at: NSPoint(x: screen.minX, y: screen.midY),
                       appearance: nil, resizableWidth: CGFloat(width), minimumWidth: 375,
                       onSizeChanged: { _ in committed = true }) {}
        let window = try #require(controller.view.window)
        #expect(window.frame.width == min(max(CGFloat(width), 375), screen.width))
        #expect(screen.contains(window.frame))
        #expect(!committed)
    }

    @Test(arguments: [false, true])
    func resizableDropdownCommitsWidthOnlyAfterResizeAndKeepsItOnContentChanges(nearRightEdge: Bool) throws {
        let presenter = LitheContextMenuPresenter()
        defer { presenter.dismiss() }
        let screen = try #require(NSScreen.main).visibleFrame.insetBy(dx: 6, dy: 6)
        let feature = GitFeatureModel(service: GitService(operations: RustGitOperations(core: RustCoreBridge())))
        let controller = LitheDropdownHostingController(rootView: AnyView(
            BranchSwitcherPopover(feature: feature, isPresented: .constant(true),
                onCommit: {}, onPush: { _ in }, onDelete: { _ in }, onNewBranch: { _ in },
                onCheckoutRevision: {}, onManageBranches: {}, onCompareWithWorkingTree: { _ in },
                onCompareReferences: { _, _ in }).litheContextMenuSurface()
        ))
        var widths: [CGFloat] = []
        let anchor = NSPoint(x: nearRightEdge ? screen.maxX - 500 : screen.minX, y: screen.midY)
        presenter.show(contentController: controller, at: anchor,
                       appearance: nil, resizableWidth: 480, minimumWidth: 375,
                       onSizeChanged: { widths.append($0.width) }) {}
        let window = try #require(controller.view.window)
        let container = try #require(window.contentView)
        // Native branch controls activate the window's constraint engine in the
        // live app; a synchronous test host otherwise leaves it inactive.
        container.widthAnchor.constraint(greaterThanOrEqualToConstant: 375).isActive = true
        window.layoutIfNeeded()
        let handle = try #require(container.subviews.compactMap { $0 as? SplitHandleInteractionView }.first)
        #expect(handle.resizeCursor === NSCursor.resizeLeftRight)
        let start = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType, translation: CGFloat = 0) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: start.x + translation, y: start.y),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }
        #expect(container.hitTest(handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: container)) === handle)
        window.layoutIfNeeded()
        #expect(window.frame.width == 480)
        #expect(window.contentMinSize.width == 375)
        #expect(window.contentMinSize.height == window.contentMaxSize.height)
        let initialLeft = window.frame.minX
        let expectedWidth = min(620, screen.maxX - initialLeft)
        window.sendEvent(try event(.leftMouseDown))
        window.sendEvent(try event(.leftMouseDragged, translation: 140))
        #expect(widths.isEmpty)
        window.sendEvent(try event(.leftMouseUp, translation: 140))
        window.layoutIfNeeded()
        // Resizing retains the left edge and must stop at the visible screen's
        // right edge, including the smaller display used by the CI runner.
        #expect(window.frame.minX == initialLeft)
        #expect(widths == [expectedWidth])
        controller.rootView = AnyView(Text("Search result").frame(minWidth: 375, maxWidth: .infinity).frame(height: 160))
        presenter.resize(contentController: controller)
        window.layoutIfNeeded()
        #expect(window.frame.width == expectedWidth)
        #expect(screen.contains(window.frame))
        presenter.dismiss()
        #expect(controller.view.subviews.compactMap { $0 as? SplitHandleInteractionView }.isEmpty)
        presenter.show(contentController: controller, at: anchor,
                       appearance: nil, resizableWidth: widths.last, minimumWidth: 375) {}
        #expect(controller.view.window?.frame.width == expectedWidth)
        #expect(widths == [expectedWidth])
    }

    @Test(arguments: [ProjectReplacePanelGeometry.Corner.topTrailing, .bottomTrailing], [false, true])
    func branchCornerResizesBothAxesAndRestoresSize(position: ProjectReplacePanelGeometry.Corner, opensAbove: Bool) throws {
        let scheduler = LitheDragUpdateScheduler(delivery: .manual)
        let presenter = LitheContextMenuPresenter(resizeScheduler: scheduler)
        defer { presenter.dismiss() }
        let screen = try #require(NSScreen.main).visibleFrame.insetBy(dx: 6, dy: 6)
        let feature = GitFeatureModel(service: GitService(operations: RustGitOperations(core: RustCoreBridge())))
        let controller = LitheDropdownHostingController(rootView: AnyView(
            BranchSwitcherPopover(feature: feature, isPresented: .constant(true),
                onCommit: {}, onPush: { _ in }, onDelete: { _ in }, onNewBranch: { _ in },
                onCheckoutRevision: {}, onManageBranches: {}, onCompareWithWorkingTree: { _ in },
                onCompareReferences: { _, _ in }).litheContextMenuSurface()
        ))
        var commits: [CGSize] = []
        func show(width: CGFloat, height: CGFloat?) {
            presenter.show(contentController: controller, at: NSPoint(x: screen.minX, y: opensAbove ? screen.minY + 120 : screen.maxY - 120),
                appearance: nil, opensUpward: opensAbove, resizableWidth: width, minimumWidth: 375,
                resizableHeight: height, minimumHeight: BranchSwitcherPopover.Metrics.minimumHeight,
                onSizeChanged: { commits.append($0) }) {}
        }
        show(width: 480, height: nil)
        let window = try #require(controller.view.window)
        let container = try #require(window.contentView)
        container.widthAnchor.constraint(greaterThanOrEqualToConstant: 375).isActive = true
        window.layoutIfNeeded()
        let initial = window.frame
        let corner = try #require(container.subviews.compactMap { $0 as? ProjectReplaceCornerHandleView }.first { $0.corner == position })
        #expect(container.subviews.compactMap { $0 as? ProjectReplaceCornerHandleView }.count == 2)
        #expect(corner.corner == position)
        if #available(macOS 15.0, *) {
            #expect(corner.resizeCursor === NSCursor.frameResize(position: position.isTop ? .topRight : .bottomRight, directions: .all))
        }
        #expect(corner.resizeCursor !== NSCursor.arrow)
        corner.updateTrackingAreas()
        #expect(corner.trackingAreas.contains { $0.options.contains(.activeAlways) })
        let oldCursor = NSCursor.current
        defer { oldCursor.set() }
        NSCursor.arrow.set()
        window.sendEvent(try #require(NSEvent.mouseEvent(with: .mouseMoved,
            location: corner.convert(NSPoint(x: corner.bounds.midX, y: corner.bounds.midY), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0)))
        #expect(NSCursor.current === corner.resizeCursor, "Hover must set the cursor before the first click")
        let point = corner.convert(NSPoint(x: corner.bounds.midX, y: corner.bounds.midY), to: container)
        #expect(container.hitTest(point) === corner)
        func drag(_ delta: CGSize) throws {
            let startFrame = window.frame
            let start = window.convertPoint(toScreen: corner.convert(NSPoint(x: corner.bounds.midX, y: corner.bounds.midY), to: nil))
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseDragged, .leftMouseUp] {
                let steps = type == .leftMouseDragged ? 20 : 1
                let deliveries = scheduler.deliveredCount
                for step in 1...steps {
                    let fraction = CGFloat(step) / CGFloat(steps)
                    let target = type == .leftMouseDown ? start : NSPoint(
                        x: start.x + delta.width * fraction, y: start.y - delta.height * fraction)
                    window.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: target),
                        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                        eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)))
                }
                if type == .leftMouseDragged {
                    #expect(commits.isEmpty)
                    #expect(window.frame == startFrame, "A burst must queue one local update, without saving or resizing for each event")
                    scheduler.flushPendingDeliveryForTesting()
                    #expect(scheduler.deliveredCount == deliveries + 1)
                    window.layoutIfNeeded()
                    #expect(window.frame.size == CGSize(
                        width: min(max(startFrame.width + delta.width, 375), screen.maxX - startFrame.minX),
                        height: min(max(startFrame.height + (position.isTop ? -delta.height : delta.height), 312),
                                    position.isTop ? screen.maxY - startFrame.minY : startFrame.maxY - screen.minY)))
                }
            }
            window.layoutIfNeeded()
        }
        try drag(CGSize(width: 100, height: position.isTop ? -100 : 100))
        let expected = CGSize(width: min(initial.width + 100, screen.width), height: min(initial.height + 100, position.isTop ? screen.maxY - initial.minY : initial.maxY - screen.minY))
        #expect(window.frame.size == expected)
        #expect(position.isTop ? window.frame.minY == initial.minY : window.frame.maxY == initial.maxY)
        #expect(controller.view.frame.size == expected)
        #expect(commits == [expected])
        let releasedFrame = window.frame
        presenter.resize(contentController: controller)
        window.layoutIfNeeded()
        #expect(window.frame == releasedFrame, "Content refresh must preserve the released corner position")
        commits.removeAll()
        try drag(CGSize(width: -10000, height: position.isTop ? 10000 : -10000))
        #expect(window.frame.size == CGSize(width: 375, height: 312))
        commits.removeAll()
        try drag(CGSize(width: 10000, height: position.isTop ? -10000 : 10000))
        #expect(screen.contains(window.frame))
        let saved = try #require(commits.last)
        presenter.dismiss()
        #expect(corner.window == nil)
        show(width: saved.width, height: saved.height)
        controller.view.window?.layoutIfNeeded()
        #expect(controller.view.window?.frame.size == saved)
    }

    @Test
    func worktreeMenuRetainsClickedItemAcrossSelectionRefresh() throws {
        let clicked = worktree("feature")
        let other = worktree("other")
        let view = GitWorktreeListNSView()
        var received: (GitWorktreeListAction, String)?
        view.update(items: [clicked, other], selectedWorktreeID: other.id, onSelect: { _ in }) {
            received = ($0, $1.id)
        }
        let menu = view.contextMenuItems(for: clicked)
        // A selection-triggered refresh must not retarget an already-open menu.
        view.update(items: [other], selectedWorktreeID: other.id, onSelect: { _ in }) { _, _ in
            Issue.record("The open menu used a replacement callback")
        }
        try #require(menu.first { $0.title == "Copy Path" }).action()
        #expect(received?.0 == .copyPath)
        #expect(received?.1 == clicked.id)
    }

    @Test
    func worktreeMenuPreservesProtectionAndBusyStates() throws {
        let view = GitWorktreeListNSView()
        let primary = worktree("primary", primary: true, current: true)
        let locked = worktree("locked", locked: true)
        let stale = worktree("stale", prunable: true)
        view.update(items: [primary, locked, stale], selectedWorktreeID: nil, onSelect: { _ in })
        let primaryMenu = view.contextMenuItems(for: primary)
        #expect(try #require(primaryMenu.first { $0.title == "Lock Worktree" }).isEnabled == false)
        #expect(try #require(primaryMenu.first { $0.title == "Remove Worktree…" }).isEnabled == false)
        #expect(try #require(primaryMenu.first { $0.title == "Prune Stale Records" }).isEnabled)
        let lockedMenu = view.contextMenuItems(for: locked)
        #expect(try #require(lockedMenu.first { $0.title == "Unlock Worktree" }).isEnabled)
        #expect(try #require(lockedMenu.first { $0.title == "Remove Worktree…" }).isEnabled == false)
        let staleMenu = view.contextMenuItems(for: stale)
        #expect(try #require(staleMenu.first { $0.title == "Open in Current Window" }).isEnabled == false)
        #expect(try #require(staleMenu.first { $0.title == "Open in New Window" }).isEnabled == false)
        view.update(items: [locked, stale], selectedWorktreeID: nil, isPerformingWorktreeOperation: true, onSelect: { _ in })
        let busyMenu = view.contextMenuItems(for: locked)
        #expect(try #require(busyMenu.first { $0.title == "Unlock Worktree" }).isEnabled == false)
        #expect(try #require(busyMenu.first { $0.title == "Prune Stale Records" }).isEnabled == false)
        #expect(try #require(busyMenu.first { $0.title == "Copy Path" }).isEnabled)
    }

    @Test
    func commitMenuRetainsActionOwnerAndClickedCommit() throws {
        let commit = GitCommit(
            hash: "abcdef123456", shortHash: "abcdef1", parentHashes: [],
            authorName: "Test", authorEmail: "test@example.invalid", date: "", subject: "Test", decorations: ""
        )
        var received: [String] = []
        let menu = GitGraphRowActions(
            onSelect: { _ in Issue.record("Right click must not check out or change selection") },
            onCherryPick: { received.append("cherry:\($0.hash)") },
            onRevert: { received.append("revert:\($0.hash)") },
            onReset: { commit, mode in received.append("reset:\(mode.rawValue):\(commit.hash)") },
            onCreateTag: { received.append("tag:\($0.hash)") }
        ).contextMenuItems(for: commit)
        for title in ["New Tag…", "Cherry-pick Commit…", "Revert Commit…"] {
            try #require(menu.first { $0.title == title }).action()
        }
        let resetMenu = try #require(menu.first { $0.title == "Reset Current Branch to Here…" })
        guard case .submenu(let resetItems) = resetMenu.kind else {
            Issue.record("Reset should offer soft, mixed, and hard as a submenu")
            return
        }
        try #require(resetItems.first { $0.title == "Mixed Reset (Keep Changes Unstaged)" }).action()
        try #require(resetItems.first { $0.title == "Hard Reset (Discard Changes)" }).action()
        #expect(received == [
            "tag:abcdef123456", "cherry:abcdef123456", "revert:abcdef123456",
            "reset:mixed:abcdef123456", "reset:hard:abcdef123456"
        ])
    }

    @Test
    func contextMenusCannotSilentlyBypassSharedStyle() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let file as URL in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(source.range(of: #"\b(?:SwiftUI\.)?Menu\s*[({]"#, options: .regularExpression) == nil,
                    "Product dropdowns must use LitheMenu in \(file.lastPathComponent)")
            #expect(source.range(of: #"\.popover\s*\("#, options: .regularExpression) == nil,
                    "Product popups must use litheDropdown in \(file.lastPathComponent)")
            #expect(source.range(of: #"\bNSPopUpButton\s*\("#, options: .regularExpression) == nil,
                    "Value dropdowns must use LitheSettingsSelect in \(file.lastPathComponent)")
            if source.contains("Picker") {
                let pickers = source.matches(of: /\bPicker\s*\(/).count
                let segmented = source.matches(of: /\.pickerStyle\(\.segmented\)/).count
                #expect(pickers == segmented,
                        "Only segmented Pickers remain native in \(file.lastPathComponent); use LitheSettingsSelect for dropdowns")
            }
            #expect(source.range(of: #"\.contextMenu\s*[({]"#, options: .regularExpression) == nil,
                    "Use the shared context menu in \(file.lastPathComponent)")
            // Completion and source-action pickers are caret popups, not right-click menus.
            // All other AppKit menu construction must use the shared presenter.
            let withoutCaretPickers = source.replacingOccurrences(
                of: #"(?ms)^    func presentLanguage(?:Completions|CodeActions)\(.*?^    \}"#,
                with: "", options: .regularExpression
            )
            #expect(withoutCaretPickers.range(of: #"\bNSMenu\s*\("#, options: .regularExpression) == nil,
                    "Audit the native menu entry in \(file.lastPathComponent)")
        }
    }

    @Test
    func windowKeyboardSkipsDisabledItemsAndNavigatesSubmenus() throws {
        let presenter = LitheContextMenuPresenter()
        defer { presenter.dismiss() }
        var calls: [String] = []
        let items: [LitheContextMenuItem] = [
            .separator, .action("Disabled", isEnabled: false) { calls.append("disabled") },
            .action("Open") { calls.append("open") },
            .submenu("Move", items: [.separator, .action("Disabled", isEnabled: false) {},
                                     .action("Folder") { calls.append("folder") }])
        ]
        func show() throws -> NSWindow {
            presenter.show(items: items, at: NSPoint(x: 200, y: 300), appearance: nil, locale: Locale(identifier: "en"))
            return try #require(NSApp.windows.first { $0.isVisible && String(describing: type(of: $0)).contains("LitheContextMenuPanel") })
        }
        var window = try show()
        try sendKey(125, to: window)
        try sendKey(36, to: window)
        #expect(calls == ["open"])
        window = try show()
        try sendKey(126, to: window)
        try sendKey(124, to: window)
        try sendKey(123, to: window)
        try sendKey(124, to: window)
        try sendKey(36, to: window)
        #expect(calls == ["open", "folder"])
    }

    @Test(arguments: [false, true])
    func projectAndActionDropdownsRenderTheSameChrome(isDark: Bool) throws {
        // Capture the real panel: sharing tokens alone did not prevent the old
        // action-menu branch from rendering a different background and border.
        let menus: [[LitheContextMenuItem]] = [
            [.action("Project") {}, .action("Dependencies") {}],
            [.action("Fetch Options…") {},
             .action("Show Worktree Repositories", systemImage: "checkmark") {}]
        ]
        for items in menus {
            let presenter = LitheContextMenuPresenter()
            defer { presenter.dismiss() }
            presenter.show(items: items, at: NSPoint(x: 200, y: 300),
                           appearance: NSAppearance(named: isDark ? .darkAqua : .aqua),
                           locale: Locale(identifier: "en"))
            let window = try #require(NSApp.windows.first {
                $0.isVisible && String(describing: type(of: $0)).contains("LitheContextMenuPanel")
            })
            #expect(window.frame.height == 60)
            let host = try #require(window.contentView)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
            let y = bitmap.pixelsHigh / 2
            let probes: [(Int, UInt32)] = [
                (Int(3 * scale), isDark ? 0x2B2D30 : 0xFFFFFF),
                (0, isDark ? 0x4C4F56 : 0xE9EAEE)
            ]
            for (x, expected) in probes {
                let pixel = try #require(bitmap.colorAt(x: x, y: y))
                // AppKit caches in the display profile, while colorAt returns
                // generically tagged channels. Restore the bitmap's profile.
                let color = try #require(NSColor(colorSpace: bitmap.colorSpace,
                    components: [pixel.redComponent, pixel.greenComponent, pixel.blueComponent, pixel.alphaComponent],
                    count: 4).usingColorSpace(.sRGB))
                #expect(abs(color.redComponent - CGFloat((expected >> 16) & 255) / 255) < 0.01)
                #expect(abs(color.greenComponent - CGFloat((expected >> 8) & 255) / 255) < 0.01)
                #expect(abs(color.blueComponent - CGFloat(expected & 255) / 255) < 0.01)
            }
        }
    }

    @Test(arguments: [false, true])
    func submenuStartsAtItsTriggerRowAndKeepsCopyTitlesVisible(isDark: Bool) async throws {
        let fontURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Fonts/Inter-Regular.otf")
        let ownsFont = NSFont(name: "Inter-Regular", size: 12.5) == nil
        if ownsFont { #expect(CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)) }
        defer { if ownsFont { CTFontManagerUnregisterFontsForURL(fontURL as CFURL, .process, nil) } }
        let screen = try #require(NSScreen.main).visibleFrame
        let presenter = LitheContextMenuPresenter()
        defer { presenter.dismiss() }
        let items = (0..<8).map { LitheContextMenuItem.action("Close tab \($0)") {} }
            + [.separator, .submenu("Copy Path / Reference", items: [
                .action("Copy Path") {}, .action("Copy Relative Path") {}
            ]), .action("Show in Finder") {}]
        presenter.show(items: items, at: NSPoint(x: screen.midX, y: screen.maxY - 60),
                       appearance: NSAppearance(named: isDark ? .darkAqua : .aqua), locale: Locale(identifier: "en"))
        let window = try #require(NSApp.windows.first {
            $0.isVisible && String(describing: type(of: $0)).contains("LitheContextMenuPanel")
        })
        let rootFrame = window.frame
        let host = try #require(window.contentView)
        host.layoutSubtreeIfNeeded()
        // Select the ninth enabled item; separators do not consume keyboard steps.
        for _ in 0..<9 { try sendKey(125, to: window) }
        try sendKey(124, to: window)
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        #expect(window.frame.minX == rootFrame.minX)
        #expect(window.frame.maxY == rootFrame.maxY)
        #expect(window.frame.height == rootFrame.height)
        #expect(screen.contains(window.frame))
        let childWidth = window.frame.width - rootFrame.width - LitheDropdownMetrics.submenuSpacing
        let text = ImageRenderer(content: Text("Copy Relative Path")
            .font(LitheTheme.uiFont(size: LitheDropdownMetrics.fontSize)).fixedSize())
        let renderedTitle = try #require(text.cgImage)
        #expect(childWidth >= CGFloat(renderedTitle.width)
            + 2 * (LitheDropdownMetrics.popupPadding + LitheDropdownMetrics.itemHorizontalPadding) + 14 + 9)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        let childX = rootFrame.width + LitheDropdownMetrics.submenuSpacing + childWidth / 2
        let rowOffset = 8 * LitheDropdownMetrics.rowHeight + LitheDropdownMetrics.separatorHeight
        let aboveChild = try #require(bitmap.colorAt(x: Int(childX * scale), y: Int(20 * scale)))
        #expect(aboveChild.alphaComponent < 0.01, "A late submenu must not start at the root menu's top")
        let childRow = try #require(bitmap.colorAt(x: Int(childX * scale), y: Int((rowOffset + 10) * scale)))
        #expect(childRow.alphaComponent > 0.99, "The flyout must occupy its trigger row")
        if let directory = ProcessInfo.processInfo.environment["LITHE_SUBMENU_CAPTURE_DIR"] {
            let destination = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: destination.appendingPathComponent(isDark ? "submenu-dark.png" : "submenu-light.png"))
        }
    }

    @Test
    func longSubmenusStayOnScreenAndLastItemCanExecute() throws {
        let screen = try #require(NSScreen.main).visibleFrame
        for count in [20, 100] {
            let presenter = LitheContextMenuPresenter()
            defer { presenter.dismiss() }
            var selected = false
            let folders = (0..<count).map { index in LitheContextMenuItem.action("Folder \(index)") {} }
                + [.action("New Folder") { selected = true }]
            presenter.show(items: [.submenu("Move to Folder", items: folders)],
                           at: NSPoint(x: screen.midX, y: screen.minY + 250), appearance: nil,
                           locale: Locale(identifier: "en"))
            let window = try #require(NSApp.windows.first { $0.isVisible && String(describing: type(of: $0)).contains("LitheContextMenuPanel") })
            try sendKey(125, to: window)
            try sendKey(124, to: window)
            window.contentView?.layoutSubtreeIfNeeded()
            #expect(screen.contains(window.frame))
            try sendKey(126, to: window)
            try sendKey(36, to: window)
            #expect(selected)
        }
    }

    @Test
    func dynamicBranchTitleUsesExistingChineseFormat() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
        let bundle = try #require(Bundle(url: resources.appendingPathComponent("zh-Hans.lproj")))
        #expect(gitNewBranchMenuTitle("feature-demo", locale: Locale(identifier: "zh-Hans"), bundle: bundle)
                == "从“feature-demo”新建分支…")
    }

    private func sendKey(_ code: UInt16, to window: NSWindow) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "",
            charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
        window.sendEvent(event)
    }

    private func worktree(
        _ name: String, primary: Bool = false, current: Bool = false,
        locked: Bool = false, prunable: Bool = false
    ) -> GitWorktreeListItem {
        GitWorktreeListItem(worktree: GitWorktree(
            path: "/test/worktrees/\(name)", head: "abcdef", branch: "refs/heads/\(name)",
            isCurrent: current, isPrimary: primary, isBare: false, isDetached: false,
            isLocked: locked, lockReason: nil, isPrunable: prunable, pruneReason: nil
        ), status: .available)
    }
}

private struct DropdownToggleTestTrigger: View {
    let title: String
    let customContent: Bool
    @State private var isPresented = false

    private var label: some View {
        Text(title).frame(width: 180, height: 28).contentShape(Rectangle())
    }

    var body: some View {
        if customContent {
            Button { isPresented.toggle() } label: { label }
                .buttonStyle(.litheNoPress)
                .litheDropdown(isPresented: $isPresented) {
                    Text("Content").frame(width: 180, height: 48)
                }
        } else {
            LitheMenu { .action("Choose") {} } label: { label }
                .buttonStyle(.litheNoPress)
        }
    }
}

@MainActor
private final class DropdownEnvironmentProbe: ObservableObject {
    @Published var isPresented = false
    var renderedLocale: String?
}

private struct DropdownEnvironmentHarness: View {
    @ObservedObject var probe: DropdownEnvironmentProbe
    var body: some View {
        Text("Anchor")
            .frame(width: 220, height: 36)
            .litheDropdown(isPresented: $probe.isPresented) { DropdownEnvironmentContent() }
            .environmentObject(probe)
            .environment(\.locale, Locale(identifier: "zh-Hans"))
    }
}

private struct DropdownEnvironmentContent: View {
    @EnvironmentObject private var probe: DropdownEnvironmentProbe
    @Environment(\.locale) private var locale
    var body: some View {
        Text("Inherited environment").frame(width: 180, height: 48)
            .onAppear { probe.renderedLocale = locale.identifier }
    }
}

private struct TopbarDropdownHarness: View {
    @ObservedObject var probe: DropdownEnvironmentProbe
    let buttonHeight: CGFloat
    let searchOnTyping: Bool
    let content: AnyView

    var body: some View {
        Button("Anchor") {}.frame(width: 140, height: buttonHeight)
            .litheRowHover(isActive: probe.isPresented, cornerRadius: 6,
                           activeBackground: LitheTheme.hoverBackground)
            .buttonStyle(.litheNoPress)
            .frame(height: LitheTheme.Metrics.toolbarHeight)
            .litheDropdown(isPresented: $probe.isPresented, searchOnTyping: searchOnTyping) { content }
            .background(LitheTheme.raised)
    }
}
