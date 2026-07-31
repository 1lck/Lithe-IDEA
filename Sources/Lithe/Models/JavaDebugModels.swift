import Foundation

enum JavaDebugTargetKind: String, CaseIterable, Identifiable, Sendable {
    case currentFile
    case runConfiguration
    case remote

    var id: String { rawValue }

    var title: String {
        switch self {
        case .currentFile: "Current File"
        case .runConfiguration: "Maven / Spring Boot"
        case .remote: "Remote JVM / Tomcat"
        }
    }

    var systemImage: String {
        switch self {
        case .currentFile: "doc.text"
        case .runConfiguration: "shippingbox"
        case .remote: "network"
        }
    }
}

enum JavaDebugSessionState: String, Sendable {
    case idle
    case launching
    case running
    case paused
    case finished
    case failed

    var title: String {
        switch self {
        case .idle: "Ready"
        case .launching: "Launching"
        case .running: "Running"
        case .paused: "Paused"
        case .finished: "Finished"
        case .failed: "Failed"
        }
    }
}

struct JavaDebugBreakpoint: Identifiable, Hashable, Sendable {
    let id: String
    let fileURL: URL
    let line: Int
    let className: String

    var title: String {
        "\(fileURL.lastPathComponent):\(line)"
    }
}
