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
                    let renderedScale = imageScale ?? fitScale

                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .frame(
                                width: image.size.width * renderedScale,
                                height: image.size.height * renderedScale
                            )
                            .padding(imageContentPadding)
                            .frame(
                                minWidth: geometry.size.width,
                                minHeight: geometry.size.height,
                                alignment: .center
                            )
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
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
                    imageScale = max(0.25, currentImageScale - 0.25)
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
                    imageScale = min(4, currentImageScale + 0.25)
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
