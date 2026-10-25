import AppKit
import Testing
import WebKit
@testable import Lithe

struct HTMLPreviewCaptureStateTests {
    @Test func captureStatesMapToTheIndicatorStates() {
        #expect(HTMLPreviewCaptureState(.none) == .inactive)
        #expect(HTMLPreviewCaptureState(.active) == .active)
        #expect(HTMLPreviewCaptureState(.muted) == .muted)
    }
}

@MainActor
struct HTMLPreviewMediaCaptureFlowTests {
    private func makeController(
        _ dialogs: RecordingDialogs,
        usage: [String: Any]? = MockCapture.usageDescriptions
    ) -> HTMLPreviewBrowserController {
        HTMLPreviewBrowserController(dialogs: dialogs, mediaUsageDescriptions: { usage })
    }

    @Test func anAnswerOfYesGrantsAfterExactlyOneQuestionNamingThePage() {
        let dialogs = RecordingDialogs()
        let controller = makeController(dialogs)
        var decisions: [WKPermissionDecision] = []

        controller.requestMediaCapture(devices: [.camera, .microphone], source: "demo.html") { decisions.append($0) }

        #expect(decisions == [.grant])
        #expect(dialogs.mediaCaptureRequests.count == 1)
        #expect(dialogs.mediaCaptureRequests.first?.devices == [.camera, .microphone])
        #expect(dialogs.mediaCaptureRequests.first?.requester == .page(name: "demo.html"))
        #expect(dialogs.alerts.isEmpty)
    }

    @Test func anAnswerOfNoDeniesTheRequest() {
        let dialogs = RecordingDialogs()
        dialogs.mediaCaptureAnswer = false
        let controller = makeController(dialogs)
        var decisions: [WKPermissionDecision] = []

        controller.requestMediaCapture(devices: .microphone, source: "demo.html") { decisions.append($0) }

        #expect(decisions == [.deny])
        #expect(dialogs.mediaCaptureRequests.count == 1)
    }

    @Test func nothingIsRememberedSoEveryRequestAsksAgain() {
        let dialogs = RecordingDialogs()
        let controller = makeController(dialogs)
        var decisions: [WKPermissionDecision] = []

        controller.requestMediaCapture(devices: .camera, source: "demo.html") { decisions.append($0) }
        dialogs.mediaCaptureAnswer = false
        controller.requestMediaCapture(devices: .camera, source: "demo.html") { decisions.append($0) }
        dialogs.mediaCaptureAnswer = true
        controller.requestMediaCapture(devices: .camera, source: "demo.html") { decisions.append($0) }

        #expect(decisions == [.grant, .deny, .grant])
        #expect(dialogs.mediaCaptureRequests.count == 3)
    }

    @Test func withoutUsageDescriptionsTheRequestIsDeniedAndTheUserToldOnceWithoutAsking() {
        let dialogs = RecordingDialogs()
        let controller = makeController(dialogs, usage: [:])
        var decisions: [WKPermissionDecision] = []

        controller.requestMediaCapture(devices: .camera, source: "demo.html") { decisions.append($0) }

        #expect(decisions == [.deny])
        #expect(dialogs.mediaCaptureRequests.isEmpty)
        #expect(dialogs.alerts.count == 1)
    }

    @Test func aRequestNamingNoDeviceIsDeniedQuietly() {
        let dialogs = RecordingDialogs()
        let controller = makeController(dialogs)
        var decisions: [WKPermissionDecision] = []

        controller.requestMediaCapture(devices: [], source: "demo.html") { decisions.append($0) }

        #expect(decisions == [.deny])
        #expect(dialogs.mediaCaptureRequests.isEmpty)
        #expect(dialogs.alerts.isEmpty)
    }

    @Test func theIndicatorModelStartsWithNoDeviceInUse() {
        let controller = makeController(RecordingDialogs())
        #expect(controller.capture.camera == .inactive)
        #expect(controller.capture.microphone == .inactive)
        #expect(!controller.capture.isCapturing)
    }
}

extension MockCaptureTests {
    /// End to end with WebKit's mock cameras and microphones.
    /// Each page makes one `getUserMedia` call; a second one on the same page is not reliable in WebKit's mock devices.
    @MainActor
    @Suite struct HTMLPreviewCapture {
        private func makeHarness(answer: Bool = true) async throws -> BrowserHarness {
            let harness = try BrowserHarness(
                files: ["site/page.html": "disk"],
                mediaUsageDescriptions: { MockCapture.usageDescriptions },
                configure: MockCapture.configure
            )
            harness.dialogs.mediaCaptureAnswer = answer
            harness.show("<!doctype html><title>ready</title>")
            #expect(await harness.waitForTitle("ready"), "Title was \(harness.webView.title ?? "nil")")
            return harness
        }

