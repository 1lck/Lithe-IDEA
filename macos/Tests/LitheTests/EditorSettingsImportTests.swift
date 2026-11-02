import Foundation
import AppKit
import SwiftUI
import Testing
@testable import Lithe

@Suite("Editor settings import")
struct EditorSettingsImportTests {
    @Test @MainActor func detectedIndentationBelongsToEachDocumentAndRejectsInvalidWidths() {
        let first = EditorDocument(url: URL(fileURLWithPath: "/fixture/first.js"), text: "", modificationDate: nil)
        let second = EditorDocument(url: URL(fileURLWithPath: "/fixture/second.js"), text: "", modificationDate: nil)
        #expect(first.indentation == nil)
        first.updateIndentation(tabSize: 2, insertSpaces: true)
        second.updateIndentation(tabSize: 8, insertSpaces: false)
        #expect(first.indentation == .init(tabSize: 2, insertSpaces: true))
        #expect(second.indentation == .init(tabSize: 8, insertSpaces: false))
        first.updateIndentation(tabSize: 0, insertSpaces: false)
        first.updateIndentation(tabSize: -1, insertSpaces: false)
        #expect(first.indentation == .init(tabSize: 2, insertSpaces: true))
        first.updateIndentation(tabSize: 4, insertSpaces: false)
        #expect(first.indentation == .init(tabSize: 4, insertSpaces: false))
        #expect(second.indentation == .init(tabSize: 8, insertSpaces: false))
    }

    @Test @MainActor func legacyIndentationMigratesAndImportUndoUsesOneValue() throws {
        let store = ImportTestStore()
        store.set(8, forKey: "settings.tabWidth")
        let settings = AppSettings(store: store)
        #expect(settings.editorAppearance.tabSize == 8)
        #expect(settings.editorImportValues(persisted: true)["tabSize"] == "8")
        try settings.importEditorSettings(["tabSize": "2", "insertSpaces": "false"], baseline: settings.editorImportValues())
        let reopened = AppSettings(store: store)
        #expect(reopened.editorAppearance.tabSize == 2)
        #expect(reopened.editorAppearance.monacoOptions["tabSize"] as? Int == 2)
        #expect(!reopened.editorAppearance.insertSpaces)
        try reopened.undoEditorSettingsImport()
        #expect(reopened.editorAppearance.tabSize == 8)
        reopened.editorAppearance.tabSize = 3
        #expect(AppSettings(store: store).editorAppearance.tabSize == 3)
    }

    @Test(arguments: [false, true])
    func laterUnsupportedKeybindingShadowsEarlierUserMapping(includeDefaults: Bool) throws {
        let supported = #"{"key":"ctrl+alt+cmd+b","command":"workbench.action.navigateBack"}"#
        for later in [
            #"{"key":"ctrl+alt+cmd+b","command":"extension.other"}"#,
            #"{"key":"ctrl+alt+cmd+b","command":"workbench.action.navigateForward","when":"editorTextFocus"}"#,
            #"{"key":"ctrl+alt+cmd+b","command":"extension.other","when":"editorTextFocus"}"#,
        ] {
            let parsed = try MacImportedKeybindings.parseVSCode(Data("[\(supported),\(later)]".utf8), includeDefaults: includeDefaults)
            #expect(parsed["navigate-back"] == nil)
        }
        let reversed = try MacImportedKeybindings.parseVSCode(Data("[{\"key\":\"ctrl+alt+cmd+b\",\"command\":\"extension.other\"},\(supported)]".utf8), includeDefaults: includeDefaults)
        #expect(reversed["navigate-back"] == [.keyPress(key: "b", modifiers: [.control, .option, .command])])
    }

