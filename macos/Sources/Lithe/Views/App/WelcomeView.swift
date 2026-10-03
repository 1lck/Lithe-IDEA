import AppKit
import SwiftUI

struct WelcomeView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var updateChecker: UpdateChecker
    @State private var projectFilter = ""
    @State private var hoveredProjectID: String?
    @State private var hoveredProjectMenuID: String?
    @State private var showingStableRollback = false
    @FocusState private var searchFocused: Bool

    // JetBrains/intellij-community: platform/platform-resources/src/themes/islands/ManyIslandsDark.theme.json
    // and platform/platform-resources/src/themes/expUI/expUI_light.theme.json.
    // Keep these welcome colors local so workspace and settings themes remain independent.
    private var surface: Color { colorScheme == .dark ? Color(red: 0.098, green: 0.102, blue: 0.110) : .white }
    private var sidebarSurface: Color { colorScheme == .dark ? Color(red: 0.098, green: 0.102, blue: 0.110) : Color(red: 0.969, green: 0.973, blue: 0.980) }
    private var textColor: Color { colorScheme == .dark ? Color(red: 0.820, green: 0.827, blue: 0.851) : .black }
    private var mutedColor: Color { colorScheme == .dark ? Color(red: 0.451, green: 0.463, blue: 0.486) : Color(red: 0.424, green: 0.439, blue: 0.494) }
    private var separatorColor: Color { colorScheme == .dark ? Color(red: 0.149, green: 0.157, blue: 0.173) : Color(red: 0.875, green: 0.882, blue: 0.898) }
    private var selectionColor: Color { colorScheme == .dark ? Color(red: 0.165, green: 0.263, blue: 0.443) : Color(red: 0.831, green: 0.886, blue: 1) }
    private var hoverColor: Color { colorScheme == .dark ? .white.opacity(0.063) : Color(red: 0.922, green: 0.925, blue: 0.941) }
    private var borderColor: Color { colorScheme == .dark ? Color(red: 0.251, green: 0.263, blue: 0.290) : Color(red: 0.788, green: 0.800, blue: 0.839) }

    var body: some View {
        HStack(spacing: 0) {
            welcomeSidebar
            Rectangle().fill(separatorColor).frame(width: 1)
            projectsContent
        }
        .background(surface.ignoresSafeArea(.container, edges: .top))
        .background(WelcomeInitialFocusReset())
        .sheet(isPresented: $showingStableRollback) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Return to Stable").font(LitheTheme.uiFont(.headline))
                StableRollbackControl()
                Button("Close") { showingStableRollback = false }
            }
            .padding(20)
            .frame(width: 420)
        }
    }

    private var welcomeSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                LitheIcons.appLogo(size: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Lithe")
                        .font(LitheTheme.uiFont(size: 13, weight: .regular))
                        .foregroundStyle(textColor)
                    Text(updateChecker.versionDescription)
                        .font(LitheTheme.uiFont(size: 11))
                        .foregroundStyle(mutedColor)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 26)
            .padding(.bottom, 38)

            HStack(spacing: 9) {
                LitheIcon(kind: .folder, size: 15)
                Text("Projects")
                    .font(LitheTheme.uiFont(size: 13, weight: .regular))
            }
            .foregroundStyle(textColor)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 32)
            .background(selectionColor)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .padding(.horizontal, 14)

            Spacer()

            Button {
                showSettingsMenu()
            } label: {
                LitheIDEAIcon(resourcePath: "expui/general/settings@20x20.svg", size: 14)
                    .frame(width: 28, height: 28)
                    .litheRowHover(isActive: false, cornerRadius: 6, activeBackground: selectionColor)
            }
            .buttonStyle(.litheNoPress)
            .lithePointer()
            .foregroundStyle(mutedColor)
            .help("Settings")
            .accessibilityLabel("Settings")
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 224)
        .background(
            sidebarSurface
                .ignoresSafeArea(.container, edges: .top)
        )
    }

    private var projectsContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    LitheSystemIcon(systemImage: "magnifyingglass")
                        .font(LitheTheme.uiFont(size: 12.5))
                        .foregroundStyle(mutedColor)
                    TextField("Search projects", text: $projectFilter)
                        .textFieldStyle(.plain)
                        .font(LitheTheme.uiFont(size: 13))
                        .focused($searchFocused)
                }
                .foregroundStyle(textColor)
                .padding(.horizontal, 8)
                .frame(maxWidth: 220)

                Spacer()

                Button("New Project") {
                    model.chooseProject(title: "New Project", prompt: "Choose Folder")
                }
                .buttonStyle(.litheNoPress)
                .welcomeActionStyle(foreground: textColor, border: borderColor, hover: hoverColor)

                Button("Open") {
                    model.chooseProject()
                }
                .buttonStyle(.litheNoPress)
                .welcomeActionStyle(foreground: textColor, border: borderColor, hover: hoverColor)

                Button("Clone Repository") {
                    model.showCloneRepository()
                }
                .buttonStyle(.litheNoPress)
                .welcomeActionStyle(foreground: textColor, border: borderColor, hover: hoverColor)
            }
            .padding(.horizontal, 14)
            .frame(height: 68)

            Rectangle().fill(separatorColor).frame(height: 1)
                .padding(.horizontal, 12)

            if filteredProjects.isEmpty {
                emptyProjectsState
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredProjects) { project in
                            projectRow(project)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                }
            }
        }
        .background(surface.ignoresSafeArea(.container, edges: .top))
    }

    private var emptyProjectsState: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder.badge.plus")
                .font(LitheTheme.uiFont(size: 32, weight: .light))
                .foregroundStyle(mutedColor)
            Text(model.recentProjects.isEmpty ? "No recent projects" : "No matching projects")
                .font(LitheTheme.uiFont(size: 14, weight: .medium))
                .foregroundStyle(textColor)
            Text("Open a local folder to start working.")
                .font(LitheTheme.uiFont)
                .foregroundStyle(mutedColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func projectRow(_ project: RecentProject) -> some View {
        let exists = model.fileExists(at: project.url)
        return HStack(spacing: 12) {
            Button {
                if exists { model.openProject(project.url) }
            } label: {
                HStack(spacing: 8) {
                    ProjectAvatarBadge(
                        name: project.name,
                        colorIndex: ProjectIdentityAppearance.colorIndex(for: project.url),
                        size: 20,
                        isEnabled: exists
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(project.name)
                            .font(LitheTheme.uiFont(size: 13.5, weight: .regular))
                            .foregroundStyle(exists ? textColor : mutedColor)
                        Text(project.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(LitheTheme.uiFont(size: 11.5))
                            .foregroundStyle(mutedColor)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.litheNoPress)
            .lithePointer()
            .disabled(!exists)

            Spacer(minLength: 0)

            LitheMenu {
                if exists {
                    LitheContextMenuItem.action("Open") { model.openProject(project.url) }
                    LitheContextMenuItem.action("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([project.url])
                    }
                }
                LitheContextMenuItem.action("Remove from Recent Projects", role: .destructive) {
                    model.removeRecentProject(project)
                }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(hoveredProjectMenuID == project.id ? hoverColor : .clear)
                    LitheSystemIcon(systemImage: "ellipsis")
                        .font(LitheTheme.uiFont(size: 12, weight: .semibold))
                        .foregroundStyle(mutedColor)
                }
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .onHover { isHovering in
                    hoveredProjectMenuID = isHovering ? project.id : nil
                }
            }
            .buttonStyle(.litheNoPress)
            .frame(width: 28, height: 28)
            .opacity(hoveredProjectID == project.id ? 1 : 0)
            .allowsHitTesting(hoveredProjectID == project.id)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .frame(height: 68)
        .background(hoveredProjectID == project.id ? selectionColor : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onHover { isHovering in
            hoveredProjectID = isHovering ? project.id : nil
        }
        .litheContextMenu {
            var items: [LitheContextMenuItem] = []
            if exists {
                items.append(.action("Open", action: { model.openProject(project.url) }))
                items.append(.action("Show in Finder", action: {
                    NSWorkspace.shared.activateFileViewerSelecting([project.url])
                }))
            }
            items.append(.action("Remove from Recent Projects", role: .destructive, action: {
                model.removeRecentProject(project)
            }))
            return items
        }
    }

    private var filteredProjects: [RecentProject] {
        guard !projectFilter.isEmpty else { return model.recentProjects }
        return model.recentProjects.filter {
            $0.name.localizedCaseInsensitiveContains(projectFilter) ||
                $0.path.localizedCaseInsensitiveContains(projectFilter)
        }
    }

    private func showSettingsMenu() {
        guard let window = NSApp.keyWindow else { return }
        let screenPoint = NSApp.currentEvent.flatMap { event in
            event.window === window ? window.convertPoint(toScreen: event.locationInWindow) : nil
        } ?? NSPoint(x: window.frame.minX + 28, y: window.frame.minY + 28)
        var items: [LitheContextMenuItem] = [
            .action("Settings…", action: { model.showSettings() }),
            .separator
        ]
        switch updateChecker.status {
        case .available(let version, _):
            items.append(.action("Update to \(version)…", action: { updateChecker.presentDetails() }))
        case .waitingForTermination:
            items.append(.action("Continue Installation", action: {
                Task { await updateChecker.retryInstallation() }
            }))
        case .checking:
            items.append(.action("Checking for Updates…", isEnabled: false, action: {}))
        case .downloading:
            items.append(.action("Downloading Update…", isEnabled: false, action: {}))
        case .installing:
            items.append(.action("Installing Update…", isEnabled: false, action: {}))
        case .failed where updateChecker.updateInfo != nil:
            items.append(.action("Retry Update…", action: { updateChecker.presentDetails() }))
        case .idle, .upToDate, .failed:
            items.append(.action(
                "Check for Updates…",
                isEnabled: !updateChecker.isBusy,
                action: {
                    Task { await updateChecker.checkForUpdates(manual: true, presentingDetails: true) }
                }
            ))
        }
        if updateChecker.isPreview {
            items.append(.action("Return to Stable…", action: { showingStableRollback = true }))
        }
        LitheContextMenuPresenter.shared.show(
            items: items,
            at: screenPoint,
            appearance: window.effectiveAppearance,
            locale: locale,
            opensUpward: true
        )
    }
}

private struct WelcomeActionStyle: ViewModifier {
    let foreground: Color
    let border: Color
    let hover: Color
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .font(LitheTheme.uiFont(size: 13, weight: .regular))
            .foregroundStyle(foreground)
            .padding(.horizontal, 13)
            .frame(height: 28)
            .background(isHovering ? hover : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(border, lineWidth: 1)
            }
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}

private extension View {
    func welcomeActionStyle(foreground: Color, border: Color, hover: Color) -> some View {
        modifier(WelcomeActionStyle(foreground: foreground, border: border, hover: hover))
    }
}

private struct WelcomeInitialFocusReset: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WelcomeInitialFocusResetView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WelcomeInitialFocusResetView: NSView {
    private var didClearFocus = false
    private var eventMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        guard !didClearFocus, let window else { return }

        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, !self.didClearFocus, let window else { return }
            window.makeFirstResponder(nil)
            self.didClearFocus = true
        }

        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            var hitView = window.contentView?.hitTest(event.locationInWindow)
            var clickedInput = false
            while let view = hitView {
                if view is NSTextField {
                    clickedInput = true
                    break
                }
                hitView = view.superview
            }
            if !clickedInput {
                window.makeFirstResponder(nil)
            }
            return event
        }
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }
}
