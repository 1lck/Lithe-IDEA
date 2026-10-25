import AppKit
import Combine
import Foundation
import Testing
import WebKit
@testable import Lithe

/// Answers the camera and microphone question the way a test says, at once or only
/// when the test lets it, and records who asked.
@MainActor
private final class RecordingConfirmer: WebMediaCaptureConfirming {
    /// nil keeps the question open until `answerOpenQuestion`.
    var answer: Bool? = true
    private(set) var requests: [(devices: WebMediaDevices, requester: WebMediaCaptureRequester)] = []
    private var open: [(Bool) -> Void] = []
    let changes = PassthroughSubject<Void, Never>()

    func confirmMediaCapture(
        devices: WebMediaDevices,
        requester: WebMediaCaptureRequester,
        in window: NSWindow?,
        completion: @escaping (Bool) -> Void
    ) {
        requests.append((devices, requester))
        if let answer { completion(answer) } else { open.append(completion) }
        changes.send()
    }

    func answerOpenQuestion(_ yes: Bool) {
        open.removeFirst()(yes)
    }
}

/// A host with nothing to offer: these pages only ask for the camera and microphone.
@MainActor
private final class IdleHost: PluginWebBridgeHost {
    var pluginWebWorkspaceURL: URL?
    func pluginWebBuildSystems(activate: Bool) async -> (any PluginWebBuildAccess)? { nil }
    func pluginWebShowBuildOutput() {}
    func pluginWebOpenFile(_ url: URL, line: Int?, column: Int?) -> Bool { false }
    func pluginWebConfirmProcessStart(_ consent: PluginWebProcessConsent) async -> Bool { false }
    func pluginWebChooseFile(_ request: PluginWebFileRequest) async -> URL? { nil }
}

/// A plugin's own page, loaded through the package scheme into a window of its own.
@MainActor
private final class PluginPageFixture {
    static let pluginID = "dev.example.web"
    let confirmer = RecordingConfirmer()
    let page: MacPluginWebPage
    let hostWindow: NSWindow
    private let root: URL

    init(usage: [String: Any]? = MockCapture.usageDescriptions, attached: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-plugin-capture-\(UUID().uuidString)")
        let ui = root.appendingPathComponent("ui")
        try FileManager.default.createDirectory(at: ui, withIntermediateDirectories: true)
        try Data("<!doctype html><html><head><meta charset=\"utf-8\"><title>ready</title></head><body></body></html>".utf8)
            .write(to: ui.appendingPathComponent("index.html"))
        let window = PluginWebWindow(
            pluginID: Self.pluginID, pluginName: "Fixture", windowID: Self.pluginID + ".window",
            entry: "ui/index.html", packageURL: root, buildSystemIDs: [], isInspectable: false
        )
        page = MacPluginWebPage(
            window: window,
            host: IdleHost(),
            stateStore: MemoryPluginWebStateStore(),
            theme: MacPluginWebTheme(colorTheme: .lithe, isDark: false, codeFontFamily: "Menlo", codeFontSize: 13),
            mediaUsageDescriptions: { usage },
            mediaConfirmer: confirmer,
            configure: MockCapture.configure
        )
        hostWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false
        )
        hostWindow.isReleasedWhenClosed = false
        if attached { attach() }
    }

    var webView: WKWebView { page.webView! }

    func attach() {
        hostWindow.contentView = webView
        hostWindow.orderFront(nil)
    }

    /// The page leaves its window the way hiding the tool window takes it off screen.
    func detach() {
        hostWindow.contentView = nil
    }

    func tearDown() {
        hostWindow.contentView = nil
        page.close()
        hostWindow.close()
        try? FileManager.default.removeItem(at: root)
    }

    /// Waits for `isSatisfied`, re-checking after every change of the web view and the confirmer.
    func wait(until isSatisfied: @escaping @MainActor () -> Bool) async -> Bool {
        await waitForChanges(webViewChanges(webView) + [confirmer.changes.eraseToAnyPublisher()], until: isSatisfied)
    }

    func waitForTitle(_ title: String) async -> Bool {
        await wait { [webView] in webView.title == title }
    }

    /// Starts the request without waiting for it, so a page that never answers cannot hang the test.
    /// `watchingEnd` makes the page title `ended` once the device stops, which is how a test sees
    /// a stop at once: WebKit lowers the capture state of the last device only about three seconds later.
    func request(_ constraints: String, watchingEnd: Bool = false) async throws {
        let onEnded = watchingEnd
            ? "stream.getTracks()[0].addEventListener('ended', () => { document.title = 'ended'; });"
            : ""
        _ = try await webView.evaluateJavaScript("""
            navigator.mediaDevices.getUserMedia(\(constraints)).then(
              stream => { window.stream = stream; \(onEnded) document.title = 'granted'; },
              error => { document.title = 'denied:' + error.name; });
            0
            """)
    }
}

