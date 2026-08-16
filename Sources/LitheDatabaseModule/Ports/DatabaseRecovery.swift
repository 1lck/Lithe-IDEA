import Foundation

package struct DatabaseBackupSchedule: Codable, Equatable, Identifiable, Sendable {
    package let profileID: UUID
    package var isEnabled: Bool
    package var intervalHours: Int
    package var retentionCount: Int
    package var nextRunAt: Date

    package var id: UUID { profileID }

    package init(profileID: UUID, isEnabled: Bool = true, intervalHours: Int = 24, retentionCount: Int = 14, nextRunAt: Date = Date()) {
        self.profileID = profileID
        self.isEnabled = isEnabled
        self.intervalHours = max(1, intervalHours)
        self.retentionCount = max(1, retentionCount)
        self.nextRunAt = nextRunAt
    }
}

package struct DatabaseRecoveryPoint: Codable, Equatable, Identifiable, Sendable {
    package let id: UUID
    package let profileID: UUID
    package let reason: String
    package let createdAt: Date
    package let byteCount: Int
    package let fileName: String
    package let originalByteCount: Int
    package let isCompressed: Bool
    package let sha256: String

    private enum CodingKeys: String, CodingKey { case id, profileID, reason, createdAt, byteCount, fileName, originalByteCount, isCompressed, sha256 }

    package init(id: UUID, profileID: UUID, reason: String, createdAt: Date, byteCount: Int, fileName: String, originalByteCount: Int, isCompressed: Bool, sha256: String = "") {
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

    package init(from decoder: Decoder) throws {
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

package struct DatabaseAuditEntry: Codable, Equatable, Identifiable, Sendable {
    package let id: UUID
    package let profileID: UUID
    package let action: String
    package let summary: String
    package let createdAt: Date
    package let recoveryPointID: UUID?
    package let rowsAffected: UInt64?
    package let succeeded: Bool
    package let errorMessage: String?
}

package enum DatabaseExecutionSource: String, Codable, Equatable, Sendable {
    case sql
    case redis
    case nacos
}

package enum DatabaseExecutionStatus: String, Codable, Equatable, Sendable {
    case succeeded
    case failed
    case cancelled
}

package struct DatabaseExecutionEvent: Codable, Equatable, Identifiable, Sendable {
    package let id: UUID
    package let profileID: UUID
    package let profileName: String
    package let source: DatabaseExecutionSource
    package let operation: String
    package let startedAt: Date
    package let durationMilliseconds: Int
    package let status: DatabaseExecutionStatus
    package let rowsReturned: Int?
    package let rowsAffected: UInt64?
    package let errorMessage: String?
}

package protocol DatabaseRecoveryStoring: AnyObject, Sendable {
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
    package func createRecoveryPoint(profileID: UUID, reason: String, data: Data) throws -> DatabaseRecoveryPoint { throw error }
    package func createRecoveryPoint(profileID: UUID, reason: String, fileURL: URL, expectedSHA256: String, progress: ((Double) -> Void)?) throws -> DatabaseRecoveryPoint { throw error }
    package func recoveryPoints(for profileID: UUID?) -> [DatabaseRecoveryPoint] { [] }
    package func data(for point: DatabaseRecoveryPoint) throws -> Data { throw error }
    package func fileURL(for point: DatabaseRecoveryPoint) throws -> URL { throw error }
    package func delete(_ point: DatabaseRecoveryPoint) throws { throw error }
    package func appendAudit(_ entry: DatabaseAuditEntry, maximumEntries: Int) throws { throw error }
    package func auditEntries(for profileID: UUID?) -> [DatabaseAuditEntry] { [] }
    package func appendExecutionEvent(_ event: DatabaseExecutionEvent, maximumEntries: Int) throws { throw error }
    package func executionEvents(for profileID: UUID?) -> [DatabaseExecutionEvent] { [] }
    package func deleteExecutionEvents(for profileID: UUID) throws { throw error }
}

package extension DatabaseRecoveryStoring {
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
