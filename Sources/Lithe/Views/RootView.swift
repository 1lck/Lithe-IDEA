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
                    .environmentObject(model.javaRunService)
                    .ignoresSafeArea(.container, edges: .top)
            }
        }
        .background(LitheTheme.window)
        .sheet(isPresented: $model.isSettingsPresented) {
            SettingsView(
                settings: model.settings,
                projectRuntime: model.projectRuntimeService
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
            if let downloadURL = notice.downloadURL {
                return Alert(
                    title: Text(LocalizedStringKey(notice.title)),
                    message: Text(LocalizedStringKey(notice.message)),
                    primaryButton: .default(Text("Download")) {
                        updateChecker.openRelease(downloadURL)
                    },
                    secondaryButton: .cancel()
                )
            }
            return Alert(
                title: Text(LocalizedStringKey(notice.title)),
                message: Text(LocalizedStringKey(notice.message)),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}
