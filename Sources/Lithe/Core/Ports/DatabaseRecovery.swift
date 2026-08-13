import Foundation

struct DatabaseBackupSchedule: Codable, Equatable, Identifiable, Sendable {
    let profileID: UUID
    var isEnabled: Bool
    var intervalHours: Int
    var retentionCount: Int
    var nextRunAt: Date

    var id: UUID { profileID }

    init(profileID: UUID, isEnabled: Bool = true, intervalHours: Int = 24, retentionCount: Int = 14, nextRunAt: Date = Date()) {
        self.profileID = profileID
        self.isEnabled = isEnabled
        self.intervalHours = max(1, intervalHours)
        self.retentionCount = max(1, retentionCount)
        self.nextRunAt = nextRunAt
    }
}

struct DatabaseRecoveryPoint: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let profileID: UUID
    let reason: String
    let createdAt: Date
    let byteCount: Int
    let fileName: String
    let originalByteCount: Int
    let isCompressed: Bool
    let sha256: String

    private enum CodingKeys: String, CodingKey { case id, profileID, reason, createdAt, byteCount, fileName, originalByteCount, isCompressed, sha256 }

    init(id: UUID, profileID: UUID, reason: String, createdAt: Date, byteCount: Int, fileName: String, originalByteCount: Int, isCompressed: Bool, sha256: String = "") {
        self.id = id
        self.profileID = profileID
        self.reason = reason
        self.createdAt = createdAt
        self.byteCount = byteCount
        self.fileName = fileName
        self.originalByteCount = originalByteCount
        self.isCompressed = isCompressed
        self.sha256 = sha256
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        profileID = try container.decode(UUID.self, forKey: .profileID)
        reason = try container.decode(String.self, forKey: .reason)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        byteCount = try container.decode(Int.self, forKey: .byteCount)
        fileName = try container.decode(String.self, forKey: .fileName)
        originalByteCount = try container.decodeIfPresent(Int.self, forKey: .originalByteCount) ?? byteCount
        isCompressed = try container.decodeIfPresent(Bool.self, forKey: .isCompressed) ?? false
        sha256 = try container.decodeIfPresent(String.self, forKey: .sha256) ?? ""
    }
}

struct DatabaseAuditEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let profileID: UUID
    let action: String
    let summary: String
    let createdAt: Date
    let recoveryPointID: UUID?
    let rowsAffected: UInt64?
    let succeeded: Bool
    let errorMessage: String?
}

enum DatabaseExecutionSource: String, Codable, Equatable, Sendable {
    case sql
    case redis
    case nacos
}

enum DatabaseExecutionStatus: String, Codable, Equatable, Sendable {
    case succeeded
    case failed
    case cancelled
}

struct DatabaseExecutionEvent: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let profileID: UUID
    let profileName: String
    let source: DatabaseExecutionSource
    let operation: String
    let startedAt: Date
    let durationMilliseconds: Int
    let status: DatabaseExecutionStatus
    let rowsReturned: Int?
    let rowsAffected: UInt64?
    let errorMessage: String?
}

protocol DatabaseRecoveryStoring: AnyObject, Sendable {
    func createRecoveryPoint(profileID: UUID, reason: String, data: Data) throws -> DatabaseRecoveryPoint
    func createRecoveryPoint(profileID: UUID, reason: String, fileURL: URL, expectedSHA256: String, progress: ((Double) -> Void)?) throws -> DatabaseRecoveryPoint
    func recoveryPoints(for profileID: UUID?) -> [DatabaseRecoveryPoint]
    func data(for point: DatabaseRecoveryPoint) throws -> Data
    func fileURL(for point: DatabaseRecoveryPoint) throws -> URL
    func delete(_ point: DatabaseRecoveryPoint) throws
    func appendAudit(_ entry: DatabaseAuditEntry, maximumEntries: Int) throws
    func auditEntries(for profileID: UUID?) -> [DatabaseAuditEntry]
    func appendExecutionEvent(_ event: DatabaseExecutionEvent, maximumEntries: Int) throws
    func executionEvents(for profileID: UUID?) -> [DatabaseExecutionEvent]
    func deleteExecutionEvents(for profileID: UUID) throws
}

final class UnavailableDatabaseRecoveryStore: DatabaseRecoveryStoring, @unchecked Sendable {
    private let error = CocoaError(.featureUnsupported)
    func createRecoveryPoint(profileID: UUID, reason: String, data: Data) throws -> DatabaseRecoveryPoint { throw error }
    func createRecoveryPoint(profileID: UUID, reason: String, fileURL: URL, expectedSHA256: String, progress: ((Double) -> Void)?) throws -> DatabaseRecoveryPoint { throw error }
    func recoveryPoints(for profileID: UUID?) -> [DatabaseRecoveryPoint] { [] }
    func data(for point: DatabaseRecoveryPoint) throws -> Data { throw error }
    func fileURL(for point: DatabaseRecoveryPoint) throws -> URL { throw error }
    func delete(_ point: DatabaseRecoveryPoint) throws { throw error }
    func appendAudit(_ entry: DatabaseAuditEntry, maximumEntries: Int) throws { throw error }
    func auditEntries(for profileID: UUID?) -> [DatabaseAuditEntry] { [] }
    func appendExecutionEvent(_ event: DatabaseExecutionEvent, maximumEntries: Int) throws { throw error }
    func executionEvents(for profileID: UUID?) -> [DatabaseExecutionEvent] { [] }
    func deleteExecutionEvents(for profileID: UUID) throws { throw error }
}

extension DatabaseRecoveryStoring {
    func createRecoveryPoint(profileID: UUID, reason: String, fileURL: URL, expectedSHA256: String = "", progress: ((Double) -> Void)? = nil) throws -> DatabaseRecoveryPoint {
        try createRecoveryPoint(profileID: profileID, reason: reason, fileURL: fileURL, expectedSHA256: expectedSHA256, progress: progress)
    }

    func recoveryPoints(for profileID: UUID? = nil) -> [DatabaseRecoveryPoint] {
        recoveryPoints(for: profileID)
    }

    func appendAudit(_ entry: DatabaseAuditEntry, maximumEntries: Int = 500) throws {
        try appendAudit(entry, maximumEntries: maximumEntries)
    }

    func auditEntries(for profileID: UUID? = nil) -> [DatabaseAuditEntry] {
        auditEntries(for: profileID)
    }

    func appendExecutionEvent(_ event: DatabaseExecutionEvent, maximumEntries: Int = 1_000) throws {
        try appendExecutionEvent(event, maximumEntries: maximumEntries)
    }

    func executionEvents(for profileID: UUID? = nil) -> [DatabaseExecutionEvent] {
        executionEvents(for: profileID)
    }
}
