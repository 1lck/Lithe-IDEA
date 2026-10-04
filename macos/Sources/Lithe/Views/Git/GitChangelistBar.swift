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
            HStack(spacing: 6) {
                LitheSettingsSelect(
                    selection: Binding(get: { feature.changelists.activeID }, set: { feature.activateChangelist($0) }),
                    options: feature.changelists.lists.map(\.id),
                    width: 180,
                    accessibilityLabel: "ChangeList",
                    title: { id in
                        id == GitLocalChangelists.defaultID
                            ? String(localized: "Default ChangeList", locale: locale)
                            : feature.changelists.lists.first { $0.id == id }?.name ?? ""
                    },
                    localizesTitles: false,
                    expandsToFitOptions: true
                )
                .help("Select the ChangeList to commit")
                Button { edit(nil) } label: { Image(systemName: "plus") }
                    .help("New ChangeList")
                Button { edit(feature.changelists.activeID) } label: { Image(systemName: "pencil") }
                    .disabled(feature.changelists.activeID == GitLocalChangelists.defaultID)
                    .help("Rename ChangeList")
                Button { deletingID = feature.changelists.activeID } label: { Image(systemName: "trash") }
                    .disabled(feature.changelists.activeID == GitLocalChangelists.defaultID)
                    .help("Delete ChangeList")
            }
            .controlSize(.small)
            .disabled(feature.changelistEditingDisabled)
            Text("Stage All and Commit use the current ChangeList.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Update parent repository references", isOn: $feature.includeChangelistParentReferences)
                .toggleStyle(.checkbox).font(.caption)
                .disabled(feature.changelistEditingDisabled)
            if let error = feature.changelistCommitError {
                Text(LocalizedStringKey(error)).font(.caption).foregroundStyle(LitheTheme.warning)
            }
        }
        .padding(8)
        .sheet(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 12) {
                Text(LocalizedStringKey(editingID == nil ? "New ChangeList" : "Rename ChangeList")).font(.headline)
                TextField("ChangeList name", text: $name).onSubmit(saveName)
                if let error { Text(LocalizedStringKey(error)).foregroundStyle(.red).font(.caption) }
                HStack {
                    Spacer()
                    Button("Cancel") { editing = false }
                    Button("Save", action: saveName).keyboardShortcut(.defaultAction)
                        .disabled(feature.changelistEditingDisabled)
                }
            }.padding(20).frame(width: 360)
        }
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
