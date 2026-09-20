import SwiftUI
import LitheCoreContracts

struct JavaLaunchDecisionDialog: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    let request: PendingJavaLaunchDecision

    private var chinese: Bool { settings.language == .simplifiedChinese }
    private var report: JavaBuildReport? { request.failure.report }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(
                chinese ? "Java 构建未成功" : "Java build did not succeed",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.headline)
            .foregroundStyle(LitheTheme.warning)

            Text(explanation)
                .font(.system(size: 13))
            Text(request.failure.message)
                .font(.system(size: 12))
                .foregroundStyle(LitheTheme.secondaryText)

            if let report {
                VStack(alignment: .leading, spacing: 5) {
                    evidenceRow(
                        chinese ? "错误范围" : "Marker scope",
                        value: report.markerScope == .workspace
                            ? (chinese ? "整个工作区（可能包含无关模块）" : "Workspace (may include unrelated modules)")
                            : (chinese ? "请求的启动目标及其依赖" : "Requested launch target and dependencies")
                    )
                    evidenceRow(
                        chinese ? "构建耗时" : "Build elapsed",
                        value: "\(report.elapsedMilliseconds) ms"
                    )
                }
                .padding(10)
                .background(LitheTheme.sidebar.opacity(0.65))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Text(chinese
                ? "“仍然运行”会使用已经解析出的产物继续本次启动，不会再次构建。"
                : "Run Anyway continues this launch with the resolved output and does not build again.")
                .font(.system(size: 12))
                .foregroundStyle(LitheTheme.secondaryText)

            HStack(spacing: 8) {
                Button(chinese ? "仍然运行" : "Run Anyway") {
                    model.completeJavaLaunchDecision(.runOnce, requestID: request.id)
                }
                .buttonStyle(.borderedProminent)

                Button(chinese ? "始终继续" : "Always Continue") {
                    model.completeJavaLaunchDecision(.alwaysContinue, requestID: request.id)
                }

                if report?.recovery == .rebuildJavaIndex {
                    Button(chinese ? "重建 Java 索引" : "Rebuild Java Index") {
                        model.completeJavaLaunchDecision(.rebuildIndex, requestID: request.id)
                    }
                }

                Spacer(minLength: 8)

                Button(chinese ? "查看日志" : "Open Logs") {
                    model.completeJavaLaunchDecision(.cancel, requestID: request.id)
                    model.showSettings(category: .diagnostics)
                }
                Button(chinese ? "取消" : "Cancel", role: .cancel) {
                    model.completeJavaLaunchDecision(.cancel, requestID: request.id)
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 590)
        .interactiveDismissDisabled()
    }

    private var explanation: String {
        if request.failure.code == "javaBuildFailed"
            || report?.builderFailedEarlier == true {
            return chinese
                ? "Java 语言服务的构建器在本次会话中发生过崩溃，当前错误标记可能是残留。你仍可运行已有产物，或重建索引恢复可信状态。"
                : "The Java language-service builder failed in this session, so these error markers may be stale. You can run the existing output or rebuild the index."
        }
        return chinese
            ? "Java 语言服务报告了编译错误，但错误也可能来自依赖工程或工作区中的其他模块。"
            : "The Java language service reported compilation errors, which may come from dependencies or other workspace modules."
    }

    private func evidenceRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label + ":")
                .foregroundStyle(LitheTheme.secondaryText)
            Text(value)
                .textSelection(.enabled)
        }
        .font(.system(size: 12))
    }
}
