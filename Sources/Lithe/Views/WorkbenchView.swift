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
                placeholderSidebar
                Rectangle().fill(LitheTheme.divider).frame(width: 1)
                editorPlaceholder
            }

            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            statusBar
        }
        .sheet(isPresented: $model.isRunPlaceholderPresented) {
            RunPlaceholderView()
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

    private var placeholderSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.selectedSidebar.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)
                Spacer()
                Image(systemName: "ellipsis")
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)

            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            VStack(spacing: 10) {
                Image(systemName: model.selectedSidebar.systemImage)
                    .font(.system(size: 28, weight: .light))
                Text("Loading \(model.selectedSidebar.title)…")
                    .font(LitheTheme.uiFont)
            }
            .foregroundStyle(LitheTheme.secondaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 310)
        .background(LitheTheme.sidebar)
    }

    private var editorPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundStyle(LitheTheme.secondaryText)
            Text("Select a file to review")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(LitheTheme.primaryText)
            Text("Changes from external tools will appear automatically.")
                .font(LitheTheme.uiFont)
                .foregroundStyle(LitheTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LitheTheme.editor)
    }

    private var statusBar: some View {
        HStack(spacing: 16) {
            Label(model.projectName, systemImage: "folder")
            Spacer()
            Text("Ready")
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
