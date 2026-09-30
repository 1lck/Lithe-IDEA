import AppKit
import CoreText
import CryptoKit
import SwiftUI
import Testing
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
            .filter { $0.lastPathComponent.hasPrefix("JetBrainsMono-") && $0.pathExtension == "ttf" }
        #expect(fonts.count == 16)
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
            #expect(registered.familyName == "JetBrains Mono")
            let version = try #require(CTFontCopyName(registered, kCTFontVersionNameKey) as String?)
            #expect(version.contains("2.304"))
            let location = try #require(CTFontCopyAttribute(registered, kCTFontURLAttribute) as? URL)
            #expect(location.standardizedFileURL == resources.appendingPathComponent(font.lastPathComponent))
            #expect(Data(SHA256.hash(data: try Data(contentsOf: location))) == hashes[font.lastPathComponent])
        }
        for (weight, face) in [(NSFont.Weight.regular, "Regular"), (.medium, "Medium"),
                               (.semibold, "SemiBold"), (.bold, "Bold")] {
            let font = LitheTheme.uiNSFont(size: 13, weight: weight)
            #expect(font.fontName == "JetBrainsMono-\(face)")
            #expect(font.pointSize == 13)
        }
        // Render SwiftUI's actual shared font as well: equal-width i/M glyphs
        // catch a system-family fallback even when native registration succeeds.
        let renderer = ImageRenderer(content: Text("iiiiMMMM").font(LitheTheme.uiFont(size: 13)).fixedSize())
        let image = try #require(renderer.cgImage)
        let expectedWidth = ("iiiiMMMM" as NSString).size(withAttributes: [.font: LitheTheme.uiNSFont(size: 13)]).width
        #expect(abs(CGFloat(image.width) - expectedWidth) <= 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: resources.path).sorted() == fonts.map(\.lastPathComponent).sorted())
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
