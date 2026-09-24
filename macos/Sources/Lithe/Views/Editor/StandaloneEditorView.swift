import SwiftUI

struct StandaloneEditorView: View {
    @EnvironmentObject private var model: AppModel
    @State private var svgViewMode: DocumentPreviewMode = .split
    @State private var htmlViewMode: DocumentPreviewMode = .split

    var body: some View {
        let closeConfirmationID = model.pendingCloseConfirmationID
        let encodingRequest = model.pendingEncodingReopen
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(LitheTheme.divider)
                .frame(height: 1)

            content
        }
        .background(LitheTheme.editor)
        .background(GoToLineDialogPresenter())
        .confirmationDialog(
            "Save changes before closing?",
            isPresented: Binding(
                get: { model.pendingCloseDocument != nil },
                set: { if !$0 { model.dismissPendingCloseConfirmation(closeConfirmationID) } }
            ),
            titleVisibility: .visible
        ) {
            Button("Save") { model.closePendingDocument(discardingChanges: false) }
            Button("Discard Changes", role: .destructive) {
                model.closePendingDocument(discardingChanges: true)
            }
            Button("Cancel", role: .cancel) { model.cancelPendingClose() }
        } message: {
            Text(model.pendingCloseDocument?.url.lastPathComponent ?? "")
        }
        .confirmationDialog(
            "Save changes before reopening with \(encodingRequest?.encoding.displayName ?? "this encoding")?",
            isPresented: Binding(
                get: { encodingRequest != nil },
                set: { if !$0 { model.dismissPendingEncodingReopen(encodingRequest?.id) } }
            ),
            titleVisibility: .visible
        ) {
            Button("Save") { model.resolvePendingEncodingReopen(saveChanges: true) }
            Button("Discard Changes", role: .destructive) {
                model.resolvePendingEncodingReopen(saveChanges: false)
            }
            Button("Cancel", role: .cancel) { model.cancelEncodingChange() }
        } message: {
            Text(encodingRequest?.document.url.lastPathComponent ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let media = model.activeMediaDocument {
            MediaViewerView(media: media)
        } else {
            textContent
        }
    }

    @ViewBuilder
    private var textContent: some View {
        switch model.standaloneFileLoadState {
        case .idle, .loading:
            ProgressView("Opening file…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            if let document = model.activeDocument {
                if document.url.pathExtension.lowercased() == "svg" {
                    switch svgViewMode {
                    case .editor:
                        editor(document)
                    case .split:
                        SVGEditorSplitView(editor: editor(document), document: document)
                    case .preview:
                        SVGPreviewView(document: document)
                    }
                } else if ["html", "htm"].contains(document.url.pathExtension.lowercased()) {
                    switch htmlViewMode {
                    case .editor:
                        editor(document)
                    case .split:
                        HStack(spacing: 0) {
                            editor(document)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            HTMLPreviewView(document: document)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    case .preview:
                        HTMLPreviewView(document: document)
                    }
                } else {
                    editor(document)
                }
            } else {
                failureView(.readFailed)
            }
        case let .failed(failure):
            failureView(failure)
        }
    }

    private func editor(_ document: EditorDocument) -> some View {
        MonacoWorkbenchEditor(document: document)
            .overlay(alignment: .top) {
                if model.isFindBarVisible {
                    FindBarView()
                }
            }
            .overlay(alignment: .topTrailing) {
                EditorSoftWrapToggle()
                    .padding(.top, 8)
                    .padding(.trailing, 10)
            }
    }

    private func failureView(_ failure: StandaloneFileOpenFailure) -> some View {
        VStack(spacing: 10) {
            LitheSystemIcon(systemImage: "doc.text.magnifyingglass")
                .font(.system(size: 26))
                .foregroundStyle(LitheTheme.secondaryText)
            Text(failure.title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(LitheTheme.primaryText)
            Text(failure.detail)
                .font(.system(size: 12))
                .foregroundStyle(LitheTheme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 8) {
                Button("Try Again") {
                    if let url = model.standaloneFileURL {
                        model.openStandaloneFile(url)
                    }
                }
                .buttonStyle(LitheSecondaryButtonStyle())
                Button("Close File") {
                    model.closeStandaloneFile()
                }
                .buttonStyle(LithePrimaryButtonStyle())
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let document = model.activeDocument {
                LitheIcon(
                    kind: LitheIcons.kind(for: document.url, isDirectory: false),
                    size: 14
                )
                Text(document.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LitheTheme.primaryText)
                    .lineLimit(1)
                if document.isDirty {
                    Circle()
                        .fill(LitheTheme.accent)
                        .frame(width: 6, height: 6)
                }
                Spacer()
                Menu {
                    Section("Reopen with Encoding") {
                        ForEach(DocumentEncoding.catalog.filter(\.supportsRead), id: \.id) { descriptor in
                            let encoding = descriptor.id
                            Button {
                                model.reopenDocument(document, with: encoding)
                            } label: {
                                HStack {
                                    Text(descriptor.displayName)
                                    if document.readEncoding == encoding { Spacer(); Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                    Divider()
                    Section("Save with Encoding") {
                        ForEach(DocumentEncoding.catalog.filter(\.supportsWrite), id: \.id) { descriptor in
                            let encoding = descriptor.id
                            Button {
                                model.saveDocument(document, encoding: encoding)
                            } label: {
                                HStack {
                                    Text(descriptor.displayName)
                                    if document.saveEncoding == encoding { Spacer(); Image(systemName: "checkmark") }
                                }
                            }
                            .disabled(document.isReadOnly)
                        }
                    }
                } label: {
                    Text(document.readEncoding.displayName)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("File encoding")
                if document.url.pathExtension.lowercased() == "svg" {
                    Picker("SVG view mode", selection: $svgViewMode) {
                        ForEach(DocumentPreviewMode.allCases) { mode in
                            Image(systemName: mode.symbolName)
                                .help(mode.title)
                                .accessibilityLabel(mode.title)
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 104)
                } else if ["html", "htm"].contains(document.url.pathExtension.lowercased()) {
                    Picker("HTML view mode", selection: $htmlViewMode) {
                        ForEach(DocumentPreviewMode.allCases) { mode in
                            Image(systemName: mode.symbolName)
                                .help(mode.title)
                                .accessibilityLabel(mode.title)
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 104)
                }
                Text(document.url.path)
                    .font(.system(size: 10.5))
                    .foregroundStyle(LitheTheme.tertiaryText)
                    .lineLimit(1)
            } else {
                Text(model.standaloneFileURL?.lastPathComponent ?? "Opening file…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(LitheTheme.toolHeader)
    }
}
