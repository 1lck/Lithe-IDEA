import Foundation

/// A local application reported by the operating system for an existing file.
struct ExternalFileApplication: Equatable, Sendable {
    let url: URL
    let name: String
    let isDefault: Bool
    let iconData: Data?
}
