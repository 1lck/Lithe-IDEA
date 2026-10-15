import SwiftUI

/// Status is supplied by the existing workflow; this component owns presentation only.
enum LitheBannerStatus: CaseIterable {
    case info, infoMuted, neutralMuted, success, warning, error

    var iconPath: String? {
        switch self {
        case .info, .infoMuted: "expui/status/info.svg"
        case .neutralMuted: nil
        case .success: "expui/status/success.svg"
        case .warning: "expui/status/warning.svg"
        case .error: "expui/status/error.svg"
        }
    }
}

struct LitheBannerIcon: View {
    let status: LitheBannerStatus

    @ViewBuilder var body: some View {
        if let path = status.iconPath {
            LitheIDEAIcon(resourcePath: path, size: LitheTheme.Metrics.toolbarIconSize,
                          preservesOriginalColors: true)
        }
    }
}

enum LitheBannerLayout { case inline, editor }

/// InlineBannerBase's multiline card, or EditorNotificationPanel's flat strip.
/// All consumers retain their own message, visibility and actions.
struct LitheBanner<Content: View>: View {
    let status: LitheBannerStatus
    var layout: LitheBannerLayout = .inline
    var iconStatus: LitheBannerStatus? = nil
    var isProgress = false
    var dismiss: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: LitheTheme.Banner.gap) {
            if isProgress {
                ProgressView().controlSize(.small)
            } else {
                LitheBannerIcon(status: iconStatus ?? status)
            }
            VStack(alignment: .leading, spacing: LitheTheme.Banner.gap, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, dismiss == nil ? 0 : 22)
        }
        .litheBannerSurface(status, layout: layout)
        .accessibilityElement(children: .contain)
        .overlay(alignment: .topTrailing) {
            if let dismiss {
                Button(action: dismiss) {
                    LitheIDEAIcon(resourcePath: "expui/general/close.svg", size: LitheTheme.Metrics.toolbarIconSize,
                                  preservesOriginalColors: true)
                }
                .buttonStyle(LitheIconButtonStyle(size: LitheTheme.Banner.dismissSize,
                                                     hoverBackground: LitheTheme.MainToolbar.hover,
                                                     pressedBackground: LitheTheme.MainToolbar.pressed))
                .padding(LitheTheme.Banner.dismissInset)
                .help("Dismiss")
                .accessibilityLabel("Dismiss notification")
            }
        }
    }
}

private struct LitheBannerSurface: ViewModifier {
    let status: LitheBannerStatus
    let layout: LitheBannerLayout

    func body(content: Content) -> some View {
        content
            .font(LitheTheme.settingsFont)
            .foregroundStyle(LitheTheme.Banner.foreground)
            .buttonStyle(LitheBannerActionStyle())
            .padding(.horizontal, LitheTheme.Banner.inset)
            .padding(.vertical, layout == .inline ? LitheTheme.Banner.inset : LitheTheme.Banner.editorVerticalInset)
            .frame(minWidth: layout == .inline ? LitheTheme.Banner.minimumWidth : nil,
                   maxWidth: .infinity, alignment: .leading)
            .background(LitheTheme.Banner.background(status))
            .overlay {
                if layout == .inline {
                    RoundedRectangle(cornerRadius: LitheTheme.Banner.cornerRadius)
                        .strokeBorder(LitheTheme.Banner.border(status), lineWidth: 1)
                } else {
                    VStack(spacing: 0) {
                        Rectangle().fill(LitheTheme.Banner.border(status)).frame(height: 1)
                        Spacer(minLength: 0)
                        Rectangle().fill(LitheTheme.Banner.border(status)).frame(height: 1)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: layout == .inline ? LitheTheme.Banner.cornerRadius : 0))
    }
}

/// InlineBanner actions use ordinary link labels, with no separate button background.
struct LitheBannerActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(LitheTheme.settingsFont)
            .foregroundStyle(isEnabled ? LitheTheme.Banner.link : LitheTheme.Banner.disabledText)
            .underline(isHovering && isEnabled)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .lithePointer()
    }
}

extension View {
    func litheBannerSurface(_ status: LitheBannerStatus, layout: LitheBannerLayout = .inline) -> some View {
        modifier(LitheBannerSurface(status: status, layout: layout))
    }

    func litheBannerTitle() -> some View {
        font(LitheTheme.settingsStrongFont).foregroundStyle(LitheTheme.Banner.foreground)
    }
}
