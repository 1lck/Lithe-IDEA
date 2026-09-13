import AppKit
import SwiftUI
import LitheSearchModule

/// Edits the same managed document used by the main editor.
struct ProjectReplacementSourcePreview: View {
    let file: ProjectReplacementFile
    let line: Int
    let query: String
    let options: ProjectSearchOptions
    let loadDocument: (URL) async -> EditorDocument?
    @State private var document: EditorDocument?
    @State private var isLoading = true

    var body: some View {
        Group {
            if let document {
                ProjectReplacementDocumentEditor(document: document, file: file, line: line, query: query, options: options)
            } else {
                VStack {
                    if isLoading { ProgressView() }
                    else { Text("Could not load file preview") }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(LitheTheme.editor)
        .task(id: file.id) {
            let loaded = await loadDocument(file.url)
            guard !Task.isCancelled else { return }
            document = loaded
            isLoading = false
        }
    }
}

private struct ProjectReplacementDocumentEditor: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var document: EditorDocument
    let file: ProjectReplacementFile
    let line: Int
    let query: String
    let options: ProjectSearchOptions
    @StateObject private var chrome = EditorChromeModel()
    @State private var viewportStore = EditorViewportStore()
    @State private var saveError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(file.url.lastPathComponent)
                    .foregroundStyle(LitheTheme.primaryText)
                Text((file.relativePath as NSString).deletingLastPathComponent)
                    .foregroundStyle(LitheTheme.secondaryText)
                if document.isDirty { Text("•").accessibilityLabel("Unsaved changes") }
                Spacer()
                Button("Save") {
                    do { try model.saveDocument(document); saveError = nil }
                    catch { saveError = error.localizedDescription }
                }
                .buttonStyle(.plain)
                .disabled(!document.isDirty || document.isReadOnly)
            }
            .font(.system(size: 12))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 32)
            .background(LitheTheme.popupBackground)
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(LitheTheme.secondaryText)
            }
            CodeEditorView(document: document, shouldFocus: false, previewLine: line, viewportStore: viewportStore)
                .environmentObject(chrome)
                .environmentObject(model.editorDiagnosticsStore)
                .clipped()
        }
        .onAppear(perform: updateSearch)
        .onChange(of: query) { _ in updateSearch() }
        .onChange(of: options) { _ in updateSearch() }
    }

    private func updateSearch() {
        chrome.setFindBarVisible(true)
        chrome.setFindBarQuery(query)
        chrome.setFindOptions(FindInFileOptions(
            matchCase: options.caseSensitive,
            wholeWords: options.wholeWords && !options.regularExpression,
            regularExpression: options.regularExpression
        ))
    }
}

enum ProjectReplacementPreviewText {
    static func lines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
    }

    static func highlighted(
        _ text: String, query: String, options: ProjectSearchOptions,
        fileName: String? = nil, isDark: Bool = true
    ) -> AttributedString {
        let storage = NSTextStorage(string: text)
        if let fileName {
            SyntaxHighlighter.apply(
                to: storage, font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                fileName: fileName, fileExtension: (fileName as NSString).pathExtension, isDark: isDark
            )
        }
        let matcher = FindInFileMatcher(query: query, options: FindInFileOptions(
            matchCase: options.caseSensitive,
            wholeWords: options.wholeWords && !options.regularExpression,
            regularExpression: options.regularExpression
        ))
        for range in matcher.matchRanges(in: text as NSString) {
            storage.addAttributes([
                .backgroundColor: NSColor.systemYellow.withAlphaComponent(0.65),
                .foregroundColor: NSColor.black
            ], range: range)
        }
        // SwiftUI Text needs SwiftUI color attributes, rather than AppKit-only attributes.
        var result = AttributedString()
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, range, _ in
            var segment = AttributedString((text as NSString).substring(with: range))
            if let color = attributes[.foregroundColor] as? NSColor { segment.foregroundColor = Color(nsColor: color) }
            if let color = attributes[.backgroundColor] as? NSColor { segment.backgroundColor = Color(nsColor: color) }
            result += segment
        }
        return result
    }
}
