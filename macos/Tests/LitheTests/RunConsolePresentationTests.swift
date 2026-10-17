import AppKit
import CoreText
import Testing
@testable import Lithe

@MainActor
@Suite("Run console presentation")
struct RunConsolePresentationTests {
    @Test(arguments: [false, true])
    func logsKeepPlainTextAndProducerANSIColors(dark: Bool) throws {
        let source = "2026-10-15 12:00:00 INFO ready\n\u{1b}[31merror\u{1b}[91mbright\u{1b}[0m"
        let result = OutputTextView.renderOutput(source, searchRoots: [], fileExists: { _ in false },
            isDark: dark, theme: .lithe, fontSize: 13, usesIDEAConsoleStyle: true)
        let text = result.string as NSString
        for token in ["2026", "ready"] {
            let color = try #require(result.attribute(.foregroundColor, at: text.range(of: token).location, effectiveRange: nil) as? NSColor)
            #expect(color == LitheConsoleStyle.foreground(dark: dark))
        }
        #expect(result.attribute(.foregroundColor, at: text.range(of: "INFO").location,
            effectiveRange: nil) as? NSColor == LitheConsoleStyle.palette(dark: dark)[2])
        for (token, index) in [("error", 1), ("bright", 9)] {
            let color = try #require(result.attribute(.foregroundColor, at: text.range(of: token).location, effectiveRange: nil) as? NSColor)
            #expect(color == LitheConsoleStyle.palette(dark: dark)[index])
        }
        #expect(result.string == "2026-10-15 12:00:00 INFO ready\nerrorbright")
    }

    @Test func usesTheShippedJetBrainsMonoLineHeight() throws {
        let fontURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Fonts/JetBrainsMono-Regular.ttf")
        let provider = try #require(CGDataProvider(url: fontURL as CFURL))
        let graphicsFont = try #require(CGFont(provider))
        let font = CTFontCreateWithGraphicsFont(graphicsFont, 13, nil, nil) as NSFont
        #expect(LitheConsoleStyle.lineHeight(for: font) == 22)
        let result = OutputTextView.renderOutput("one\ntwo\n", searchRoots: [], fileExists: { _ in false },
            isDark: true, theme: .lithe, fontSize: 13, usesIDEAConsoleStyle: true)
        let paragraph = try #require(result.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let renderedFont = try #require(result.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(renderedFont.pointSize == 13)
        #expect(paragraph.minimumLineHeight == paragraph.maximumLineHeight)
        #expect(paragraph.minimumLineHeight > renderedFont.pointSize)
    }

    @Test(arguments: [false, true])
    func stackTraceLinksKeepNavigationAndConsoleLinkAppearance(dark: Bool) throws {
        let result = OutputTextView.renderOutput("at demo.Main.run(Main.java:42)",
            searchRoots: [URL(fileURLWithPath: "/project")],
            fileExists: { $0.path == "/project/src/main/java/demo/Main.java" },
            isDark: dark, theme: .lithe, fontSize: 13, usesIDEAConsoleStyle: true)
        var links = 0
        result.enumerateAttribute(.link, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            guard let url = value as? URL else { return }
            links += 1
            #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "line", value: "42")) == true)
            #expect(result.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor == LitheConsoleStyle.hyperlink(dark: dark))
            #expect(result.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
        }
        #expect(links == 1)
    }
}
