/// Saves a window/application scope and checks its live owners before allowing close.
@MainActor
enum DocumentSaveBatch {
    static func save(owners: () -> [any UnsavedDocumentHandling]) async -> Bool {
        var savedAll = true
        for owner in owners() {
            if await !owner.saveAllDocuments() { savedAll = false }
        }
        // Earlier owners can become dirty while a later save is suspended. Read the
        // scope again so newly opened sessions also participate in the close check.
        return savedAll && !owners().contains { owner in
            owner.closingDocuments.isEmpty ? owner.hasUnsavedDocuments
                : owner.closingDocuments.contains(where: \.isDirty)
        }
    }
}

/// Core-owned membership and result rules for one owner's Save All
/// (`document.planSaveBatch` / `document.reduceSaveBatch`). Writes, dialogs and
/// notifications stay with the caller.
@MainActor
enum DocumentSaveBatchCore {
    enum Outcome: String, Encodable { case saved, failed, cancelled }

    private struct Document: Encodable {
        let id: String
        let dirty: Bool
        let readOnly: Bool
        let contentSynchronized: Bool

        @MainActor
        init(_ document: EditorDocument) {
            id = document.id.uuidString
            dirty = document.isDirty
            readOnly = document.isReadOnly
            contentSynchronized = !document.needsEditorSynchronization
        }
    }

    /// Documents the batch writes, in request order. Core failure plans nothing.
    static func members(of documents: [EditorDocument]) -> [EditorDocument] {
        struct Request: Encodable { let documents: [Document] }
        struct Response: Decodable { let members: [String] }
        let result: Result<Response, RustCoreBridge.CoreCallError> = RustCoreBridge().executeResult(
            command: "document.planSaveBatch", payload: Request(documents: documents.map { Document($0) }))
        guard case .success(let response) = result else { return [] }
        let selected = Set(response.members)
        return documents.filter { selected.contains($0.id.uuidString) }
    }

    /// True only when every member saved and no live document is dirty.
    static func isComplete(
        members: [EditorDocument], outcomes: [Outcome], live: [EditorDocument]
    ) -> Bool {
        struct Result_: Encodable { let id: String; let outcome: Outcome }
        struct Request: Encodable {
            let members: [String]
            let results: [Result_]
            let documents: [Document]
        }
        struct Response: Decodable { let status: String }
        let request = Request(
            members: members.map { $0.id.uuidString },
            results: zip(members, outcomes).map { Result_(id: $0.id.uuidString, outcome: $1) },
            documents: live.map { Document($0) })
        let result: Result<Response, RustCoreBridge.CoreCallError> = RustCoreBridge().executeResult(
            command: "document.reduceSaveBatch", payload: request)
        guard case .success(let response) = result else { return false }
        return response.status == "saved"
    }
}
