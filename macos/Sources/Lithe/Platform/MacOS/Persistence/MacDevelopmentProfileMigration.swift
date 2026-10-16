import Foundation
import Darwin

/// Note: 首次复制与后续隔离见 .agents/notes/implemented/process/2026-09-13-macos-update-signing-and-release-strategy.md
/// Runs before any settings/session store is constructed. The transaction lives
/// in writable Application Support, never in the signed application bundle.
struct MacDevelopmentProfileMigration {
    static let markerKey = "lithe.developmentProfileImport.v1"
    private static let transactionName = ".stable-profile-import-v1.plist"
    // These adapters persist user configuration outside the settings/lithe namespaces.
    // Use the same allowlist when detecting existing Dev data to avoid replacing it.
    private static let additionalUserPreferences: Set<String> = [
        "database.profiles.v1", "database.connection-folders.v1",
        "database.sql-history.v1", "database.backup-schedules.v1",
        "platform.macos.workbenchBackgroundImageAccess"
    ]
    private static let excludedPreferences: Set<String> = [
        AppUpdateChannel.preferenceKey, "settings.customLogDirectory", markerKey,
        "lithe.modules.pending-activation", "lithe.modules.pending-activations", "lithe.plugins.pending-code-load"
    ]

    enum Outcome: Equatable { case notDevelopment, existing, imported, fresh }

    static func prepare(
        identity: MacAppIdentity = MacAppIdentity(),
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        supportDirectory: URL? = nil,
        sourceDomain: String = "app.lithe.desktop",
        destinationDomain: String = "app.lithe.desktop.dev"
    ) throws -> Outcome {
        guard identity.isDevelopment else { return .notDevelopment }
        let base = supportDirectory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let destination = identity.storageRoot(base)
        let transaction = destination.appendingPathComponent(transactionName)
        let ownPreferences = defaults.persistentDomain(forName: destinationDomain) ?? [:]
        if ownPreferences[markerKey] != nil {
            try? fileManager.removeItem(at: transaction)
            return .existing
        }

        // A crash after publishing files but before committing preferences resumes
        // from the same snapshot; it never reads a newer Stable profile halfway.
        if fileManager.fileExists(atPath: transaction.path) {
            let snapshot = try PropertyListSerialization.propertyList(from: Data(contentsOf: transaction), format: nil)
            guard let preferences = snapshot as? [String: Any] else { throw MigrationError.invalidSnapshot }
            try commit(preferences, defaults: defaults, domain: destinationDomain)
            try? fileManager.removeItem(at: transaction)
            return .imported
        }
        guard !ownPreferences.keys.contains(where: isUserPreference) else { return .existing }
        if fileManager.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else { return .existing }
            guard try fileManager.contentsOfDirectory(atPath: destination.path).isEmpty else { return .existing }
        }

        let source = defaults.persistentDomain(forName: sourceDomain) ?? [:]
        let preferences = source.filter { isUserPreference($0.key) && shouldImport($0.key) }
        // Explicit durable-data allowlist: caches, indexes, plugins, recovery
        // databases, logs and process connection/lock files are rebuilt by Dev.
        let paths = ["Lithe/ai-secrets.json", "Lithe/Maven", "Lithe/PluginMarketplace/sources.json"]
        let existingPaths = paths.filter { fileManager.fileExists(atPath: base.appendingPathComponent($0).path) }
        guard !preferences.isEmpty || !existingPaths.isEmpty else {
            try commit([:], defaults: defaults, domain: destinationDomain, marker: "fresh")
            return .fresh
        }

        let staging = base.appendingPathComponent(".lithe-dev-profile-import-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: staging) }
        for path in existingPaths {
            try copyRegularTree(from: base.appendingPathComponent(path), to: staging.appendingPathComponent(path), fileManager: fileManager)
        }
        let snapshot = try PropertyListSerialization.data(fromPropertyList: preferences, format: .binary, options: 0)
        let snapshotURL = staging.appendingPathComponent(transactionName)
        try snapshot.write(to: snapshotURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshotURL.path)
        // rmdir removes only an empty directory, so a concurrent writer's new
        // files are preserved. moveItem then refuses any concurrently recreated root.
        if fileManager.fileExists(atPath: destination.path), rmdir(destination.path) != 0 {
            throw MigrationError.destinationChanged
        }
        try fileManager.moveItem(at: staging, to: destination)
        try commit(preferences, defaults: defaults, domain: destinationDomain)
        try? fileManager.removeItem(at: transaction)
        return .imported
    }

    private static func isUserPreference(_ key: String) -> Bool {
        key.hasPrefix("settings.") || key.hasPrefix("lithe.")
            || additionalUserPreferences.contains(key) || key == AppUpdateChannel.preferenceKey
    }

    private static func shouldImport(_ key: String) -> Bool {
        !excludedPreferences.contains(key)
    }

    private static func commit(_ preferences: [String: Any], defaults: UserDefaults, domain: String, marker: String = "imported") throws {
        var values = preferences
        values[markerKey] = marker
        defaults.setPersistentDomain(values, forName: domain)
        guard defaults.synchronize() else { throw MigrationError.preferencesUnavailable }
    }

    private static func copyRegularTree(from source: URL, to destination: URL, fileManager: FileManager) throws {
        let values = try source.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
        guard values.isSymbolicLink != true else { throw MigrationError.unsupportedFile }
        if values.isDirectory == true {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for child in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try copyRegularTree(from: child, to: destination.appendingPathComponent(child.lastPathComponent), fileManager: fileManager)
            }
        } else {
            guard values.isRegularFile == true else { throw MigrationError.unsupportedFile }
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Read a complete, atomically written source file into an independent
            // destination. Source metadata, aliases and symlinks are not copied.
            try Data(contentsOf: source).write(to: destination, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
    }

    private enum MigrationError: LocalizedError {
        case invalidSnapshot, preferencesUnavailable, unsupportedFile, destinationChanged
        var errorDescription: String? {
            String(localized: "The Stable profile could not be copied safely. Its original data has been preserved.")
        }
    }
}
