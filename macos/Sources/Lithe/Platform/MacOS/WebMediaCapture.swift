import AppKit
import WebKit

// Note: 摄像头和麦克风默认拒绝、每次确认的决策见 .agents/notes/implemented/feature/2026-10-22-html-preview-embedded-browser.md

/// The devices a page asks to capture from.
struct WebMediaDevices: OptionSet, Equatable {
    let rawValue: Int

    static let camera = WebMediaDevices(rawValue: 1 << 0)
    static let microphone = WebMediaDevices(rawValue: 1 << 1)

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// A capture type WebKit adds later asks for nothing Lithe knows, so it gets no device.
    init(_ type: WKMediaCaptureType) {
        switch type {
        case .camera: self = .camera
        case .microphone: self = .microphone
        case .cameraAndMicrophone: self = [.camera, .microphone]
        @unknown default: self = []
        }
    }
}

/// Whether the app may ask the system for a device at all.
///
/// macOS ends a process that touches the camera or microphone without the
/// matching usage description in its Info.plist, so a request is only put to the
/// user when the description is there. WebKit reads the same entries: without
/// them `navigator.mediaDevices` is not even defined, which makes this a second
/// line of defence for scripts that reach the delegate another way.
enum WebMediaAccess {
    enum Outcome: Equatable {
        /// The user decides.
        case ask
        /// The app cannot offer these devices. An empty set means the request named none.
        case unavailable(missing: WebMediaDevices)
    }

    static let cameraUsageKey = "NSCameraUsageDescription"
    static let microphoneUsageKey = "NSMicrophoneUsageDescription"

    static func outcome(for devices: WebMediaDevices, usageDescriptions info: [String: Any]?) -> Outcome {
        guard !devices.isEmpty else { return .unavailable(missing: []) }
        var missing: WebMediaDevices = []
        let required: [(device: WebMediaDevices, key: String)] = [
            (.camera, cameraUsageKey),
            (.microphone, microphoneUsageKey),
        ]
        for (device, key) in required where devices.contains(device) {
            let description = (info?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if description.isEmpty { missing.insert(device) }
        }
        return missing.isEmpty ? .ask : .unavailable(missing: missing)
    }
}

/// Who is asking, as the question names them. A plugin picks its own name, so
/// the question says it is a plugin and shows the ID the host knows it by.
enum WebMediaCaptureRequester: Equatable {
    /// A page the user opened in the HTML preview.
    case page(name: String)
    /// A plugin's own page in a tool window.
    case plugin(name: String, id: String)
}

/// Puts a request to the user. An implementation answers exactly once, and
/// answers `true` only for an explicit "yes".
@MainActor
protocol WebMediaCaptureConfirming: AnyObject {
    func confirmMediaCapture(
        devices: WebMediaDevices,
        requester: WebMediaCaptureRequester,
        in window: NSWindow?,
        completion: @escaping (Bool) -> Void
    )
}

/// The only place a camera or microphone request becomes a grant.
///
/// Nothing has access by default. A request is granted after the user answers
/// "yes" to a question that names who asks, and every request is asked again.
/// Whatever else is true (no device named, no usage description, no window to
/// ask in) the answer is no.
@MainActor
enum WebMediaCapture {
    /// Answers `completion` exactly once and reports what the app could offer, so a
    /// caller can tell the user when the build cannot give a device at all.
    @discardableResult
    static func decide(
        devices: WebMediaDevices,
        requester: WebMediaCaptureRequester,
        in window: NSWindow?,
        usageDescriptions: [String: Any]?,
        confirmer: any WebMediaCaptureConfirming,
        completion: @escaping @MainActor (WKPermissionDecision) -> Void
    ) -> WebMediaAccess.Outcome {
        let outcome = WebMediaAccess.outcome(for: devices, usageDescriptions: usageDescriptions)
        switch outcome {
        case .ask:
            confirmer.confirmMediaCapture(devices: devices, requester: requester, in: window) { granted in
                completion(granted ? .grant : .deny)
            }
        case .unavailable:
            completion(.deny)
        }
        return outcome
    }
}

/// The UI delegate of the web views that show Lithe's own pages: the editors,
/// the Markdown preview and the release notes. They have no use for a camera or
/// microphone, so a request is refused without asking anyone.
///
/// A web view whose delegate leaves the request unanswered falls back to
/// WebKit's own prompt instead of refusing, so each of them names this delegate.
@MainActor
final class WebMediaCaptureDenier: NSObject, WKUIDelegate {
    static let shared = WebMediaCaptureDenier()

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.deny)
    }
}

/// Asks in a sheet on the window that shows the page.
///
/// "Don’t Allow" comes first, so it is what Return chooses; a device is granted
/// only by an explicit click on "Allow". Without a window there is nobody to
/// ask, so the answer is no.
@MainActor
final class AppKitWebMediaCaptureConfirmer: WebMediaCaptureConfirming {
    func confirmMediaCapture(
        devices: WebMediaDevices,
        requester: WebMediaCaptureRequester,
        in window: NSWindow?,
        completion: @escaping (Bool) -> Void
    ) {
        guard let window else { return completion(false) }
        let alert = NSAlert()
        alert.messageText = Self.question(for: devices, requester: requester)
        alert.informativeText = Self.explanation(for: requester)
        alert.addButton(withTitle: String(localized: "Don’t Allow"))
        alert.addButton(withTitle: String(localized: "Allow"))
        alert.beginSheetModal(for: window) { completion($0 == .alertSecondButtonReturn) }
    }

    /// The alert title: who asks and for which devices.
    static func question(for devices: WebMediaDevices, requester: WebMediaCaptureRequester) -> String {
        switch requester {
        case let .page(name):
            let format = switch (devices.contains(.camera), devices.contains(.microphone)) {
            case (true, true): String(localized: "“%@” wants to use your camera and microphone.")
            case (true, false): String(localized: "“%@” wants to use your camera.")
            default: String(localized: "“%@” wants to use your microphone.")
            }
            return String(format: format, displayText(name))
        case let .plugin(name, _):
            let format = switch (devices.contains(.camera), devices.contains(.microphone)) {
            case (true, true): String(localized: "The plugin “%@” wants to use your camera and microphone.")
            case (true, false): String(localized: "The plugin “%@” wants to use your camera.")
            default: String(localized: "The plugin “%@” wants to use your microphone.")
            }
            return String(format: format, displayText(name))
        }
    }

    /// What the user can do about it once the page is using the device.
    static func explanation(for requester: WebMediaCaptureRequester) -> String {
        switch requester {
        case .page:
            String(localized: "You can mute or stop the device from the address bar while the page is using it.")
        case let .plugin(_, id):
            String(
                format: String(localized: "Plugin ID: %@. It can keep using the device until you close or hide its window."),
                displayText(id)
            )
        }
    }

    /// A name goes into a question the user answers, and a plugin chooses its own:
    /// line breaks, direction overrides and other invisible characters are dropped
    /// and a long one is cut, so it cannot reshape or imitate the rest of the text.
    static func displayText(_ text: String, limit: Int = 80) -> String {
        let visible = String(String.UnicodeScalarView(text.unicodeScalars.filter {
            $0.properties.generalCategory != .control && $0.properties.generalCategory != .format
        }))
        let trimmed = visible.trimmingCharacters(in: .whitespaces)
        return trimmed.count > limit ? String(trimmed.prefix(limit)) + "…" : trimmed
    }
}
