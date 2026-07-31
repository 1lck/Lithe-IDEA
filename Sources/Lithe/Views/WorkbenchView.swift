import SwiftUI

struct WorkbenchView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var runService: JavaRunService
    @State private var sidebarWidth: CGFloat = 320
    @State private var sidebarDragStart: CGFloat = 320
    @State private var topPaneHeight: CGFloat?
    @State private var topPaneDragStart: CGFloat = 0
    @State private var isBranchSwitcherPresented = false
    @State private var newBranchReference: GitReference?
    @State private var isCheckoutRevisionPresented = false
    @State private var pendingTopBarPushReference: GitReference?
    @State private var isRunConfigurationEditorPresented = false

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
            "Discard this change block?",
            isPresented: Binding(
                get: { model.pendingDiscardHunk != nil },
                set: { if !$0 { model.cancelDiscardHunk() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Discard Block", role: .destructive) {
                Task { await model.confirmDiscardHunk() }
            }
            Button("Cancel", role: .cancel) { model.cancelDiscardHunk() }
        } message: {
            Text(model.pendingDiscardHunk?.change.path ?? "This action cannot be undone by Lithe.")
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
        .overlay {
            if model.isSearchEverywhereVisible {
                SearchEverywhereView()
                    .environmentObject(model)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.isSearchEverywhereVisible)
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

            runControls

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

            activityToolButton(
                systemImage: "terminal",
                help: "Terminal",
                isSelected: model.isTerminalVisible
            ) {
                model.toggleTerminal()
            }

            activityToolButton(
                systemImage: "point.3.connected.trianglepath.dotted",
                help: "Git",
                isSelected: model.isGitLogVisible
            ) {
                if !model.isGitLogVisible {
                    model.selectedSidebar = .changes
                }
                Task { await model.toggleGitLog() }
            }

            activityToolButton(
                systemImage: "exclamationmark.triangle",
                help: "Problems",
                isSelected: model.isProblemsVisible
            ) {
                model.toggleProblems()
            }

            activityToolButton(
                systemImage: "shippingbox",
                help: "Maven",
                isSelected: model.isMavenVisible
            ) {
                model.toggleMaven()
            }

            activityToolButton(
                systemImage: "ladybug",
                help: "Debug",
                isSelected: model.isDebugVisible
            ) {
                model.toggleDebug()
            }

            activityToolButton(
                systemImage: "gearshape",
                help: "Settings",
                isSelected: model.isSettingsPresented
            ) {
                model.isSettingsPresented = true
            }
        }
        .padding(.vertical, 8)
        .frame(width: 48)
        .background(LitheTheme.titlebar)
    }

    private var runControls: some View {
        HStack(spacing: 3) {
            Picker(
                selection: Binding(
                    get: { runService.selectedConfigurationID },
                    set: { runService.selectedConfigurationID = $0 }
                )
            ) {
                ForEach(runService.configurations) { configuration in
                    Label(configuration.name, systemImage: configuration.systemImage)
                        .tag(configuration.id)
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: runService.selectedConfiguration?.systemImage ?? "play.fill")
                    Text(runService.selectedConfiguration?.name ?? "Current File")
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(maxWidth: 230)
            }
            .pickerStyle(.menu)
            .help("Select run configuration")

            Button {
                isRunConfigurationEditorPresented = true
            } label: {
                Image(systemName: "gearshape")
            }
            .litheIconButton()
            .help("Edit run configuration")
            .popover(isPresented: $isRunConfigurationEditorPresented, arrowEdge: .bottom) {
                if let configuration = runService.selectedConfiguration {
                    JavaRunConfigurationEditorView(
                        service: runService,
                        configuration: configuration
                    )
                }
            }

            Button {
                if runService.isRunning {
                    model.stopSelectedRun()
                } else {
                    model.runSelectedConfiguration()
                }
            } label: {
                Image(systemName: runService.isRunning ? "stop.fill" : "play.fill")
                    .foregroundStyle(runService.isRunning ? LitheTheme.warning : LitheTheme.success)
            }
            .buttonStyle(.plain)
            .frame(width: 24, height: 28)
            .help(runService.isRunning ? "Stop" : "Run")
        }
    }

    private func activityToolButton(
        systemImage: String,
        help: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 40, height: 34)
                .contentShape(Rectangle())
                .overlay(alignment: .leading) {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(LitheTheme.accent)
                            .frame(width: 3, height: 22)
                    }
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? LitheTheme.primaryText : LitheTheme.secondaryText)
        .help(help)
        .accessibilityLabel(help)
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
                        } else if model.isProblemsVisible {
                            JavaProblemsView()
                        } else if model.isDebugVisible {
                            JavaDebugView(
                                service: model.javaDebugService,
                                runService: runService
                            )
                        } else if model.isRunVisible {
                            RunView(service: runService)
                        } else if model.isMavenVisible {
                            MavenView(service: model.mavenService)
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
        model.isGitLogVisible || model.isTerminalVisible || model.isReferencesVisible || model.isProblemsVisible || model.isMavenVisible || model.isDebugVisible || model.isRunVisible
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            editorBreadcrumbs
                .frame(maxWidth: .infinity, alignment: .leading)

            ViewThatFits(in: .horizontal) {
                detailedStatusItems
                compactStatusItems
            }
        }
        .font(LitheTheme.smallFont)
        .foregroundStyle(LitheTheme.secondaryText)
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(LitheTheme.titlebar)
    }

    private var editorBreadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if let document = model.activeDocument {
                    let components = model.relativePath(for: document.url).split(separator: "/")
                    ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                        breadcrumbItem(
                            title: String(component),
                            systemImage: index == components.count - 1 ? "doc.text" : nil,
                            isEmphasized: index == components.count - 1
                        ) {
                            model.selectedSidebar = .project
                        }
                        if index < components.count - 1 || !activeJavaBreadcrumbs.isEmpty {
                            breadcrumbSeparator
                        }
                    }

                    ForEach(Array(activeJavaBreadcrumbs.enumerated()), id: \.offset) { index, hint in
                        breadcrumbItem(
                            title: hint.symbol,
                            systemImage: index == activeJavaBreadcrumbs.count - 1 ? "m.circle" : "c.circle",
                            isEmphasized: index == activeJavaBreadcrumbs.count - 1
                        ) {
                            model.editorNavigationTarget = EditorNavigationTarget(
                                url: document.url,
                                line: hint.line,
                                utf16Column: hint.utf16Column
                            )
                        }
                        if index < activeJavaBreadcrumbs.count - 1 {
                            breadcrumbSeparator
                        }
                    }
                } else {
                    Label(model.projectName, systemImage: "folder")
                }
            }
        }
    }

    private var activeJavaBreadcrumbs: [JavaCodeVisionHint] {
        guard let document = model.activeDocument,
              document.url.pathExtension.lowercased() == "java" else { return [] }
        let caretLine = model.editorCaret?.url.standardizedFileURL == document.url.standardizedFileURL
            ? model.editorCaret?.line ?? Int.max
            : Int.max
        return Array(
            (model.javaCodeVisionHints[document.url] ?? [])
                .filter { $0.line <= caretLine }
                .suffix(2)
        )
    }

    private func breadcrumbItem(
        title: String,
        systemImage: String?,
        isEmphasized: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10))
                        .foregroundStyle(isEmphasized ? LitheTheme.accent : LitheTheme.secondaryText)
                }
                Text(title)
                    .lineLimit(1)
            }
            .foregroundStyle(isEmphasized ? LitheTheme.primaryText : LitheTheme.secondaryText)
        }
        .buttonStyle(.plain)
        .help(title)
    }

    private var breadcrumbSeparator: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 7, weight: .semibold))
            .foregroundStyle(LitheTheme.secondaryText.opacity(0.72))
    }

    private var detailedStatusItems: some View {
        HStack(spacing: 14) {
            caretPosition
            Text("UTF-8")
            Text("\(settings.tabWidth) spaces")
            Button {
                model.saveActiveDocument()
            } label: {
                Image(systemName: "lock.open")
            }
            .buttonStyle(.plain)
            .help("Save")
            gitStatus
        }
    }

    private var compactStatusItems: some View {
        HStack(spacing: 10) {
            caretPosition
            gitStatus
        }
    }

    private var caretPosition: some View {
        Text(model.editorCaret.map { "\($0.line + 1):\($0.utf16Column + 1)" } ?? "1:1")
            .monospacedDigit()
    }

    private var gitStatus: some View {
        HStack(spacing: 7) {
            if model.isReferencesVisible {
                Label("\(model.javaNavigationLocations.count) usages", systemImage: "scope")
            }
            Text(model.gitChanges.isEmpty ? "No changes" : "\(model.gitChanges.count) changes")
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(LitheTheme.success)
        }
    }

    private var projectInitials: String {
        let words = model.projectName.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let initials = words.prefix(2).compactMap(\.first)
        return initials.isEmpty ? "LI" : String(initials).uppercased()
    }
}
