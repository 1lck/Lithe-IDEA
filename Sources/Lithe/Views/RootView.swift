import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.workspaceURL == nil {
                WelcomeView()
            } else {
                WorkbenchView()
                    .ignoresSafeArea(.container, edges: .top)
            }
        }
        .background(LitheTheme.window)
        .sheet(isPresented: $model.isSettingsPresented) {
            SettingsView(settings: model.settings)
                .environmentObject(model)
        }
    }
}
