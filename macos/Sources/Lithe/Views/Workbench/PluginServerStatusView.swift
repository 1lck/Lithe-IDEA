import SwiftUI
import LitheLanguageIntelligenceModule
import LitheModuleAPI

// Note: 插件自有语言服务器会话与后端决定启动方式见 .agents/notes/implemented/architecture/2026-11-04-plugin-owned-language-server-sessions.md

/// How far the plugin-owned language servers say they are from usable. A
/// server that reports `ready` shows nothing; one that is preparing, limited
/// or failed shows the plugin's own text, because only the plugin knows what
/// it is waiting for. The host adds no wording about any language or tool.
struct PluginServerStatusView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        PluginServerStatusContent(feature: model.languageToolingFeature)
    }
}

private struct PluginServerStatusContent: View {
    /// Observed so that a language change redraws the fallback texts.
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var feature: LanguageToolingFeatureModel

    /// The servers that are not ready, in a stable order.
    private var pending: [(serverID: String, status: PluginServerStatus)] {
        feature.pluginServerStatuses
            .filter { $0.value.state != .ready }
            .sorted { $0.key < $1.key }
            .map { (serverID: $0.key, status: $0.value) }
    }

    var body: some View {
        if let first = pending.first {
            HStack(spacing: 6) {
                if first.status.state == .preparing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "exclamationmark.triangle")
                }
                Text(verbatim: text(for: first.status)).lineLimit(1)
            }
            .font(LitheTheme.uiFont(size: 11))
            .help(pending.map { text(for: $0.status) }.joined(separator: "\n"))
        }
    }

    /// The plugin's message, or a neutral sentence when it sent none.
    private func text(for status: PluginServerStatus) -> String {
        let base = status.message.flatMap { $0.isEmpty ? nil : $0 } ?? fallback(for: status.state)
        guard let percentage = status.percentage else { return base }
        return "\(base) \(percentage)%"
    }

    private func fallback(for state: PluginServerStatus.State) -> String {
        switch state {
        case .preparing, .ready:
            L10n.string("Preparing the language server")
        case .degraded:
            L10n.string("The language server runs with limited features")
        case .failed:
            L10n.string("The language server could not get ready")
        }
    }
}
