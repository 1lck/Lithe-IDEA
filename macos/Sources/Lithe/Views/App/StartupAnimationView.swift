import SwiftUI

/// The startup animation layer.
///
/// The layer is painted above the workbench while the product is starting. It
/// shows the brand lockup, the phase the product is working on, and how far the
/// startup progressed, and it keeps a failed startup on screen with the reason
/// and a way to continue.
///
/// The wording and the progress values come from the shared startup feedback
/// contract, so both products describe the same phase with the same sentence
/// and advance the same indicator.
struct StartupAnimationView: View {
    @ObservedObject var feedback: StartupFeedbackCoordinator

    private let cardWidth: CGFloat = 460
    private let trackWidth: CGFloat = 380

    var body: some View {
        if feedback.isVisible {
            layer
        }
    }

    private var layer: some View {
        ZStack {
            LitheTheme.window
                .ignoresSafeArea()
            card
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(feedback.isFading ? 0 : 1)
        .animation(
            .easeOut(duration: StartupFeedbackTiming.fadeOutDurationInSeconds),
            value: feedback.isFading
        )
    }

    private var card: some View {
        VStack(spacing: 24) {
            brandLockup
            if feedback.outcome == .failed {
                failureContent
            } else {
                progressSection
            }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 44)
        .frame(width: cardWidth)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(LitheTheme.panelBorder.opacity(0.5), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.35), radius: 40, y: 18)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(LitheTheme.raised)
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [LitheTheme.accent.opacity(0.12), .clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
            )
    }

    private var brandLockup: some View {
        VStack(spacing: 10) {
            ZStack {
                RadialGradient(
                    colors: [LitheTheme.accent.opacity(0.30), .clear],
                    center: .center,
                    startRadius: 4,
                    endRadius: 90
                )
                .frame(width: 180, height: 180)
                LitheIcons.appLogo(size: 80)
            }
            Text("LITHE")
                .font(LitheTheme.uiFont(size: 28, weight: .semibold))
                .tracking(10)
                .foregroundStyle(LitheTheme.primaryText)
            Text("PERSONAL WORKBENCH")
                .font(LitheTheme.uiFont(size: 10, weight: .medium))
                .tracking(4)
                .foregroundStyle(LitheTheme.tertiaryText)
        }
    }

    private var progressSection: some View {
        VStack(spacing: 12) {
            progressTrack
            HStack(spacing: 12) {
                Text(LocalizedStringKey(feedback.stage.englishLabel))
                    .font(LitheTheme.uiFont(size: 11, weight: .medium))
                    .textCase(.uppercase)
                    .tracking(1.6)
                    .foregroundStyle(LitheTheme.secondaryText)
                Spacer(minLength: 8)
                Text("\(progressPercentage)%")
                    .font(LitheTheme.uiFont(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(LitheTheme.primaryText)
            }
        }
    }

    private var progressTrack: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(LitheTheme.secondaryText.opacity(0.16))
                .frame(height: 4)
            Capsule()
                .fill(LitheTheme.accent)
                .frame(width: trackWidth * progressFraction, height: 4)
        }
        .frame(width: trackWidth, height: 4)
        .animation(.easeOut(duration: 0.42), value: progressPercentage)
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
        .frame(maxWidth: .infinity)
    }

    private var progressPercentage: Int {
        feedback.outcome == .ready ? 100 : feedback.stage.progress
    }

    private var progressFraction: CGFloat {
        min(max(CGFloat(progressPercentage) / 100, 0), 1)
    }
}
