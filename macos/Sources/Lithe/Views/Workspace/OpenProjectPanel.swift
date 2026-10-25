import LitheModuleAPI
import SwiftUI

// Note: SSH 连接配置与测试连接见 .agents/notes/implemented/feature/2026-10-24-remote-ssh-connections.md

/// Owns the panel's state while the sheet is shown, so a re-render of the
/// presenting view does not drop the open connection.
struct OpenProjectPanelSheet: View {
    @StateObject private var feature: RemoteConnectionsFeatureModel

    init(feature: @autoclosure @escaping () -> RemoteConnectionsFeatureModel) {
        _feature = StateObject(wrappedValue: feature())
    }

    var body: some View {
        OpenProjectPanel(feature: feature)
    }
}

/// Open, when SSH connections are saved: one panel to pick the folder, on this
/// Mac or on a saved SSH host. Saved connections are only listed here; they
/// are added and edited in the Remote Development window.
struct OpenProjectPanel: View {
    @ObservedObject var feature: RemoteConnectionsFeatureModel
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var localPath = ""
    @State private var localEntries: [FolderListingEntry] = []
    @State private var localError: String?

    private static let sidebarWidth: CGFloat = 168
    private static let localID = "local"

    /// Fixed when the panel opens; see `RemoteConnectionsView.sheetSize`.
    @State private var size = ParentWindowFit.size(
        preferred: CGSize(width: 920, height: 600), minimum: CGSize(width: 560, height: 380)
    )

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar.frame(width: Self.sidebarWidth)
                Rectangle().fill(LitheTheme.divider).frame(width: 1)
                detail
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            footer
        }
        .frame(width: size.width, height: size.height)
        .background(LitheTheme.window)
        .sheet(item: Binding(get: { feature.prompts.first }, set: { _ in })) { prompt in
            RemoteAuthenticationView(prompt: prompt) { feature.answerPrompt($0) }
                .interactiveDismissDisabled()
        }
        .onAppear {
            feature.selectedID = nil
            listLocal(model.localHomeFolderPath)
        }
        .onChange(of: feature.selectedID) { id in
            feature.closeBrowser()
            feature.cancelTest()
            if id != nil { feature.browseRemoteFolder() }
        }
        .onDisappear { feature.close() }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        LitheTreeList(nodes: sidebarNodes, selection: Binding<String?>(
            get: { feature.selectedID?.uuidString ?? Self.localID },
            set: { feature.selectedID = $0.flatMap(UUID.init(uuidString:)) }
        ))
        .background(LitheTheme.settingsSidebar)
    }

    private var sidebarNodes: [LitheTreeListNode] {
        [LitheTreeListNode(id: Self.localID, onSelect: { feature.selectedID = nil }) {
            HStack(spacing: 8) {
                LitheIDEAIcon(resourcePath: "expui/nodes/folder.svg", size: 16, fallbackSystemImage: "folder")
                Text(LocalizedStringKey("Local Folder")).lineLimit(1)
            }
        }, LitheTreeListNode(id: "heading-ssh", isSelectable: false) { LitheSidebarHeading("SSH") }]
            + feature.connections.map { connection in
                LitheTreeListNode(id: connection.id.uuidString, onSelect: { feature.selectedID = connection.id }) {
                    HStack(spacing: 8) {
                        LitheIDEAIcon(resourcePath: "expui/webReferences/server.svg", size: 16,
                                      fallbackSystemImage: "server.rack")
                        Text(verbatim: connection.displayName).lineLimit(1)
                    }
                }
            }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if feature.selection == nil {
            FolderListing(
                path: localPath, parentPath: localPath == "/" ? nil : (localPath as NSString).deletingLastPathComponent,
                entries: localEntries, isLoading: false, error: localError,
                go: { listLocal(($0 as NSString).expandingTildeInPath) },
                enter: { listLocal((localPath as NSString).appendingPathComponent($0)) }
            )
        } else if let browser = feature.browser {
            VStack(alignment: .leading, spacing: 12) {
                RemoteFolderListing(feature: feature, browser: browser)
            }
        } else {
            VStack(spacing: 10) {
                Spacer()
                switch feature.testState {
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(LitheTheme.warning)
                    Text(verbatim: message).multilineTextAlignment(.center).textSelection(.enabled)
                    Button(LocalizedStringKey("Retry")) { feature.browseRemoteFolder() }
                        .buttonStyle(LitheActionButtonStyle())
                default:
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
            .font(LitheTheme.uiFont(size: 12.5))
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: LitheTheme.ActionButton.spacing) {
            Button(LocalizedStringKey("Remote Development")) {
                dismiss()
                DispatchQueue.main.async { model.showRemoteConnections() }
            }
            .buttonStyle(LitheActionButtonStyle())
            Spacer()
            Button(LocalizedStringKey("Cancel")) { dismiss() }
                .buttonStyle(LitheActionButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button(LocalizedStringKey("Open")) {
                if feature.selection == nil { openLocalFolder() } else { feature.openBrowsedFolder() }
            }
            .buttonStyle(LitheActionButtonStyle(isPrimary: true))
            .keyboardShortcut(.defaultAction)
            .disabled(feature.selection == nil ? localPath.isEmpty : (feature.browser?.isLoading ?? true))
        }
        .padding(14)
        .background(LitheTheme.toolHeader)
    }

    /// Lists `path` on this Mac; a path that cannot be read keeps the previous
    /// listing and shows why.
    private func listLocal(_ path: String) {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let entries = model.localFolderEntries(at: normalized) else {
            localError = L10n.string("Enter an absolute path that starts with /.")
            return
        }
        localPath = normalized
        localEntries = entries
        localError = nil
    }

    private func openLocalFolder() {
        let url = URL(fileURLWithPath: localPath, isDirectory: true)
        dismiss()
        // The sheet must be gone before the workspace replaces this window's content.
        DispatchQueue.main.async { model.openProject(url) }
    }
}
