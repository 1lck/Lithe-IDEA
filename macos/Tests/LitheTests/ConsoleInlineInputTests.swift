import AppKit
import SwiftUI
import Testing
import LitheDebugModule
@testable import Lithe

@MainActor
@Suite("Console inline standard input", .serialized)
struct ConsoleInlineInputTests {
    @Test(arguments: [false, true])
    func fontFamilyChangesRestyleRetainedOutputFoldsAndInput(dark: Bool) throws {
        try #require(MacEditorFontCatalog.resolvedFamily("Menlo") == "Menlo")
        let presentation = ConsoleFoldPresentation()
        presentation.fontSize = 17 // Retained Console zoom is independent of the Editor font size.
        let sessionID = UUID()
        let source = "plain \u{1b}[1;31mbold\u{1b}[0m\n"
            + (1...12).map { "\tat demo.Main.frame\($0)(Main.java:1)\n" }.joined()
        func content(_ family: String, output: String = source, acceptsInput: Bool = true) -> some View {
            OutputTextView(output: output, searchRoots: [], fileExists: { _ in false }, emptyMessage: "No output",
                consolePresentation: presentation, standardInputSessionID: sessionID,
                onSubmitStandardInput: acceptsInput ? { _ in true } : nil, onOpenLocation: { _, _, _ in })
                .environment(\.consoleFontFamily, family)
                .environment(\.colorScheme, dark ? .dark : .light)
        }
        let host = NSHostingView(rootView: content(EditorFontDefaults.monospacedFamily))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let view = try #require(findTextView(host))
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        view.insertText("draft", replacementRange: view.selectedRange())
        let retainedText = view.string

        for family in ["Menlo", "Lithe Missing Monospace Family", "Menlo"] {
            // Only the font changes: an unchanged producer buffer must still be restyled.
            host.rootView = content(family)
            host.layoutSubtreeIfNeeded()
            #expect(findTextView(host) === view)
            #expect(view.string == retainedText)
            #expect(presentation.inputDraft == "draft")
            #expect(presentation.fontSize == 17)
            let storage = try #require(view.textStorage)
            for (token, weight) in [("plain", NSFont.Weight.regular), ("bold", .bold),
                                    ("<4 folded frames>", .regular), ("draft", .regular)] {
                let range = (view.string as NSString).range(of: token)
                try #require(range.location != NSNotFound)
                let font = try #require(storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
                let expected = MacEditorFontCatalog.font(family: family, size: 17, weight: weight)
                #expect(font.fontName == expected.fontName)
                #expect(font.pointSize == 17)
                let paragraph = try #require(storage.attribute(.paragraphStyle, at: range.location,
                    effectiveRange: nil) as? NSParagraphStyle)
                #expect(paragraph.minimumLineHeight == LitheConsoleStyle.lineHeight(
                    for: MacEditorFontCatalog.font(family: family, size: 17)))
            }
            let boldOffset = (view.string as NSString).range(of: "bold").location
            #expect(storage.attribute(.foregroundColor, at: boldOffset, effectiveRange: nil) as? NSColor
                == LitheConsoleStyle.palette(dark: dark)[1])
        }
        host.rootView = content("Menlo", output: source + "appended\n")
        host.layoutSubtreeIfNeeded()
        let appended = (view.string as NSString).range(of: "appended")
        try #require(appended.location != NSNotFound)
        let font = try #require(view.textStorage?.attribute(.font, at: appended.location, effectiveRange: nil) as? NSFont)
        #expect(font.fontName == MacEditorFontCatalog.font(family: "Menlo", size: 17).fontName)
        #expect(view.string.hasSuffix("appended\ndraft"))
        for family in [EditorFontDefaults.monospacedFamily, "Menlo"] {
            host.rootView = content(family, output: "", acceptsInput: false)
            host.layoutSubtreeIfNeeded()
            #expect(view.string == "No output")
            let placeholder = try #require(view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            #expect(placeholder.fontName == MacEditorFontCatalog.font(family: family, size: 17).fontName)
        }
    }

    @Test(arguments: [false, true])
    func nativeInputProtectsLogsAndSendsOnlyTheDraft(dark: Bool) throws {
        let presentation = ConsoleFoldPresentation()
        var submitted: [String] = []
        var acceptsInput = true
        let content = OutputTextView(output: "ready> ", searchRoots: [], fileExists: { _ in false }, emptyMessage: "",
            fontSize: 13, consolePresentation: presentation,
            standardInputSessionID: UUID(), onSubmitStandardInput: { submitted.append($0); return acceptsInput },
            onOpenLocation: { _, _, _ in })
        let host = NSHostingView(rootView: content.environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let view = try #require(findTextView(host))
        #expect(view.isEditable)
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        view.insertText("hello", replacementRange: view.selectedRange())
        #expect(view.string == "ready> hello")
        #expect(presentation.inputDraft == "hello")
        view.setSelectedRange(NSRange(location: 0, length: 3))
        view.deleteBackward(nil)
        #expect(view.string == "ready> hello")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertText("!", replacementRange: view.selectedRange())
        #expect(view.string == "ready> hello!")
        acceptsInput = false
        #expect(view.delegate?.textView?(view, doCommandBy: #selector(NSTextView.insertNewline(_:))) == true)
        #expect(view.string == "ready> hello!")
        acceptsInput = true
        #expect(view.delegate?.textView?(view, doCommandBy: #selector(NSTextView.insertNewline(_:))) == true)
        #expect(submitted == ["hello!\n", "hello!\n"])
        #expect(view.string == "ready> ")
        #expect(presentation.inputDraft.isEmpty)
        #expect(view.delegate?.textView?(view, doCommandBy: #selector(NSTextView.insertNewline(_:))) == true)
        #expect(submitted.last == "\n")
    }

    @Test
    func producerUpdatesKeepDraftAndIMEWhileSessionChangesClearIt() throws {
        let presentation = ConsoleFoldPresentation()
        let sessionID = UUID()
        func content(_ output: String, session: UUID = sessionID, acceptsInput: Bool = true) -> OutputTextView {
            OutputTextView(output: output, searchRoots: [], fileExists: { _ in false }, emptyMessage: "",
                fontSize: 13, consolePresentation: presentation,
                standardInputSessionID: session, onSubmitStandardInput: acceptsInput ? { _ in true } : nil,
                onOpenLocation: { _, _, _ in })
        }
        let host = NSHostingView(rootView: content("first\n"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let view = try #require(findTextView(host))
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        view.insertText("draft", replacementRange: view.selectedRange())
        host.rootView = content("first\nsecond\n")
        host.layoutSubtreeIfNeeded()
        #expect(view.string == "first\nsecond\ndraft")
        #expect(view.selectedRange().location == view.string.utf16.count)
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: view.selectedRange())
        #expect(view.hasMarkedText())
        host.rootView = content("first\nsecond\nthird\n")
        host.layoutSubtreeIfNeeded()
        #expect(view.hasMarkedText())
        view.insertText("你", replacementRange: view.markedRange())
        #expect(view.string == "first\nsecond\nthird\ndraft你")
        host.rootView = content("finished\n", acceptsInput: false)
        host.layoutSubtreeIfNeeded()
        #expect(!view.isEditable)
        #expect(view.string == "finished\n")
        host.rootView = content("new> ", session: UUID())
        host.layoutSubtreeIfNeeded()
        #expect(view.isEditable)
        #expect(view.string == "new> ")
        #expect(presentation.inputDraft.isEmpty)
    }

    @Test
    func editableConsoleStillOpensSourceLinksAndTogglesFolds() throws {
        let output = (1...12).map { "\tat demo.Main.frame\($0)(Main.java:1)\n" }.joined()
        let presentation = ConsoleFoldPresentation()
        var openedLine: Int?
        let content = OutputTextView(output: output, searchRoots: [URL(fileURLWithPath: "/workspace")],
            fileExists: { _ in true }, emptyMessage: "", fontSize: 13,             consolePresentation: presentation, standardInputSessionID: UUID(), onSubmitStandardInput: { _ in true },
            onOpenLocation: { _, line, _ in openedLine = line })
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let view = try #require(findTextView(host))
        let layout = try #require(view.layoutManager), container = try #require(view.textContainer)
        func click(_ point: NSPoint) throws {
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(point, to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1))
            view.mouseDown(with: event)
        }
        func clickText(_ token: String) throws {
            layout.ensureLayout(for: container)
            let range = (view.string as NSString).range(of: token)
            try #require(range.location != NSNotFound)
            let rect = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
            try click(NSPoint(x: rect.midX + view.textContainerOrigin.x, y: rect.midY + view.textContainerOrigin.y))
        }
        try clickText("<4 folded frames>")
        #expect(view.string == output)
        let anchor = try #require(view.consoleFoldAnchors().first)
        try click(NSPoint(x: anchor.rect.midX, y: anchor.rect.midY))
        #expect(view.string.contains("<4 folded frames>"))
        try clickText("Main.java:1")
        #expect(openedLine == 1)
    }

    @Test(arguments: [false, true], [HorizontalEdge.leading, .trailing])
    func wallpaperChangesUpdateEveryConsoleLayerWithoutReplacingInput(dark: Bool, toolbarEdge: HorizontalEdge) throws {
        let presentation = ConsoleFoldPresentation()
        let sessionID = UUID()
        func content(_ wallpaper: Bool) -> some View {
            OutputTextView(output: "ready> ", searchRoots: [], fileExists: { _ in false }, emptyMessage: "",
                showsConsoleToolbar: true, consoleToolbarPlacement: toolbarEdge,
                fontSize: 13,                 consolePresentation: presentation, standardInputSessionID: sessionID,
                onSubmitStandardInput: { _ in true }, onOpenLocation: { _, _, _ in })
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.workbenchHasBackgroundImage, wallpaper)
                .background(Color(red: 0.8, green: 0.1, blue: 0.2))
        }
        let host = NSHostingView(rootView: content(false))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let view = try #require(findTextView(host))
        let scroll = try #require(view.enclosingScrollView)
        let outputFrame = scroll.convert(scroll.bounds, to: host)
        #expect(abs(outputFrame.width - (600 - LitheTheme.ActionStripe.width - 1)) < 1)
        #expect(abs(outputFrame.minX - (toolbarEdge == .leading ? LitheTheme.ActionStripe.width + 1 : 0)) < 1)
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        view.insertText("draft", replacementRange: view.selectedRange())
        for wallpaper in [false, true, false] {
            host.rootView = content(wallpaper)
            host.layoutSubtreeIfNeeded()
            #expect(findTextView(host) === view)
            #expect(!view.drawsBackground)
            // Shared SwiftUI surfaces own both solid theme and wallpaper backgrounds.
            #expect(!scroll.drawsBackground)
            #expect(presentation.inputDraft == "draft")
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            // Both the action stripe and native output must expose the same
            // wallpaper, then restore the theme surface when it is removed.
            for logicalX in [18, 582] {
                let pixel = try #require(bitmap.colorAt(x: logicalX * bitmap.pixelsWide / 600,
                    y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
                #expect((pixel.redComponent - pixel.greenComponent > 0.4) == wallpaper)
            }
        }
    }

    @Test(arguments: [false, true])
    func realScrollViewPaintsBothFoldMarkersAndTogglesThem(dark: Bool) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/IDEAIcons")
        let source = (1...12).map { "\tat demo.Main.frame\($0)(Main.java:\($0))\n" }.joined()
        let presentation = ConsoleFoldPresentation()
        func content(_ output: String) -> some View {
            OutputTextView(output: output, searchRoots: [], fileExists: { _ in false }, emptyMessage: "",
                fontSize: 13, consolePresentation: presentation,
                onOpenLocation: { _, _, _ in })
                .environment(\.colorScheme, dark ? .dark : .light)
        }
        let host = NSHostingView(rootView: content("starting\n"))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let view = try #require(findTextView(host))
        // SwiftPM has no app-bundle SVGs. Resolve the exact production resources.
        view.consoleFoldImage = { NSImage(contentsOf: root.appendingPathComponent($0)) }
        host.rootView = content(source)
        host.layoutSubtreeIfNeeded()
        for expanded in [false, true, false] {
            view.layoutManager?.ensureLayout(for: try #require(view.textContainer))
            let anchor = try #require(view.consoleFoldAnchors().first)
            #expect(anchor.isExpanded == expanded)
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: anchor.rect))
            view.cacheDisplay(in: anchor.rect, to: bitmap)
            var visiblePixels = 0
            for x in 0..<bitmap.pixelsWide {
                for y in 0..<bitmap.pixelsHigh {
                    if let c = bitmap.colorAt(x: x, y: y), c.alphaComponent > 0.1 {
                        // Compare against the Console background, not text outside the gutter.
                        let background = LitheConsoleStyle.background(dark: dark).usingColorSpace(.sRGB)!
                        let pixel = c.usingColorSpace(.sRGB)!
                        if abs(pixel.redComponent - background.redComponent) > 0.1 { visiblePixels += 1 }
                    }
                }
            }
            #expect(visiblePixels > 3, "Fold marker is not painted (expanded=\(expanded), dark=\(dark))")
            let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
                location: view.convert(NSPoint(x: anchor.rect.midX, y: anchor.rect.midY), to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
            view.mouseDown(with: click)
            #expect(view.string.contains("<4 folded frames>") == expanded)
        }
    }

    @Test(arguments: [true, false])
    func nextAndPreviousVisitDistinctOccurrencesOfTheSameSourceLink(forward: Bool) throws {
        let output = String(repeating: "\tat demo.Main.repeat(Main.java:1)\n", count: 3)
        var opened = 0
        func content(_ source: String) -> OutputTextView {
            OutputTextView(output: source,
                searchRoots: [URL(fileURLWithPath: "/fixture")], fileExists: { _ in true }, emptyMessage: "",
                fontSize: 13, onOpenLocation: { _, _, _ in opened += 1 })
        }
        let host = NSHostingView(rootView: content(output))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let view = try #require(findTextView(host))
        let storage = try #require(view.textStorage)
        var ranges: [NSRange] = []
        var urls: [URL] = []
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let url = value as? URL, url.scheme == "lithe-open" { ranges.append(range); urls.append(url) }
        }
        #expect(ranges.count == 3)
        #expect(Set(urls).count == 1)
        let target = try #require(view.delegate as? NSObject)
        let next = NSSelectorFromString("nextConsoleOccurrence:")
        let previous = NSSelectorFromString("previousConsoleOccurrence:")
        try #require(target.responds(to: next) && target.responds(to: previous))
        let action = forward ? next : previous
        for index in forward ? [0, 1, 2, 0] : [2, 1, 0, 2] {
            _ = target.perform(action, with: nil)
            #expect(view.selectedRange() == ranges[index])
        }
        // Replace the source while retaining identical link URLs and ranges;
        // navigation must restart rather than continue its old position.
        host.rootView = content(output.replacingOccurrences(of: "repeat", with: "modify"))
        host.layoutSubtreeIfNeeded()
        _ = target.perform(action, with: nil)
        #expect(view.selectedRange() == ranges[forward ? 0 : 2])
        #expect(opened == 5)
    }

    @Test
    func consoleNavigationButtonsFollowSourceLinksAndIgnoreSupersededUpdates() async throws {
        let application = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAccessibility = (application.accessibilityAttributeValue(attribute) as? Bool) ?? false
        application.accessibilitySetValue(true, forAttribute: attribute)
        defer { application.accessibilitySetValue(previousAccessibility, forAttribute: attribute) }
        func content(_ output: String) -> AnyView {
            AnyView(OutputTextView(output: output, searchRoots: [URL(fileURLWithPath: "/fixture")],
                fileExists: { _ in true }, emptyMessage: "", showsConsoleToolbar: true,
                onOpenLocation: { _, _, _ in })
                .environment(\.locale, Locale(identifier: "en")))
        }
        let host = NSHostingView(rootView: content("plain output"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = host
        window.orderFront(nil)
        func navigationMatches(_ enabled: Bool) -> Bool {
            CFRunLoopRunInMode(.defaultMode, 0, true)
            let buttons = accessibilityButtons(in: host).filter {
                ["Previous Stack Trace", "Next Stack Trace"].contains(
                    $0.accessibilityLabel?() ?? $0.accessibilityTitle?() ?? "")
            }
            return buttons.count == 2 && buttons.allSatisfy { $0.isAccessibilityEnabled?() == enabled }
        }
        func awaitNavigation(_ enabled: Bool) async -> Bool {
            var queuedUpdatesPassed = false
            DispatchQueue.main.async { queuedUpdatesPassed = true }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(2))
            repeat {
                host.layoutSubtreeIfNeeded()
                if queuedUpdatesPassed && navigationMatches(enabled) { return true }
                await Task.yield()
            } while clock.now < deadline
            return queuedUpdatesPassed && navigationMatches(enabled)
        }
        #expect(await awaitNavigation(false))
        let linked = "\tat demo.Main.run(Main.java:42)\n"
        host.rootView = content(linked)
        #expect(await awaitNavigation(true))
        host.rootView = content("")
        #expect(await awaitNavigation(false))
        // A link update superseded before queued delivery must not re-enable navigation.
        host.rootView = content(linked)
        host.layoutSubtreeIfNeeded()
        host.rootView = content("")
        host.layoutSubtreeIfNeeded()
        #expect(await awaitNavigation(false))
        // Dismantle with a notification pending, then mount a fresh empty Console.
        host.rootView = content(linked)
        host.layoutSubtreeIfNeeded()
        host.rootView = AnyView(EmptyView())
        host.layoutSubtreeIfNeeded()
        host.rootView = content("")
        #expect(await awaitNavigation(false))
    }

    @Test
    func stoppedDebugContentCanSwitchFromVariablesBackToRetainedConsole() async throws {
        let application = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAccessibility = (application.accessibilityAttributeValue(attribute) as? Bool) ?? false
        application.accessibilitySetValue(true, forAttribute: attribute)
        defer { application.accessibilitySetValue(previousAccessibility, forAttribute: attribute) }
        let domain = "lithe.debug-retained-console.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = MacUserDefaultsStore(defaults: defaults)
        let settings = AppSettings(store: store)
        let model = AppModel(settings: settings,
            services: MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode).services)
        let feature = GenericDebugFeatureModel(sessions: DebugAdapterSessionManager(providers: []) { _, _ in nil })
        defer { feature.reset() }
        feature.appendDebuggeeOutput("retained console output\n")
        let host = NSHostingView(rootView: GenericDebugView(feature: feature).environmentObject(model)
            .environment(\.locale, Locale(identifier: "en")))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = host
        window.orderFront(nil)
        func button(_ title: String) -> AnyObject? {
            accessibilityButtons(in: host).first { ($0.accessibilityLabel?() ?? $0.accessibilityTitle?()) == title }
        }
        func awaitView(_ condition: () -> Bool) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(2))
            repeat {
                host.layoutSubtreeIfNeeded()
                if condition() { return true }
                await Task.yield()
            } while clock.now < deadline
            return condition()
        }
        #expect(await awaitView { button("Threads & Variables") != nil })
        let variables = try #require(button("Threads & Variables"))
        #expect(variables.accessibilityPerformPress?() == true)
        #expect(await awaitView { findTextView(host) == nil })
        feature.stop()
        #expect(await awaitView { button("Console") != nil })
        let console = try #require(button("Console"))
        #expect(console.accessibilityPerformPress?() == true)
        #expect(await awaitView { findTextView(host)?.string.contains("retained console output") == true })
    }

    private func accessibilityButtons(in element: Any) -> [AnyObject] {
        // SwiftUI nodes expose the native selectors without adopting the full
        // NSAccessibilityProtocol. Optional dispatch also handles ignored views.
        let accessible = element as AnyObject
        let isButton = accessible.accessibilityRole?() == .button
        return (isButton ? [accessible] : [])
            + (accessible.accessibilityChildren?() ?? []).flatMap { accessibilityButtons(in: $0) }
    }

    private func findTextView(_ view: NSView) -> OutputNativeTextView? {
        if let text = view as? OutputNativeTextView { return text }
        return view.subviews.lazy.compactMap { findTextView($0) }.first
    }
}
