import SwiftUI
import LitheLocalHistoryModule

struct LocalHistoryView: View {
    @EnvironmentObject private var model: AppModel
    let request: LocalHistoryRequest
    /// Family for the comparison text. Defaults to the bundled monospaced family
    /// so the sheet keeps rendering without a required `AppSettings` environment
    /// object; the presenting root view passes the configured family explicitly.
    var fontFamily: String = EditorFontDefaults.monospacedFamily
    @State private var isRestoreConfirmationPresented = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            HStack(spacing: 0) {
                historyList
                    .frame(width: 290)
                Rectangle().fill(LitheTheme.divider).frame(width: 1)
                comparison
            }
        }
        .frame(minWidth: 980, minHeight: 620)
        .background(LitheTheme.window)
        .confirmationDialog(
            "Restore this version?",
            isPresented: $isRestoreConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Restore") {
                Task { await model.restoreSelectedLocalHistoryEntry() }
            }
            .lithePointer()
            Button("Cancel", role: .cancel) {}
                .lithePointer()
        } message: {
            Text("The current file will be saved to Local History before it is replaced.")
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(LitheTheme.accent)
            Text("Local History")
                .font(LitheTheme.uiFont(size: 13, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)
            Text(request.fileURL.lastPathComponent)
                .font(LitheTheme.uiFont(size: 12))
                .foregroundStyle(LitheTheme.secondaryText)
            Spacer()
            Button {
                Task { await model.refreshLocalHistory() }
            } label: {
                LitheSystemIcon(systemImage: "arrow.clockwise")
            }
            .litheIconButton()
            .help("Refresh local history")
            Button("Restore") {
                isRestoreConfirmationPresented = true
            }
            .buttonStyle(LitheActionButtonStyle(isPrimary: true))
            .lithePointer()
            .tint(LitheTheme.accent)
            .disabled(model.selectedLocalHistoryEntry == nil)
            Button {
                model.localHistoryRequest = nil
            } label: {
                Image(systemName: "xmark")
            }
            .litheIconButton()
            .help("Close")
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(LitheTheme.toolHeader)
    }

    private var historyList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Changes")
                    .font(LitheTheme.uiFont(size: 11.5, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)
                Spacer()
                Text("\(model.localHistoryEntries.count)")
                    .font(LitheTheme.uiFont(size: 10.5, weight: .medium))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(LitheTheme.sidebar)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            if model.isLoadingLocalHistory, model.localHistoryEntries.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.localHistoryEntries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.badge.questionmark")
                        .font(LitheTheme.uiFont(size: 28, weight: .light))
                    Text("No history recorded yet")
                }
                .font(LitheTheme.uiFont)
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LitheTreeList(
                    model.localHistoryEntries,
                    selection: Binding(
                        get: { model.selectedLocalHistoryEntry?.id },
                        set: { id in
                            if let entry = model.localHistoryEntries.first(where: { $0.id == id }) {
                                model.selectLocalHistoryEntry(entry)
                            }
                        }), multiline: true
                ) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizedStringKey(entry.reason.title))
                            .font(LitheTheme.uiFont(size: 12, weight: .medium))
                            .foregroundStyle(LitheTheme.primaryText)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                            Text(ByteCountFormatter.string(fromByteCount: Int64(entry.byteCount), countStyle: .file))
                        }
                        .font(LitheTheme.uiFont(size: 10.5))
                        .foregroundStyle(LitheTheme.secondaryText)
                    }
                    .padding(.horizontal, LitheTheme.Tree.iconTextGap)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                }
            }
        }
        .background(LitheTheme.sidebar)
    }

    private var comparison: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                versionHeader("Historical version", icon: "clock")
                Rectangle().fill(LitheTheme.divider).frame(width: 1)
                versionHeader("Current version", icon: "doc.text")
            }
            .frame(height: 34)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            if model.isLoadingLocalHistory {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.selectedLocalHistoryEntry == nil {
                Text("Select a history entry")
                    .font(LitheTheme.uiFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DiffPaneView(
                    rows: model.localHistoryDiffRows,
                    fileExtension: request.fileURL.pathExtension,
                    minimumWidth: 860,
                    fontFamily: fontFamily
                )
            }
        }
        .background(LitheTheme.editor)
    }

    private func versionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(LitheTheme.uiFont(size: 10.5))
                .foregroundStyle(LitheTheme.secondaryText)
            Text(LocalizedStringKey(title))
                .font(LitheTheme.uiFont(size: 11.5, weight: .medium))
                .foregroundStyle(LitheTheme.primaryText)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .background(LitheTheme.window)
    }
}
