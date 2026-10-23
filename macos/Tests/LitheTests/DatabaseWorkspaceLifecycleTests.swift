import AppKit
import Darwin
import LitheTestDesktopIsolation
import LitheApplicationKernel
@testable import LitheDatabaseModule
import LitheModuleAPI
import SwiftUI
import Testing
@testable import Lithe

@Suite("Database workspace lifecycle")
@MainActor
struct DatabaseWorkspaceLifecycleTests {
    @Test func newConnectionNamesUseDatabaseAndHostWithoutCredentials() {
        #expect(DatabaseConnectionEditor.defaultConnectionName(kind: .mysql, host: "127.0.0.1", database: "", path: "") == "@127.0.0.1")
        #expect(DatabaseConnectionEditor.defaultConnectionName(kind: .mysql, host: " localhost ", database: "foodmes", path: "") == "foodmes@localhost")
        #expect(DatabaseConnectionEditor.defaultConnectionName(kind: .sqlite, host: "", database: "", path: "/fixture/catalog.sqlite") == "catalog.sqlite")
        #expect(DatabaseConnectionEditor.defaultConnectionName(kind: .sqlite, host: "", database: "", path: "") == "SQLite")
        #expect(DatabaseConnectionEditor.defaultConnectionName(kind: .mongodb, host: "mongodb://fixture:secret@db.example.test/catalog?token=secret", database: "catalog", path: "") == "catalog@db.example.test")
    }

