import CryptoKit
import Foundation

struct DatabaseDBXImportFolder: Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let parentID: UUID?
}

struct DatabaseDBXImportCandidate: Equatable, Identifiable, Sendable {
    let sourceID: String
    var profile: DatabaseProfile
    let password: String
    let warnings: [String]
    let isDuplicate: Bool

    var id: UUID { profile.id }
}

struct DatabaseDBXImportPlan: Equatable, Sendable {
    let candidates: [DatabaseDBXImportCandidate]
    let folders: [DatabaseDBXImportFolder]
    let unsupportedTypes: [String: Int]
    let wasEncrypted: Bool

    var importableCount: Int { candidates.count { !$0.isDuplicate } }
    var duplicateCount: Int { candidates.count { $0.isDuplicate } }
    var unsupportedCount: Int { unsupportedTypes.values.reduce(0, +) }
}

enum DatabaseDBXImportError: LocalizedError, Equatable {
    case invalidFile
    case passphraseRequired
    case wrongPassphrase
    case unsupportedEncryptedFormat

    var errorDescription: String? {
        switch self {
        case .invalidFile: "The selected file is not a valid DBX connection export."
        case .passphraseRequired: "Enter the DBX export password to read this file."
        case .wrongPassphrase: "The DBX export password is incorrect."
        case .unsupportedEncryptedFormat: "This DBX encrypted export version is not supported."
        }
    }
}

struct DatabaseDBXImportService: Sendable {
    func isEncrypted(_ data: Data) -> Bool {
        guard let envelope = try? JSONDecoder().decode(DBXEncryptedEnvelope.self, from: data) else { return false }
        return envelope.format == "dbx-encrypted"
    }

    func parse(
        data: Data,
        passphrase: String?,
        existingProfiles: [DatabaseProfile]
    ) throws -> DatabaseDBXImportPlan {
        let encrypted = isEncrypted(data)
        let plaintext: Data
        if encrypted {
            guard let passphrase, !passphrase.isEmpty else { throw DatabaseDBXImportError.passphraseRequired }
            plaintext = try decrypt(data, passphrase: passphrase)
        } else {
            plaintext = data
        }

        let export = try decodeExport(plaintext)
        let layout = buildLayout(export.layout)
        var unsupportedTypes: [String: Int] = [:]
        var candidates: [DatabaseDBXImportCandidate] = []

        for connection in export.connections {
            guard let kind = databaseKind(connection.dbType) else {
                unsupportedTypes[connection.dbType, default: 0] += 1
                continue
            }
            let folderID = layout.connectionFolderIDs[connection.id]
            let firstSSH = connection.transportLayers?.first { $0.type == "ssh" && $0.enabled != false }
            let firstProxy = connection.transportLayers?.first { $0.type == "proxy" && $0.enabled != false }
            var warnings: [String] = []
            let activeLayers = connection.transportLayers?.filter { $0.enabled != false } ?? []
            if activeLayers.filter({ $0.type == "ssh" }).count > 1 {
                warnings.append("Only the first SSH tunnel was imported.")
            }
            if firstSSH?.password?.nonEmpty != nil {
                warnings.append("The SSH password could not be imported; select an SSH key or enter it again.")
            }
            if activeLayers.contains(where: { $0.type == "http_tunnel" }) {
                warnings.append("DBX HTTP tunnel settings are not supported.")
            }
            if firstProxy != nil {
                warnings.append("DBX proxy settings require manual review.")
            }
            if connection.connectionString?.nonEmpty != nil {
                warnings.append("The DBX connection string requires manual review.")
            }
            if connection.clientCertPath?.nonEmpty != nil || connection.clientKeyPath?.nonEmpty != nil {
                warnings.append("Client certificate settings require manual review.")
            }
            if connection.urlParams?.nonEmpty != nil {
                warnings.append("DBX URL parameters require manual review.")
            }
            if kind == .redis, connection.redisConnectionMode != nil, connection.redisConnectionMode != "standalone" {
                warnings.append("Redis Sentinel or Cluster settings require manual review.")
            }

            let path = kind == .sqlite ? connection.host : ""
            let host = kind == .sqlite ? "" : connection.host
            let profile = DatabaseProfile(
                name: connection.name.nonEmpty ?? connection.id,
                kind: kind,
                host: host,
                port: UInt16(clamping: connection.port),
                username: connection.username,
                database: kind == .sqlite ? "" : (connection.database ?? ""),
                path: path,
                ssl: connection.ssl ?? false,
                folderID: folderID,
                colorHex: connection.color ?? "",
                readOnly: connection.readOnly ?? false,
                productionProtection: connection.isProduction ?? false,
                caCertificatePath: connection.caCertPath ?? "",
                sshHost: firstSSH?.host ?? "",
                sshPort: UInt16(clamping: firstSSH?.port ?? 0),
                sshUsername: firstSSH?.user ?? "",
                sshKeyPath: firstSSH?.keyPath ?? ""
            )
            let duplicate = existingProfiles.contains { existing in
                existing.name == profile.name && existing.host == profile.host && existing.port == profile.port && existing.path == profile.path
            }
            candidates.append(DatabaseDBXImportCandidate(
                sourceID: connection.id,
                profile: profile,
                password: connection.password,
                warnings: warnings,
                isDuplicate: duplicate
            ))
        }

        return DatabaseDBXImportPlan(
            candidates: candidates,
            folders: layout.folders,
            unsupportedTypes: unsupportedTypes,
            wasEncrypted: encrypted
        )
    }

