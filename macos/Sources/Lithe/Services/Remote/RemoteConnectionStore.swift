import Foundation

// Note: SSH 连接配置与测试连接见 .agents/notes/implemented/feature/2026-10-24-remote-ssh-connections.md

/// Saved SSH connections. The list lives in preferences; a remembered
/// password or key passphrase lives in the secure store under the
/// connection's id and is never written to preferences or sent to Core.
struct RemoteConnectionStore {
    private static let key = "lithe.remote.ssh-connections.v1"
    private let store: any KeyValueStore
    private let secureStore: any SecureStore

    init(store: any KeyValueStore, secureStore: any SecureStore) {
        self.store = store
        self.secureStore = secureStore
    }

    func load() -> [RemoteSSHConnection] {
        guard let data = store.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([RemoteSSHConnection].self, from: data)) ?? []
    }

    func save(_ connections: [RemoteSSHConnection]) throws {
        store.set(try JSONEncoder().encode(connections), forKey: Self.key)
    }

    func secret(for id: UUID) -> String? {
        secureStore.read(key: secretKey(id))
    }

    func saveSecret(_ secret: String, for id: UUID) throws {
        try secureStore.write(secret, key: secretKey(id))
    }

    func deleteSecret(for id: UUID) throws {
        try secureStore.delete(key: secretKey(id))
    }

    private func secretKey(_ id: UUID) -> String { "remote.ssh.\(id.uuidString).secret" }
}
