import SwiftUI

struct WorkbenchView: View {
    @EnvironmentObject private var model: AppModel
    @State private var sidebarWidth: CGFloat = 320
    @State private var sidebarDragStart: CGFloat = 320
    @State private var topPaneHeight: CGFloat?
    @State private var topPaneDragStart: CGFloat = 0
    @State private var isBranchSwitcherPresented = false
    @State private var newBranchReference: GitReference?
    @State private var isCheckoutRevisionPresented = false
    @State private var pendingTopBarPushReference: GitReference?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            HStack(spacing: 0) {
                activityBar
                Rectangle().fill(LitheTheme.divider).frame(width: 1)
                workspaceArea
            }

            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            statusBar
        }
        .sheet(isPresented: $model.isRunPlaceholderPresented) {
            RunPlaceholderView()
        }
        .sheet(item: $newBranchReference) { reference in
            TopBarNewBranchDialog(reference: reference) { name, checkout in
                Task {
                    await model.createBranch(named: name, from: reference, checkout: checkout)
                }
            }
        }
        .sheet(isPresented: $isCheckoutRevisionPresented) {
            CheckoutRevisionDialog { revision in
                Task { await model.checkoutRevision(revision) }
            }
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
        .confirmationDialog(
            "Push '\(pendingTopBarPushReference?.shortName ?? "")'?",
            isPresented: Binding(
                get: { pendingTopBarPushReference != nil },
                set: { if !$0 { pendingTopBarPushReference = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Push") {
                guard let reference = pendingTopBarPushReference else { return }
                pendingTopBarPushReference = nil
                Task { await model.pushBranch(reference) }
            }
            Button("Cancel", role: .cancel) {
                pendingTopBarPushReference = nil
            }
        } message: {
            Text("This sends the current branch to its configured remote.")
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
        HStack(spacing: 9) {
            Text(projectInitials)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(LitheTheme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(model.activeDocument?.url.lastPathComponent ?? model.projectName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)

            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(LitheTheme.secondaryText)

            Rectangle()
                .fill(LitheTheme.divider)
                .frame(width: 1, height: 20)
                .padding(.horizontal, 5)

            Button {
                isBranchSwitcherPresented.toggle()
                if isBranchSwitcherPresented {
                    Task { await model.refreshGitHistory() }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 13))
                        .foregroundStyle(LitheTheme.secondaryText)
                    Text(model.currentBranch)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(LitheTheme.primaryText)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                .padding(.horizontal, 9)
                .frame(height: 32)
                .background(isBranchSwitcherPresented ? LitheTheme.subtleSelection : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isBranchSwitcherPresented, arrowEdge: .bottom) {
                BranchSwitcherPopover(
                    isPresented: $isBranchSwitcherPresented,
                    onCommit: {
                        isBranchSwitcherPresented = false
                        model.selectedSidebar = .changes
                    },
                    onPush: { reference in
                        isBranchSwitcherPresented = false
                        pendingTopBarPushReference = reference
                    },
                    onNewBranch: { reference in
                        isBranchSwitcherPresented = false
                        newBranchReference = reference
                    },
                    onCheckoutRevision: {
                        isBranchSwitcherPresented = false
                        isCheckoutRevisionPresented = true
                    },
                    onManageBranches: {
                        isBranchSwitcherPresented = false
                        if !model.isGitLogVisible {
                            model.selectedSidebar = .changes
                            Task { await model.toggleGitLog() }
                        }
                    }
                )
                .environmentObject(model)
            }

            Spacer(minLength: 22)

            HStack(spacing: 6) {
                Image(systemName: "leaf")
                    .foregroundStyle(LitheTheme.success)
                Text(model.projectName)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(LitheTheme.primaryText)

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

            Button {
                model.selectedSidebar = .search
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .litheIconButton()
            .help("Search")

            Menu {
                Button("Open Project…", action: model.chooseProject)
                Button("Close Project", action: model.closeProject)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
        }
        .padding(.leading, 76)
        .padding(.trailing, 10)
        .frame(height: 50)
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
                if !model.isGitLogVisible {
                    model.selectedSidebar = .changes
                }
                Task { await model.toggleGitLog() }
            } label: {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 36, height: 36)
                    .background(model.isGitLogVisible ? LitheTheme.accent : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.isGitLogVisible ? Color.white : LitheTheme.secondaryText)
            .help("Git Log")

            Button {
                model.toggleTerminal()
            } label: {
                Image(systemName: "terminal")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 36, height: 36)
                    .background(model.isTerminalVisible ? LitheTheme.accent : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.isTerminalVisible ? Color.white : LitheTheme.secondaryText)
            .help("Terminal")
        }
        .padding(.vertical, 10)
        .frame(width: 48)
        .background(LitheTheme.titlebar)
    }

    private var workspaceArea: some View {
        GeometryReader { geometry in
            let horizontalPadding: CGFloat = 6
            let availableTopWidth = max(0, geometry.size.width - (horizontalPadding * 2))
            let minimumSidebarWidth: CGFloat = 220
            let minimumEditorWidth: CGFloat = 400
            let maximumSidebarWidth = max(
                minimumSidebarWidth,
                min(520, availableTopWidth - SplitHandleView.thickness - minimumEditorWidth)
            )
            let resolvedSidebarWidth = constrained(
                sidebarWidth,
                minimum: minimumSidebarWidth,
                maximum: maximumSidebarWidth
            )

            let minimumTopPaneHeight: CGFloat = 220
            let minimumGitPaneHeight: CGFloat = 260
            let maximumTopPaneHeight = max(
                minimumTopPaneHeight,
                geometry.size.height - SplitHandleView.thickness - minimumGitPaneHeight
            )
            let resolvedTopPaneHeight = constrained(
                topPaneHeight ?? max(255, geometry.size.height * 0.40),
                minimum: minimumTopPaneHeight,
                maximum: maximumTopPaneHeight
            )

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    activeSidebar
                        .frame(width: resolvedSidebarWidth)

                    SplitHandleView(
                        axis: .horizontal,
                        onDragStarted: {
                            sidebarDragStart = resolvedSidebarWidth
                        },
                        onDragChanged: { translation in
                            sidebarWidth = constrained(
                                sidebarDragStart + translation,
                                minimum: minimumSidebarWidth,
                                maximum: maximumSidebarWidth
                            )
                        },
                        onDragEnded: {}
                    )

                    EditorAreaView()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .padding(.top, 6)
                .padding(.horizontal, 6)
                .padding(.bottom, isBottomToolVisible ? 0 : 6)
                .frame(height: isBottomToolVisible ? resolvedTopPaneHeight : geometry.size.height)

                if isBottomToolVisible {
                    SplitHandleView(
                        axis: .vertical,
                        onDragStarted: {
                            topPaneDragStart = resolvedTopPaneHeight
                        },
                        onDragChanged: { translation in
                            topPaneHeight = constrained(
                                topPaneDragStart + translation,
                                minimum: minimumTopPaneHeight,
                                maximum: maximumTopPaneHeight
                            )
                        },
                        onDragEnded: {}
                    )
                    .padding(.horizontal, 6)

                    Group {
                        if model.isTerminalVisible {
                            TerminalView(session: model.terminalSession)
                        } else if model.isReferencesVisible {
                            JavaReferencesView()
                        } else {
                            GitLogView()
                        }
                    }
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                        .frame(maxHeight: .infinity)
                }
            }
            .background(LitheTheme.titlebar)
        }
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
        .background(LitheTheme.sidebar)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func constrained(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        min(max(value, minimum), maximum)
    }

    private var isBottomToolVisible: Bool {
        model.isGitLogVisible || model.isTerminalVisible || model.isReferencesVisible
    }

    private var statusBar: some View {
        HStack(spacing: 16) {
            Label(model.projectName, systemImage: "folder")
            Spacer()
            Button {
                model.toggleTerminal()
            } label: {
                Label("Terminal", systemImage: "terminal")
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.isTerminalVisible ? LitheTheme.primaryText : LitheTheme.secondaryText)
            if model.isReferencesVisible {
                Label("\(model.javaNavigationLocations.count) usages", systemImage: "scope")
                    .foregroundStyle(LitheTheme.primaryText)
            }
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