@MainActor
struct PluginMediaCaptureDecisionTests {
    @Test func aRequestFromAnyOtherFrameIsRefusedWithoutAQuestion() throws {
        let fixture = try PluginPageFixture()
        defer { fixture.tearDown() }
        var decisions: [WKPermissionDecision] = []

        fixture.page.requestMediaCapture(devices: .camera, fromOwnPage: false) { decisions.append($0) }

        #expect(decisions == [.deny])
        #expect(fixture.confirmer.requests.isEmpty)
    }

    @Test func aPageOnScreenAsksTheUserNamingThePluginAndItsID() throws {
        let fixture = try PluginPageFixture()
        defer { fixture.tearDown() }
        var decisions: [WKPermissionDecision] = []

        fixture.page.requestMediaCapture(devices: [.camera, .microphone], fromOwnPage: true) { decisions.append($0) }

        #expect(decisions == [.grant])
        #expect(fixture.confirmer.requests.count == 1)
        #expect(fixture.confirmer.requests.first?.devices == [.camera, .microphone])
        #expect(fixture.confirmer.requests.first?.requester == .plugin(name: "Fixture", id: PluginPageFixture.pluginID))
    }

    @Test func aPageThatIsNotInAWindowIsRefusedWithoutAQuestion() throws {
        let fixture = try PluginPageFixture(attached: false)
        defer { fixture.tearDown() }
        _ = fixture.webView
        var decisions: [WKPermissionDecision] = []

        fixture.page.requestMediaCapture(devices: .camera, fromOwnPage: true) { decisions.append($0) }

        #expect(decisions == [.deny])
        #expect(fixture.confirmer.requests.isEmpty)
    }

    @Test func aClosedPageIsRefusedWithoutAQuestion() throws {
        let fixture = try PluginPageFixture()
        defer { fixture.tearDown() }
        var decisions: [WKPermissionDecision] = []

        fixture.page.close()
        fixture.page.requestMediaCapture(devices: .camera, fromOwnPage: true) { decisions.append($0) }

        #expect(decisions == [.deny])
        #expect(fixture.confirmer.requests.isEmpty)
    }

    @Test func withoutUsageDescriptionsAPluginIsRefusedWithoutAQuestion() throws {
        let fixture = try PluginPageFixture(usage: [:])
        defer { fixture.tearDown() }
        var decisions: [WKPermissionDecision] = []

        fixture.page.requestMediaCapture(devices: .microphone, fromOwnPage: true) { decisions.append($0) }

        #expect(decisions == [.deny])
        #expect(fixture.confirmer.requests.isEmpty)
    }

    @Test func aYesGivenAfterThePageWasHiddenDoesNotGrantAnything() throws {
        let fixture = try PluginPageFixture()
        defer { fixture.tearDown() }
        fixture.confirmer.answer = nil
        var decisions: [WKPermissionDecision] = []

        fixture.page.requestMediaCapture(devices: .camera, fromOwnPage: true) { decisions.append($0) }
        #expect(decisions.isEmpty)
        fixture.detach()
        fixture.confirmer.answerOpenQuestion(true)

        #expect(decisions == [.deny])
    }

    @Test func aYesGivenAfterThePageWasClosedDoesNotGrantAnything() throws {
        let fixture = try PluginPageFixture()
        defer { fixture.tearDown() }
        fixture.confirmer.answer = nil
        var decisions: [WKPermissionDecision] = []

        fixture.page.requestMediaCapture(devices: .camera, fromOwnPage: true) { decisions.append($0) }
        fixture.page.close()
        fixture.confirmer.answerOpenQuestion(true)

        #expect(decisions == [.deny])
    }
}

extension MockCaptureTests {
    /// End to end with WebKit's mock cameras and microphones, through the real package scheme.
    @MainActor
    @Suite struct PluginPage {
        private func makeFixture(
            answer: Bool? = true,
            usage: [String: Any]? = MockCapture.usageDescriptions,
            attached: Bool = true
        ) async throws -> PluginPageFixture {
            let fixture = try PluginPageFixture(usage: usage, attached: attached)
            fixture.confirmer.answer = answer
            #expect(await fixture.waitForTitle("ready"), "Title was \(fixture.webView.title ?? "nil")")
            return fixture
        }

