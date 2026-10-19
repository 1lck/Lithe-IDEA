import SwiftUI
import LitheModuleAPI

/// The host supplies the shared header and focus behavior; the body is the
/// declared text or the plugin's packaged page (`ui` 2).
struct DeclarativeToolWindowView: View {
    let contribution: ModuleContribution
    @ObservedObject var model: AppModel
    var icon: WorkbenchContributionIcon? = nil

    var body: some View {
        VStack(spacing: 0) {
            LitheToolWindowHeader(title: contribution.title, icon: icon.map { AnyView($0) }, onMinimize: {
                model.workbenchFeature.setVisibility(.init(rawValue: contribution.id), isVisible: false)
            }) { EmptyView() }
            if contribution.webEntry != nil {
                MacPluginWebToolWindowContent(windowID: contribution.id, model: model)
            } else {
                ScrollView {
                    Text(verbatim: contribution.text ?? "")
                        .font(LitheTheme.uiFont(size: 13))
                        .foregroundStyle(LitheTheme.primaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .litheScrollViewChrome()
            }
        }
        .background(LitheTheme.editor)
        .accessibilityIdentifier("tool-window-" + contribution.id)
    }
}
