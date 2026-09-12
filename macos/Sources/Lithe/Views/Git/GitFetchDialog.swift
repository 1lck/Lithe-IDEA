import SwiftUI
import LitheGitModule

struct GitFetchDialog: View {
    @ObservedObject var feature: GitFeatureModel
    let onFetch: (GitFetchOptions) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var loadingDefaults = true
    @State private var defaultsError: String?
    @State private var options = GitFetchOptions()
    @State private var plan: GitFetchPlan?
    @State private var errorMessage: String?

    init(feature: GitFeatureModel, onFetch: @escaping (GitFetchOptions) -> Void) {
        self.feature = feature
        self.onFetch = onFetch
        _options = State(initialValue: feature.defaultFetchOptions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Fetch Options").font(.headline)
            if let root = feature.gitRepositoryRoot {
                Text(verbatim: root.path).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Toggle("Fetch all remotes", isOn: Binding(
                get: { options.remote == nil },
                set: { options.remote = $0 ? nil : "" }
            ))
            if options.remote != nil {
                TextField("Configured remote name", text: Binding(
                    get: { options.remote ?? "" }, set: { options.remote = $0 }
                ))
                .textFieldStyle(.roundedBorder)
            }
            GitFetchPolicyControls(options: $options)
            Text("These choices apply to this Fetch only. Git configuration and credentials remain unchanged.")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text("Planned command").font(.subheadline.weight(.medium))
                if let plan, plan.options == options {
                    Text(verbatim: plan.commandLine)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                } else if let errorMessage {
                    Text(verbatim: errorMessage).foregroundStyle(LitheTheme.error)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(LitheTheme.editor, in: RoundedRectangle(cornerRadius: 6))
            if let defaultsError { Text(verbatim: defaultsError).foregroundStyle(LitheTheme.error) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Fetch") {
                    guard let plan, plan.options == options else { return }
                    onFetch(plan.options)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(loadingDefaults || defaultsError != nil || plan?.options != options || feature.isPerformingBranchOperation || feature.gitRepositoryRoot == nil)
            }
        }
        .padding(24).frame(width: 580)
        .task {
            let result = await feature.resolvedFetchOptions()
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let defaults): options = defaults
            case .failure(let error): defaultsError = error.message
            }
            loadingDefaults = false
        }
        .task(id: options) {
            let requestedOptions = options
            plan = nil
            errorMessage = nil
            let result = await feature.previewFetch(options: requestedOptions)
            guard !Task.isCancelled, options == requestedOptions else { return }
            switch result {
            case .success(let value): plan = value
            case .failure(let error): errorMessage = error.message
            }
        }
        .onChange(of: feature.gitRepositoryRoot) { _ in dismiss() }
    }
}
