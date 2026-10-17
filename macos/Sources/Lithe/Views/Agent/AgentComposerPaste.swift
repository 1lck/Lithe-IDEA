import AppKit
import SwiftUI

/// Naming for pasted images saved by `AppModel.saveAgentPastedImage`.
enum AgentPastedImage {
    /// `Pasted image 2026-10-16 14.03.21.png` reads well in the attachment chip;
    /// the suffix keeps two pastes within one second apart.
    static func fileName(date: Date = Date(), timeZone: TimeZone = .current,
                         suffix: String = String(UUID().uuidString.prefix(4))) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Pasted image \(formatter.string(from: date)) \(suffix).png"
    }

    static let previewExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "tif", "tiff", "webp", "bmp"]
}

/// What ⌘V in the composer attaches instead of pasting text.
enum AgentPasteboardAttachment: Equatable {
    /// Files copied in Finder; also carries their names as text, which is ignored.
    case files([URL])
    /// Image data without text, such as a screenshot; normalized to PNG.
    case image(Data)

    /// Nil when the pasteboard holds text, so the field pastes as usual.
    static func read(from pasteboard: NSPasteboard) -> Self? {
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !files.isEmpty { return .files(files) }
        guard pasteboard.string(forType: .string) == nil,
              let image = NSImage(pasteboard: pasteboard),
              let png = png(image) else { return nil }
        return .image(png)
    }

    static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

/// Mounted behind the writing field so each monitor can verify its native owner.
struct AgentPasteAttachments: NSViewRepresentable {
    let isActive: Bool
    /// Returns true when the pasteboard was attached and the key is consumed.
    let onPaste: (AgentPasteboardAttachment) -> Bool

    func makeNSView(context: Context) -> AgentPasteAttachmentView {
        let view = AgentPasteAttachmentView()
        view.onPaste = isActive ? onPaste : nil
        return view
    }

    func updateNSView(_ view: AgentPasteAttachmentView, context: Context) {
        view.onPaste = isActive ? onPaste : nil
    }

    static func dismantleNSView(_ view: AgentPasteAttachmentView, coordinator: ()) {
        view.onPaste = nil
        view.removeMonitor()
    }
}

@MainActor
final class AgentPasteAttachmentView: NSView {
    var onPaste: ((AgentPasteboardAttachment) -> Bool)?
    private var token: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors run on the main thread.
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.handle(event) == nil
            }
            return consumed ? nil : event
        }
    }

    func handle(_ event: NSEvent, pasteboard: NSPasteboard = .general) -> NSEvent? {
        guard let onPaste, let window, event.window === window,
              let editor = window.firstResponder as? NSTextView, editor.isEditable,
              editor.convert(editor.bounds, to: self).contains(NSPoint(x: bounds.midX, y: bounds.midY)),
              event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
              event.charactersIgnoringModifiers?.lowercased() == "v",
              let attachment = AgentPasteboardAttachment.read(from: pasteboard),
              onPaste(attachment) else { return event }
        return nil
    }

    func removeMonitor() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}
