import Foundation

/// Compatibility boundary for Java implementation markers. The UI call sites
/// remain in place, but marker resolution belongs to the Rust LSP host.
@MainActor
final class JavaImplementationMarkerService: @unchecked Sendable {
    init() {}

    func invalidate(_: EditorDocument) {}

    func markers(
        for _: EditorDocument,
        candidates _: [JavaImplementationMarker]
    ) async -> [JavaImplementationMarker] {
        []
    }
}
