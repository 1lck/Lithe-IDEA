import Combine
import Foundation

/// Owns commit text and AI replacement confirmation, independently of Git and AI
/// module activation. Callers supply the generation operation for this draft.
@MainActor
final class CommitDraftFeatureModel: ObservableObject {
    enum GenerationOutcome: Equatable {
        case filledDraft
        case awaitingConfirmation
    }

    @Published var message = ""
    @Published var amend = false
    @Published private(set) var isGenerating = false
    @Published private(set) var pendingGeneratedMessage: String?

    func generate(using operation: () async throws -> String?) async throws -> GenerationOutcome? {
        guard !isGenerating else { return nil }
        isGenerating = true
        pendingGeneratedMessage = nil
        defer { isGenerating = false }
        guard let generated = try await operation(), !Task.isCancelled else { return nil }
        if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message = generated
            return .filledDraft
        }
        pendingGeneratedMessage = generated
        return .awaitingConfirmation
    }

    @discardableResult
    func applyGeneratedMessage() -> Bool {
        guard let pendingGeneratedMessage else { return false }
        message = pendingGeneratedMessage
        self.pendingGeneratedMessage = nil
        return true
    }

    func discardGeneratedMessage() {
        pendingGeneratedMessage = nil
    }

    func clearAfterCommit() {
        message = ""
        amend = false
    }
}
