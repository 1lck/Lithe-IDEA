import SwiftUI

struct ChangesSidebarView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedTab = CommitTab.commit
    @State private var trackedExpanded = true
    @State private var untrackedExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            tabHeader
            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            if selectedTab == .shelf {
                shelfPlaceholder
            } else if model.gitRepositoryRoot == nil {
                noRepository
            } else {
                commitContent
            }
        }
        .background(LitheTheme.sidebar)
    }

    private var tabHeader: some View {
        HStack(spacing: 7) {
            ForEach(CommitTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Text(tab.title)
                        .font(.system(size: 12.5, weight: tab == selectedTab ? .semibold : .regular))
                        .foregroundStyle(tab == selectedTab ? LitheTheme.primaryText : LitheTheme.secondaryText)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(tab == selectedTab ? LitheTheme.subtleSelection : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 45)
        .background(LitheTheme.toolHeader)
    }

    private var commitContent: some View {
        VStack(spacing: 0) {
            commitToolbar
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            changeList
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            commitArea
        }
    }

    private var commitToolbar: some View {
        HStack(spacing: 2) {
            Button {
                Task { await model.refreshGit() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .litheIconButton()
            .help("Refresh changes")

            Button {
                model.requestDiscardSelectedChange()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .litheIconButton()
            .disabled(model.selectedChange == nil)
            .help("Discard selected change")

            Button {
                Task { await model.stageAllChanges() }
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .litheIconButton()
            .disabled(model.gitChanges.isEmpty)
            .help("Stage all changes")

            Button {
                if let first = model.gitChanges.first {
                    model.selectChange(first)
                }
            } label: {
                Image(systemName: "eye")
            }
            .litheIconButton()
            .disabled(model.gitChanges.isEmpty)
            .help("Preview first change")

            Spacer()

            Text(model.currentBranch)
                .font(.system(size: 10.5))
                .foregroundStyle(LitheTheme.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .frame(height: 39)
    }

    private var changeList: some View {
        Group {
            if model.gitChanges.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 27, weight: .light))
                        .foregroundStyle(LitheTheme.success)
                    Text("Working tree is clean")
                }
                .font(LitheTheme.uiFont)
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        changeSection(
                            "Changes",
                            changes: trackedChanges,
                            expanded: $trackedExpanded
                        )
                        changeSection(
                            "Unversioned Files",
                            changes: untrackedChanges,
                            expanded: $untrackedExpanded
                        )
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .frame(minWidth: 300, alignment: .topLeading)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func changeSection(_ title: String, changes: [GitChange], expanded: Binding<Bool>) -> some View {
        if !changes.isEmpty {
            Button {
                expanded.wrappedValue.toggle()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 10)
                    Image(systemName: "square")
                        .font(.system(size: 16))
                        .foregroundStyle(LitheTheme.secondaryText)
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(LitheTheme.primaryText)
                    Text(changes.count == 1 ? "1 file" : "\(changes.count) files")
                        .font(.system(size: 11))
                        .foregroundStyle(LitheTheme.secondaryText)
                    Spacer()
                }
                .padding(.horizontal, 7)
                .frame(width: 298, height: 30)
                .background(LitheTheme.subtleSelection.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded.wrappedValue {
                ForEach(changes) { change in
                    changeRow(change)
                }
            }
        }
    }

    private func changeRow(_ change: GitChange) -> some View {
        HStack(spacing: 6) {
            Button {
                Task { await model.toggleStaging(change) }
            } label: {
                Image(systemName: change.isStaged ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16))
                    .foregroundStyle(change.isStaged ? LitheTheme.accent : LitheTheme.secondaryText)
            }
            .buttonStyle(.plain)
            .help(change.isStaged ? "Unstage file" : "Stage file")

            Button {
                model.selectChange(change)
            } label: {
                HStack(spacing: 7) {
                    Text(change.displayStatus)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(statusColor(change))
                        .frame(width: 17)
                    Text(change.url.lastPathComponent)
                        .font(.system(size: 12.5))
                        .foregroundStyle(LitheTheme.primaryText)
                        .lineLimit(1)
                    let parent = (change.path as NSString).deletingLastPathComponent
                    if !parent.isEmpty {
                        Text(parent)
                            .font(.system(size: 10.5))
                            .foregroundStyle(LitheTheme.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 30)
        .padding(.trailing, 6)
        .frame(width: 298, height: 30)
        .background(model.selectedChange?.id == change.id ? LitheTheme.subtleSelection : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var commitArea: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                Toggle("Amend", isOn: $model.amendCommit)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                Image(systemName: "clock")
                    .foregroundStyle(LitheTheme.secondaryText)
                Spacer()
                Text("\(stagedChanges.count) staged")
                    .font(.system(size: 10.5))
                    .foregroundStyle(LitheTheme.secondaryText)
            }

            TextField("Commit Message", text: $model.commitMessage, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .lineLimit(2...4)
                .padding(8)
                .frame(maxWidth: .infinity, minHeight: 50, alignment: .topLeading)
                .background(LitheTheme.editor)
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(LitheTheme.divider, lineWidth: 1)
                }

            HStack(spacing: 8) {
                Button {
                    Task { await model.commitStagedChanges() }
                } label: {
                    HStack(spacing: 6) {
                        if model.isCommitting {
                            ProgressView().controlSize(.mini)
                        }
                        Text("Commit")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!canCommit)

                Button("Commit and Push…") {
                    model.showPushPlaceholder()
                }
                .buttonStyle(.bordered)
                .disabled(!canCommit)

                Spacer()
                Image(systemName: "gearshape")
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(height: 154)
        .background(LitheTheme.toolHeader)
    }

    private var noRepository: some View {
        VStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 30, weight: .light))
            Text("This project is not a Git repository")
                .multilineTextAlignment(.center)
        }
        .font(LitheTheme.uiFont)
        .foregroundStyle(LitheTheme.secondaryText)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var shelfPlaceholder: some View {
        VStack(spacing: 9) {
            Image(systemName: "archivebox")
                .font(.system(size: 28, weight: .light))
            Text("No shelves")
            Text("Shelving is outside the current Lithe scope.")
                .font(.system(size: 11.5))
        }
        .font(LitheTheme.uiFont)
        .foregroundStyle(LitheTheme.secondaryText)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private var trackedChanges: [GitChange] {
        model.gitChanges.filter { !$0.isUntracked }
    }

    private var untrackedChanges: [GitChange] {
        model.gitChanges.filter(\.isUntracked)
    }

    private var stagedChanges: [GitChange] {
        model.gitChanges.filter(\.isStaged)
    }

    private var canCommit: Bool {
        !stagedChanges.isEmpty &&
            !model.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !model.isCommitting
    }

    private func statusColor(_ change: GitChange) -> Color {
        switch change.displayStatus {
        case "A", "?": LitheTheme.success
        case "D": .red.opacity(0.86)
        case "R": LitheTheme.accent
        default: LitheTheme.warning
        }
    }
}

private enum CommitTab: String, CaseIterable, Identifiable {
    case commit
    case shelf

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}
