import SwiftUI
import LitheCoreContracts

/// Both placements read the same session-owned snapshot; opening details starts no work.
struct ProjectPreparationStatusView: View {
    @EnvironmentObject private var model: AppModel
    var compact = false

    var body: some View {
        ProjectPreparationContent(feature: model.languageToolingFeature, compact: compact)
    }
}

private struct ProjectPreparationContent: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var feature: LanguageToolingFeatureModel
    var compact: Bool
    @State private var showingDetails = false

    private var chinese: Bool { settings.language == .simplifiedChinese }
    private var snapshot: ProjectPreparationSnapshot? {
        feature.projectPreparation
    }

    var body: some View {
        if let snapshot, snapshot.phase != "stopped", !compact || snapshot.status != "ready" {
            Button { showingDetails.toggle() } label: {
                HStack(spacing: 6) {
                    if snapshot.status == "loading" {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: snapshot.status == "failed" ? "exclamationmark.triangle" : "checkmark.circle")
                    }
                    Text(snapshot.status == "failed"
                        ? (chinese ? "Java 项目准备失败" : "Java project preparation failed")
                        : phaseTitle(snapshot.phase))
                        .lineLimit(1)
                }
                .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help(chinese ? "查看项目准备详情" : "View project preparation details")
            .popover(isPresented: $showingDetails, arrowEdge: compact ? .bottom : .top) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(phaseTitle(snapshot.phase)).font(.headline)
                    ForEach(["starting", "importing", "configuring", "building"], id: \.self) { phase in
                        Text((snapshot.phase == phase ? "› " : "· ") + phaseTitle(phase))
                            .font(.system(size: 12, weight: snapshot.phase == phase ? .semibold : .regular))
                    }
                    Text(chinese
                        ? "Java 工作区准备完成后才能启动。普通后台索引不阻塞运行，编译在运行前执行。"
                        : "The Java workspace must finish preparation before launch. Background indexing does not block running; compilation runs before launch.")
                        .font(.system(size: 12))
                    Button(chinese ? "语言服务设置与重试" : "Language service settings and retry") {
                        showingDetails = false
                        model.showSettings(category: .lsp)
                    }
                    Button(chinese ? "查看日志" : "View logs") {
                        showingDetails = false
                        model.showSettings(category: .diagnostics)
                    }
                }
                .padding(16)
                .frame(width: 330)
            }
        }
    }

    private func phaseTitle(_ phase: String) -> String {
        switch phase {
        case "starting": chinese ? "正在启动 Java 服务" : "Starting Java service"
        case "importing": chinese ? "正在导入 Java 项目与依赖" : "Importing Java project and dependencies"
        case "configuring": chinese ? "正在同步 Java 项目配置" : "Synchronizing Java project configuration"
        case "building": chinese ? "正在构建 Java 项目" : "Building Java project"
        case "ready": chinese ? "Java 项目模型已就绪" : "Java project model ready"
        default: chinese ? "Java 项目准备已停止" : "Java project preparation stopped"
        }
    }
}