        @Test(.enabled(if: MockCapture.isAvailable))
        func aPluginPageSeesTheCameraOnlyAfterTheUserSaysYes() async throws {
            let fixture = try await makeFixture()
            defer { fixture.tearDown() }

            try await fixture.request("{ video: true }")
            #expect(await fixture.waitForTitle("granted"), "Title was \(fixture.webView.title ?? "nil")")
            #expect(fixture.confirmer.requests.count == 1)
            #expect(fixture.confirmer.requests.first?.devices == .camera)
            #expect(fixture.confirmer.requests.first?.requester == .plugin(name: "Fixture", id: PluginPageFixture.pluginID))
            #expect(await fixture.wait { fixture.webView.cameraCaptureState == .active })
        }

        @Test(.enabled(if: MockCapture.isAvailable))
        func aPluginPageThatIsRefusedIsToldNotAllowed() async throws {
            let fixture = try await makeFixture(answer: false)
            defer { fixture.tearDown() }

            try await fixture.request("{ video: true, audio: true }")
            #expect(await fixture.waitForTitle("denied:NotAllowedError"), "Title was \(fixture.webView.title ?? "nil")")
            #expect(fixture.confirmer.requests.count == 1)
            #expect(fixture.webView.cameraCaptureState == .none)
            #expect(fixture.webView.microphoneCaptureState == .none)
        }

        @Test(.enabled(if: MockCapture.isAvailable))
        func aPluginPageIsRefusedWithoutAQuestionWhenTheAppCannotOfferTheDevice() async throws {
            let fixture = try await makeFixture(usage: [:])
            defer { fixture.tearDown() }

            try await fixture.request("{ audio: true }")
            #expect(await fixture.waitForTitle("denied:NotAllowedError"), "Title was \(fixture.webView.title ?? "nil")")
            #expect(fixture.confirmer.requests.isEmpty)
        }

        @Test(.enabled(if: MockCapture.isAvailable))
        func aDeviceThatStartsAfterTheUserSaidYesWhileThePageWasHiddenIsStopped() async throws {
            let fixture = try await makeFixture(answer: nil)
            defer { fixture.tearDown() }

            try await fixture.request("{ video: true }", watchingEnd: true)
            #expect(await fixture.wait { fixture.confirmer.requests.count == 1 })
            // WebKit starts the device only once the answer reaches it, and the page can leave its
            // window before that: hiding then finds no capture to stop.
            fixture.confirmer.answerOpenQuestion(true)
            fixture.detach()

            #expect(await fixture.waitForTitle("ended"), "Title was \(fixture.webView.title ?? "nil")")
        }

        @Test(.enabled(if: MockCapture.isAvailable))
        func hidingThePluginPageEndsTheCaptureInProgress() async throws {
            let fixture = try await makeFixture()
            defer { fixture.tearDown() }

            try await fixture.request("{ video: true }")
            #expect(await fixture.waitForTitle("granted"), "Title was \(fixture.webView.title ?? "nil")")
            #expect(await fixture.wait { fixture.webView.cameraCaptureState == .active })
            // WebKit lowers the state of the last device only about three seconds after it stops,
            // so the page's own track is what shows the stop at once.
            _ = try await fixture.webView.evaluateJavaScript(
                "window.stream.getVideoTracks()[0].addEventListener('ended', () => { document.title = 'ended'; }); 0"
            )

            fixture.detach()

            #expect(await fixture.waitForTitle("ended"), "Title was \(fixture.webView.title ?? "nil")")
        }

        @Test(.enabled(if: MockCapture.isAvailable))
        func aYesGivenAfterThePluginPageWasHiddenReachesThePageAsNotAllowed() async throws {
            let fixture = try await makeFixture(answer: nil)
            defer { fixture.tearDown() }

            try await fixture.request("{ video: true }")
            #expect(await fixture.wait { fixture.confirmer.requests.count == 1 })
            #expect(fixture.webView.title == "ready")
            fixture.detach()
            fixture.confirmer.answerOpenQuestion(true)

            #expect(await fixture.waitForTitle("denied:NotAllowedError"), "Title was \(fixture.webView.title ?? "nil")")
            #expect(fixture.webView.cameraCaptureState == .none)
        }
    }
}
