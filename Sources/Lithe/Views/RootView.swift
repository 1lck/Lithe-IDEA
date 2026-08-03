import AppKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var updateChecker: UpdateChecker

    var body: some View {
        Group {
            if model.workspaceURL == nil {
                WelcomeView()
            } else {
                WorkbenchView()
                    .environmentObject(model.runFeature)
                    .ignoresSafeArea(.container, edges: .top)
            }
        }
        .background(LitheTheme.window)
        .background(WindowCloseGuard(model: model))
        .sheet(isPresented: $model.isSettingsPresented) {
            SettingsView(
                settings: model.settings,
                runtimeFeature: model.runtimeFeature
            )
                .environmentObject(model)
        }
        .sheet(isPresented: $model.isCloneRepositoryPresented) {
            CloneRepositoryView()
                .environmentObject(model)
        }
        .sheet(item: $model.localHistoryRequest) { request in
            LocalHistoryView(request: request)
                .environmentObject(model)
        }
        .sheet(item: $model.projectLocalHistoryRequest) { request in
            ProjectLocalHistoryView(request: request)
                .environmentObject(model)
        }
        .task {
            await updateChecker.checkForUpdates()
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
    }
}

private struct WindowCloseGuard: NSViewRepresentable {
    let model: AppModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.attach(to: view.window)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.model = model
        DispatchQueue.main.async {
            context.coordinator.attach(to: view.window)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        var model: AppModel
        weak var window: NSWindow?

        init(model: AppModel) {
            self.model = model
        }

        func attach(to window: NSWindow?) {
            guard let window, self.window !== window else { return }
            self.window = window
            window.delegate = self
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            LitheAppDelegate.confirmUnsavedDocuments(for: model)
        }
    }
}
