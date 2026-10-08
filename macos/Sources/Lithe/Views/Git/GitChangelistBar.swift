import SwiftUI
import LitheGitModule

struct GitChangelistBar: View {
    @ObservedObject var feature: GitFeatureModel
    @Environment(\.locale) private var locale
    @State private var editing = false
    @State private var editingID: String?
    @State private var name = ""
    @State private var error: String?
    @State private var deletingID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 2) {
                LitheSettingsSelect(
                    selection: Binding(get: { feature.changelists.activeID }, set: { feature.activateChangelist($0) }),
                    options: feature.changelists.lists.map(\.id),
                    width: LitheDropdownMetrics.minimumRootWidth,
                    accessibilityLabel: "ChangeList",
                    title: { id in
                        id == GitLocalChangelists.defaultID
                            ? String(localized: "Default ChangeList", locale: locale)
                            : feature.changelists.lists.first { $0.id == id }?.name ?? ""
                    },
                    localizesTitles: false,
                    expandsToFitOptions: true
                )
                .help("Stage All and Commit use the current ChangeList.")
                Spacer(minLength: 0)
                Button { edit(nil) } label: {
                    LitheIDEAIcon(resourcePath: "expui/general/add.svg", size: LitheTheme.Metrics.toolbarIconSize,
                                  fallbackSystemImage: "plus", preservesOriginalColors: true)
                }
                    .litheToolbarIconButton(isEnabled: !feature.changelistEditingDisabled)
                    .help("New ChangeList")
                    .accessibilityLabel("New ChangeList")
                Button { edit(feature.changelists.activeID) } label: {
                    LitheIDEAIcon(resourcePath: "expui/general/edit.svg", size: LitheTheme.Metrics.toolbarIconSize,
                                  fallbackSystemImage: "pencil", preservesOriginalColors: true)
                }
                    .litheToolbarIconButton(isEnabled: !feature.changelistEditingDisabled && feature.changelists.activeID != GitLocalChangelists.defaultID)
                    .help("Rename ChangeList")
                    .accessibilityLabel("Rename ChangeList")
                Button { deletingID = feature.changelists.activeID } label: {
                    LitheIDEAIcon(resourcePath: "expui/general/delete.svg", size: LitheTheme.Metrics.toolbarIconSize,
                                  fallbackSystemImage: "trash", preservesOriginalColors: true)
                }
                    .litheToolbarIconButton(isEnabled: !feature.changelistEditingDisabled && feature.changelists.activeID != GitLocalChangelists.defaultID)
                    .help("Delete ChangeList")
                    .accessibilityLabel("Delete ChangeList")
            }
            .disabled(feature.changelistEditingDisabled)
            Toggle("Update parent repository references", isOn: $feature.includeChangelistParentReferences)
                .toggleStyle(.checkbox).font(.caption)
                .disabled(feature.changelistEditingDisabled)
            if let error = feature.changelistCommitError {
                Text(LocalizedStringKey(error)).font(.caption).foregroundStyle(LitheTheme.warning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(LitheCenteredPopup(isPresented: $editing, dialogTitle: String(
            localized: editingID == nil ? "New ChangeList" : "Rename ChangeList", locale: locale
        )) {
            GitChangelistDialog(name: $name,
                                error: error, isDisabled: feature.changelistEditingDisabled,
                                save: saveName, cancel: { editing = false })
        }.frame(width: 0, height: 0).allowsHitTesting(false))
        .confirmationDialog("Delete ChangeList?", isPresented: Binding(
            get: { deletingID != nil }, set: { if !$0 { deletingID = nil } }
        ), titleVisibility: .visible) {
            Button("Delete ChangeList", role: .destructive) {
                if let id = deletingID { feature.removeChangelist(id) }
                deletingID = nil
            }
            Button("Cancel", role: .cancel) { deletingID = nil }
        } message: {
            Text("Files return to the default ChangeList and may be included by Stage All. Their Git staging state is unchanged.")
        }
    }

    private func edit(_ id: String?) {
        editingID = id
        name = feature.changelists.lists.first { $0.id == id }?.name ?? ""
        error = nil
        editing = true
    }

    private func saveName() {
        error = feature.saveChangelistName(name, id: editingID)
        if error == nil { editing = false }
    }
}

/// The Commit dialog uses IDEA's labeled editor fields, rather than the New File popup row.
struct GitChangelistDialog: View {
    @Binding var name: String
    let error: String?
    let isDisabled: Bool
    let save: () -> Void
    let cancel: () -> Void
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 6) {
                Text("Name:")
                TextField("ChangeList name", text: $name)
                    .focused($nameFocused)
                    .modifier(LitheCommitDialogInputStyle(focused: nameFocused))
                    .onSubmit(save)
            }
            .disabled(isDisabled)
            if let error { Text(LocalizedStringKey(error)).foregroundStyle(LitheTheme.error) }
            HStack(spacing: 12) {
                Spacer()
                Button("Cancel", action: cancel)
                    .buttonStyle(LitheCommitDialogButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(LitheCommitDialogButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                    .disabled(isDisabled || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .font(LitheTheme.uiFont(size: 13))
        .foregroundStyle(LitheTheme.primaryText)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 340)
        .background(LitheCommitDialogStyle.background)
        .environment(\.lithePointingHandCursorEnabled, false)
        .onExitCommand(perform: cancel)
        .task { nameFocused = true }
    }
}
