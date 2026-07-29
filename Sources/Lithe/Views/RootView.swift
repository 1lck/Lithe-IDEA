import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.workspaceURL == nil {
                WelcomeView()
            } else {
                WorkbenchView()
            }
        }
        .background(LitheTheme.window)
    }
}
