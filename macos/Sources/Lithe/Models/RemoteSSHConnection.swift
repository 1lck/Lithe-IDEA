import Foundation

/// One SSH connection the user saved for remote development. Secrets are
/// not part of it; `RemoteConnectionStore` keeps them in the keychain.
struct RemoteSSHConnection: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    /// Host name, address, or a `Host` alias from `~/.ssh/config`.
    var host: String
    /// `nil` keeps the port from the SSH configuration (22 by default).
    var port: Int?
    /// Empty keeps the user from the SSH configuration.
    var user: String
    var authentication: RemoteSSHAuthentication
    /// Private key path for `.privateKey`; `~` is expanded by OpenSSH.
    var identityFile: String
    /// Whether the password or key passphrase is kept in the keychain.
    var remembersSecret: Bool
    /// `nil` uses Core's default.
    var connectTimeoutSeconds: Int?
    /// `nil` uses the transport's keep-alive default.
    var keepAliveSeconds: Int?
    /// Project folder on the host chosen in the folder browser; empty until
    /// one is chosen.
    var remoteDirectory: String
    /// What the last successful test or connection learned about the host.
    var lastKnownHost: RemoteKnownHost?

    init(
        id: UUID = UUID(), name: String = "", host: String = "", port: Int? = nil, user: String = "",
        authentication: RemoteSSHAuthentication = .auto, identityFile: String = "",
        remembersSecret: Bool = false, connectTimeoutSeconds: Int? = nil, keepAliveSeconds: Int? = nil,
        remoteDirectory: String = ""
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.user = user
        self.authentication = authentication
        self.identityFile = identityFile
        self.remembersSecret = remembersSecret
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.keepAliveSeconds = keepAliveSeconds
        self.remoteDirectory = remoteDirectory
        lastKnownHost = nil
    }

    /// Fields added later decode with their defaults, so older saved lists
    /// keep loading.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try container.decodeIfPresent(Int.self, forKey: .port)
        user = try container.decodeIfPresent(String.self, forKey: .user) ?? ""
        authentication = (try? container.decodeIfPresent(RemoteSSHAuthentication.self, forKey: .authentication)) ?? .auto
        identityFile = try container.decodeIfPresent(String.self, forKey: .identityFile) ?? ""
        remembersSecret = try container.decodeIfPresent(Bool.self, forKey: .remembersSecret) ?? false
        connectTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .connectTimeoutSeconds)
        keepAliveSeconds = try container.decodeIfPresent(Int.self, forKey: .keepAliveSeconds)
        remoteDirectory = try container.decodeIfPresent(String.self, forKey: .remoteDirectory) ?? ""
        lastKnownHost = try? container.decodeIfPresent(RemoteKnownHost.self, forKey: .lastKnownHost)
    }

    /// Name shown in lists: the user's name, else `user@host`, else the host.
    var displayName: String {
        let name = name.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { return name }
        let host = host.trimmingCharacters(in: .whitespaces)
        let user = user.trimmingCharacters(in: .whitespaces)
        return user.isEmpty || host.isEmpty ? host : "\(user)@\(host)"
    }

    /// The folder to open: the chosen one, else the remote home directory
    /// learned from the last connection.
    var effectiveRemoteDirectory: String? {
        let chosen = remoteDirectory.trimmingCharacters(in: .whitespaces)
        if chosen.hasPrefix("/") { return chosen }
        return lastKnownHost?.homeDirectory
    }

    /// Whether the authentication method uses a secret that can be remembered.
    var usesSecret: Bool { authentication == .password || authentication == .privateKey }

    var target: RemoteSSHTarget {
        let trimmed = { (value: String) -> String? in
            let value = value.trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return RemoteSSHTarget(
            host: host.trimmingCharacters(in: .whitespaces),
            port: port,
            user: trimmed(user),
            authentication: authentication,
            identityFile: authentication == .privateKey ? trimmed(identityFile) : nil,
            connectTimeoutSeconds: connectTimeoutSeconds,
            keepAliveSeconds: keepAliveSeconds
        )
    }

    /// The first problem that prevents saving or testing, or `nil`.
    var problem: Problem? {
        let host = host.trimmingCharacters(in: .whitespaces)
        if host.isEmpty { return .missingHost }
        if host.contains("@") || host.contains(where: \.isWhitespace) { return .invalidHost }
        if let port, !(1...65_535).contains(port) { return .invalidPort }
        if user.contains(where: { $0 == "@" || $0 == ":" || $0.isWhitespace }) { return .invalidUser }
        if authentication == .privateKey, identityFile.trimmingCharacters(in: .whitespaces).isEmpty {
            return .missingIdentityFile
        }
        return nil
    }

    enum Problem: Equatable, Sendable {
        case missingHost
        case invalidHost
        case invalidPort
        case invalidUser
        case missingIdentityFile

        var message: String {
            switch self {
            case .missingHost: String(localized: "Enter a host.")
            case .invalidHost: String(localized: "Enter the host without a user name or spaces; put the user in User name.")
            case .invalidPort: String(localized: "The port must be between 1 and 65535.")
            case .invalidUser: String(localized: "The user name cannot contain @, : or spaces.")
            case .missingIdentityFile: String(localized: "Choose a private key file.")
            }
        }
    }
}

/// Host facts remembered with a connection, shown without reconnecting.
struct RemoteKnownHost: Codable, Equatable, Sendable {
    var checkedAt: Date
    var system: String
    var machine: String
    var homeDirectory: String?
    var details: RemoteHostDetails
    /// Address the host name resolved to on this Mac.
    var address: String?
    /// Filled only when the user asked for the location.
    var location: RemoteHostLocation?
}
