import AppKit
import WebKit

// Isolated feasibility host. This does not replace Lithe's document or LSP models.
final class Assets: NSObject, WKURLSchemeHandler {
    let root: URL
    init(root: URL) { self.root = root }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        do {
            guard let url = task.request.url, url.scheme == "lithe-probe", url.host == "app" else {
                throw ProbeError.invalid("Unexpected asset origin")
            }
            let file = root.appendingPathComponent(url.path).standardizedFileURL.resolvingSymlinksInPath()
            guard file.path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else {
                throw ProbeError.invalid("Asset escaped bundle")
            }
            let data = try Data(contentsOf: file)
            let types = ["html": "text/html", "js": "application/javascript", "css": "text/css", "ttf": "font/ttf", "json": "application/json"]
            task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": types[file.pathExtension] ?? "application/octet-stream"])!)
            task.didReceive(data)
            task.didFinish()
        } catch { task.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

enum ProbeError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

final class Probe: NSObject, NSApplicationDelegate, WKScriptMessageHandlerWithReply, WKNavigationDelegate, NSWindowDelegate {
    let assets: URL
    let output: URL
    let automated: Bool
    let logicOnly: Bool
    let workbenchTests: Bool
    let initialText: String
    var window: NSWindow!
    var webView: WKWebView!
    var watchdog: DispatchWorkItem?
    var text = ""
    var revision = 0
    var actionCommandCount = 0
    var codeVisionActions: [String] = []
    var gitLineActions: [String] = []
    var blameCommits: [String] = []
    var javaNavigationActions: [String] = []
    var debugRequests: [[String: Any]] = []
    var fixtureDocuments: [String: (text: String, revision: Int)] = [:]
    var semanticCount = 0
    var holdImagePaste = false
    var heldImagePaste: ((Any?, String?) -> Void)?
    var imagePasteWaiter: ((Any?, String?) -> Void)?
    var imagePasteNotification: String?
    var imagePasteNotificationWaiter: ((Any?, String?) -> Void)?
    let imagePasteResult: [String: Any] = ["text": "\n\n![fixture](assets/image.png)\n\n"]
    var holdResolve = false
    var heldResolve: ((Any?, String?) -> Void)?
    var resolveWaiter: ((Any?, String?) -> Void)?
    var holdFormat = false
    var heldFormat: ((Any?, String?) -> Void)?
    var formatWaiter: ((Any?, String?) -> Void)?
    let formatResult: [String: Any] = ["edits": [["range": ["startLineNumber": 1, "startColumn": 1,
        "endLineNumber": 1, "endColumn": 15], "text": "class Probe { }"]]]
    var holdSemantic = false
    var heldSemantic: ((Any?, String?) -> Void)?
    var semanticWaiter: ((Any?, String?) -> Void)?
    var completed = false
    var activity: NSObjectProtocol?
    let started = ProcessInfo.processInfo.systemUptime

    init(assets: URL, output: URL, automated: Bool, logicOnly: Bool, workbenchTests: Bool, text: String) {
        self.assets = assets; self.output = output; self.automated = automated; self.logicOnly = logicOnly; self.workbenchTests = workbenchTests; self.initialText = text
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(Assets(root: assets), forURLScheme: "lithe-probe")
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: workbenchTests ? "litheEditor" : "probe")
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        if automated, #available(macOS 14.0, *) {
            config.preferences.inactiveSchedulingPolicy = .none
        }
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Lithe Monaco Probe — isolated experiment"
        window.contentView = webView
        window.delegate = self
        if automated {
            // A hidden WebView may suspend rAF and even JS deadlines. Benchmark a visible surface.
            window.level = .floating
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Bounded Monaco integration probe")
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Integration watchdog uses a monotonic dispatch deadline, never a synchronizing sleep.
        let watchdog = DispatchWorkItem { [weak self] in self?.finish(error: "Host deadline exceeded") }
        self.watchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + (automated ? 120 : 600), execute: watchdog)
        webView.load(URLRequest(url: URL(string: "lithe-probe://app/index.html")!))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        do {
            guard message.frameInfo.isMainFrame,
                  message.frameInfo.securityOrigin.protocol == "lithe-probe",
                  message.frameInfo.securityOrigin.host == "app",
                  let body = message.body as? [String: Any], let type = body["type"] as? String else {
                throw ProbeError.invalid("Invalid bridge source or message")
            }
            switch type {
            case "javaNavigation":
                replyHandler(["markers": body["id"] as? String == "navigation" ? [
                    ["id": "super", "line": 1, "direction": "up"],
                    ["id": "implementations", "line": 1, "direction": "down"]
                ] : []], nil)
            case "javaNavigationAction":
                javaNavigationActions.append(body["marker"] as? String ?? "")
                replyHandler(["ok": true], nil)
            case "javaNavigationActions": replyHandler(["markers": javaNavigationActions], nil)
            case "blameCommit":
                blameCommits.append(body["commit"] as? String ?? "")
                replyHandler(["ok": true], nil)
            case "blameCommits": replyHandler(["commits": blameCommits], nil)
            case "gitLineAction":
                gitLineActions.append(body["action"] as? String ?? "")
                replyHandler(["ok": true], nil)
            case "gitLineActions": replyHandler(["actions": gitLineActions], nil)
            case "codeVision":
                let hints: [[String: Any]] = body["id"] as? String == "vision" ? [
                    ["id": "symbol", "line": 1, "usageCount": 2, "implementationCount": 1, "authorName": "Fixture Author"]
                ] : []
                replyHandler(["hints": hints], nil)
            case "codeVisionAction":
                codeVisionActions.append(body["action"] as? String ?? "")
                replyHandler(["ok": true], nil)
            case "codeVisionActions": replyHandler(["actions": codeVisionActions], nil)
            case "focus", "cursor": replyHandler(["ok": true], nil)
            case "editorNotification":
                imagePasteNotification = body["message"] as? String
                imagePasteNotificationWaiter?(["message": imagePasteNotification ?? ""], nil)
                imagePasteNotificationWaiter = nil
                replyHandler(["ok": true], nil)
            case "prepareImagePaste":
                replyHandler(["maximumByteCount": 1024], nil)
            case "pasteImage":
                guard body["mimeType"] as? String == "image/png",
                      let encoded = body["base64"] as? String,
                      Data(base64Encoded: encoded) == Data("fixture".utf8) else {
                    throw ProbeError.invalid("Image paste did not preserve event snapshot bytes")
                }
                if holdImagePaste {
                    heldImagePaste = replyHandler
                    imagePasteWaiter?(["ok": true], nil); imagePasteWaiter = nil
                } else { replyHandler(imagePasteResult, nil) }
            case "holdImagePaste":
                holdImagePaste = true; imagePasteNotification = nil
                replyHandler(["ok": true], nil)
            case "awaitImagePaste":
                if heldImagePaste != nil { replyHandler(["ok": true], nil) }
                else { imagePasteWaiter = replyHandler }
            case "releaseImagePaste":
                holdImagePaste = false
                heldImagePaste?(imagePasteResult, nil); heldImagePaste = nil
                replyHandler(["ok": true], nil)
            case "awaitImagePasteNotification":
                if let imagePasteNotification { replyHandler(["message": imagePasteNotification], nil) }
                else { imagePasteNotificationWaiter = replyHandler }
            case "resetImagePaste":
                holdImagePaste = false
                heldImagePaste?(["cancelled": true], nil); heldImagePaste = nil
                imagePasteWaiter?(["cancelled": true], nil); imagePasteWaiter = nil
                imagePasteNotificationWaiter?(["cancelled": true], nil); imagePasteNotificationWaiter = nil
                replyHandler(["ok": true], nil)
            case "semantic":
                semanticCount += 1
                if holdSemantic {
                    heldSemantic = replyHandler
                    semanticWaiter?(["ok": true], nil); semanticWaiter = nil
                } else { replyHandler(semanticResult, nil) }
            case "semanticCount": replyHandler(["count": semanticCount], nil)
            case "holdSemantic": holdSemantic = true; replyHandler(["ok": true], nil)
            case "awaitSemantic":
                if heldSemantic != nil { replyHandler(["ok": true], nil) }
                else { semanticWaiter = replyHandler }
            case "releaseSemantic":
                holdSemantic = false
                heldSemantic?(semanticResult, nil); heldSemantic = nil
                replyHandler(["ok": true], nil)
            case "format":
                if holdFormat {
                    heldFormat = replyHandler
                    formatWaiter?(["ok": true], nil); formatWaiter = nil
                } else { replyHandler(formatResult, nil) }
            case "holdFormat": holdFormat = true; replyHandler(["ok": true], nil)
            case "awaitFormat":
                if heldFormat != nil { replyHandler(["ok": true], nil) }
                else { formatWaiter = replyHandler }
            case "releaseFormat":
                holdFormat = false
                heldFormat?(formatResult, nil); heldFormat = nil
                replyHandler(["ok": true], nil)
            case "rename":
                guard let name = body["newName"] as? String else { throw ProbeError.invalid("Missing rename") }
                replyHandler(["changes": try workspaceFixtureChanges(name: name)], nil)
            case "runToCursor":
                debugRequests.append(body)
                replyHandler(["ok": true], nil)
            case "debugRequests":
                replyHandler(["requests": debugRequests], nil)
            case "fixtureSnapshot":
                guard let id = body["id"] as? String, let fixture = fixtureDocuments[id] else { throw ProbeError.invalid("Missing fixture") }
                replyHandler(["text": fixture.text, "revision": fixture.revision, "commandCount": actionCommandCount], nil)
            case "codeActions":
                replyHandler(["list": "fixture-actions", "actions": [["index": 0, "title": "Fix workspace", "kind": "quickfix", "isPreferred": true]]], nil)
            case "resolveCodeAction":
                replyHandler(["changes": try workspaceFixtureChanges(name: "fixed"), "command": "fixture-command"], nil)
            case "executeCodeAction":
                guard body["command"] as? String == "fixture-command",
                      fixtureDocuments["rename-source"]?.text == "let fixed = 1",
                      fixtureDocuments["rename-target"]?.text == "print(fixed)",
                      body["revision"] as? Int == fixtureDocuments["rename-source"]?.revision else {
                    throw ProbeError.invalid("Command ran before workspace edits were synchronized")
                }
                actionCommandCount += 1
                replyHandler(["ok": true], nil)
            case "inlayHints":
                replyHandler(["hints": [["position": ["lineNumber": 1, "column": 5], "label": "value:", "kind": 2,
                    "tooltip": "Parameter name", "paddingLeft": false, "paddingRight": true,
                    "textEdits": [["range": ["startLineNumber": 1, "startColumn": 5, "endLineNumber": 1, "endColumn": 5], "text": "value: "]]]]], nil)
            case "hover": replyHandler(["contents": "Host hover"], nil)
            case "debugHover": replyHandler(["contents": "second = <value> [literal]"], nil)
            case "completion": replyHandler(["items": [
                ["label": "sampleMethod", "insertText": "sampleMethod(${1:value})$0", "kind": 2, "insertTextFormat": 2,
                 "sortText": "001", "filterText": "sample", "completionList": "fixture-list", "completionIndex": 0] as [String: Any]
            ]], nil)
            case "resolveCompletion":
                if holdResolve {
                    heldResolve = replyHandler
                    resolveWaiter?(["ok": true], nil); resolveWaiter = nil
                } else { replyHandler(resolveResult, nil) }
            case "holdResolve": holdResolve = true; replyHandler(["ok": true], nil)
            case "awaitResolve":
                if heldResolve != nil { replyHandler(["ok": true], nil) }
                else { resolveWaiter = replyHandler }
            case "releaseResolve":
                holdResolve = false
                heldResolve?(resolveResult, nil); heldResolve = nil
                replyHandler(["ok": true], nil)
            case "progress":
                print("Probe: \(body["name"] ?? "")")
                fflush(stdout)
                replyHandler(["ok": true], nil)
            case "ready":
                replyHandler(["automated": automated, "logicOnly": logicOnly, "text": initialText], nil)
            case "open":
                guard let incoming = body["text"] as? String else { throw ProbeError.invalid("Missing text") }
                if let id = body["id"] as? String {
                    fixtureDocuments[id] = (incoming, 0)
                    replyHandler(["revision": 0], nil); return
                }
                text = incoming; revision = 0
                replyHandler(["revision": revision], nil)
            case "edit":
                let fixtureID = body["id"] as? String
                let fixture = fixtureID.flatMap { fixtureDocuments[$0] }
                var text = fixture?.text ?? self.text
                var revision = fixture?.revision ?? self.revision
                guard body["baseRevision"] as? Int == revision,
                      let changes = body["changes"] as? [[String: Any]] else {
                    throw ProbeError.invalid("Stale or invalid edit")
                }
                // Validate and apply the whole batch on a copy before publishing anything.
                var next = text as NSString
                var upperBound = next.length
                for change in changes.sorted(by: { ($0["offset"] as? Int ?? -1) > ($1["offset"] as? Int ?? -1) }) {
                    guard let offset = change["offset"] as? Int, let length = change["length"] as? Int,
                          let replacement = change["text"] as? String,
                          offset >= 0, length >= 0, offset <= upperBound, length <= upperBound - offset else {
                        throw ProbeError.invalid("Invalid or overlapping UTF-16 edit")
                    }
                    next = next.replacingCharacters(in: NSRange(location: offset, length: length), with: replacement) as NSString
                    upperBound = offset
                }
                text = next as String; revision += 1
                if let fixtureID, fixture != nil { fixtureDocuments[fixtureID] = (text, revision) }
                else { self.text = text; self.revision = revision }
                replyHandler(["revision": revision], nil)
            case "save":
                guard body["revision"] as? Int == revision, body["expected"] as? String == text else {
                    throw ProbeError.invalid("Save barrier or native text mismatch")
                }
                let copy = output.appendingPathComponent("document-copy.java")
                try text.write(to: copy, atomically: true, encoding: .utf8)
                guard try String(contentsOf: copy, encoding: .utf8) == text else { throw ProbeError.invalid("Disk round trip mismatch") }
                replyHandler(["revision": revision], nil)
            case "complete":
                var report = body
                report["hostElapsedMs"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
                report["os"] = ProcessInfo.processInfo.operatingSystemVersionString
                report["displayMaximumFramesPerSecond"] = window.screen?.maximumFramesPerSecond ?? 0
                report["viewportWidth"] = webView.bounds.width
                report["viewportHeight"] = webView.bounds.height
                report["nativeBuild"] = "swiftc -O -swift-version 5"
                report["backgroundSchedulingDisabledForProbe"] = automated
                report["status"] = "passed"
                report["renderingValidated"] = !logicOnly
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("result.json"))
                completed = true
                replyHandler(["ok": true], nil)
                if logicOnly { DispatchQueue.main.async { self.finish(error: nil) }; return }
                webView.takeSnapshot(with: nil) { [weak self] image, error in
                    guard let self else { return }
                    do {
                        if let error { throw error }
                        guard let data = image?.tiffRepresentation,
                              let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else {
                            throw ProbeError.invalid("Snapshot unavailable")
                        }
                        try png.write(to: self.output.appendingPathComponent("editor.png"))
                        if self.automated { self.finish(error: nil) }
                    } catch { self.finish(error: "Snapshot failed: \(error)") }
                }
            case "failure":
                replyHandler(["ok": true], nil)
                finish(error: body["message"] as? String ?? "Unknown JavaScript failure")
            default: throw ProbeError.invalid("Unknown bridge message")
            }
        } catch { replyHandler(nil, error.localizedDescription) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url?.absoluteString == "lithe-probe://app/index.html" ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(error: error.localizedDescription) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error: error.localizedDescription) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(error: "WebContent process terminated") }
    private var semanticResult: [String: Any] {
        ["tokenTypes": ["class"], "tokenModifiers": [], "tokens": [["line": 0, "startChar": 6, "length": 5, "tokenType": 0, "tokenModifiers": 0]]]
    }

