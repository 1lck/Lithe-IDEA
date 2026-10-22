import AppKit
import Combine
import SwiftUI

/// The HTML preview: an embedded single-tab browser whose first page is the
/// document in the editor.
struct HTMLPreviewView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var document: EditorDocument
    @State private var browserError: String?
    @State private var isOpeningBrowser = false
    @State private var addressText = ""
    @FocusState private var addressFocused: Bool
    @StateObject private var content: HTMLPreviewContent
    @StateObject private var browser = HTMLPreviewBrowserController()

    init(document: EditorDocument) {
        self.document = document
        _content = StateObject(wrappedValue: HTMLPreviewContent(document: document))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            LitheToolWindowHeaderDivider()
            HTMLPreviewFindBar(find: browser.find)
            if let loadError = browser.loadError {
                errorBanner(loadError)
            }
            HTMLPreviewWebView(
                controller: browser,
                payload: .init(
                    html: content.html(for: document),
                    documentURL: document.url,
                    workspaceURL: model.workspaceURL
                )
            )
        }
        .alert("Could not open HTML in browser", isPresented: Binding(
            get: { browserError != nil },
            set: { if !$0 { browserError = nil } }
        )) {
            Button("OK") { browserError = nil }
        } message: {
            Text(browserError ?? "")
        }
        .background(LitheTheme.editor)
        .onAppear {
            content.observe(document)
            addressText = browser.address
        }
        .onChange(of: document.id) { _ in content.observe(document) }
        .onChange(of: document.url) { _ in content.observe(document) }
        .onChange(of: browser.address) { address in
            // Typing is never overwritten by a page that finishes loading.
            if !addressFocused { addressText = address }
        }
        .onChange(of: addressFocused) { focused in
            if !focused { addressText = browser.address }
        }
        .onDisappear { content.stopObserving() }
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            toolbarButton("Back", isEnabled: browser.canGoBack) {
                browser.goBack()
            } icon: {
                LitheIDEAIcon(resourcePath: "expui/general/chevronLeft.svg", size: 16, fallbackSystemImage: "chevron.left")
            }
            toolbarButton("Forward", isEnabled: browser.canGoForward) {
                browser.goForward()
            } icon: {
                LitheIDEAIcon(resourcePath: "expui/general/chevronRight.svg", size: 16, fallbackSystemImage: "chevron.right")
            }
            toolbarButton(browser.isLoading ? "Stop Loading" : "Reload") {
                if browser.isLoading {
                    browser.stopLoading()
                } else {
                    // Shift-click bypasses caches, like a browser's hard reload.
                    browser.reload(fromOrigin: NSEvent.modifierFlags.contains(.shift))
                }
            } icon: {
                if browser.isLoading {
                    LitheIDEAIcon(resourcePath: "expui/general/close.svg", size: 16, fallbackSystemImage: "xmark")
                } else {
                    LitheSystemIcon(systemImage: "arrow.clockwise", size: 16)
                }
            }

            LitheTextField("Enter address", text: $addressText, focus: $addressFocused)
                .onSubmit {
                    if browser.navigate(toAddress: addressText) { addressFocused = false }
                }
                .onExitCommand {
                    addressText = browser.address
                    addressFocused = false
                }

            HTMLPreviewCaptureIndicator(capture: browser.capture)
            zoomControls

            toolbarButton("Open HTML in Browser", isEnabled: !isOpeningBrowser) {
                openInBrowser()
            } icon: {
                Image(systemName: "arrow.up.right.square")
                    .font(LitheTheme.uiFont(size: 12, weight: .medium))
            }
            toolbarButton(
                "Developer Tools",
                isEnabled: browser.isDeveloperToolsAvailable,
                isSelected: browser.isDeveloperToolsVisible
            ) {
                browser.toggleDeveloperTools()
            } icon: {
                LitheSystemIcon(systemImage: "ladybug", size: 16)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 36)
        .background(LitheTheme.toolHeader)
    }

    /// "−", the zoom percentage (a click returns to 100%) and "+".
    private var zoomControls: some View {
        let percent = HTMLPreviewZoom.percent(browser.zoomFactor)
        return HStack(spacing: 0) {
            toolbarButton("Zoom Out", isEnabled: browser.canZoomOut) {
                browser.zoomOut()
            } icon: {
                LitheSystemIcon(systemImage: "minus.magnifyingglass", size: 16)
            }
            Button {
                browser.resetZoom()
            } label: {
                Text(verbatim: "\(percent)%")
                    .font(LitheTheme.uiFont(size: 11, weight: .medium))
                    .monospacedDigit()
            }
            .buttonStyle(ZoomPercentageButtonStyle())
            .help("Reset Page Zoom (100%)")
            .accessibilityLabel("Page Zoom")
            .accessibilityValue(Text(verbatim: "\(percent)%"))
            toolbarButton("Zoom In", isEnabled: browser.canZoomIn) {
                browser.zoomIn()
            } icon: {
                LitheSystemIcon(systemImage: "plus.magnifyingglass", size: 16)
            }
        }
    }

    private func toolbarButton<Icon: View>(
        _ title: LocalizedStringKey,
        isEnabled: Bool = true,
        isSelected: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        Button(action: action) { icon() }
            .buttonStyle(LitheIconButtonStyle(size: LitheTheme.Metrics.toolbarIconButtonSize, isSelected: isSelected))
            .disabled(!isEnabled)
            .help(title)
            .accessibilityLabel(title)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(LitheTheme.warning)
            Text(message)
                .font(LitheTheme.uiFont(size: 12))
                .foregroundStyle(LitheTheme.secondaryText)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(LitheTheme.toolHeader)
    }

    /// Opens what the preview is showing in the system's default web browser.
    /// A local page is read from disk, so unsaved editor changes are not included.
    private func openInBrowser() {
        switch browser.externalOpenTarget ?? .localFile(document.url) {
        case let .remote(url):
            browser.openInSystemBrowser(url)
        case let .localFile(file):
            isOpeningBrowser = true
            Task { @MainActor in
                defer { isOpeningBrowser = false }
                do {
                    try await model.platformUI.openHTMLInBrowser(file)
                } catch {
                    browserError = error.localizedDescription
                }
            }
        }
    }
}

/// Debounces live editor changes before refreshing the previewed document.
@MainActor
private final class HTMLPreviewContent: ObservableObject {
    @Published private(set) var html: String
    private var observedDocumentID: UUID
    private var changes: AnyCancellable?

    init(document: EditorDocument) {
        html = document.text
        observedDocumentID = document.id
    }

    /// The text to preview for `document`. When the editor switches to another
    /// HTML file this view is reused and `observe` only runs after the first
    /// render, so until then `html` is still the previous file's text.
    func html(for document: EditorDocument) -> String {
        observedDocumentID == document.id ? html : document.text
    }

    func observe(_ document: EditorDocument) {
        stopObserving()
        observedDocumentID = document.id
        update(document)
        changes = document.textDidChange
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self, weak document] _ in
                guard let document else { return }
                self?.update(document)
            }
    }

    func stopObserving() {
        changes?.cancel()
        changes = nil
    }

    private func update(_ document: EditorDocument) {
        html = document.text
    }
}
