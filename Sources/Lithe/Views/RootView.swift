import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

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
            SettingsView(settings: model.settings)
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
    }
}
