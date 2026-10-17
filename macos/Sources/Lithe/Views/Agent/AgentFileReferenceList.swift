import AppKit
import SwiftUI
import LitheAgentConversationModule

struct AgentFileReferenceList: View {
    @Environment(\.locale) private var locale
    let files: [AgentFileReference]
    let onRemove: (String) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(files) { file in
                    HStack(spacing: 5) {
                        AgentFileReferenceIcon(url: file.url)
                        Text(file.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: 160)
                        Button { onRemove(file.id) } label: {
                            Image(systemName: "xmark").font(LitheTheme.uiFont(size: 9))
                        }
                        .buttonStyle(.litheNoPress)
                        .accessibilityLabel(String(format: AgentLocalization.string("Remove file %@", locale: locale), file.name))
                    }
                    .font(LitheTheme.uiFont(size: 11))
                    .foregroundStyle(AgentPanelStyle.text)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(AgentPanelStyle.context, in: RoundedRectangle(cornerRadius: 5))
                    .help(file.url.path)
                }
            }
            .padding(.horizontal, 8)
        }
        .scrollIndicators(.hidden)
        .frame(height: AgentComposerMetrics.fileHeight)
    }
}

/// Image attachments show a thumbnail so a pasted screenshot is recognizable.
private struct AgentFileReferenceIcon: View {
    let url: URL
    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Image(systemName: isImage ? "photo" : "doc")
            }
        }
        .task(id: url) {
            guard isImage else { return }
            let url = url
            thumbnail = await Task.detached(priority: .utility) { NSImage(contentsOf: url) }.value
        }
    }

    private var isImage: Bool { AgentPastedImage.previewExtensions.contains(url.pathExtension.lowercased()) }
}
