import Foundation
import LitheCoreContracts

public struct LocalHistoryEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let relativePath: String
    public let reason: LocalHistoryReason
    public let contentURL: URL
    public let byteCount: Int

    public init(id: UUID, timestamp: Date, relativePath: String, reason: LocalHistoryReason, contentURL: URL, byteCount: Int) {
        self.id = id
        self.timestamp = timestamp
        self.relativePath = relativePath
        self.reason = reason
        self.contentURL = contentURL
        self.byteCount = byteCount
    }
}

public typealias LocalHistoryReason = LitheCoreContracts.LocalHistoryReason
public typealias LocalHistoryEvent = LitheCoreContracts.LocalHistoryEvent
public typealias LocalHistorySnapshotPlan = LitheCoreContracts.LocalHistorySnapshotPlan

public struct LocalHistoryRequest: Identifiable {
    public let id = UUID()
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }
}

public struct ProjectLocalHistoryRequest: Identifiable {
    public let id = UUID()
    public init() {}
}
