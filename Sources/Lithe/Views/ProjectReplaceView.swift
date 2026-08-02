import SwiftUI

struct ProjectReplaceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var expandedPaths: Set<String> = []

    private var selectedFiles: [ProjectReplacementFile] {
        model.projectReplacementFiles.filter {
            model.selectedProjectReplacementPaths.contains($0.relativePath)
        }
    }

    private var selectedMatchCount: Int {
        selectedFiles.reduce(0) { $0 + $1.matchCount }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            controls
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            results
        }
        .frame(minWidth: 780, minHeight: 560)
        .background(LitheTheme.window)
        .onChange(of: model.projectReplaceQuery) {
            clearPreview()
        }
        .onChange(of: model.projectReplaceText) {
            clearPreview()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.left.arrow.right")
                .foregroundStyle(LitheTheme.accent)
            Text("Replace in Project")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)
            Spacer()
            Button {
                model.isProjectReplaceVisible = false
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

    private var controls: some View {
        VStack(spacing: 9) {
            HStack(spacing: 9) {
                TextField("Find", text: $model.projectReplaceQuery)
                    .textFieldStyle(.plain)
                    .litheSearchField()
                Image(systemName: "arrow.right")
                    .foregroundStyle(LitheTheme.secondaryText)
                TextField("Replace with", text: $model.projectReplaceText)
                    .textFieldStyle(.plain)
                    .litheSearchField()
            }

            HStack(spacing: 8) {
                Button {
                    Task { await model.previewProjectReplacement() }
                } label: {
                    Label("Preview", systemImage: "eye")
                }
                .buttonStyle(.borderedProminent)
                .lithePointer()
                .tint(LitheTheme.accent)
                .disabled(model.projectReplaceQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isLoadingProjectReplacement)

                Button {
                    let allSelected = model.selectedProjectReplacementPaths.count == model.projectReplacementFiles.count
                    model.selectedProjectReplacementPaths = allSelected
                        ? []
                        : Set(model.projectReplacementFiles.map(\.relativePath))
                } label: {
                    Text(model.selectedProjectReplacementPaths.count == model.projectReplacementFiles.count
                        ? "Clear Selection"
                        : "Select All")
                }
                .buttonStyle(.bordered)
                .lithePointer()
                .disabled(model.projectReplacementFiles.isEmpty)

                Spacer()

                if model.isLoadingProjectReplacement {
                    ProgressView()
                        .controlSize(.small)
                }
                Text("\(selectedFiles.count) files, \(selectedMatchCount) matches")
                    .font(.system(size: 11.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                Button("Apply") {
                    Task { await model.applyProjectReplacement() }
                }
                .buttonStyle(.borderedProminent)
                .lithePointer()
                .tint(LitheTheme.accent)
                .disabled(selectedFiles.isEmpty || model.isLoadingProjectReplacement)
            }
        }
        .padding(12)
        .background(LitheTheme.sidebar)
    }

    @ViewBuilder
    private var results: some View {
        if model.projectReplacementFiles.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 28, weight: .light))
                Text(model.projectReplaceQuery.isEmpty
                    ? "Enter text to preview project changes"
                    : "No replacement matches")
            }
            .font(LitheTheme.uiFont)
            .foregroundStyle(LitheTheme.secondaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.projectReplacementFiles) { file in
                        fileRow(file)
                        Rectangle().fill(LitheTheme.divider).frame(height: 1)
                    }
                }
            }
            .background(LitheTheme.editor)
        }
    }

    private func fileRow(_ file: ProjectReplacementFile) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { expandedPaths.contains(file.relativePath) },
                set: { expanded in
                    if expanded { expandedPaths.insert(file.relativePath) }
                    else { expandedPaths.remove(file.relativePath) }
                }
            )
        ) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(file.matches) { match in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Line \(match.line)  \(match.before)")
                            .foregroundStyle(LitheTheme.secondaryText)
                            .lineLimit(2)
                        Text("        \(match.after)")
                            .foregroundStyle(LitheTheme.primaryText)
                            .lineLimit(2)
                    }
                    .font(.system(size: 11.5, design: .monospaced))
                }
            }
            .padding(.leading, 28)
            .padding(.vertical, 5)
        } label: {
            HStack(spacing: 8) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { model.selectedProjectReplacementPaths.contains(file.relativePath) },
                        set: { selected in
                            if selected { model.selectedProjectReplacementPaths.insert(file.relativePath) }
                            else { model.selectedProjectReplacementPaths.remove(file.relativePath) }
                        }
                    )
                )
                .labelsHidden()
                .lithePointer()
                LitheSystemIcon(systemImage: "doc.text")
                    .foregroundStyle(LitheTheme.secondaryText)
                Text(file.relativePath)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(LitheTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text("\(file.matchCount) matches")
                    .font(.system(size: 11.5))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            .lithePointer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func clearPreview() {
        guard !model.projectReplacementFiles.isEmpty else { return }
        model.clearProjectReplacementPreview()
    }
}