    private func decrypt(_ data: Data, passphrase: String) throws -> Data {
        let envelope: DBXEncryptedEnvelope
        do { envelope = try JSONDecoder().decode(DBXEncryptedEnvelope.self, from: data) }
        catch { throw DatabaseDBXImportError.invalidFile }
        guard envelope.format == "dbx-encrypted", envelope.version == 1 else {
            throw DatabaseDBXImportError.unsupportedEncryptedFormat
        }
        guard let salt = Data(base64Encoded: envelope.salt),
              let nonceData = Data(base64Encoded: envelope.iv),
              let sealedData = Data(base64Encoded: envelope.data),
              nonceData.count == 12,
              sealedData.count >= 16 else {
            throw DatabaseDBXImportError.invalidFile
        }
        let keyData = pbkdf2SHA256(password: Data(passphrase.utf8), salt: salt, iterations: 100_000, keyLength: 32)
        let ciphertext = sealedData.dropLast(16)
        let tag = sealedData.suffix(16)
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonceData),
                ciphertext: ciphertext,
                tag: tag
            )
            return try AES.GCM.open(box, using: SymmetricKey(data: keyData))
        } catch {
            throw DatabaseDBXImportError.wrongPassphrase
        }
    }

    private func pbkdf2SHA256(password: Data, salt: Data, iterations: Int, keyLength: Int) -> Data {
        let key = SymmetricKey(data: password)
        var derived = Data()
        var blockIndex: UInt32 = 1
        while derived.count < keyLength {
            var blockSalt = salt
            var bigEndian = blockIndex.bigEndian
            blockSalt.append(Data(bytes: &bigEndian, count: MemoryLayout<UInt32>.size))
            var u = Data(HMAC<SHA256>.authenticationCode(for: blockSalt, using: key))
            var block = u
            if iterations > 1 {
                for _ in 2...iterations {
                    u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
                    for index in block.indices { block[index] ^= u[index] }
                }
            }
            derived.append(block)
            blockIndex += 1
        }
        return derived.prefix(keyLength)
    }

    private func decodeExport(_ data: Data) throws -> DBXExport {
        let decoder = JSONDecoder()
        if let export = try? decoder.decode(DBXExport.self, from: data) { return export }
        if let connections = try? decoder.decode([DBXConnection].self, from: data) {
            return DBXExport(connections: connections, layout: nil)
        }
        throw DatabaseDBXImportError.invalidFile
    }

    private func databaseKind(_ value: String) -> DatabaseKind? {
        switch value.lowercased() {
        case "mysql": .mysql
        case "mariadb": .mariadb
        case "postgres", "postgresql": .postgresql
        case "sqlite": .sqlite
        case "sqlserver", "sql-server": .sqlserver
        case "mongodb", "mongo": .mongodb
        case "redis": .redis
        case "nacos": .nacos
        default: nil
        }
    }

    private func buildLayout(_ layout: DBXLayout?) -> DBXResolvedLayout {
        guard let layout else { return .init(folders: [], connectionFolderIDs: [:]) }
        let names = Dictionary(uniqueKeysWithValues: layout.groups.map { ($0.id, $0.name) })
        var folderIDs: [String: UUID] = [:]
        var folders: [DatabaseDBXImportFolder] = []
        var connectionFolderIDs: [String: UUID] = [:]

        func visit(_ entries: [DBXOrderEntry], parentID: UUID?) {
            for entry in entries {
                if entry.type == "connection" {
                    if let parentID { connectionFolderIDs[entry.id] = parentID }
                    continue
                }
                guard entry.type == "group" else { continue }
                let folderID = folderIDs[entry.id] ?? UUID()
                folderIDs[entry.id] = folderID
                if !folders.contains(where: { $0.id == folderID }) {
                    folders.append(.init(id: folderID, name: names[entry.id]?.nonEmpty ?? "Imported Group", parentID: parentID))
                }
                for connectionID in entry.connectionIds ?? [] { connectionFolderIDs[connectionID] = folderID }
                visit(entry.children ?? [], parentID: folderID)
            }
        }
        visit(layout.order, parentID: nil)
        return .init(folders: folders, connectionFolderIDs: connectionFolderIDs)
    }
}

