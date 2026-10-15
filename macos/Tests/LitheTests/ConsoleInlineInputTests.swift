import AppKit
import SwiftUI
import Testing
@testable import Lithe

@MainActor
@Suite("Console inline standard input", .serialized)
struct ConsoleInlineInputTests {
    @Test(arguments: [false, true])
    func nativeInputProtectsLogsAndSendsOnlyTheDraft(dark: Bool) throws {
        let presentation = ConsoleFoldPresentation()
        var submitted: [String] = []
        var acceptsInput = true
        let content = OutputTextView(output: "ready> ", searchRoots: [], fileExists: { _ in false }, emptyMessage: "",
            fontSize: 13, usesIDEAConsoleStyle: true, consolePresentation: presentation,
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
                fontSize: 13, usesIDEAConsoleStyle: true, consolePresentation: presentation,
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
            fileExists: { _ in true }, emptyMessage: "", fontSize: 13, usesIDEAConsoleStyle: true,
            consolePresentation: presentation, standardInputSessionID: UUID(), onSubmitStandardInput: { _ in true },
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

    @Test(arguments: [false, true])
    func wallpaperChangesUpdateEveryConsoleLayerWithoutReplacingInput(dark: Bool) throws {
        let presentation = ConsoleFoldPresentation()
        let sessionID = UUID()
        func content(_ wallpaper: Bool) -> some View {
            OutputTextView(output: "ready> ", searchRoots: [], fileExists: { _ in false }, emptyMessage: "",
                showsConsoleToolbar: true, fontSize: 13, usesIDEAConsoleStyle: true,
                consolePresentation: presentation, standardInputSessionID: sessionID,
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
            for logicalX in [18, 500] {
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
                fontSize: 13, usesIDEAConsoleStyle: true, consolePresentation: presentation,
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
                fontSize: 13, usesIDEAConsoleStyle: true, onOpenLocation: { _, _, _ in opened += 1 })
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

    private func findTextView(_ view: NSView) -> OutputNativeTextView? {
        if let text = view as? OutputNativeTextView { return text }
        return view.subviews.lazy.compactMap { findTextView($0) }.first
    }
}
