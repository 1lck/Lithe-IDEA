import SwiftUI

struct PluginToolchainSettingsView: View {
    @ObservedObject var feature: PluginToolchainFeatureModel
    let chooseToolchainPath: () -> Void
    let downloadLatestToolchain: () -> Void
    let installLanguageServer: () -> Void

    private var usesChinese: Bool {
        Locale.current.language.languageCode?.identifier == "zh"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(feature.snapshot.displayName)
                .font(.system(size: 15, weight: .semibold))
            status
            HStack(spacing: 8) {
                Button(usesChinese ? "选择路径…" : "Choose Path…") {
                    chooseToolchainPath()
                }
                .buttonStyle(.bordered)
                .disabled(isBusy)
                Button(usesChinese ? "下载官方工具链" : "Download Official Toolchain") {
                    downloadLatestToolchain()
                }
                .buttonStyle(.borderedProminent)
                .tint(LitheTheme.accent)
                .disabled(isBusy)
                if feature.snapshot.canInstallLanguageServer {
                    Button(usesChinese ? "安装语言服务器" : "Install Language Server") {
                        installLanguageServer()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy || !isConfigured)
                }
            }
            Text(usesChinese
                ? "选择本地工具链，或下载官方版本。语言服务器将使用选定的工具链。"
                : "Choose a local toolchain or download an official version. The language server uses the selected toolchain.")
                .font(LitheTheme.smallFont)
                .foregroundStyle(LitheTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: LitheTheme.Metrics.cornerRadius).fill(LitheTheme.settingsSurface))
        .overlay { RoundedRectangle(cornerRadius: LitheTheme.Metrics.cornerRadius).stroke(LitheTheme.divider, lineWidth: 1) }
    }

    @ViewBuilder
    private var status: some View {
        switch feature.snapshot.state {
        case .missing:
            Label(usesChinese ? "未配置工具链" : "Toolchain is not configured", systemImage: "exclamationmark.triangle")
                .foregroundStyle(LitheTheme.warning)
        case .configured(let path, let version):
            VStack(alignment: .leading, spacing: 4) {
                Label(version ?? (usesChinese ? "已配置" : "Configured"), systemImage: "checkmark.circle.fill")
                Text(path)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .foregroundStyle(LitheTheme.success)
        case .checking:
            progress(usesChinese ? "正在验证工具链…" : "Validating the toolchain…")
        case .downloading:
            progress(usesChinese ? "正在下载并安装官方工具链…" : "Downloading and installing the official toolchain…")
        case .installingServer:
            progress(usesChinese ? "正在安装语言服务器…" : "Installing the language server…")
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(LitheTheme.error)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
        }
        .foregroundStyle(LitheTheme.secondaryText)
    }

    private var isBusy: Bool {
        switch feature.snapshot.state {
        case .checking, .downloading, .installingServer: true
        default: false
        }
    }

    private var isConfigured: Bool {
        if case .configured = feature.snapshot.state { return true }
        return false
    }
}
