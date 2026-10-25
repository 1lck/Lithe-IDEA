import AppKit
import Foundation
import Testing
import WebKit
@testable import Lithe

struct WebMediaAccessTests {
    @Test func captureTypesMapToTheDevicesTheyNeed() {
        #expect(WebMediaDevices(.camera) == .camera)
        #expect(WebMediaDevices(.microphone) == .microphone)
        #expect(WebMediaDevices(.cameraAndMicrophone) == [.camera, .microphone])
    }

    @Test func aRequestIsAskedOnlyWhenEveryRequestedDeviceHasAUsageDescription() {
        let both = MockCapture.usageDescriptions
        #expect(WebMediaAccess.outcome(for: .camera, usageDescriptions: both) == .ask)
        #expect(WebMediaAccess.outcome(for: .microphone, usageDescriptions: both) == .ask)
        #expect(WebMediaAccess.outcome(for: [.camera, .microphone], usageDescriptions: both) == .ask)

        let cameraOnly: [String: Any] = [WebMediaAccess.cameraUsageKey: "Camera"]
        #expect(WebMediaAccess.outcome(for: .camera, usageDescriptions: cameraOnly) == .ask)
        #expect(WebMediaAccess.outcome(for: .microphone, usageDescriptions: cameraOnly) == .unavailable(missing: .microphone))
        // One missing description is enough: the system would end the app when the microphone is touched.
        #expect(
            WebMediaAccess.outcome(for: [.camera, .microphone], usageDescriptions: cameraOnly)
                == .unavailable(missing: .microphone)
        )
    }

    @Test func missingBlankOrMalformedDescriptionsCountAsMissing() {
        #expect(WebMediaAccess.outcome(for: .camera, usageDescriptions: nil) == .unavailable(missing: .camera))
        #expect(WebMediaAccess.outcome(for: .camera, usageDescriptions: [:]) == .unavailable(missing: .camera))
        #expect(
            WebMediaAccess.outcome(for: .camera, usageDescriptions: [WebMediaAccess.cameraUsageKey: "  \n"])
                == .unavailable(missing: .camera)
        )
        #expect(
            WebMediaAccess.outcome(for: .camera, usageDescriptions: [WebMediaAccess.cameraUsageKey: 1])
                == .unavailable(missing: .camera)
        )
        #expect(
            WebMediaAccess.outcome(for: [.camera, .microphone], usageDescriptions: nil)
                == .unavailable(missing: [.camera, .microphone])
        )
    }

    @Test func aRequestForNoKnownDeviceIsNeverAsked() {
        #expect(WebMediaAccess.outcome(for: [], usageDescriptions: MockCapture.usageDescriptions) == .unavailable(missing: []))
    }
}

/// Holds each question until the test answers it, to show that nothing is granted before then.
@MainActor
private final class PendingConfirmer: WebMediaCaptureConfirming {
    private(set) var questions: [(devices: WebMediaDevices, requester: WebMediaCaptureRequester)] = []
    private var completions: [(Bool) -> Void] = []

    func confirmMediaCapture(
        devices: WebMediaDevices,
        requester: WebMediaCaptureRequester,
        in window: NSWindow?,
        completion: @escaping (Bool) -> Void
    ) {
        questions.append((devices, requester))
        completions.append(completion)
    }

    func answer(_ yes: Bool) {
        completions.removeFirst()(yes)
    }
}

@MainActor
struct WebMediaCaptureDecisionTests {
    private final class Decisions {
        var all: [WKPermissionDecision] = []
    }

    private func decide(
        _ devices: WebMediaDevices,
        by requester: WebMediaCaptureRequester = .page(name: "demo.html"),
        usage: [String: Any]? = MockCapture.usageDescriptions,
        confirmer: PendingConfirmer
    ) -> (decisions: Decisions, outcome: WebMediaAccess.Outcome) {
        let decisions = Decisions()
        let outcome = WebMediaCapture.decide(
            devices: devices,
            requester: requester,
            in: nil,
            usageDescriptions: usage,
            confirmer: confirmer
        ) { decisions.all.append($0) }
        return (decisions, outcome)
    }

    @Test func nothingIsGrantedWhileTheQuestionIsOpen() {
        let confirmer = PendingConfirmer()
        let (decisions, outcome) = decide([.camera, .microphone], confirmer: confirmer)

        #expect(outcome == .ask)
        #expect(confirmer.questions.count == 1)
        #expect(decisions.all.isEmpty)

        confirmer.answer(true)
        #expect(decisions.all == [.grant])
    }

    @Test func onlyAnExplicitYesGrants() {
        let confirmer = PendingConfirmer()
        let (decisions, _) = decide(.microphone, confirmer: confirmer)

        confirmer.answer(false)

        #expect(decisions.all == [.deny])
    }

