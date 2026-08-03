import Foundation

protocol KeyValueStore {
    func data(forKey key: String) -> Data?
    func object(forKey key: String) -> Any?
    func string(forKey key: String) -> String?
    func stringArray(forKey key: String) -> [String]?
    func set(_ value: Any?, forKey key: String)
}