        /// Starts the request without waiting for it, so a page that never answers cannot hang the test.
        private func request(_ constraints: String, in harness: BrowserHarness) async throws {
            _ = try await harness.evaluate("""
                navigator.mediaDevices.getUserMedia(\(constraints)).then(
                  stream => { window.stream = stream; document.title = 'granted'; },
                  error => { document.title = 'denied:' + error.name; });
                0
                """)
        }

        @Test(.enabled(if: MockCapture.isAvailable))
        func aGrantedCameraShowsInTheIndicatorAndCanBeMutedAndStopped() async throws {
            let harness = try await makeHarness()
            defer { harness.tearDown() }
            let capture = harness.controller.capture

            try await request("{ video: true }", in: harness)
            #expect(await harness.waitForTitle("granted"), "Title was \(harness.webView.title ?? "nil")")
            #expect(harness.dialogs.mediaCaptureRequests.count == 1)
            #expect(harness.dialogs.mediaCaptureRequests.first?.devices == .camera)
            #expect(harness.dialogs.mediaCaptureRequests.first?.requester == .page(name: "page.html"))
            #expect(await harness.wait { capture.camera == .active })
            #expect(capture.microphone == .inactive)
            #expect(capture.isCapturing)

            capture.setCameraMuted(true)
            #expect(await harness.wait { capture.camera == .muted })
            capture.setCameraMuted(false)
            #expect(await harness.wait { capture.camera == .active })

            // WebKit lowers the state of the last device only about three seconds after it stops,
            // so the page's own track is what shows the stop at once.
            _ = try await harness.evaluate("window.stream.getVideoTracks()[0].addEventListener('ended', () => { document.title = 'ended'; }); 0")
            capture.stopCamera()
            #expect(await harness.waitForTitle("ended"), "Title was \(harness.webView.title ?? "nil")")
        }

        @Test(.enabled(if: MockCapture.isAvailable))
        func cameraAndMicrophoneAreAskedTogetherAndControlledSeparately() async throws {
            let harness = try await makeHarness()
            defer { harness.tearDown() }
            let capture = harness.controller.capture

            try await request("{ video: true, audio: true }", in: harness)
            #expect(await harness.waitForTitle("granted"), "Title was \(harness.webView.title ?? "nil")")
            #expect(harness.dialogs.mediaCaptureRequests.count == 1)
            #expect(harness.dialogs.mediaCaptureRequests.first?.devices == [.camera, .microphone])
            let bothActive = await harness.wait { capture.camera == .active && capture.microphone == .active }
            #expect(bothActive, "Camera \(capture.camera), microphone \(capture.microphone)")

            capture.setMicrophoneMuted(true)
            #expect(await harness.wait { capture.microphone == .muted })
            #expect(capture.camera == .active)
            capture.setMicrophoneMuted(false)
            #expect(await harness.wait { capture.microphone == .active })

            // The camera is still in use, so the stopped microphone leaves the indicator at once.
            capture.stopMicrophone()
            #expect(await harness.wait { capture.microphone == .inactive })
            #expect(capture.camera == .active)
            #expect(capture.isCapturing)
        }

        @Test(.enabled(if: MockCapture.isAvailable))
        func aRefusedRequestReachesThePageAsNotAllowedAndShowsNothing() async throws {
            let harness = try await makeHarness(answer: false)
            defer { harness.tearDown() }

            try await request("{ video: true }", in: harness)
            #expect(await harness.waitForTitle("denied:NotAllowedError"), "Title was \(harness.webView.title ?? "nil")")
            #expect(harness.dialogs.mediaCaptureRequests.count == 1)
            #expect(!harness.controller.capture.isCapturing)
        }

        @Test(.enabled(if: MockCapture.isAvailable))
        func pagesAreNotOfferedScreenSharing() async throws {
            let harness = try await makeHarness()
            defer { harness.tearDown() }

            let kind = try await harness.evaluate("typeof navigator.mediaDevices.getDisplayMedia") as? String
            #expect(kind == "undefined")
        }
    }
}
