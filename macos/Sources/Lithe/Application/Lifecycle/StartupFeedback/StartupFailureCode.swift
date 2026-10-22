import Foundation

/// The reasons a startup can fail, shared by both Lithe products.
enum StartupFailureCode: String, CaseIterable, Sendable {
    case pluginLoadFailed
    case languageServiceInitializationFailed
    case workspaceOpenFailed
    case sessionRestoreFailed
}