    @Test @MainActor func vscodeDefaultsOverridesAndShadowedKeys() throws {
        let defaults = try MacEditorSettingsImportReader.parseVSCode(Data("{}".utf8), fonts: [], includeAppearanceDefaults: true).0
        #expect(defaults["tabSize"] == "4" && defaults["insertSpaces"] == "true")
        #expect(defaults["detectIndentation"] == "true" && defaults["softWrap"] == "false")
        #expect(defaults["lineNumbers"] == "on" && defaults["minimap"] == "true")
        let explicit = try MacEditorSettingsImportReader.parseVSCode(Data(#"{"editor.tabSize":2,"editor.insertSpaces":false,"editor.wordWrap":"on","editor.minimap.enabled":null}"#.utf8), fonts: [], includeAppearanceDefaults: true).0
        #expect(explicit["tabSize"] == "2" && explicit["insertSpaces"] == "false")
        #expect(explicit["softWrap"] == "true" && explicit["minimap"] == nil)
        let keys = try MacImportedKeybindings.parseVSCode(Data(#"[{"key":"cmd+s","command":"extension.save"},{"key":"cmd+shift+s","command":"workbench.action.files.save","when":"editorTextFocus"},{"key":"cmd+g","command":"-workbench.action.gotoLine"}]"#.utf8), includeDefaults: true)
        #expect(keys["save"] == nil && keys["go-to-line"] == nil)
        #expect(keys["settings"] != nil)
        let palette = try MacEditorSettingsImportReader.parseVSCode(Data(##"{"editor.tokenColorCustomizations":{"comments":"#aa00ff"},"workbench.colorCustomizations":{"editor.background":"#121212"}}"##.utf8), fonts: [], includeAppearanceDefaults: true).0
        let theme = try #require(palette["customTheme"].flatMap(ImportedEditorTheme.decode))
        #expect(theme.tokens["comment"]?.foreground == "#aa00ff")
        #expect(theme.colors["background"] == "#121212")
        let store = ImportTestStore()
        let settings = AppSettings(store: store)
        let baseline = settings.editorImportValues()
        try settings.importEditorSettings(palette, baseline: baseline)
        #expect(AppSettings(store: store).editorImportValues()["customTheme"] == theme.encoded)
        try settings.undoEditorSettingsImport()
        #expect(settings.editorImportValues() == baseline)
    }

    @Test @MainActor func appearanceImportPersistsRestoresAndProtectsCustomMode() async throws {
        for mode in ["light", "system", "dark"] {
            let store = ImportTestStore()
            let settings = AppSettings(store: store)
            let before = settings.editorImportValues()
            let parsed = try MacEditorSettingsImportReader.parseVSCode(Data((mode == "system"
                ? #"{"window.autoDetectColorScheme":true,"workbench.colorTheme":"Default Light Modern"}"#
                : "{\"workbench.colorTheme\":\"Default \(mode == "light" ? "Light" : "Dark") Modern\"}").utf8), fonts: [])
            #expect(parsed.0["themePreference"] == mode)
            let source = EditorSettingsImportSource(directory: URL(fileURLWithPath: "/fixture/Code/User"),
                title: "VS Code", revision: "appearance", values: parsed.0, warnings: [])
            let feature = EditorSettingsImportFeatureModel(settings: settings, chooseDirectory: { nil }, scan: { _ in [source] })
            await feature.scan()
            #expect(settings.editorImportValues() == before)
            #expect(feature.changedFields.allSatisfy { $0.isAppearance })
            #expect(await feature.apply())
            let restored = AppSettings(store: store)
            #expect(restored.themePreference.rawValue == mode)
            try restored.undoEditorSettingsImport()
            #expect(restored.editorImportValues() == before)
            settings.themePreference = .light
            await feature.scan()
            #expect(feature.selected.contains("themePreference") == (mode == "light"))
        }
        let store = ImportTestStore()
        let settings = AppSettings(store: store)
        let baseline = settings.editorImportValues()
        store.rejectNextKey = "settings.themePreference"
        #expect(throws: EditorSettingsImportError.self) {
            try settings.importEditorSettings(["themePreference": "system"], baseline: baseline)
        }
        #expect(settings.editorImportValues() == baseline)
        #expect(AppSettings(store: store).editorImportValues() == baseline)
    }

    @Test func appearanceDefaultsPreserveExplicitAndUnsupportedValues() throws {
        let defaults = try MacEditorSettingsImportReader.parseVSCode(Data("{}".utf8), fonts: ["Menlo"], includeAppearanceDefaults: true).0
        #expect(defaults["fontFamily"] == "Menlo" && defaults["fontSize"] == "12.0")
        #expect(defaults["themePreference"] == "dark" && defaults["colorScheme"] == "vscode")
        let explicit = try MacEditorSettingsImportReader.parseVSCode(Data(#"{"editor.fontSize":18,"editor.lineHeight":27,"workbench.colorTheme":"Default Light Modern"}"#.utf8), fonts: [], includeAppearanceDefaults: true)
        #expect(explicit.0["fontSize"] == "18.0" && explicit.0["lineHeight"] == "1.5")
        #expect(explicit.2 == "18.0" && explicit.0["themePreference"] == "light")
        let unsupported = try MacEditorSettingsImportReader.parseVSCode(Data(#"{"editor.fontSize":null,"editor.fontFamily":"Missing Font","workbench.colorTheme":"Custom"}"#.utf8), fonts: ["Menlo"], includeAppearanceDefaults: true).0
        #expect(unsupported["fontSize"] == nil && unsupported["fontFamily"] == nil)
        #expect(unsupported["themePreference"] == nil && unsupported["colorScheme"] == nil)
        let system = try MacEditorSettingsImportReader.parseVSCode(Data(#"{"window.autoDetectColorScheme":true,"workbench.preferredLightColorTheme":"Custom"}"#.utf8), fonts: [], includeAppearanceDefaults: true).0
        #expect(system["themePreference"] == "system" && system["colorScheme"] == nil)
        let idea = try MacEditorSettingsImportReader.parseIDEA(["options/laf.xml": Data(#"<application><component name="LafManager" autodetect="true"><laf themeId="Islands Light"/></component></application>"#.utf8)], fonts: [], includeAppearanceDefaults: true).0
        #expect(idea["themePreference"] == "system")
        #expect(idea["fontFamily"] == nil && idea["fontSize"] == "13.0")
    }

    @Test @MainActor func ideaSchemeFontsUseAppDefaultsAndRejectChangedOrAmbiguousSources() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("Library/Application Support/JetBrains/IdeaIC2026.2")
        let options = root.appendingPathComponent("options"), colors = root.appendingPathComponent("colors")
        try FileManager.default.createDirectory(at: options, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: colors, withIntermediateDirectories: true)
        try Data(#"<application><component name="DefaultFont"><option name="FONT_FAMILY" value="Menlo"/><option name="FONT_SIZE" value="16"/><option name="FONT_SIZE_2D" value="13"/></component></application>"#.utf8).write(to: options.appendingPathComponent("editor-font.xml"))
        try Data(#"<application><component name="EditorColorsManager"><global_color_scheme name="Custom"/></component></application>"#.utf8).write(to: options.appendingPathComponent("colors.scheme.xml"))
        let active = colors.appendingPathComponent("custom.icls")
        let inherited = Data(#"<scheme name="Custom" version="142" parent_scheme="Parent"/>"#.utf8)
        try inherited.write(to: active)
        try Data(#"<scheme name="Parent" version="142" parent_scheme="Custom"><option name="EDITOR_FONT_SIZE" value="30"/></scheme>"#.utf8).write(to: colors.appendingPathComponent("parent.icls"))
        let settings = AppSettings(store: ImportTestStore())
        let feature = EditorSettingsImportFeatureModel(settings: settings, chooseDirectory: { nil }, scan: { directory in
            try MacEditorSettingsImportReader.scan(home: home, directory: directory, fonts: ["Menlo", "JetBrains Mono"])
        })
        await feature.scan()
        #expect(feature.source?.readFailed == true, "Cyclic color inheritance must be rejected")
        #expect(feature.source?.values["colorScheme"] == nil)
        let overridden = Data(#"<scheme name="Custom" version="142" parent_scheme="Unknown"><option name="FONT_SCALE" value="1.0"/><option name="LINE_SPACING" value="1.4"/><option name="EDITOR_LIGATURES" value="true"/><font><option name="EDITOR_FONT_NAME" value="Missing"/><option name="EDITOR_FONT_SIZE" value="20"/></font><font><option name="EDITOR_FONT_NAME" value="JetBrains Mono"/><option name="EDITOR_FONT_SIZE" value="22"/></font></scheme>"#.utf8)
        try overridden.write(to: active)
        #expect(await feature.apply() == false)
        #expect(settings.editorFontSize == 13)
        await feature.scan()
        #expect(feature.source?.values["fontFamily"] == "JetBrains Mono")
        #expect(feature.source?.values["fontSize"] == "22.0" && feature.source?.values["lineHeight"] == "1.4")
        #expect(feature.source?.values["fontLigatures"] == "true")
        #expect(await feature.apply())
        #expect(settings.editorFontSize == 22 && settings.editorAppearance.fontLigatures)
        #expect(try Data(contentsOf: active) == overridden)
        try inherited.write(to: colors.appendingPathComponent("duplicate.icls"))
        await feature.scan()
        #expect(feature.source?.readFailed == true && feature.selected.isEmpty)
        try FileManager.default.removeItem(at: colors.appendingPathComponent("duplicate.icls"))
        try Data(#"<scheme name="Custom" version="999"/>"#.utf8).write(to: active)
        await feature.scan()
        #expect(feature.source?.readFailed == true)
        try FileManager.default.removeItem(at: colors)
        let outside = home.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: colors, withDestinationURL: outside)
        await feature.scan()
        #expect(feature.source?.readFailed == true)
    }

    @Test @MainActor func importReportsActualWorkAndDoesNotInventImportHistory() async throws {
        let store = ImportTestStore()
        let settings = AppSettings(store: store)
        let source = EditorSettingsImportSource(directory: URL(fileURLWithPath: "/fixture/Code/User"), title: "VS Code",
            revision: "result", values: ["fontSize": "18.0", "themePreference": "system", "softWrap": "true"], warnings: [])
        weak var active: EditorSettingsImportFeatureModel?
        let feature = EditorSettingsImportFeatureModel(settings: settings, chooseDirectory: { nil }, scan: { directory in
            if directory != nil {
                #expect(active?.isBusy == true && active?.isImporting == true)
                active?.backToSources()
                #expect(active?.isChoosingSettings == true)
            }
            return [source]
        })
        active = feature
        await feature.scan()
        feature.chooseSource(source.id)
        feature.selected = ["fontSize"]
        #expect(await feature.apply())
        #expect(feature.importResult?.applied == 1 && feature.importResult?.unselected == 2)
        #expect(!feature.isImporting && !feature.isBusy)
        #expect(settings.themePreference == .dark && !settings.editorSoftWrapEnabled)
        feature.chooseSource(source.id)
        #expect(feature.importResult == nil)
        #expect(await feature.apply())
        #expect(feature.importResult?.applied == 2 && feature.importResult?.unselected == 0)
        let reopened = EditorSettingsImportFeatureModel(settings: AppSettings(store: store), chooseDirectory: { nil }, scan: { _ in [source] })
        await reopened.scan()
        #expect(reopened.importResult == nil)
        #expect(reopened.sourceStatusMessage == "The settings we can read already match Lithe.")
        reopened.undo()
        #expect(reopened.settings.themePreference == .dark && reopened.settings.editorFontSize == 18)
    }

    @Test func importEntryCannotBypassSharedDialogPresentation() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Lithe/Views/App/EditorSettingsImportView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(source.contains("LitheCenteredPopup(isPresented: $isPresented"))
        #expect(source.contains("allowsDismiss: !feature.isBusy"))
        #expect(source.contains("dialogTitle: L10n.string(\"Import IDE settings\")"))
        #expect(source.contains("EditorSettingsImportView(feature: feature) { isPresented = false }"))
        #expect(source.contains("LitheCommitDialogStyle.background"))
        let systemPresentation = try NSRegularExpression(pattern: #"\.(?:sheet|popover|interactiveDismissDisabled)\s*\("#)
        #expect(systemPresentation.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) == nil,
                "Import must use the shared product dialog, including its dismissal lifecycle")
    }

    @Test @MainActor func startupImportPrecedesWelcomeWithoutAChildWindow() async throws {
        for scheme in [ColorScheme.dark, .light] {
            let settings = AppSettings(store: ImportTestStore())
            let source = EditorSettingsImportSource(directory: URL(fileURLWithPath: "/fixture/Code/User"),
                title: "IntelliJ IDEA 2026.2", revision: "one", values: ["fontSize": "16.0"], warnings: [])
            let second = EditorSettingsImportSource(directory: URL(fileURLWithPath: "/fixture/Code/User/Profile"),
                title: "VS Code", revision: "two", values: ["fontSize": "15.0"], warnings: [], isVSCode: true)
            let feature = EditorSettingsImportFeatureModel(settings: settings, chooseDirectory: { nil }, scan: { _ in [source, second] })
            var welcomeWasShown = false
            let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 467),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            parent.isReleasedWhenClosed = false
            parent.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            parent.contentViewController = NSHostingController(rootView:
                EditorSettingsImportStartup(feature: feature) {
                    Text(verbatim: "Welcome fixture").onAppear { welcomeWasShown = true }
                }.environment(\.colorScheme, scheme))
            defer { parent.contentViewController = nil; parent.close() }
            parent.orderFront(nil)
            let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while feature.sources.isEmpty, clock.now < deadline { await Task.yield() }
            #expect(feature.sources.count == 2)
            #expect(!welcomeWasShown)
            #expect(!feature.startupFinished)
            #expect(!settings.didOfferEditorSettingsImport)
            #expect(parent.sheets.isEmpty && (parent.childWindows ?? []).isEmpty)
            #expect(settings.editorFontSize == 13)
            if let directory = ProcessInfo.processInfo.environment["LITHE_POPUP_CAPTURE_DIR"] {
                let view = try #require(parent.contentView)
                for page in ["sources", "settings"] {
                    if page == "settings" { feature.chooseSource(source.id) }
                    view.layoutSubtreeIfNeeded()
                    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                        URL(fileURLWithPath: directory).appendingPathComponent("import-\(page)-\(scheme == .dark ? "dark" : "light").png"))
                }
            }
            feature.finishStartup()
            let finishDeadline = clock.now.advanced(by: .seconds(2))
            while !welcomeWasShown, clock.now < finishDeadline { await Task.yield() }
            #expect(welcomeWasShown)
            #expect(settings.didOfferEditorSettingsImport)
        }
    }

    @Test @MainActor func startupHandlesEmptySourcesFailuresAndSuccessfulImport() async throws {
        let emptySettings = AppSettings(store: ImportTestStore())
        let empty = EditorSettingsImportFeatureModel(settings: emptySettings, chooseDirectory: { nil }, scan: { _ in [] })
        await empty.prepareStartup()
        #expect(empty.startupFinished && emptySettings.didOfferEditorSettingsImport)
        let settings = AppSettings(store: ImportTestStore())
        let failure = EditorSettingsImportFeatureModel(settings: settings, chooseDirectory: { nil }, scan: { _ in throw EditorSettingsImportError.read })
        await failure.prepareStartup()
        #expect(!failure.startupFinished && !settings.didOfferEditorSettingsImport)
        let source = EditorSettingsImportSource(directory: URL(fileURLWithPath: "/fixture/Code/User"), title: "Fixture", revision: "one",
            values: ["fontSize": "16.0", "softWrap": "false"], warnings: [])
        let success = EditorSettingsImportFeatureModel(settings: settings, chooseDirectory: { nil }, scan: { _ in [source] })
        await success.prepareStartup()
        #expect(success.changedFields == [.fontSize])
        let applied = await success.apply()
        #expect(applied)
        success.finishStartup()
        #expect(success.startupFinished && settings.editorFontSize == 16)
        #expect(success.changedFields.isEmpty)
    }

    @Test @MainActor func choosingSourceNavigatesWithoutWritingSettings() async {
        let settings = AppSettings(store: ImportTestStore())
        let source = EditorSettingsImportSource(directory: URL(fileURLWithPath: "/fixture/Code/User"), title: "VS Code", revision: "one",
            values: ["fontSize": "16.0"], warnings: [])
        let feature = EditorSettingsImportFeatureModel(settings: settings, chooseDirectory: { nil }, scan: { _ in [source] })
        await feature.scan()
        #expect(!feature.isChoosingSettings)
        feature.chooseSource("missing")
        #expect(!feature.isChoosingSettings)
        feature.chooseSource(source.id)
        #expect(feature.isChoosingSettings && feature.selected.contains("fontSize"))
        #expect(settings.editorFontSize == 13)
        feature.backToSources()
        #expect(!feature.isChoosingSettings && settings.editorFontSize == 13)
        feature.chooseSource(source.id)
        let applied = await feature.apply()
        #expect(applied && settings.editorFontSize == 16)
    }

    @Test @MainActor func readFailuresEmptySourcesAndMatchingSettingsStayDistinct() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = AppSettings(store: ImportTestStore())
        let feature = EditorSettingsImportFeatureModel(settings: settings, chooseDirectory: { nil }, scan: { directory in
            try MacEditorSettingsImportReader.scan(home: home, directory: directory, fonts: [])
        })
        for (path, broken, empty, matching, changed) in [
            ("Code/User/settings.json", "{broken", "{}", "{\"editor.fontSize\":13}", "{\"editor.fontSize\":18}"),
            ("IdeaIC/options/editor.xml", "<application>", "<application/>",
             "<application><component name=\"DefaultFont\"><option name=\"FONT_SIZE\" value=\"13\"/></component></application>",
             "<application><component name=\"DefaultFont\"><option name=\"FONT_SIZE\" value=\"18\"/></component></application>")
        ] {
            let file = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let directory = path.hasSuffix("xml") ? file.deletingLastPathComponent().deletingLastPathComponent() : file.deletingLastPathComponent()
            try Data(broken.utf8).write(to: file)
            await feature.scan(directory: directory)
            #expect(feature.source?.readFailed == true)
            #expect(feature.sourceStatusMessage == "The configuration could not be read. Check the selected directory and file permissions.")
            #expect(feature.selected.isEmpty)
            let applied = await feature.apply()
            #expect(!applied && settings.editorFontSize == 13)
            try Data(empty.utf8).write(to: file)
            await feature.scan(directory: directory)
            #expect(feature.source?.readFailed == false)
            #expect(feature.source?.defaultFields.isEmpty == false)
            #expect(feature.source?.values.isEmpty == false)
            try Data(matching.utf8).write(to: file)
            await feature.scan(directory: directory)
            let matchingValues = feature.importValues
            try settings.importEditorSettings(matchingValues, baseline: settings.editorImportValues())
            await feature.scan(directory: directory)
            #expect(feature.sourceStatusMessage == "The settings we can read already match Lithe.")
            try Data(changed.utf8).write(to: file)
            await feature.scan(directory: directory)
            #expect(feature.sourceStatusMessage == nil && feature.changedFields == [.fontSize])
        }
    }

    @Test @MainActor func undoButtonWorksAfterRestartWithNoSources() async throws {
        let store = ImportTestStore()
        let previous = AppSettings(store: store)
        try previous.importEditorSettings(["fontSize": "18.0"], baseline: previous.editorImportValues())
        let settings = AppSettings(store: store)
        let feature = EditorSettingsImportFeatureModel(settings: settings, chooseDirectory: { nil }, scan: { _ in [] })
        await feature.scan()
        let host = NSHostingView(rootView: EditorSettingsImportView(feature: feature, onDismiss: {}))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 467),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        let application = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let enhanced = (application.accessibilityAttributeValue(attribute) as? Bool) ?? false
        application.accessibilitySetValue(true, forAttribute: attribute)
        defer { application.accessibilitySetValue(enhanced, forAttribute: attribute) }
        func elements(_ element: Any) -> [AnyObject] {
            let accessible = element as AnyObject
            let children = accessible.accessibilityChildren?() ?? []
            let descendants: [Any] = children.isEmpty ? ((element as? NSView)?.subviews ?? []) : children
            return [accessible] + descendants.flatMap { elements($0) }
        }
        var undo: AnyObject?
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(2))
        repeat {
            host.layoutSubtreeIfNeeded()
            undo = elements(host).first { $0.accessibilityIdentifier?() == "editor-import-undo" }
            if undo != nil && !feature.isBusy { break }
            await Task.yield()
        } while clock.now < deadline
        #expect(feature.sources.isEmpty && !feature.isChoosingSettings)
        let button = try #require(undo)
        #expect(button.accessibilityPerformPress?() == true)
        #expect(settings.editorFontSize == 13)
        #expect(AppSettings(store: store).editorFontSize == 13)
        #expect(!settings.canUndoEditorSettingsImport)
    }

    @Test(arguments: [false, true]) @MainActor
    func compactImportControlsRefreshPreviewSkipApplyAndUndo(startup: Bool) async throws {
        let settings = AppSettings(store: ImportTestStore())
        var current = EditorSettingsImportSource(directory: URL(fileURLWithPath: "/fixture/Code/User"),
            title: "VS Code", revision: "empty", values: [:], warnings: [], isVSCode: true, settingsFileMissing: true)
        let other = EditorSettingsImportSource(directory: URL(fileURLWithPath: "/fixture/Cursor/User"),
            title: "Cursor", revision: "other", values: ["fontSize": "16.0"], warnings: [], isVSCode: true, isCursor: true)
        var requestedDirectories: [URL?] = []
        let feature = EditorSettingsImportFeatureModel(settings: settings, chooseDirectory: { nil }, scan: { directory in
            requestedDirectories.append(directory)
            return directory == nil ? [current, other] : [current]
        })
        await feature.scan()
        var dismissed = false
        let host = NSHostingView(rootView: EditorSettingsImportView(feature: feature, startup: startup) {
            dismissed = true
            if startup { feature.finishStartup() }
        }.environment(\.colorScheme, startup ? .light : .dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 467),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: startup ? .aqua : .darkAqua)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        let application = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let enhanced = (application.accessibilityAttributeValue(attribute) as? Bool) ?? false
        application.accessibilitySetValue(true, forAttribute: attribute)
        defer { application.accessibilitySetValue(enhanced, forAttribute: attribute) }
        func elements(_ element: Any) -> [AnyObject] {
            let accessible = element as AnyObject
            let children = accessible.accessibilityChildren?() ?? []
            let descendants: [Any] = children.isEmpty ? ((element as? NSView)?.subviews ?? []) : children
            return [accessible] + descendants.flatMap { elements($0) }
        }
        func button(_ id: String) async -> AnyObject? {
            let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(2))
            repeat {
                host.layoutSubtreeIfNeeded()
                if !feature.isBusy, let found = elements(host).first(where: { $0.accessibilityIdentifier?() == id }) { return found }
                await Task.yield()
            } while clock.now < deadline
            return nil
        }
        let skip = try #require(await button("editor-import-skip"))
        let scan = try #require(await button("editor-import-rescan"))
        let skipFrame = try #require(skip.accessibilityFrame?())
        let scanFrame = try #require(scan.accessibilityFrame?())
        #expect(scanFrame.minY > skipFrame.maxY && scanFrame.minX > skipFrame.maxX)
        feature.chooseSource(current.id)
        _ = try #require(await button("editor-import-back"))
        #expect(!elements(host).contains { $0.accessibilityIdentifier?() == "editor-import-apply" })
        if let directory = ProcessInfo.processInfo.environment["LITHE_POPUP_CAPTURE_DIR"] {
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                URL(fileURLWithPath: directory).appendingPathComponent("import-empty-\(startup ? "light" : "dark").png"))
        }
        current.settingsFileMissing = false
        current.values = ["fontSize": "18.0", "themePreference": "system", "colorScheme": "vscode", "lineHeight": "1.5", "fontLigatures": "true", "softWrap": "true"]
        current.defaultFields = ["lineHeight", "fontLigatures"]
        current.approximateFields = ["colorScheme"]
        let rescan = try #require(await button("editor-import-rescan"))
        #expect(rescan.accessibilityPerformPress?() == true)
        _ = try #require(await button("editor-import-apply"))
        #expect(requestedDirectories.last == current.directory)
        #expect(feature.source?.values["fontSize"] == "18.0")
        #expect(feature.sources.map(\.id) == [current.id, other.id])
        let title = try #require(await button("editor-import-appearance-title"))
        let group = try #require(await button("editor-import-appearance-group"))
        let titleFrame = try #require(title.accessibilityFrame?())
        let checkboxFrame = try #require(group.accessibilityFrame?())
        #expect(titleFrame.maxX < checkboxFrame.minX)
        #expect(group.accessibilityPerformPress?() == true)
        #expect(feature.selected == ["softWrap"])
        #expect(group.accessibilityPerformPress?() == true)
        #expect(feature.selected.contains("fontSize") && feature.selected.contains("themePreference"))
        if let directory = ProcessInfo.processInfo.environment["LITHE_POPUP_CAPTURE_DIR"] {
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                URL(fileURLWithPath: directory).appendingPathComponent("import-appearance-\(startup ? "light" : "dark").png"))
        }
        let back = try #require(await button("editor-import-back"))
        #expect(back.accessibilityPerformPress?() == true)
        let skipAgain = try #require(await button("editor-import-skip"))
        #expect(skipAgain.accessibilityPerformPress?() == true)
        #expect(dismissed && settings.editorFontSize == 13)
        #expect(settings.didOfferEditorSettingsImport == startup)
        #expect(!settings.canUndoEditorSettingsImport)
        // The same native controls also complete a real isolated import and undo.
        feature.chooseSource(current.id)
        let apply = try #require(await button("editor-import-apply"))
        #expect(apply.accessibilityPerformPress?() == true)
        _ = try #require(await button("editor-import-result"))
        #expect(feature.importResult?.applied == 6)
        #expect(settings.editorFontSize == 18 && settings.themePreference == .system)
        let undo = try #require(await button("editor-import-undo"))
        #expect(undo.accessibilityPerformPress?() == true)
        #expect(settings.editorFontSize == 13 && settings.themePreference == .dark)
        #expect(feature.importResult == nil && !settings.canUndoEditorSettingsImport)
        current.values["keymap"] = EditorImportKeymap(preset: "", commands: ["navigate-back": [.keyPress(key: "b", modifiers: [.control, .option, .command])]]).encoded
        current.values["tabSize"] = "2"
        current.values["insertSpaces"] = "false"
        current.values["detectIndentation"] = "false"
        await feature.scan(directory: current.directory)
        for category in ["keymap", "code"] {
            let control = try #require(await button("editor-import-" + category + "-group"))
            #expect(control.isAccessibilityEnabled?() == true)
            #expect(control.accessibilityPerformPress?() == true)
        }
        #expect(feature.selected == ["fontSize", "themePreference", "colorScheme", "lineHeight", "fontLigatures", "softWrap"])
        if let directory = ProcessInfo.processInfo.environment["LITHE_POPUP_CAPTURE_DIR"] {
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                URL(fileURLWithPath: directory).appendingPathComponent("import-categories-\(startup ? "light" : "dark").png"))
        }
        // Available categories stay visible even when their values already match.
        current.values = ["fontSize": "18.0", "softWrap": "false"]
        await feature.scan(directory: current.directory)
        let unchangedPreferences = try #require(await button("editor-import-preferences-group"))
        let changedAppearance = try #require(await button("editor-import-appearance-group"))
        #expect(unchangedPreferences.isAccessibilityEnabled?() == true)
        #expect(changedAppearance.isAccessibilityEnabled?() == true)
        #expect(feature.selected == ["fontSize", "softWrap"])
        current.values["fontSize"] = "13.0"
        await feature.scan(directory: current.directory)
        let unchangedAppearance = try #require(await button("editor-import-appearance-group"))
        _ = try #require(await button("editor-import-preferences-title"))
        #expect(unchangedAppearance.isAccessibilityEnabled?() == true)
        #expect(feature.changedFields.isEmpty && feature.selected == ["fontSize", "softWrap"])
        #expect(unchangedAppearance.accessibilityPerformPress?() == true)
        #expect(feature.selected == ["softWrap"])
        #expect(unchangedAppearance.accessibilityPerformPress?() == true)
        let sameValueImport = try #require(await button("editor-import-apply"))
        #expect(sameValueImport.accessibilityPerformPress?() == true)
        _ = try #require(await button("editor-import-result"))
        #expect(feature.importResult?.applied == 0 && feature.importResult?.unselected == 0)
        #expect(settings.editorFontSize == 13 && !settings.canUndoEditorSettingsImport)
        await feature.scan(directory: current.directory)
        settings.editorFontSize = 20
        #expect(await feature.apply() == false)
        #expect(settings.editorFontSize == 20)
    }

    @Test func vscodeJSONCMapsUnitsAndNeverCopiesUnknownValues() throws {
        let data = Data(#"""
        { // user preferences
          "editor.fontFamily": "'Missing Font', 'Fixture Mono', monospace",
          "editor.fontSize": 16, "editor.lineHeight": 24,
          "editor.fontLigatures": true, "editor.lineNumbers": "relative",
          "editor.minimap.enabled": false, "editor.wordWrap": "on",
          "[java]": {"editor.fontSize": 99}, "secret.token": "do-not-copy",
        }
        """#.utf8)
        let (values, warnings, _) = try MacEditorSettingsImportReader.parseVSCode(data, fonts: ["Fixture Mono"])
        #expect(values["fontFamily"] == "Fixture Mono")
        #expect(values["fontSize"] == "16.0")
        #expect(values["lineHeight"] == "1.5")
        #expect(values["lineNumbers"] == "relative")
        #expect(values["fontLigatures"] == "true")
        #expect(values["minimap"] == "false")
        #expect(values["softWrap"] == "true")
        #expect(!String(describing: values).contains("do-not-copy"))
        #expect(!warnings.joined().contains("do-not-copy"))
    }

    @Test func invalidAndUnsupportedPreferencesAreSkipped() throws {
        let data = Data(#"{"editor.fontSize": 300, "editor.lineHeight": 24, "editor.fontLigatures": "liga", "editor.minimap.enabled": 1, "editor.fontFamily":"missing", "editor.cursorStyle":"line-thin", "editor.wordWrap":"bounded"}"#.utf8)
        let (values, warnings, _) = try MacEditorSettingsImportReader.parseVSCode(data, fonts: [])
        #expect(values.isEmpty)
        #expect(!warnings.isEmpty)
        #expect(throws: (any Error).self) { try MacEditorSettingsImportReader.parseVSCode(Data("{".utf8), fonts: []) }
    }

    @Test func ideaComponentsUseExplicitValuesAndRejectEntities() throws {
        let font = Data(#"<application><component name="DefaultFont"><option name="FONT_FAMILY" value="Fixture Mono"/><option name="FONT_SIZE_2D" value="15.5"/><option name="FONT_SCALE" value="1.0"/><option name="LINE_SPACING" value="1.4"/><option name="USE_LIGATURES" value="true"/></component></application>"#.utf8)
        let editor = Data(#"<application><component name="EditorSettings"><option name="ARE_LINE_NUMBERS_SHOWN" value="false"/><option name="IS_BLOCK_CURSOR" value="true"/><option name="USE_SOFT_WRAPS" value="MAIN_EDITOR"/></component><component name="Other"><option name="IS_BLOCK_CURSOR" value="false"/></component></application>"#.utf8)
        let (values, warnings, _) = try MacEditorSettingsImportReader.parseIDEA(["options/editor-font.xml": font, "options/editor.xml": editor], fonts: ["Fixture Mono"])
        #expect(values["fontSize"] == "15.5")
        #expect(values["lineHeight"] == "1.4")
        #expect(values["fontLigatures"] == "true")
        #expect(values["lineNumbers"] == "off")
        #expect(values["cursorStyle"] == "block")
        #expect(values["softWrap"] == nil)
        #expect(!warnings.isEmpty)
        let entity = Data(#"<!DOCTYPE application [<!ENTITY x SYSTEM "file:///secret">]><application/>"#.utf8)
        #expect(throws: (any Error).self) { try MacEditorSettingsImportReader.parseIDEA(["options/editor.xml": entity], fonts: []) }
    }

    @Test func customIdeaSchemeDoesNotImportAnOverriddenGlobalFont() throws {
        let files = ["options/editor-font.xml": Data(#"<application><component name="DefaultFont"><option name="FONT_SIZE" value="16"/></component></application>"#.utf8),
                     "options/colors.scheme.xml": Data(#"<application><component name="EditorColorsManager"><global_color_scheme name="Custom"/></component></application>"#.utf8)]
        let (values, warnings, _) = try MacEditorSettingsImportReader.parseIDEA(files, fonts: [])
        #expect(values["fontSize"] == nil)
        #expect(values["colorScheme"] == nil)
        #expect(!warnings.isEmpty)
    }

    @Test func discoveryFindsVersionsAndProfilesWithoutWritingSources() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = ["Library/Application Support/Code/User/settings.json",
                     "Library/Application Support/Code/User/profiles/example/settings.json",
                     "Library/Application Support/Cursor/User/settings.json",
                     "Library/Application Support/Cursor/User/profiles/example/settings.json",
                     "Library/Application Support/JetBrains/IdeaIC2026.2/options/editor.xml"]
        for path in paths {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((path.hasSuffix("xml") ? "<application/>" : "{\"editor.fontSize\":16}").utf8).write(to: url)
        }
        let before = try paths.map { try Data(contentsOf: home.appendingPathComponent($0)) }
        let sources = try MacEditorSettingsImportReader.scan(home: home, fonts: [])
        #expect(sources.count == 5)
        #expect(sources.filter(\.isVSCode).count == 4)
        #expect(sources.filter(\.isCursor).count == 2)
        #expect(sources.first { !$0.isVSCode }?.title == "IdeaIC2026.2")
        #expect(Set(sources.map(\.id)).count == 5)
        #expect(sources.allSatisfy { !$0.revision.isEmpty })
        let after = try paths.map { try Data(contentsOf: home.appendingPathComponent($0)) }
        #expect(before == after)
        let source = try #require(sources.first { $0.values["fontSize"] != nil })
        #expect(try MacEditorSettingsImportReader.scan(home: home, directory: source.directory, fonts: []).first?.isVSCode == true)
        try Data("{\"editor.fontSize\":18}".utf8).write(to: source.directory.appendingPathComponent("settings.json"))
        #expect(try MacEditorSettingsImportReader.scan(home: home, directory: source.directory, fonts: []).first?.revision != source.revision)
    }

    // Opt-in integration check: reads this Mac's real sources, never applies settings.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHE_LOCAL_IMPORT_DISCOVERY"] == "1"))
    func localInstalledEditorsReadOnlyIntegration() async throws {
        let sources = try await MacEditorSettingsImportReader.scan(directory: nil)
        for title in ["VS Code", "Cursor"] {
            let source = try #require(sources.first { $0.title == title })
            #expect(!source.readFailed)
            #expect(source.isCursor == (title == "Cursor"))
            print("Read-only discovery: \(title), settings file missing: \(source.settingsFileMissing)")
        }
        let idea = try #require(sources.first { !$0.isVSCode })
        #expect(!idea.readFailed)
        #expect(idea.values["colorScheme"] == "idea")
        print("Read-only discovery: IntelliJ IDEA, supported fields: \(idea.values.keys.sorted())")
    }

    @Test @MainActor func discoversEditorsWithoutSettingsAndImportsCursorAfterRescan() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: home) }
        let settings = AppSettings(store: ImportTestStore())
        let feature = EditorSettingsImportFeatureModel(settings: settings, chooseDirectory: { nil }, scan: { directory in
            try MacEditorSettingsImportReader.scan(home: home, directory: directory, fonts: [])
        })
        await feature.scan()
        #expect(feature.sources.isEmpty)
        let code = home.appendingPathComponent("Library/Application Support/Code/User")
        let cursor = home.appendingPathComponent("Library/Application Support/Cursor/User")
        for directory in [code, cursor] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
        await feature.scan()
        #expect(feature.sources.map(\.title) == ["VS Code", "Cursor"])
        for source in feature.sources {
            let categories = Set(EditorSettingsImportField.allCases.filter { source.values[$0.rawValue] != nil }.map(\.category))
            #expect(categories == Set(["appearance", "keymap", "code", "preferences"]))
        }
        #expect(feature.sources.allSatisfy { $0.settingsFileMissing && !$0.readFailed && !$0.values.isEmpty && !$0.defaultFields.isEmpty })
        #expect(feature.sourceStatusMessage == nil)
        #expect(feature.selected.contains("fontSize") && settings.editorFontSize == 13)
        #expect(feature.sources.first { $0.isCursor }?.approximateFields.contains("fontSize") == true)
        let defaults = try #require(feature.source?.values)
        feature.selected = Set(defaults.keys)
        #expect(await feature.apply(), Comment(rawValue: feature.message ?? ""))
        await feature.scan()
        #expect(feature.source?.settingsFileMissing == true)
        #expect(feature.sourceStatusMessage == "The settings we can read already match Lithe.")
        try settings.undoEditorSettingsImport()
        await feature.scan()
        for directory in [code, cursor] {
            #expect(try fm.contentsOfDirectory(atPath: directory.path).isEmpty)
            let manual = try #require(MacEditorSettingsImportReader.scan(home: home, directory: directory, fonts: []).first)
            #expect(manual.settingsFileMissing && manual.isVSCode)
            #expect(manual.isCursor == (directory == cursor))
        }
        let codeFile = code.appendingPathComponent("settings.json")
        try Data(#"{"editor.lineHeight":24}"#.utf8).write(to: codeFile)
        let converted = try #require(MacEditorSettingsImportReader.scan(home: home, directory: code, fonts: []).first)
        #expect(converted.values["lineHeight"] == "2.0" && converted.lineHeightFontSize == "12.0")
        #expect(converted.defaultFields.contains("fontSize") && !converted.defaultFields.contains("lineHeight"))
        try fm.removeItem(at: codeFile)
        let file = cursor.appendingPathComponent("settings.json")
        let contents = Data("{ /* JSONC */ \"editor.fontSize\": 18, \"editor.lineHeight\": 27, }".utf8)
        try contents.write(to: file)
        await feature.scan(directory: cursor)
        let source = try #require(feature.source)
        #expect(source.title == "Cursor" && source.isCursor && !source.settingsFileMissing)
        #expect(source.values["fontSize"] == "18.0" && source.values["lineHeight"] == "1.5")
        #expect(await feature.apply())
        #expect(settings.editorFontSize == 18 && settings.editorAppearance.lineHeight == 1.5)
        #expect(try Data(contentsOf: file) == contents)
        try fm.removeItem(at: file)
        await feature.scan(directory: cursor)
        #expect(feature.source?.settingsFileMissing == true && feature.source?.readFailed == false)
        #expect(settings.editorFontSize == 18)
        let unrelated = home.appendingPathComponent("unrelated")
        try fm.createDirectory(at: unrelated, withIntermediateDirectories: true)
        #expect(try MacEditorSettingsImportReader.scan(home: home, directory: unrelated, fonts: []).isEmpty)
    }

    @Test @MainActor func previewPreservesCustomSettingsAndRejectsChangedSource() async throws {
        let settings = AppSettings(store: ImportTestStore())
        settings.editorFontSize = 22
        let directory = URL(fileURLWithPath: "/fixture/config")
        var current = EditorSettingsImportSource(directory: directory, title: "Fixture", revision: "a",
            values: ["fontSize":"16.0", "lineHeight":"1.5", "lineNumbers":"off"], warnings: [])
        let feature = EditorSettingsImportFeatureModel(settings: settings, chooseDirectory: { nil }, scan: { _ in [current] })
        await feature.scan()
        #expect(!feature.selected.contains("fontSize"))
        #expect(!feature.selected.contains("lineHeight"))
        #expect(feature.selected.contains("lineNumbers"))
        current = EditorSettingsImportSource(directory: directory, title: "Fixture", revision: "b", values: current.values, warnings: [])
        await feature.apply()
        #expect(settings.editorFontSize == 22)
        #expect(settings.editorAppearance.lineNumbers == .on)
        await feature.scan()
        await feature.apply()
        #expect(settings.editorAppearance.lineNumbers == .off)
        #expect(settings.editorFontSize == 22)
        feature.undo()
        #expect(settings.editorAppearance.lineNumbers == .on)
        await feature.scan()
        settings.editorAppearance.lineNumbers = .relative
        await feature.apply()
        #expect(settings.editorAppearance.lineNumbers == .relative)
    }

    @Test @MainActor func pixelLineHeightRequiresItsSourceFontSize() async throws {
        let settings = AppSettings(store: ImportTestStore())
        settings.editorFontSize = 22
        let source = EditorSettingsImportSource(directory: URL(fileURLWithPath: "/fixture/Code/User"), title: "Fixture", revision: "one", values: ["fontSize": "16.0", "lineHeight": "1.5"], warnings: [], lineHeightFontSize: "16.0")
        let feature = EditorSettingsImportFeatureModel(settings: settings, chooseDirectory: { nil }, scan: { _ in [source] })
        await feature.scan()
        #expect(!feature.selected.contains("lineHeight"))
        feature.selected = ["lineHeight"]
        await feature.apply()
        #expect(settings.editorAppearance.lineHeight == 0)
        feature.selected = ["lineHeight", "fontSize"]
        await feature.apply()
        #expect(settings.editorFontSize == 16)
        #expect(settings.editorAppearance.lineHeight == 1.5)
    }

    @Test @MainActor func concurrentPreferenceChangesAndDamagedRecoveryArePreserved() throws {
        let store = ImportTestStore()
        let settings = AppSettings(store: store)
        let other = AppSettings(store: store)
        other.editorAppearance.whitespace = .all
        try settings.importEditorSettings(["fontSize": "16.0"], baseline: settings.editorImportValues())
        #expect(settings.editorAppearance.whitespace == .all)
        let baseline = settings.editorImportValues()
        store.set(21.0, forKey: "settings.editorFontSize")
        #expect(throws: EditorSettingsImportError.self) {
            try settings.importEditorSettings(["fontSize": "16.0"], baseline: baseline)
        }
        #expect((store.object(forKey: "settings.editorFontSize") as? Double) == 21)
        store.set(Data("broken journal".utf8), forKey: "settings.editorImportJournal.v1")
        let recovered = AppSettings(store: store)
        #expect(recovered.editorImportRecoveryFailed)
        #expect(throws: EditorSettingsImportError.self) {
            try recovered.importEditorSettings(["fontSize": "16.0"], baseline: recovered.editorImportValues())
        }
        #expect((store.object(forKey: "settings.editorFontSize") as? Double) == 21)
        #expect(store.data(forKey: "settings.editorImportJournal.v1") == Data("broken journal".utf8))
    }

    @Test @MainActor func selectedValuesPersistAndUndoProtectsLaterEdits() throws {
        let store = ImportTestStore()
        let target = AppSettings(store: store)
        target.editorAppearance.tabSize = 8
        let before = target.editorImportValues()
        try target.importEditorSettings(["fontSize": "18.0", "lineNumbers": "relative"], baseline: before)
        let reloaded = AppSettings(store: store)
        #expect(reloaded.editorFontSize == 18)
        #expect(reloaded.editorAppearance.lineNumbers == .relative)
        #expect(reloaded.editorAppearance.tabSize == 8)
        reloaded.editorFontSize = 20
        #expect(throws: EditorSettingsImportError.self) { try reloaded.undoEditorSettingsImport() }
        #expect(reloaded.editorFontSize == 20)
        reloaded.editorFontSize = 18
        try reloaded.undoEditorSettingsImport()
        #expect(reloaded.editorImportValues() == before)
        #expect(!reloaded.canUndoEditorSettingsImport)
        #expect(throws: EditorSettingsImportError.self) { try target.importEditorSettings(["fontSize":"21.0"], baseline: before) }
    }

    @Test @MainActor func failedWriteRollsBackAndInterruptedImportRecovers() throws {
        let store = ImportTestStore()
        let settings = AppSettings(store: store)
        let before = settings.editorImportValues()
        store.rejectNextKey = "settings.editorFontSize"
        #expect(throws: EditorSettingsImportError.self) {
            try settings.importEditorSettings(["fontSize":"18.0", "lineNumbers":"relative"], baseline: before)
        }
        #expect(settings.editorImportValues() == before)
        #expect(AppSettings(store: store).editorImportValues() == before)
        settings.editorFontSize = 19
        let journal = EditorSettingsImportJournal(before: ["fontSize":"13.0"], after: ["fontSize":"19.0"], pending: true)
        store.set(try JSONEncoder().encode(journal), forKey: "settings.editorImportJournal.v1")
        #expect(AppSettings(store: store).editorFontSize == 13)
        #expect(store.data(forKey: "settings.editorImportJournal.v1") == nil)
    }
    @Test func explicitKeymapsAndGlobalCodeSettings() throws {
        let keys = try MacImportedKeybindings.parseVSCode(Data(#"""
        [ // Conditions and duplicate/removal rules must never become unconditional bindings.
          {"key":"cmd+alt+s","command":"workbench.action.files.save"},
          {"key":"cmd+f","command":"workbench.action.findInFiles","when":"editorTextFocus"},
          {"key":"cmd+k cmd+s","command":"workbench.action.openSettings"},
          {"key":"cmd+b","command":"workbench.action.navigateBack"},
          {"key":"cmd+b","command":"-workbench.action.navigateBack"},
        ]
        """#.utf8))
        #expect(Set(keys.keys) == ["save"])
        #expect(keys["save"] == [.keyPress(key: "s", modifiers: [.command, .option])])
        #expect(MacImportedKeybindings.binding("cmd+delete", idea: false) == nil)
        #expect(MacImportedKeybindings.binding("meta BACK_SPACE", idea: true) == .keyPress(key: "delete", modifiers: .command))
        #expect(MacImportedKeybindings.vscode.values.allSatisfy { LitheCommandCatalog.command(id: $0) != nil })
        #expect(MacImportedKeybindings.idea.values.allSatisfy { LitheCommandCatalog.command(id: $0) != nil })
        let code = try MacEditorSettingsImportReader.parseVSCode(Data(#"{"editor.tabSize":2,"editor.insertSpaces":false,"editor.detectIndentation":false}"#.utf8), fonts: [])
        #expect(code.0["tabSize"] == "2" && code.0["insertSpaces"] == "false" && code.0["detectIndentation"] == "false")
        let distinctIndent = try MacEditorSettingsImportReader.parseVSCode(Data(#"{"editor.tabSize":4,"editor.indentSize":2}"#.utf8), fonts: [])
        #expect(distinctIndent.0["tabSize"] == nil && !distinctIndent.1.isEmpty)
        let invalid = try MacEditorSettingsImportReader.parseVSCode(Data(#"{"editor.tabSize":true,"editor.insertSpaces":1,"editor.detectIndentation":"true"}"#.utf8), fonts: [])
        #expect(invalid.0["tabSize"] == nil && invalid.0["insertSpaces"] == nil && invalid.0["detectIndentation"] == nil)
        let files = [
            "options/keymap.xml": "<application><component name='KeymapManager'><active_keymap name='Mine'/></component></application>",
            "keymaps/custom.xml": "<keymap name='Mine' parent='Mac OS X'><action id='Back'><keyboard-shortcut first-keystroke='meta alt B'/></action><action id='Forward'><keyboard-shortcut first-keystroke='meta K' second-keystroke='meta S'/></action></keymap>",
            "options/code.style.schemes.xml": "<application><component name='CodeStyleSchemeSettings'><option name='CURRENT_SCHEME_NAME' value='Mine'/></component></application>",
            "codestyles/custom.xml": "<code_scheme name='Mine'><option name='AUTODETECT_INDENTS' value='false'/><option name='OTHER_INDENT_OPTIONS'><value><option name='TAB_SIZE' value='2'/><option name='INDENT_SIZE' value='2'/><option name='USE_TAB_CHARACTER' value='true'/></value></option><codeStyleSettings language='JAVA'><indentOptions><option name='TAB_SIZE' value='8'/></indentOptions></codeStyleSettings></code_scheme>"
        ].mapValues { Data($0.utf8) }
        let idea = try MacEditorSettingsImportReader.parseIDEA(files, fonts: [])
        let map = try #require(idea.0["keymap"].flatMap(EditorImportKeymap.decode))
        #expect(Set(map.commands.keys) == ["navigate-back"])
        #expect(idea.0["tabSize"] == "2" && idea.0["insertSpaces"] == "false" && idea.0["detectIndentation"] == "false")
    }

    @Test @MainActor func keymapAndIndentImportMergePersistUndoAndConflict() async throws {
        let store = ImportTestStore(), settings = AppSettings(store: ImportTestStore())
        // Use a separate persisted store for the merge/undo transaction.
        let target = AppSettings(store: store)
        target.setKeyboardShortcutOverrides(["save": [.keyPress(key: "s", modifiers: [.command, .control])]])
        let before = target.editorImportValues()
        let map = EditorImportKeymap(preset: "", commands: ["navigate-back": [.keyPress(key: "b", modifiers: [.control, .option, .command])]])
        let source = EditorSettingsImportSource(directory: URL(fileURLWithPath: "/fixture/Code/User"), title: "VS Code", revision: "keymap", values: ["keymap": map.encoded, "tabSize": "2", "insertSpaces": "false", "detectIndentation": "false"], warnings: [])
        let feature = EditorSettingsImportFeatureModel(settings: target, chooseDirectory: { nil }, scan: { _ in [source] })
        await feature.scan()
        #expect(feature.selected.contains("keymap"))
        #expect(await feature.apply())
        let restored = AppSettings(store: store)
        #expect(restored.keyboardShortcutOverrides["save"] == target.keyboardShortcutOverrides["save"])
        #expect(restored.keyboardShortcutOverrides["navigate-back"] == map.commands["navigate-back"])
        #expect(restored.editorAppearance.tabSize == 2 && !restored.editorAppearance.insertSpaces && !restored.editorAppearance.detectIndentation)
        try restored.undoEditorSettingsImport()
        #expect(restored.editorImportValues() == before)
        let conflicting = EditorImportKeymap(preset: "", commands: ["navigate-back": [.keyPress(key: "s", modifiers: .command)]])
        var badSource = source; badSource.values = ["keymap": conflicting.encoded]
        let conflictedSource = badSource
        let conflict = EditorSettingsImportFeatureModel(settings: settings, chooseDirectory: { nil }, scan: { _ in [conflictedSource] })
        await conflict.scan()
        #expect(conflict.keymapConflict != nil)
        #expect(await conflict.apply() == false)
        #expect(settings.keyboardShortcutOverrides.isEmpty && !settings.canUndoEditorSettingsImport)
        store.rejectNextKey = "settings.keyboardShortcutPresets"
        #expect(throws: EditorSettingsImportError.self) {
            try restored.importEditorSettings(["keymap": EditorImportKeymap(preset: "macOS", commands: map.commands).encoded], baseline: before)
        }
        #expect(restored.editorImportValues() == before)
    }

    @Test @MainActor func keymapOnlyDirectoryIsReadOnlyAndDetectsSourceChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("keybindings.json")
        let data = Data(#"[{"key":"ctrl+alt+cmd+b","command":"workbench.action.navigateBack"}]"#.utf8)
        try data.write(to: file)
        let settings = AppSettings(store: ImportTestStore())
        let feature = EditorSettingsImportFeatureModel(settings: settings, chooseDirectory: { nil }, scan: { _ in
            try MacEditorSettingsImportReader.scan(home: directory, directory: directory, fonts: [])
        })
        await feature.scan()
        #expect(feature.source?.values["keymap"] != nil)
        #expect(try Data(contentsOf: file) == data)
        try Data(#"[{"key":"ctrl+alt+cmd+n","command":"workbench.action.navigateBack"}]"#.utf8).write(to: file)
        #expect(await feature.apply() == false)
        #expect(settings.keyboardShortcutOverrides.isEmpty)
        await feature.scan()
        #expect(await feature.apply())
        #expect(settings.keyboardShortcutOverrides["navigate-back"] == [.keyPress(key: "n", modifiers: [.control, .option, .command])])
    }

    @Test @MainActor func ideaDefaultsImportWithoutCustomFilesAndPreserveInheritance() async throws {
        let parsed = try MacEditorSettingsImportReader.parseIDEA([:], fonts: [], includeAppearanceDefaults: true)
        #expect(parsed.0["tabSize"] == "4" && parsed.0["insertSpaces"] == "true" && parsed.0["detectIndentation"] == "true")
        let defaults = try #require(parsed.0["keymap"].flatMap(EditorImportKeymap.decode))
        #expect(MacImportedKeybindings.ideaDefaults("Mac OS X")?["go-to-line"] == [.keyPress(key: "g", modifiers: .command)])
        #expect(defaults.commands["run"] == [.keyPress(key: "r", modifiers: .control)])
        #expect(defaults.commands["settings"] == [.keyPress(key: ",", modifiers: .command)])
        let settings = AppSettings(store: ImportTestStore())
        let source = EditorSettingsImportSource(directory: URL(fileURLWithPath: "/fixture/IDEA"), title: "IDEA", revision: "default", values: parsed.0, warnings: [])
        let feature = EditorSettingsImportFeatureModel(settings: settings, chooseDirectory: { nil }, scan: { _ in [source] })
        await feature.scan()
        #expect(feature.keymapConflict == nil)
        #expect(await feature.apply())
        #expect(settings.keyboardShortcutOverrides["run"] == defaults.commands["run"])
        try settings.undoEditorSettingsImport()
        #expect(settings.keyboardShortcutOverrides.isEmpty)
        let files = [
          "options/keymap.xml": "<application><component name='KeymapManager'><active_keymap name='Mine'/></component></application>",
          "keymaps/mine.xml": "<keymap name='Mine' parent='Mac OS X 10.5+'><action id='Run'><keyboard-shortcut first-keystroke='meta alt R'/></action><action id='Debug'><keyboard-shortcut first-keystroke='meta K' second-keystroke='meta D'/></action></keymap>"
        ].mapValues { Data($0.utf8) }
        let inherited = try MacEditorSettingsImportReader.parseIDEA(files, fonts: [], includeAppearanceDefaults: true)
        let map = try #require(inherited.0["keymap"].flatMap(EditorImportKeymap.decode))
        #expect(map.commands["settings"] == defaults.commands["settings"])
        #expect(map.commands["run"] == [.keyPress(key: "r", modifiers: [.command, .option])])
        #expect(map.commands["debug"] == nil)
        let unknown = try MacEditorSettingsImportReader.parseIDEA(["options/keymap.xml": Data("<application><component name='KeymapManager'><active_keymap name='Unknown'/></component></application>".utf8)], fonts: [], includeAppearanceDefaults: true)
        #expect(unknown.0["keymap"] == nil)
        var cyclic = files
        cyclic["keymaps/mine.xml"] = Data("<keymap name='Mine' parent='Mine'/>".utf8)
        #expect(throws: EditorSettingsImportError.self) { try MacEditorSettingsImportReader.parseIDEA(cyclic, fonts: [], includeAppearanceDefaults: true) }
    }

    @Test @MainActor func importedThemeInheritsPurpleCommentsPersistsAndUndoes() async throws {
        let files = [
          "options/colors.scheme.xml": "<application><component name='EditorColorsManager'><global_color_scheme name='Purple'/></component></application>",
          "colors/parent.icls": "<scheme name='Parent' version='142' parent_scheme='Darcula'><attributes><option name='DEFAULT_STRING'><value><option name='FOREGROUND' value='00FF00'/></value></option><option name='DEFAULT_LINE_COMMENT'><value><option name='FOREGROUND' value='888888'/></value></option></attributes></scheme>",
          "colors/child.icls": "<scheme name='Purple' version='142' parent_scheme='Parent'><colors><option name='CARET_COLOR' value='FF00FF'/></colors><attributes><option name='DEFAULT_LINE_COMMENT'><value><option name='FOREGROUND' value='AA44CC'/><option name='FONT_TYPE' value='2'/></value></option><option name='JAVA_DOC_COMMENT' baseAttributes='DEFAULT_LINE_COMMENT'/><option name='METHOD_DECLARATION_ATTRIBUTES'><value><option name='FOREGROUND' value='CC88FF'/></value></option></attributes></scheme>"
        ].mapValues { Data($0.utf8) }
        let values = try MacEditorSettingsImportReader.parseIDEA(files, fonts: []).0
        let theme = try #require(values["customTheme"].flatMap(ImportedEditorTheme.decode))
        #expect(theme.tokens["comment.line"]?.foreground == "#AA44CC")
        #expect(theme.tokens["comment.line"]?.fontStyle == "italic")
        #expect(theme.tokens["string"]?.foreground == "#00FF00")
        #expect(theme.tokens["comment.documentation.java"]?.foreground == "#AA44CC")
        #expect(theme.tokens["method.declaration"]?.foreground == "#CC88FF")
        #expect(theme.colors["cursor"] == "#FF00FF")
        let store = ImportTestStore(), settings = AppSettings(store: ImportTestStore())
        let target = AppSettings(store: store)
        let before = target.editorImportValues()
        try target.importEditorSettings(values, baseline: before)
        #expect(AppSettings(store: store).editorAppearance.customTheme == theme.encoded)
        #expect(target.editorAppearance.monacoOptions["customTheme"] as? String == theme.encoded)
        try target.undoEditorSettingsImport()
        #expect(target.editorImportValues() == before)
        #expect(settings.editorAppearance.customTheme.isEmpty)
        var cycle = files
        cycle["colors/parent.icls"] = Data("<scheme name='Parent' version='142' parent_scheme='Purple'/>".utf8)
        #expect(throws: EditorSettingsImportError.self) { try MacEditorSettingsImportReader.parseIDEA(cycle, fonts: []) }
        #expect(ImportedEditorTheme.decode("{\"name\":\"bad\"}") == nil)
    }

}

private final class ImportTestStore: KeyValueStore {
    var values: [String: Any] = [:]
    var rejectNextKey: String?
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) {
        if rejectNextKey == key { rejectNextKey = nil; return }
        values[key] = value
    }
}
