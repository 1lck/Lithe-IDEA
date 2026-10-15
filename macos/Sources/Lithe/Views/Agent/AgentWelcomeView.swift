import SwiftUI

/// Agent chooser retained until a selection; built-in choices enter chat and setup choices open settings.
struct AgentWelcomeView: View {
    let onOpenAgent: (String) -> Void
    let onOpenProviders: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Use an Agent in your project")
                    .font(LitheTheme.uiFont(size: 19, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                section("Lithe Agent") {
                    HStack(spacing: 14) {
                        HStack(spacing: 6) {
                            brand("Claude")
                            brand("Codex")
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Welcome to Lithe Agent")
                                .font(LitheTheme.uiFont(size: 13, weight: .medium))
                                .foregroundStyle(LitheTheme.primaryText)
                            Text("Collaborate with Claude and Codex to ask questions, run tasks, and review code changes.")
                                .font(LitheTheme.uiFont(size: 12))
                                .foregroundStyle(LitheTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
                    .background(AgentPanelStyle.welcomeGradient,
                                in: RoundedRectangle(cornerRadius: LitheWelcomeCardStyle.cornerRadius))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("agent-welcome-banner")
                }
                section("Choose an Agent") {
                    LitheWelcomeRow(title: "Codex", action: { onOpenAgent("codex-acp") }) {
                        AgentBrandIcon(name: "Codex", style: .brand)
                    }.accessibilityIdentifier("agent-welcome-codex")
                    LitheWelcomeRow(title: "Claude Agent", action: { onOpenAgent("claude-acp") }) {
                        AgentBrandIcon(name: "Claude", style: .brand)
                    }.accessibilityIdentifier("agent-welcome-claude")
                    LitheWelcomeRow(title: "More Agents…",
                                    subtitle: "Cline, Cursor, Kilo, Mistral, and more with ACP technology",
                                    action: { onOpenAgent(AgentConfiguration.customAgentID) }) {
                        LitheIDEAIcon(resourcePath: "toolwindows/toolWindowAgent", size: 16)
                    }.accessibilityIdentifier("agent-welcome-more")
                }
                section("Use a third-party provider") {
                    LitheWelcomeRow(title: "Custom API provider", action: onOpenProviders) {
                        LitheSystemIcon(systemImage: "key", size: LitheTheme.Metrics.toolbarIconSize)
                    }.accessibilityIdentifier("agent-welcome-providers")
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .litheScrollViewChrome()
        .litheWorkbenchSurface(AgentPanelStyle.canvas)
    }

    private func brand(_ name: String) -> some View {
        AgentBrandIcon(name: name, size: 16, style: .brand)
            .frame(width: 26, height: 26)
            .background(AgentPanelStyle.canvas, in: Circle())
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: LitheWelcomeCardStyle.spacing) {
            Text(title).font(LitheTheme.uiFont(size: 12))
                .foregroundStyle(LitheTheme.secondaryText)
                .padding(.bottom, 6)
            content()
        }
    }
}