    private var resolveResult: [String: Any] {
        ["item": [
                "label": "sampleMethod", "insertText": "sampleMethod(${1:value})$0", "kind": 2,
                "insertTextFormat": 2, "documentation": "Resolved documentation",
                "additionalTextEdits": [["range": ["startLineNumber": 1, "startColumn": 1,
                    "endLineNumber": 1, "endColumn": 1], "text": "import sample\n"]]
            ] as [String: Any]]
    }

    private func workspaceFixtureChanges(name: String) throws -> [[String: Any]] {
        let targets: [(String, Int, Int)] = [("rename-source", 5, 10), ("rename-target", 7, 12)]
        let changes: [[String: Any]] = try targets.map { id, start, end in
            guard let fixture = fixtureDocuments[id] else { throw ProbeError.invalid("Missing rename fixture") }
            return ["id": id, "text": fixture.text, "revision": fixture.revision, "language": "python", "readonly": false,
                    "edits": [["range": ["startLineNumber": 1, "startColumn": start, "endLineNumber": 1, "endColumn": end], "text": name]]]
        }
        return changes
    }

    func windowWillClose(_ notification: Notification) { finish(error: automated && !completed ? "Closed before completion" : nil) }

    func finish(error: String?) {
        heldResolve?(nil, "Probe finished"); heldResolve = nil
        resolveWaiter?(nil, "Probe finished"); resolveWaiter = nil
        heldFormat?(nil, "Probe finished"); heldFormat = nil
        formatWaiter?(nil, "Probe finished"); formatWaiter = nil
        heldSemantic?(nil, "Probe finished"); heldSemantic = nil
        semanticWaiter?(nil, "Probe finished"); semanticWaiter = nil
        watchdog?.cancel(); watchdog = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: workbenchTests ? "litheEditor" : "probe", contentWorld: .page)
        webView?.navigationDelegate = nil
        window?.delegate = nil
        window?.orderOut(nil)
        window?.contentView = nil
        webView = nil
        if let error {
            do {
                try JSONSerialization.data(withJSONObject: ["status": "failed", "error": error], options: [.prettyPrinted]).write(to: output.appendingPathComponent("result.json"))
            } catch { fputs("Cannot write failure report: \(error)\n", stderr) }
            fputs("Monaco probe failed: \(error)\n", stderr)
        }
        exit(error == nil ? 0 : 1)
    }
}

let args = CommandLine.arguments
guard args.count >= 3 else { fatalError("Usage: LitheMonacoProbe assets output [--manual [file]]") }
let manual = args.count > 3 && args[3] == "--manual"
let initialText: String
do {
    initialText = manual && args.count > 4 ? try String(contentsOfFile: args[4], encoding: .utf8) : (0..<10_000).map { "public int method\($0)() { return \($0); } // 中文 日本語 😀" }.joined(separator: "\n")
} catch { fputs("Cannot read input: \(error)\n", stderr); exit(1) }
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let probe = Probe(assets: URL(fileURLWithPath: args[1]), output: URL(fileURLWithPath: args[2]), automated: !manual, logicOnly: args.contains("--logic-only"), workbenchTests: args.contains("--workbench-tests"), text: initialText)
app.delegate = probe
app.run()
