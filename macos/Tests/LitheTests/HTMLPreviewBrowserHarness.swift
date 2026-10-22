import AppKit
import Combine
import Foundation
import Testing
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
    var mediaCaptureRequests: [(devices: WebMediaDevices, requester: WebMediaCaptureRequester)] = []
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
        devices: WebMediaDevices,
        requester: WebMediaCaptureRequester,
        in window: NSWindow?,
        completion: @escaping (Bool) -> Void
    ) {
        mediaCaptureRequests.append((devices, requester))
        completion(mediaCaptureAnswer)
    }

    /// Print operations are recorded, never run: a print panel would wait for a person.
    func runPrintOperation(_ operation: NSPrintOperation, in window: NSWindow?) {
        printOperations.append(operation)
    }
}

/// Every end-to-end capture test, wherever it lives, runs one at a time: two pages
/// that capture side by side in one process mute each other.
@MainActor
@Suite("Mock capture", .serialized)
struct MockCaptureTests {}

/// WebKit's mock cameras and microphones: nothing touches real hardware or asks the system for access.
enum MockCapture {
    /// Info.plist entries of an app that may use both devices.
    static var usageDescriptions: [String: Any] {
        [
            WebMediaAccess.cameraUsageKey: "Lithe shows the camera in a page you preview.",
            WebMediaAccess.microphoneUsageKey: "Lithe records sound for a page you preview."
        ]
    }

    /// The private preferences that give a page mock devices; absent on a WebKit that dropped them.
    private static let preferences: [(selector: String, key: String, value: Bool)] = [
        ("_setMediaDevicesEnabled:", "mediaDevicesEnabled", true),
        ("_setMockCaptureDevicesEnabled:", "mockCaptureDevicesEnabled", true),
        ("_setGetUserMediaRequiresFocus:", "getUserMediaRequiresFocus", false)
    ]

    static let isAvailable = preferences.allSatisfy {
        class_respondsToSelector(WKPreferences.self, NSSelectorFromString($0.selector))
    }

    static func configure(_ configuration: WKWebViewConfiguration) {
        for preference in preferences {
            configuration.preferences.setValue(preference.value, forKey: preference.key)
        }
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

/// The changes of a web view that a test waits on.
@MainActor
func webViewChanges(_ webView: WKWebView) -> [AnyPublisher<Void, Never>] {
    [
        webView.publisher(for: \.title).map { _ in () }.eraseToAnyPublisher(),
        webView.publisher(for: \.url).map { _ in () }.eraseToAnyPublisher(),
        webView.publisher(for: \.isLoading).map { _ in () }.eraseToAnyPublisher(),
        webView.publisher(for: \.cameraCaptureState).map { _ in () }.eraseToAnyPublisher(),
        webView.publisher(for: \.microphoneCaptureState).map { _ in () }.eraseToAnyPublisher()
    ]
}

/// Waits for `isSatisfied`, re-checking after every change `changes` publishes.
/// Returns false at the deadline instead of hanging.
@MainActor
func waitForChanges(
    _ changes: [AnyPublisher<Void, Never>],
    timeout: DispatchTimeInterval = .seconds(15),
    until isSatisfied: @escaping @MainActor () -> Bool
) async -> Bool {
    if isSatisfied() { return true }
    return await withCheckedContinuation { continuation in
        let gate = WaitGate(continuation)
        gate.hold(Publishers.MergeMany(changes).sink { _ in
            Task { @MainActor in
                if isSatisfied() { gate.finish(true) }
            }
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { gate.finish(false) }
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
        let controller = controller
        let dialogs = dialogs
        return await waitForChanges(
            webViewChanges(webView) + [
                controller.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                controller.find.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                controller.capture.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                dialogs.objectWillChange.map { _ in () }.eraseToAnyPublisher()
            ],
            timeout: timeout,
            until: isSatisfied
        )
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
