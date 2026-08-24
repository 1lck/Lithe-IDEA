import Foundation

/// Opaque, platform-owned authorization for one user-selected background image.
struct WorkbenchBackgroundImageAccess: Codable, Equatable {
    let opaqueData: Data
    let displayName: String
}

/// Result of resolving an image access token, including a refreshed token when
/// a platform needs to rotate its local authorization representation.
struct WorkbenchBackgroundImageData {
    let data: Data
    let refreshedAccess: WorkbenchBackgroundImageAccess?
}

/// Native image resources and file authorization used by the workbench background.
/// The shared preference only stores source kind and bundled slot; implementations
/// keep resource paths and authorization data platform-private.
@MainActor
protocol WorkbenchBackgroundPlatformProviding: AnyObject {
    func chooseImage(title: String, prompt: String) -> URL?
    func hasBundledImage(for slot: String) -> Bool
    func bundledImageData(for slot: String) -> Data?
    func makeImageAccess(for url: URL) -> WorkbenchBackgroundImageAccess?
    func loadImageData(for access: WorkbenchBackgroundImageAccess) -> WorkbenchBackgroundImageData?
}

@MainActor
final class UnavailableWorkbenchBackgroundPlatform: WorkbenchBackgroundPlatformProviding {
    func chooseImage(title: String, prompt: String) -> URL? { nil }
    func hasBundledImage(for slot: String) -> Bool { false }
    func bundledImageData(for slot: String) -> Data? { nil }
    func makeImageAccess(for url: URL) -> WorkbenchBackgroundImageAccess? { nil }
    func loadImageData(for access: WorkbenchBackgroundImageAccess) -> WorkbenchBackgroundImageData? { nil }
}
