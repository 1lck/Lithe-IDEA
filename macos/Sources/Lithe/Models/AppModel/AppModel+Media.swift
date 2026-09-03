import Foundation

extension AppModel {
    func configureMediaViewerRegistry() {
        services.binaryFileViewerRegistry.register(
            BinaryFileViewerRegistration(
                identifier: "mac.image",
                fileExtensions: ["png", "jpg", "jpeg", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp"],
                magicSignatures: [
                    BinaryFileMagicSignature(bytes: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])),
                    BinaryFileMagicSignature(bytes: Data([0xFF, 0xD8, 0xFF])),
                    BinaryFileMagicSignature(bytes: Data("GIF87a".utf8)),
                    BinaryFileMagicSignature(bytes: Data("GIF89a".utf8))
                ],
                open: { [weak self] request in
                    self?.openMediaFile(
                        request.url,
                        kind: .image,
                        activateWhenReady: request.activateWhenReady
                    )
                }
            )
        )
        services.binaryFileViewerRegistry.register(
            BinaryFileViewerRegistration(
                identifier: "mac.video",
                fileExtensions: ["mp4", "mov", "m4v"],
                open: { [weak self] request in
                    self?.openMediaFile(
                        request.url,
                        kind: .video,
                        activateWhenReady: request.activateWhenReady
                    )
                }
            )
        )
    }

    func openMediaFile(
        _ url: URL,
        kind: MediaDocumentKind,
        activateWhenReady: Bool = true
    ) {
        let normalizedURL = url.standardizedFileURL
        if activateWhenReady {
            selectedChange = nil
            closeBranchComparison()
            editorNavigationTarget = nil
            terminalPlacementFeature.activateDocument()
            activeDocumentID = nil
        }
        let media = mediaFeature.open(
            url: normalizedURL,
            kind: kind,
            activateWhenReady: activateWhenReady
        )
        editorTabOrderFeature.moveToEnd(.media(media.id))
    }

    func selectMediaDocument(_ media: MediaDocument) {
        guard openMediaDocuments.contains(where: { $0.id == media.id }) else { return }
        terminalPlacementFeature.activateDocument()
        activeDocumentID = nil
        mediaFeature.select(media)
    }

    func closeMediaDocument(_ media: MediaDocument) {
        if standaloneFileURL?.standardizedFileURL == media.url.standardizedFileURL {
            closeStandaloneFile()
            return
        }
        let mediaItem = EditorTabItem.media(media.id)
        let tabItemsBeforeClose = editorTabItems
        let fallbackItem: EditorTabItem? = {
            guard let index = tabItemsBeforeClose.firstIndex(of: mediaItem) else { return nil }
            if tabItemsBeforeClose.indices.contains(index + 1) {
                return tabItemsBeforeClose[index + 1]
            }
            guard index > tabItemsBeforeClose.startIndex else { return nil }
            return tabItemsBeforeClose[index - 1]
        }()
        let wasActive = activeMediaDocumentID == media.id

        mediaFeature.close(media)
        editorTabOrderFeature.remove(mediaItem)
        guard wasActive else { return }

        switch fallbackItem {
        case .document(let documentID):
            if let document = openDocuments.first(where: { $0.id == documentID }) {
                selectEditorDocument(document)
            }
        case .terminal(let sessionID):
            if let session = terminalSessions.first(where: { $0.id == sessionID }) {
                selectEditorTerminalSession(session)
            }
        case .media(let mediaID):
            if let nextMedia = openMediaDocuments.first(where: { $0.id == mediaID }) {
                selectMediaDocument(nextMedia)
            }
        case nil:
            activeDocumentID = nil
            terminalPlacementFeature.activateDocument()
        }
    }

    func openMediaInDefaultApplication(_ media: MediaDocument) {
        platformUI.open(media.url)
    }
}
