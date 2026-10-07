import SwiftUI

/// The global notification balloon. Message lifetime and history remain model-owned.
struct WorkbenchNotificationBanner: View {
    @Environment(\.locale) private var locale
    @State private var isExpanded = false
    let message: String
    var collapsedCount = 0
    /// How often the message has appeared; shown as a suffix from the second
    /// time on. Required so a caller cannot silently drop the merged count.
    var occurrenceCount: Int
    /// Localization bundle for the message and its count suffix. Injectable so a
    /// capture can render the shipped translation instead of the format key.
    var bundle: Bundle = .main
    var showHistory: () -> Void = {}
    let dismiss: () -> Void

    private var localizedMessage: String {
        String(localized: String.LocalizationValue(message), bundle: bundle, locale: locale)
    }
    private var displayMessage: String {
        WorkbenchNotificationPresentation.message(localizedMessage,
            occurrenceCount: occurrenceCount,
            locale: locale,
            bundle: bundle)
    }
    private var lineHeight: CGFloat { NSLayoutManager().defaultLineHeight(for: LitheTheme.uiNSFont(size: 13)) }
    private var textHeight: CGFloat {
        ceil((displayMessage as NSString).boundingRect(with: NSSize(width: LitheTheme.Notification.width - 70,
            height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: LitheTheme.uiNSFont(size: 13)]).height)
    }
    private var canExpand: Bool { textHeight > 2 * lineHeight }

    var body: some View {
        VStack(spacing: 0) {
            messageContent
            if collapsedCount > 0 {
                Button(action: showHistory) {
                    Text(collapsedCount == 1 ? LocalizedStringKey("1 more notification") : "\(collapsedCount) more notifications")
                        .font(LitheTheme.uiFont(size: 13))
                        .foregroundStyle(LitheTheme.Notification.moreForeground)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.litheNoPress)
                .background {
                    GeometryReader { geometry in
                        RoundedRectangle(cornerRadius: LitheTheme.Notification.cornerRadius)
                            .fill(LitheTheme.Notification.moreBackground)
                            .overlay(alignment: .top) {
                                LitheTheme.Notification.moreBackground
                                    .frame(height: max(0, geometry.size.height - LitheTheme.Notification.cornerRadius))
                            }
                    }
                }
                .accessibilityHint("Open notification history")
            }
        }
        .frame(width: LitheTheme.Notification.width, alignment: .topLeading)
        .litheNotificationSurface()
        .overlay(alignment: .topTrailing) {
            Button(action: dismiss) {
                LitheIDEAIcon(resourcePath: "expui/general/close.svg", size: 16, preservesOriginalColors: true)
            }
            .buttonStyle(LitheIconButtonStyle(size: 20, cornerRadius: 4,
                                              hoverBackground: LitheTheme.Notification.iconHover))
            .padding(.top, 7)
            .padding(.trailing, 7)
            .accessibilityLabel("Dismiss notification")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workbench-notification")
    }

    private var messageContent: some View {
        // New UI: content insets (4,4,6,0), a 32pt icon panel + 2pt gap,
        // and the one/two-line configuration's 11pt top / 14pt bottom spacing.
        HStack(alignment: .top, spacing: 8) {
            LitheIDEAIcon(resourcePath: "expui/status/info.svg", size: 16, preservesOriginalColors: true)
                .padding(.top, 15)
            Group {
                if isExpanded {
                    ScrollView {
                        messageText
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: min(textHeight, 10 * lineHeight))
                } else {
                    messageText.lineLimit(2)
                }
            }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 15)
                .padding(.bottom, 20)
        }
        .padding(.leading, 14)
        .padding(.trailing, 32)
        .overlay(alignment: .bottomTrailing) {
            if canExpand {
                Button { isExpanded.toggle() } label: {
                    LitheIDEAIcon(resourcePath: isExpanded ? "expui/general/chevronUp.svg" : "expui/general/chevronDown.svg",
                                  size: 16, preservesOriginalColors: true)
                }
                .buttonStyle(LitheIconButtonStyle(size: 20, cornerRadius: 4,
                                                  hoverBackground: LitheTheme.Notification.iconHover))
                .padding(.trailing, 7)
                .padding(.bottom, 7)
                .accessibilityLabel(Text(isExpanded ? "Collapse notification" : "Expand notification"))
            }
        }
    }

    private var messageText: some View {
        Text(displayMessage)
            .font(LitheTheme.uiFont(size: 13, weight: .regular))
            .foregroundStyle(LitheTheme.Notification.foreground)
            .fixedSize(horizontal: false, vertical: true)
    }
}
