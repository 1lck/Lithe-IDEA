import AppKit
import LitheLocalHistoryModule
import SwiftUI

enum LitheWindowID {
    static let welcome = "welcome"
    static let settings = "settings"
    static let project = "project"
}

private struct ProjectWindowScopeKey: EnvironmentKey {
    static let defaultValue: ProjectWindowScope = .primary
}

extension EnvironmentValues {
    var projectWindowScope: ProjectWindowScope {
        get { self[ProjectWindowScopeKey.self] }
        set { self[ProjectWindowScopeKey.self] = newValue }
    }
}

/// Installs window present callbacks from a live SwiftUI scene environment so
/// they are not tied to the primary window's lifetime alone.
private struct ProjectWindowSceneBridge: View {
    @EnvironmentObject private var projectWindowLauncher: ProjectWindowLauncher
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear(perform: installCallbacks)
    }

    private func installCallbacks() {
        projectWindowLauncher.presentProjectWindow = { windowID in
            openWindow(id: LitheWindowID.project, value: windowID)
        }
        projectWindowLauncher.dismissProjectWindow = { windowID in
            ProjectWindowAppKitDismisser.dismiss(windowID: windowID)
        }
        projectWindowLauncher.presentPrimaryWindow = {
            openWindow(id: LitheWindowID.welcome)
        }
    }
}

enum ProjectWindowAppKitDismisser {
    static func dismiss(windowID: UUID) {
        let identifier = NSUserInterfaceItemIdentifier(windowID.uuidString)
        for window in NSApplication.shared.windows where window.identifier == identifier {
            window.close()
        }
    }
}

struct RootView: View {
    let scope: ProjectWindowScope
    @EnvironmentObject private var projectSessions: ProjectSessionManager
    @EnvironmentObject private var projectWindowLauncher: ProjectWindowLauncher
    @EnvironmentObject private var updateChecker: UpdateChecker
    @Environment(\.openWindow) private var openWindow
    @State private var didStartAutomaticUpdateCheck = false

    init(scope: ProjectWindowScope = .primary) {
        self.scope = scope
    }

