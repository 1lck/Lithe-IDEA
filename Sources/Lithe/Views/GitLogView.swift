import SwiftUI

struct GitLogView: View {
    @EnvironmentObject private var model: AppModel
    @State private var localExpanded = true
    @State private var remoteExpanded = true
    @State private var tagsExpanded = true
    @State private var collapsedFileGroups: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            toolWindowHeader
            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            HStack(spacing: 0) {
                referencePane
                    .frame(width: 300)
                Rectangle().fill(LitheTheme.divider).frame(width: 1)
                commitPane
                    .frame(minWidth: 340, maxWidth: .infinity)
                Rectangle().fill(LitheTheme.divider).frame(width: 1)
                detailPane
                    .frame(width: 350)
            }
        }
        .background(LitheTheme.sidebar)
    }

    private var toolWindowHeader: some View {
        HStack(spacing: 8) {
            Text("Git")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)

            HStack(spacing: 7) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 11))
                Text("Log: \(model.selectedGitReference?.shortName ?? model.currentBranch)")
                    .lineLimit(1)
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(LitheTheme.primaryText)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(LitheTheme.selection)
            .clipShape(RoundedRectangle(cornerRadius: 5))

            Button {
                Task { await model.selectGitReference(nil) }
            } label: {
                Image(systemName: "plus")
            }
            .litheIconButton()
            .help("Show all references")

            Spacer()

            if model.isLoadingGitHistory {
                ProgressView().controlSize(.mini)
            }

            Button {
                Task { await model.refreshGitHistory() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .litheIconButton()
            .help("Refresh Git log")

            Button {
                model.closeGitLog()
            } label: {
                Image(systemName: "minus")
            }
            .litheIconButton()
            .help("Hide Git tool window")
        }
        .padding(.leading, 12)
        .padding(.trailing, 7)
        .frame(height: 42)
        .background(LitheTheme.toolHeader)
    }

    private var referencePane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    Task { await model.selectGitReference(nil) }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .litheIconButton()

                Button {
                    model.gitLogSearchQuery = ""
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .litheIconButton()
                .help("Clear log search")

                Spacer()
            }
            .padding(.horizontal, 6)
            .frame(height: 38)

            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            GeometryReader { geometry in
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let current = currentReference {
                            referenceButton(current, title: "HEAD (Current Branch)", icon: "arrow.right")
                                .padding(.bottom, 4)
                        }

                        referenceSection(
                            title: "Local",
                            icon: "folder",
                            kind: .local,
                            expanded: $localExpanded
                        )
                        referenceSection(
                            title: "Remote",
                            icon: "network",
                            kind: .remote,
                            expanded: $remoteExpanded
                        )
                        referenceSection(
                            title: "Tags",
                            icon: "tag",
                            kind: .tag,
                            expanded: $tagsExpanded
                        )
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 9)
                    .frame(
                        minWidth: geometry.size.width,
                        minHeight: geometry.size.height,
                        alignment: .topLeading
                    )
                }
            }
        }
        .background(LitheTheme.sidebar)
    }

    private func referenceSection(
        title: String,
        icon: String,
        kind: GitReferenceKind,
        expanded: Binding<Bool>
    ) -> some View {
        let references = model.gitReferences.filter { $0.kind == kind }
        return VStack(alignment: .leading, spacing: 1) {
            Button {
                expanded.wrappedValue.toggle()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 10)
                    Image(systemName: icon)
                        .font(.system(size: 12))
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                }
                .foregroundStyle(LitheTheme.primaryText)
                .frame(height: 27)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded.wrappedValue {
                ForEach(references) { reference in
                    referenceButton(reference, title: reference.shortName, icon: referenceIcon(reference))
                        .padding(.leading, 18)
                }
            }
        }
    }

    private func referenceButton(_ reference: GitReference, title: String, icon: String) -> some View {
        Button {
            Task { await model.selectGitReference(reference) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 11.5))
                    .foregroundStyle(reference.kind == .tag ? LitheTheme.warning : LitheTheme.secondaryText)
                    .frame(width: 15)
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(LitheTheme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 7)
            .frame(width: 260, height: 28)
            .background(model.selectedGitReference?.id == reference.id ? LitheTheme.subtleSelection : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var commitPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(LitheTheme.secondaryText)
                TextField("Text or hash", text: $model.gitLogSearchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                if !model.gitLogSearchQuery.isEmpty {
                    Button {
                        model.gitLogSearchQuery = ""
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(LitheTheme.secondaryText)
                }
                Rectangle().fill(LitheTheme.divider).frame(width: 1, height: 20)
                Text("Branch: \(model.selectedGitReference?.shortName ?? "All")")
                    .font(.system(size: 11.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "eye")
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(LitheTheme.toolHeader)

            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            if filteredCommits.isEmpty && !model.isLoadingGitHistory {
                VStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 27, weight: .light))
                    Text("No commits match this view")
                }
                .font(LitheTheme.uiFont)
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredCommits.enumerated()), id: \.element.id) { index, commit in
                            commitRow(commit, index: index)
                        }
                    }
                }
            }
        }
        .background(LitheTheme.editor)
    }

    private func commitRow(_ commit: GitCommit, index: Int) -> some View {
        Button {
            Task { await model.selectGitCommit(commit) }
        } label: {
            HStack(spacing: 0) {
                ZStack {
                    Rectangle()
                        .fill(LitheTheme.success.opacity(0.70))
                        .frame(width: 1)
                    Circle()
                        .fill(commit.parentHashes.count > 1 ? LitheTheme.warning : LitheTheme.success)
                        .frame(width: 9, height: 9)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 1) {
                    Text(commit.subject)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(LitheTheme.primaryText)
                        .lineLimit(1)
                    if !commit.decorations.isEmpty {
                        Text(commit.decorations)
                            .font(.system(size: 9.5))
                            .foregroundStyle(LitheTheme.accent)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(commit.authorName)
                    .font(.system(size: 11.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
                    .frame(width: 104, alignment: .leading)

                Text(commit.date)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(width: 122, alignment: .trailing)
            }
            .padding(.horizontal, 7)
            .frame(height: 34)
            .background(model.selectedGitCommit?.hash == commit.hash ? LitheTheme.selection : (index.isMultiple(of: 2) ? Color.white.opacity(0.012) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var detailPane: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.left.arrow.right")
                    Image(systemName: "clock")
                    Image(systemName: "eye")
                    Spacer()
                    Text("\(model.selectedGitCommitFiles.count) files")
                }
                .font(.system(size: 11.5))
                .foregroundStyle(LitheTheme.secondaryText)
                .padding(.horizontal, 10)
                .frame(height: 38)
                .background(LitheTheme.toolHeader)

                Rectangle().fill(LitheTheme.divider).frame(height: 1)

                if model.selectedGitCommitFiles.isEmpty {
                    Text(model.selectedGitCommit == nil ? "Select a commit" : "No changed files")
                        .font(LitheTheme.uiFont)
                        .foregroundStyle(LitheTheme.secondaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    GeometryReader { geometry in
                        ScrollView([.vertical, .horizontal]) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(commitFileGroups) { group in
                                    Button {
                                        if collapsedFileGroups.contains(group.path) {
                                            collapsedFileGroups.remove(group.path)
                                        } else {
                                            collapsedFileGroups.insert(group.path)
                                        }
                                    } label: {
                                        HStack(spacing: 7) {
                                            Image(systemName: collapsedFileGroups.contains(group.path) ? "chevron.right" : "chevron.down")
                                                .font(.system(size: 8, weight: .bold))
                                                .frame(width: 10)
                                                .foregroundStyle(LitheTheme.secondaryText)
                                            Image(systemName: "folder")
                                                .font(.system(size: 11.5))
                                                .foregroundStyle(LitheTheme.secondaryText)
                                            Text(group.displayName)
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundStyle(LitheTheme.primaryText)
                                                .lineLimit(1)
                                            Text(group.files.count == 1 ? "1 file" : "\(group.files.count) files")
                                                .font(.system(size: 10.5))
                                                .foregroundStyle(LitheTheme.secondaryText)
                                            Spacer(minLength: 8)
                                        }
                                        .padding(.horizontal, 8)
                                        .frame(width: 330, height: 27)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)

                                    if !collapsedFileGroups.contains(group.path) {
                                        ForEach(group.files) { file in
                                            commitFileRow(file)
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 5)
                            .frame(
                                minWidth: geometry.size.width,
                                minHeight: geometry.size.height,
                                alignment: .topLeading
                            )
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            commitDetail
                .frame(height: 156)
        }
        .background(LitheTheme.sidebar)
    }

    private var commitDetail: some View {
        Group {
            if let commit = model.selectedGitCommit {
                VStack(alignment: .leading, spacing: 9) {
                    Text(commit.subject)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LitheTheme.primaryText)
                        .lineLimit(2)
                    Text("\(commit.shortHash)  \(commit.authorName) <\(commit.authorEmail)>")
                        .font(.system(size: 11.5))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .lineLimit(1)
                    Text(commit.date)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(LitheTheme.secondaryText)
                    if !commit.decorations.isEmpty {
                        Text(commit.decorations)
                            .font(.system(size: 11.5))
                            .foregroundStyle(LitheTheme.accent)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(11)
                .textSelection(.enabled)
            } else {
                Text("Commit details")
                    .font(LitheTheme.uiFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(LitheTheme.editor)
    }

    private var filteredCommits: [GitCommit] {
        let query = model.gitLogSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.gitCommits }
        return model.gitCommits.filter { commit in
            [commit.subject, commit.hash, commit.shortHash, commit.authorName, commit.authorEmail, commit.decorations]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var commitFileGroups: [GitCommitFileGroup] {
        let groups = Dictionary(grouping: model.selectedGitCommitFiles) { file in
            (file.path as NSString).deletingLastPathComponent
        }
        return groups.map { path, files in
            GitCommitFileGroup(
                path: path,
                displayName: path.isEmpty ? model.projectName : path,
                files: files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            )
        }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private var currentReference: GitReference? {
        model.gitReferences.first(where: \.isCurrent)
    }

    private func referenceIcon(_ reference: GitReference) -> String {
        switch reference.kind {
        case .local: reference.isCurrent ? "star.fill" : "point.3.connected.trianglepath.dotted"
        case .remote: "cloud"
        case .tag: "tag"
        }
    }

    private func fileStatusColor(_ status: String) -> Color {
        if status.hasPrefix("A") { return LitheTheme.success }
        if status.hasPrefix("D") { return .red.opacity(0.85) }
        if status.hasPrefix("R") { return LitheTheme.accent }
        return LitheTheme.warning
    }

    private func commitFileRow(_ file: GitCommitFile) -> some View {
        Button {
            model.selectedGitCommitFile = file
        } label: {
            HStack(spacing: 7) {
                Text(file.status)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(fileStatusColor(file.status))
                    .frame(width: 18)
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                    .foregroundStyle(LitheTheme.accent)
                Text((file.path as NSString).lastPathComponent)
                    .font(.system(size: 12))
                    .foregroundStyle(LitheTheme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
            }
            .padding(.leading, 30)
            .padding(.trailing, 8)
            .frame(width: 330, height: 27)
            .background(model.selectedGitCommitFile?.id == file.id ? LitheTheme.subtleSelection : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct GitCommitFileGroup: Identifiable {
    let path: String
    let displayName: String
    let files: [GitCommitFile]

    var id: String { path }
}
