import Foundation

enum DocumentLifecycleStatus: String, Codable, Sendable {
    case clean
    case dirty
    case saving
    case conflict
}

struct DocumentLifecycleState: Codable, Equatable, Sendable {
    let status: DocumentLifecycleStatus
    let revision: UInt64
    let savedRevision: UInt64?
    let saveRevision: UInt64?
    let operationId: String?

    static func clean(revision: UInt64) -> Self {
        Self(
            status: .clean,
            revision: revision,
            savedRevision: nil,
            saveRevision: nil,
            operationId: nil
        )
    }

    static func dirty(revision: UInt64, savedRevision: UInt64) -> Self {
        Self(
            status: .dirty,
            revision: revision,
            savedRevision: savedRevision,
            saveRevision: nil,
            operationId: nil
        )
    }

    var hasUnpersistedText: Bool { status != .clean }
}

enum DocumentLifecycleEventType: String, Codable, Sendable {
    case edited
    case saveStarted
    case saveSucceeded
    case saveFailed
    case externalChanged
    case reloadSucceeded
    case keepEditor
    case loadDisk
}

struct DocumentLifecycleEvent: Codable, Equatable, Sendable {
    let type: DocumentLifecycleEventType
    let revision: UInt64?
    let matchesSavedContent: Bool?
    let operationId: String?

    static func edited(revision: UInt64, matchesSavedContent: Bool) -> Self {
        Self(
            type: .edited,
            revision: revision,
            matchesSavedContent: matchesSavedContent,
            operationId: nil
        )
    }

    static func saveStarted(operationID: String) -> Self {
        operation(.saveStarted, operationID: operationID)
    }

    static func saveSucceeded(operationID: String) -> Self {
        operation(.saveSucceeded, operationID: operationID)
    }

    static func saveFailed(operationID: String) -> Self {
        operation(.saveFailed, operationID: operationID)
    }

    static let externalChanged = Self(type: .externalChanged)
    static let keepEditor = Self(type: .keepEditor)
    static let loadDisk = Self(type: .loadDisk)

    private init(
        type: DocumentLifecycleEventType,
        revision: UInt64?,
        matchesSavedContent: Bool?,
        operationId: String?
    ) {
        self.type = type
        self.revision = revision
        self.matchesSavedContent = matchesSavedContent
        self.operationId = operationId
    }

    private static func operation(
        _ type: DocumentLifecycleEventType,
        operationID: String
    ) -> Self {
        Self(type: type, revision: nil, matchesSavedContent: nil, operationId: operationID)
    }

    private init(type: DocumentLifecycleEventType) {
        self.init(type: type, revision: nil, matchesSavedContent: nil, operationId: nil)
    }
}

enum DocumentLifecycleAction: String, Codable, Sendable {
    case none
    case writeToDisk
    case reloadFromDisk
    case showConflict
    case reportSaveFailure
    case ignoreStaleResult
}

struct DocumentLifecycleDecision: Codable, Equatable, Sendable {
    let state: DocumentLifecycleState
    let action: DocumentLifecycleAction
}

protocol DocumentLifecycleDeciding: Sendable {
    func decide(
        state: DocumentLifecycleState,
        event: DocumentLifecycleEvent,
        operationID: String
    ) throws -> DocumentLifecycleDecision
}
