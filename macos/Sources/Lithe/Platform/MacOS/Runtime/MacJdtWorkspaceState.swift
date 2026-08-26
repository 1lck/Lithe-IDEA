import Foundation

/// macOS filesystem adapter for JDT LS workspace fingerprints and cached state.
///
/// The adapter only inspects immediate build-system inputs. Rust Core remains
/// the sole owner of workspace-key normalization and hashing.
struct MacJdtWorkspaceState {
    private static let buildFileNames = ["pom.xml", "build.gradle", "build.gradle.kts"]
    private static let mavenDescriptorName = "pom.xml"
    private static let manifestName = "manifest.json"
    private static let corePluginPrefix = "org.eclipse.jdt.ls.core_"
    private static let lastUsedMarkerName = ".lithe-last-used"

    private let cacheDirectoryURL: URL
    private let workspaceFingerprintResolver: ((
        [RustCoreBridge.JdtBuildFileObservation],
        [String],
        String
    ) throws -> String)?
    private let workspaceKeyResolver: (URL, String?) throws -> String
    private let cacheRetentionPlanner: ((
        UInt64,
        String,
        [RustCoreBridge.JdtCacheEntry]
    ) throws -> RustCoreBridge.JdtCacheRetentionPayload)?

    init(core: RustCoreBridge, cacheDirectoryURL: URL) {
        self.init(
            cacheDirectoryURL: cacheDirectoryURL,
            workspaceFingerprintResolver: { buildFiles, directMavenModules, jdtlsVersion in
                try core.jdtWorkspaceFingerprint(
                    buildFiles: buildFiles,
                    directMavenModules: directMavenModules,
                    jdtlsVersion: jdtlsVersion
                ).get()
            },
            workspaceKeyResolver: { workspaceRootURL, fingerprint in
                try core.jdtWorkspaceKey(
                    workspaceRootURL: workspaceRootURL,
                    workspaceFingerprint: fingerprint
                ).get()
            },
            cacheRetentionPlanner: { nowUnixSeconds, activeWorkspaceKey, entries in
                try core.jdtCacheRetention(
                    nowUnixSeconds: nowUnixSeconds,
                    activeWorkspaceKey: activeWorkspaceKey,
                    entries: entries
                ).get()
            }
        )
    }

    init(
        cacheDirectoryURL: URL,
        workspaceFingerprintResolver: ((
            [RustCoreBridge.JdtBuildFileObservation],
            [String],
            String
        ) throws -> String)? = nil,
        workspaceKeyResolver: @escaping (URL, String?) throws -> String,
        cacheRetentionPlanner: ((
            UInt64,
            String,
            [RustCoreBridge.JdtCacheEntry]
        ) throws -> RustCoreBridge.JdtCacheRetentionPayload)? = nil
    ) {
        self.cacheDirectoryURL = cacheDirectoryURL.standardizedFileURL
        self.workspaceFingerprintResolver = workspaceFingerprintResolver
        self.workspaceKeyResolver = workspaceKeyResolver
        self.cacheRetentionPlanner = cacheRetentionPlanner
    }

    /// Builds a deterministic, non-recursive digest input for one Java workspace.
    func fingerprint(
        at workspaceRootURL: URL,
        languageServerExecutableURL: URL?
    ) throws -> String {
        guard let workspaceFingerprintResolver else {
            throw MacJdtWorkspaceStateError.workspaceFingerprintUnavailable
        }
        let fileManager = FileManager.default
        let root = workspaceRootURL.standardizedFileURL
        var buildFiles: [RustCoreBridge.JdtBuildFileObservation] = []

        for name in Self.buildFileNames {
            let path = root.appendingPathComponent(name).path
            do {
                let attributes = try fileManager.attributesOfItem(atPath: path)
                guard let modified = attributes[.modificationDate] as? Date,
                      let size = attributes[.size] as? NSNumber else {
                    throw MacJdtWorkspaceStateError.invalidBuildFileMetadata(name)
                }
                buildFiles.append(RustCoreBridge.JdtBuildFileObservation(
                    path: name,
                    modifiedUnixMilliseconds: UInt64(max(
                        0,
                        (modified.timeIntervalSince1970 * 1_000).rounded(.down)
                    )),
                    sizeBytes: size.uint64Value
                ))
            } catch where isMissingFileError(error) {
                continue
            }
        }

        var modules: [String] = []
        let entries = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        for entry in entries {
            let isDirectory = try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory
            guard isDirectory == true else { continue }
            let descriptorPath = entry.appendingPathComponent(Self.mavenDescriptorName).path
            do {
                let attributes = try fileManager.attributesOfItem(atPath: descriptorPath)
                guard attributes[.type] as? FileAttributeType == .typeRegular else { continue }
                modules.append(entry.lastPathComponent)
            } catch where isMissingFileError(error) {
                continue
            }
        }

        return try workspaceFingerprintResolver(
            buildFiles,
            modules,
            languageServerVersion(for: languageServerExecutableURL)
        )
    }

