import Foundation

package struct DatabaseProcessRequest: Sendable {
    package let executablePath: String
    package let environment: [String: String]?
    package let standardInput: Data?
    package let timeoutMilliseconds: Int?

    package init(executablePath: String, environment: [String: String]?, standardInput: Data?, timeoutMilliseconds: Int?) {
        self.executablePath = executablePath
        self.environment = environment
        self.standardInput = standardInput
        self.timeoutMilliseconds = timeoutMilliseconds
    }
}

package struct DatabaseProcessResult: Sendable {
    package let output: String
    package let exitCode: Int32
    package var succeeded: Bool { exitCode == 0 }

    package init(output: String, exitCode: Int32) {
        self.output = output
        self.exitCode = exitCode
    }
}

package protocol DatabaseProcessRunning: Sendable {
    func runDatabaseProcess(_ request: DatabaseProcessRequest) -> DatabaseProcessResult
}

package protocol DatabasePreferenceStore: Sendable {
    func data(forKey key: String) -> Data?
    func set(_ value: Any?, forKey key: String)
}

package protocol DatabaseSecureStore: Sendable {
    func read(key: String) -> String?
    func write(_ value: String, key: String) throws
    func delete(key: String) throws
}

package protocol DatabaseFileStorage: Sendable {
    func temporaryDirectory() -> URL
    func fileExists(at url: URL) -> Bool
    func readData(from url: URL) throws -> Data
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws
    func removeItem(at url: URL) throws
}

package struct UnavailableDatabaseFileStorage: DatabaseFileStorage {
    private let root = URL(fileURLWithPath: "/unavailable")
    package func temporaryDirectory() -> URL { root }
    package func fileExists(at url: URL) -> Bool { false }
    package func readData(from url: URL) throws -> Data { throw CocoaError(.fileReadNoSuchFile) }
    package func copyItem(at sourceURL: URL, to destinationURL: URL) throws { throw CocoaError(.fileNoSuchFile) }
    package func removeItem(at url: URL) throws { throw CocoaError(.fileNoSuchFile) }
}
