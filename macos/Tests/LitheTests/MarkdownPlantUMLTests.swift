import AppKit
import CryptoKit
import Foundation
import Testing
import WebKit
@testable import Lithe

@MainActor
struct MarkdownPlantUMLTests {
    @Test(arguments: ["light", "dark"])
    func realOfflineEngineRendersSequenceAndClassDiagrams(appearance: String) async throws {
        let directory = try #require(MarkdownPreviewResources.directoryURL)
        let before = try manifest(directory)
        let renderer = MarkdownPlantUMLRenderer()
        defer { renderer.cancel() }
        for source in [
            "@startuml\nAlice -> Bob : Offline hello\n@enduml",
            "@startuml\nclass Account\nclass Customer\nCustomer --> Account\n@enduml"
        ] {
            let completed = TestGate()
            var image: String?
            var failure: String?
            renderer.render(source: source, dark: appearance == "dark") { value, error in
                image = value as? String
                failure = error
                completed.open()
            }
            try #require(await completed.waitUntilOpen(timeout: .seconds(10)), "Native renderer did not finish")
            #expect(failure == nil, "Renderer failed: \(failure ?? "")")
            let encoded = try #require(image?.split(separator: ",", maxSplits: 1).last)
            let svg = String(decoding: try #require(Data(base64Encoded: String(encoded))), as: UTF8.self)
            #expect(svg.contains("<svg"))
            #expect(svg.contains(source.contains("Alice") ? "Offline hello" : "Account"))
        }
        #expect(try manifest(directory) == before, "Rendering must not mutate bundled inputs")
    }

    @Test func cancellationAndOversizedSourceFinishWithoutRendering() async throws {
        let renderer = MarkdownPlantUMLRenderer()
        defer { renderer.cancel() }
        var replies: [String] = []
        renderer.render(source: "@startuml\nAlice -> Bob\n@enduml", dark: false) { _, error in
            replies.append(error ?? "unexpectedSuccess")
        }
        renderer.cancel()
        #expect(replies == ["diagramCancelled"])
        renderer.render(source: String(repeating: "x", count: MarkdownPlantUMLRenderer.maximumSourceBytes + 1), dark: false) { _, error in
            replies.append(error ?? "unexpectedSuccess")
        }
        #expect(replies == ["diagramCancelled", "diagramSourceTooLarge"])
    }

    @Test func productionPreviewUsesPassiveImagesAndRejectsStaleResults() async throws {
        let coordinator = MarkdownPreviewWebView.Coordinator(scrollPosition: nil)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        coordinator.installPlantUMLBridge(in: configuration)
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
        defer { MarkdownPreviewWebView.dismantleNSView(webView, coordinator: coordinator); window.close() }
        coordinator.loadTemplate(in: webView)
        try #require(await waitForChanges(webViewChanges(webView), timeout: .seconds(5)) {
            !webView.isLoading && webView.title == "Markdown Preview"
        })
        let source = "```plantuml\n@startuml\nAlice -> Bob : Preview\n@enduml\n```"
        let payload = MarkdownPreviewWebView.Payload(
            html: try RustCoreBridge().markdownRender(source).get().html,
            documentURL: URL(fileURLWithPath: "/workspace/README.md"), workspaceURL: nil, appearance: "light"
        )
        let finished = TestGate()
        var response: Result<Any, Error>?
        webView.callAsyncJavaScript("""
            await window.LithePreview.update(payload);
            const image = document.querySelector('.plantuml-shell img');
            const passive = !!image?.src.startsWith('data:image/svg+xml;base64,') &&
                !document.querySelector('.plantuml-shell svg');
            const denied = { ...payload, html: '<pre><code class="language-plantuml">@startuml\\n!include secret.puml\\nAlice -&gt; Bob\\n@enduml</code></pre>' };
            await window.LithePreview.update(denied);
            const fallback = document.querySelector('.diagram-source-fallback code')?.textContent.includes('secret.puml') &&
                document.querySelector('.diagram-error')?.textContent === payload.plantumlFailure;
            const oldRender = window.LithePreview.update(payload);
            const latestRender = window.LithePreview.update({ ...payload, html: '<p>Latest document</p>' });
            const results = await Promise.all([oldRender, latestRender]);
            return { passive, fallback, stale: results[0] === false, latest: results[1] === true,
                text: document.getElementById('content').textContent,
                noDiagram: !document.querySelector('.plantuml-shell') };
            """, arguments: ["payload": payload.javaScriptValue], in: nil, in: .page) {
            response = $0
            finished.open()
        }
        try #require(await finished.waitUntilOpen(timeout: .seconds(12)))
        let completed = try #require(response)
        let values = try #require(try completed.get() as? [String: Any])
        for key in ["passive", "fallback", "stale", "latest", "noDiagram"] { #expect(values[key] as? Bool == true, "\(key): \(values)") }
        #expect(values["text"] as? String == "Latest document")
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
}
