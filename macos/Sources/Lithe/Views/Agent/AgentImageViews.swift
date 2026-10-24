import AppKit
import ImageIO
import SwiftUI
import LitheAgentConversationModule

/// Images of one tool group or message, opened at `index` in the enlarged viewer.
struct AgentImageGallery: Identifiable, Equatable {
    let id = UUID()
    let images: [AgentImage]
    var index: Int
}

/// Owns the open viewer. Rows hold only this reference, so opening or closing
/// the viewer never re-evaluates the transcript rows themselves.
@MainActor
final class AgentImageViewerState: ObservableObject {
    @Published var gallery: AgentImageGallery?

    func open(_ images: [AgentImage], at index: Int) {
        guard images.indices.contains(index) else { return }
        gallery = AgentImageGallery(images: images, index: index)
    }
}

private struct AgentImageViewerStateKey: EnvironmentKey {
    static let defaultValue: AgentImageViewerState? = nil
}

extension EnvironmentValues {
    var agentImageViewer: AgentImageViewerState? {
        get { self[AgentImageViewerStateKey.self] }
        set { self[AgentImageViewerStateKey.self] = newValue }
    }
}

/// Decodes bounded renditions off the main thread. Inline pictures can be several
/// megabytes, so rows ask for a thumbnail-sized decode and share it through a cache.
enum AgentImageLoader {
    private static let cache = NSCache<NSString, NSImage>()

    static func cachedImage(for image: AgentImage, maxPixel: Int) -> NSImage? {
        cache.object(forKey: key(image, maxPixel))
    }

    static func image(for image: AgentImage, maxPixel: Int) async -> NSImage? {
        if let cached = cachedImage(for: image, maxPixel: maxPixel) { return cached }
        let source = image.source
        let rendition = await Task.detached(priority: .utility) { () -> CGImage? in
            let imageSource: CGImageSource?
            switch source {
            case .data(let data): imageSource = CGImageSourceCreateWithData(data as CFData, nil)
            case .file(let path): imageSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
            }
            guard let imageSource else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ] as CFDictionary)
        }.value
        guard let rendition else { return nil }
        let result = NSImage(cgImage: rendition, size: NSSize(width: rendition.width, height: rendition.height))
        cache.setObject(result, forKey: key(image, maxPixel))
        return result
    }

    private static func key(_ image: AgentImage, _ maxPixel: Int) -> NSString { "\(image.id)@\(maxPixel)" as NSString }
}

/// A picture that fills its frame, or fits inside it, once decoded.
struct AgentImageThumbnail: View {
    let image: AgentImage
    var maxPixel = 160
    var fills = true
    @State private var rendition: NSImage?

    var body: some View {
        ZStack {
            if let rendition {
                Image(nsImage: rendition).resizable().aspectRatio(contentMode: fills ? .fill : .fit)
            } else {
                Rectangle().fill(LitheTheme.raised)
            }
        }
        .task(id: image.id) {
            rendition = AgentImageLoader.cachedImage(for: image, maxPixel: maxPixel)
            if rendition == nil { rendition = await AgentImageLoader.image(for: image, maxPixel: maxPixel) }
        }
    }
}

/// Newest pictures beside a tool row or group, `+N` for the rest. Hovering previews
/// one; clicking opens the whole set in the viewer.
struct AgentImageStrip: View {
    @Environment(\.agentImageViewer) private var viewer
    let images: [AgentImage]
    static let visibleLimit = 3
    static let thumbnailSize = CGSize(width: 36, height: 26)

