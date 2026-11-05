import Combine
import Foundation

/// Synchronizes document selection and tab collections without an AppModel dependency.
@MainActor
final class EditorSessionCoordinator {
    private let document: DocumentFeatureModel
    private let media: MediaDocumentFeatureModel
    private let tabOrder: EditorTabOrderFeatureModel
    private let languageServerLogs: LanguageServerLogsModel?
    private var observations: [AnyCancellable]

    init(
        document: DocumentFeatureModel,
        media: MediaDocumentFeatureModel,
        terminalPlacement: TerminalPlacementFeatureModel,
        tabOrder: EditorTabOrderFeatureModel,
        languageServerLogs: LanguageServerLogsModel? = nil
    ) {
        self.document = document
        self.media = media
        self.tabOrder = tabOrder
        self.languageServerLogs = languageServerLogs
        observations = [
            document.$activeDocumentID.dropFirst().sink { [weak media, weak terminalPlacement, weak tabOrder] id in
                guard let id else { return }
                terminalPlacement?.activateDocument()
                media?.deactivate()
                // File opens can select directly on DocumentFeatureModel rather
                // than through AppModel. A utility tab must not mask that open.
                if tabOrder?.focusedItem == .languageLogs { tabOrder?.focus(.document(id)) }
            },
            document.$openDocuments.map { $0.map(\.id) }.removeDuplicates()
                .sink { [weak tabOrder] ids in
                    tabOrder?.reconcileDocuments(orderedIDs: ids)
                },
            media.$openMediaDocuments.map { $0.map(\.id) }.removeDuplicates()
                .sink { [weak tabOrder] ids in
                    tabOrder?.reconcileMedia(orderedIDs: ids)
                }
        ]
    }

    func resetContent() {
        tabOrder.remove(.languageLogs)
        languageServerLogs?.stop()
        document.reset()
        media.reset()
    }

    func restoreDocuments(
        orderedPaths: [String], activePath: String?, availableFiles: [URL],
        readEncodings: [String: DocumentEncoding] = [:],
        saveEncodings: [String: DocumentEncoding] = [:]
    ) async {
        let availablePaths = Set(availableFiles.map { $0.standardizedFileURL.path })
        let paths = orderedPaths.filter { availablePaths.contains($0) }
        await withTaskGroup(of: Void.self) { group in
            for path in paths {
                group.addTask { [document] in
                    await document.openFileAsync(
                        URL(fileURLWithPath: path),
                        isReadOnly: false,
                        displayPath: nil,
                        activateWhenReady: false,
                        encoding: readEncodings[path],
                        saveEncoding: saveEncodings[path]
                    )
                }
            }
        }
        document.reorderDocuments(orderedPaths: paths)
        document.activeDocumentID = activePath.flatMap { path in
            document.openDocuments.first { $0.url.standardizedFileURL.path == path }?.id
        } ?? document.openDocuments.last?.id
    }
}
