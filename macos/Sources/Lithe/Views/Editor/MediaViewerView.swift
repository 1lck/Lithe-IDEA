import AVKit
import AppKit
import SwiftUI

struct MediaViewerView: View {
    @EnvironmentObject private var model: AppModel
    let media: MediaDocument
    private let imageContentPadding: CGFloat = 24
    @State private var imageScale: CGFloat?
    @State private var imageFitScale: CGFloat = 1
    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle()
                .fill(LitheTheme.divider)
                .frame(height: 1)
            viewer
        }
        .background(LitheTheme.editor)
        .onAppear {
            if media.kind == .video, player == nil {
                player = AVPlayer(url: media.url)
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
        .onChange(of: media.id) { _ in
            imageScale = nil
            imageFitScale = 1
            player?.pause()
            player = media.kind == .video ? AVPlayer(url: media.url) : nil
        }
    }

    @ViewBuilder
    private var viewer: some View {
        switch media.kind {
        case .image:
            imageViewer
        case .video:
            if let player {
                VideoPlayer(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(12)
            } else {
                ProgressView("Loading video…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var imageViewer: some View {
        Group {
            if let image = NSImage(contentsOf: media.url) {
                GeometryReader { geometry in
                    let fitScale = imageFitScale(for: image, in: geometry.size)
                    let renderedScale = clampedImageScale(
                        imageScale ?? fitScale,
                        fitScale: fitScale
                    )

                    MediaImageScrollView(
                        image: image,
                        imageID: media.id,
                        scale: $imageScale,
                        targetScale: renderedScale,
                        minimumScale: min(0.25, fitScale),
                        maximumScale: 4,
                        contentPadding: imageContentPadding
                    )
                    .background(checkerboard)
                    .onAppear {
                        updateImageFitScale(fitScale)
                    }
                    .onChange(of: geometry.size) { _ in
                        updateImageFitScale(fitScale)
                    }
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 28))
                        .foregroundStyle(LitheTheme.secondaryText)
                    Text("Could not load this image")
                        .foregroundStyle(LitheTheme.primaryText)
                    Text(media.url.path)
                        .font(.system(size: 11))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func imageFitScale(for image: NSImage, in viewport: CGSize) -> CGFloat {
        guard image.size.width > 0, image.size.height > 0 else { return 1 }

        let availableWidth = max(1, viewport.width - imageContentPadding * 2)
        let availableHeight = max(1, viewport.height - imageContentPadding * 2)
        return min(
            availableWidth / image.size.width,
            availableHeight / image.size.height,
            1
        )
    }

    private func updateImageFitScale(_ fitScale: CGFloat) {
        guard fitScale.isFinite, fitScale > 0 else { return }
        guard abs(imageFitScale - fitScale) > 0.001 else { return }
        imageFitScale = fitScale
    }

    private func clampedImageScale(
        _ scale: CGFloat,
        fitScale: CGFloat? = nil
    ) -> CGFloat {
        let minimumScale = min(0.25, fitScale ?? imageFitScale)
        return min(max(scale, minimumScale), 4)
    }

    private var checkerboard: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let tile: CGFloat = 16
                let columns = Int(ceil(size.width / tile))
                let rows = Int(ceil(size.height / tile))
                for row in 0..<rows {
                    for column in 0..<columns {
                        let color = (row + column).isMultiple(of: 2)
                            ? Color.white.opacity(0.07)
                            : Color.black.opacity(0.07)
                        context.fill(
                            Path(CGRect(
                                x: CGFloat(column) * tile,
                                y: CGFloat(row) * tile,
                                width: tile,
                                height: tile
                            )),
                            with: .color(color)
                        )
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .allowsHitTesting(false)
    }

    private var currentImageScale: CGFloat {
        imageScale ?? imageFitScale
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            LitheIcon(kind: LitheIcons.kind(for: media.url, isDirectory: false), size: 14)
            Text(media.displayName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LitheTheme.primaryText)
                .lineLimit(1)
            Spacer()
            if media.kind == .image {
                Button {
                    imageScale = clampedImageScale(currentImageScale - 0.25)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .litheIconButton()
                .help("Zoom out")
                Button {
                    imageScale = 1
                } label: {
                    Image(systemName: "1.magnifyingglass")
                }
                .litheIconButton()
                .help("Actual size")
                Button {
                    imageScale = clampedImageScale(currentImageScale + 0.25)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .litheIconButton()
                .help("Zoom in")
            }
            Button("Open in Default App") {
                model.openMediaInDefaultApplication(media)
            }
            .buttonStyle(LitheSecondaryButtonStyle())
            Button {
                model.revealProjectItemInFinder(media.url)
            } label: {
                Image(systemName: "folder")
            }
            .litheIconButton()
            .help("Show in Finder")
            Button {
                model.closeMediaDocument(media)
            } label: {
                Image(systemName: "xmark")
            }
            .litheIconButton()
            .help("Close")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(LitheTheme.toolHeader)
    }
}

/// Uses AppKit's image scrolling surface so trackpad panning and pinch zooming
/// remain native and do not rebuild the surrounding editor during live gestures.
private struct MediaImageScrollView: NSViewRepresentable {
    let image: NSImage
    let imageID: UUID
    @Binding var scale: CGFloat?
    let targetScale: CGFloat
    let minimumScale: CGFloat
    let maximumScale: CGFloat
    let contentPadding: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(scale: $scale)
    }

    func makeNSView(context: Context) -> NativeImageScrollView {
        let scrollView = NativeImageScrollView()
        scrollView.onMagnificationEnded = context.coordinator.commitMagnification
        scrollView.configure(
            image: image,
            imageID: imageID,
            contentPadding: contentPadding
        )
        scrollView.updateMagnificationRange(
            minimum: minimumScale,
            maximum: maximumScale
        )
        scrollView.applyMagnification(targetScale, centerOnImage: true)
        return scrollView
    }

    func updateNSView(_ scrollView: NativeImageScrollView, context: Context) {
        context.coordinator.scale = $scale
        scrollView.onMagnificationEnded = context.coordinator.commitMagnification

        let imageChanged = scrollView.configure(
            image: image,
            imageID: imageID,
            contentPadding: contentPadding
        )
        scrollView.updateMagnificationRange(
            minimum: minimumScale,
            maximum: maximumScale
        )
        scrollView.applyMagnification(
            targetScale,
            centerOnImage: imageChanged
        )
    }

    final class Coordinator {
        var scale: Binding<CGFloat?>

        init(scale: Binding<CGFloat?>) {
            self.scale = scale
        }

        func commitMagnification(_ magnification: CGFloat) {
            if let currentScale = scale.wrappedValue,
               abs(currentScale - magnification) <= 0.001 {
                return
            }
            scale.wrappedValue = magnification
        }
    }
}

private final class NativeImageScrollView: NSScrollView {
    private let imageDocumentView = ImageDocumentView()
    private var representedImageID: UUID?
    private var isLiveMagnifying = false
    private var magnificationObservers: [NSObjectProtocol] = []
    var onMagnificationEnded: ((CGFloat) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        allowsMagnification = true
        contentView = CenteringClipView()
        documentView = imageDocumentView
        imageDocumentView.wantsLayer = true
        imageDocumentView.layer?.backgroundColor = NSColor.clear.cgColor
        installMagnificationObservers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        for observer in magnificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    @discardableResult
    func configure(
        image: NSImage,
        imageID: UUID,
        contentPadding: CGFloat
    ) -> Bool {
        guard representedImageID != imageID else { return false }
        representedImageID = imageID
        imageDocumentView.configure(image: image, contentPadding: contentPadding)
        contentView.scroll(to: imageDocumentView.bounds.origin)
        reflectScrolledClipView(contentView)
        return true
    }

    func updateMagnificationRange(minimum: CGFloat, maximum: CGFloat) {
        let validMinimum = max(0.001, minimum)
        let validMaximum = max(validMinimum, maximum)
        if abs(minMagnification - validMinimum) > 0.001 {
            minMagnification = validMinimum
        }
        if abs(maxMagnification - validMaximum) > 0.001 {
            maxMagnification = validMaximum
        }
    }

    func applyMagnification(_ value: CGFloat, centerOnImage: Bool) {
        guard !isLiveMagnifying else { return }
        let clamped = min(max(value, minMagnification), maxMagnification)
        guard abs(magnification - clamped) > 0.001 else { return }
        let center = centerOnImage
            ? NSPoint(x: imageDocumentView.bounds.midX, y: imageDocumentView.bounds.midY)
            : NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        setMagnification(clamped, centeredAt: center)
    }

    private func installMagnificationObservers() {
        let center = NotificationCenter.default
        magnificationObservers = [
            center.addObserver(
                forName: NSScrollView.willStartLiveMagnifyNotification,
                object: self,
                queue: .main
            ) { [weak self] _ in
                self?.isLiveMagnifying = true
            },
            center.addObserver(
                forName: NSScrollView.didEndLiveMagnifyNotification,
                object: self,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                isLiveMagnifying = false
                onMagnificationEnded?(magnification)
            }
        ]
    }
}

private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrainedBounds = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return constrainedBounds }

        if proposedBounds.width > documentView.frame.width {
            constrainedBounds.origin.x = (documentView.frame.width - proposedBounds.width) / 2
        }
        if proposedBounds.height > documentView.frame.height {
            constrainedBounds.origin.y = (documentView.frame.height - proposedBounds.height) / 2
        }
        return constrainedBounds
    }
}

private final class ImageDocumentView: NSView {
    private let imageView = NSImageView()
    private var dragStartLocation: NSPoint?
    private var dragStartOrigin: NSPoint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageView.imageScaling = .scaleNone
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(image: NSImage, contentPadding: CGFloat) {
        imageView.image = image
        imageView.frame = NSRect(
            x: contentPadding,
            y: contentPadding,
            width: image.size.width,
            height: image.size.height
        )
        frame.size = NSSize(
            width: image.size.width + contentPadding * 2,
            height: image.size.height + contentPadding * 2
        )
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard let scrollView = enclosingScrollView else {
            super.mouseDown(with: event)
            return
        }
        dragStartLocation = event.locationInWindow
        dragStartOrigin = scrollView.contentView.bounds.origin
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let scrollView = enclosingScrollView,
              let dragStartLocation,
              let dragStartOrigin else { return }
        let location = event.locationInWindow
        let magnification = max(scrollView.magnification, 0.001)
        let proposedOrigin = NSPoint(
            x: dragStartOrigin.x - (location.x - dragStartLocation.x) / magnification,
            y: dragStartOrigin.y - (location.y - dragStartLocation.y) / magnification
        )
        let proposedBounds = NSRect(origin: proposedOrigin, size: scrollView.contentView.bounds.size)
        let constrainedBounds = scrollView.contentView.constrainBoundsRect(proposedBounds)
        scrollView.contentView.scroll(to: constrainedBounds.origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    override func mouseUp(with event: NSEvent) {
        dragStartLocation = nil
        dragStartOrigin = nil
        NSCursor.openHand.set()
    }
}
