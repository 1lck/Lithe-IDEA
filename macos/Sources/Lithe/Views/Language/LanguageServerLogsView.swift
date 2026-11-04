import SwiftUI
import LitheModuleAPI

/// Server output has its own window; application diagnostics keep their separate entry.
struct LanguageServerLogsView: View {
    @ObservedObject var feature: LanguageServerLogsModel
    @ObservedObject var coordinator: LanguageServerLogsCoordinator

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                LitheSettingsSelect(selection: Binding(get: { feature.providerID }, set: feature.select),
                    options: [""] + feature.servers.map(\.id), width: 200,
                    accessibilityLabel: "Language Server", title: serverTitle, localizesTitles: false)
                Text("Server Logs").foregroundStyle(LitheTheme.accent)
                LitheInfoTip("Shows the selected language server's session events, stderr and server messages. Application logs are available separately in Logs and Diagnostics.")
                Spacer(minLength: 0)
            }.padding(12).font(LitheTheme.uiFont(size: 12))
            Divider()
            if let error = feature.error { Text(error).foregroundStyle(LitheTheme.error).padding(8) }
            LanguageServerLogOutput(model: feature.logs)
        }
        .background(LitheTheme.editor)
        .frame(minWidth: 720, minHeight: 400)
        .onAppear {
            if let request = coordinator.request { feature.apply(request) }
            feature.start()
        }
        .onReceive(coordinator.$request) { request in
            if let request { feature.apply(request) }
        }
        .onDisappear { feature.stop() }
    }
    private func serverTitle(_ id: String) -> String {
        id.isEmpty ? L10n.string("All language servers") : feature.servers.first { $0.id == id }?.displayName ?? id
    }
}

private struct LanguageServerLogOutput: View {
    @ObservedObject var model: LogWindowModel
    @State private var wrapsLines = false
    private var output: String {
        model.state.records.map { record in
            let diagnostic = record.fields["diagnostic"] ?? record.fields["error"]
            let detail = diagnostic.map { $0.isEmpty ? "" : "\n" + $0 } ?? ""
            return "[\(record.level)] \(record.ts)  \(record.channel)  \(record.event)\n\(record.msg)\(detail)\n"
        }.joined()
    }
    var body: some View {
        VStack(spacing: 0) {
            if let error = model.error {
                HStack {
                    Text(error).foregroundStyle(LitheTheme.error)
                    Button("Retry") { model.retry() }
                }.padding(8)
            }
            OutputTextView(output: output, searchRoots: [], fileExists: { _ in false },
                emptyMessage: L10n.string("No matching language server logs"), wrapsLines: wrapsLines,
                showsConsoleToolbar: true, onClearOutput: model.clearDisplay,
                onToggleWrapsLines: { wrapsLines.toggle() }, onOpenLocation: { _, _, _ in })
        }
    }
}
