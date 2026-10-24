import SwiftUI
import LitheModuleAPI

/// Native presentation only; the feature owns data and events, shared controls own style.
struct PluginNativeToolWindowView: View {
    let contribution: ModuleContribution
    let makeFeature: () throws -> PluginNativeUIFeature
    let releaseFeature: (PluginNativeUIFeature) -> Void
    let onMinimize: () -> Void

    var body: some View {
        PluginNativeToolWindowSession(contribution: contribution, makeFeature: makeFeature,
            releaseFeature: releaseFeature, onMinimize: onMinimize)
            .id(contribution.id)
    }
}

/// A dock slot may reuse this renderer for another contribution. Its feature
/// and release callback must always belong to the same window identity.
private struct PluginNativeToolWindowSession: View {
    let contribution: ModuleContribution
    let onMinimize: () -> Void
    @StateObject private var session: PluginNativePanelSession

    init(contribution: ModuleContribution, makeFeature: @escaping () throws -> PluginNativeUIFeature,
         releaseFeature: @escaping (PluginNativeUIFeature) -> Void,
         onMinimize: @escaping () -> Void) {
        self.contribution = contribution
        self.onMinimize = onMinimize
        _session = StateObject(wrappedValue: PluginNativePanelSession(make: makeFeature, release: releaseFeature))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let feature = session.feature {
                PluginNativePanel(contribution: contribution, feature: feature, onMinimize: onMinimize)
            } else {
                LitheToolWindowHeader(title: contribution.title, onMinimize: onMinimize) { EmptyView() }
                if let failure = session.failure {
                    Text(verbatim: failure).font(LitheTheme.smallFont).foregroundStyle(LitheTheme.warning).padding(8)
                } else { ProgressView().controlSize(.small).padding(8) }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { session.open() }
        .onDisappear { session.close() }
    }
}

/// The resource owner survives body updates and releases its exact handle even
/// when SwiftUI destroys state storage before delivering disappearance callbacks.
@MainActor
private final class PluginNativePanelSession: ObservableObject {
    @Published private(set) var feature: PluginNativeUIFeature?
    @Published private(set) var failure: String?
    private let make: () throws -> PluginNativeUIFeature
    private let release: (PluginNativeUIFeature) -> Void

    init(make: @escaping () throws -> PluginNativeUIFeature, release: @escaping (PluginNativeUIFeature) -> Void) {
        self.make = make
        self.release = release
    }

    func open() {
        guard feature == nil else { return }
        do { feature = try make(); failure = nil; feature?.refresh() }
        catch { failure = (error as? PluginWebBridgeFailure)?.message ?? error.localizedDescription }
    }

    func close() {
        if let feature { release(feature) }
        feature = nil
    }

    isolated deinit {
        if let feature { release(feature) }
    }
}

struct PluginNativePanel: View {
    let contribution: ModuleContribution
    @ObservedObject var feature: PluginNativeUIFeature
    let onMinimize: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            LitheToolWindowHeader(title: contribution.title, onMinimize: onMinimize) {
                ForEach(actions(feature.declaration.toolbar)) { action in
                    Button { feature.perform(action) } label: {
                        WorkbenchContributionIcon(asset: .init(action.icon ?? PluginUIIcon(
                            host: action.kind == .refresh ? "refresh" : "run"), resources: nil), role: .action)
                    }
                    .litheToolbarIconButton(isEnabled: feature.canPerform(action))
                    .help(action.title)
                    .accessibilityLabel(Text(verbatim: action.title))
                    .modifier(LitheToolWindowHoverAction())
                }
            }
            if feature.isBusy { ProgressView().controlSize(.small).padding(4) }
            if let error = feature.error { feedback(error, isError: true) }
            if let message = feature.message { feedback(message, isError: false) }
            if feature.declaration.kind == .form {
                PluginNativeForm(feature: feature)
            } else if feature.rows.isEmpty {
                Text("No items").font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LitheTreeList(feature.rows, selection: Binding(
                    get: { feature.state.selection }, set: { if let id = $0 { feature.select(id) } }),
                    hierarchy: { row in
                        .init(depth: row.depth, isBranch: !(row.node.children ?? []).isEmpty,
                              isExpanded: feature.state.expanded.contains(row.id))
                    }, onExpansion: { row, expanded in
                        if feature.state.expanded.contains(row.id) != expanded { feature.toggle(row.id) }
                    }, contextMenu: { row in
                        actions(feature.declaration.contextMenu).map { action in
                            .action(action.title, localizesTitle: false, isEnabled: !feature.isBusy) {
                                feature.select(row.id)
                                feature.perform(action)
                            }
                        }
                    }) { row in
                        Text(verbatim: row.node.label).lineLimit(1)
                            .accessibilityLabel(Text(verbatim: row.node.label))
                    }
            }
        }
        .background(LitheTheme.editor)
        .accessibilityIdentifier("tool-window-" + contribution.id)
    }

    private func feedback(_ text: String, isError: Bool) -> some View {
        Text(verbatim: text).font(LitheTheme.smallFont)
            .foregroundStyle(isError ? LitheTheme.warning : LitheTheme.secondaryText)
            .textSelection(.enabled).padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actions(_ ids: [String]) -> [PluginNativeUI.Action] {
        ids.compactMap { id in feature.declaration.actions.first { $0.id == id } }
    }

}

