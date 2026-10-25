import AppKit
import Combine
import SwiftUI
import WebKit

// Note: HTML 预览作为内嵌浏览器的决策见 .agents/notes/implemented/feature/2026-10-22-html-preview-embedded-browser.md

/// Whether the page is capturing from a device, mirroring `WKMediaCaptureState`.
enum HTMLPreviewCaptureState: Equatable {
    case inactive
    case active
    case muted

    init(_ state: WKMediaCaptureState) {
        switch state {
        case .active: self = .active
        case .muted: self = .muted
        case .none: self = .inactive
        @unknown default: self = .inactive
        }
    }
}

/// The camera and microphone state of the page, for the indicator in the toolbar.
///
/// WebKit owns the truth: the state is read from the web view's observable
/// properties, and muting or stopping goes back through the web view, so the
/// indicator follows whatever the page or the system does too.
@MainActor
final class HTMLPreviewCaptureModel: ObservableObject {
    @Published private(set) var camera = HTMLPreviewCaptureState.inactive
    @Published private(set) var microphone = HTMLPreviewCaptureState.inactive

    private weak var webView: WKWebView?
    private var cancellables = Set<AnyCancellable>()

    var isCapturing: Bool { camera != .inactive || microphone != .inactive }

    init(webView: WKWebView) {
        self.webView = webView
        webView.publisher(for: \.cameraCaptureState).removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.camera = HTMLPreviewCaptureState(state) }
            .store(in: &cancellables)
        webView.publisher(for: \.microphoneCaptureState).removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.microphone = HTMLPreviewCaptureState(state) }
            .store(in: &cancellables)
    }

    func setCameraMuted(_ muted: Bool) {
        webView?.setCameraCaptureState(muted ? .muted : .active, completionHandler: nil)
    }

    func stopCamera() {
        webView?.setCameraCaptureState(.none, completionHandler: nil)
    }

    func setMicrophoneMuted(_ muted: Bool) {
        webView?.setMicrophoneCaptureState(muted ? .muted : .active, completionHandler: nil)
    }

    func stopMicrophone() {
        webView?.setMicrophoneCaptureState(.none, completionHandler: nil)
    }
}

/// The device-in-use indicator shown at the right of the address bar. It is
/// there only while a device is in use; a click opens the choices to mute or stop it.
struct HTMLPreviewCaptureIndicator: View {
    @ObservedObject var capture: HTMLPreviewCaptureModel

    var body: some View {
        if capture.isCapturing {
            LitheMenu {
                LitheContextMenuItem.heading(title)
                LitheContextMenuItem.separator
                if capture.camera != .inactive {
                    LitheContextMenuItem.action(capture.camera == .muted ? "Unmute Camera" : "Mute Camera") {
                        capture.setCameraMuted(capture.camera != .muted)
                    }
                    LitheContextMenuItem.action("Stop Camera") { capture.stopCamera() }
                }
                if capture.microphone != .inactive {
                    LitheContextMenuItem.action(capture.microphone == .muted ? "Unmute Microphone" : "Mute Microphone") {
                        capture.setMicrophoneMuted(capture.microphone != .muted)
                    }
                    LitheContextMenuItem.action("Stop Microphone") { capture.stopMicrophone() }
                }
            } label: {
                HStack(spacing: 3) {
                    if capture.camera != .inactive {
                        icon(active: "video.fill", muted: "video.slash.fill", state: capture.camera)
                    }
                    if capture.microphone != .inactive {
                        icon(active: "mic.fill", muted: "mic.slash.fill", state: capture.microphone)
                    }
                }
                .padding(.horizontal, 4)
            }
            .litheToolbarIconButton(isIconOnly: false)
            .help(LocalizedStringKey(title))
            .accessibilityLabel(LocalizedStringKey(title))
        }
    }

    /// The localization key naming what the page is using.
    private var title: String {
        switch (capture.camera != .inactive, capture.microphone != .inactive) {
        case (true, true): "Camera and microphone in use"
        case (true, false): "Camera in use"
        default: "Microphone in use"
        }
    }

    /// Red while the device is recording, grey once it is muted.
    private func icon(active: String, muted: String, state: HTMLPreviewCaptureState) -> some View {
        Image(systemName: state == .muted ? muted : active)
            .font(LitheTheme.uiFont(size: 13, weight: .medium))
            .foregroundStyle(state == .muted ? LitheTheme.secondaryText : LitheTheme.error)
    }
}

extension HTMLPreviewBrowserController {
    /// A page asked for the camera and/or microphone (`getUserMedia`).
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        requestMediaCapture(
            devices: WebMediaDevices(type),
            source: sourceLabel(for: frame.request.url),
            decide: decisionHandler
        )
    }

    /// The whole decision, free of the WebKit types a test cannot build. Every
    /// request that reaches here ends in exactly one answer; Lithe keeps no record
    /// of earlier answers, so each of them asks.
    func requestMediaCapture(
        devices: WebMediaDevices,
        source: String,
        decide: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        let outcome = WebMediaCapture.decide(
            devices: devices,
            requester: .page(name: source),
            in: webView.window,
            usageDescriptions: mediaUsageDescriptions(),
            confirmer: dialogs,
            completion: decide
        )
        guard case let .unavailable(missing) = outcome, !missing.isEmpty else { return }
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Lithe"
        dialogs.presentAlert(
            message: String(localized: "Lithe can’t give pages access to the camera or microphone in this version."),
            source: appName,
            in: webView.window,
            completion: {}
        )
    }
}
