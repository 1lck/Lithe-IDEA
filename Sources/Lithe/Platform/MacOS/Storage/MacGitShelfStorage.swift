import Foundation
import LitheGitModule

struct MacGitShelfStorage: GitShelfStorage {
    let storage: any FileStorage
    func applicationSupportDirectory() -> URL { storage.applicationSupportDirectory() }
    func fileExists(at url: URL) -> Bool { storage.fileExists(at: url) }
    func listDirectory(at url: URL) -> [URL] { storage.listDirectory(at: url) }
    func readData(from url: URL) throws -> Data { try storage.readData(from: url, options: []) }
    func writeData(_ data: Data, to url: URL) throws { try storage.writeData(data, to: url, options: []) }
    func createDirectory(at url: URL) throws { try storage.createDirectory(at: url, withIntermediateDirectories: true) }
    func removeItem(at url: URL) throws { try storage.removeItem(at: url) }
}
