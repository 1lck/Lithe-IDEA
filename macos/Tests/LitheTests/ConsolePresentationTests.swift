import AppKit
import CoreText
import Testing
@testable import Lithe

@MainActor
@Suite("IDEA console presentation", .serialized)
struct ConsolePresentationTests {
    @Test(arguments: [false, true])
    func timestampedLevelsShareColorsWithoutRepaintingMessages(dark: Bool) throws {
        let source = "00:20:11.123 2026-10-16T00:20:11.000-07:00 \u{1b}[34mINFO\u{1b}[0m 42 --- [main] demo.App : body ERROR.java\n"
            + "2026-10-16 00:20:11 [main] WARN warning body\n[ERROR] error body\nordinary INFO message\n"
        let rendered = OutputTextView.renderOutput(source, searchRoots: [], fileExists: { _ in false },
            isDark: dark, theme: .lithe, usesIDEAConsoleStyle: true)
        let text = rendered.string as NSString
        for (token, index) in [("INFO", 2), ("WARN", 3), ("[ERROR]", 1)] {
            let range = text.range(of: token)
            let offset = range.location + (token.hasPrefix("[") ? 1 : 0)
            #expect(rendered.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor
                == LitheConsoleStyle.palette(dark: dark)[index])
        }
        for token in ["body ERROR.java", "warning body", "error body", "ordinary INFO message"] {
            #expect(rendered.attribute(.foregroundColor, at: text.range(of: token).location,
                effectiveRange: nil) as? NSColor == LitheConsoleStyle.foreground(dark: dark))
        }
    }

    @Test(arguments: [false, true])
    func mavenProducerStylesOnlyItsOwnSegments(dark: Bool) throws {
        let source = "[\u{1b}[1;34mINFO\u{1b}[m] Nothing to compile\n[\u{1b}[1;34mINFO\u{1b}[m] \u{1b}[1m--- \u{1b}[0;32mcompiler:3.13.0:compile\u{1b}[m ---\n"
        let rendered = OutputTextView.renderOutput(source, searchRoots: [], fileExists: { _ in false },
            isDark: dark, theme: .lithe, fontSize: 13, usesIDEAConsoleStyle: true)
        let text = rendered.string as NSString
        for (token, expected) in [("INFO", LitheConsoleStyle.palette(dark: dark)[2]),
            ("Nothing to compile", LitheConsoleStyle.foreground(dark: dark)),
            ("compiler:", LitheConsoleStyle.palette(dark: dark)[2])] {
            let color = try #require(rendered.attribute(.foregroundColor, at: text.range(of: token).location,
                effectiveRange: nil) as? NSColor)
            #expect(color == expected)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func plainMavenInfoKeepsDefaultConsoleForeground(dark: Bool, consoleStyle: Bool) throws {
        let source = "[INFO] Compiling 1 source file\n[INFO] --- compiler:3.13.0:compile ---\n"
        let rendered = OutputTextView.renderOutput(source, searchRoots: [], fileExists: { _ in false },
            isDark: dark, theme: .lithe, fontSize: 13, usesIDEAConsoleStyle: consoleStyle)
        let expected = consoleStyle ? LitheConsoleStyle.foreground(dark: dark)
            : LitheTheme.nsColor(.primaryText, theme: .lithe, isDark: dark)
        let text = rendered.string as NSString
        for token in ["Compiling", "compiler:"] {
            #expect(rendered.attribute(.foregroundColor, at: text.range(of: token).location,
                effectiveRange: nil) as? NSColor == expected)
        }
        #expect(rendered.attribute(.foregroundColor, at: text.range(of: "INFO").location,
            effectiveRange: nil) as? NSColor == (consoleStyle ? LitheConsoleStyle.palette(dark: dark)[2] : expected))
        #expect(rendered.string == source)
    }

    @Test func longStacksKeepEightFramesAndCopyTheOriginalUnicodeText() throws {
        let text = "异常 🐞\n" + (1...12).map { "\tat demo.Main.frame\($0)(Main.java:\($0))\n" }.joined()
        let presentation = ConsoleFoldPresentation()
        let raw = NSAttributedString(string: text)
        let folded = presentation.project(raw, dark: true, fontSize: 13)
        #expect(folded.string.contains("frame8("))
        #expect(!folded.string.contains("frame9("))
        #expect(folded.string.contains("<4 folded frames>"))
        #expect(ConsoleFoldPresentation.copyText(folded) == text)
        let region = try #require(presentation.regions.first)
        presentation.expanded.insert(region.id)
        let expanded = presentation.project(raw, dark: true, fontSize: 13)
        #expect(expanded.string == text)
        var anchors = 0
        expanded.enumerateAttribute(.consoleExpandedFoldID, in: NSRange(location: 0, length: expanded.length)) { value, _, _ in
            if value != nil { anchors += 1 }
        }
        #expect(anchors == 1)
        #expect(expanded.string.contains("frame12("))
        #expect(ConsoleFoldPresentation.copyText(expanded) == text)
    }

    @Test(arguments: [false, true])
    func logbackTimeLevelAndLoggerKeepProducerColors(dark: Bool) throws {
        let raw = "\u{1b}[36m2026-10-14 12:00:00\u{1b}[0m \u{1b}[32m[main]\u{1b}[0m \u{1b}[31mERROR\u{1b}[0m \u{1b}[1;35mdemo.Application\u{1b}[0m message"
        let rendered = OutputTextView.renderOutput(raw, searchRoots: [], fileExists: { _ in false },
            isDark: dark, theme: .lithe, fontSize: 13, usesIDEAConsoleStyle: true)
        for (token, index) in [("2026", 6), ("[main]", 2), ("ERROR", 1), ("demo.Application", 5)] {
            let offset = (rendered.string as NSString).range(of: token).location
            #expect(rendered.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor == LitheConsoleStyle.palette(dark: dark)[index])
        }
        let offset = (rendered.string as NSString).range(of: "demo.Application").location
        let font = try #require(rendered.attribute(.font, at: offset, effectiveRange: nil) as? NSFont)
        #expect(font.fontDescriptor.symbolicTraits.contains(.bold))
    }

    @Test func foldedPlaceholderUsesHandAndExpandedGutterDoesNotOccupyText() throws {
        let text = (1...12).map { "\tat demo.Main.frame\($0)(Main.java:1)\n" }.joined()
        let presentation = ConsoleFoldPresentation()
        let raw = NSAttributedString(string: text, attributes: [
            .font: LitheTheme.editorFont(size: 13), .paragraphStyle: LitheConsoleStyle.paragraphStyle(fontSize: 13)
        ])
        let view = OutputNativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        view.usesIDEAConsoleStyle = true
        view.textContainerInset = NSSize(width: 12, height: 12)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { NSCursor.arrow.set(); window.contentView = nil; window.close() }
        window.contentView = view
        view.textStorage?.setAttributedString(presentation.project(raw, dark: true, fontSize: 13))
        let layout = try #require(view.layoutManager), container = try #require(view.textContainer)
        layout.ensureLayout(for: container)
        let range = (view.string as NSString).range(of: "<4 folded frames>")
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        let point = NSPoint(x: rect.midX + view.textContainerOrigin.x, y: rect.midY + view.textContainerOrigin.y)
        let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: view.convert(point, to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        view.mouseMoved(with: event)
        #expect(NSCursor.current === NSCursor.pointingHand)
        let collapsed = try #require(view.consoleFoldAnchors().first)
        #expect(!collapsed.isExpanded)
        #expect(collapsed.rect.size == NSSize(width: 9, height: 9))
        var toggled: String?
        view.onToggleConsoleFold = { toggled = $0 }
        let expandClick = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
            location: view.convert(NSPoint(x: collapsed.rect.midX, y: collapsed.rect.midY), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        view.mouseDown(with: expandClick)
        #expect(toggled == collapsed.id)
        let region = try #require(presentation.regions.first)
        presentation.expanded.insert(region.id)
        view.textStorage?.setAttributedString(presentation.project(raw, dark: true, fontSize: 13))
        layout.ensureLayout(for: container)
        #expect(view.string == text)
        let anchor = try #require(view.consoleFoldAnchors().first)
        #expect(anchor.rect.size == NSSize(width: 9, height: 9))
        #expect(anchor.isExpanded)
        toggled = nil
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
            location: view.convert(NSPoint(x: anchor.rect.midX, y: anchor.rect.midY), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        view.mouseDown(with: click)
        #expect(toggled == region.id)
    }

    @Test func internalFramesSupportModulePrefixesAndNestInsideLongStacks() throws {
        let text = (1...8).map { "\tat demo.Main.frame\($0)(Main.java:1)\n" }.joined()
            + String(repeating: "\tat java.base/java.util.concurrent.ThreadPoolExecutor.runWorker(ThreadPoolExecutor.java:1)\n", count: 5)
        let raw = NSAttributedString(string: text)
        let presentation = ConsoleFoldPresentation()
        let folded = presentation.project(raw, dark: true, fontSize: 13)
        #expect(folded.string.contains("<5 folded frames>"))
        let outer = try #require(presentation.regions.first(where: { $0.kind == "frames" }))
        presentation.expanded.insert(outer.id)
        let nested = presentation.project(raw, dark: true, fontSize: 13)
        #expect(nested.string.contains("<5 internal lines>"))
        #expect(ConsoleFoldPresentation.copyText(nested) == text)
        presentation.expanded = Set(presentation.regions.map(\.id))
        #expect(ConsoleFoldPresentation.copyText(presentation.project(raw, dark: false, fontSize: 18)) == text)
    }

    @Test func stackBoundariesAndEnclosedMoreDoNotFoldOrdinaryLogLines() {
        let first = (1...8).map { "\tat demo.Main.f\($0)(Main.java:1)\n" }.joined()
        #expect(ConsoleStackTraceFolding.regions(in: first).isEmpty)
        let withMore = first + "\t... 20 more\nordinary INFO log\n" + first
        let regions = ConsoleStackTraceFolding.regions(in: withMore)
        #expect(regions.count == 1)
        #expect(regions.first?.label == "\t<1 folded frames>")
    }

    @Test(arguments: [false, true])
    func consolePreservesANSIColorsAndDoesNotDimOrRecolorPlainLogs(dark: Bool) throws {
        let raw = "2026-10-14 12:00:00 INFO plain\n\u{1b}[31mred\u{1b}[91mbright\u{1b}[0m"
        let rendered = OutputTextView.renderOutput(raw, searchRoots: [], fileExists: { _ in false },
            isDark: dark, theme: .lithe, fontSize: 17, usesIDEAConsoleStyle: true)
        let foreground = try #require(rendered.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        #expect(foreground == LitheConsoleStyle.foreground(dark: dark))
        let text = rendered.string as NSString
        let red = try #require(rendered.attribute(.foregroundColor, at: text.range(of: "red").location, effectiveRange: nil) as? NSColor)
        let bright = try #require(rendered.attribute(.foregroundColor, at: text.range(of: "bright").location, effectiveRange: nil) as? NSColor)
        #expect(red == LitheConsoleStyle.palette(dark: dark)[1])
        #expect(bright == LitheConsoleStyle.palette(dark: dark)[9])
        #expect(red != bright)
        let font = try #require(rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize == 17)
    }

    @Test func incrementalProjectionDetectsStyleChangesAndKeepsUnicodeBoundaries() {
        let old = NSAttributedString(string: "🐞same", attributes: [.foregroundColor: NSColor.red])
        let restyled = NSAttributedString(string: "🐞same", attributes: [.foregroundColor: NSColor.green])
        #expect(ConsoleFoldPresentation.firstDifference(old, restyled) == 0)
        let changed = NSAttributedString(string: "🐛same", attributes: [.foregroundColor: NSColor.red])
        #expect(ConsoleFoldPresentation.firstDifference(old, changed) == 0)
        #expect(ConsoleFoldPresentation.firstDifference(old, old) == old.length)
    }

    @Test func unfinishedLastLineStaysVisibleUntilTheNextChunkCompletesIt() {
        let prefix = String(repeating: "\tat demo.Main.run(Main.java:1)\n", count: 8)
        let partial = prefix + "\tat demo.Other.run(Other.java:2)"
        #expect(ConsoleStackTraceFolding.regions(in: partial).isEmpty)
        #expect(ConsoleStackTraceFolding.regions(in: partial + "\n").first?.label == "\t<1 folded frames>")
    }

    @Test func consoleLineHeightUsesIDEAFontMetricsAndSpacing() throws {
        let fontURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Fonts/JetBrainsMono-Regular.ttf")
        let provider = try #require(CGDataProvider(url: fontURL as CFURL))
        let graphicsFont = try #require(CGFont(provider))
        let font = CTFontCreateWithGraphicsFont(graphicsFont, 13, nil, nil) as NSFont
        #expect(LitheConsoleStyle.lineHeight(for: font) == 22)
        let large = CTFontCreateWithGraphicsFont(graphicsFont, 18, nil, nil) as NSFont
        #expect(LitheConsoleStyle.lineHeight(for: large) > 22)
        let rendered = OutputTextView.renderOutput("one\ntwo\n", searchRoots: [], fileExists: { _ in false },
            isDark: true, theme: .lithe, fontSize: 13, usesIDEAConsoleStyle: true)
        let style = try #require(rendered.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.minimumLineHeight == style.maximumLineHeight)
        #expect(style.minimumLineHeight > 13)
    }

    @Test func fontActionsUseOnePointStepsBoundsAndConsoleLocalState() {
        #expect(LitheConsoleStyle.resizedFont(current: 13, delta: 1) == 14)
        #expect(LitheConsoleStyle.resizedFont(current: 13, delta: -1) == 12)
        #expect(LitheConsoleStyle.resizedFont(current: 8, delta: -1) == 8)
        #expect(LitheConsoleStyle.resizedFont(current: 40, delta: 1) == 40)
        #expect(LitheConsoleStyle.resizedFont(current: 24, delta: nil) == 13)
        let first = ConsoleFoldPresentation(), second = ConsoleFoldPresentation()
        first.fontSize = 18
        #expect(second.fontSize == 13)
    }

    @Test func boundedConsoleProjectionKeepsOnlyItsChangedTailVisible() {
        let line = "\tat demo.Main.run(Main.java:1)\n"
        let source = String(repeating: line, count: 10_000)
        let presentation = ConsoleFoldPresentation()
        let result = presentation.project(NSAttributedString(string: source), dark: true, fontSize: 13)
        #expect(result.string.contains("<9992 folded frames>"))
        #expect(ConsoleFoldPresentation.copyText(result) == source)
    }

    @Test func malformedANSIColorsCannotIndexOutsideTheIDEAPalette() {
        for code in ["38;5;-1", "38;5;256", "48;5;-1", "38;2;999;0;0"] {
            let foreground = NSColor.white
            let parsed = ANSIOutputRenderer.parse("\u{1b}[\(code)mtext", defaultForeground: foreground,
                palette: LitheConsoleStyle.palette(dark: true))
            #expect(parsed.cleanText == "text")
            #expect(parsed.segments.first?.foreground == foreground)
        }
    }

    @Test func grayFilterUsesThemeBrightnessAndContrastWithoutChangingAlpha() throws {
        #expect(LitheIDEADisabledIcon.gray(red: 255, green: 255, blue: 255, dark: true) == 91)
        #expect(LitheIDEADisabledIcon.gray(red: 255, green: 255, blue: 255, dark: false) == 210)
        let original = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { bounds in
            NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5).setFill(); bounds.fill(); return true
        }
        let image = LitheIDEADisabledIcon.image(original, dark: true)
        let bitmap = try #require(image.representations.first as? NSBitmapImageRep)
        let pixel = try #require(bitmap.colorAt(x: 16, y: 16)?.usingColorSpace(.sRGB))
        #expect(abs(pixel.alphaComponent - 0.5) < 0.01)
        #expect(abs(pixel.redComponent - pixel.greenComponent) < 0.001)
        #expect(abs(pixel.greenComponent - pixel.blueComponent) < 0.001)
        #expect(image.size == original.size)
    }
}