private struct DBXEncryptedEnvelope: Decodable {
    let format: String
    let version: Int
    let salt: String
    let iv: String
    let data: String
}

private struct DBXExport: Decodable {
    let connections: [DBXConnection]
    let layout: DBXLayout?
}

private struct DBXConnection: Decodable {
    let id: String
    let name: String
    let dbType: String
    let host: String
    let port: Int
    let username: String
    let password: String
    let database: String?
    let color: String?
    let readOnly: Bool?
    let isProduction: Bool?
    let ssl: Bool?
    let caCertPath: String?
    let clientCertPath: String?
    let clientKeyPath: String?
    let connectionString: String?
    let urlParams: String?
    let transportLayers: [DBXTransportLayer]?
    let redisConnectionMode: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, password, database, color, ssl
        case dbType = "db_type"
        case readOnly = "read_only"
        case isProduction = "is_production"
        case caCertPath = "ca_cert_path"
        case clientCertPath = "client_cert_path"
        case clientKeyPath = "client_key_path"
        case connectionString = "connection_string"
        case urlParams = "url_params"
        case transportLayers = "transport_layers"
        case redisConnectionMode = "redis_connection_mode"
    }
}

private struct DBXTransportLayer: Decodable {
    let type: String
    let enabled: Bool?
    let host: String
    let port: Int
    let user: String?
    let password: String?
    let keyPath: String?
    let proxyType: String?

    private enum CodingKeys: String, CodingKey {
        case type, enabled, host, port, user, password
        case keyPath = "key_path"
        case proxyType = "proxy_type"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 0
        user = try container.decodeIfPresent(String.self, forKey: .user)
        password = try container.decodeIfPresent(String.self, forKey: .password)
        keyPath = try container.decodeIfPresent(String.self, forKey: .keyPath)
        proxyType = try container.decodeIfPresent(String.self, forKey: .proxyType)
    }
}

private struct DBXLayout: Decodable {
    let groups: [DBXGroup]
    let order: [DBXOrderEntry]
}

private struct DBXGroup: Decodable {
    let id: String
    let name: String
}

private struct DBXOrderEntry: Decodable {
    let type: String
    let id: String
    let children: [DBXOrderEntry]?
    let connectionIds: [String]?
}

private struct DBXResolvedLayout {
    let folders: [DatabaseDBXImportFolder]
    let connectionFolderIDs: [String: UUID]
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
