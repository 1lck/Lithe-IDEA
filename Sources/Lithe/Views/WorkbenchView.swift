import SwiftUI

struct WorkbenchView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            HStack(spacing: 0) {
                activityBar
                Rectangle().fill(LitheTheme.divider).frame(width: 1)
                activeSidebar
                Rectangle().fill(LitheTheme.divider).frame(width: 1)
                EditorAreaView()
            }

            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            statusBar
        }
        .sheet(isPresented: $model.isRunPlaceholderPresented) {
            RunPlaceholderView()
        }
        .confirmationDialog(
            "Save changes before closing?",
            isPresented: Binding(
                get: { model.pendingCloseDocument != nil },
                set: { if !$0 { model.cancelPendingClose() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Save") { model.closePendingDocument(discardingChanges: false) }
            Button("Discard Changes", role: .destructive) { model.closePendingDocument(discardingChanges: true) }
            Button("Cancel", role: .cancel) { model.cancelPendingClose() }
        } message: {
            Text(model.pendingCloseDocument?.url.lastPathComponent ?? "")
        }
        .confirmationDialog(
            model.pendingDiscardChange?.isUntracked == true ? "Delete this untracked file?" : "Discard changes to this file?",
            isPresented: Binding(
                get: { model.pendingDiscardChange != nil },
                set: { if !$0 { model.cancelDiscardChange() } }
            ),
            titleVisibility: .visible
        ) {
            Button(model.pendingDiscardChange?.isUntracked == true ? "Delete File" : "Discard Changes", role: .destructive) {
                Task { await model.confirmDiscardChange() }
            }
            Button("Cancel", role: .cancel) { model.cancelDiscardChange() }
        } message: {
            Text("This action cannot be undone by Lithe.")
        }
        .overlay(alignment: .bottom) {
            if let message = model.notificationMessage {
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LitheTheme.primaryText)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(LitheTheme.raised)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                    .padding(.bottom, 38)
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Text(projectInitials)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(LitheTheme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(model.projectName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)

            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(LitheTheme.secondaryText)

            Spacer()

            Button {
                model.isRunPlaceholderPresented = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                    Text("Run")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LitheTheme.secondaryText)
            }
            .buttonStyle(.plain)
            .help("Run support is planned for a later release")

            Button(action: model.chooseProject) {
                Image(systemName: "folder.badge.plus")
            }
            .litheIconButton()
            .help("Open Project")

            Button {
            } label: {
                Image(systemName: "gearshape")
            }
            .litheIconButton()
        }
        .padding(.leading, 76)
        .padding(.trailing, 10)
        .frame(height: 54)
        .background(LitheTheme.titlebar)
    }

    private var activityBar: some View {
        VStack(spacing: 6) {
            ForEach(SidebarDestination.allCases) { destination in
                Button {
                    model.selectedSidebar = destination
                } label: {
                    Image(systemName: destination.systemImage)
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 36, height: 36)
                        .background(model.selectedSidebar == destination ? LitheTheme.subtleSelection : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.selectedSidebar == destination ? LitheTheme.primaryText : LitheTheme.secondaryText)
                .help(destination.title)
            }

            Spacer()

            Button {
            } label: {
                Image(systemName: "gearshape")
            }
            .litheIconButton()
        }
        .padding(.vertical, 10)
        .frame(width: 48)
        .background(LitheTheme.titlebar)
    }

    @ViewBuilder
    private var activeSidebar: some View {
        Group {
            switch model.selectedSidebar {
            case .project:
                ProjectSidebarView()
            case .changes:
                ChangesSidebarView()
            case .search:
                SearchSidebarView()
            }
        }
        .frame(width: 310)
        .background(LitheTheme.sidebar)
    }

    private var statusBar: some View {
        HStack(spacing: 16) {
            Label(model.projectName, systemImage: "folder")
            Spacer()
            Text(model.gitChanges.isEmpty ? "No changes" : "\(model.gitChanges.count) changes")
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(LitheTheme.success)
        }
        .font(LitheTheme.smallFont)
        .foregroundStyle(LitheTheme.secondaryText)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(LitheTheme.titlebar)
    }

    private var projectInitials: String {
        let words = model.projectName.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let initials = words.prefix(2).compactMap(\.first)
        return initials.isEmpty ? "LI" : String(initials).uppercased()
    }
}

private struct RunPlaceholderView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "play.slash")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(LitheTheme.secondaryText)
            Text("Run is not connected yet")
                .font(.system(size: 16, weight: .semibold))
            Text("For now, use your external AI tool or terminal to run the project.")
                .font(LitheTheme.uiFont)
                .foregroundStyle(LitheTheme.secondaryText)
                .multilineTextAlignment(.center)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(32)
        .frame(width: 390)
        .background(LitheTheme.window)
    }
}
