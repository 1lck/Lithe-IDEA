import AppKit
import SwiftUI

enum LitheWindowID {
    static let settings = "settings"
}

struct RootView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var projectSessions: ProjectSessionManager
    @EnvironmentObject private var updateChecker: UpdateChecker
    @State private var didStartAutomaticUpdateCheck = false

    var body: some View {
        ZStack {
            ForEach(projectSessions.sessions) { session in
                projectContent(for: session)
                    .opacity(session.id == projectSessions.activeSessionID ? 1 : 0)
                    .allowsHitTesting(session.id == projectSessions.activeSessionID)
                    .accessibilityHidden(session.id != projectSessions.activeSessionID)
                    .zIndex(session.id == projectSessions.activeSessionID ? 1 : 0)
            }
        }
        .frame(
            minWidth: windowLayout.minimumContentSize.width,
            minHeight: windowLayout.minimumContentSize.height
        )
        .background(LitheTheme.window)
        .background(
            WindowCloseGuard(
                projectSessions: projectSessions,
                layout: windowLayout,
                title: windowTitle
            )
        )
        .onReceive(model.$isSettingsPresented) { isPresented in
            guard isPresented else { return }
            openWindow(id: LitheWindowID.settings)
        }
        .sheet(isPresented: $model.isCloneRepositoryPresented) {
            CloneRepositoryView()
                .environmentObject(model)
        }
        .sheet(item: $projectSessions.pendingProjectOpen) { request in
            OpenProjectLocationDialog(request: request) { placement, doNotAskAgain in
                projectSessions.resolvePendingOpen(
                    request,
                    placement: placement,
                    doNotAskAgain: doNotAskAgain
                )
            }
        }
        .sheet(item: $model.localHistoryRequest) { request in
            LocalHistoryView(request: request)
                .environmentObject(model)
        }
        .sheet(item: $model.projectLocalHistoryRequest) { request in
            ProjectLocalHistoryView(request: request)
                .environmentObject(model)
        }
        .alert(item: $updateChecker.notice) { notice in
            switch notice.action {
            case .install:
                return Alert(
                    title: Text(LocalizedStringKey(notice.title)),
                    message: Text(LocalizedStringKey(notice.message)),
                    primaryButton: .default(Text("Update")) {
                        Task { await updateChecker.installAvailableUpdate() }
                    },
                    secondaryButton: .cancel()
                )
            case .open(let url):
                return Alert(
                    title: Text(LocalizedStringKey(notice.title)),
                    message: Text(LocalizedStringKey(notice.message)),
                    primaryButton: .default(Text("Download")) {
                        updateChecker.openRelease(url)
                    },
                    secondaryButton: .cancel()
                )
            case .dismiss:
                return Alert(
                    title: Text(LocalizedStringKey(notice.title)),
                    message: Text(LocalizedStringKey(notice.message)),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
        .confirmationDialog(
            updateChecker.updatePrompt?.title ?? "Update Available",
            isPresented: updatePromptPresented,
            titleVisibility: .visible
        ) {
            if let prompt = updateChecker.updatePrompt {
                Button("Update Now") {
                    Task { await updateChecker.installAvailableUpdate() }
                }
                Button("Open Release Page") {
                    updateChecker.openRelease(prompt.releaseURL)
                }
                Button("Later", role: .cancel) {
                    updateChecker.dismissUpdatePrompt()
                }
            }
        } message: {
            if let prompt = updateChecker.updatePrompt {
                Text(LocalizedStringKey(prompt.message))
            }
        }
        .task {
            guard !didStartAutomaticUpdateCheck else { return }
            didStartAutomaticUpdateCheck = true
            await updateChecker.checkForUpdates()
        }
    }

    @ViewBuilder
    private func projectContent(for session: AppModel) -> some View {
        Group {
            if session.workspaceURL == nil {
                WelcomeView()
            } else {
                WorkbenchView()
                    .ignoresSafeArea(.container, edges: .top)
            }
        }
        .environmentObject(session)
    }

    private var updatePromptPresented: Binding<Bool> {
        Binding(
            get: { updateChecker.updatePrompt != nil },
            set: { isPresented in
                if !isPresented {
                    updateChecker.dismissUpdatePrompt()
                }
            }
        )
    }

    private var windowLayout: LitheWindowLayout {
        projectSessions.activeModel.workspaceURL == nil ? .welcome : .workspace
    }

    private var windowTitle: String? {
        guard windowLayout == .welcome else { return nil }
        return String(
            localized: "Welcome to Lithe",
            bundle: .main,
            locale: model.settings.language.locale
        )
    }
}

private struct WindowCloseGuard: NSViewRepresentable {
    let projectSessions: ProjectSessionManager
    let layout: LitheWindowLayout
    let title: String?

    func makeCoordinator() -> LitheWindowCoordinator {
        LitheWindowCoordinator(projectSessions: projectSessions)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.attach(to: view.window, layout: layout, title: title)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.projectSessions = projectSessions
        DispatchQueue.main.async {
            context.coordinator.attach(to: view.window, layout: layout, title: title)
        }
    }
}

enum LitheWindowLayout: Equatable {
    case welcome
    case workspace

    static let welcomeContentSize = NSSize(width: 900, height: 620)
    static let workspaceContentSize = NSSize(width: 1440, height: 900)
    static let screenMargin: CGFloat = 12

    var contentSize: NSSize {
        switch self {
        case .welcome: Self.welcomeContentSize
        case .workspace: Self.workspaceContentSize
        }
    }

    var minimumContentSize: NSSize {
        switch self {
        case .welcome: NSSize(width: 820, height: 560)
        case .workspace: NSSize(width: 980, height: 640)
        }
    }

    static func frame(_ targetFrame: NSRect, fitting visibleFrame: NSRect) -> NSRect {
        let availableFrame = visibleFrame.insetBy(dx: screenMargin, dy: screenMargin)
        var fittedFrame = targetFrame
        fittedFrame.size.width = min(fittedFrame.width, availableFrame.width)
        fittedFrame.size.height = min(fittedFrame.height, availableFrame.height)
        fittedFrame.origin.x = min(
            max(fittedFrame.origin.x, availableFrame.minX),
            availableFrame.maxX - fittedFrame.width
        )
        fittedFrame.origin.y = min(
            max(fittedFrame.origin.y, availableFrame.minY),
            availableFrame.maxY - fittedFrame.height
        )
        return fittedFrame
    }
}

@MainActor
protocol ProjectWindowSessionHandling: AnyObject {
    var hasActiveProject: Bool { get }
    func closeActiveProject()
}

extension ProjectSessionManager: ProjectWindowSessionHandling {
    var hasActiveProject: Bool {
        activeModel.workspaceURL != nil
    }
}

@MainActor
final class LitheWindowCoordinator: NSObject, NSWindowDelegate {
    var projectSessions: any ProjectWindowSessionHandling
    weak var window: NSWindow?
    private var layout: LitheWindowLayout?
    private var restoredWorkspaceFrame: NSRect?

    init(projectSessions: any ProjectWindowSessionHandling) {
        self.projectSessions = projectSessions
    }

    func attach(to window: NSWindow?, layout: LitheWindowLayout, title: String? = nil) {
        guard let window else { return }
        if self.window !== window {
            self.window = window
            window.delegate = self
            self.layout = nil
            restoredWorkspaceFrame = nil
        }
        apply(layout, title: title, to: window)
    }

    func toggleWorkspaceZoom() {
        guard let visibleFrame = (window?.screen ?? NSScreen.main)?.visibleFrame else { return }
        toggleWorkspaceZoom(fitting: visibleFrame)
    }

    func toggleWorkspaceZoom(fitting visibleFrame: NSRect) {
        guard layout == .workspace, let window else { return }

        let targetFrame: NSRect
        if Self.framesMatch(window.frame, visibleFrame) {
            targetFrame = restoredWorkspaceFrame.map {
                LitheWindowLayout.frame($0, fitting: visibleFrame)
            } ?? defaultWorkspaceFrame(for: window, fitting: visibleFrame)
            restoredWorkspaceFrame = nil
        } else {
            restoredWorkspaceFrame = window.frame
            targetFrame = visibleFrame
        }
        window.setFrame(targetFrame, display: true, animate: window.isVisible)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if projectSessions.hasActiveProject {
            projectSessions.closeActiveProject()
            return false
        }
        return true
    }

    private func apply(_ layout: LitheWindowLayout, title: String?, to window: NSWindow) {
        window.contentMinSize = layout.minimumContentSize
        if let title {
            window.title = title
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .visible
        } else {
            window.title = ""
            window.titleVisibility = .hidden
        }
        guard self.layout != layout else { return }

        let shouldAnimate = self.layout != nil && window.isVisible
        self.layout = layout
        restoredWorkspaceFrame = nil

        let currentFrame = window.frame
        let targetContentRect = NSRect(origin: .zero, size: layout.contentSize)
        var targetFrame = window.frameRect(forContentRect: targetContentRect)
        targetFrame.origin = NSPoint(
            x: currentFrame.midX - targetFrame.width / 2,
            y: currentFrame.midY - targetFrame.height / 2
        )
        if let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame {
            targetFrame = LitheWindowLayout.frame(targetFrame, fitting: visibleFrame)
        }
        window.setFrame(targetFrame, display: true, animate: shouldAnimate)
    }

    private func defaultWorkspaceFrame(for window: NSWindow, fitting visibleFrame: NSRect) -> NSRect {
        let targetContentRect = NSRect(origin: .zero, size: LitheWindowLayout.workspace.contentSize)
        var targetFrame = window.frameRect(forContentRect: targetContentRect)
        targetFrame.origin = NSPoint(
            x: visibleFrame.midX - targetFrame.width / 2,
            y: visibleFrame.midY - targetFrame.height / 2
        )
        return LitheWindowLayout.frame(targetFrame, fitting: visibleFrame)
    }

    private static func framesMatch(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        let tolerance: CGFloat = 1
        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }
}
