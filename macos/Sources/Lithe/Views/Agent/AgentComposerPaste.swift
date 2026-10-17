import AppKit
import SwiftUI

/// Naming for pasted images saved by `AppModel.saveAgentPastedImage`.
enum AgentPastedImage {
    /// `Pasted image 2026-10-16 14.03.21.png` reads well in the attachment chip;
    /// the suffix keeps two pastes within one second apart.
    static func fileName(date: Date = Date(), suffix: String = String(UUID().uuidString.prefix(4))) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
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

/// Intercepts ⌘V while the composer is focused. The text field's field editor
/// handles `paste:` before SwiftUI sees it, so a key monitor is the only hook.
struct AgentPasteAttachments: ViewModifier {
    let isActive: Bool
    /// Returns true when the pasteboard was attached and the key is consumed.
    let onPaste: (AgentPasteboardAttachment) -> Bool
    @State private var monitor = AgentPasteMonitor()

    func body(content: Content) -> some View {
        content
            .onAppear { monitor.onPaste = isActive ? onPaste : nil; monitor.install() }
            .onChange(of: isActive) { active in monitor.onPaste = active ? onPaste : nil }
            .onDisappear { monitor.remove() }
    }
}

@MainActor
private final class AgentPasteMonitor {
    var onPaste: ((AgentPasteboardAttachment) -> Bool)?
    private var token: Any?

    func install() {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors run on the main thread.
            MainActor.assumeIsolated {
                guard let onPaste = self?.onPaste,
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      event.charactersIgnoringModifiers?.lowercased() == "v",
                      let attachment = AgentPasteboardAttachment.read(from: .general),
                      onPaste(attachment) else { return event }
                return nil
            }
        }
    }

    func remove() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}