    var body: some View {
        ZStack {
            ForEach(visibleSessions) { session in
                ProjectSessionContent(
                    session: session,
                    isActive: isSessionActive(session)
                )
            }
            if let scopedModel {
                ActiveSessionChrome(scope: scope, session: scopedModel)
            }
        }
        .environment(\.projectWindowScope, scope)
        .background(ProjectWindowSceneBridge())
        .frame(
            minWidth: windowLayout.minimumContentSize.width,
            minHeight: windowLayout.minimumContentSize.height
        )
        .background(LitheTheme.window)
        .sheet(item: scopedPendingProjectOpen) { request in
            OpenProjectLocationDialog(request: request) { placement, doNotAskAgain in
                projectSessions.resolvePendingOpen(
                    request,
                    placement: placement,
                    doNotAskAgain: doNotAskAgain
                )
            }
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
                    primaryButton: .default(Text("Open Release Page")) {
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
            guard scope == .primary else { return }
            guard !didStartAutomaticUpdateCheck else { return }
            didStartAutomaticUpdateCheck = true
            guard !LithePerformanceBaseline.isEnabled else { return }
            await updateChecker.checkForUpdates()
        }
    }

    private var visibleSessions: [AppModel] {
        projectSessions.sessions(in: scope)
    }

    private func isSessionActive(_ session: AppModel) -> Bool {
        session.id == projectSessions.activeSessionID(in: scope)
    }

    private var scopedModel: AppModel? {
        let sessions = visibleSessions
        guard !sessions.isEmpty else { return nil }
        return projectSessions.activeModel(in: scope)
    }

    private var windowLayout: LitheWindowLayout {
        guard let model = scopedModel else { return .welcome }
        if model.standaloneFileURL != nil { return .standalone }
        return model.workspaceURL == nil ? .welcome : .workspace
    }

    private var scopedPendingProjectOpen: Binding<PendingProjectOpen?> {
        Binding(
            get: { projectSessions.pendingProjectOpen(in: scope) },
            set: { newValue in
                guard newValue == nil,
                      let pending = projectSessions.pendingProjectOpen,
                      projectSessions.scope(for: pending.sourceSessionID) == scope else {
                    return
                }
                projectSessions.cancelPendingOpen()
            }
        )
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
}

private struct ProjectSessionContent: View {
    @ObservedObject var session: AppModel
    let isActive: Bool

    var body: some View {
        Group {
            if session.standaloneFileURL != nil {
                StandaloneEditorView()
            } else if session.workspaceURL == nil {
                WelcomeView()
            } else {
                WorkbenchView()
                    .ignoresSafeArea(.container, edges: .top)
            }
        }
        .environmentObject(session)
        .environmentObject(session.editorChrome)
        .environmentObject(session.editorDiagnosticsStore)
        .opacity(isActive ? 1 : 0)
        .allowsHitTesting(isActive)
        .accessibilityHidden(!isActive)
        .zIndex(isActive ? 1 : 0)
    }
}

private struct ActiveSessionChrome: View {
    let scope: ProjectWindowScope
    @ObservedObject var session: AppModel
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var projectSessions: ProjectSessionManager

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .background(
                WindowCloseGuard(
                    windowHandler: windowHandler,
                    layout: windowLayout,
                    title: windowTitle
                )
            )
            .onReceive(session.workbenchFeature.$isSettingsPresented) { isPresented in
                guard isPresented else { return }
                openWindow(id: LitheWindowID.settings)
            }
            .sheet(isPresented: Binding(
                get: { session.workbenchFeature.isCloneRepositoryPresented },
                set: { session.workbenchFeature.isCloneRepositoryPresented = $0 }
            )) {
                CloneRepositoryView()
                    .environmentObject(session)
            }
            .sheet(item: scopedLocalHistoryRequest) { request in
                LocalHistoryView(request: request)
                    .environmentObject(session)
            }
            .sheet(item: scopedProjectLocalHistoryRequest) { request in
                ProjectLocalHistoryView(request: request)
                    .environmentObject(session)
            }
            .confirmationDialog(
                "Close Running Terminal?",
                isPresented: terminalCloseConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Close Terminal", role: .destructive) {
                    session.confirmTerminalClose()
                }
                Button("Cancel", role: .cancel) {
                    session.cancelTerminalClose()
                }
            } message: {
                Text("Closing this terminal will stop its shell and any running command.")
            }
    }

    private var windowHandler: any ProjectWindowSessionHandling {
        switch scope {
        case .primary:
            return PrimaryProjectWindowSessions(manager: projectSessions)
        case .dedicated(let windowID):
            return DedicatedProjectWindowSessions(manager: projectSessions, windowID: windowID)
        }
    }

    private var windowLayout: LitheWindowLayout {
        if session.standaloneFileURL != nil { return .standalone }
        return session.workspaceURL == nil ? .welcome : .workspace
    }

    private var scopedLocalHistoryRequest: Binding<LocalHistoryRequest?> {
        Binding(
            get: { session.localHistoryRequest },
            set: { session.localHistoryRequest = $0 }
        )
    }

    private var scopedProjectLocalHistoryRequest: Binding<ProjectLocalHistoryRequest?> {
        Binding(
            get: { session.projectLocalHistoryRequest },
            set: { session.projectLocalHistoryRequest = $0 }
        )
    }

    private var terminalCloseConfirmationPresented: Binding<Bool> {
        Binding(
            get: { session.pendingTerminalCloseSessionID != nil },
            set: { isPresented in
                if !isPresented {
                    session.cancelTerminalClose()
                }
            }
        )
    }

    private var windowTitle: String? {
        if windowLayout == .standalone {
            return session.standaloneFileURL?.lastPathComponent ?? "Lithe"
        }
        if windowLayout == .workspace {
            return session.workspaceURL?.lastPathComponent ?? "Lithe"
        }
        return String(
            localized: "Welcome to Lithe",
            bundle: .main,
            locale: session.settings.language.locale
        )
    }
}

private struct WindowCloseGuard: NSViewRepresentable {
    let windowHandler: any ProjectWindowSessionHandling
    let layout: LitheWindowLayout
    let title: String?