/// Controls use the IDE's existing owners; the declaration cannot provide chrome.
private struct PluginNativeForm: View {
    @ObservedObject var feature: PluginNativeUIFeature

    var body: some View {
        GeometryReader { geometry in
            let width = max(0, geometry.size.width - 2 * LitheTheme.Tree.horizontalInset)
            let columns = feature.declaration.layout?.columns ?? 1
            let grid = LitheFormGrid(columns: columns)
            ScrollView {
                grid {
                    ForEach(feature.declaration.controls ?? []) { control in
                        field(control, width: grid.cellWidth(span: control.span ?? columns, width: width))
                            .layoutValue(key: LitheFormGrid.Span.self, value: control.span ?? columns)
                            .accessibilityIdentifier("native-control-" + control.id)
                    }
                }
                .frame(width: width, alignment: .leading)
                .padding(.horizontal, LitheTheme.Tree.horizontalInset)
                .padding(.vertical, LitheTheme.Tree.verticalInset)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: LitheTheme.ActionButton.spacing) { formActions }
                    VStack(alignment: .leading, spacing: LitheTheme.ActionButton.spacing) { formActions }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, LitheTheme.Tree.horizontalInset)
            }
            .litheScrollViewChrome()
        }
    }

    @ViewBuilder private func field(_ control: PluginNativeUI.Control, width: CGFloat) -> some View {
        switch control.kind {
        case .input:
            LitheTextField(verbatim: control.placeholder ?? "", text: textBinding(control),
                           label: control.label, info: control.info, isEnabled: isEnabled(control))
                .onSubmit { feature.commit(control) }
        case .search:
            LitheSearchField(label: control.label, placeholder: control.placeholder ?? "", text: textBinding(control),
                             info: control.info, isEnabled: isEnabled(control))
                .onSubmit { feature.commit(control) }
        case .editor:
            LitheTextEditor(text: textBinding(control), rows: control.rows ?? 4, label: control.label,
                            info: control.info, isEnabled: isEnabled(control))
        case .segmented:
            LitheFormField(title: Text(verbatim: control.label), info: control.info, isEnabled: isEnabled(control)) {
                LitheSettingsSegmentedControl(
                    selection: textBinding(control, commitsChanges: true),
                    options: (control.options ?? []).map(\.id), width: width,
                    title: { id in control.options?.first { $0.id == id }?.label ?? id }, localizesTitles: false)
                    .accessibilityLabel(Text(verbatim: control.label))
            }
        case .stepper:
            LitheFormField(title: Text(verbatim: control.label), info: control.info, isEnabled: isEnabled(control)) {
                LitheSettingsStepper(
                    value: Binding(
                        get: { if case .number(let number) = feature.value(for: control) { return number }; return 0 },
                        set: { if feature.setValue(.number($0), for: control) { feature.commit(control) } }),
                    in: (control.minimum ?? 0)...(control.maximum ?? 1), step: control.step ?? 1, width: width,
                    verbatimAccessibilityLabel: control.label, title: { $0.formatted() })
            }
        case .select:
            LitheFormField(title: Text(verbatim: control.label), info: control.info, isEnabled: isEnabled(control)) {
                LitheSettingsSelect(
                    selection: Binding(
                        get: { if case .text(let id) = feature.value(for: control) { return id }; return "" },
                        set: { if feature.setValue(.text($0), for: control) { feature.commit(control) } }),
                    options: (control.options ?? []).map(\.id), width: width,
                    accessibilityLabel: control.label,
                    title: { id in control.options?.first { $0.id == id }?.label ?? id }, localizesTitles: false)
            }
        case .checkbox:
            HStack(spacing: LitheInfoTip.labelSpacing) {
                LitheSettingsCheckbox(
                    isOn: Binding(
                        get: { if case .checked(let checked) = feature.value(for: control) { return checked }; return false },
                        set: { if feature.setValue(.checked($0), for: control) { feature.commit(control) } }),
                    verbatimTitle: control.label)
                    .disabled(!isEnabled(control))
                if let info = control.info { LitheInfoTip(verbatim: info) }
            }

        }
    }
    private func isEnabled(_ control: PluginNativeUI.Control) -> Bool {
        !feature.isBusy && control.enabled != false
    }

    private func textBinding(_ control: PluginNativeUI.Control, commitsChanges: Bool = false) -> Binding<String> {
        Binding(
            get: { if case .text(let text) = feature.value(for: control) { return text }; return "" },
            set: {
                if feature.setValue(.text($0), for: control), commitsChanges { feature.commit(control) }
            })
    }

    private var formActions: some View {
        ForEach(feature.declaration.buttons ?? []) { button in
            HStack(spacing: LitheInfoTip.labelSpacing) {
                Button { feature.perform(button) } label: { Text(verbatim: button.label) }
                    .disabled(!feature.canPerform(button))
                    .buttonStyle(LitheActionButtonStyle(isPrimary: button.primary == true))
                if let info = button.info { LitheInfoTip(verbatim: info) }
            }
            .accessibilityIdentifier("native-button-" + button.id)
        }
    }
}
