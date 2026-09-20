import Combine
import SwiftUI

struct HTMLPreviewView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var document: EditorDocument
    @StateObject private var content: HTMLPreviewContent

    init(document: EditorDocument) {
        self.document = document
        _content = StateObject(wrappedValue: HTMLPreviewContent(document: document))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HTMLPreviewWebView(
                payload: .init(
                    html: content.html,
                    documentURL: document.url
                )
            )

            Button {
                model.platformUI.open(document.url)
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(LitheTheme.secondaryText)
            .background(LitheTheme.toolHeader.opacity(0.92))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(LitheTheme.divider, lineWidth: 1)
            }
            .help("Open HTML in Browser")
            .accessibilityLabel("Open HTML in Browser")
            .padding(.top, 8)
            .padding(.trailing, 10)
        }
        .background(LitheTheme.editor)
        .onAppear { content.observe(document) }
        .onChange(of: document.id) { _ in content.observe(document) }
        .onChange(of: document.url) { _ in content.observe(document) }
        .onDisappear { content.stopObserving() }
    }
}

/// Debounces live editor changes before reloading the static WebKit document.
@MainActor
private final class HTMLPreviewContent: ObservableObject {
    @Published private(set) var html: String
    private var changes: AnyCancellable?

    init(document: EditorDocument) {
        html = document.text
    }

    func observe(_ document: EditorDocument) {
        stopObserving()
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
