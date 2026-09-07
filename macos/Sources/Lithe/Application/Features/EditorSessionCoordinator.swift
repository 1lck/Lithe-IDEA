import Combine
import Foundation

/// Synchronizes document selection and tab collections without an AppModel dependency.
@MainActor
final class EditorSessionCoordinator {
    private let document: DocumentFeatureModel
    private let media: MediaDocumentFeatureModel
    private var observations: [AnyCancellable]

    init(
        document: DocumentFeatureModel,
        media: MediaDocumentFeatureModel,
        terminalPlacement: TerminalPlacementFeatureModel,
        tabOrder: EditorTabOrderFeatureModel
    ) {
        self.document = document
        self.media = media
        observations = [
            document.$activeDocumentID.dropFirst().sink { [weak media, weak terminalPlacement] id in
                guard id != nil else { return }
                terminalPlacement?.activateDocument()
                media?.deactivate()
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
        document.reset()
        media.reset()
    }

    func restoreDocuments(orderedPaths: [String], activePath: String?, availableFiles: [URL]) async {
        let availablePaths = Set(availableFiles.map { $0.standardizedFileURL.path })
        let paths = orderedPaths.filter { availablePaths.contains($0) }
        await withTaskGroup(of: Void.self) { group in
            for path in paths {
                group.addTask { [document] in
                    await document.openFileAsync(
                        URL(fileURLWithPath: path),
                        isReadOnly: false,
                        displayPath: nil,
                        activateWhenReady: false
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
