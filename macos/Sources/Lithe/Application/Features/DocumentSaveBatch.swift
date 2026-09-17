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
