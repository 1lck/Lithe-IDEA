import AppKit
import SwiftUI

struct RootView: View {
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
        .background(LitheTheme.window)
        .background(WindowCloseGuard(projectSessions: projectSessions))
        .sheet(isPresented: $model.isSettingsPresented) {
            SettingsView(
                settings: model.settings,
                initialCategory: model.requestedSettingsCategory
            )
                .environmentObject(model)
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
                    .environmentObject(session.runFeature)
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
}

private struct WindowCloseGuard: NSViewRepresentable {
    let projectSessions: ProjectSessionManager

    func makeCoordinator() -> Coordinator {
        Coordinator(projectSessions: projectSessions)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.attach(to: view.window)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.projectSessions = projectSessions
        DispatchQueue.main.async {
            context.coordinator.attach(to: view.window)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        var projectSessions: ProjectSessionManager
        weak var window: NSWindow?

        init(projectSessions: ProjectSessionManager) {
            self.projectSessions = projectSessions
        }

        func attach(to window: NSWindow?) {
            guard let window, self.window !== window else { return }
            self.window = window
            window.delegate = self
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            LitheAppDelegate.confirmUnsavedDocuments(for: projectSessions)
        }
    }
}
