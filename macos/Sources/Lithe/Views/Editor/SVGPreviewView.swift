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
    @State private var imageData = Data()
    @State private var imageRevision = 0
    @State private var media: MediaDocument?

    var body: some View {
        Group {
            if let media {
                MediaViewerView(
                    media: media,
                    imageData: imageData,
                    imageRevision: imageRevision,
                    showsFileActions: false
                )
            }
        }
        .onAppear {
            media = MediaDocument(url: document.url, kind: .image)
            updatePreview()
        }
        .onChange(of: document.url) { _ in
            media = MediaDocument(url: document.url, kind: .image)
            updatePreview()
        }
        .onReceive(document.textDidChange.debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)) { _ in
            updatePreview()
        }
    }

    private func updatePreview() {
        imageData = Data(document.text.utf8)
        imageRevision += 1
    }
}
