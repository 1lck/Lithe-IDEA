import SwiftUI
import LitheModuleAPI

/// The host supplies the shared header, focus behavior and plain-text renderer.
/// ponytail: text-only UI covers static views; interactive plugin content needs
/// a versioned host component protocol, not an embedded executable renderer.
struct DeclarativeToolWindowView: View {
    let contribution: ModuleContribution
    @ObservedObject var model: AppModel
    var icon: WorkbenchContributionIcon? = nil

    var body: some View {
        VStack(spacing: 0) {
            LitheToolWindowHeader(title: contribution.title, icon: icon.map { AnyView($0) }, onMinimize: {
                model.workbenchFeature.setVisibility(.init(rawValue: contribution.id), isVisible: false)
            }) { EmptyView() }
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
        .background(LitheTheme.editor)
        .accessibilityIdentifier("tool-window-" + contribution.id)
    }
}
