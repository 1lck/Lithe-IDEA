import AppKit
import CryptoKit
import Foundation
import Testing
import WebKit
@testable import Lithe

@MainActor
struct MarkdownPreviewRichContentTests {
    @Test(arguments: ["light", "dark"])
    func formulasChemistryMermaidAndFootnotesRenderOffline(appearance: String) async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try JSONDecoder().decode(
            Fixture.self,
            from: Data(contentsOf: root.appendingPathComponent("shared/fixtures/editor/markdown-rich-content-v1.json"))
        ).source
        let html = try RustCoreBridge().markdownRender(source).get().html
        let directory = try #require(MarkdownPreviewResources.directoryURL)
        let before = try manifest(directory)
        let coordinator = MarkdownPreviewWebView.Coordinator(scrollPosition: nil)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = WebMediaCaptureDenier.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.orderFront(nil)
        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            window.contentView = nil
            window.close()
        }

        coordinator.loadTemplate(in: webView)
        try #require(await waitForChanges(webViewChanges(webView), timeout: .seconds(5)) {
            !webView.isLoading && webView.title == "Markdown Preview"
        }, "The production preview template did not load")

        let completed = TestGate()
        var result: Result<Any, Error>?
        webView.callAsyncJavaScript(
            """
            await window.LithePreview.update({ html, appearance });
            const content = document.getElementById('content');
            const math = content.querySelectorAll('[data-math-style]');
            return {
                formulas: math.length,
                renderedFormulas: content.querySelectorAll('[data-math-style] .katex').length,
                formulaErrors: content.querySelectorAll('.katex-error').length,
                mathml: content.querySelectorAll('math').length,
                mermaid: !!content.querySelector('.mermaid-shell svg'),
                diagramErrors: content.querySelectorAll('.diagram-error').length,
                subscript: Array.from(content.querySelectorAll('p > sub')).some(sub =>
                    sub.textContent === '2' && sub.previousSibling?.textContent.endsWith('H') &&
                    sub.nextSibling?.textContent.startsWith('O')),
                superscript: Array.from(content.querySelectorAll('p > sup')).some(sup =>
                    sup.textContent === '2' && sup.previousSibling?.textContent.endsWith('x')),
                strikethrough: !!content.querySelector('del'),
                code: Array.from(content.querySelectorAll('code')).some(code => code.textContent === 'H~2~O x^2^'),
                footnote: !!content.querySelector('a[data-footnote-ref][href="#fn-note"]') &&
                    !!content.querySelector('#fn-note a[data-footnote-backref]'),
                remoteScripts: Array.from(document.scripts).some(script => /^https?:/.test(script.src)),
                remoteResources: performance.getEntriesByType('resource').some(entry => /^https?:/.test(entry.name)),
                appearance: document.documentElement.dataset.theme
            };
            """,
            arguments: ["html": html, "appearance": appearance], in: nil, in: .page
        ) {
            result = $0
            completed.open()
        }
        try #require(await completed.waitUntilOpen(timeout: .seconds(8)), "Rich Markdown rendering timed out")
        let response = try #require(result)
        let values = try #require(try response.get() as? [String: Any])
        #expect(values["formulas"] as? Int == 3)
        #expect(values["renderedFormulas"] as? Int == 3)
        #expect(values["mathml"] as? Int == 3)
        #expect(values["formulaErrors"] as? Int == 0)
        #expect(values["diagramErrors"] as? Int == 0)
        for key in ["mermaid", "subscript", "superscript", "strikethrough", "code", "footnote"] {
            #expect(values[key] as? Bool == true, "Expected \(key): \(values)")
        }
        #expect(values["remoteScripts"] as? Bool == false)
        #expect(values["remoteResources"] as? Bool == false)
        #expect(values["appearance"] as? String == appearance)
        #expect(try manifest(directory) == before, "Rendering must not mutate packaged preview resources")
    }

    private func manifest(_ directory: URL) throws -> [String: String] {
        let files = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: String] = [:]
        for case let file as URL in files {
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            result[String(file.path.dropFirst(directory.path.count))] = SHA256.hash(data: try Data(contentsOf: file))
                .map { String(format: "%02x", $0) }.joined()
        }
        return result
    }

    private struct Fixture: Decodable {
        let source: String
    }
}