    @Test(arguments: [
        WebMediaCaptureRequester.page(name: "demo.html"),
        .plugin(name: "Acme", id: "dev.acme.tools")
    ])
    func everyRequestAsksAgainAndNamesWhoAsks(requester: WebMediaCaptureRequester) {
        let confirmer = PendingConfirmer()
        let first = decide(.camera, by: requester, confirmer: confirmer)
        confirmer.answer(true)
        let second = decide(.camera, by: requester, confirmer: confirmer)
        confirmer.answer(false)
        let third = decide(.camera, by: requester, confirmer: confirmer)
        confirmer.answer(true)

        #expect(first.decisions.all == [.grant])
        #expect(second.decisions.all == [.deny])
        #expect(third.decisions.all == [.grant])
        #expect(confirmer.questions.count == 3)
        #expect(confirmer.questions.allSatisfy { $0.requester == requester && $0.devices == .camera })
    }

    @Test func aRequestNamingNoDeviceIsDeniedWithoutAskingAnyone() {
        let confirmer = PendingConfirmer()
        let (decisions, outcome) = decide([], confirmer: confirmer)

        #expect(decisions.all == [.deny])
        #expect(outcome == .unavailable(missing: []))
        #expect(confirmer.questions.isEmpty)
    }

    /// An app whose Info.plist lacks the camera description, in the ways it can lack it.
    enum WithoutCameraDescription: CaseIterable {
        case noInfoPlist
        case noEntries
        case microphoneOnly

        var usageDescriptions: [String: Any]? {
            switch self {
            case .noInfoPlist: nil
            case .noEntries: [:]
            case .microphoneOnly: [WebMediaAccess.microphoneUsageKey: "Microphone"]
            }
        }
    }

    @Test(arguments: WithoutCameraDescription.allCases)
    func withoutTheUsageDescriptionTheRequestIsDeniedWithoutAskingAnyone(info: WithoutCameraDescription) {
        let confirmer = PendingConfirmer()
        let (decisions, outcome) = decide(.camera, usage: info.usageDescriptions, confirmer: confirmer)

        #expect(decisions.all == [.deny])
        #expect(outcome == .unavailable(missing: .camera))
        #expect(confirmer.questions.isEmpty)
    }

    @Test func withoutAWindowTheAppKitConfirmerDeniesExactlyOnce() {
        var answers: [Bool] = []
        AppKitWebMediaCaptureConfirmer().confirmMediaCapture(
            devices: .camera, requester: .page(name: "demo.html"), in: nil
        ) { answers.append($0) }
        #expect(answers == [false])
    }
}

@MainActor
struct WebMediaCaptureQuestionTests {
    private let devices: [WebMediaDevices] = [.camera, .microphone, [.camera, .microphone]]

    @Test func theQuestionNamesWhoAsksAndWhichDevices() {
        let requesters: [WebMediaCaptureRequester] = [.page(name: "demo.html"), .plugin(name: "demo.html", id: "dev.acme")]
        var questions: Set<String> = []
        for requester in requesters {
            for set in devices {
                let question = AppKitWebMediaCaptureConfirmer.question(for: set, requester: requester)
                #expect(question.contains("demo.html"))
                questions.insert(question)
            }
        }
        // Three device sets for a page and three for a plugin: all different, so a plugin cannot pass as a page.
        #expect(questions.count == 6)
    }

    @Test func aPluginsExplanationShowsItsID() {
        let explanation = AppKitWebMediaCaptureConfirmer.explanation(for: .plugin(name: "Acme", id: "dev.acme.tools"))
        #expect(explanation.contains("dev.acme.tools"))
        #expect(explanation != AppKitWebMediaCaptureConfirmer.explanation(for: .page(name: "Acme")))
    }

    @Test func aNameCannotReshapeOrImitateTheQuestion() {
        let text = AppKitWebMediaCaptureConfirmer.displayText(" Lithe\u{202E}\nwants\u{200B} nothing\t ")
        #expect(text == "Lithewants nothing")

        let long = String(repeating: "a", count: 200)
        let shortened = AppKitWebMediaCaptureConfirmer.displayText(long)
        #expect(shortened == String(repeating: "a", count: 80) + "…")
        #expect(AppKitWebMediaCaptureConfirmer.displayText("文档.html") == "文档.html")

        let question = AppKitWebMediaCaptureConfirmer.question(
            for: .camera, requester: .plugin(name: "Evil\nInject", id: "dev.acme")
        )
        #expect(!question.contains("\n"))
    }
}

