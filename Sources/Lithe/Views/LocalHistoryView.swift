import SwiftUI

struct LocalHistoryView: View {
    @EnvironmentObject private var model: AppModel
    let request: LocalHistoryRequest
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
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)
            Text(request.fileURL.lastPathComponent)
                .font(.system(size: 12))
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
            .buttonStyle(.borderedProminent)
            .lithePointer()
            .tint(LitheTheme.accent)
            .controlSize(.small)
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
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)
                Spacer()
                Text("\(model.localHistoryEntries.count)")
                    .font(.system(size: 10.5, weight: .medium))
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
                        .font(.system(size: 28, weight: .light))
                    Text("No history recorded yet")
                }
                .font(LitheTheme.uiFont)
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.localHistoryEntries) { entry in
                            Button {
                                model.selectLocalHistoryEntry(entry)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(LocalizedStringKey(entry.reason.title))
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(LitheTheme.primaryText)
                                        .lineLimit(1)
                                    HStack(spacing: 6) {
                                        Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                                        Text(ByteCountFormatter.string(fromByteCount: Int64(entry.byteCount), countStyle: .file))
                                    }
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(LitheTheme.secondaryText)
                                }
                                .padding(.horizontal, 12)
                                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                                .background(
                                    model.selectedLocalHistoryEntry?.id == entry.id
                                        ? LitheTheme.selection
                                        : Color.clear
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .lithePointer()
                        }
                    }
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
                GeometryReader { geometry in
                    let width = max(860, geometry.size.width)
                    let kinds = model.localHistoryDiffRows.map(\.kind)
                    let contentHeight = max(
                        DiffLayoutMetrics.contentHeight(rows: model.localHistoryDiffRows, kinds: kinds),
                        geometry.size.height
                    )
                    ScrollView(.horizontal) {
                        ScrollView(.vertical) {
                            ZStack(alignment: .topLeading) {
                                DiffConnectorOverlay(
                                    rows: model.localHistoryDiffRows,
                                    kinds: kinds,
                                    contentWidth: width
                                )

                                LazyVStack(spacing: 0) {
                                    ForEach(model.localHistoryDiffRows) { row in
                                        DiffRowView(
                                            row: row,
                                            kind: row.kind,
                                            fileExtension: request.fileURL.pathExtension,
                                            highlightsWords: true,
                                            isSelectedDifference: false
                                        )
                                    }
                                }
                                .textSelection(.enabled)
                            }
                            .frame(width: width, height: contentHeight, alignment: .topLeading)
                        }
                        .frame(width: width, height: geometry.size.height, alignment: .topLeading)
                    }
                }
            }
        }
        .background(LitheTheme.editor)
    }

    private func versionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 10.5))
                .foregroundStyle(LitheTheme.secondaryText)
            Text(LocalizedStringKey(title))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(LitheTheme.primaryText)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .background(LitheTheme.window)
    }
}
