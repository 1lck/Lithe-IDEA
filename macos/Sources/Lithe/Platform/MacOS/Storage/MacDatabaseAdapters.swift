import Foundation
import LitheDatabaseModule

extension MacProcessRunner: DatabaseProcessRunning {
    func runDatabaseProcess(_ request: DatabaseProcessRequest) -> DatabaseProcessResult {
        let result = run(ProcessRequest(
            executablePath: request.executablePath,
            environment: request.environment,
            standardInput: request.standardInput,
            timeoutMilliseconds: request.timeoutMilliseconds
        ))
        return DatabaseProcessResult(output: result.output, exitCode: result.exitCode)
    }
}

extension MacKeychainSecureStore: DatabaseSecureStore {}

struct MacDatabasePreferenceStore: DatabasePreferenceStore, @unchecked Sendable {
    let store: any KeyValueStore
    func data(forKey key: String) -> Data? { store.data(forKey: key) }
    func set(_ value: Any?, forKey key: String) { store.set(value, forKey: key) }
}

extension MacFileStorage: DatabaseFileStorage {
    func readData(from url: URL) throws -> Data { try readData(from: url, options: []) }
}
