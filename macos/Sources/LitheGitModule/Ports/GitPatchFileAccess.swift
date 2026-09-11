import Foundation

@MainActor
package protocol GitPatchFileAccess {
    func choosePatchFile() -> URL?
    func choosePatchDestination() -> URL?
    func clipboardPatch() -> String?
    func readPatch(at url: URL) async throws -> String
    func writePatch(_ patch: String, at url: URL) async throws
}