/// An unanswered request is not a refusal: a web view whose delegate leaves it
/// unanswered shows WebKit's own prompt, so every place that builds a web view has
/// to name who answers, and only the gate may turn a request into a grant.
struct WebMediaCaptureCoverageTests {
    /// Each file that builds a web view, with the file and text that answer its requests.
    private static let answers: [String: (file: String, marker: String)] = [
        "Lithe/Platform/MacOS/MarkdownPreviewWebView.swift": ("MarkdownPreviewWebView.swift", "WebMediaCaptureDenier.shared"),
        "Lithe/Platform/MacOS/MonacoDiffEditor.swift": ("MonacoDiffEditor.swift", "WebMediaCaptureDenier.shared"),
        "Lithe/Platform/MacOS/MonacoWorkbenchEditor.swift": ("MonacoWorkbenchEditor.swift", "WebMediaCaptureDenier.shared"),
        "Lithe/Platform/MacOS/Updates/ReleaseNotesWebView.swift": ("ReleaseNotesWebView.swift", "WebMediaCaptureDenier.shared"),
        "Lithe/Views/Agent/AgentDesktopCardView.swift": ("AgentDesktopCardView.swift", "WebMediaCaptureDenier.shared"),
        "Lithe/Platform/MacOS/HTMLPreviewZoom.swift": ("HTMLPreviewMediaCapture.swift", "WebMediaCapture.decide("),
        "Lithe/Platform/MacOS/Plugins/Web/MacPluginWebPage.swift": ("MacPluginWebPage.swift", "WebMediaCapture.decide(")
    ]

    private func swiftSources() throws -> [(path: String, text: String)] {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [(String, String)] = []
        for case let file as URL in files where file.pathExtension == "swift" {
            result.append((String(file.path.dropFirst(sources.path.count + 1)), try String(contentsOf: file, encoding: .utf8)))
        }
        return result
    }

    @Test func everyWebViewNamesWhoAnswersItsCameraAndMicrophoneRequests() throws {
        let sources = try swiftSources()
        let builders = sources.filter {
            $0.text.contains("WKWebView(") || $0.text.range(of: #"class\s+\w+\s*:\s*WKWebView\b"#, options: .regularExpression) != nil
        }
        #expect(
            Set(builders.map(\.path)) == Set(Self.answers.keys),
            "A file builds a web view without naming who answers its camera and microphone requests, or one listed here no longer does."
        )
        for (creator, answer) in Self.answers {
            let file = sources.first { $0.path.hasSuffix("/" + answer.file) || $0.path == answer.file }
            #expect(file?.text.contains(answer.marker) == true, "\(creator) is not answered by \(answer.file)")
        }
    }

    @Test func onlyTheGateGrantsARequest() throws {
        let grants = try swiftSources().filter { $0.text.range(of: #"\.grant\b"#, options: .regularExpression) != nil }
        #expect(grants.map(\.path) == ["Lithe/Platform/MacOS/WebMediaCapture.swift"])
    }
}

@MainActor
struct WebMediaCaptureDenierTests {
    @Test func theDenierAnswersTheRequestWebKitSends() {
        let selector = NSSelectorFromString("webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:")
        #expect(WebMediaCaptureDenier.shared.responds(to: selector))
    }
}

extension MockCaptureTests {
    @MainActor
    @Suite struct LithePage {
        @Test(.enabled(if: MockCapture.isAvailable))
        func aPageOfLitheIsRefusedWithoutAnyQuestion() async throws {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            MockCapture.configure(configuration)
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
            webView.uiDelegate = WebMediaCaptureDenier.shared
            let window = NSWindow(contentRect: webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = webView
            window.orderFront(nil)
            defer {
                webView.stopLoading()
                window.contentView = nil
                window.close()
            }

            webView.loadHTMLString("<!doctype html><title>ready</title>", baseURL: URL(string: "https://lithe.example/"))
            let loaded = await waitForChanges(webViewChanges(webView)) { webView.title == "ready" }
            #expect(loaded, "Title was \(webView.title ?? "nil")")

            // Started without waiting, so a web view that asked someone instead of refusing cannot hang the test.
            _ = try await webView.evaluateJavaScript("""
                navigator.mediaDevices.getUserMedia({ video: true, audio: true }).then(
                  stream => { document.title = 'granted'; },
                  error => { document.title = 'denied:' + error.name; });
                0
                """)
            let answered = await waitForChanges(webViewChanges(webView)) { webView.title?.hasPrefix("denied:") == true }
            #expect(answered, "Title was \(webView.title ?? "nil")")
            #expect(webView.title == "denied:NotAllowedError")
            #expect(webView.cameraCaptureState == .none)
            #expect(webView.microphoneCaptureState == .none)
        }
    }
}
