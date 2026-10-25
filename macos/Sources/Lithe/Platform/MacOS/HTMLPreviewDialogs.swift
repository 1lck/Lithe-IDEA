import AppKit

/// Native replacements for the dialogs a browser supplies to web pages.
///
/// `WKWebView` answers every one of these with "cancel" unless its UI delegate
/// implements them, which is why `alert`, `confirm`, `prompt` and file inputs
/// silently did nothing in the preview. Each completion runs exactly once.
@MainActor
protocol HTMLPreviewDialogPresenting: WebMediaCaptureConfirming {
    func presentAlert(message: String, source: String, in window: NSWindow?, completion: @escaping () -> Void)
    func presentConfirm(message: String, source: String, in window: NSWindow?, completion: @escaping (Bool) -> Void)
    func presentPrompt(
        message: String,
        defaultText: String?,
        source: String,
        in window: NSWindow?,
        completion: @escaping (String?) -> Void
    )
    func chooseFiles(
        allowsMultiple: Bool,
        allowsDirectories: Bool,
        in window: NSWindow?,
        completion: @escaping ([URL]?) -> Void
    )
    func chooseDownloadDestination(suggestedFilename: String, in window: NSWindow?, completion: @escaping (URL?) -> Void)
    /// Shows the print panel for `operation` as a sheet on `window`.
    func runPrintOperation(_ operation: NSPrintOperation, in window: NSWindow?)
}

/// Presents the dialogs as sheets on the preview's window. A page's script stays
/// blocked until the sheet closes, matching how browsers treat `alert`.
@MainActor
final class HTMLPreviewAppKitDialogs: HTMLPreviewDialogPresenting {
    private let mediaCapture = AppKitWebMediaCaptureConfirmer()

    func presentAlert(message: String, source: String, in window: NSWindow?, completion: @escaping () -> Void) {
        guard let window else { return completion() }
        let alert = makeAlert(message: message, source: source)
        alert.addButton(withTitle: String(localized: "OK"))
        alert.beginSheetModal(for: window) { _ in completion() }
    }

    func presentConfirm(message: String, source: String, in window: NSWindow?, completion: @escaping (Bool) -> Void) {
        guard let window else { return completion(false) }
        let alert = makeAlert(message: message, source: source)
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { completion($0 == .alertFirstButtonReturn) }
    }

    func presentPrompt(
        message: String,
        defaultText: String?,
        source: String,
        in window: NSWindow?,
        completion: @escaping (String?) -> Void
    ) {
        guard let window else { return completion(nil) }
        let alert = makeAlert(message: message, source: source)
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            completion(response == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    func chooseFiles(
        allowsMultiple: Bool,
        allowsDirectories: Bool,
        in window: NSWindow?,
        completion: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = allowsMultiple
        panel.canChooseDirectories = allowsDirectories
        panel.canChooseFiles = true
        if let window {
            panel.beginSheetModal(for: window) { completion($0 == .OK ? panel.urls : nil) }
        } else {
            completion(nil)
        }
    }

    func chooseDownloadDestination(suggestedFilename: String, in window: NSWindow?, completion: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true
        if let window {
            panel.beginSheetModal(for: window) { completion($0 == .OK ? panel.url : nil) }
        } else {
            completion(nil)
        }
    }

    func confirmMediaCapture(
        devices: WebMediaDevices,
        requester: WebMediaCaptureRequester,
        in window: NSWindow?,
        completion: @escaping (Bool) -> Void
    ) {
        mediaCapture.confirmMediaCapture(devices: devices, requester: requester, in: window, completion: completion)
    }

    func runPrintOperation(_ operation: NSPrintOperation, in window: NSWindow?) {
        guard let window else { return }
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    private func makeAlert(message: String, source: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(format: String(localized: "“%@” says"), source)
        alert.informativeText = message
        return alert
    }
}
