import SwiftUI

struct StandaloneEditorView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editorViewportStore = EditorViewportStore()

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(LitheTheme.divider)
                .frame(height: 1)

            content
        }
        .background(LitheTheme.editor)
        .confirmationDialog(
            "Save changes before closing?",
            isPresented: Binding(
                get: { model.pendingCloseDocument != nil },
                set: { if !$0 { model.cancelPendingClose() } }
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
    }

    @ViewBuilder
    private var content: some View {
        switch model.standaloneFileLoadState {
        case .idle, .loading:
            ProgressView("Opening file…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            if let document = model.activeDocument {
                CodeEditorView(
                    document: document,
                    shouldFocus: true,
                    viewportStore: editorViewportStore
                )
                    .overlay(alignment: .top) {
                        if model.isFindBarVisible {
                            FindBarView()
                                .padding(.top, 10)
                                .padding(.horizontal, 12)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        GoToLineBarOverlay()
                    }
            } else {
                failureView(.readFailed)
            }
        case let .failed(failure):
            failureView(failure)
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
