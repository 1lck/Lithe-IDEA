import AppKit
import CoreText
import CryptoKit
import SwiftUI
import Testing
import LitheGitModule
import WebKit
@testable import Lithe

@MainActor
@Suite("Bundled application typography", .serialized)
struct BundledUIFontTests {
    @Test func packagedFontsRegisterAtProcessScopeAndRemainUnchanged() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Fonts")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let resources = temporary.appendingPathComponent("Typography.bundle/Contents/Resources/Fonts")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let fonts = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            .filter { ["ttf", "otf"].contains($0.pathExtension) }
        #expect(fonts.count == 34)
        var hashes: [String: Data] = [:]
        for font in fonts {
            let destination = resources.appendingPathComponent(font.lastPathComponent)
            try FileManager.default.copyItem(at: font, to: destination)
            hashes[font.lastPathComponent] = Data(SHA256.hash(data: try Data(contentsOf: destination)))
        }
        let contents = resources.deletingLastPathComponent().deletingLastPathComponent()
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "test.lithe.typography"],
            format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try #require(Bundle(url: contents.deletingLastPathComponent()))
        // Cleanup only fonts owned by this temporary bundle, including on an assertion failure.
        defer {
            for font in fonts {
                CTFontManagerUnregisterFontsForURL(resources.appendingPathComponent(font.lastPathComponent) as CFURL,
                                                  .process, nil)
            }
        }
        var messages: [String] = []
        MacBundledFontRegistry.registerFonts(bundle: bundle) { messages.append($0) }
        MacBundledFontRegistry.registerFonts(bundle: bundle) { messages.append($0) }
        #expect(messages.isEmpty)
        for font in fonts {
            let name = font.deletingPathExtension().lastPathComponent
            let registered = try #require(NSFont(name: name, size: 13))
            #expect(registered.familyName == (name.hasPrefix("Inter-") ? "Inter" : "JetBrains Mono"))
            if name.hasPrefix("JetBrainsMono-") {
                let version = try #require(CTFontCopyName(registered, kCTFontVersionNameKey) as String?)
                #expect(version.contains("2.304"))
            } else {
                // The official Inter 4.1 distribution identifies its static faces as 4.001.
                let version = try #require(CTFontCopyName(registered, kCTFontVersionNameKey) as String?)
                #expect(version.contains("4.001"))
            }
            let location = try #require(CTFontCopyAttribute(registered, kCTFontURLAttribute) as? URL)
            #expect(location.standardizedFileURL == resources.appendingPathComponent(font.lastPathComponent))
            #expect(Data(SHA256.hash(data: try Data(contentsOf: location))) == hashes[font.lastPathComponent])
        }
        for (weight, face) in [(NSFont.Weight.regular, "Regular"), (.medium, "Medium"),
                               (.semibold, "SemiBold"), (.bold, "Bold")] {
            let font = LitheTheme.editorFont(size: 13, weight: weight)
            #expect(font.fontName == "JetBrainsMono-\(face)")
            #expect(font.pointSize == 13)
        }
        // Compare only the white letter pixels with the Community font, not
        // the avatar gradient. This catches the old Inter Bold glyphs.
        func whiteGlyphs<V: View>(_ view: V) throws -> [Bool] {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
            return try (0..<bitmap.pixelsHigh).flatMap { y in
                try (0..<bitmap.pixelsWide).map { x in
                    let color = try #require(bitmap.colorAt(x: x, y: y))
                    return color.alphaComponent > 0.95 && color.redComponent > 0.95
                        && color.greenComponent > 0.95 && color.blueComponent > 0.95
                }
            }
        }
        let avatar = try whiteGlyphs(ProjectAvatarBadge(name: "Lithe-IDEA", colorIndex: 5, size: 20))
        let reference = try whiteGlyphs(Text("LI").font(Font(LitheTheme.editorFont(size: 13, weight: .semibold)))
            .foregroundStyle(.white).frame(width: 20, height: 20))
        #expect(avatar.contains(true))
        #expect(avatar == reference)
        let uiFont = LitheTheme.uiNSFont(size: 13)
        #expect(uiFont.fontName == "Inter-Regular")
        for (weight, native, face) in [(Font.Weight.regular, NSFont.Weight.regular, "Regular"),
                                      (.medium, .medium, "Medium"), (.semibold, .semibold, "SemiBold"),
                                      (.bold, .bold, "Bold"), (.black, .black, "Black")] {
            let expected = try #require(NSFont(name: "Inter-\(face)", size: 13))
            #expect(LitheTheme.uiNSFont(size: 13, weight: native).fontName == expected.fontName)
            let renderer = ImageRenderer(content: Text("iiiiMMMM").font(LitheTheme.uiFont(size: 13, weight: weight)).fixedSize())
            let image = try #require(renderer.cgImage)
            let width = ("iiiiMMMM" as NSString).size(withAttributes: [.font: expected]).width
            #expect(abs(CGFloat(image.width) - width) <= 1)
        }
        #expect(("iiii" as NSString).size(withAttributes: [.font: uiFont]).width
                < ("MMMM" as NSString).size(withAttributes: [.font: uiFont]).width)
        #expect(GitGraphGeometry.rowHeight(for: uiFont) == 26)
        #expect(GitGraphGeometry.textBaseline(for: uiFont, height: 26) == 18)
        let largeFont = LitheTheme.uiNSFont(size: 32)
        let largeHeight = GitGraphGeometry.rowHeight(for: largeFont)
        #expect(largeHeight > 26)
        #expect(GitGraphGeometry.textBaseline(for: largeFont, height: largeHeight) + ceil(-largeFont.descender) <= largeHeight)
        // Capture the actual commit-row renderer while only the test bundle's fonts are registered.
        if let directory = ProcessInfo.processInfo.environment["LITHE_GIT_GRAPH_CAPTURE_DIR"] {
            let commits = ["update", "Merge branch 'preview' into codex/frontend2", "chore(issue): expand automatic labels", "fix(ci): restore service helper placement", "修复界面：中文、emoji 👨‍👩‍👧‍👦 和较长标题的省略显示，确认文字超出单元格时不会覆盖右侧作者与日期列"]
                .enumerated().map { index, subject in
                    GitCommit(hash: String(index), shortHash: String(index), parentHashes: index == 1 ? ["2", "3"] : [],
                              authorName: "Author", authorEmail: "author@example.invalid", date: "2026/09/30",
                              subject: subject, decorations: "")
                }
            let rows = GitGraphLayoutService.layout(commits: commits).rows
            for dark in [false, true] {
                let view = GitGraphCommitRowsNSView(frame: NSRect(x: 0, y: 0, width: 720, height: CGFloat(rows.count) * 26))
                view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                view.update(rows: rows, selectedHash: "0", showDecorations: false, graphWidth: 30, rowHeight: 26,
                            actions: GitGraphRowActions(onSelect: { _ in }, onCherryPick: { _ in }, onRevert: { _ in },
                                                        onReset: { _, _ in }, onCreateTag: { _ in }))
                let surface = GraphCaptureBackground(frame: view.bounds)
                surface.appearance = view.appearance
                surface.addSubview(view)
                let bitmap = try #require(surface.bitmapImageRepForCachingDisplay(in: surface.bounds))
                surface.cacheDisplay(in: surface.bounds, to: bitmap)
                let root = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: root.appendingPathComponent("typography-\(dark ? "dark" : "light").png"))
            }
        }
        // Compare SwiftUI and AppKit metrics so one renderer cannot fall back to Mono.
        for (font, native) in [
            (LitheTheme.uiFont(size: 13), uiFont),
            (LitheTheme.uiFont(size: 13, design: .monospaced), LitheTheme.editorFont(size: 13))
        ] {
            let renderer = ImageRenderer(content: Text("iiiiMMMM").font(font).fixedSize())
            let image = try #require(renderer.cgImage)
            let expectedWidth = ("iiiiMMMM" as NSString).size(withAttributes: [.font: native]).width
            #expect(abs(CGFloat(image.width) - expectedWidth) <= 1)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: resources.path).sorted() == fonts.map(\.lastPathComponent).sorted())
    }

    @Test func textStylePreservesRequestedFontDesign() {
        let size = NSFont.preferredFont(forTextStyle: .caption1).pointSize
        #expect(LitheTheme.uiFont(.caption, design: .monospaced) ==
                LitheTheme.uiFont(size: size, design: .monospaced))
        #expect(LitheTheme.uiFont(.caption) == LitheTheme.uiFont(size: size))
        #expect(LitheTheme.uiFont(.headline, design: .monospaced) ==
                LitheTheme.uiFont(size: NSFont.preferredFont(forTextStyle: .headline).pointSize,
                                  weight: .bold, design: .monospaced))
    }

    @Test func embeddedEditorReadsOnlyBundledFontDirectory() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let editor = temporary.appendingPathComponent("MonacoEditor")
        let fonts = temporary.appendingPathComponent("Fonts")
        try FileManager.default.createDirectory(at: editor, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let font = fonts.appendingPathComponent("JetBrainsMono-Regular.ttf")
        let bytes = Data([0, 1, 2, 3])
        try bytes.write(to: font)
        try bytes.write(to: temporary.appendingPathComponent("outside.ttf"))
        let assets = MonacoWorkbenchAssets(root: editor, fontsRoot: fonts)
        let webView = WKWebView(frame: .zero)
        defer { webView.stopLoading() }
        let request = FontAssetTask("lithe-editor://app/fonts/JetBrainsMono-Regular.ttf")
        assets.webView(webView, start: request)
        #expect(request.finished && request.error == nil)
        #expect(request.data == bytes)
        #expect(request.response?.mimeType == "font/ttf")
        for path in ["fonts/../outside.ttf", "fonts/../../outside.ttf", "fonts/OFL.txt"] {
            let denied = FontAssetTask("lithe-editor://app/\(path)")
            assets.webView(webView, start: denied)
            #expect(denied.error != nil && !denied.finished)
            #expect(denied.data.isEmpty)
        }
        #expect(try Data(contentsOf: font) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fonts.path) == [font.lastPathComponent])
    }

    @Test(arguments: [ColorScheme.dark, .light])
    func gitLogHoverAndSelectionRenderSourceColors(scheme: ColorScheme) throws {
        func renderedColor(selected: Bool, hovered: Bool, focused: Bool = true) throws -> NSColor {
            let renderer = ImageRenderer(content: LitheTheme.GitLog.rowBackground(
                selected: selected, hovered: hovered, focused: focused)
                .frame(width: 20, height: 26).environment(\.colorScheme, scheme))
            let image = try #require(renderer.cgImage)
            #expect(image.height == 26)
            var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            try pixels.withUnsafeMutableBytes { bytes in
                let context = try #require(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            let offset = (13 * image.width + 10) * 4
            let alpha = CGFloat(pixels[offset + 3]) / 255
            return NSColor(srgbRed: CGFloat(pixels[offset]) / 255 / max(alpha, 0.001),
                           green: CGFloat(pixels[offset + 1]) / 255 / max(alpha, 0.001),
                           blue: CGFloat(pixels[offset + 2]) / 255 / max(alpha, 0.001), alpha: alpha)
        }
        let selected = try renderedColor(selected: true, hovered: false)
        let selectedHovered = try renderedColor(selected: true, hovered: true)
        #expect(abs(selected.redComponent - selectedHovered.redComponent) < 0.005)
        let focusedHex: UInt32 = scheme == .dark ? 0x2A4371 : 0xD0DFFE
        #expect(abs(selected.redComponent - CGFloat(focusedHex >> 16) / 255) < 0.005)
        #expect(abs(selected.greenComponent - CGFloat((focusedHex >> 8) & 255) / 255) < 0.005)
        #expect(abs(selected.blueComponent - CGFloat(focusedHex & 255) / 255) < 0.005)
        let hover = try renderedColor(selected: false, hovered: true)
        if scheme == .dark {
            #expect(hover.alphaComponent == 1)
            #expect(abs(hover.redComponent - 40.0 / 255) < 0.005)
            #expect(abs(hover.greenComponent - 41.0 / 255) < 0.005)
            #expect(abs(hover.blueComponent - 43.0 / 255) < 0.005)
        } else {
            #expect(abs(hover.redComponent - 233.0 / 255) < 0.005)
            #expect(abs(hover.greenComponent - 234.0 / 255) < 0.005)
            #expect(abs(hover.blueComponent - 236.0 / 255) < 0.005)
        }
        let inactive = try renderedColor(selected: true, hovered: true, focused: false)
        #expect(abs(inactive.redComponent - selected.redComponent) > 0.01)
    }
}

private final class FontAssetTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    var response: URLResponse?
    var data = Data()
    var finished = false
    var error: Error?
    init(_ url: String) { request = URLRequest(url: URL(string: url)!) }
    func didReceive(_ response: URLResponse) { self.response = response }
    func didReceive(_ data: Data) { self.data.append(data) }
    func didFinish() { finished = true }
    func didFailWithError(_ error: Error) { self.error = error }
}