    /// Removes only the current workspace/fingerprint directory. Other cached
    /// structures remain available if the user later switches back to them.
    func clearIndex(at workspaceRootURL: URL, workspaceFingerprint: String?) throws {
        let key = try workspaceKeyResolver(
            workspaceRootURL.standardizedFileURL,
            workspaceFingerprint
        )
        try validateWorkspaceKey(key)

        let target = cacheDirectoryURL
            .appendingPathComponent("jdtls", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
            .standardizedFileURL
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
    }

    /// Removes inactive JDT LS caches selected by Rust Core's shared policy.
    /// The active directory is marked as recently used before the decision.
    func pruneExpiredCaches(
        at workspaceRootURL: URL,
        workspaceFingerprint: String?,
        now: Date = Date()
    ) throws -> MacJdtCacheCleanupResult {
        guard let cacheRetentionPlanner else {
            throw MacJdtWorkspaceStateError.cacheRetentionUnavailable
        }
        let activeWorkspaceKey = try workspaceKeyResolver(
            workspaceRootURL.standardizedFileURL,
            workspaceFingerprint
        )
        try validateWorkspaceKey(activeWorkspaceKey)

        let jdtlsCacheURL = cacheDirectoryURL.appendingPathComponent("jdtls", isDirectory: true)
        let fileManager = FileManager.default
        let candidates: [URL]
        do {
            candidates = try fileManager.contentsOfDirectory(
                at: jdtlsCacheURL,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .contentModificationDateKey,
                ],
                options: [.skipsHiddenFiles]
            )
        } catch where isMissingFileError(error) {
            let plan = try cacheRetentionPlanner(
                unixSeconds(now),
                activeWorkspaceKey,
                []
            )
            return MacJdtCacheCleanupResult(
                retentionDays: plan.retentionDays,
                removedWorkspaceKeys: []
            )
        }

        var observedKeys: Set<String> = []
        var entries: [RustCoreBridge.JdtCacheEntry] = []
        for candidate in candidates {
            let values = try candidate.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey,
            ])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let key = candidate.lastPathComponent
            guard isWorkspaceKey(key) else { continue }
            let markerModified: Date?
            if key == activeWorkspaceKey {
                try Data(String(unixSeconds(now)).utf8).write(
                    to: candidate.appendingPathComponent(Self.lastUsedMarkerName),
                    options: [.atomic]
                )
                markerModified = now
            } else {
                markerModified = try lastUsedDate(at: candidate)
            }
            let modified = [values.contentModificationDate, markerModified]
                .compactMap { $0 }
                .max() ?? .distantPast
            observedKeys.insert(key)
            entries.append(RustCoreBridge.JdtCacheEntry(
                workspaceKey: key,
                lastModifiedUnixSeconds: unixSeconds(modified)
            ))
        }

        let plan = try cacheRetentionPlanner(
            unixSeconds(now),
            activeWorkspaceKey,
            entries
        )
        var removedWorkspaceKeys: [String] = []
        for key in plan.expiredWorkspaceKeys {
            guard key != activeWorkspaceKey, observedKeys.contains(key), isWorkspaceKey(key) else {
                throw MacJdtWorkspaceStateError.invalidRetentionPlan
            }
            let target = jdtlsCacheURL.appendingPathComponent(key, isDirectory: true)
            let values = try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw MacJdtWorkspaceStateError.invalidRetentionTarget
            }
            try fileManager.removeItem(at: target)
            removedWorkspaceKeys.append(key)
        }
        return MacJdtCacheCleanupResult(
            retentionDays: plan.retentionDays,
            removedWorkspaceKeys: removedWorkspaceKeys
        )
    }

    private func validateWorkspaceKey(_ key: String) throws {
        guard isWorkspaceKey(key) else {
            throw MacJdtWorkspaceStateError.invalidWorkspaceKey
        }
    }

    private func isWorkspaceKey(_ key: String) -> Bool {
        key.utf8.count == 64 && key.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    private func unixSeconds(_ date: Date) -> UInt64 {
        UInt64(max(0, date.timeIntervalSince1970.rounded(.down)))
    }

    private func lastUsedDate(at workspaceCacheURL: URL) throws -> Date? {
        let markerURL = workspaceCacheURL.appendingPathComponent(Self.lastUsedMarkerName)
        do {
            return try markerURL.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
        } catch {
            if isMissingFileError(error) {
                return nil
            }
            throw error
        }
    }

    private func isMissingFileError(_ error: Error) -> Bool {
        let cocoaError = error as NSError
        return cocoaError.domain == NSCocoaErrorDomain
            && (cocoaError.code == NSFileNoSuchFileError
                || cocoaError.code == NSFileReadNoSuchFileError)
    }

    private func languageServerVersion(for executableURL: URL?) throws -> String {
        let fileManager = FileManager.default
        var roots: [URL] = []
        if let executableURL {
            let bin = executableURL.standardizedFileURL.deletingLastPathComponent()
            roots.append(bin)
            roots.append(bin.deletingLastPathComponent())
        }
        if let resourceURL = Bundle.main.resourceURL {
            roots.append(
                resourceURL
                    .appendingPathComponent("LanguageServers", isDirectory: true)
                    .appendingPathComponent("jdtls", isDirectory: true)
            )
        }

        var visited: Set<String> = []
        for root in roots where visited.insert(root.standardizedFileURL.path).inserted {
            let manifestURL = root.appendingPathComponent(Self.manifestName)
            do {
                let data = try Data(contentsOf: manifestURL)
                let manifest: JdtManifest
                do {
                    manifest = try JSONDecoder().decode(JdtManifest.self, from: data)
                } catch {
                    throw MacJdtWorkspaceStateError.invalidLanguageServerManifest(
                        manifestURL.path
                    )
                }
                let version = manifest.version.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !version.isEmpty else {
                    throw MacJdtWorkspaceStateError.invalidLanguageServerManifest(
                        manifestURL.path
                    )
                }
                return version
            } catch where isMissingFileError(error) {
                // A selected development executable may not ship a manifest;
                // the JDT LS core plug-in name remains the next stable source.
            }

            let pluginsURL = root.appendingPathComponent("plugins", isDirectory: true)
            let names: [String]
            do {
                names = try fileManager.contentsOfDirectory(atPath: pluginsURL.path)
            } catch where isMissingFileError(error) {
                continue
            }
            if let pluginName = names.sorted().first(where: {
                $0.hasPrefix(Self.corePluginPrefix) && $0.hasSuffix(".jar")
            }) {
                let suffix = pluginName
                    .dropFirst(Self.corePluginPrefix.count)
                    .dropLast(".jar".count)
                let components = suffix.split(separator: ".")
                if components.count >= 3 {
                    return components.prefix(3).joined(separator: ".")
                }
                return String(suffix)
            }
        }
        throw MacJdtWorkspaceStateError.languageServerVersionUnavailable
    }
}