    @Test func passwordPersistenceMigratesWithoutWritingTemporarySecrets() throws {
        let preferences = DatabaseLifecyclePreferences()
        let secrets = DatabaseFolderSecrets()
        let store = DatabaseConnectionStore(store: preferences, secureStore: secrets)
        var profile = DatabaseProfile(name: "Fixture", kind: .mysql)
        let key = "database.connection.\(profile.id.uuidString).password"
        defer { try? store.deletePassword(for: profile.id) }
        try store.save([profile])
        try store.savePassword("fixture-permanent", for: profile.id)
        #expect(secrets.read(key: key) == "fixture-permanent")
        secrets.rejectChanges(true)
        #expect(throws: (any Error).self) { try store.savePassword("fixture-temporary", for: profile.id, persistence: .untilRestart) }
        #expect(store.password(for: profile.id) == "fixture-permanent")
        secrets.rejectChanges(false)
        profile.passwordPersistence = .untilRestart
        try store.savePassword("fixture-temporary", for: profile.id, persistence: .untilRestart)
        try store.save([profile])
        #expect(secrets.read(key: key) == nil)
        let reopened = DatabaseConnectionStore(store: preferences, secureStore: secrets)
        #expect(reopened.password(for: profile.id) == "fixture-temporary")
        #expect(reopened.hasPassword(for: profile.id))
        var restartProfile = DatabaseProfile(name: "Restarted", kind: .mysql)
        restartProfile.passwordPersistence = .untilRestart
        try store.save([profile, restartProfile])
        try secrets.write("obsolete-keychain-secret", key: "database.connection.\(restartProfile.id.uuidString).password")
        let keychainReads = secrets.readCount
        #expect(reopened.password(for: restartProfile.id).isEmpty)
        #expect(!reopened.hasPassword(for: restartProfile.id))
        #expect(secrets.readCount == keychainReads)
        let encoded = try JSONEncoder().encode(profile)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("fixture-temporary"))
        secrets.rejectChanges(true)
        #expect(throws: (any Error).self) { try store.savePassword("replacement", for: profile.id, persistence: .forever) }
        #expect(reopened.password(for: profile.id) == "fixture-temporary")
        #expect(secrets.read(key: key) == nil)
        secrets.rejectChanges(false)
        try store.savePassword(reopened.password(for: profile.id), for: profile.id, persistence: .forever)
        profile.passwordPersistence = .forever
        try store.save([profile])
        #expect(secrets.read(key: key) == "fixture-temporary")
        try store.deletePassword(for: profile.id)
        #expect(!reopened.hasPassword(for: profile.id))
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "passwordPersistence")
        #expect(try JSONDecoder().decode(DatabaseProfile.self, from: JSONSerialization.data(withJSONObject: legacy)).passwordPersistence == .forever)
    }

    @Test
    func databaseTreeRendersDarkTheme() async throws {
        try await databaseTreeRendersAndExpandsDatabasesIndependently(scheme: .dark)
    }

    @Test
    func databaseTreeRendersLightTheme() async throws {
        try await databaseTreeRendersAndExpandsDatabasesIndependently(scheme: .light)
    }

    @Test(arguments: [ColorScheme.dark, .light], ["en", "zh-Hans"])
    func connectionResultBalloonUsesDialogSurfaceAndPointer(scheme: ColorScheme, language: String) throws {
        MacBundledFontRegistry.registerFonts()
        let summary = language == "en" ? "DBMS: MySQL\n\nConnection test duration: 11 ms" : "DBMS: MySQL\n\n连接检测耗时：11 毫秒"
        let host = NSHostingView(rootView: DatabaseConnectionResultView(summary: summary, pointerX: 90)
            .environment(\.colorScheme, scheme).environment(\.locale, Locale(identifier: language)))
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        #expect(host.bounds.width == 728)
        #expect(host.bounds.height > 90 && host.bounds.height < 160)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        func color(_ x: CGFloat, _ y: CGFloat) throws -> NSColor {
            try #require(bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB))
        }
        func expectColor(_ hex: UInt32, x: CGFloat, y: CGFloat) throws {
            let actual = try color(x, y)
            #expect(abs(actual.redComponent - CGFloat((hex >> 16) & 255) / 255) < 0.01)
            #expect(abs(actual.greenComponent - CGFloat((hex >> 8) & 255) / 255) < 0.01)
            #expect(abs(actual.blueComponent - CGFloat(hex & 255) / 255) < 0.01)
        }
        let background: UInt32 = scheme == .dark ? 0x191A1C : 0xF7F8F9
        try expectColor(background, x: 400, y: host.bounds.height - 16)
        // Integer-aligned upstream edges cover half the first pixel at 1x, unlike a half-point inset.
        let border: UInt32 = scheme == .dark ? 0x33353B : 0xDDDFE4
        let edge = try color(400, 0)
        for (component, shift) in [(edge.redComponent, 16), (edge.greenComponent, 8), (edge.blueComponent, 0)] {
            let expected = scale == 1
                ? CGFloat(((background >> shift) & 255) + ((border >> shift) & 255)) / 510
                : CGFloat((border >> shift) & 255) / 255
            #expect(abs(component - expected) < 0.01)
        }
        // The tail is filled continuously; the surrounding bottom strip stays transparent.
        try expectColor(background, x: 90, y: host.bounds.height - 5)
        #expect(try color(400, host.bounds.height - 5).alphaComponent < 0.01)
        #expect(try color(host.bounds.width - 1, 0).alphaComponent < 0.01)
        if let directory = ProcessInfo.processInfo.environment["LITHE_DATABASE_TREE_SCREENSHOTS"] {
            try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                URL(fileURLWithPath: directory).appendingPathComponent("database-result-\(scheme == .dark ? "dark" : "light")-\(language).png"))
        }
    }

    @Test(arguments: [ColorScheme.dark, .light])
    func connectionEditorTabsAndTestAction(scheme: ColorScheme) async throws {
        let store = DatabaseConnectionStore(store: DatabaseLifecyclePreferences(), secureStore: DatabaseLifecycleSecrets())
        let feature = DatabaseFeatureModel(operations: DatabaseSidecarService(processRunner: TableEditsWorkspaceRunner(),
            executableURL: URL(fileURLWithPath: "/fixture/database")), connectionStore: store)
        defer { feature.prepareForModuleRelease() }
        let app = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = (app.accessibilityAttributeValue(attribute) as? Bool) ?? false
        app.accessibilitySetValue(true, forAttribute: attribute)
        defer { app.accessibilitySetValue(previous, forAttribute: attribute) }
        let host = NSHostingView(rootView: DatabaseConnectionEditor(isPresented: .constant(true), profile: DatabaseProfile(name: "Nacos", kind: .nacos, port: 8848, username: "", path: "/nacos"))
            .environmentObject(feature).environment(\.colorScheme, scheme).environment(\.locale, Locale(identifier: "en")))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 580), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        func elements(_ element: Any) -> [AnyObject] {
            let accessible = element as AnyObject
            return [accessible] + (accessible.accessibilityChildren?() ?? []).flatMap(elements)
        }
        func element(_ label: String) -> AnyObject? {
            (elements(host) + (window.childWindows ?? []).flatMap { $0.contentView.map(elements) ?? [] }).first {
                let title: String = $0.accessibilityLabel?() ?? $0.accessibilityTitle?() ?? ""
                // SwiftUI AX nodes expose the selector without adopting the public static-text protocol.
                let object = $0 as? NSObject
                let selector = NSSelectorFromString("accessibilityValue")
                let value = object?.responds(to: selector) == true ? object?.perform(selector)?.takeUnretainedValue() as? String : nil
                return title == label || value == label
            }
        }
        func waitFor(_ condition: () -> Bool) async -> Bool {
            let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(2))
            repeat {
                host.layoutSubtreeIfNeeded()
                if condition() { return true }
                await Task.yield()
            } while clock.now < deadline
            return condition()
        }
        func capture(_ tab: String) throws {
            guard let directory = ProcessInfo.processInfo.environment["LITHE_DATABASE_TREE_SCREENSHOTS"],
                  let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                URL(fileURLWithPath: directory).appendingPathComponent("database-editor-\(tab)-\(scheme == .dark ? "dark" : "light").png"))
        }
        try #require(await waitFor { element("API context path") != nil })
        let generalFrame = host.frame
        let fields = elements(host).filter { $0.accessibilityRole?() == .textField }
        func inputFrame(_ label: String) throws -> NSRect {
            try #require(fields.first { $0.accessibilityLabel?() == label }?.accessibilityFrame?())
        }
        let hostInput = try inputFrame("Host")
        for label in ["Username (optional)", "Password"] {
            let frame = try inputFrame(label)
            #expect(abs(frame.minX - hostInput.minX) < 1)
            #expect(abs(frame.width - hostInput.width) < 1)
        }
        #expect(try #require(element("Test Connection")).accessibilityPerformPress?() == true)
        try #require(await waitFor { element("Connection successful") != nil })
        #expect(store.load().isEmpty && feature.selectedProfileID == nil)
        #expect(element("Copy") != nil)
        let resultWindow = try #require(window.childWindows?.first(where: { $0.isVisible }))
        #expect(resultWindow.hasShadow == false)
        try #require(await waitFor { LitheTestRequestedWindowAlpha(resultWindow) == 1 })
        if let directory = ProcessInfo.processInfo.environment["LITHE_DATABASE_TREE_SCREENSHOTS"],
           let popup = window.childWindows?.first(where: { $0.isVisible }), let content = popup.contentView,
           let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                URL(fileURLWithPath: directory).appendingPathComponent("database-connection-success-\(scheme == .dark ? "dark" : "light").png"))
        }
        let pasteboard = NSPasteboard.general
        let savedClipboard = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { result, type in result[type] = item.data(forType: type) }
        }
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(savedClipboard.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            })
        }
        #expect(try #require(element("Copy")).accessibilityPerformPress?() == true)
        try #require(await waitFor { element("Connection successful") == nil })
        #expect(pasteboard.string(forType: .string)?.hasPrefix("DBMS: Nacos") == true)
        #expect(try #require(element("Connection test result")).accessibilityPerformPress?() == true)
        try #require(await waitFor { element("Connection successful") != nil })
        #expect(try #require(element("Connection test result")).accessibilityPerformPress?() == true)
        try #require(await waitFor { element("Connection successful") == nil })
        #expect(try #require(element("Connection test result")).accessibilityPerformPress?() == true)
        try #require(await waitFor { element("Connection successful") != nil })
        #expect(try #require(element("Connection test result")).accessibilityPerformPress?() == true)
        try #require(await waitFor { element("Connection successful") == nil })
        try capture("general")
        #expect(try #require(element("SSH / TLS")).accessibilityPerformPress?() == true)
        try #require(await waitFor { element("Use TLS") != nil && element("API context path") == nil })
        #expect(host.frame == generalFrame)
        let nameLabelFrame = try #require(element("Name")?.accessibilityFrame?())
        let tlsLabelFrame = try #require(element("Use TLS")?.accessibilityFrame?())
        #expect(abs(nameLabelFrame.minX - tlsLabelFrame.minX) < 1)
        try capture("network")
        #expect(try #require(element("Safety and Labels")).accessibilityPerformPress?() == true)
        try #require(await waitFor { element("Read-only connection") != nil })
        #expect(host.frame == generalFrame)
        try capture("safety")
        #expect(try #require(element("General")).accessibilityPerformPress?() == true)
        try #require(await waitFor { element("API context path") != nil })
    }

    private func databaseTreeRendersAndExpandsDatabasesIndependently(scheme: ColorScheme) async throws {
        let runner = DatabaseTreeRunner()
        let preferences = DatabaseLifecyclePreferences()
        let store = DatabaseConnectionStore(store: preferences, secureStore: DatabaseLifecycleSecrets())
        let folder = DatabaseConnectionFolder(name: "Development")
        let profile = DatabaseProfile(name: "Local MySQL", kind: .mysql, folderID: folder.id)
        let sqlite = DatabaseProfile(name: "SQLite cache", kind: .sqlite, path: "/fixture/cache.db")
        try store.save([profile, sqlite]); try store.saveFolders([folder])
        let recoveryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: recoveryRoot) }
        let feature = DatabaseFeatureModel(operations: DatabaseSidecarService(processRunner: runner, executableURL: URL(fileURLWithPath: "/fixture/database")), connectionStore: store, recoveryStore: MacDatabaseRecoveryStore(rootURL: recoveryRoot))
        defer { feature.prepareForModuleRelease() }
        await feature.loadDatabaseTree(for: profile.id)
        let settings = AppSettings(store: preferences)
        let model = AppModel(settings: settings, services: MacServiceContainer(store: preferences, settings: settings, moduleLaunchMode: .safeMode).services)
        model.cacheModuleCapability(DatabaseModuleCapability(feature: feature), id: .databaseWorkspace, moduleID: .database)
        let application = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAccessibility = (application.accessibilityAttributeValue(attribute) as? Bool) ?? false
        application.accessibilitySetValue(true, forAttribute: attribute)
        defer { application.accessibilitySetValue(previousAccessibility, forAttribute: attribute) }
        if ProcessInfo.processInfo.environment["LITHE_DATABASE_TREE_SCREENSHOTS"] != nil {
            MacBundledFontRegistry.registerFonts()
            #expect(NSFont(name: "Inter-Regular", size: 13) != nil)
            for kind in DatabaseKind.allCases {
                let filename = kind.brandIconFilename as NSString
                let url = try #require(Bundle.main.url(forResource: filename.deletingPathExtension,
                    withExtension: filename.pathExtension, subdirectory: "DatabaseIcons"))
                #expect(NSImage(contentsOf: url) != nil)
            }
        }
        let host = NSHostingView(rootView: DatabaseSidebarView()
            .environmentObject(feature).environmentObject(model).environmentObject(settings)
            .environment(\.colorScheme, scheme).environment(\.locale, Locale(identifier: "en"))
            .background(LitheTheme.sidebar).frame(width: 320, height: 620))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        let originalWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        defer {
            for popup in NSApp.windows where !originalWindows.contains(ObjectIdentifier(popup)) {
                if let menu = popup.delegate as? LitheContextMenuPresenter { menu.dismiss() }
                else if let centered = popup.delegate as? LitheCenteredPopupPresenter { centered.close() }
            }
        }
        func buttons(_ element: Any) -> [AnyObject] {
            let accessible = element as AnyObject
            return (accessible.accessibilityRole?() == .button ? [accessible] : [])
                + (accessible.accessibilityChildren?() ?? []).flatMap { buttons($0) }
        }
        func button(_ label: String) -> AnyObject? {
            buttons(host).first {
                let title = $0.accessibilityLabel?() ?? $0.accessibilityTitle?() ?? ""
                return title == label || (["Local MySQL", "SQLite cache"].contains(label) && title.contains(label))
            }
        }
        func waitForView(_ condition: () -> Bool) async -> Bool {
            let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(3))
            repeat {
                host.layoutSubtreeIfNeeded()
                if condition() { return true }
                await Task.yield()
            } while clock.now < deadline
            return condition()
        }
        #expect(await waitForView { button("Expand connection") != nil })
        let connectionButton = try #require(button("Expand connection"))
        #expect(connectionButton.accessibilityPerformPress?() == true)
        #expect(await waitForView { button("Collapse connection") != nil })
        #expect(feature.selectedProfileID == nil) // Disclosure must not navigate or open the editor.
        window.makeKeyAndOrderFront(nil)
        func doubleClick(_ label: String, trailingSpace: Bool = false) async throws {
            let name = try #require(button(label))
            let screenFrame = try #require(name.accessibilityFrame?())
            let x = trailingSpace ? window.frame.maxX - LitheTheme.Tree.horizontalInset - 16 : screenFrame.midX
            let location = window.convertPoint(fromScreen: NSPoint(x: x, y: screenFrame.midY))
            for count in 1...2 {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try #require(NSEvent.mouseEvent(with: type, location: location,
                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                        clickCount: count, pressure: type == .leftMouseDown ? 1 : 0))
                    window.sendEvent(event)
                    await Task.yield()
                }
            }
        }
        #expect(try #require(button("Development")).accessibilityPerformPress?() == true)
        #expect(button("Local MySQL") != nil)
        try await doubleClick("Development")
        #expect(await waitForView { button("Local MySQL") == nil })
        try await doubleClick("Development")
        #expect(await waitForView { button("Local MySQL") != nil })
        try await doubleClick("Local MySQL")
        #expect(await waitForView { button("Expand connection") != nil && button("Expand database alpha") == nil })
        try await doubleClick("Local MySQL")
        #expect(await waitForView { button("Collapse connection") != nil && button("Expand database alpha") != nil })
        for database in ["alpha", "beta"] {
            #expect(await waitForView { button("Expand database \(database)") != nil })
            let disclosure = try #require(button("Expand database \(database)"))
            #expect(disclosure.accessibilityPerformPress?() == true)
        }
        #expect(await waitForView { button("alpha_only") != nil && button("beta_only") != nil })
        for _ in 0..<2 {
            #expect(try #require(button("alpha")).accessibilityPerformPress?() == true)
            #expect(button("alpha_only") != nil)
            try await doubleClick("alpha")
            #expect(await waitForView { button("alpha_only") == nil && button("beta_only") != nil })
            try await doubleClick("alpha")
            #expect(await waitForView { button("alpha_only") != nil })
            try await doubleClick("Tables")
            #expect(await waitForView { button("alpha_only") == nil && button("beta_only") != nil })
            try await doubleClick("Tables")
            #expect(await waitForView { button("alpha_only") != nil })
        }
        #expect(buttons(host).filter { ($0.accessibilityLabel?() ?? $0.accessibilityTitle?()) == "shared" }.count == 2)
        #expect(feature.selectedTable == nil) // Connection double-click must not open table data.
        func selectedRowCount() throws -> Int {
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            // Compare against the same native capture path; NSBitmapImageRep applies the display color profile.
            let referenceHeight = LitheTheme.Tree.rowHeight * 2
            let reference = NSHostingView(rootView: VStack(spacing: 0) {
                Color.clear.litheTreeRow(isSelected: true, isFocused: false)
                Color.clear.litheTreeRow(isSelected: true, isFocused: true)
            }.environment(\.colorScheme, scheme).environment(\.controlActiveState, .key)
                .frame(width: 320, height: referenceHeight))
            let referenceWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: referenceHeight), styleMask: [.borderless], backing: .buffered, defer: false)
            referenceWindow.isReleasedWhenClosed = false
            referenceWindow.appearance = window.appearance
            referenceWindow.contentView = reference
            defer { referenceWindow.contentView = nil; referenceWindow.close() }
            reference.layoutSubtreeIfNeeded()
            let referenceBitmap = try #require(reference.bitmapImageRepForCachingDisplay(in: reference.bounds))
            reference.cacheDisplay(in: reference.bounds, to: referenceBitmap)
            let referenceX = Int(280 * CGFloat(referenceBitmap.pixelsWide) / reference.bounds.width)
            let colors = try [1, 3].map { quarter in
                try #require(referenceBitmap.colorAt(x: referenceX, y: referenceBitmap.pixelsHigh * quarter / 4)?.usingColorSpace(.sRGB))
            }
            let x = Int(280 * CGFloat(bitmap.pixelsWide) / host.bounds.width)
            let rowPixels = Int(LitheTheme.Tree.rowHeight * CGFloat(bitmap.pixelsWide) / host.bounds.width)
            var runs = 0, runLength = 0
            func finishBand() {
                // The light header separator shares the inactive color; only full-height row bands are selections.
                if runLength >= rowPixels - 1 { runs += Int((Double(runLength) / Double(rowPixels)).rounded()) }
                runLength = 0
            }
            for y in 0..<bitmap.pixelsHigh {
                let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                let selected = colors.contains { expected in
                    let redMatches = abs(color.redComponent - expected.redComponent) < 0.006
                    let greenMatches = abs(color.greenComponent - expected.greenComponent) < 0.006
                    let blueMatches = abs(color.blueComponent - expected.blueComponent) < 0.006
                    return redMatches && greenMatches && blueMatches && color.alphaComponent > 0.99
                }
                if selected { runLength += 1 }
                else { finishBand() }
            }
            finishBand()
            if runs != 1 { print("Database tree selection render: \(runs) highlight bands; reference colors: \(colors)") }
            return runs
        }
        let serverRow = try #require(button("Local MySQL"))
        #expect(serverRow.accessibilityPerformPress?() == true)
        #expect(await waitForView { feature.selectedProfileID == profile.id && !feature.isLoading })
        #expect(try selectedRowCount() == 1)
        let databaseRow = try #require(button("beta"))
        #expect(databaseRow.accessibilityPerformPress?() == true)
        #expect(await waitForView { !feature.isLoading })
        #expect(feature.selectedProfile?.database == profile.database) // Tree selection must not navigate the editor.
        #expect(try selectedRowCount() == 1) // The parent connection must relinquish selection.
        if let directory = ProcessInfo.processInfo.environment["LITHE_DATABASE_TREE_SCREENSHOTS"] {
            // Screenshots are accepted only with the real bundled SVGs and fonts staged at build time.
            #expect(LitheIcons.ideaImage(resourcePath: "database/expui/schema.svg") != nil)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            let destination = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try png.write(to: destination.appendingPathComponent("database-tree-\(scheme == .dark ? "dark" : "light").png"))
        }
        let tableRow = try #require(button("beta_only"))
        #expect(tableRow.accessibilityPerformPress?() == true)
        #expect(await waitForView { button("beta_only") != nil })
        #expect(feature.selectedTable == nil)
        #expect(try selectedRowCount() == 1) // Neither ancestor may stay selected when the table is selected.
        let beforeRefresh = runner.requests.count
        #expect(try #require(button("Refresh selected structure")).accessibilityPerformPress?() == true)
        let betaKey = DatabaseTreeTableKey(profileID: profile.id, database: "beta", table: "beta_only")
        #expect(await waitForView { feature.tableTrees[betaKey]?.state == .ready })
        #expect(runner.requests.dropFirst(beforeRefresh).allSatisfy {
            $0.database == "beta" && ["describeTable", "listIndexes", "listForeignKeys"].contains($0.method)
        })
        let requestCount = runner.requests.count
        runner.blockedMethod = "describeTable"
        runner.blocks = true
        defer { runner.release.open() }
        let expandTable = try #require(button("Expand table alpha_only"))
        #expect(expandTable.accessibilityPerformPress?() == true)
        #expect(await runner.entered.waitUntilOpen())
        let metadataKey = DatabaseTreeTableKey(profileID: profile.id, database: "alpha", table: "alpha_only")
        #expect(feature.tableTrees[metadataKey]?.state == .loading)
        #expect(feature.selectedProfile?.database == profile.database && feature.selectedTable == nil)
        func hasLoadingRow(_ element: Any) -> Bool {
            let accessible = element as AnyObject
            return accessible.accessibilityLabel?() == "Loading…"
                || (accessible.accessibilityChildren?() ?? []).contains { hasLoadingRow($0) }
        }
        #expect(await waitForView { button("Collapse table alpha_only") != nil && hasLoadingRow(host) })
        if let directory = ProcessInfo.processInfo.environment["LITHE_DATABASE_TREE_SCREENSHOTS"] {
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent("database-tree-loading-\(scheme == .dark ? "dark" : "light").png"))
        }
        #expect(!runner.requests.dropFirst(requestCount).contains { $0.method == "pageTable" })
        let collapseTable = try #require(button("Collapse table alpha_only"))
        #expect(collapseTable.accessibilityPerformPress?() == true)
        #expect(await waitForView { button("Expand table alpha_only") != nil && !hasLoadingRow(host) })
        runner.release.open()
        #expect(await waitForView { feature.tableTrees[metadataKey]?.state == .ready })
        // A late response must not reopen the collapsed node, and reopening must use its cache.
        #expect(button("Collapse table alpha_only") == nil)
        let completedRequests = runner.requests.count
        let reopen = try #require(button("Expand table alpha_only"))
        #expect(reopen.accessibilityPerformPress?() == true)
        #expect(await waitForView { button("Collapse table alpha_only") != nil })
        #expect(runner.requests.count == completedRequests)
        let collapse = try #require(button("Collapse database alpha"))
        #expect(collapse.accessibilityPerformPress?() == true)
        #expect(await waitForView { button("alpha_only") == nil && button("beta_only") != nil })
        try await doubleClick("beta_only")
        #expect(await waitForView { feature.selectedTable == "beta_only" && !feature.isLoading })
        #expect(feature.selectedProfile?.database == "beta")
        #expect(button("Expand table beta_only") != nil) // Double-click opens data, not table structure.
        try await doubleClick("Local MySQL")
        #expect(await waitForView { button("beta_only") == nil })
        try await doubleClick("SQLite cache")
        #expect(await waitForView { button("Default database") != nil && button("_only") != nil })
        for _ in 0..<2 {
            try await doubleClick("Default database")
            #expect(await waitForView { button("_only") == nil })
            try await doubleClick("Default database")
            #expect(await waitForView { button("_only") != nil })
            #expect(try #require(button("Tables")).accessibilityPerformPress?() == true)
            #expect(button("_only") != nil)
            try await doubleClick("Tables")
            #expect(await waitForView { button("_only") == nil })
            try await doubleClick("Tables")
            #expect(await waitForView { button("_only") != nil })
        }
        runner.includesObjects = true
        await feature.refreshTables()
        for title in ["Views", "Routines", "Triggers", "Sequences"] {
            #expect(await waitForView { button(title) != nil })
            #expect(try #require(button(title)).accessibilityPerformPress?() == true)
            for _ in 0..<2 {
                #expect(button("Collapse \(title)") != nil)
                try await doubleClick(title)
                #expect(await waitForView { button("Expand \(title)") != nil })
                try await doubleClick(title)
                #expect(await waitForView { button("Collapse \(title)") != nil })
            }
        }
        func popupButton(_ label: String) -> AnyObject? {
            NSApp.windows.filter { $0.isVisible && $0 !== window }.flatMap { candidate in
                candidate.contentView?.layoutSubtreeIfNeeded()
                return buttons(candidate)
            }.first { ($0.accessibilityLabel?() ?? $0.accessibilityTitle?()) == label }
        }
        func rightClick(at point: NSPoint) throws {
            func captures(_ view: NSView) -> [NSView] {
                (String(describing: type(of: view)).contains("LitheRightClickCaptureView") ? [view] : [])
                    + view.subviews.flatMap(captures)
            }
            let matching = captures(host).filter {
                $0.bounds.contains($0.convert(point, from: nil))
            }
            if matching.isEmpty {
                print("Missing context capture at \(point), host \(host.bounds), captures \(captures(host).map { $0.convert($0.bounds, to: nil) })")
            }
            let capture = try #require(matching.min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height })
            // SwiftPM has no application event loop; dispatch to the existing native capture at this row.
            capture.rightMouseDown(with: try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 0)))
        }
        func openMovePicker() async throws {
            let name = try #require(button("SQLite cache"))
            let rect = try #require(name.accessibilityFrame?())
            try rightClick(at: window.convertPoint(fromScreen: NSPoint(x: rect.midX, y: rect.midY)))
            #expect(await waitForView { popupButton("Move") != nil })
            #expect(try #require(popupButton("Move")).accessibilityPerformPress?() == true)
            #expect(await waitForView { popupButton("To Folder…") != nil })
            #expect(try #require(popupButton("To Folder…")).accessibilityPerformPress?() == true)
        }
        @discardableResult
        func submitName(_ name: String, confirm: Bool = true) async throws -> NSWindow {
            #expect(await waitForView { NSApp.windows.contains { $0.isVisible && $0.firstResponder is NSTextView } })
            let popup = try #require(NSApp.windows.first { $0.isVisible && $0.firstResponder is NSTextView })
            let editor = try #require(popup.firstResponder as? NSTextView)
            editor.selectAll(nil); editor.insertText(name, replacementRange: editor.selectedRange())
            await Task.yield()
            popup.sendEvent(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: popup.windowNumber, context: nil,
                characters: confirm ? "\r" : "\u{1B}", charactersIgnoringModifiers: confirm ? "\r" : "\u{1B}",
                isARepeat: false, keyCode: confirm ? 36 : 53)))
            return popup
        }
        try await openMovePicker()
        #expect(await waitForView { popupButton("Development") != nil })
        #expect(try #require(popupButton("Development")).accessibilityPerformPress?() == true)
        #expect(await waitForView { feature.profiles.first { $0.id == sqlite.id }?.folderID == folder.id })
        try await openMovePicker()
        #expect(await waitForView { popupButton("New Folder…") != nil })
        #expect(try #require(popupButton("New Folder…")).accessibilityPerformPress?() == true)
        try await submitName("QA/Shared")
        #expect(await waitForView {
            guard let target = feature.folders.first(where: { $0.name == "Shared" }) else { return false }
            return feature.profiles.first { $0.id == sqlite.id }?.folderID == target.id
        })
        #expect(feature.folders.contains { $0.name == "QA" })
        let folderCount = feature.folders.count
        #expect(try #require(button("New Folder")).accessibilityPerformPress?() == true)
        let rejectedPopup = try await submitName("QA/Shared")
        #expect(await waitForView { feature.errorMessage == "A folder with this name already exists." })
        #expect(await waitForView { rejectedPopup.frame.height > 78 }) // Inline validation must fit below the name field.
        #expect(feature.folders.count == folderCount)
        try await submitName("Cancelled", confirm: false)
        #expect(await waitForView { !rejectedPopup.isVisible })
        #expect(feature.folders.count == folderCount)
        func popupElement(_ label: String) -> AnyObject? {
            func elements(_ element: Any) -> [AnyObject] {
                let accessible = element as AnyObject
                return [accessible] + (accessible.accessibilityChildren?() ?? []).flatMap(elements)
            }
            return NSApp.windows.filter { $0.isVisible && $0 !== window }.flatMap { popup in
                popup.contentView?.layoutSubtreeIfNeeded()
                return elements(popup)
            }.first { ($0.accessibilityLabel?() ?? $0.accessibilityTitle?()) == label }
        }
        func schemaPopupKey(_ keyCode: UInt16, characters typed: String? = nil) throws {
            let popup = try #require(NSApp.windows.first { $0.isVisible && $0.parent === window && $0.delegate is LitheContextMenuPresenter })
            let characters = typed ?? (keyCode == 53 ? "\u{1B}" : "\r")
            popup.sendEvent(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: popup.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)))
        }
        #expect(try #require(button("Select databases")).accessibilityPerformPress?() == true)
        #expect(await waitForView { popupElement("All schemas") != nil })
        if let directory = ProcessInfo.processInfo.environment["LITHE_DATABASE_TREE_SCREENSHOTS"],
           let popup = NSApp.windows.first(where: { $0.isVisible && $0 !== window && $0.parent === window }),
           let content = popup.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                URL(fileURLWithPath: directory).appendingPathComponent("database-schema-selector-\(scheme == .dark ? "dark" : "light").png"))
        }
        // The unified checkbox row is clickable even in the empty area beyond its label.
        let scopePopup = try #require(NSApp.windows.first { $0.isVisible && $0.parent === window && $0.delegate is LitheContextMenuPresenter })
        let betaCheckbox = try #require(popupElement("beta"))
        let betaFrame = try #require(betaCheckbox.accessibilityFrame?())
        #expect(betaFrame.width >= LitheDropdownMetrics.maximumWidth - 2 * LitheTheme.Tree.horizontalInset - LitheTheme.Tree.indent)
        #expect(betaFrame.height == LitheDropdownMetrics.rowHeight)
        let rowEnd = scopePopup.convertPoint(fromScreen: NSPoint(x: betaFrame.maxX - 4, y: betaFrame.midY))
        for expected in [0, 1] {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                scopePopup.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: rowEnd, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: scopePopup.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 0)))
            }
            #expect(await waitForView {
                guard let checkbox = popupElement("beta") as? NSObject,
                      checkbox.responds(to: NSSelectorFromString("accessibilityValue")) else { return false }
                return (checkbox.perform(NSSelectorFromString("accessibilityValue"))?.takeUnretainedValue() as? NSNumber)?.intValue == expected
            })
        }
        #expect(feature.visibleDatabaseNames(for: profile.id) == ["alpha", "beta"]) // Still a draft until applied.
        // A native key event reveals the initially collapsed search field and filters the list.
        try schemaPopupKey(11, characters: "b")
        #expect(await waitForView { popupElement("alpha") == nil && popupElement("beta") != nil })
        try schemaPopupKey(53)
        #expect(await waitForView { popupElement("All schemas") == nil })
        #expect(try #require(button("Select databases")).accessibilityPerformPress?() == true)
        #expect(await waitForView { popupElement("alpha") != nil && popupElement("beta") != nil })
        #expect(try #require(popupElement("beta")).accessibilityPerformPress?() == true)
        try schemaPopupKey(36)
        #expect(await waitForView { feature.visibleDatabaseNames(for: profile.id) == ["alpha"] })
        #expect(store.load().first { $0.id == profile.id }?.visibleDatabases == ["alpha"])
        // Exercise the rendered badge in Chinese: its count must not use the global ordinal translation.
        host.rootView = DatabaseSidebarView()
            .environmentObject(feature).environmentObject(model).environmentObject(settings)
            .environment(\.colorScheme, scheme).environment(\.locale, Locale(identifier: "zh-Hans"))
            .background(LitheTheme.sidebar).frame(width: 320, height: 620)
        func scopeBadge() -> NSObject? {
            buttons(host).first { ($0.accessibilityIdentifier?() ?? "") == "database-schema-scope" } as? NSObject
        }
        #expect(await waitForView { scopeBadge() != nil })
        let badge = try #require(scopeBadge())
        let valueSelector = NSSelectorFromString("accessibilityValue")
        #expect(badge.responds(to: valueSelector))
        #expect(badge.perform(valueSelector)?.takeUnretainedValue() as? String == "1 of 2")
        let badgeFrame = try #require((badge as AnyObject).accessibilityFrame?())
        #expect(badgeFrame.height == LitheTheme.Tree.rowHeight)
        if let directory = ProcessInfo.processInfo.environment["LITHE_DATABASE_TREE_SCREENSHOTS"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                URL(fileURLWithPath: directory).appendingPathComponent("database-scope-chinese-\(scheme == .dark ? "dark" : "light").png"))
        }
        host.rootView = DatabaseSidebarView()
            .environmentObject(feature).environmentObject(model).environmentObject(settings)
            .environment(\.colorScheme, scheme).environment(\.locale, Locale(identifier: "en"))
            .background(LitheTheme.sidebar).frame(width: 320, height: 620)
        #expect(await waitForView { button("Select databases") != nil })
        try await doubleClick("Local MySQL")
        #expect(await waitForView { button("alpha") != nil && button("beta") == nil })
        // Escape cancels the draft selection rather than changing the stored scope.
        #expect(try #require(button("Select databases")).accessibilityPerformPress?() == true)
        #expect(await waitForView { popupElement("All schemas") != nil })
        #expect(try #require(popupElement("All schemas")).accessibilityPerformPress?() == true)
        try schemaPopupKey(53)
        #expect(await waitForView { popupElement("All schemas") == nil })
        #expect(feature.visibleDatabaseNames(for: profile.id) == ["alpha"])
        #expect(try #require(button("Select databases")).accessibilityPerformPress?() == true)
        #expect(await waitForView { popupElement("All schemas") != nil })
        #expect(try #require(popupElement("All schemas")).accessibilityPerformPress?() == true)
        try schemaPopupKey(36)
        #expect(await waitForView { popupElement("All schemas") == nil && feature.visibleDatabaseNames(for: profile.id) == ["alpha", "beta"] })
        // Clicking away applies the draft. Escape above must still cancel it.
        #expect(try #require(button("Select databases")).accessibilityPerformPress?() == true)
        #expect(await waitForView { popupElement("beta") != nil })
        #expect(popupButton("Apply") == nil && popupButton("Cancel") == nil)
        #expect(try #require(popupElement("beta")).accessibilityPerformPress?() == true)
        window.makeKeyAndOrderFront(nil)
        #expect(await waitForView { popupElement("All schemas") == nil && feature.visibleDatabaseNames(for: profile.id) == ["alpha"] })
        #expect(store.load().first { $0.id == profile.id }?.visibleDatabases == ["alpha"])
        // The trigger owns its own close; a second click must not reset the draft and reopen it.
        #expect(try #require(button("Select databases")).accessibilityPerformPress?() == true)
        #expect(await waitForView { popupElement("All schemas") != nil })
        #expect(try #require(popupElement("All schemas")).accessibilityPerformPress?() == true)
        #expect(try #require(button("Select databases")).accessibilityPerformPress?() == true)
        #expect(await waitForView { popupElement("All schemas") == nil && feature.visibleDatabaseNames(for: profile.id) == ["alpha", "beta"] })
        // The plus opens the shared New menu; engine selection configures a new, unsaved connection.
        #expect(try #require(button("New")).accessibilityPerformPress?() == true)
        try #require(await waitForView { popupButton("Data Source") != nil && popupButton("Query Console") != nil })
        #expect(popupButton("Folder") != nil && popupButton("Import Data Sources…") != nil)
        if let directory = ProcessInfo.processInfo.environment["LITHE_DATABASE_TREE_SCREENSHOTS"],
           let menu = NSApp.windows.first(where: { $0.isVisible && $0.delegate is LitheContextMenuPresenter }),
           let content = menu.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                URL(fileURLWithPath: directory).appendingPathComponent("database-new-menu-\(scheme == .dark ? "dark" : "light").png"))
        }
        #expect(try #require(popupButton("Data Source")).accessibilityPerformPress?() == true)
        try #require(await waitForView { popupButton("SQLite") != nil })
        for name in ["MySQL", "MariaDB", "PostgreSQL", "SQLite", "SQL Server", "MongoDB", "Redis", "Nacos"] {
            #expect(popupButton(name) != nil)
        }
        #expect(try #require(popupButton("SQLite")).accessibilityPerformPress?() == true)
        func connectionPanel() -> NSWindow? {
            NSApp.windows.first { $0.isVisible && $0.parent === window && $0.delegate is LitheCenteredPopupPresenter }
        }
        try #require(await waitForView { connectionPanel() != nil })
        let editorPanel = try #require(connectionPanel())
        let connectionContent = try #require(editorPanel.contentView)
        func editableFields(_ view: NSView) -> [NSTextField] {
            let own = (view as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? []
            return own + view.subviews.flatMap(editableFields)
        }
        // SQLite asks only for a name and a file path, not host/port/credentials.
        try #require(await waitForView {
            connectionContent.layoutSubtreeIfNeeded()
            return editableFields(connectionContent).count == 2 && connectionContent.frame.height == 580
        })
        if let directory = ProcessInfo.processInfo.environment["LITHE_DATABASE_TREE_SCREENSHOTS"],
           let bitmap = connectionContent.bitmapImageRepForCachingDisplay(in: connectionContent.bounds) {
            connectionContent.cacheDisplay(in: connectionContent.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                URL(fileURLWithPath: directory).appendingPathComponent("database-new-sqlite-\(scheme == .dark ? "dark" : "light").png"))
        }
        editorPanel.performClose(nil)
        try #require(await waitForView { !editorPanel.isVisible })
        #expect(feature.profiles.count == 2)
        // A zero-schema scope must still expand. Name and trailing blank space have the same action.
        func hasEmptyScopeHint(_ element: Any) -> Bool {
            let accessible = element as AnyObject
            return accessible.accessibilityIdentifier?() == "database-no-schemas-selected"
                || (accessible.accessibilityChildren?() ?? []).contains(where: hasEmptyScopeHint)
        }
        #expect(feature.setVisibleDatabases([], for: profile.id))
        try #require(await waitForView { hasEmptyScopeHint(host) })
        #expect(button("alpha") == nil && button("beta") == nil)
        let emptyScopeBadge = try #require(scopeBadge())
        #expect(emptyScopeBadge.perform(valueSelector)?.takeUnretainedValue() as? String == "0 of 2")
        for trailingSpace in [false, true] {
            try await doubleClick("Local MySQL", trailingSpace: trailingSpace)
            try #require(await waitForView { !hasEmptyScopeHint(host) }, "Double-click must collapse the connection (trailing space: \(trailingSpace))")
            try await doubleClick("Local MySQL", trailingSpace: trailingSpace)
            try #require(await waitForView { hasEmptyScopeHint(host) }, "Double-click must expand even when no schemas are selected (trailing space: \(trailingSpace))")
            #expect(popupElement("All schemas") == nil)
        }
        if let directory = ProcessInfo.processInfo.environment["LITHE_DATABASE_TREE_SCREENSHOTS"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                URL(fileURLWithPath: directory).appendingPathComponent("database-empty-scope-\(scheme == .dark ? "dark" : "light").png"))
        }
        #expect(try #require(button("Collapse all")).accessibilityPerformPress?() == true)
        #expect(await waitForView { button("SQLite cache") == nil })
        // Stay inside the tree viewport, above the optional bottom progress indicator.
        let blank = NSPoint(x: host.bounds.midX, y: host.isFlipped ? host.bounds.maxY - 60 : host.bounds.minY + 60)
        try rightClick(at: host.convert(blank, to: nil))
        #expect(await waitForView { popupButton("New") != nil && popupButton("Import connections from DBX") != nil })
        #expect(try #require(popupButton("New")).accessibilityPerformPress?() == true)
        #expect(await waitForView { popupButton("Folder") != nil })
        #expect(try #require(popupButton("Folder")).accessibilityPerformPress?() == true)
        let backgroundPopup = try await submitName("Cancelled", confirm: false)
        #expect(await waitForView { !backgroundPopup.isVisible })
        #expect(feature.folders.count == folderCount)
        for connection in feature.profiles { #expect(feature.remove(connection)) }
        for group in feature.folders { feature.removeFolder(group) }
        #expect(await waitForView { feature.profiles.isEmpty && feature.folders.isEmpty })
        try rightClick(at: host.convert(blank, to: nil))
        #expect(await waitForView { popupButton("New") != nil })
        #expect(try #require(popupButton("New")).accessibilityPerformPress?() == true)
        #expect(await waitForView { popupButton("Folder") != nil })
        #expect(try #require(popupButton("Folder")).accessibilityPerformPress?() == true)
        let emptyPopup = try await submitName("First folder")
        #expect(await waitForView { !emptyPopup.isVisible && feature.folders.contains { $0.name == "First folder" } })
        await model.shutdownProjectSession()
    }

    @Test
    func databaseSchemaScopePersistsAndRefreshSkipsHiddenDatabases() async throws {
        let runner = DatabaseTreeRunner(), secrets = DatabaseFolderSecrets()
        let store = DatabaseConnectionStore(store: DatabaseLifecyclePreferences(), secureStore: secrets)
        let profile = DatabaseProfile(name: "Server", kind: .mysql, database: "beta")
        try store.save([profile]); try store.savePassword("unchanged", for: profile.id)
        #expect(store.load().first?.visibleDatabases == nil) // Legacy profiles keep showing all accessible names.
        let feature = DatabaseFeatureModel(operations: DatabaseSidecarService(processRunner: runner, executableURL: URL(fileURLWithPath: "/fixture/database")), connectionStore: store)
        defer { runner.release.open(); feature.prepareForModuleRelease() }
        await feature.loadDatabaseTree(for: profile.id)
        await feature.loadDatabaseTree("beta", for: profile.id)
        feature.selectedProfileID = profile.id; feature.selectedTable = "shared"
        let before = runner.requests.count
        #expect(feature.setVisibleDatabases(["alpha", "alpha"], for: profile.id))
        #expect(feature.visibleDatabaseNames(for: profile.id) == ["alpha"])
        #expect(store.load().first?.visibleDatabases == ["alpha"])
        #expect(feature.databaseTrees[profile.id]?.databases["beta"] == nil)
        #expect(runner.requests.count == before) // Scope changes never test connections or load rows.
        #expect(feature.selectedProfile?.database == "beta" && feature.selectedTable == "shared")
        #expect(store.password(for: profile.id) == "unchanged")
        let restarted = DatabaseFeatureModel(operations: DatabaseSidecarService(processRunner: runner, executableURL: URL(fileURLWithPath: "/fixture/database")), connectionStore: store)
        defer { restarted.prepareForModuleRelease() }
        await restarted.loadDatabaseTree(for: profile.id)
        #expect(restarted.visibleDatabaseNames(for: profile.id) == ["alpha"])
        // An editor can still load a hidden database; connection refresh must respect the tree's scope.
        for name in ["alpha", "beta"] { await feature.loadDatabaseTree(name, for: profile.id) }
        runner.names = ["alpha", "beta", "new_database"]
        let refreshStart = runner.requests.count
        await feature.refreshDatabaseTree(for: profile.id, force: true)
        #expect(feature.visibleDatabaseNames(for: profile.id) == ["alpha"])
        #expect(runner.requests.dropFirst(refreshStart).filter { $0.method != "listDatabases" }.allSatisfy { $0.database == "alpha" })
        #expect(feature.setVisibleDatabases([], for: profile.id))
        #expect(feature.visibleDatabaseNames(for: profile.id).isEmpty && store.load().first?.visibleDatabases == [])
        #expect(!feature.setVisibleDatabases(["not_permitted"], for: profile.id))
        #expect(!feature.setVisibleDatabases(nil, for: UUID()))
        #expect(store.load().first?.visibleDatabases == [])
        #expect(feature.setVisibleDatabases(nil, for: profile.id))
        runner.names.append("another_new_database")
        await feature.loadDatabaseTree(for: profile.id, force: true)
        #expect(feature.visibleDatabaseNames(for: profile.id) == runner.names.sorted())
        #expect(store.load().first?.visibleDatabases == nil)
        // Hiding a database invalidates an in-flight structure response.
        runner.blocks = true
        let pending = Task { await feature.loadDatabaseTree("alpha", for: profile.id, force: true) }
        defer { pending.cancel(); runner.release.open() }
        #expect(await runner.entered.waitUntilOpen())
        #expect(feature.setVisibleDatabases(["beta"], for: profile.id))
        runner.release.open(); await pending.value
        #expect(feature.databaseTrees[profile.id]?.databases["alpha"] == nil)
        #expect(feature.visibleDatabaseNames(for: profile.id) == ["beta"])
        #expect(!feature.hasActiveModuleWork)
    }

    @Test
    func databaseFolderCreationAndMovePersistWithoutChangingTheConnection() throws {
        let preferences = DatabaseLifecyclePreferences(), secrets = DatabaseFolderSecrets()
        let store = DatabaseConnectionStore(store: preferences, secureStore: secrets)
        let profile = DatabaseProfile(name: "Local", kind: .sqlite, path: "/fixture/cache.db")
        try store.save([profile]); try store.savePassword("fixture-password", for: profile.id)
        let feature = DatabaseFeatureModel(operations: DatabaseSidecarService(processRunner: DatabaseTreeRunner(), executableURL: URL(fileURLWithPath: "/fixture/database")), connectionStore: store)
        defer { feature.prepareForModuleRelease() }
        #expect(feature.createFolder(name: "Team/QA", movingProfileID: profile.id))
        let team = try #require(feature.folders.first { $0.name == "Team" })
        let qa = try #require(feature.folders.first { $0.name == "QA" })
        #expect(qa.parentID == team.id && feature.profiles.first?.folderID == qa.id)
        #expect(store.loadFolders().count == feature.folders.count && store.loadFolders().allSatisfy { feature.folders.contains($0) } && store.load() == feature.profiles)
        #expect(store.password(for: profile.id) == "fixture-password")
        #expect(feature.createFolder(name: "team/Backend"))
        #expect(feature.folders.filter { $0.name == "Team" }.count == 1)
        #expect(feature.move(profile, toFolder: nil))
        #expect(feature.profiles.first?.folderID == nil)
        #expect(feature.createFolder(name: "Other"))
        let other = try #require(feature.folders.first { $0.name == "Other" })
        #expect(feature.moveFolder(team.id, toParent: other.id))
        #expect(feature.folders.first { $0.id == qa.id }?.parentID == team.id)
        #expect(!feature.moveFolder(other.id, toParent: qa.id))
        #expect(!feature.moveFolder(team.id, toParent: team.id))
        let before = feature.folders
        #expect(!feature.createFolder(name: "Other/Team/QA/New", movingFolderID: other.id))
        #expect(feature.folders == before && store.loadFolders().count == before.count && store.loadFolders().allSatisfy { before.contains($0) })
        #expect(feature.createFolder(name: "Fresh/Nested", movingFolderID: team.id))
        let nested = try #require(feature.folders.first { $0.name == "Nested" })
        #expect(feature.folders.first { $0.id == team.id }?.parentID == nested.id)
        #expect(feature.moveFolder(team.id, toParent: nil))
        #expect(feature.createFolder(name: "Destination/Team"))
        let destination = try #require(feature.folders.first { $0.name == "Destination" })
        #expect(!feature.moveFolder(team.id, toParent: destination.id))
        #expect(feature.profiles.first?.id == profile.id && feature.profiles.first?.path == profile.path)
    }

    @Test
    func databaseFolderInvalidPathsAndStaleTargetsDoNotPersistPartialGroups() throws {
        let store = DatabaseConnectionStore(store: DatabaseLifecyclePreferences(), secureStore: DatabaseLifecycleSecrets())
        let feature = DatabaseFeatureModel(operations: DatabaseSidecarService(processRunner: DatabaseTreeRunner(), executableURL: URL(fileURLWithPath: "/fixture/database")), connectionStore: store)
        defer { feature.prepareForModuleRelease() }
        for name in ["", " ", "Team//QA", "/Team", "Team/"] {
            #expect(!feature.createFolder(name: name))
            #expect(feature.folders.isEmpty && store.loadFolders().isEmpty)
        }
        #expect(!feature.createFolder(name: "Team/QA", movingProfileID: UUID()))
        #expect(!feature.createFolder(name: "Team/QA", parentID: UUID()))
        #expect(feature.folders.isEmpty)
        #expect(feature.createFolder(name: "Team/QA"))
        let before = feature.folders
        #expect(!feature.createFolder(name: "team/qa"))
        #expect(feature.folders == before && store.loadFolders().count == before.count && store.loadFolders().allSatisfy { before.contains($0) })
    }

    @Test
    func databaseTreeTableMetadataSharesRequestsWithEditorAndDoesNotFetchRows() async throws {
        let runner = DatabaseTreeRunner()
        runner.blocks = true
        runner.blockedMethod = "describeTable"
        let store = DatabaseConnectionStore(store: DatabaseLifecyclePreferences(), secureStore: DatabaseLifecycleSecrets())
        let profile = DatabaseProfile(name: "Server", kind: .mysql, database: "alpha")
        try store.save([profile])
        let feature = DatabaseFeatureModel(operations: DatabaseSidecarService(processRunner: runner, executableURL: URL(fileURLWithPath: "/fixture/database")), connectionStore: store)
        defer { runner.release.open(); feature.prepareForModuleRelease() }
        let key = DatabaseTreeTableKey(profileID: profile.id, database: "alpha", table: "shared")
        let tree = Task { await feature.loadTableTree(key) }
        defer { tree.cancel(); runner.release.open() }
        #expect(await runner.entered.waitUntilOpen())
        #expect(feature.tableTrees[key]?.state == .loading)
        #expect(feature.selectedProfileID == nil && !feature.isLoading)
        #expect(!runner.requests.contains { $0.method == "pageTable" })
        let otherKey = DatabaseTreeTableKey(profileID: profile.id, database: "beta", table: "shared")
        await feature.loadTableTree(otherKey)
        #expect(feature.tableTrees[otherKey]?.state == .ready)
        feature.activateProfile(profile)
        let editor = Task { await feature.openTable("shared") }
        defer { editor.cancel(); runner.release.open() }
        #expect(await runner.pageEntered.waitUntilOpen())
        #expect(feature.isLoading)
        runner.release.open()
        await tree.value
        await editor.value
        #expect(feature.tableTrees[key]?.columns.count == 2)
        #expect(feature.columns == ["id", "name"])
        #expect(runner.requests.filter { $0.method == "describeTable" && $0.database == "alpha" }.count == 1)
        await feature.select(profile)
        #expect(runner.requests.filter { $0.method == "describeTable" && $0.database == "alpha" }.count == 1)
        let count = runner.requests.count
        await feature.loadTableTree(key)
        #expect(runner.requests.count == count)
        await feature.loadTableTree(key, force: true)
        #expect(runner.requests.filter { $0.method == "describeTable" && $0.database == "alpha" }.count == 2)
        #expect(!feature.hasActiveModuleWork)
    }

    @Test
    func databaseTreeTableMetadataFailureStaysOnItsNodeAndCanRetry() async throws {
        let runner = DatabaseTreeRunner()
        runner.fails = true
        runner.failureMethod = "describeTable"
        let store = DatabaseConnectionStore(store: DatabaseLifecyclePreferences(), secureStore: DatabaseLifecycleSecrets())
        let profile = DatabaseProfile(name: "Server", kind: .mysql, database: "alpha")
        try store.save([profile])
        let feature = DatabaseFeatureModel(operations: DatabaseSidecarService(processRunner: runner, executableURL: URL(fileURLWithPath: "/fixture/database")), connectionStore: store)
        defer { feature.prepareForModuleRelease() }
        feature.errorMessage = "Existing editor error"
        let key = DatabaseTreeTableKey(profileID: profile.id, database: "alpha", table: "shared")
        await feature.loadTableTree(key)
        guard case .failed = feature.tableTrees[key]?.state else { Issue.record("Metadata failure must be retryable on its node"); return }
        #expect(feature.errorMessage == "Existing editor error")
        runner.fails = false
        await feature.loadTableTree(key, force: true)
        #expect(feature.tableTrees[key]?.state == .ready)
        #expect(feature.tableTrees[key]?.columns.count == 2)
        #expect(!feature.hasActiveModuleWork)
    }

    @Test(arguments: [DatabaseKind.mysql, .mariadb])
    func databaseTreeKeepsMultipleDatabasesAndConnectionsWithoutMovingEditor(kind: DatabaseKind) async throws {
        let runner = DatabaseTreeRunner()
        let store = DatabaseConnectionStore(store: DatabaseLifecyclePreferences(), secureStore: DatabaseLifecycleSecrets())
        let folder = DatabaseConnectionFolder(name: "Development")
        let first = DatabaseProfile(name: "Server", kind: kind, database: "alpha", folderID: folder.id)
        let second = DatabaseProfile(name: "Other server", kind: kind, database: "beta", folderID: folder.id)
        let sqlite = DatabaseProfile(name: "Cache", kind: .sqlite, path: "/fixture/cache.db", folderID: folder.id)
        try store.save([first, second, sqlite]); try store.saveFolders([folder])
        let feature = DatabaseFeatureModel(operations: DatabaseSidecarService(processRunner: runner, executableURL: URL(fileURLWithPath: "/fixture/database")), connectionStore: store)
        defer { feature.prepareForModuleRelease() }
        await feature.select(sqlite)
        let initialTableRequests = runner.requests.filter { $0.method == "listTables" }.count
        feature.selectedTable = "keep_this_selection"
        await feature.loadDatabaseTree(for: first.id)
        #expect(feature.databaseTrees[first.id]?.names == ["alpha", "beta"])
        #expect(runner.requests.filter { $0.method == "listTables" }.count == initialTableRequests)
        await feature.loadDatabaseTree("alpha", for: first.id)
        await feature.loadDatabaseTree("beta", for: first.id)
        await feature.loadDatabaseTree(for: second.id)
        await feature.loadDatabaseTree("beta", for: second.id)
        #expect(feature.databaseTrees[first.id]?.databases["alpha"]?.tables == ["alpha_only", "shared"])
        #expect(feature.databaseTrees[first.id]?.databases["beta"]?.tables == ["beta_only", "shared"])
        #expect(feature.databaseTrees[second.id]?.databases["beta"]?.state == .ready)
        #expect(feature.selectedProfileID == sqlite.id)
        #expect(feature.selectedTable == "keep_this_selection")
        #expect(feature.folders == [folder] && feature.profiles.allSatisfy { $0.folderID == folder.id })
        let count = runner.requests.count
        await feature.loadDatabaseTree("alpha", for: first.id)
        await feature.loadDatabaseTree("not_permitted", for: first.id)
        #expect(runner.requests.count == count)
        #expect(!feature.hasActiveModuleWork)
    }

    @Test(arguments: [ColorScheme.dark, .light], [false, true])
    func databaseTableEmptyStateUsesSharedInstruction(scheme: ColorScheme, hasConnection: Bool) async throws {
        let preferences = DatabaseLifecyclePreferences()
        let store = DatabaseConnectionStore(store: preferences, secureStore: DatabaseLifecycleSecrets())
        let profile = DatabaseProfile(name: "Server", kind: .mysql)
        try store.save([profile])
        let feature = DatabaseFeatureModel(operations: DatabaseSidecarService(processRunner: DatabaseTreeRunner(), executableURL: URL(fileURLWithPath: "/fixture/database")), connectionStore: store)
        defer { feature.prepareForModuleRelease() }
        if hasConnection { feature.selectedProfileID = profile.id }
        let settings = AppSettings(store: preferences)
        let model = AppModel(settings: settings, services: MacServiceContainer(store: preferences, settings: settings, moduleLaunchMode: .safeMode).services)
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let application = NSApplication.shared
        let previous = application.accessibilityAttributeValue(attribute) as? Bool ?? false
        application.accessibilitySetValue(true, forAttribute: attribute)
        defer { application.accessibilitySetValue(previous, forAttribute: attribute) }
        let host = NSHostingView(rootView: DatabaseTableView().environmentObject(feature).environmentObject(model)
            .environmentObject(settings).environment(\.colorScheme, scheme).environment(\.locale, Locale(identifier: "en"))
            .frame(width: 540, height: 410))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 410), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        func texts(_ element: AnyObject) -> [String] {
            // SwiftUI's private AX nodes expose the value selector without conforming to NSAccessibilityStaticText.
            let object = element as? NSObject
            let selector = NSSelectorFromString("accessibilityValue")
            let value = object?.responds(to: selector) == true ? object?.perform(selector)?.takeUnretainedValue() as? String : nil
            return [element.accessibilityLabel?(), element.accessibilityTitle?(), value].compactMap { $0 }
                + (element.accessibilityChildren?() ?? []).flatMap { texts($0 as AnyObject) }
        }
        let message = hasConnection ? "Double-click a table to view data" : "Select a connection in the database tree"
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(3))
        repeat {
            host.layoutSubtreeIfNeeded()
            if texts(host).contains(message) { break }
            await Task.yield()
        } while clock.now < deadline
        #expect(texts(host).contains(message))
        #expect(!texts(host).contains("No Table Selected"))
        if let directory = ProcessInfo.processInfo.environment["LITHE_DATABASE_TREE_SCREENSHOTS"] {
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                URL(fileURLWithPath: directory).appendingPathComponent("database-empty-\(hasConnection ? "connection" : "none")-\(scheme == .dark ? "dark" : "light").png"))
        }
    }

    @Test
    func databaseTreeRefreshScopesAndForceRefreshPreserveEditor() async throws {
        let runner = DatabaseTreeRunner()
        let store = DatabaseConnectionStore(store: DatabaseLifecyclePreferences(), secureStore: DatabaseLifecycleSecrets())
        let profile = DatabaseProfile(name: "Server", kind: .mysql)
        try store.save([profile])
        let feature = DatabaseFeatureModel(operations: DatabaseSidecarService(processRunner: runner, executableURL: URL(fileURLWithPath: "/fixture/database")), connectionStore: store)
        defer { runner.release.open(); feature.prepareForModuleRelease() }
        await feature.loadDatabaseTree(for: profile.id)
        for database in ["alpha", "beta"] { await feature.loadDatabaseTree(database, for: profile.id) }
        let alpha = DatabaseTreeTableKey(profileID: profile.id, database: "alpha", table: "shared")
        let beta = DatabaseTreeTableKey(profileID: profile.id, database: "beta", table: "shared")
        await feature.loadTableTree(alpha); await feature.loadTableTree(beta)
        feature.selectedProfileID = profile.id
        feature.selectedTable = "unchanged"
        let before = runner.requests.count
        await feature.refreshDatabaseTree(for: profile.id, database: "beta")
        let scoped = Array(runner.requests.dropFirst(before))
        #expect(!scoped.isEmpty && scoped.allSatisfy { $0.database == "beta" })
        #expect(scoped.contains { $0.method == "listTables" } && scoped.contains { $0.method == "describeTable" })
        #expect(!scoped.contains { $0.method == "pageTable" || $0.method == "listDatabases" })
        let beforeTable = runner.requests.count
        await feature.loadTableTree(beta, force: true)
        #expect(runner.requests.dropFirst(beforeTable).allSatisfy {
            $0.database == "beta" && ["describeTable", "listIndexes", "listForeignKeys"].contains($0.method)
        })
        // A full reload supersedes an old worker even if its synchronous process cannot be cancelled.
        runner.blocks = true; runner.blockedMethod = "describeTable"
        let old = Task { await feature.loadTableTree(alpha, force: true) }
        defer { old.cancel(); runner.release.open() }
        #expect(await runner.entered.waitUntilOpen())
        let oldID = feature.tableTrees[alpha]?.requestID
        runner.blocks = false
        await feature.refreshDatabaseTree(for: profile.id, force: true)
        let refreshedID = try #require(feature.tableTrees[alpha]?.requestID)
        #expect(refreshedID != oldID && feature.tableTrees[alpha]?.state == .ready)
        runner.release.open(); await old.value
        #expect(feature.tableTrees[alpha]?.requestID == refreshedID)
        runner.names = ["beta"]
        await feature.refreshDatabaseTree(for: profile.id)
        #expect(feature.databaseTrees[profile.id]?.databases["alpha"] == nil && feature.tableTrees[alpha] == nil)
        #expect(feature.selectedTable == "unchanged" && feature.rows.isEmpty)
        #expect(!runner.requests.contains { $0.method == "pageTable" })
        #expect(!feature.hasActiveModuleWork)
    }

    @Test
    func databaseTreeActionsSelectTheDatabaseOwningAnIdenticallyNamedTable() async throws {
        let runner = DatabaseTreeRunner()
        let store = DatabaseConnectionStore(store: DatabaseLifecyclePreferences(), secureStore: DatabaseLifecycleSecrets())
        let profile = DatabaseProfile(name: "Server", kind: .mysql, database: "alpha")
        try store.save([profile])
        let feature = DatabaseFeatureModel(operations: DatabaseSidecarService(processRunner: runner, executableURL: URL(fileURLWithPath: "/fixture/database")), connectionStore: store)
        defer { feature.prepareForModuleRelease() }
        await feature.loadDatabaseTree(for: profile.id)
        await feature.loadDatabaseTree("alpha", for: profile.id)
        var target = profile; target.database = "beta"
        #expect(await feature.selectDatabaseContext(target))
        await feature.openTable("shared")
        #expect(feature.selectedProfile?.database == "beta")
        #expect(runner.requests.last(where: { $0.method == "pageTable" })?.database == "beta")
        #expect(feature.databaseTrees[profile.id]?.databases["alpha"]?.tables == ["alpha_only", "shared"])
        #expect(feature.databaseTrees[profile.id]?.databases["beta"]?.tables == ["beta_only", "shared"])
        target.database = "not_permitted"
        #expect(await !feature.selectDatabaseContext(target))
        #expect(feature.selectedProfile?.database == "beta")
    }

    @Test
    func databaseTreeCanBrowseServerWithoutADefaultDatabase() async throws {
        let runner = DatabaseTreeRunner()
        let store = DatabaseConnectionStore(store: DatabaseLifecyclePreferences(), secureStore: DatabaseLifecycleSecrets())
        let profile = DatabaseProfile(name: "Server", kind: .mysql)
        try store.save([profile])
        let feature = DatabaseFeatureModel(operations: DatabaseSidecarService(processRunner: runner, executableURL: URL(fileURLWithPath: "/fixture/database")), connectionStore: store)
        defer { feature.prepareForModuleRelease() }
        await feature.select(profile)
        #expect(feature.databaseTrees[profile.id]?.names == ["alpha", "beta"])
        #expect(feature.errorMessage == nil && !feature.isLoading)
        #expect(runner.requests.allSatisfy { $0.method == "listDatabases" })
    }

    @Test
    func databaseTreeRetriesFailureWithoutLosingOtherDatabases() async throws {
        let runner = DatabaseTreeRunner()
        let store = DatabaseConnectionStore(store: DatabaseLifecyclePreferences(), secureStore: DatabaseLifecycleSecrets())
        let profile = DatabaseProfile(name: "Server", kind: .mysql)
        try store.save([profile])
        let feature = DatabaseFeatureModel(operations: DatabaseSidecarService(processRunner: runner, executableURL: URL(fileURLWithPath: "/fixture/database")), connectionStore: store)
        defer { feature.prepareForModuleRelease() }
        await feature.loadDatabaseTree(for: profile.id)
        await feature.loadDatabaseTree("alpha", for: profile.id)
        runner.fails = true
        await feature.loadDatabaseTree("beta", for: profile.id)
        guard case .failed = feature.databaseTrees[profile.id]?.databases["beta"]?.state else {
            Issue.record("A denied database must expose a retryable failure"); return
        }
        #expect(feature.databaseTrees[profile.id]?.databases["alpha"]?.state == .ready)
        runner.fails = false
        await feature.loadDatabaseTree("beta", for: profile.id, force: true)
        #expect(feature.databaseTrees[profile.id]?.databases["beta"]?.state == .ready)
        runner.names = ["beta"]
        await feature.loadDatabaseTree(for: profile.id, force: true)
        #expect(feature.databaseTrees[profile.id]?.databases["alpha"] == nil)
        #expect(!feature.hasActiveModuleWork)
    }

    @Test(arguments: ["disconnect", "remove", "release"], [false, true])
    func databaseTreeRejectsLateResultsAfterInvalidation(action: String, tableMetadata: Bool) async throws {
        let runner = DatabaseTreeRunner()
        let store = DatabaseConnectionStore(store: DatabaseLifecyclePreferences(), secureStore: DatabaseLifecycleSecrets())
        let profile = DatabaseProfile(name: "Server", kind: .mysql)
        try store.save([profile])
        let recoveryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: recoveryRoot) }
        let feature = DatabaseFeatureModel(operations: DatabaseSidecarService(processRunner: runner, executableURL: URL(fileURLWithPath: "/fixture/database")), connectionStore: store, recoveryStore: MacDatabaseRecoveryStore(rootURL: recoveryRoot))
        defer { runner.release.open(); feature.prepareForModuleRelease() }
        await feature.loadDatabaseTree(for: profile.id)
        runner.blocks = true
        runner.blockedMethod = tableMetadata ? "describeTable" : "listTables"
        let key = DatabaseTreeTableKey(profileID: profile.id, database: "alpha", table: "shared")
        let task = Task {
            if tableMetadata { await feature.loadTableTree(key) }
            else { await feature.loadDatabaseTree("alpha", for: profile.id) }
        }
        defer { task.cancel(); runner.release.open() }
        #expect(await runner.entered.waitUntilOpen())
        #expect(feature.hasActiveModuleWork)
        // Another database can finish while alpha remains blocked, without moving the editor.
        await feature.loadDatabaseTree("beta", for: profile.id)
        #expect(feature.databaseTrees[profile.id]?.databases["beta"]?.state == .ready)
        switch action {
        case "disconnect": feature.disconnect(profile)
        case "remove": #expect(feature.remove(profile))
        default: feature.prepareForModuleRelease()
        }
        runner.release.open()
        await task.value
        #expect(feature.databaseTrees[profile.id] == nil)
        #expect(feature.tableTrees[key] == nil)
        #expect(!feature.hasActiveModuleWork)
    }

    @Test(arguments: [
        ("listDatabases", "cancel"), ("listDatabases", "collapse"), ("listDatabases", "release"),
        ("listTables", "collapse"), ("listTables", "disconnect"), ("listTables", "forceRefresh"),
        ("describeTable", "release")
    ])
    func databaseTreeCancellationStopsSidecarWithoutReleasingARequest(scenario: (String, String)) async throws {
        let (method, action) = scenario
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-tree-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("blocked-sidecar.sh")
        let pidFile = directory.appendingPathComponent("sidecar.pid")
        try "#!/bin/sh\nprintf '%s' \"$$\" > \"$LITHE_TEST_PID_FILE\"\ntrap '' TERM\nwhile :; do :; done\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let runner = CancellableTreeSidecarRunner(blockedMethod: method, pidFile: pidFile)
        let store = DatabaseConnectionStore(store: DatabaseLifecyclePreferences(), secureStore: DatabaseLifecycleSecrets())
        let profile = DatabaseProfile(name: "Server", kind: .mysql)
        try store.save([profile])
        let feature = DatabaseFeatureModel(operations: DatabaseSidecarService(processRunner: runner, executableURL: executable), connectionStore: store)
        defer { feature.prepareForModuleRelease() }
        if method != "listDatabases" { await feature.loadDatabaseTree(for: profile.id) }
        if method == "describeTable" { await feature.loadDatabaseTree("alpha", for: profile.id) }
        let loading = Task { @MainActor in
            switch method {
            case "describeTable": await feature.loadTableTree(DatabaseTreeTableKey(profileID: profile.id, database: "alpha", table: "shared"))
            case "listTables": await feature.loadDatabaseTree("alpha", for: profile.id)
            default: await feature.loadDatabaseTree(for: profile.id)
            }
        }
        defer { loading.cancel() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        var processID: Int32?
        while clock.now < deadline {
            processID = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { Int32($0) }
            if processID != nil { break }
            // test-stability: allow(swift-real-sleep) reason: sidecar startup exposes only a PID file, so poll it with a local deadline.
            try? await Task.sleep(for: .milliseconds(10))
        }
        let pid = try #require(processID)
        defer { if Darwin.kill(pid, 0) == 0 { _ = Darwin.kill(pid, SIGKILL) } }
        let started = clock.now
        switch action {
        case "cancel": loading.cancel()
        case "release": feature.prepareForModuleRelease()
        case "collapse": feature.cancelDatabaseTreeLoad(for: profile.id, database: method == "listTables" ? "alpha" : nil)
        case "disconnect": feature.disconnect(profile)
        default:
            runner.shouldBlock = false
            await feature.refreshDatabaseTree(for: profile.id, force: true)
        }
        await loading.value
        #expect(clock.now - started < .seconds(2))
        errno = 0
        #expect(Darwin.kill(pid, 0) == -1 && errno == ESRCH)
        #expect(!feature.hasActiveModuleWork)
    }

    @Test(arguments: [false, true], [false, true])
    func formattedMiddleSelectionKeepsTheWholeStatement(dark: Bool, wholeScript: Bool) throws {
        let original = "select '😀';\nselect 1;\nselect 2;"
        let selected = (original as NSString).range(of: "select 1;")
        let formatted = wholeScript ? DatabaseSQLFormatter.format(original) : "select '😀';\nselect\n    1;\nselect 2;"
        let settings = AppSettings(store: DatabaseLifecyclePreferences())
        func view(_ sql: String) -> some View {
            SQLSyntaxEditor(text: .constant(sql), completions: [], onRun: {}, onSelectionChange: { _ in })
                .environmentObject(settings).environment(\.colorScheme, dark ? .dark : .light)
        }
        let host = NSHostingView(rootView: view(original))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 240), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defer { window.contentView = nil; window.close() }
        window.contentView = host; host.layoutSubtreeIfNeeded()
        func editor(_ view: NSView) -> SQLTextView? {
            if let text = view as? SQLTextView { return text }
            return view.subviews.lazy.compactMap { editor($0) }.first
        }
        let text = try #require(editor(host))
        text.setSelectedRange(selected)
        host.rootView = view(formatted); host.layoutSubtreeIfNeeded()
        #expect(editor(host) === text)
        #expect((text.string as NSString).substring(with: text.selectedRange()) == "select\n    1;")
        #expect(text.selectedRange() == (formatted as NSString).range(of: "select\n    1;"))
        #expect(SQLSyntaxEditor.selection(NSRange(location: original.utf16.count, length: 0), replacing: original, with: formatted)
            == NSRange(location: formatted.utf16.count, length: 0))
        #expect(SQLSyntaxEditor.selection(NSRange(location: 0, length: original.utf16.count), replacing: original, with: formatted)
            == NSRange(location: 0, length: formatted.utf16.count))
    }

    @Test(arguments: [false, true])
    func multilineStatementOutlineEndsAtFinalLineInsteadOfWidestLine(dark: Bool) throws {
        let sql = "SELECT\n    c.name, SUM(o.total) AS total_spent FROM customers c\n    JOIN orders o ON o.customer_id = c.id\nGROUP BY c.name;"
        let range = NSRange(location: 0, length: sql.utf16.count)
        let record = DatabaseSQLStatementExecution(id: UUID(), sql: sql, sourceSQL: sql, sourceRange: range,
            startedAt: Date(timeIntervalSince1970: 0), batchStartedAt: Date(timeIntervalSince1970: 0), durationMilliseconds: 74,
            result: nil, rowsReturned: 3, rowsAffected: nil, errorMessage: nil)
        let host = NSHostingView(rootView: SQLSyntaxEditor(text: .constant(sql), completions: [], onRun: {}, onSelectionChange: { _ in }, executions: [record])
            .environmentObject(AppSettings(store: DatabaseLifecyclePreferences())).environment(\.colorScheme, dark ? .dark : .light)
            .background(LitheTheme.editor))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 240), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defer { window.contentView = nil; window.close() }
        window.contentView = host; host.layoutSubtreeIfNeeded()
        func editor(_ view: NSView) -> SQLTextView? {
            if let text = view as? SQLTextView { return text }
            return view.subviews.lazy.compactMap { editor($0) }.first
        }
        let text = try #require(editor(host))
        let lines = text.statementLineRects(range)
        #expect(lines.count == 4)
        let last = try #require(lines.last)
        let box = text.statementRect(range), outline = text.statementOutline(range)
        #expect(last.maxX < box.maxX - 80)
        #expect(outline.contains(NSPoint(x: box.maxX - 4, y: lines[1].midY)))
        #expect(!outline.contains(NSPoint(x: box.maxX - 4, y: last.midY)))
        // Rendered right edge must step inward on GROUP BY; the old union rectangle colored the widest X on every row.
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        func color(x: CGFloat, y: CGFloat) throws -> NSColor {
            let point = text.convert(NSPoint(x: x, y: y), to: host)
            let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
            return try #require(bitmap.colorAt(x: Int(point.x * scale), y: Int((host.isFlipped ? point.y : host.bounds.height - point.y) * scale))?.usingColorSpace(.sRGB))
        }
        let border = try color(x: floor(last.maxX) + 0.5, y: last.midY)
        let reference = try color(x: floor(box.maxX) + 0.5, y: lines[1].midY)
        let outside = try color(x: floor(box.maxX) + 0.5, y: last.midY)
        let background = try color(x: box.maxX - 5, y: last.midY)
        #expect(abs(border.redComponent - reference.redComponent) < 0.01 && abs(border.greenComponent - reference.greenComponent) < 0.01
            && abs(border.blueComponent - reference.blueComponent) < 0.01)
        #expect(abs(outside.redComponent - background.redComponent) < 0.01 && abs(outside.greenComponent - background.greenComponent) < 0.01
            && abs(outside.blueComponent - background.blueComponent) < 0.01)
        #expect(text.statementLineRects(NSRange(location: NSNotFound, length: 1)).isEmpty)
    }

    @Test(arguments: [false, true], [false, true])
    func queryOutputTracksStatementsSelectionAndFailures(fails: Bool, dark: Bool) async throws {
        let store = DatabaseConnectionStore(store: DatabaseLifecyclePreferences(), secureStore: DatabaseLifecycleSecrets())
        let profile = DatabaseProfile(name: "Output fixture", kind: .sqlite, database: "fixture")
        try store.save([profile])
        let feature = DatabaseFeatureModel(operations: DatabaseSidecarService(processRunner: QueryOutputRunner(fails: fails), executableURL: URL(fileURLWithPath: "/fixture/database")), connectionStore: store)
        defer { feature.prepareForModuleRelease() }
        feature.activateProfile(profile)
        let id = try #require(feature.selectedSQLTabID)
        let sql = "SELECT '😀;';\nSELECT '😀;';"
        feature.updateSQL(sql, in: id)
        let selection = (sql as NSString).range(of: "SELECT '😀;';", options: .backwards)
        await feature.runSQL(in: id, scope: .selection("SELECT '😀;';"), selectionRange: selection)
        let record = try #require(feature.selectedSQLTab?.statementExecutions.first)
        #expect(record.sourceRange == NSRange(location: selection.location, length: "SELECT\n    '😀;';".utf16.count))
        #expect(feature.selectedSQLTab?.sql == "SELECT '😀;';\nSELECT\n    '😀;';")
        #expect(record.result?.rows.count == 1)
        #expect(record.durationMilliseconds >= 0)
        #expect(DatabaseQueryResult(rows: [["b": .integer(2)], ["a": .integer(1)]], truncated: false).resolvedColumns == ["b", "a"])
        feature.updateSQL("SELECT 1; SELECT missing_table;", in: id)
        await feature.runSQL(in: id)
        let tab = try #require(feature.selectedSQLTab)
        #expect(tab.statementExecutions.count == 3)
        #expect(tab.execution != nil) // Both success and failure retain actual elapsed time.
        #expect((tab.errorMessage != nil) == fails)
        #expect((tab.statementExecutions.last?.errorMessage != nil) == fails)
        #expect(feature.sqlHistory.count == 2) // Failed executions are browsable too.
        #expect(tab.statementExecutions[1].sourceRange == NSRange(location: 0, length: 13))
        #expect(tab.statementExecutions[2].sourceRange == NSRange(location: 14, length: 25))
        feature.clearSQLOutput(in: id)
        #expect(feature.selectedSQLTab?.statementExecutions == tab.statementExecutions)
        #expect(feature.selectedSQLTab?.outputHiddenThroughExecutionID == tab.statementExecutions.last?.id)
        feature.dismissSQLError(in: id)
        #expect(feature.selectedSQLTab?.errorMessage == nil)
        feature.updateSQL("INSERT INTO customers VALUES(3, 'C', 'D');", in: id)
        await feature.runSQL(in: id, confirmedRisk: true) // Unavailable recovery storage fails before provider execution.
        let preparationFailure = try #require(feature.selectedSQLTab?.statementExecutions.last)
        #expect(preparationFailure.errorMessage != nil)
        #expect(preparationFailure.sourceRange == nil)
        #expect(preparationFailure.result == nil)

        let host = NSHostingView(rootView: SQLSyntaxEditor(text: .constant(tab.sql), completions: [], onRun: {}, onSelectionChange: { _ in }, executions: tab.statementExecutions, wrapsLines: true)
            .environmentObject(AppSettings(store: DatabaseLifecyclePreferences()))
            .environment(\.colorScheme, dark ? .dark : .light).background(LitheTheme.editor))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defer { window.contentView = nil; window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func editor(_ view: NSView) -> SQLTextView? {
            if let text = view as? SQLTextView { return text }
            return view.subviews.lazy.compactMap { editor($0) }.first
        }
        let text = try #require(editor(host))
        let statementBox = text.statementRect(NSRange(location: 0, length: tab.sql.utf16.count))
        #expect(statementBox.width < text.bounds.width * 0.9)
        // The newline's viewport-wide advance must not widen a multiline statement.
        text.string = "SELECT\n '😀';"
        let multilineBox = text.statementRect(NSRange(location: 0, length: text.string.utf16.count))
        #expect(multilineBox.width < text.bounds.width * 0.9)
        text.string = tab.sql
        #expect(text.textContainer?.widthTracksTextView == true)
        #expect(!text.isHorizontallyResizable)
        // Native caches inherit the display's HDR profile; calibrate against the same native color in-window.
        let reference = NSBox(frame: NSRect(x: host.bounds.maxX - 10, y: host.bounds.maxY - 10, width: 8, height: 8))
        reference.boxType = .custom; reference.titlePosition = .noTitle; reference.borderType = .noBorder
        reference.fillColor = NSColor(LitheTheme.DatabaseConsole.statementOutline)
        host.addSubview(reference)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap) // Draw the real statement boxes and inline timings.
        let firstRange = try #require(tab.statementExecutions.first { $0.sourceSQL == tab.sql && $0.sourceRange != nil }?.sourceRange)
        let firstBox = text.statementRect(firstRange)
        let leftEdge = text.convert(NSPoint(x: 0.5, y: firstBox.midY), to: host)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        let pixelY = host.isFlipped ? leftEdge.y : host.bounds.height - leftEdge.y
        let actualBorder = try #require(bitmap.colorAt(x: Int(leftEdge.x * scale), y: Int(pixelY * scale))?.usingColorSpace(.sRGB))
        var expectedBorder = NSColor.black
        window.appearance!.performAsCurrentDrawingAppearance { expectedBorder = NSColor(LitheTheme.DatabaseConsole.statementOutline).usingColorSpace(.sRGB)! }
        #expect(abs(expectedBorder.redComponent - 61.0 / 255) < 0.00001)
        #expect(abs(expectedBorder.greenComponent - 122.0 / 255) < 0.00001)
        #expect(abs(expectedBorder.blueComponent - 73.0 / 255) < 0.00001)
        let referencePoint = NSPoint(x: reference.frame.midX, y: reference.frame.midY)
        let referenceY = host.isFlipped ? referencePoint.y : host.bounds.height - referencePoint.y
        let renderedReference = try #require(bitmap.colorAt(x: Int(referencePoint.x * scale), y: Int(referenceY * scale))?.usingColorSpace(.sRGB))
        #expect(abs(actualBorder.redComponent - renderedReference.redComponent) < 0.01)
        #expect(abs(actualBorder.greenComponent - renderedReference.greenComponent) < 0.01)
        #expect(abs(actualBorder.blueComponent - renderedReference.blueComponent) < 0.01)
        text.string = String(repeating: "SELECT 'long value' ", count: 100)
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        var fragments = 0
        text.layoutManager?.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: text.layoutManager?.numberOfGlyphs ?? 0)) { _, _, _, _, _ in fragments += 1 }
        #expect(fragments > 1)
        #expect(!text.string.contains("\n")) // Soft wraps never rewrite SQL or its logical line count.
        text.string = "select * from t;"
        text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
        let formatted = "select\n    * from t;"
        host.rootView = SQLSyntaxEditor(text: .constant(formatted), completions: [], onRun: {}, onSelectionChange: { _ in }, executions: [], wrapsLines: true)
            .environmentObject(AppSettings(store: DatabaseLifecyclePreferences()))
            .environment(\.colorScheme, dark ? .dark : .light).background(LitheTheme.editor)
        host.layoutSubtreeIfNeeded()
        #expect(editor(host) === text)
        #expect(text.selectedRange() == NSRange(location: formatted.utf16.count, length: 0))
    }

    @Test(arguments: [false, true])
    func executionMarkersFollowUnchangedStatementsAndExposeStripePositions(dark: Bool) async throws {
        let store = DatabaseConnectionStore(store: DatabaseLifecyclePreferences(), secureStore: DatabaseLifecycleSecrets())
        let profile = DatabaseProfile(name: "Marker fixture", kind: .sqlite, database: "fixture")
        try store.save([profile])
        let feature = DatabaseFeatureModel(operations: DatabaseSidecarService(processRunner: QueryOutputRunner(fails: true), executableURL: URL(fileURLWithPath: "/fixture/database")), connectionStore: store)
        defer { feature.prepareForModuleRelease() }
        feature.activateProfile(profile)
        let id = try #require(feature.selectedSQLTabID)
        feature.updateSQL("select '😀';", in: id)
        await feature.runSQL(in: id)
        let first = try #require(feature.selectedSQLTab?.statementExecutions.first)
        let appended = try #require(feature.selectedSQLTab?.sql) + "\n\nselect * from missing_table;"
        feature.updateSQL(appended, in: id)
        #expect(feature.selectedSQLTab?.statementExecutions.first?.sourceRange == first.sourceRange)
        let selection = (appended as NSString).range(of: "select * from missing_table;")
        await feature.runSQL(in: id, scope: .selection("select * from missing_table;"), selectionRange: selection)
        let tab = try #require(feature.selectedSQLTab)
        #expect(tab.statementExecutions.count == 2)
        #expect(tab.statementExecutions.first?.sql == first.sql) // Output retains the actual executed SQL.
        #expect(tab.statementExecutions.first?.sourceSQL == tab.sql)
        #expect(tab.statementExecutions.first?.sourceRange == first.sourceRange)

        let settings = AppSettings(store: DatabaseLifecyclePreferences())
        func view(_ tab: DatabaseSQLTab) -> some View {
            SQLSyntaxEditor(text: .constant(tab.sql), completions: [], onRun: {}, onSelectionChange: { _ in }, executions: tab.statementExecutions)
                .environmentObject(settings).environment(\.colorScheme, dark ? .dark : .light).background(LitheTheme.editor)
        }
        let host = NSHostingView(rootView: view(tab))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 240), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defer { window.contentView = nil; window.close() }
        window.contentView = host; host.layoutSubtreeIfNeeded()
        func editor(_ view: NSView) -> SQLTextView? {
            if let text = view as? SQLTextView { return text }
            return view.subviews.lazy.compactMap { editor($0) }.first
        }
        let text = try #require(editor(host))
        let stripe = try #require(text.executionStripe)
        #expect(text.visibleExecutions.count == 2)
        #expect(text.gutter?.consoleExecutionMarkers[1] == "expui/general/greenCheckmark.svg")
        #expect(text.gutter?.consoleExecutionMarkers[4] == "expui/status/error.svg")
        let firstRange = try #require(tab.statementExecutions[0].sourceRange)
        let lastRange = try #require(tab.statementExecutions[1].sourceRange)
        let success = stripe.markerRect(firstRange), failure = stripe.markerRect(lastRange)
        #expect(success.height == 2 && success.width == 14)
        #expect(success.minY == floor(text.statementRect(firstRange).maxY)) // Short documents are not stretched.
        #expect(failure.minY > success.maxY)
        let markerHit = stripe.convert(NSPoint(x: success.midX, y: success.midY), to: stripe.superview)
        #expect(stripe.hitTest(markerHit) === stripe)
        let blankHit = stripe.convert(NSPoint(x: success.midX, y: failure.maxY + 20), to: stripe.superview)
        #expect(stripe.hitTest(blankHit) == nil)
        #expect(stripe.wantsLayer) // Text-view repaint must not erase its transparent sibling's ticks.
        #expect((stripe.accessibilityValue() as? String)?.contains("Succeeded, line 1") == true)
        #expect((stripe.accessibilityValue() as? String)?.contains("Failed, line 4") == true)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)

        let prefix = String(repeating: "\n", count: 1000)
        feature.updateSQL(prefix + tab.sql, in: id)
        let long = try #require(feature.selectedSQLTab)
        #expect(long.statementExecutions[0].sourceRange?.location == firstRange.location + prefix.utf16.count)
        host.rootView = view(long); host.layoutSubtreeIfNeeded()
        let compressed = stripe.markerRect(try #require(long.statementExecutions[1].sourceRange))
        #expect(compressed.maxY <= stripe.bounds.height)
        #expect(compressed.minY > stripe.bounds.height * 0.9)
        // Editing only the failed statement keeps the earlier check; editing a boundary removes stale status.
        feature.updateSQL(long.sql.replacingOccurrences(of: "missing_table", with: "customers"), in: id)
        #expect(feature.selectedSQLTab?.statementExecutions[0].sourceRange != nil)
        #expect(feature.selectedSQLTab?.statementExecutions[1].sourceRange == nil)
        let beforeJoin = try #require(feature.selectedSQLTab)
        let insertion = try #require(beforeJoin.statementExecutions[0].sourceRange).location
        feature.updateSQL((beforeJoin.sql as NSString).replacingCharacters(in: NSRange(location: insertion, length: 0), with: "x"), in: id)
        #expect(feature.selectedSQLTab?.statementExecutions[0].sourceRange == nil)
    }

    @Test(arguments: [false, true])
    func queryCompletionKeepsOnlyUnchangedExecutionMarkers(editedStatement: Bool) async throws {
        let runner = GatedDatabaseWorkspaceRunner(fails: false, gatedMethod: "query")
        let store = DatabaseConnectionStore(store: DatabaseLifecyclePreferences(), secureStore: DatabaseLifecycleSecrets())
        let profile = DatabaseProfile(name: "Pending marker fixture", kind: .sqlite, database: "fixture")
        try store.save([profile])
        let feature = DatabaseFeatureModel(operations: DatabaseSidecarService(processRunner: runner, executableURL: URL(fileURLWithPath: "/fixture/database")), connectionStore: store)
        defer { runner.release.open(); feature.prepareForModuleRelease() }
        feature.activateProfile(profile)
        let id = try #require(feature.selectedSQLTabID)
        feature.updateSQL("select 1;", in: id)
        let task = Task { await feature.runSQL(in: id) }
        #expect(await runner.entered.waitUntilOpen())
        let running = feature.selectedSQLTab?.sql ?? ""
        #expect(!running.isEmpty)
        feature.updateSQL(editedStatement ? running.replacingOccurrences(of: "1", with: "2") : running + "\nselect 2;", in: id)
        runner.release.open()
        await task.value
        let tab = try #require(feature.selectedSQLTab)
        let record = try #require(tab.statementExecutions.last)
        #expect(record.sql == "select\n    1")
        #expect(record.sourceSQL == tab.sql)
        #expect((record.sourceRange == nil) == editedStatement)
    }

    @Test(arguments: [false, true])
    func querySyntaxColorsProtectQuotedIdentifiersAndLiterals(dark: Bool) throws {
        let source = #"select * from "from" where n>=1.25e-2 and value=E'it\'s SELECT -- text' and body=$tag$WHERE 12$tag$ -- SELECT 9"#
        let storage = NSTextStorage(string: source)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        appearance.performAsCurrentDrawingAppearance {
            SQLSyntaxHighlighter.apply(to: storage, font: LitheTheme.editorFont(size: 13), isDark: dark)
        }
        func expectColor(_ text: String, _ color: Color) throws {
            let range = (source as NSString).range(of: text)
            let actual = try #require(storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor)
            var expected = NSColor.black
            var resolved = NSColor.black
            appearance.performAsCurrentDrawingAppearance {
                expected = NSColor(color).usingColorSpace(.sRGB)!
                resolved = actual.usingColorSpace(.sRGB)!
            }
            #expect(resolved == expected)
        }
        try expectColor("select", LitheTheme.DatabaseConsole.keyword)
        try expectColor("*", LitheTheme.DatabaseConsole.keyword)
        try expectColor(">=", LitheTheme.DatabaseConsole.keyword)
        try expectColor("1.25e-2", LitheTheme.DatabaseConsole.number)
        try expectColor(#""from""#, LitheTheme.DatabaseGrid.text)
        try expectColor(#"SELECT -- text'"#, LitheTheme.DatabaseConsole.string)
        try expectColor("WHERE 12", LitheTheme.DatabaseConsole.string)
        try expectColor("-- SELECT 9", LitheTheme.DatabaseConsole.comment)
        #expect(storage.string == source)
    }

    @Test func executionFormatsOnlyTheSelectedSQLWithNativeRange() async throws {
        let store = DatabaseConnectionStore(store: DatabaseLifecyclePreferences(), secureStore: DatabaseLifecycleSecrets())
        let profile = DatabaseProfile(name: "Format fixture", kind: .sqlite, database: "fixture")
        try store.save([profile])
        let feature = DatabaseFeatureModel(operations: DatabaseSidecarService(processRunner: QueryOutputRunner(fails: false), executableURL: URL(fileURLWithPath: "/fixture/database")), connectionStore: store)
        defer { feature.prepareForModuleRelease() }
        feature.activateProfile(profile)
        let id = try #require(feature.selectedSQLTabID)
        let statement = " select '😀' from customers where id>=1; "
        let original = statement + "\n" + statement
        let range = (original as NSString).range(of: statement, options: .backwards)
        feature.updateSQL(original, in: id)
        await feature.runSQL(in: id, scope: .selection(statement), selectionRange: range)
        let tab = try #require(feature.selectedSQLTab)
        #expect(tab.sql == statement + "\n select\n    '😀' from customers\nwhere id>=1; ")
        let record = try #require(tab.statementExecutions.last)
        #expect(record.sql == "select\n    '😀' from customers\nwhere id>=1")
        #expect((tab.sql as NSString).substring(with: try #require(record.sourceRange)) == record.sql + ";")
        // A string-only caller cannot replace the wrong copy of repeated text.
        feature.updateSQL(original, in: id)
        await feature.runSQL(in: id, scope: .selection(statement))
        #expect(feature.selectedSQLTab?.sql == original)
        #expect(feature.selectedSQLTab?.statementExecutions.last?.sourceRange == nil)
        feature.updateSQL("select * from customers where id>=1;", in: id)
        await feature.runSQL(in: id)
        #expect(feature.selectedSQLTab?.sql == "select\n    * from customers\nwhere id>=1;")
    }

    @Test func historyPreviewUsesReadOnlyCompactNativeGutter() throws {
        let host = NSHostingView(rootView: SQLSyntaxEditor(text: .constant("SELECT\n  1;"), completions: [], onRun: {}, onSelectionChange: { _ in }, isEditable: false)
            .environmentObject(AppSettings(store: DatabaseLifecyclePreferences())))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 300)
        host.layoutSubtreeIfNeeded()
        func editor(_ view: NSView) -> SQLTextView? {
            if let text = view as? SQLTextView { return text }
            return view.subviews.lazy.compactMap { editor($0) }.first
        }
        let text = try #require(editor(host))
        let gutter = try #require(text.gutter)
        #expect(!text.isEditable)
        #expect(text.isSelectable)
        #expect(gutter.bounds.width == gutter.consoleLineNumberOnlyWidth)
        #expect(gutter.bounds.width < EditorLayoutMetrics.standardGutterWidth)
    }

    @Test(arguments: ["stay", "otherTable", "returnToTable", "otherConnection", "returnToConnection"], [false, true])
    func delayedApplyLocksDraftsAndPreservesNavigation(destination: String, fails: Bool) async throws {
        let preferences = DatabaseLifecyclePreferences()
        let store = DatabaseConnectionStore(store: preferences, secureStore: DatabaseLifecycleSecrets())
        let profile = DatabaseProfile(name: "Apply fixture", kind: .mongodb, database: "fixture")
        let otherProfile = DatabaseProfile(name: "Other apply fixture", kind: .mongodb, database: "other_fixture")
        try store.save([profile, otherProfile])
        let runner = GatedDatabaseApplyRunner(fails: fails)
        let feature = DatabaseFeatureModel(operations: DatabaseSidecarService(processRunner: runner, executableURL: URL(fileURLWithPath: "/fixture/database")), connectionStore: store)
        defer { runner.release.open(); feature.prepareForModuleRelease() }
        feature.activateProfile(profile)
        await feature.openTable("customers")
        let inserted: [DatabaseRow] = [["name": .string("A")]]
        feature.tableInsertedRows = inserted
        feature.tableCellDrafts = [DatabaseCellKey(row: 0, column: "name"): .string("updated")]
        feature.tableDeletedRows = [1]
        let submittedDrafts = feature.tableCellDrafts
        let task = Task {
            await feature.apply(drafts: submittedDrafts.map { DatabaseCellDraft(rowIndex: $0.key.row, column: $0.key.column, value: $0.value) }, insertedRows: inserted, deletedIndexes: [1])
        }
        #expect(await runner.entered.waitUntilOpen())
        #expect(feature.isApplyingTableEdits)
        // These are the shared mutation paths used by typing, TSV paste, batch edits and delete.
        feature.tableInsertedRows[0]["name"] = .string("B")
        feature.tableCellDrafts.removeAll()
        feature.tableDeletedRows.removeAll()
        #expect(feature.tableInsertedRows == inserted)
        #expect(feature.tableCellDrafts == submittedDrafts)
        #expect(feature.tableDeletedRows == [1])
        #expect(await feature.apply(drafts: [], insertedRows: inserted, deletedIndexes: []) == false)
        await feature.loadPage(filters: [], sort: [], offset: 200)
        await feature.refreshTables()
        #expect(feature.currentOffset == 0)
        let otherCell = DatabaseCellKey(row: 0, column: "name")
        if destination == "otherConnection" || destination == "returnToConnection" {
            await feature.select(otherProfile)
            #expect(feature.tables.contains("customers"))
            await feature.openTable("customers")
            #expect(!feature.isApplyingTableEdits)
            #expect(!feature.isLoading)
            #expect(feature.hasActiveModuleWork) // The background connection still owns its write.
            feature.tableCellDrafts[otherCell] = .string("other connection draft")
            #expect(feature.tableCellDrafts[otherCell] == .string("other connection draft"))
            if destination == "returnToConnection" {
                await feature.select(profile)
                #expect(feature.isApplyingTableEdits)
                #expect(feature.isLoading) // The write owns the lock; returning queues its refresh.
            }
        } else if destination != "stay" {
            await feature.openTable("orders")
            if destination == "returnToTable" { await feature.openTable("customers") }
        }
        let pagesBeforeCompletion = runner.pageRequests
        runner.release.open()
        #expect(await task.value == !fails)
        #expect(!feature.isApplyingTableEdits)
        #expect(!feature.isLoading)
        #expect(feature.selectedTable == (destination == "otherTable" ? "orders" : "customers"))
        #expect(feature.tableApplyFailed == (fails && destination == "stay"))
        if destination == "otherConnection" {
            #expect(feature.selectedProfileID == otherProfile.id)
            #expect(feature.tableCellDrafts[otherCell] == .string("other connection draft"))
            #expect(!feature.hasActiveModuleWork)
        } else if destination == "stay", fails {
            #expect(feature.tableInsertedRows == inserted)
        } else {
            #expect(!feature.hasTableEdits)
            #expect(await feature.apply(drafts: [], insertedRows: feature.tableInsertedRows, deletedIndexes: []) == true)
        }
        #expect(runner.applyRequests == 1)
        #expect(runner.pageRequests == pagesBeforeCompletion + ((destination == "stay" && !fails) || ["otherTable", "returnToTable", "returnToConnection"].contains(destination) ? 1 : 0))
    }

    @Test(arguments: [false, true], [false, true])
    func sidebarTableSelectionDuringApplyLoadsLastSelection(returnToFirst: Bool, fails: Bool) async throws {
        let preferences = DatabaseLifecyclePreferences()
        let store = DatabaseConnectionStore(store: preferences, secureStore: DatabaseLifecycleSecrets())
        let profile = DatabaseProfile(name: "Sidebar apply fixture", kind: .mongodb, database: "fixture")
        try store.save([profile])
        let settings = AppSettings(store: preferences)
        let model = AppModel(settings: settings, services: MacServiceContainer(store: preferences, settings: settings, moduleLaunchMode: .safeMode).services)
        let runner = GatedDatabaseApplyRunner(fails: fails)
        let feature = DatabaseFeatureModel(operations: DatabaseSidecarService(processRunner: runner, executableURL: URL(fileURLWithPath: "/fixture/database")), connectionStore: store)
        defer { runner.release.open(); feature.prepareForModuleRelease() }
        model.cacheModuleCapability(DatabaseModuleCapability(feature: feature), id: .databaseWorkspace, moduleID: .database)
        feature.activateProfile(profile)
        await feature.openTable("customers")
        let task = Task { await feature.apply(drafts: [], insertedRows: [["name": .string("A")]], deletedIndexes: []) }
        #expect(await runner.entered.waitUntilOpen())
        // Use the same synchronous navigation + scheduled I/O entry as the sidebar click.
        model.selectDatabaseWorkspace(profileID: profile.id, table: "orders")
        if returnToFirst { model.selectDatabaseWorkspace(profileID: profile.id, table: "customers") }
        let expectedTable = returnToFirst ? "customers" : "orders"
        #expect(feature.selectedTable == expectedTable)
        #expect(feature.rows.isEmpty) // Never display the old page under the newly selected table.
        #expect(feature.isLoading && feature.isApplyingTableEdits)
        runner.release.open()
        #expect(await task.value == !fails)
        #expect(await awaitChange(on: feature, until: { !feature.isLoading && !feature.rows.isEmpty }))
        #expect(feature.selectedTable == expectedTable)
        #expect(feature.rows.first?["name"] == .string(expectedTable))
        #expect(!feature.isApplyingTableEdits)
        #expect(runner.applyRequests == 1)
        await model.shutdownProjectSession()
    }

    @Test(arguments: ["execute", "query", "batch", "partialBatch"], [(false, false), (false, true), (true, false), (true, true)])
    func sqlExecutionLockSurvivesConnectionNavigation(method: String, scenario: (Bool, Bool)) async throws {
        let (returnBeforeCompletion, fails) = scenario
        let store = DatabaseConnectionStore(store: DatabaseLifecyclePreferences(), secureStore: DatabaseLifecycleSecrets())
        let first = DatabaseProfile(name: "SQL A", kind: .sqlite, database: "first")
        let second = DatabaseProfile(name: "SQL B", kind: .sqlite, database: "second")
        try store.save([first, second])
        let recoveryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-navigation-sql-\(UUID())")
        defer { try? FileManager.default.removeItem(at: recoveryRoot) }
        let isBatch = method == "batch" || method == "partialBatch"
        let sentBeforeNavigation = method == "partialBatch" ? 2 : 1
        let runner = GatedSQLNavigationRunner(method: isBatch ? "execute" : method, fails: fails, gatedRequest: sentBeforeNavigation)
        let feature = DatabaseFeatureModel(
            operations: DatabaseSidecarService(processRunner: runner, executableURL: URL(fileURLWithPath: "/fixture/database")),
            connectionStore: store, recoveryStore: MacDatabaseRecoveryStore(rootURL: recoveryRoot), fileStorage: MacFileStorage()
        )
        defer { runner.release.open(); feature.prepareForModuleRelease() }
        await feature.select(first)
        let statementCount = isBatch ? sentBeforeNavigation + 1 : 1
        let sql = method == "query" ? "SELECT 1" : (1...statementCount).map { "INSERT INTO items VALUES (\($0));" }.joined(separator: " ")
        feature.addSQLTab(sql: sql)
        let tabID = try #require(feature.selectedSQLTabID)
        let task = Task { await feature.runSQL(in: tabID) }
        #expect(await runner.entered.waitUntilOpen())
        await feature.select(second)
        #expect(!feature.isLoading)
        #expect(feature.hasActiveModuleWork)
        #expect(feature.sqlTab(tabID, profileID: first.id)?.isRunning == true)
        if returnBeforeCompletion {
            await feature.select(first)
            #expect(feature.selectedSQLTab?.isRunning == true)
            await feature.runSQL(in: tabID)
            #expect(runner.requests == sentBeforeNavigation)
        }
        runner.release.open()
        await task.value
        #expect(!feature.hasActiveModuleWork)
        #expect(feature.sqlTab(tabID, profileID: first.id)?.isRunning == false)
        if !returnBeforeCompletion { await feature.select(first) }
        #expect(feature.selectedSQLTab?.isRunning == false)
        #expect(feature.selectedSQLTab?.result == nil) // Stale completion never repopulates a restored page.
        #expect(runner.requests == sentBeforeNavigation)
        // Durable logs belong to A even when the UI is on B or A has a new generation.
        let history = store.loadSQLHistory()
        #expect(history.count == 1 && history.first?.profileID == first.id)
        let persisted = MacDatabaseRecoveryStore(rootURL: recoveryRoot)
        let events = persisted.executionEvents()
        #expect(events.count == 1 && events.first?.profileID == first.id)
        #expect(events.first?.status == (fails ? .failed : (isBatch ? .cancelled : .succeeded)))
        let completedWrites = method == "query" ? 0 : sentBeforeNavigation - (fails ? 1 : 0)
        let affected: UInt64? = completedWrites > 0 ? UInt64(completedWrites) : nil
        #expect(events.first?.rowsAffected == affected)
        #expect(history.first?.rowsAffected == affected)
        let audit = persisted.auditEntries().filter { $0.action == "sql" }
        #expect(audit.count == 1 && audit.first?.profileID == first.id)
        #expect(audit.first?.succeeded == (!fails && !isBatch))
        #expect(audit.first?.rowsAffected == affected)
        if isBatch, !fails {
            let progress = "\(sentBeforeNavigation) of \(statementCount)"
            #expect(events.first?.errorMessage?.contains(progress) == true)
            #expect(audit.first?.summary.contains(progress) == true)
        }
        if method == "partialBatch", fails {
            #expect(events.first?.errorMessage?.contains("Statement 2 failed") == true)
        }
        await feature.runSQL(in: tabID)
        #expect(runner.requests == (sentBeforeNavigation + (fails ? 1 : statementCount))) // Only a new explicit run sends the next request.
        #expect((feature.selectedSQLTab?.errorMessage != nil) == fails)
        #expect(!feature.hasActiveModuleWork)
    }

    @Test(arguments: [false, true], [false, true])
    func reselectingFilteredTableDiscardsDraftsBeforeReplacingKeys(sorted: Bool, fails: Bool) async throws {
        let store = DatabaseConnectionStore(store: DatabaseLifecyclePreferences(), secureStore: DatabaseLifecycleSecrets())
        let profile = DatabaseProfile(name: "Reload fixture", kind: .mongodb, database: "fixture")
        try store.save([profile])
        let runner = ReloadedTableKeysRunner(fails: fails)
        let feature = DatabaseFeatureModel(operations: DatabaseSidecarService(processRunner: runner, executableURL: URL(fileURLWithPath: "/fixture/database")), connectionStore: store)
        defer { feature.prepareForModuleRelease() }
        await feature.select(profile)
        await feature.openTable("customers")
        await feature.loadPage(filters: sorted ? [] : [DatabaseFilter(column: "id", value: .integer(2))],
                               sort: sorted ? [DatabaseSort(column: "id", descending: true)] : [], offset: 0)
        #expect(feature.rows.first?["id"] == .integer(2))
        feature.tableCellDrafts[DatabaseCellKey(row: 0, column: "name")] = .string("edited id 2")
        feature.selectTable("customers")
        await feature.openTable("customers")
        #expect(!feature.hasTableEdits)
        #expect(!feature.isLoading)
        #expect((feature.errorMessage != nil) == fails)
        #expect(feature.rows.first?["id"] == (fails ? nil : .integer(1)))
        let drafts = feature.tableCellDrafts.map { DatabaseCellDraft(rowIndex: $0.key.row, column: $0.key.column, value: $0.value) }
        #expect(await feature.apply(drafts: drafts, insertedRows: feature.tableInsertedRows, deletedIndexes: feature.tableDeletedRows))
        #expect(runner.applyRequests == 0) // Old index 0 must never become an UPDATE/DELETE for id 1.
    }

    @Test(arguments: ["stay", "otherTable", "otherConnection", "newerPage"], [false, true])
    func delayedPageOnlyClearsItsOwnCurrentDrafts(destination: String, fails: Bool) async throws {
        let store = DatabaseConnectionStore(store: DatabaseLifecyclePreferences(), secureStore: DatabaseLifecycleSecrets())
        let first = DatabaseProfile(name: "Page fixture", kind: .mongodb, database: "first")
        let second = DatabaseProfile(name: "Other page fixture", kind: .mongodb, database: "second")
        try store.save([first, second])
        let runner = GatedDatabasePageRunner(fails: fails)
        let feature = DatabaseFeatureModel(operations: DatabaseSidecarService(processRunner: runner, executableURL: URL(fileURLWithPath: "/fixture/database")), connectionStore: store)
        defer { runner.release.open(); feature.prepareForModuleRelease() }
        await feature.select(first)
        await feature.openTable("customers")
        let cell = DatabaseCellKey(row: 0, column: "name")
        feature.tableCellDrafts[cell] = .string("old page draft")
        let task = Task { await feature.loadPage(filters: [], sort: [], offset: 200) }
        #expect(await runner.entered.waitUntilOpen())
        switch destination {
        case "otherTable": await feature.openTable("orders")
        case "otherConnection":
            await feature.select(second)
            await feature.openTable("customers")
        case "newerPage": await feature.loadPage(filters: [], sort: [], offset: 400)
        default: break
        }
        feature.tableCellDrafts[cell] = .string("current page draft")
        feature.tableInsertedRows = [["name": .string("new row")]]
        feature.tableDeletedRows = [1]
        feature.tableApplyFailed = true
        let rows = feature.rows
        let offset = feature.currentOffset
        let profileID = feature.selectedProfileID
        let table = feature.selectedTable
        runner.release.open()
        await task.value
        #expect(feature.selectedProfileID == profileID)
        #expect(feature.selectedTable == table)
        #expect(!feature.isLoading)
        if destination == "stay" {
            #expect(!feature.hasTableEdits)
            #expect(!feature.tableApplyFailed)
            #expect((feature.errorMessage != nil) == fails)
        } else {
            #expect(feature.tableCellDrafts[cell] == .string("current page draft"))
            #expect(feature.tableInsertedRows == [["name": .string("new row")]])
            #expect(feature.tableDeletedRows == [1])
            #expect(feature.tableApplyFailed)
            #expect(feature.rows == rows)
            #expect(feature.currentOffset == offset)
            #expect(feature.errorMessage == nil)
        }
        await feature.loadPage(filters: [], sort: [], offset: 0)
        #expect(!feature.hasTableEdits)
        #expect(!feature.tableApplyFailed)
        #expect(feature.rows.count == 2)
    }

    @Test(arguments: ["current", "background", "last"])
    func removingConnectionClosesOwnedTabsAndFallsBack(destination: String) async throws {
        let preferences = DatabaseLifecyclePreferences()
        let store = DatabaseConnectionStore(store: preferences, secureStore: DatabaseLifecycleSecrets())
        let first = DatabaseProfile(name: "First", kind: .sqlite, database: "first")
        let second = DatabaseProfile(name: "Second", kind: .sqlite, database: "second")
        try store.save(destination == "last" ? [first] : [first, second])
        let settings = AppSettings(store: preferences)
        let model = AppModel(settings: settings, services: MacServiceContainer(store: preferences, settings: settings, moduleLaunchMode: .safeMode).services)
        let recoveryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: recoveryRoot) }
        let feature = DatabaseFeatureModel(operations: DatabaseSidecarService(processRunner: EmptyDatabaseWorkspaceRunner(), executableURL: URL(fileURLWithPath: "/fixture/database")), connectionStore: store, recoveryStore: MacDatabaseRecoveryStore(rootURL: recoveryRoot))
        defer { feature.prepareForModuleRelease() }
        model.cacheModuleCapability(DatabaseModuleCapability(feature: feature), id: .databaseWorkspace, moduleID: .database)
        await feature.select(first)
        model.openDatabaseWorkspace()
        model.openDatabaseQuery(profileID: first.id, sql: "SELECT 1")
        if destination != "last" {
            await feature.select(second)
            model.openDatabaseWorkspace()
        }
        let removed = destination == "current" ? second : first
        model.removeDatabaseConnection(removed)
        #expect(!feature.profiles.contains(where: { $0.id == removed.id }))
        #expect(!model.editorTabOrderFeature.items.contains { item in
            switch item {
            case .database(let id): return id == removed.id
            case .databaseQuery(let id, _): return id == removed.id
            default: return false
            }
        })
        if destination == "last" {
            #expect(!model.editorTabOrderFeature.databaseSelected)
            #expect(!model.isDatabaseWorkspaceSelected)
            #expect(model.editorTabOrderFeature.items.isEmpty)
        } else {
            #expect(model.isDatabaseWorkspaceSelected)
            #expect(model.editorTabOrderFeature.databaseProfileSelected == (destination == "current" ? first.id : second.id))
            #expect(await awaitChange(on: feature, until: { !feature.isLoading }))
        }
        await model.shutdownProjectSession()
    }

    @Test
    func backgroundConnectionManagementPreservesEditorSelection() async throws {
        let preferences = DatabaseLifecyclePreferences()
        let store = DatabaseConnectionStore(store: preferences, secureStore: DatabaseLifecycleSecrets())
        let first = DatabaseProfile(name: "First", kind: .sqlite, database: "first")
        let second = DatabaseProfile(name: "Second", kind: .sqlite, database: "second")
        try store.save([first, second])
        let settings = AppSettings(store: preferences)
        let model = AppModel(settings: settings, services: MacServiceContainer(store: preferences, settings: settings, moduleLaunchMode: .safeMode).services)
        let feature = DatabaseFeatureModel(operations: DatabaseSidecarService(processRunner: TableEditsWorkspaceRunner(), executableURL: URL(fileURLWithPath: "/fixture/database")), connectionStore: store)
        defer { feature.prepareForModuleRelease() }
        model.cacheModuleCapability(DatabaseModuleCapability(feature: feature), id: .databaseWorkspace, moduleID: .database)
        await feature.select(first)
        model.openDatabaseQuery(profileID: first.id, sql: "SELECT 1")
        let active = model.activeDatabaseEditorTab
        let tabs = model.editorTabItems
        await feature.refresh(second)
        #expect(feature.selectedProfileID == first.id)
        #expect(await feature.add(DatabaseProfile(name: "Third", kind: .sqlite, database: "third"), password: ""))
        #expect(feature.selectedProfileID == first.id)
        #expect(model.activeDatabaseEditorTab == active)
        // Even a feature-level selection cannot manufacture or select an editor tab.
        await feature.select(second)
        #expect(model.activeDatabaseEditorTab == active)
        #expect(model.editorTabItems == tabs)
        #expect(model.isDatabaseWorkspaceSelected)
        await model.shutdownProjectSession()
    }

    @Test(arguments: ["success", "failure", "cancel", "release"])
    func draftConnectionTestDoesNotSaveOrNavigate(outcome: String) async throws {
        let store = DatabaseConnectionStore(store: DatabaseLifecyclePreferences(), secureStore: DatabaseFolderSecrets())
        let saved = DatabaseProfile(name: "Saved", kind: .mysql)
        try store.save([saved])
        try store.savePassword("saved-secret", for: saved.id)
        let runner = GatedBackgroundSaveRunner(operation: "idle", fails: outcome == "failure")
        let feature = DatabaseFeatureModel(operations: DatabaseSidecarService(processRunner: runner,
            executableURL: URL(fileURLWithPath: "/fixture/database")), connectionStore: store)
        defer { runner.saveRelease.open(); feature.prepareForModuleRelease() }
        feature.activateProfile(saved)
        await feature.refreshTables()
        let status = feature.connectionStatus(for: saved)
        var draft = saved
        draft.name = "Unsaved"
        let probe = Task { try await feature.testConnection(draft, password: "draft-secret") }
        defer { probe.cancel() }
        #expect(await runner.saveEntered.waitUntilOpen())
        #expect(feature.connectionStatus(for: saved) == status)
        #expect(!feature.isLoading)
        if outcome == "cancel" { probe.cancel() }
        if outcome == "release" { feature.prepareForModuleRelease() }
        runner.saveRelease.open()
        do {
            try await probe.value
            #expect(outcome == "success")
        } catch {
            #expect(outcome != "success")
            if outcome == "cancel" || outcome == "release" { #expect(error is CancellationError) }
        }
        #expect(store.load() == [saved])
        #expect(store.password(for: saved.id) == "saved-secret")
        #expect(feature.connectionStatus(for: saved) == status)
        if outcome != "release" { #expect(feature.selectedProfileID == saved.id) }
        #expect(feature.errorMessage == nil)
    }

    @Test(arguments: ["idle", "refresh", "open", "page"], [(false, false), (false, true), (true, false), (true, true)])
    func backgroundSavePreservesCurrentLoading(operation: String, scenario: (Bool, Bool)) async throws {
        let (saveFirst, fails) = scenario
        let store = DatabaseConnectionStore(store: DatabaseLifecyclePreferences(), secureStore: DatabaseLifecycleSecrets())
        let first = DatabaseProfile(name: "First", kind: .sqlite, database: "first")
        let second = DatabaseProfile(name: "Second", kind: .sqlite, database: "second")
        try store.save([first, second])
        let runner = GatedBackgroundSaveRunner(operation: operation, fails: fails)
        let feature = DatabaseFeatureModel(
            operations: DatabaseSidecarService(processRunner: runner, executableURL: URL(fileURLWithPath: "/fixture/database")),
            connectionStore: store
        )
        defer { runner.loadRelease.open(); runner.saveRelease.open(); feature.prepareForModuleRelease() }
        feature.activateProfile(first)
        if operation == "idle" { await feature.refreshTables() }
        if operation == "page" { await feature.openTable("customers") }
        let load = Task { @MainActor in
            switch operation {
            case "refresh": await feature.refreshTables()
            case "open": await feature.openTable("customers")
            case "page": await feature.loadPage(filters: [], sort: [], offset: 200)
            default: break
            }
        }
        if operation != "idle" { #expect(await runner.loadEntered.waitUntilOpen()) }
        else { await load.value }
        #expect(feature.isLoading == (operation != "idle"))
        let save = Task { @MainActor in await feature.update(second, password: nil) }
        #expect(await runner.saveEntered.waitUntilOpen())
        #expect(feature.connectionStatus(for: second) == .connecting)
        #expect(feature.isLoading == (operation != "idle"))
        // Control both completion orders without sleeps; neither B's start nor finish owns A's loading.
        if saveFirst {
            runner.saveRelease.open()
            #expect(await save.value == !fails)
            #expect(feature.isLoading == (operation != "idle"))
            runner.loadRelease.open()
            await load.value
        } else {
            runner.loadRelease.open()
            await load.value
            #expect(!feature.isLoading)
            runner.saveRelease.open()
            #expect(await save.value == !fails)
        }
        #expect(!feature.isLoading)
        #expect(feature.selectedProfileID == first.id)
        #expect(feature.connectionStatus(for: second) == (fails ? .failed : .connected))
    }

    @Test(arguments: [false, true], [DatabaseKind.sqlite, .redis])
    func retainedViewsRenderAfterProjectSessionShutdown(hasSelectedConnection: Bool, kind: DatabaseKind) async throws {
        let preferences = DatabaseLifecyclePreferences()
        let connectionStore = DatabaseConnectionStore(store: preferences, secureStore: DatabaseLifecycleSecrets())
        let profile = DatabaseProfile(name: "Lifecycle fixture", kind: kind, path: "/fixture/lifecycle.sqlite")
        try connectionStore.save([profile])
        let settings = AppSettings(store: preferences)
        let services = MacServiceContainer(
            store: preferences, settings: settings, moduleLaunchMode: .safeMode
        ).services
        let model = AppModel(settings: settings, services: services)
        let feature = DatabaseFeatureModel(
            operations: DatabaseSidecarService(processRunner: DatabaseLifecycleProcessRunner(), executableURL: nil),
            connectionStore: connectionStore
        )
        defer { feature.prepareForModuleRelease() }
        #expect(DatabaseWorkspaceTabTitle(feature: feature, profileID: feature.selectedProfileID).title == "SQL History")
        feature.selectedProfileID = profile.id
        for section in DatabaseWorkspaceSection.allCases {
            feature.workspaceSection = section
            #expect(DatabaseWorkspaceTabTitle(feature: feature, profileID: profile.id).title == profile.name)
        }
        feature.selectedProfileID = nil
        if hasSelectedConnection {
            feature.selectedProfileID = profile.id
            feature.workspaceSection = .sql
        }
        let databaseTab = EditorTabItem.database(feature.selectedProfileID)
        model.cacheModuleCapability(DatabaseModuleCapability(feature: feature), id: .databaseWorkspace, moduleID: .database)
        model.workbenchFeature.setVisibility(.database, isVisible: true)
        #expect(model.selectedSidebar == .project)
        #expect(!model.editorTabItems.contains(databaseTab))
        model.openDatabaseWorkspace()
        model.openDatabaseWorkspace()
        #expect(model.editorTabItems.filter { $0 == databaseTab }.count == 1)
        #expect(model.isDatabaseWorkspaceSelected)
        model.workbenchFeature.setVisibility(.database, isVisible: false)
        #expect(model.isDatabaseWorkspaceSelected)
        #expect(model.requestCloseActiveWorkbenchItem())
        #expect(!model.editorTabItems.contains(databaseTab))
        model.openDatabaseWorkspace()
        feature.addSQLTab(sql: "SELECT 'retained draft'")
        let draftID = feature.selectedSQLTabID
        model.openDatabaseWorkspace(overview: true)
        model.openDatabaseWorkspace(overview: true)
        #expect(model.editorTabItems.filter { $0 == .databaseOverview }.count == 1)
        #expect(model.editorTabItems.contains(databaseTab))
        #expect(model.editorTabOrderFeature.databaseOverviewSelected)
        model.editorTabOrderFeature.reconcileDocuments(orderedIDs: [])
        #expect(model.editorTabItems.contains(.databaseOverview))
        #expect(model.requestCloseActiveWorkbenchItem())
        #expect(!model.editorTabItems.contains(.databaseOverview))
        #expect(model.editorTabItems.contains(databaseTab))
        #expect(model.isDatabaseWorkspaceSelected)
        #expect(!model.editorTabOrderFeature.databaseOverviewSelected)
        #expect(feature.selectedSQLTabID == draftID)
        #expect(feature.selectedSQLTab?.sql == "SELECT 'retained draft'")
        model.openDatabaseWorkspace(overview: true)
        model.closeDatabaseWorkspace(overview: false)
        #expect(model.isDatabaseWorkspaceSelected)
        #expect(model.editorTabOrderFeature.databaseOverviewSelected)
        model.openDatabaseWorkspace()

        func content(revision: Int) -> AnyView {
            AnyView(HStack(spacing: 0) {
                DatabaseSidebarView().frame(width: 280)
                VStack {
                    if feature.workspaceSection == .sql { DatabaseSQLWorkspaceView() }
                    else { DatabaseWorkspaceView() }
                    DatabaseOverviewView()
                }.frame(width: 760, height: 550)
            }
            .id(revision)
            .environmentObject(feature)
            .environmentObject(model)
            .environmentObject(settings))
        }
        let host = NSHostingView(rootView: content(revision: 0))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 550),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width > 0)
        #expect(model.databaseFeatureIfActive === feature)
        // The same native host must survive all four page renderers, including
        // their empty states, without starting a database process.
        if hasSelectedConnection {
            for section in DatabaseWorkspaceSection.allCases {
                feature.workspaceSection = section
                host.rootView = content(revision: 2)
                host.layoutSubtreeIfNeeded()
                #expect(host.fittingSize.width > 0)
            }
        }

        // Keep the native host alive across cache teardown, then force another
        // body evaluation. A parent sidebar guard cannot protect this ordering.
        feature.prepareForModuleRelease()
        await model.shutdownProjectSession()
        #expect(model.databaseFeatureIfActive == nil)
        #expect(!model.editorTabItems.contains(databaseTab))
        #expect(!model.editorTabItems.contains(.databaseOverview))
        host.rootView = content(revision: 1)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width > 0)

        // Connection and schema sheets can also outlive the workspace subtree.
        host.rootView = AnyView(VStack {
            DatabaseConnectionEditor(isPresented: .constant(true))
            DatabaseSchemaDiffView()
        }.environmentObject(feature)
            .environmentObject(model)
            .environmentObject(settings))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width > 0)
    }

    @Test(arguments: [false, true])
    func consoleUsesEditorTypographyAndCoversTheBlankViewport(dark: Bool) async throws {
        let preferences = DatabaseLifecyclePreferences()
        let store = DatabaseConnectionStore(store: preferences, secureStore: DatabaseLifecycleSecrets())
        let profile = DatabaseProfile(name: "Console fixture", kind: .sqlite, path: "/fixture/console.sqlite")
        try store.save([profile])
        let settings = AppSettings(store: preferences)
        let model = AppModel(settings: settings, services: MacServiceContainer(store: preferences, settings: settings, moduleLaunchMode: .safeMode).services)
        let feature = DatabaseFeatureModel(operations: DatabaseSidecarService(processRunner: DatabaseLifecycleProcessRunner(), executableURL: nil), connectionStore: store)
        defer { feature.prepareForModuleRelease() }
        feature.activateProfile(profile)
        feature.addSQLTab(sql: "SELECT 12, '-- value' -- comment")
        let host = NSHostingView(rootView: VStack(spacing: 0) {
            LitheTheme.sidebar.frame(height: 20)
            DatabaseSQLWorkspaceView()
        }
            .environmentObject(feature).environmentObject(model).environmentObject(settings)
            .environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defer { window.contentView = nil; window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func editor(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        let textView = try #require(editor(in: host))
        let scroll = try #require(textView.enclosingScrollView)
        let gutter = try #require(scroll.superview?.subviews.compactMap { $0 as? LineNumberGutterView }.first)
        func pixel(_ view: NSView, at point: NSPoint) throws -> NSColor {
            let rect = NSRect(origin: point, size: NSSize(width: 1, height: 1))
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: rect))
            view.cacheDisplay(in: rect, to: bitmap)
            return try #require(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        }
        func expectSameRGB(_ first: NSColor, _ second: NSColor) {
            for (a, b) in zip([first.redComponent, first.greenComponent, first.blueComponent], [second.redComponent, second.greenComponent, second.blueComponent]) {
                #expect(abs(a - b) < 0.015)
            }
        }
        // Sample the outer edge: the current line must cover the whole gutter, not leave an inset.
        let line = LitheTextViewportLayout.consoleCaretLineRect(in: textView)
        expectSameRGB(try pixel(gutter, at: NSPoint(x: 0, y: line.midY)), try pixel(textView, at: NSPoint(x: 500, y: line.midY)))
        expectSameRGB(try pixel(gutter, at: NSPoint(x: 0, y: 100)), try pixel(textView, at: NSPoint(x: 500, y: 100)))
        // New UI positions the separator 3 logical pixels before the content origin.
        let separator = try pixel(gutter, at: NSPoint(x: gutter.bounds.width - 3, y: 100))
        let editorBackground = try pixel(textView, at: NSPoint(x: 500, y: 100))
        // Detect the line position in the rendered bitmap; color tokens have separate appearance tests.
        #expect(abs(separator.redComponent - editorBackground.redComponent) > 0.04)
        for x in [gutter.bounds.width - 2, gutter.bounds.width - 1] {
            expectSameRGB(try pixel(gutter, at: NSPoint(x: x, y: 100)), try pixel(textView, at: NSPoint(x: 500, y: 100)))
        }
        #expect(textView.textLayoutManager == nil) // Console and its shared gutter use TextKit 1 from creation.
        scroll.layoutSubtreeIfNeeded()
        // Like the main editor, native views leave the structural background to the SwiftUI pane.
        #expect(!textView.drawsBackground)
        #expect(!scroll.drawsBackground)
        #expect(!scroll.contentView.drawsBackground)
        #expect(!gutter.isOpaque)
        // Compare the composed pixels, including native children, with a sidebar surface in this window.
        let sidebarPoint = NSPoint(x: 500, y: host.isFlipped ? 10 : host.bounds.maxY - 10)
        let canvasPoint = host.convert(NSPoint(x: 500, y: 100), from: textView)
        #expect(try pixel(host, at: canvasPoint) == pixel(host, at: sidebarPoint))
        #expect(textView.font?.pointSize == 13)
        #expect(textView.defaultParagraphStyle?.lineHeightMultiple == 1.2)
        #expect(textView.textContainerOrigin.x + (textView.textContainer?.lineFragmentPadding ?? 0) == 0)
        let storage = try #require(textView.textStorage)
        #expect((storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 13)
        #expect(!(textView.font?.fontDescriptor.symbolicTraits.contains(.bold) ?? true))
        let completions = textView.delegate?.textView?(textView, completions: [], forPartialWordRange: NSRange(location: 0, length: 3), indexOfSelectedItem: nil)
        #expect(completions == ["SELECT"])
        let literal = (storage.string as NSString).range(of: "'-- value'")
        let quoteColor = storage.attribute(.foregroundColor, at: literal.location, effectiveRange: nil) as? NSColor
        let markerColor = storage.attribute(.foregroundColor, at: literal.location + 1, effectiveRange: nil) as? NSColor
        #expect(quoteColor == markerColor)
        #expect(textView.frame.height >= scroll.contentSize.height)
        // Empty space below a short query stays editable when the console is taller than its old 240pt document.
        #expect(scroll.contentSize.height > 240)
        let hoverPoint = textView.convert(NSPoint(x: 4, y: scroll.documentVisibleRect.maxY - 4), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: hoverPoint, modifierFlags: [], timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        textView.cursorUpdate(with: event)
        #expect(NSCursor.current == NSCursor.iBeam)
        let originalCursor = NSCursor.current
        defer { originalCursor.set() }
        textView.updateTrackingAreas()
        #expect(textView.trackingAreas.contains { $0.owner === textView && $0.options.contains([.inVisibleRect, .cursorUpdate, .mouseEnteredAndExited, .mouseMoved, .activeAlways]) })
        // Hover must work before focus, including the blank area below the query.
        window.makeFirstResponder(nil)
        NSCursor.arrow.set()
        textView.mouseEntered(with: event)
        #expect(NSCursor.current == NSCursor.iBeam)
        NSCursor.arrow.set()
        textView.mouseMoved(with: event)
        #expect(NSCursor.current == NSCursor.iBeam)
        let exit = try #require(NSEvent.enterExitEvent(with: .mouseExited, location: hoverPoint, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        NSCursor.resizeLeftRight.set()
        textView.mouseExited(with: exit)
        #expect(NSCursor.current == NSCursor.resizeLeftRight)
        #expect(textView.acceptsFirstMouse(for: event))
        // Native insertion hit testing clamps blank-space clicks to EOF without adding lines.
        for x in [CGFloat(4), scroll.contentSize.width - 4] {
            textView.setSelectedRange(NSRange(location: 0, length: 3))
            let point = NSPoint(x: x, y: scroll.contentSize.height - 20)
            #expect(textView.hitTest(point) === textView)
            #expect(textView.characterIndexForInsertion(at: point) == storage.length)
        }
        #expect(window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: storage.length, length: 0))
        textView.insertText("\nSELECT 2", replacementRange: textView.selectedRange())
        #expect(feature.selectedSQLTab?.sql.hasSuffix("\nSELECT 2") == true)
        #expect((textView.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.lineHeightMultiple == 1.2)
        textView.insertText("\n", replacementRange: textView.selectedRange())
        #expect(gutter.currentConsoleLine == 3)
        let emptyFinalLine = LitheTextViewportLayout.consoleCaretLineRect(in: textView)
        #expect(emptyFinalLine.minY > line.minY)
        expectSameRGB(try pixel(gutter, at: NSPoint(x: 0, y: emptyFinalLine.midY)), try pixel(textView, at: NSPoint(x: 500, y: emptyFinalLine.midY)))
        // AppKit suppresses selection notifications during mouse tracking. Chrome must already follow the caret.
        textView.setSelectedRange(NSRange(location: 0, length: 0), affinity: .downstream, stillSelecting: true)
        #expect(gutter.currentConsoleLine == 1)
        expectSameRGB(try pixel(gutter, at: NSPoint(x: 0, y: line.midY)), try pixel(textView, at: NSPoint(x: 500, y: line.midY)))
        textView.setSelectedRanges([NSValue(range: NSRange(location: storage.length, length: 0))], affinity: .downstream, stillSelecting: true)
        #expect(gutter.currentConsoleLine == 3)
        textView.setSelectedRange(NSRange(location: storage.length, length: 0), affinity: .downstream, stillSelecting: false)
        func gutterImage(at y: CGFloat) throws -> Data {
            let rect = NSRect(x: 0, y: y, width: gutter.bounds.width - 1, height: 32)
            let bitmap = try #require(gutter.bitmapImageRepForCachingDisplay(in: rect))
            gutter.cacheDisplay(in: rect, to: bitmap)
            return try #require(bitmap.representation(using: .png, properties: [:]))
        }
        // The same line number must remain at the same baseline when the EOF fragment gains a glyph.
        let emptyNumber = try gutterImage(at: emptyFinalLine.minY)
        textView.insertText("2", replacementRange: textView.selectedRange())
        #expect(try gutterImage(at: emptyFinalLine.minY) == emptyNumber)
        // An entirely empty document uses a separate native layout path; protect it too.
        textView.setSelectedRange(NSRange(location: 0, length: storage.length))
        textView.insertText("", replacementRange: textView.selectedRange())
        #expect(gutter.currentConsoleLine == 1)
        let firstNumber = try gutterImage(at: 0)
        textView.insertText("1", replacementRange: textView.selectedRange())
        #expect(try gutterImage(at: 0) == firstNumber)
        // Community's 4 + 4 + 14pt areas right-align a one-digit number before x = 22.
        let numberRect = NSRect(x: 0, y: 0, width: gutter.bounds.width - 3,
                                height: floor(LitheTextViewportLayout.consoleCaretLineRect(in: textView).height))
        let numberBitmap = try #require(gutter.bitmapImageRepForCachingDisplay(in: numberRect))
        gutter.cacheDisplay(in: numberRect, to: numberBitmap)
        let background = try #require(numberBitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        var inkColumns = Set<Int>()
        for y in 0..<numberBitmap.pixelsHigh {
            for x in 0..<numberBitmap.pixelsWide {
                let color = try #require(numberBitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                if abs(color.redComponent - background.redComponent) > 0.05 { inkColumns.insert(x) }
            }
        }
        let rightmostInk = try #require(inkColumns.max())
        #expect(CGFloat(rightmostInk) * numberRect.width / CGFloat(numberBitmap.pixelsWide) < 22)
        window.setContentSize(NSSize(width: 500, height: 900))
        host.layoutSubtreeIfNeeded()
        scroll.layoutSubtreeIfNeeded()
        #expect(textView.frame.height >= scroll.contentSize.height)
        await model.shutdownProjectSession()
    }

    @Test
    func tableEditsSurviveConsoleRenderingAndBackgroundRefresh() async throws {
        let preferences = DatabaseLifecyclePreferences()
        let store = DatabaseConnectionStore(store: preferences, secureStore: DatabaseLifecycleSecrets())
        let profile = DatabaseProfile(name: "Table edits", kind: .mysql, database: "first_db")
        try store.save([profile])
        let settings = AppSettings(store: preferences)
        let model = AppModel(settings: settings, services: MacServiceContainer(store: preferences, settings: settings, moduleLaunchMode: .safeMode).services)
        let feature = DatabaseFeatureModel(operations: DatabaseSidecarService(processRunner: TableEditsWorkspaceRunner(), executableURL: URL(fileURLWithPath: "/fixture/database")), connectionStore: store)
        defer { feature.prepareForModuleRelease() }
        model.cacheModuleCapability(DatabaseModuleCapability(feature: feature), id: .databaseWorkspace, moduleID: .database)
        feature.activateProfile(profile)
        await feature.openTable("customers")
        let originalRows = feature.rows
        #expect(originalRows.count == 2)
        let cell = DatabaseCellKey(row: 0, column: "name")
        feature.tableCellDrafts[cell] = .string("edited")
        feature.tableInsertedRows = [["name": .string("new")]]
        feature.tableDeletedRows = [1]
        func dataView() -> AnyView {
            AnyView(DatabaseWorkspaceView().environmentObject(feature).environmentObject(model).environmentObject(settings))
        }
        let host = NSHostingView(rootView: dataView())
        host.frame = NSRect(x: 0, y: 0, width: 740, height: 550)
        host.layoutSubtreeIfNeeded()
        if let directory = ProcessInfo.processInfo.environment["LITHE_DATABASE_CAPTURE_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                URL(fileURLWithPath: directory).appendingPathComponent("database-drafts.png"))
        }
        model.openDatabaseQuery(profileID: profile.id, sql: "SELECT 1 AS x, 2 AS x")
        host.rootView = AnyView(DatabaseSQLWorkspaceView().environmentObject(feature).environmentObject(model).environmentObject(settings))
        let query = try #require(feature.selectedSQLTabID)
        await feature.runSQL(in: query)
        #expect(feature.selectedSQLTab?.resultColumns == ["x", "x"])
        host.rootView = AnyView(DatabaseServicesView().environmentObject(feature).environmentObject(model).environmentObject(settings))
        host.layoutSubtreeIfNeeded() // This renders the formerly crashing duplicate-column result.
        await feature.refreshTables()
        #expect(feature.rows == originalRows)
        model.selectDatabaseWorkspace(profileID: profile.id)
        host.rootView = dataView()
        host.layoutSubtreeIfNeeded()
        #expect(feature.tableCellDrafts[cell] == .string("edited"))
        #expect(feature.tableInsertedRows == [["name": .string("new")]])
        #expect(feature.tableDeletedRows == [1])
        feature.discardTableEdits()
        #expect(!feature.hasTableEdits)
        feature.tableCellDrafts[cell] = .null
        await feature.openTable("orders")
        #expect(!feature.hasTableEdits) // Edits must never attach to a different table.
        await model.shutdownProjectSession()
    }

    @Test
    func connectionAndConsoleTabsRestoreDraftsAndCloseIndependently() async throws {
        let preferences = DatabaseLifecyclePreferences()
        let store = DatabaseConnectionStore(store: preferences, secureStore: DatabaseLifecycleSecrets())
        let first = DatabaseProfile(name: "First", kind: .mysql, database: "first_db")
        let second = DatabaseProfile(name: "Second", kind: .sqlite, database: "second_db")
        try store.save([first, second])
        let settings = AppSettings(store: preferences)
        let model = AppModel(settings: settings, services: MacServiceContainer(
            store: preferences, settings: settings, moduleLaunchMode: .safeMode
        ).services)
        let feature = DatabaseFeatureModel(
            operations: DatabaseSidecarService(processRunner: EmptyDatabaseWorkspaceRunner(), executableURL: URL(fileURLWithPath: "/fixture/database")),
            connectionStore: store
        )
        defer { feature.prepareForModuleRelease() }
        model.cacheModuleCapability(DatabaseModuleCapability(feature: feature), id: .databaseWorkspace, moduleID: .database)
        do {
            await feature.select(first)
            model.openDatabaseWorkspace()
            model.openDatabaseWorkspace()
            model.openDatabaseQuery(profileID: first.id, sql: "SELECT 'first draft'")
            let firstQueryID = try #require(feature.selectedSQLTabID)
            let firstQuery = EditorTabItem.databaseQuery(profileID: first.id, queryID: firstQueryID)
            model.openDatabaseQuery(profileID: first.id, sql: "SELECT 'second draft'")
            let secondQueryID = try #require(feature.selectedSQLTabID)
            let secondQuery = EditorTabItem.databaseQuery(profileID: first.id, queryID: secondQueryID)
            #expect(model.editorTabItems == [.database(first.id), firstQuery, secondQuery])
            #expect(model.activeDatabaseEditorTab == secondQuery)
            #expect(model.isDatabaseWorkspaceSelected)
            #expect(DatabaseWorkspaceTabTitle(feature: feature, profileID: first.id, queryID: firstQueryID).title == "console [First]")
            await feature.refreshDatabases()
            await feature.selectDatabase("alternate_db", for: first)
            #expect(feature.selectedProfile?.database == "alternate_db")
            #expect(feature.selectedSQLTabID == secondQueryID)
            #expect(model.activeDatabaseEditorTab == secondQuery)
            #expect(feature.sqlTab(firstQueryID, profileID: first.id)?.sql == "SELECT 'first draft'")
            model.selectDatabaseWorkspace(profileID: first.id)
            #expect(feature.workspaceSection == .data)
            #expect(model.activeDatabaseEditorTab == .database(first.id))
            model.openDatabaseQuery(profileID: second.id, sql: "SELECT 'other connection'")
            #expect(await awaitChange(on: feature, until: { !feature.isLoading }))
            let otherQueryID = try #require(feature.selectedSQLTabID)
            let otherQuery = EditorTabItem.databaseQuery(profileID: second.id, queryID: otherQueryID)
            #expect(!model.editorTabItems.contains(.database(second.id)))
            #expect(feature.sqlTab(firstQueryID, profileID: first.id)?.sql == "SELECT 'first draft'")
            model.editorTabOrderFeature.reconcileDocuments(orderedIDs: [])
            #expect(model.editorTabItems.contains(firstQuery))
            // Closing a background console edits only its owning connection's draft cache.
            model.closeDatabaseTab(secondQuery)
            #expect(model.activeDatabaseEditorTab == otherQuery)
            #expect(feature.sqlTab(secondQueryID, profileID: first.id) == nil)
            model.selectDatabaseWorkspace(profileID: first.id, queryID: firstQueryID)
            #expect(await awaitChange(on: feature, until: { !feature.isLoading }))
            #expect(model.activeDatabaseEditorTab == firstQuery)
            #expect(feature.selectedSQLTab?.sql == "SELECT 'first draft'")
            #expect(model.requestCloseActiveWorkbenchItem())
            #expect(!model.editorTabItems.contains(firstQuery))
            #expect(model.editorTabItems.contains(.database(first.id)))
            #expect(model.activeDatabaseEditorTab == otherQuery)
            #expect(await awaitChange(on: feature, until: { !feature.isLoading }))
            #expect(feature.selectedSQLTab?.sql == "SELECT 'other connection'")
            model.openDatabaseWorkspace(overview: true)
            #expect(model.requestCloseActiveWorkbenchItem())
            #expect(model.activeDatabaseEditorTab == otherQuery)
            model.closeDatabaseWorkspace()
            #expect(model.editorTabItems.isEmpty)
            #expect(model.editorTabOrderFeature.databaseQuerySelected == nil)
        } catch {
            await model.shutdownProjectSession()
            throw error
        }
        await model.shutdownProjectSession()
    }

    @Test
    func sleepingModuleStopsResourcesWhileOldPresentationSurvivesAndWakeUsesNewFeature() async throws {
        let runtime = ModuleRuntime()
        let preferences = DatabaseLifecyclePreferences()
        try runtime.register(ModuleFactory(manifest: ModuleManifest(id: .workspace, displayName: "Workspace", scope: .workspace)) {
            DatabaseLifecycleWorkspaceModule()
        })
        try runtime.register(ModuleFactory(manifest: DatabaseModule.moduleManifest, contributions: DatabaseModule.moduleContributions) {
            DatabaseModule(
                processRunner: DatabaseLifecycleProcessRunner(), executableURL: nil,
                preferenceStore: preferences, secureStore: DatabaseLifecycleSecrets(),
                recoveryStore: UnavailableDatabaseRecoveryStore(), fileStorage: UnavailableDatabaseFileStorage()
            )
        })
        var notifications: [String] = []
        let coordinator = DatabaseModuleCoordinator(runtime: runtime, store: ModuleCapabilityStore(), onChange: {}, onError: { notifications.append($0) })
        do {
            var retained: DatabaseFeatureModel? = try #require(await coordinator.activate())
            #expect(await coordinator.activate() === retained)
            retained?.errorMessage = "Connection failed"
            #expect(notifications == ["Connection failed"])
            retained?.errorMessage = nil
            #expect(notifications.count == 1)
            weak var released = retained
            retained?.addSQLTab(sql: "SELECT 'old presentation'")

            await coordinator.sleep()
            retained?.errorMessage = "Late failure after sleep"
            #expect(notifications == ["Connection failed"])
            #expect(runtime.capability(.databaseWorkspace) == nil)
            #expect(try runtime.snapshot(for: .database).activity.activeResourceCount == 0)
            #expect(retained?.hasActiveModuleWork == false)
            #expect(retained?.selectedSQLTab?.sql == "SELECT 'old presentation'")

            let next = try #require(await coordinator.activate())
            next.errorMessage = "New connection failed"
            #expect(notifications == ["Connection failed", "New connection failed"])
            #expect(next !== retained)
            #expect(next.selectedSQLTab?.sql == "")
            retained?.updateSQL("SELECT 'late edit'", in: try #require(retained?.selectedSQLTabID))
            #expect(next.selectedSQLTab?.sql == "")
            retained = nil
            #expect(released == nil, "The old feature must be released when its presentation goes away")
        } catch {
            await runtime.shutdownAll()
            throw error
        }
        await runtime.shutdownAll()
    }

    @Test(arguments: ["document", "overview", "query", "close", "closeAll", "closeBeforeLoad"], [false, true])
    func delayedConnectionLoadPreservesLaterNavigation(destination: String, fails: Bool) async throws {
        let preferences = DatabaseLifecyclePreferences()
        let store = DatabaseConnectionStore(store: preferences, secureStore: DatabaseLifecycleSecrets())
        let first = DatabaseProfile(name: "First", kind: .redis)
        let second = DatabaseProfile(name: "Second", kind: .sqlite)
        try store.save([first, second])
        let settings = AppSettings(store: preferences)
        let model = AppModel(settings: settings, services: MacServiceContainer(
            store: preferences, settings: settings, moduleLaunchMode: .safeMode
        ).services)
        let runner = GatedDatabaseWorkspaceRunner(fails: fails)
        let feature = DatabaseFeatureModel(
            operations: DatabaseSidecarService(processRunner: runner, executableURL: URL(fileURLWithPath: "/fixture/database")),
            connectionStore: store
        )
        defer { runner.release.open(); feature.prepareForModuleRelease() }
        model.cacheModuleCapability(DatabaseModuleCapability(feature: feature), id: .databaseWorkspace, moduleID: .database)
        feature.activateProfile(first)
        #expect(!feature.isLoading && feature.connectionStatus(for: first) == .connected)
        model.documentFeature.openVirtualDocument(URL(string: "lithe-test://documents/Navigation.txt")!, text: "fixture", displayPath: nil)
        do {
            let document = try #require(model.openDocuments.first)
            model.selectDatabaseWorkspace(profileID: second.id)
            // The tab must become selected before I/O starts, so even a loading
            // connection is immediately closable. This fails with the old await-then-open path.
            #expect(feature.selectedProfileID == second.id)
            #expect(model.isDatabaseWorkspaceSelected)
            #expect(model.activeDatabaseEditorTab == .database(second.id))
            if destination == "closeBeforeLoad" { model.closeDatabaseTab(.database(second.id)) }
            #expect(await runner.entered.waitUntilOpen())
            #expect(feature.isLoading)
            switch destination {
            case "document": model.selectEditorDocument(document)
            case "overview": model.openDatabaseWorkspace(overview: true)
            case "query": model.openDatabaseQuery(profileID: second.id, sql: "SELECT 1")
            case "close": model.closeDatabaseTab(.database(second.id))
            case "closeBeforeLoad": break
            default: model.closeDatabaseWorkspace()
            }
            let expectedTabs = model.editorTabItems
            let expectedSelected = model.isDatabaseWorkspaceSelected
            let expectedOverview = model.editorTabOrderFeature.databaseOverviewSelected
            let expectedDatabaseTab = model.activeDatabaseEditorTab
            runner.release.open()
            #expect(await awaitChange(on: feature, until: { !feature.isLoading }))
            #expect((feature.errorMessage != nil) == fails)
            #expect(model.editorTabItems == expectedTabs)
            #expect(model.isDatabaseWorkspaceSelected == expectedSelected)
            #expect(model.editorTabOrderFeature.databaseOverviewSelected == expectedOverview)
            #expect(model.activeDatabaseEditorTab == expectedDatabaseTab)
            if destination == "document" { #expect(model.activeDocumentID == document.id) }
        } catch {
            runner.release.open()
            _ = await awaitChange(on: feature, until: { !feature.isLoading })
            await model.shutdownProjectSession()
            throw error
        }
        await model.shutdownProjectSession()
    }
}

@MainActor
private final class DatabaseLifecycleWorkspaceModule: LitheModule {
    let manifest = ModuleManifest(id: .workspace, displayName: "Workspace", scope: .workspace)
    func activate(context: ModuleContext) async throws {}
    func prepareForSleep() async throws {}
    func sleep() async {}
    func shutdown() async {}
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] { [:] }
}

private struct DatabaseLifecycleProcessRunner: DatabaseProcessRunning {
    func runDatabaseProcess(_ request: DatabaseProcessRequest) -> DatabaseProcessResult {
        Issue.record("Rendering database views must not launch a database process")
        return DatabaseProcessResult(output: "", exitCode: 1)
    }
}

private final class DatabaseLifecyclePreferences: KeyValueStore, DatabasePreferenceStore, @unchecked Sendable {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

private final class DatabaseFolderSecrets: DatabaseSecureStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var rejectsChanges = false
    private var reads = 0
    var readCount: Int { lock.withLock { reads } }
    func rejectChanges(_ reject: Bool) { lock.withLock { rejectsChanges = reject } }
    func read(key: String) -> String? { lock.withLock { reads += 1; return values[key] } }
    func write(_ value: String, key: String) throws {
        try lock.withLock {
            if rejectsChanges { throw NSError(domain: "Fixture", code: 1) }
            values[key] = value
        }
    }
    func delete(key: String) throws {
        try lock.withLock {
            if rejectsChanges { throw NSError(domain: "Fixture", code: 1) }
            values.removeValue(forKey: key)
        }
    }
}

private struct DatabaseLifecycleSecrets: DatabaseSecureStore {
    func read(key: String) -> String? { nil }
    func write(_ value: String, key: String) throws {}
    func delete(key: String) throws {}
}

private struct EmptyDatabaseWorkspaceRunner: DatabaseProcessRunning {
    func runDatabaseProcess(_ request: DatabaseProcessRequest) -> DatabaseProcessResult {
        guard let data = request.standardInput,
              let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = input["id"] as? String,
              let output = try? JSONSerialization.data(withJSONObject: ["id": id, "ok": true, "result": input["method"] as? String == "listDatabases" ? ["first_db", "alternate_db"] : []]) else {
            return DatabaseProcessResult(output: "Invalid fixture request", exitCode: 1)
        }
        return DatabaseProcessResult(output: String(decoding: output, as: UTF8.self), exitCode: 0)
    }
}

private struct GatedBackgroundSaveRunner: DatabaseProcessRunning {
    let operation: String
    let fails: Bool
    let loadEntered = TestGate()
    let loadRelease = TestGate()
    let saveEntered = TestGate()
    let saveRelease = TestGate()

    func runDatabaseProcess(_ request: DatabaseProcessRequest) -> DatabaseProcessResult {
        guard let data = request.standardInput,
              let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = input["method"] as? String else {
            return DatabaseProcessResult(output: "Invalid fixture request", exitCode: 1)
        }
        let params = input["params"] as? [String: Any]
        let isSave = method == "testConnection"
        let isLoad = (operation == "refresh" && method == "listTables")
            || (operation == "open" && method == "describeTable")
            || (operation == "page" && method == "pageTable" && params?["offset"] as? Int == 200)
        if isSave || isLoad {
            (isSave ? saveEntered : loadEntered).open()
            // The synchronous port runs on the production worker, with cleanup and a local deadline.
            guard (isSave ? saveRelease : loadRelease).waitSynchronously(timeout: 5) else {
                Issue.record("Background save test did not release its request")
                return DatabaseProcessResult(output: "Fixture deadline exceeded", exitCode: 1)
            }
            if isSave && fails { return DatabaseProcessResult(output: "Fixture connection failed", exitCode: 1) }
        }
        return TableEditsWorkspaceRunner().runDatabaseProcess(request)
    }
}

private struct GatedDatabaseWorkspaceRunner: DatabaseProcessRunning {
    let fails: Bool
    var gatedMethod = "listTables"
    let entered = TestGate()
    let release = TestGate()

    func runDatabaseProcess(_ request: DatabaseProcessRequest) -> DatabaseProcessResult {
        guard let data = request.standardInput,
              let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = input["id"] as? String else {
            return DatabaseProcessResult(output: "Invalid fixture request", exitCode: 1)
        }
        if input["method"] as? String == gatedMethod {
            entered.open()
            // This synchronous port runs on the production-owned worker, never MainActor.
            guard release.waitSynchronously(timeout: 2) else {
                Issue.record("Database navigation test did not release its request")
                return DatabaseProcessResult(output: "Fixture deadline exceeded", exitCode: 1)
            }
            if fails { return DatabaseProcessResult(output: "Fixture connection failed", exitCode: 1) }
        }
        if gatedMethod == "query" { return TableEditsWorkspaceRunner().runDatabaseProcess(request) }
        guard let output = try? JSONSerialization.data(withJSONObject: ["id": id, "ok": true, "result": []]) else {
            return DatabaseProcessResult(output: "Invalid fixture response", exitCode: 1)
        }
        return DatabaseProcessResult(output: String(decoding: output, as: UTF8.self), exitCode: 0)
    }
}

private struct TableEditsWorkspaceRunner: DatabaseProcessRunning {
    func runDatabaseProcess(_ request: DatabaseProcessRequest) -> DatabaseProcessResult {
        guard let data = request.standardInput,
              let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = input["id"] as? String else { return DatabaseProcessResult(output: "Invalid fixture", exitCode: 1) }
        let result: Any
        switch input["method"] as? String {
        case "testConnection": result = ["connected": true]
        case "listDatabases": result = ["first_db", "alternate_db"]
        case "listTables": result = [["table_name": "customers"], ["table_name": "orders"]]
        case "describeTable": result = [["name": "id", "type": "INTEGER", "pk": 1], ["name": "name", "type": "TEXT", "pk": 0]]
        case "pageTable": result = ["columns": ["id", "name"], "rows": [["id": 1, "name": "Alice"], ["id": 2, "name": "Bob"]], "truncated": false, "totalRows": 2]
        case "query": result = ["columns": ["x", "x"], "rows": [["x": 2]], "truncated": false]
        default: result = []
        }
        guard let output = try? JSONSerialization.data(withJSONObject: ["id": id, "ok": true, "result": result]) else { return DatabaseProcessResult(output: "Invalid fixture response", exitCode: 1) }
        return DatabaseProcessResult(output: String(decoding: output, as: UTF8.self), exitCode: 0)
    }
}

private struct QueryOutputRunner: DatabaseProcessRunning {
    let fails: Bool
    func runDatabaseProcess(_ request: DatabaseProcessRequest) -> DatabaseProcessResult {
        guard let data = request.standardInput,
              let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let params = input["params"] as? [String: Any] else { return DatabaseProcessResult(output: "Invalid fixture", exitCode: 1) }
        if input["method"] as? String == "query", fails, (params["sql"] as? String)?.contains("missing_table") == true {
            return DatabaseProcessResult(output: "Table 'fixture.missing_table' doesn't exist", exitCode: 1)
        }
        return TableEditsWorkspaceRunner().runDatabaseProcess(request)
    }
}

private struct GatedDatabasePageRunner: DatabaseProcessRunning {
    let fails: Bool
    let entered = TestGate()
    let release = TestGate()

    func runDatabaseProcess(_ request: DatabaseProcessRequest) -> DatabaseProcessResult {
        guard let data = request.standardInput,
              let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let params = input["params"] as? [String: Any] else {
            return DatabaseProcessResult(output: "Invalid fixture request", exitCode: 1)
        }
        if input["method"] as? String == "pageTable", params["offset"] as? Int == 200 {
            entered.open()
            // The synchronous provider port is called on the production-owned worker.
            guard release.waitSynchronously(timeout: 5) else {
                Issue.record("Delayed page was not released before its deadline")
                return DatabaseProcessResult(output: "Fixture deadline exceeded", exitCode: 1)
            }
            if fails { return DatabaseProcessResult(output: "Fixture page failed", exitCode: 1) }
        }
        return TableEditsWorkspaceRunner().runDatabaseProcess(request)
    }
}

private final class ReloadedTableKeysRunner: DatabaseProcessRunning, @unchecked Sendable {
    let fails: Bool
    private let lock = NSLock()
    private var unfilteredPages = 0
    private var applies = 0
    var applyRequests: Int { lock.withLock { applies } }
    init(fails: Bool) { self.fails = fails }

    func runDatabaseProcess(_ request: DatabaseProcessRequest) -> DatabaseProcessResult {
        guard let data = request.standardInput,
              let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = input["id"] as? String else { return DatabaseProcessResult(output: "Invalid fixture", exitCode: 1) }
        if input["method"] as? String == "applyChanges" { lock.withLock { applies += 1 } }
        if input["method"] as? String == "pageTable", let params = input["params"] as? [String: Any] {
            let narrowed = !(params["filters"] as? [Any] ?? []).isEmpty || !(params["sort"] as? [Any] ?? []).isEmpty
            if !narrowed {
                let page = lock.withLock { unfilteredPages += 1; return unfilteredPages }
                if fails && page > 1 { return DatabaseProcessResult(output: "Fixture reload failed", exitCode: 1) }
            }
            let result: [String: Any] = ["columns": ["id", "name"], "rows": [["id": narrowed ? 2 : 1, "name": "fixture"]], "truncated": false, "totalRows": 1]
            guard let output = try? JSONSerialization.data(withJSONObject: ["id": id, "ok": true, "result": result]) else {
                return DatabaseProcessResult(output: "Invalid fixture page", exitCode: 1)
            }
            return DatabaseProcessResult(output: String(decoding: output, as: UTF8.self), exitCode: 0)
        }
        return TableEditsWorkspaceRunner().runDatabaseProcess(request)
    }
}

private final class GatedSQLNavigationRunner: DatabaseProcessRunning, @unchecked Sendable {
    let method: String
    let fails: Bool
    let gatedRequest: Int
    let entered = TestGate()
    let release = TestGate()
    private let lock = NSLock()
    private var count = 0
    var requests: Int { lock.withLock { count } }
    init(method: String, fails: Bool, gatedRequest: Int = 1) { self.method = method; self.fails = fails; self.gatedRequest = gatedRequest }

    func runDatabaseProcess(_ request: DatabaseProcessRequest) -> DatabaseProcessResult {
        guard let data = request.standardInput,
              let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = input["id"] as? String else {
            return DatabaseProcessResult(output: "Invalid fixture request", exitCode: 1)
        }
        if input["method"] as? String == "exportSqlToFile",
           let params = input["params"] as? [String: Any], let path = params["outputPath"] as? String {
            do {
                try Data().write(to: URL(fileURLWithPath: path))
                let response: [String: Any] = ["id": id, "ok": true, "result": ["path": path, "byteCount": 0,
                    "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"]]
                return DatabaseProcessResult(output: String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self), exitCode: 0)
            } catch { return DatabaseProcessResult(output: error.localizedDescription, exitCode: 1) }
        }
        if input["method"] as? String == method {
            let number = lock.withLock { count += 1; return count }
            if number >= gatedRequest {
                entered.open()
                // Block only the synchronous provider worker; the test owns release and a bounded deadline.
                guard release.waitSynchronously(timeout: 5) else {
                    Issue.record("SQL navigation test did not release its request")
                    return DatabaseProcessResult(output: "Fixture deadline exceeded", exitCode: 1)
                }
                if fails { return DatabaseProcessResult(output: "Fixture SQL failed", exitCode: 1) }
            }
            if method == "execute" {
                return DatabaseProcessResult(output: "{\"id\":\"\(id)\",\"ok\":true,\"result\":{\"rowsAffected\":1}}", exitCode: 0)
            }
        }
        return TableEditsWorkspaceRunner().runDatabaseProcess(request)
    }
}

private final class GatedDatabaseApplyRunner: DatabaseProcessRunning, @unchecked Sendable {
    let fails: Bool
    let entered = TestGate()
    let release = TestGate()
    private let lock = NSLock()
    private var applies = 0
    private var pages = 0
    var applyRequests: Int { lock.withLock { applies } }
    var pageRequests: Int { lock.withLock { pages } }
    init(fails: Bool) { self.fails = fails }

    func runDatabaseProcess(_ request: DatabaseProcessRequest) -> DatabaseProcessResult {
        guard let data = request.standardInput,
              let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = input["id"] as? String else { return DatabaseProcessResult(output: "Invalid fixture", exitCode: 1) }
        if input["method"] as? String == "pageTable" {
            lock.withLock { pages += 1 }
            let params = input["params"] as? [String: Any]
            let table = params?["table"] as? String ?? ""
            let response: [String: Any] = ["id": id, "ok": true, "result": ["columns": ["id", "name"],
                "rows": [["id": 1, "name": table], ["id": 2, "name": table]], "truncated": false, "totalRows": 2]]
            guard let data = try? JSONSerialization.data(withJSONObject: response) else {
                return DatabaseProcessResult(output: "Invalid fixture page", exitCode: 1)
            }
            return DatabaseProcessResult(output: String(decoding: data, as: UTF8.self), exitCode: 0)
        }
        guard input["method"] as? String == "applyChanges" else { return TableEditsWorkspaceRunner().runDatabaseProcess(request) }
        lock.withLock { applies += 1 }
        entered.open()
        guard release.waitSynchronously(timeout: 5) else {
            Issue.record("Delayed apply was not released before its deadline")
            return DatabaseProcessResult(output: "Fixture deadline exceeded", exitCode: 1)
        }
        if fails { return DatabaseProcessResult(output: "Fixture write failed", exitCode: 1) }
        let output = "{\"id\":\"\(id)\",\"ok\":true,\"result\":{\"rowsAffected\":1}}"
        return DatabaseProcessResult(output: output, exitCode: 0)
    }
}

private final class CancellableTreeSidecarRunner: DatabaseProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var blocks = true
    private let blockedMethod: String
    private let pidFile: URL
    private let fallback = DatabaseTreeRunner()

    init(blockedMethod: String, pidFile: URL) {
        self.blockedMethod = blockedMethod
        self.pidFile = pidFile
    }

    var shouldBlock: Bool {
        get { lock.withLock { blocks } }
        set { lock.withLock { blocks = newValue } }
    }

    func runDatabaseProcess(_ request: DatabaseProcessRequest) -> DatabaseProcessResult {
        let method = request.standardInput.flatMap {
            (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["method"] as? String
        }
        guard method == blockedMethod, shouldBlock else { return fallback.runDatabaseProcess(request) }
        return MacProcessRunner().runDatabaseProcess(DatabaseProcessRequest(
            executablePath: request.executablePath,
            environment: ["LITHE_TEST_PID_FILE": pidFile.path],
            standardInput: request.standardInput,
            timeoutMilliseconds: 2_500
        ))
    }
}

private final class DatabaseTreeRunner: DatabaseProcessRunning, @unchecked Sendable {
    struct Request { let method: String; let database: String }
    private let lock = NSLock()
    private var recorded: [Request] = []
    private var storedNames = ["beta", "alpha", "alpha"]
    private var storedIncludesObjects = false
    private var storedFails = false
    private var storedBlocks = false
    private var storedBlockedMethod = "listTables"
    private var storedFailureMethod = "listTables"
    let entered = TestGate(), release = TestGate(), pageEntered = TestGate()
    var requests: [Request] { lock.withLock { recorded } }
    var names: [String] {
        get { lock.withLock { storedNames } }
        set { lock.withLock { storedNames = newValue } }
    }
    var fails: Bool {
        get { lock.withLock { storedFails } }
        set { lock.withLock { storedFails = newValue } }
    }
    var blocks: Bool {
        get { lock.withLock { storedBlocks } }
        set { lock.withLock { storedBlocks = newValue } }
    }

    var blockedMethod: String {
        get { lock.withLock { storedBlockedMethod } }
        set { lock.withLock { storedBlockedMethod = newValue } }
    }
    var failureMethod: String {
        get { lock.withLock { storedFailureMethod } }
        set { lock.withLock { storedFailureMethod = newValue } }
    }

    var includesObjects: Bool {
        get { lock.withLock { storedIncludesObjects } }
        set { lock.withLock { storedIncludesObjects = newValue } }
    }

    func runDatabaseProcess(_ request: DatabaseProcessRequest) -> DatabaseProcessResult {
        do {
            let inputData = try #require(request.standardInput)
            let input = try #require(JSONSerialization.jsonObject(with: inputData) as? [String: Any])
            let id = try #require(input["id"] as? String)
            let method = try #require(input["method"] as? String)
            let params = input["params"] as? [String: Any] ?? [:]
            let connection = params["connection"] as? [String: Any] ?? [:]
            let database = connection["database"] as? String ?? ""
            lock.withLock { recorded.append(Request(method: method, database: database)) }
            if blocks && method == blockedMethod && database == "alpha" {
                entered.open()
                // Production invokes this synchronous port on its worker; the gate has a local deadline.
                guard release.waitSynchronously(timeout: 5) else { throw CocoaError(.userCancelled) }
            }
            if fails && method == failureMethod { throw CocoaError(.fileReadNoPermission) }
            let result: Any
            switch method {
            case "listDatabases": result = names
            case "listTables": result = [["table_name": "\(database)_only"], ["table_name": "shared"]]
            case "listObjects": result = includesObjects ? [["name": "fixture_\(params["kind"] as? String ?? "object")"]] : []
            case "describeTable": result = [["column_name": "id", "data_type": "int"], ["column_name": "name", "data_type": "text"]]
            case "listIndexes", "listForeignKeys": result = [] as [String]
            case "pageTable":
                pageEntered.open()
                result = ["columns": [], "rows": [], "totalRows": 0, "truncated": false]
            default: throw CocoaError(.featureUnsupported)
            }
            let data = try JSONSerialization.data(withJSONObject: ["id": id, "ok": true, "result": result])
            return DatabaseProcessResult(output: String(decoding: data, as: UTF8.self), exitCode: 0)
        } catch {
            return DatabaseProcessResult(output: error.localizedDescription, exitCode: 1)
        }
    }
}
