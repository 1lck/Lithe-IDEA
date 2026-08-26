import Foundation
import LitheLocalHistoryModule

struct MacLocalHistoryStorage: LocalHistoryStorage {
    let storage: any FileStorage
    func applicationSupportDirectory() -> URL { storage.applicationSupportDirectory() }
}

struct MacLocalHistoryWorkspaceAccess: LocalHistoryWorkspaceAccess {
    let workspaceOperations: any WorkspaceOperations
    let fileOperations: any WorkspaceFileOperations
    func fileExists(at url: URL) -> Bool { fileOperations.fileExists(at: url) }
    func readFile(at workspaceURL: URL, relativePath: String) -> String? { workspaceOperations.readFile(at: workspaceURL, relativePath: relativePath) }
    func writeFile(_ text: String, at workspaceURL: URL, relativePath: String) -> Bool { workspaceOperations.writeFile(text, at: workspaceURL, relativePath: relativePath) }
}
