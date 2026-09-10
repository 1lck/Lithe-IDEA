import Combine
import SwiftUI

struct SVGEditorSplitView<Editor: View>: View {
    let editor: Editor
    let document: EditorDocument

    var body: some View {
        GeometryReader { geometry in
            let available = max(0, geometry.size.width - SplitHandleView.thickness)
            let minimum = min(200, available / 2)
            LitheSplitPaneView(
                axis: .horizontal,
                placement: .leading,
                defaultSize: available / 2,
                minimum: minimum,
                maximum: max(minimum, available - minimum),
                flexibleMinimum: minimum,
                sized: { editor },
                flexible: { SVGPreviewView(document: document) }
            )
        }
    }
}

struct SVGPreviewView: View {
    @ObservedObject var document: EditorDocument
    @StateObject private var content: SVGPreviewContent

    init(document: EditorDocument) {
        self.document = document
        _content = StateObject(wrappedValue: SVGPreviewContent(document: document))
    }

    var body: some View {
        // Always mount a concrete viewer. An empty conditional Group cannot
        // bootstrap itself with onAppear and collapses the editor layout.
        MediaViewerView(
            media: content.media,
            imageData: content.imageData,
            imageRevision: content.imageRevision,
            showsFileActions: false
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { content.observe(document) }
        .onChange(of: document.id) { _ in content.observe(document) }
        .onChange(of: document.url) { _ in content.observe(document) }
        .onDisappear { content.stopObserving() }
    }
}

/// Owns preview-only invalidation and a stable debounce subscription across view updates.
@MainActor
private final class SVGPreviewContent: ObservableObject {
    @Published private(set) var imageData: Data
    private(set) var media: MediaDocument
    private(set) var imageRevision = 0
    private var changes: AnyCancellable?

    init(document: EditorDocument) {
        imageData = Data(document.text.utf8)
        media = MediaDocument(url: document.url, kind: .image)
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
        if media.url != document.url {
            media = MediaDocument(url: document.url, kind: .image)
        }
        imageRevision += 1
        imageData = Data(document.text.utf8)
    }
}
