import Foundation
import SwiftUI

enum MarkdownPreviewDebounce {
    static func nanoseconds(forByteCount byteCount: Int) -> UInt64 {
        switch byteCount {
        case ..<16_384:
            120_000_000
        case ..<131_072:
            220_000_000
        default:
            360_000_000
        }
    }
}

struct MarkdownPreviewView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var document: EditorDocument
    var scrollPosition: Binding<MarkdownScrollPosition>? = nil
    @State private var html = ""
    @State private var errorMessage: String?
    @State private var isInitialRender = true
    @State private var renderTask: Task<Void, Never>?
    @State private var requestedRevision = 0

    var body: some View {
        ZStack {
            MarkdownPreviewWebView(
                payload: .init(
                    html: html,
                    documentURL: document.url,
                    workspaceURL: model.workspaceURL,
                    appearance: colorScheme == .dark ? "dark" : "light"
                ),
                scrollPosition: scrollPosition
            )

            if isInitialRender {
                ProgressView()
                    .controlSize(.small)
                    .padding(12)
                    .background(LitheTheme.editor.opacity(0.92))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else if let errorMessage {
                VStack(spacing: 9) {
                    Text("Preview unavailable")
                        .font(.system(size: 13, weight: .semibold))
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                    Button("Retry") {
                        scheduleRender(immediate: true)
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12))
                }
                .padding(16)
                .frame(maxWidth: 360)
                .background(LitheTheme.editor.opacity(0.96))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(LitheTheme.divider, lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
        }
        .background(LitheTheme.editor)
        .onAppear {
            scheduleRender(immediate: true)
        }
        .onChange(of: document.text) { _, _ in
            scheduleRender(immediate: false)
        }
        .onChange(of: document.url) { _, _ in
            scheduleRender(immediate: true)
        }
        .onDisappear {
            renderTask?.cancel()
        }
    }

    private func scheduleRender(immediate: Bool) {
        renderTask?.cancel()
        requestedRevision &+= 1
        let revision = requestedRevision
        let source = document.text
        let delay = immediate ? 0 : MarkdownPreviewDebounce.nanoseconds(forByteCount: source.utf8.count)

        renderTask = Task { @MainActor in
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled, revision == requestedRevision else { return }
            do {
                let rendered = try await model.renderMarkdown(source)
                guard !Task.isCancelled, revision == requestedRevision else { return }
                html = rendered.html
                errorMessage = nil
                isInitialRender = false
            } catch {
                guard !Task.isCancelled, revision == requestedRevision else { return }
                errorMessage = error.localizedDescription
                isInitialRender = false
            }
        }
    }
}
