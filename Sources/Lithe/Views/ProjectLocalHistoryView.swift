import SwiftUI

struct ProjectLocalHistoryView: View {
    @EnvironmentObject private var model: AppModel
    let request: ProjectLocalHistoryRequest
    @State private var isRestoreConfirmationPresented = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            HStack(spacing: 0) {
                historyList
                    .frame(width: 350)
                Rectangle().fill(LitheTheme.divider).frame(width: 1)
                comparison
            }
        }
        .frame(minWidth: 1120, minHeight: 680)
        .background(LitheTheme.window)
        .confirmationDialog(
            "Restore this project version?",
            isPresented: $isRestoreConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Restore") {
                Task { await model.restoreSelectedProjectLocalHistoryEntry() }
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
            Text("Project Local History")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)
            Text(model.projectName)
                .font(.system(size: 12))
                .foregroundStyle(LitheTheme.secondaryText)
            Spacer()
            Button {
                Task { await model.refreshProjectLocalHistory() }
            } label: {
                LitheSystemIcon(systemImage: "arrow.clockwise")
            }
            .litheIconButton()
            .help("Refresh project history")
            Button("Restore") {
                isRestoreConfirmationPresented = true
            }
            .buttonStyle(.borderedProminent)
            .lithePointer()
            .tint(LitheTheme.accent)
            .controlSize(.small)
            .disabled(model.selectedProjectLocalHistoryEntry == nil)
            Button {
                model.projectLocalHistoryRequest = nil
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
                Text("Project changes")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)
                Spacer()
                Text("\(model.projectLocalHistoryEntries.count)")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(LitheTheme.sidebar)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            if model.isLoadingProjectLocalHistory, model.projectLocalHistoryEntries.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.projectLocalHistoryEntries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.badge.questionmark")
                        .font(.system(size: 28, weight: .light))
                    Text("No project history recorded yet")
                }
                .font(LitheTheme.uiFont)
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.projectLocalHistoryEntries) { entry in
                            Button {
                                model.selectProjectLocalHistoryEntry(entry)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.relativePath)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(LitheTheme.primaryText)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    HStack(spacing: 6) {
                                        Text(entry.reason.title)
                                        Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                                        Text(ByteCountFormatter.string(fromByteCount: Int64(entry.byteCount), countStyle: .file))
                                    }
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(LitheTheme.secondaryText)
                                    .lineLimit(1)
                                }
                                .padding(.horizontal, 12)
                                .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                                .background(
                                    model.selectedProjectLocalHistoryEntry?.id == entry.id
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

            if model.isLoadingProjectLocalHistory {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.selectedProjectLocalHistoryEntry == nil {
                Text("Select a project history entry")
                    .font(LitheTheme.uiFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.projectLocalHistoryDiffRows.isEmpty {
                Text("No textual difference")
                    .font(LitheTheme.uiFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    let contentWidth = max(900, geometry.size.width)
                    let kinds = model.projectLocalHistoryDiffRows.map(\.kind)
                    let contentHeight = max(
                        DiffLayoutMetrics.contentHeight(rows: model.projectLocalHistoryDiffRows, kinds: kinds),
                        geometry.size.height
                    )

                    ScrollView([.vertical, .horizontal]) {
                        ZStack(alignment: .topLeading) {
                            DiffConnectorOverlay(
                                rows: model.projectLocalHistoryDiffRows,
                                kinds: kinds,
                                contentWidth: contentWidth
                            )

                            LazyVStack(spacing: 0) {
                                ForEach(model.projectLocalHistoryDiffRows) { row in
                                    DiffRowView(
                                        row: row,
                                        kind: row.kind,
                                        fileExtension: selectedFileExtension,
                                        highlightsWords: true,
                                        isSelectedDifference: false
                                    )
                                }
                            }
                            .textSelection(.enabled)
                        }
                        .frame(width: contentWidth, height: contentHeight, alignment: .topLeading)
                    }
                }
            }
        }
        .background(LitheTheme.editor)
    }

    private var selectedFileExtension: String {
        model.selectedProjectLocalHistoryEntry?.relativePath.split(separator: ".").last.map(String.init) ?? ""
    }

    private func versionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 10.5))
                .foregroundStyle(LitheTheme.secondaryText)
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(LitheTheme.primaryText)
            if title == "Historical version",
               let entry = model.selectedProjectLocalHistoryEntry {
                Text(entry.relativePath)
                    .font(.system(size: 10.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .background(LitheTheme.window)
    }
}
