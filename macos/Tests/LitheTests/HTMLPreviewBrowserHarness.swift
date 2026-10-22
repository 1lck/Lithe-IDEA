import AppKit
import Combine
import Foundation
import WebKit
@testable import Lithe

/// Answers page dialogs without showing any, and records what the page asked.
@MainActor
final class RecordingDialogs: ObservableObject, HTMLPreviewDialogPresenting {
    var alerts: [String] = []
    var confirms: [String] = []
    var prompts: [(message: String, defaultText: String?)] = []
    var sources: [String] = []
    var confirmAnswer = true
    var promptAnswer: String? = "Ada"
    @Published var downloadNames: [String] = []
    var downloadDestination: URL?
    var mediaCaptureRequests: [(devices: HTMLPreviewMediaDevices, source: String)] = []
    var mediaCaptureAnswer = true
    var printOperations: [NSPrintOperation] = []

    func presentAlert(message: String, source: String, in window: NSWindow?, completion: @escaping () -> Void) {
        alerts.append(message)
        sources.append(source)
        completion()
    }

    func presentConfirm(message: String, source: String, in window: NSWindow?, completion: @escaping (Bool) -> Void) {
        confirms.append(message)
        completion(confirmAnswer)
    }

    func presentPrompt(
        message: String,
        defaultText: String?,
        source: String,
        in window: NSWindow?,
        completion: @escaping (String?) -> Void
    ) {
        prompts.append((message, defaultText))
        completion(promptAnswer)
    }

    func chooseFiles(
        allowsMultiple: Bool,
        allowsDirectories: Bool,
        in window: NSWindow?,
        completion: @escaping ([URL]?) -> Void
    ) {
        completion(nil)
    }

    func chooseDownloadDestination(suggestedFilename: String, in window: NSWindow?, completion: @escaping (URL?) -> Void) {
        downloadNames.append(suggestedFilename)
        completion(downloadDestination)
    }

    func confirmMediaCapture(
        devices: HTMLPreviewMediaDevices,
        source: String,
        in window: NSWindow?,
        completion: @escaping (Bool) -> Void
    ) {
        mediaCaptureRequests.append((devices, source))
        completion(mediaCaptureAnswer)
    }

    /// Print operations are recorded, never run: a print panel would wait for a person.
    func runPrintOperation(_ operation: NSPrintOperation, in window: NSWindow?) {
        printOperations.append(operation)
    }
}

/// Resumes a continuation exactly once, from the observation or the deadline,
/// both of which run on the main thread.
final class WaitGate: @unchecked Sendable {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var observation: AnyCancellable?

    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }

    func hold(_ observation: AnyCancellable) {
        guard continuation != nil else { return observation.cancel() }
        self.observation = observation
    }

    func finish(_ value: Bool) {
        guard let pending = continuation else { return }
        continuation = nil
        observation?.cancel()
        observation = nil
        pending.resume(returning: value)
    }
}

/// A controller whose web view sits in a real window, so layout, scrolling and
/// dialogs behave as they do in the app.
@MainActor
final class BrowserHarness {
    let fixture: HTMLPreviewFixture
    let dialogs = RecordingDialogs()
    let controller: HTMLPreviewBrowserController
    let window: NSWindow

    init(
        files: [String: String],
        mediaUsageDescriptions: @escaping () -> [String: Any]? = { Bundle.main.infoDictionary },
        configure: (WKWebViewConfiguration) -> Void = { _ in }
    ) throws {
        fixture = try HTMLPreviewFixture(files: files)
        controller = HTMLPreviewBrowserController(
            dialogs: dialogs,
            mediaUsageDescriptions: mediaUsageDescriptions,
            configure: configure
        )
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = controller.containerView
        window.orderFront(nil)
    }

    func tearDown() {
        controller.webView.stopLoading()
        window.contentView = nil
        window.close()
    }

    var webView: WKWebView { controller.webView }

    func show(_ html: String, document: String = "site/page.html") {
        controller.update(.init(html: html, documentURL: fixture.url(document), workspaceURL: fixture.workspace))
    }

    /// Waits for `isSatisfied`, re-checking after every change WebKit, the
    /// controller or its find and capture models publish. Returns false at the
    /// deadline instead of hanging.
    func wait(timeout: DispatchTimeInterval = .seconds(15), until isSatisfied: @escaping @MainActor () -> Bool) async -> Bool {
        if isSatisfied() { return true }
        let webView = webView
        let controller = controller
        let dialogs = dialogs
        return await withCheckedContinuation { continuation in
            let gate = WaitGate(continuation)
            let changes = Publishers.MergeMany(
                webView.publisher(for: \.title).map { _ in () }.eraseToAnyPublisher(),
                webView.publisher(for: \.url).map { _ in () }.eraseToAnyPublisher(),
                webView.publisher(for: \.isLoading).map { _ in () }.eraseToAnyPublisher(),
                controller.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                controller.find.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                controller.capture.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                dialogs.objectWillChange.map { _ in () }.eraseToAnyPublisher()
            )
            gate.hold(changes.sink { _ in
                Task { @MainActor in
                    if isSatisfied() { gate.finish(true) }
                }
            })
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { gate.finish(false) }
        }
    }

    func waitForTitle(_ title: String) async -> Bool {
        await wait { [webView] in webView.title == title }
    }

    func evaluate(_ script: String) async throws -> Any? {
        try await webView.evaluateJavaScript(script)
    }

    /// Runs a function body that may `await`, in the page's own world.
    func evaluateAsync(_ body: String, arguments: [String: Any] = [:]) async throws -> Any? {
        try await webView.callAsyncJavaScript(body, arguments: arguments, contentWorld: .page)
    }
}

extension BrowserHarness {
    /// A key press for a shortcut, addressed to the harness window the way AppKit offers it to a view.
    func keyEvent(_ characters: String, modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 0
        )!
    }
}
