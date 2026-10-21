import SwiftUI

/// The startup animation layer.
///
/// The layer is painted above the workbench while the product is starting. It
/// shows the brand logo and the phase the product is working on, and it keeps a
/// failed startup on screen with the reason and a way to continue.
///
/// The wording comes from the shared startup feedback contract, so both
/// products describe the same phase with the same sentence.
struct StartupAnimationView: View {
    @ObservedObject var feedback: StartupFeedbackCoordinator

    var body: some View {
        if feedback.isVisible {
            layer
        }
    }

    private var layer: some View {
        ZStack {
            LitheTheme.window
                .ignoresSafeArea()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(feedback.isFading ? 0 : 1)
        .animation(
            .easeOut(duration: StartupFeedbackTiming.fadeOutDurationInSeconds),
            value: feedback.isFading
        )
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 16) {
            LitheIcons.appLogo(size: 64)
            if feedback.outcome == .failed {
                failureContent
            } else {
                loadingContent
            }
        }
        .padding(32)
    }

    private var loadingContent: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(LocalizedStringKey(feedback.stage.englishLabel))
                .font(LitheTheme.uiFont(size: 13))
                .foregroundStyle(LitheTheme.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }

    private var failureContent: some View {
        VStack(spacing: 10) {
            Text("Lithe could not finish starting")
                .font(LitheTheme.uiFont(size: 14, weight: .medium))
                .foregroundStyle(LitheTheme.primaryText)
            Text(LocalizedStringKey(feedback.stage.englishLabel))
                .font(LitheTheme.uiFont(size: 12))
                .foregroundStyle(LitheTheme.secondaryText)
            if let message = feedback.failureMessage, !message.isEmpty {
                Text(verbatim: message)
                    .font(LitheTheme.uiFont(size: 12))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            Button("Continue") {
                feedback.dismiss()
            }
            .buttonStyle(LitheActionButtonStyle(isPrimary: true))
        }
        .frame(maxWidth: 360)
    }
}