    func makeCoordinator() -> LitheWindowCoordinator {
        LitheWindowCoordinator(projectSessions: windowHandler)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.attach(to: view.window, layout: layout, title: title)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.projectSessions = windowHandler
        DispatchQueue.main.async {
            context.coordinator.attach(to: view.window, layout: layout, title: title)
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: LitheWindowCoordinator) {
        coordinator.detach()
    }
}

enum LitheWindowLayout: Equatable {
    case welcome
    case workspace
    case standalone

    static let welcomeContentSize = NSSize(width: 900, height: 620)
    static let workspaceContentSize = NSSize(width: 1440, height: 900)
    static let standaloneContentSize = NSSize(width: 1200, height: 760)
    static let standaloneMinimumContentSize = NSSize(width: 760, height: 480)
    static let standaloneMaximumContentSize = NSSize(width: 1200, height: 820)
    static let screenMargin: CGFloat = 12

    var contentSize: NSSize {
        switch self {
        case .welcome: Self.welcomeContentSize
        case .workspace: Self.workspaceContentSize
        case .standalone: Self.standaloneContentSize
        }
    }

    var minimumContentSize: NSSize {
        switch self {
        case .welcome: NSSize(width: 820, height: 560)
        case .workspace: NSSize(width: 980, height: 640)
        case .standalone: Self.standaloneMinimumContentSize
        }
    }

