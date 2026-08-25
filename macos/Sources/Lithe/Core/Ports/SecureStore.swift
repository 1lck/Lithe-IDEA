import Foundation

protocol SecureStore: Sendable {
    func read(key: String) -> String?
    func write(_ value: String, key: String) throws
    func delete(key: String) throws
}
