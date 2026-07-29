import SwiftUI

struct ChangesSidebarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            if model.gitRepositoryRoot == nil {
                noRepository
            } else {
                changeList
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
                commitArea
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Changes")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)
            if !model.gitChanges.isEmpty {
                Text("\(model.gitChanges.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(LitheTheme.raised)
                    .clipShape(Capsule())
            }
            Spacer()
            if model.isRefreshingGit {
                ProgressView().controlSize(.mini)
            } else {
                Button {
                    Task { await model.refreshGit() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .litheIconButton()
                .help("Refresh Git")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private var noRepository: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 30, weight: .light))
            Text("This project is not a Git repository")
                .multilineTextAlignment(.center)
        }
        .font(LitheTheme.uiFont)
        .foregroundStyle(LitheTheme.secondaryText)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var changeList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.triangle.branch")
                Text(model.currentBranch)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                Spacer()
            }
            .foregroundStyle(LitheTheme.secondaryText)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(LitheTheme.window.opacity(0.35))

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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        changeSection("Staged", changes: stagedChanges)
                        changeSection("Changes", changes: unstagedChanges)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func changeSection(_ title: String, changes: [GitChange]) -> some View {
        if !changes.isEmpty {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(LitheTheme.secondaryText)
                .padding(.horizontal, 11)
                .padding(.top, 9)
                .padding(.bottom, 4)

            ForEach(changes) { change in
                Button {
                    model.selectChange(change)
                } label: {
                    HStack(spacing: 8) {
                        Text(change.displayStatus)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(statusColor(change))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
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
                        }
                        Spacer(minLength: 4)
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 42)
                    .background(model.selectedChange?.id == change.id ? LitheTheme.subtleSelection : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var commitArea: some View {
        VStack(spacing: 8) {
            TextField("Commit message", text: $model.commitMessage, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .lineLimit(2...4)
                .padding(8)
                .background(LitheTheme.raised)
                .clipShape(RoundedRectangle(cornerRadius: 5))

            Button {
                Task { await model.commitStagedChanges() }
            } label: {
                HStack {
                    if model.isCommitting {
                        ProgressView().controlSize(.mini)
                    }
                    Text("Commit Staged Changes")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(LitheTheme.accent)
            .disabled(stagedChanges.isEmpty || model.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isCommitting)
        }
        .padding(10)
    }

    private var stagedChanges: [GitChange] {
        model.gitChanges.filter(\.isStaged)
    }

    private var unstagedChanges: [GitChange] {
        model.gitChanges.filter { !$0.isStaged || $0.hasWorkingTreeChange }
    }

    private func statusColor(_ change: GitChange) -> Color {
        switch change.displayStatus {
        case "A", "?": LitheTheme.success
        case "D": Color.red.opacity(0.86)
        case "R": Color(red: 0.55, green: 0.70, blue: 0.96)
        default: LitheTheme.warning
        }
    }
}
