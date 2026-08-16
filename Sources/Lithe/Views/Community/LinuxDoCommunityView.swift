import SwiftUI

struct LinuxDoCommunityView: View {
    @EnvironmentObject private var webSession: LinuxDoAnonymousWebSession
    @State private var pageTitle = "LINUX DO"
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var navigationAction: LinuxDoWebNavigationAction = .none

    var body: some View {
        VStack(spacing: 0) {
            header
            if let errorMessage {
                failureView(errorMessage)
            } else {
                LinuxDoAnonymousWebView(
                    session: webSession,
                    title: $pageTitle,
                    canGoBack: $canGoBack,
                    canGoForward: $canGoForward,
                    isLoading: $isLoading,
                    errorMessage: $errorMessage,
                    navigationAction: navigationAction
                )
            }
        }
        .background(LitheTheme.sidebar)
        .onAppear { webSession.resume() }
        .onDisappear { webSession.releaseAfterInactivity() }
    }

    private var header: some View {
        LitheToolWindowHeader(
            title: pageTitle,
            systemImage: "bubble.left.and.bubble.right",
            subtitle: "Guest"
        ) {
            Button { navigationAction = .home(UUID()) } label: {
                Label("Topics", systemImage: "list.bullet").labelStyle(.iconOnly)
            }
            .litheIconButton()
            .help("Latest topics")

            Button { navigationAction = .reload(UUID()) } label: {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Reload", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                }
            }
            .litheIconButton()
            .help("Reload")
        }
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "wifi.exclamationmark")
                .font(.title)
                .foregroundStyle(LitheTheme.warning)
            Text("Couldn’t load LINUX DO")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(LitheTheme.secondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            Button("Try Again") {
                errorMessage = nil
                navigationAction = .reload(UUID())
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