    var body: some View {
        let first = max(images.count - Self.visibleLimit, 0)
        HStack(spacing: 6) {
            if first > 0 {
                Text(verbatim: "+\(first)")
                    .font(LitheTheme.uiFont(size: 12.5))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            ForEach(Array(images.enumerated()).suffix(Self.visibleLimit), id: \.element.id) { index, image in
                AgentImageThumbnail(image: image)
                    .frame(width: Self.thumbnailSize.width, height: Self.thumbnailSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(LitheTheme.panelBorder, lineWidth: 1))
                    .contentShape(Rectangle())
                    .lithePointer()
                    .onTapGesture { viewer?.open(images, at: index) }
                    .workbenchHoverCard(placement: .above, maximumWidth: AgentImagePreviewCard.width) {
                        AgentImagePreviewCard(image: image, position: index + 1, count: images.count)
                    }
                    .accessibilityElement()
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(Text(verbatim: image.title ?? "Image"))
                    .accessibilityHint(Text("Enlarge image"))
            }
        }
        .fixedSize()
        .accessibilityIdentifier("agent-image-strip")
    }
}

/// Non-interactive hover card with a larger rendition and its caption.
private struct AgentImagePreviewCard: View {
    @Environment(\.locale) private var locale
    let image: AgentImage
    let position: Int
    let count: Int
    static let width: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AgentImageThumbnail(image: image, maxPixel: 960, fills: false)
                .frame(maxWidth: Self.width, maxHeight: 220)
                .frame(minHeight: 60)
            HStack(spacing: 8) {
                Text(verbatim: image.title ?? "")
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if count > 1 {
                    Text(String(format: AgentLocalization.string("Item %lld of %lld", locale: locale), position, count))
                        .foregroundStyle(LitheTheme.secondaryText)
                }
            }
            .font(LitheTheme.uiFont(size: 12.5))
            .foregroundStyle(LitheTheme.HoverTooltip.foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .frame(width: Self.width)
        .litheHoverTooltipSurface()
    }
}

/// Attachments of a user message, larger than tool thumbnails.
struct AgentUserImages: View {
    @Environment(\.agentImageViewer) private var viewer
    let images: [AgentImage]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                AgentImageThumbnail(image: image, maxPixel: 320)
                    .frame(width: 84, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(LitheTheme.panelBorder, lineWidth: 1))
                    .contentShape(Rectangle())
                    .lithePointer()
                    .onTapGesture { viewer?.open(images, at: index) }
                    .accessibilityElement()
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(Text(verbatim: image.title ?? "Image"))
                    .accessibilityHint(Text("Enlarge image"))
            }
        }
        .accessibilityIdentifier("agent-user-images")
    }
}

/// Full-pane viewer: dimmed backdrop, image fitted to the pane, arrows and Esc.
struct AgentImageViewer: View {
    @Environment(\.locale) private var locale
    @ObservedObject var state: AgentImageViewerState
    let gallery: AgentImageGallery

    var body: some View {
        let image = gallery.images[gallery.index]
        ZStack {
            Color.black.opacity(0.62)
                .contentShape(Rectangle())
                .onTapGesture { state.gallery = nil }
            VStack(spacing: 10) {
                AgentImageThumbnail(image: image, maxPixel: 2400, fills: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .shadow(color: .black.opacity(0.35), radius: 12)
                    .allowsHitTesting(false)
                HStack(spacing: 8) {
                    Text(verbatim: image.title ?? "")
                        .lineLimit(1).truncationMode(.middle)
                    if gallery.images.count > 1 {
                        Text(String(format: AgentLocalization.string("Item %lld of %lld", locale: locale),
                                    gallery.index + 1, gallery.images.count))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .font(LitheTheme.uiFont(size: 12.5))
                .foregroundStyle(.white)
            }
            .padding(.horizontal, 56)
            .padding(.vertical, 40)
            HStack {
                if gallery.images.count > 1 {
                    step(-1, systemImage: "chevron.left", key: .leftArrow, label: "Previous image")
                }
                Spacer()
                if gallery.images.count > 1 {
                    step(1, systemImage: "chevron.right", key: .rightArrow, label: "Next image")
                }
            }
            .padding(.horizontal, 12)
            VStack {
                HStack {
                    Spacer()
                    Button { state.gallery = nil } label: {
                        Image(systemName: "xmark").font(LitheTheme.uiFont(size: 13, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .background(.white.opacity(0.16), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.litheNoPress)
                    .foregroundStyle(.white)
                    .keyboardShortcut(.cancelAction)
                    .lithePointer()
                    .help("Close")
                    .accessibilityLabel("Close")
                }
                Spacer()
            }
            .padding(12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-image-viewer")
    }

    private func step(_ delta: Int, systemImage: String, key: KeyEquivalent, label: LocalizedStringKey) -> some View {
        Button {
            let count = gallery.images.count
            state.gallery?.index = (gallery.index + delta + count) % count
        } label: {
            Image(systemName: systemImage).font(LitheTheme.uiFont(size: 14, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.16), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.litheNoPress)
        .foregroundStyle(.white)
        .keyboardShortcut(key, modifiers: [])
        .lithePointer()
        .help(label)
        .accessibilityLabel(label)
    }
}
