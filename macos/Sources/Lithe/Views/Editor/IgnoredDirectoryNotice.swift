import SwiftUI
import LitheCoreContracts
import LitheWorkspaceModule

/// Opening an ignore file only inspects; the selected directories are excluded on confirmation.
struct IgnoredDirectoryNotice: View {
    @ObservedObject var feature: WorkspaceFeatureModel
    let fileURL: URL
    @State private var suggestions = WorkspaceIgnoredDirectorySuggestions()
    @State private var failed = false
    @State private var showingDirectories = false
    @State private var selected: Set<String> = []
    @State private var applying = false
    @State private var retry = 0

    private struct QueryID: Equatable {
        let file: URL
        let generation: Int
        let revision: UInt64
        let dismissed: Bool
        let retry: Int
    }
    private var queryID: QueryID {
        QueryID(file: fileURL, generation: feature.workspaceGeneration,
                revision: feature.indexingStatus.revision,
                dismissed: feature.indexingSettings.ignoredDirectoryNoticeDismissed == true, retry: retry)
    }

    var body: some View {
        // Keep a mounted container while the first query has no content yet.
        // An empty conditional Group never starts its task on macOS.
        VStack(spacing: 0) {
            if feature.contains(fileURL), !queryID.dismissed, feature.indexingStatus.supportsExclusions {
                if failed {
                    LitheBanner(status: .warning, layout: .editor) {
                        HStack {
                            Text("Could not check ignored directories.")
                            Spacer()
                            Button("Retry") { retry += 1 }
                        }
                    }
                } else if !suggestions.directories.isEmpty {
                    LitheBanner(status: .info, layout: .editor) {
                        HStack(spacing: LitheTheme.Banner.actionGap) {
                            Text("Some ignored directories are still included in analysis and search.")
                            Spacer(minLength: 0)
                            Button("View Directories") {
                                selected = Set(suggestions.directories)
                                showingDirectories = true
                            }
                            Button("Don't Show Again") { feature.dismissIgnoredDirectoryNotice() }
                            LitheInfoTip("Excluding directories removes them from Lithe analysis and search without changing Git commit candidates. Files remain available in the project tree. Language servers may still scan build-declared modules.")
                        }
                    }
                } else if suggestions.incomplete || suggestions.gitIgnoreFailed {
                    LitheBanner(status: .warning, layout: .editor) {
                        Text("Some directories could not be checked. The list may be incomplete.")
                        Button("Retry") { retry += 1 }
                    }
                }
            }
        }
        .task(id: queryID) {
            let identity = queryID
            suggestions = WorkspaceIgnoredDirectorySuggestions()
            failed = false
            showingDirectories = false
            guard feature.contains(fileURL), !identity.dismissed, feature.indexingStatus.supportsExclusions,
                  identity.revision != 0 else { return }
            do {
                let result = try await feature.ignoredDirectorySuggestions()
                guard !Task.isCancelled, queryID == identity else { return }
                suggestions = result
            } catch is CancellationError {} catch {
                guard !Task.isCancelled, queryID == identity else { return }
                failed = true
            }
        }
        .sheet(isPresented: $showingDirectories) { directoryPicker }
    }

    private var directoryPicker: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ignored Directories").font(LitheTheme.uiFont(size: 16, weight: .semibold))
            if suggestions.incomplete || suggestions.gitIgnoreFailed {
                LitheBanner(status: .warning) {
                    Text("Some directories could not be checked. The list may be incomplete.")
                }
            }
            LitheTreeList(suggestions.directories, id: \.self, selection: $selected,
                          togglesSelectionOnClick: true) { path in
                HStack {
                    Image(systemName: selected.contains(path) ? "checkmark.square.fill" : "square")
                        .foregroundStyle(selected.contains(path) ? LitheTheme.accent : LitheTheme.secondaryText)
                    Text(verbatim: path).lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(height: 280)
            .disabled(applying)
            if failed {
                Text("Could not check ignored directories.").foregroundStyle(LitheTheme.secondaryText)
            }
            if let error = feature.indexingError { Text(error).foregroundStyle(LitheTheme.secondaryText) }
            HStack(spacing: LitheTheme.ActionButton.spacing) {
                Spacer()
                Button("Cancel") { showingDirectories = false }
                    .buttonStyle(LitheActionButtonStyle()).keyboardShortcut(.cancelAction)
                    .disabled(applying)
                Button("Exclude Selected") {
                    let generation = feature.workspaceGeneration
                    let requested = selected
                    applying = true
                    Task {
                        defer { applying = false }
                        guard feature.workspaceGeneration == generation else { return }
                        do {
                            try await feature.excludeIgnoredDirectories(requested)
                            showingDirectories = false
                            retry += 1
                        } catch is CancellationError {} catch { failed = true }
                    }
                }
                .buttonStyle(LitheActionButtonStyle(isPrimary: true))
                .keyboardShortcut(.defaultAction)
                .disabled(applying || selected.isEmpty)
            }
        }
        .padding(20).frame(width: 600).background(LitheTheme.raised)
        .interactiveDismissDisabled(applying)
    }
}