private struct JdtManifest: Decodable {
    let version: String
}

struct MacJdtCacheCleanupResult: Equatable {
    let retentionDays: UInt64
    let removedWorkspaceKeys: [String]
}

private enum MacJdtWorkspaceStateError: LocalizedError {
    case workspaceFingerprintUnavailable
    case invalidBuildFileMetadata(String)
    case invalidLanguageServerManifest(String)
    case languageServerVersionUnavailable
    case invalidWorkspaceKey
    case cacheRetentionUnavailable
    case invalidRetentionPlan
    case invalidRetentionTarget

    var errorDescription: String? {
        switch self {
        case .workspaceFingerprintUnavailable:
            "Rust Core workspace-fingerprint resolution is unavailable."
        case .invalidBuildFileMetadata(let path):
            "Could not read Java build-file metadata for \(path)."
        case .invalidLanguageServerManifest(let path):
            "The bundled JDT LS manifest is invalid at \(path)."
        case .languageServerVersionUnavailable:
            "The bundled JDT LS version could not be determined."
        case .invalidWorkspaceKey:
            "Rust Core returned an invalid Java workspace key."
        case .cacheRetentionUnavailable:
            "Rust Core cache-retention planning is unavailable."
        case .invalidRetentionPlan:
            "Rust Core returned a Java cache-retention key that was not observed."
        case .invalidRetentionTarget:
            "A Java cache-retention target is not a removable directory."
        }
    }
}