    static func standaloneContentSize(fitting visibleFrame: NSRect) -> NSSize {
        NSSize(
            width: min(
                max(visibleFrame.width * 0.65, standaloneMinimumContentSize.width),
                standaloneMaximumContentSize.width
            ),
            height: min(
                max(visibleFrame.height * 0.72, standaloneMinimumContentSize.height),
                standaloneMaximumContentSize.height
            )
        )
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
protocol ProjectWindowSessionHandling: UnsavedDocumentHandling {
    var hasActiveProject: Bool { get }
    var hasActiveStandaloneFile: Bool { get }
    /// When true, closing the active project dismisses the window instead of
    /// converting it into a welcome shell.
    var shouldDismissWindowWhenClosingActiveSession: Bool { get }
    var windowScope: ProjectWindowScope { get }
    func closeActiveProject()
    func requestCloseActiveWorkbenchItem() -> Bool
    func requestCloseActiveSession() -> Bool
    func resetForProjectWindowClose() async
    func noteWindowBecameKey()
}

@MainActor
final class LitheWindowCoordinator: NSObject, NSWindowDelegate {
    private enum NativeWindowCloseIntent {
        case commandW
        case projectCleanupCompleted
        case dismissActiveSession
    }

    var projectSessions: any ProjectWindowSessionHandling
    weak var window: NSWindow?
    private var layout: LitheWindowLayout?
    private var restoredWorkspaceFrame: NSRect?
    private var closeCommandMonitor: Any?
    private var pendingNativeWindowCloseIntent: NativeWindowCloseIntent?
    private var nativeWindowCloseTask: Task<Void, Never>?
    private let confirmUnsavedDocuments: @MainActor (any UnsavedDocumentHandling) -> Bool
    private var isDetached = false

    init(
        projectSessions: any ProjectWindowSessionHandling,
        confirmUnsavedDocuments: @escaping @MainActor (any UnsavedDocumentHandling) -> Bool = {
            LitheAppDelegate.confirmUnsavedDocuments(
                for: $0,
                context: .projectWindowClose
            )
        }
    ) {
        self.projectSessions = projectSessions
        self.confirmUnsavedDocuments = confirmUnsavedDocuments
    }

    func attach(to window: NSWindow?, layout: LitheWindowLayout, title: String? = nil) {
        guard !isDetached, let window else { return }
        if self.window !== window {
            stopMonitoringCloseCommand()
            self.window = window
            window.delegate = self
            self.layout = nil
            restoredWorkspaceFrame = nil
            startMonitoringCloseCommand()
        }
        if case .dedicated(let windowID) = projectSessions.windowScope {
            window.identifier = NSUserInterfaceItemIdentifier(windowID.uuidString)
        }
        apply(layout, title: title, to: window)
        if window.isKeyWindow {
            projectSessions.noteWindowBecameKey()
        }
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

    func windowDidBecomeKey(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        projectSessions.noteWindowBecameKey()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if case .projectCleanupCompleted? = pendingNativeWindowCloseIntent {
            pendingNativeWindowCloseIntent = nil
            return true
        }
        guard nativeWindowCloseTask == nil else { return false }
        if case .commandW? = pendingNativeWindowCloseIntent {
            pendingNativeWindowCloseIntent = nil
            guard confirmUnsavedDocuments(projectSessions) else { return false }
            // Cmd+W closes this window's sessions only. Dedicated windows always
            // dismiss; primary windows either dismiss or tear down primary scope
            // without touching other project windows.
            closeWindowAfterProjectCleanup(sender)
            return false
        }
        if projectSessions.hasActiveProject || projectSessions.hasActiveStandaloneFile {
            if projectSessions.shouldDismissWindowWhenClosingActiveSession {
                guard confirmUnsavedDocuments(projectSessions) else { return false }
                pendingNativeWindowCloseIntent = .dismissActiveSession
                closeWindowAfterProjectCleanup(sender)
                return false
            }
            return projectSessions.requestCloseActiveSession()
        }
        return true
    }

    func performCloseCommand() {
        guard let window else { return }
        guard nativeWindowCloseTask == nil else { return }
        guard !projectSessions.requestCloseActiveWorkbenchItem() else { return }
        pendingNativeWindowCloseIntent = .commandW
        defer { pendingNativeWindowCloseIntent = nil }
        window.performClose(nil)
    }

    private func closeWindowAfterProjectCleanup(_ sender: NSWindow) {
        guard nativeWindowCloseTask == nil else { return }
        let projectSessions = projectSessions
        nativeWindowCloseTask = Task { @MainActor [weak self, weak sender] in
            await projectSessions.resetForProjectWindowClose()
            guard let self else { return }
            defer { self.nativeWindowCloseTask = nil }
            guard !self.isDetached,
                  let sender,
                  self.window === sender else { return }
            self.pendingNativeWindowCloseIntent = .projectCleanupCompleted
            defer { self.pendingNativeWindowCloseIntent = nil }
            sender.performClose(nil)
        }
    }

    private func startMonitoringCloseCommand() {
        guard closeCommandMonitor == nil else { return }
        closeCommandMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self, Self.isCloseCommand(event, for: self.window) else { return event }
            self.performCloseCommand()
            return nil
        }
    }

    func stopMonitoringCloseCommand() {
        guard let closeCommandMonitor else { return }
        NSEvent.removeMonitor(closeCommandMonitor)
        self.closeCommandMonitor = nil
    }

    func detach() {
        isDetached = true
        stopMonitoringCloseCommand()
        window = nil
    }

    static func isCloseCommand(_ event: NSEvent, for window: NSWindow?) -> Bool {
        guard event.type == .keyDown,
              !event.isARepeat,
              event.window === window,
              event.charactersIgnoringModifiers?.lowercased() == "w" else {
            return false
        }
        let closeModifiers = event.modifierFlags.intersection([
            .command, .control, .option, .shift
        ])
        return closeModifiers == .command
    }

    deinit {
        if let closeCommandMonitor {
            NSEvent.removeMonitor(closeCommandMonitor)
        }
    }

    private func apply(_ layout: LitheWindowLayout, title: String?, to window: NSWindow) {
        window.contentMinSize = layout.minimumContentSize
        if let title {
            window.title = title
            window.titlebarAppearsTransparent = true
            window.titleVisibility = layout == .workspace ? .hidden : .visible
        } else {
            window.title = ""
            window.titleVisibility = .hidden
        }
        guard self.layout != layout else { return }

        let shouldAnimate = self.layout != nil && window.isVisible
        self.layout = layout
        restoredWorkspaceFrame = nil

        let currentFrame = window.frame
        let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame
        let targetContentSize: NSSize
        if layout == .standalone, let visibleFrame {
            targetContentSize = LitheWindowLayout.standaloneContentSize(fitting: visibleFrame)
        } else {
            targetContentSize = layout.contentSize
        }
        let targetContentRect = NSRect(origin: .zero, size: targetContentSize)
        var targetFrame = window.frameRect(forContentRect: targetContentRect)
        targetFrame.origin = NSPoint(
            x: currentFrame.midX - targetFrame.width / 2,
            y: currentFrame.midY - targetFrame.height / 2
        )
        if let visibleFrame {
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
