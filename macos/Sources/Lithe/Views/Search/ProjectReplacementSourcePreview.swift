import AppKit
import SwiftUI
import LitheSearchModule

typealias SourcePreviewEditorBuilder = (EditorDocument, MonacoPreviewConfiguration) -> AnyView

enum SourcePreviewEditorContent {
    static func monaco(_ document: EditorDocument, _ configuration: MonacoPreviewConfiguration) -> AnyView {
        AnyView(MonacoWorkbenchEditor(document: document, preview: configuration))
    }
}

/// Reuses open documents and promotes transient previews on their first edit.
struct ProjectReplacementSourcePreview: View {
    let file: ProjectReplacementFile
    let line: Int
    let query: String
    let options: ProjectSearchOptions
    let loadDocument: (URL) async -> EditorDocument?
    let onEdit: () -> Void
    var makeEditor: SourcePreviewEditorBuilder = SourcePreviewEditorContent.monaco
    @State private var document: EditorDocument?
    @State private var isLoading = true

    var body: some View {
        Group {
            if let document {
                ProjectReplacementDocumentEditor(document: document, file: file, line: line, query: query, options: options, onEdit: onEdit, makeEditor: makeEditor)
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
    let onEdit: () -> Void
    var makeEditor: SourcePreviewEditorBuilder = SourcePreviewEditorContent.monaco
    @State private var saveError: String?
    @State private var saveTask: Task<Void, Never>?

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
                    guard saveTask == nil else { return }
                    saveTask = Task { @MainActor in
                        guard !Task.isCancelled else { return }
                        defer { if !Task.isCancelled { saveTask = nil } }
                        do {
                            try await model.saveDocument(document)
                            guard !Task.isCancelled else { return }
                            saveError = nil
                        } catch {
                            guard !Task.isCancelled else { return }
                            saveError = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(saveTask != nil || !document.isDirty || document.isReadOnly)
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
            makeEditor(document, MonacoPreviewConfiguration(
                line: line, query: query, matchCase: options.caseSensitive,
                wholeWord: options.wholeWords && !options.regularExpression, regex: options.regularExpression))
                .environmentObject(model.editorDiagnosticsStore)
                .clipped()
        }
        .onReceive(document.textDidChange) {
            // Promote the first edit so closing the dialog preserves unsaved changes.
            if document.isDirty { model.documentFeature.promotePreviewDocument(document) }
            onEdit()
        }
        .onDisappear { saveTask?.cancel(); saveTask = nil }
        .onChange(of: document.id) { _ in
            saveTask?.cancel()
            saveTask = nil
            saveError = nil
        }
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
