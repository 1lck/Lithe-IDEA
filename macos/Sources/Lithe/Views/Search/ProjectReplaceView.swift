import SwiftUI
import LitheSearchModule

struct ProjectReplaceView: View {
    @ObservedObject var feature: SearchFeatureModel
    @ObservedObject var session: SearchSessionFeatureModel
    let previewReplacement: (String, String, ProjectSearchOptions) async -> Void
    let applyReplacement: (String) async -> Void
    let close: () -> Void
    let openFile: (URL, String) -> Void
    let revealInFinder: (URL) -> Void
    let copyPath: (URL, Bool) -> Void
    @State private var expandedPaths: Set<String> = []
    @State private var query = ""
    @State private var replacement = ""
    @State private var options = ProjectSearchOptions.default

    private var selectedFiles: [ProjectReplacementFile] {
        feature.projectReplacementFiles.filter {
            session.selectedReplacementPaths.contains($0.relativePath)
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
        .onAppear {
            query = session.replacementQuery
            replacement = session.replacementText
            options = session.replacementOptions
        }
        .onChange(of: query) { _ in
            clearPreview()
        }
        .onChange(of: replacement) { _ in
            clearPreview()
        }
        .onChange(of: options) { _ in
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
                close()
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
                TextField("Find", text: $query)
                    .textFieldStyle(.plain)
                    .litheSearchField()
                Image(systemName: "arrow.right")
                    .foregroundStyle(LitheTheme.secondaryText)
                TextField("Replace with", text: $replacement)
                    .textFieldStyle(.plain)
                    .litheSearchField()
            }

            HStack(spacing: 14) {
                Toggle("Match Case", isOn: $options.caseSensitive)
                    .lithePointer()
                Toggle("Whole Words", isOn: $options.wholeWords)
                    .lithePointer()
                Toggle("Regex", isOn: $options.regularExpression)
                    .lithePointer()
                Toggle("Preserve Case", isOn: $options.preserveCase)
                    .lithePointer()
                    .disabled(options.caseSensitive)
                    .help("Match the original casing of each hit: fooBar → bazQux, FooBar → BazQux, FOOBAR → BAZQUX.")

                TextField("File mask", text: $options.fileMask)
                    .textFieldStyle(.plain)
                    .litheSearchField()
                    .frame(maxWidth: 190)
                    .help("Comma-separated glob patterns, e.g. *.java, *.kt")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(LitheTheme.secondaryText)

            HStack(spacing: 8) {
                Button {
                    Task {
                        await previewReplacement(query, replacement, options)
                    }
                } label: {
                    Label("Preview", systemImage: "eye")
                }
                .buttonStyle(.borderedProminent)
                .lithePointer()
                .tint(LitheTheme.accent)
                .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || feature.isLoadingProjectReplacement)

                Button {
                    let allSelected = session.selectedReplacementPaths.count == feature.projectReplacementFiles.count
                    session.selectedReplacementPaths = allSelected
                        ? []
                        : Set(feature.projectReplacementFiles.map(\.relativePath))
                } label: {
                    Text(session.selectedReplacementPaths.count == feature.projectReplacementFiles.count
                        ? "Clear Selection"
                        : "Select All")
                }
                .buttonStyle(.bordered)
                .lithePointer()
                .disabled(feature.projectReplacementFiles.isEmpty)

                Spacer()

                if feature.isLoadingProjectReplacement {
                    ProgressView()
                        .controlSize(.small)
                }
                Text("\(selectedFiles.count) files, \(selectedMatchCount) matches")
                    .font(.system(size: 11.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                Button("Apply") {
                    Task { await applyReplacement(query) }
                }
                .buttonStyle(.borderedProminent)
                .lithePointer()
                .tint(LitheTheme.accent)
                .disabled(selectedFiles.isEmpty || feature.isLoadingProjectReplacement)
            }
        }
        .padding(12)
        .background(LitheTheme.sidebar)
    }

    @ViewBuilder
    private var results: some View {
        if feature.projectReplacementFiles.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 28, weight: .light))
                Text(query.isEmpty
                    ? "Enter text to preview project changes"
                    : "No replacement matches")
            }
            .font(LitheTheme.uiFont)
            .foregroundStyle(LitheTheme.secondaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(feature.projectReplacementFiles) { file in
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
                        get: { session.selectedReplacementPaths.contains(file.relativePath) },
                        set: { selected in
                            if selected { session.selectedReplacementPaths.insert(file.relativePath) }
                            else { session.selectedReplacementPaths.remove(file.relativePath) }
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .litheContextMenu {
            [
                .action("Open", systemImage: "doc.text", action: {
                    openFile(file.url, file.relativePath)
                }),
                .action("Show in Finder", systemImage: "folder", action: {
                    revealInFinder(file.url)
                }),
                .submenu("Copy Path / Reference", items: [
                    .action("Copy Path", action: {
                        copyPath(file.url, false)
                    }),
                    .action("Copy Relative Path", action: {
                        copyPath(file.url, true)
                    })
                ])
            ]
        }
    }

    private func clearPreview() {
        guard !feature.projectReplacementFiles.isEmpty else { return }
        feature.clearProjectReplacementPreview()
    }
}
