import Foundation

struct LocalHistoryEntry: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let timestamp: Date
    let relativePath: String
    let reason: LocalHistoryReason
    let contentURL: URL
    let byteCount: Int
}

enum LocalHistoryReason: String, Codable, Sendable {
    case projectBaseline
    case saved
    case externalChange
    case beforeRename
    case beforeDelete
    case restored

    var title: String {
        switch self {
        case .projectBaseline: "Project opened"
        case .saved: "File saved"
        case .externalChange: "External change"
        case .beforeRename: "Before rename"
        case .beforeDelete: "Before deletion"
        case .restored: "Before restore"
        }
    }
}

struct LocalHistoryRequest: Identifiable {
    let id = UUID()
    let fileURL: URL
}

