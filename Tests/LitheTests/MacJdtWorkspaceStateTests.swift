import Foundation
import Testing
@testable import Lithe

@Suite("macOS JDT LS workspace state")
struct MacJdtWorkspaceStateTests {
    @Test
    func fingerprintIncludesVersionWithoutRootBuildFiles() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let state = MacJdtWorkspaceState(
            cacheDirectoryURL: fixture.cacheURL,
            workspaceFingerprintResolver: { buildFiles, modules, version in
                #expect(buildFiles.isEmpty)
                #expect(modules.isEmpty)
                #expect(version == "7.6.5")
                return "core-fingerprint"
            },
            workspaceKeyResolver: { _, _ in String(repeating: "a", count: 64) }
        )

        let fingerprint = try state.fingerprint(
            at: fixture.workspaceURL,
            languageServerExecutableURL: fixture.executableURL
        )

        #expect(fingerprint == "core-fingerprint")
    }

    @Test
    func fingerprintObservesRootBuildFilesAndDirectMavenModules() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let capture = FingerprintObservationCapture()
        let state = MacJdtWorkspaceState(
            cacheDirectoryURL: fixture.cacheURL,
            workspaceFingerprintResolver: { buildFiles, modules, version in
                capture.record(buildFiles: buildFiles, modules: modules, version: version)
                return "core-fingerprint"
            },
            workspaceKeyResolver: { _, _ in String(repeating: "a", count: 64) }
        )
        _ = try state.fingerprint(
            at: fixture.workspaceURL,
            languageServerExecutableURL: fixture.executableURL
        )
        #expect(capture.last?.buildFiles.isEmpty == true)

        try write("a", to: fixture.workspaceURL.appendingPathComponent("pom.xml"))
        _ = try state.fingerprint(
            at: fixture.workspaceURL,
            languageServerExecutableURL: fixture.executableURL
        )
        let initialPomSize = capture.last?.buildFiles.first?.sizeBytes
        #expect(capture.last?.buildFiles.map(\.path) == ["pom.xml"])
        try write(
            "a larger project descriptor",
            to: fixture.workspaceURL.appendingPathComponent("pom.xml")
        )
        _ = try state.fingerprint(
            at: fixture.workspaceURL,
            languageServerExecutableURL: fixture.executableURL
        )
        #expect((capture.last?.buildFiles.first?.sizeBytes ?? 0) > (initialPomSize ?? 0))

        for moduleName in ["zeta", "alpha"] {
            let moduleURL = fixture.workspaceURL.appendingPathComponent(
                moduleName,
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: moduleURL,
                withIntermediateDirectories: true
            )
            try write("<project/>", to: moduleURL.appendingPathComponent("pom.xml"))
        }
        let gradleOnlyURL = fixture.workspaceURL.appendingPathComponent(
            "gradle-only",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: gradleOnlyURL,
            withIntermediateDirectories: true
        )
        try write("plugins {}", to: gradleOnlyURL.appendingPathComponent("build.gradle"))
        _ = try state.fingerprint(
            at: fixture.workspaceURL,
            languageServerExecutableURL: fixture.executableURL
        )

        #expect(Set(capture.last?.modules ?? []) == Set(["alpha", "zeta"]))
        #expect(capture.last?.version == "7.6.5")
    }

    @Test
    func clearIndexRemovesOnlyTheResolvedWorkspaceKey() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let currentKey = String(repeating: "a", count: 64)
        let siblingKey = String(repeating: "b", count: 64)
        let jdtlsCacheURL = fixture.cacheURL.appendingPathComponent("jdtls", isDirectory: true)
        let currentURL = jdtlsCacheURL.appendingPathComponent(currentKey, isDirectory: true)
        let siblingURL = jdtlsCacheURL.appendingPathComponent(siblingKey, isDirectory: true)
        try FileManager.default.createDirectory(at: currentURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingURL, withIntermediateDirectories: true)
        try write("current", to: currentURL.appendingPathComponent("index.bin"))
        try write("sibling", to: siblingURL.appendingPathComponent("index.bin"))
        let state = MacJdtWorkspaceState(
            cacheDirectoryURL: fixture.cacheURL,
            workspaceKeyResolver: { rootURL, fingerprint in
                #expect(rootURL == fixture.workspaceURL.standardizedFileURL)
                #expect(fingerprint == "current-fingerprint")
                return currentKey
            }
        )

        try state.clearIndex(
            at: fixture.workspaceURL,
            workspaceFingerprint: "current-fingerprint"
        )

        #expect(!FileManager.default.fileExists(atPath: currentURL.path))
        #expect(FileManager.default.fileExists(atPath: siblingURL.path))
    }

    @Test
    func cacheCleanupRemovesOnlyCoreSelectedInactiveDirectories() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let expiredKey = String(repeating: "a", count: 64)
        let recentKey = String(repeating: "b", count: 64)
        let activeKey = String(repeating: "c", count: 64)
        let linkedKey = String(repeating: "d", count: 64)
        let now = Date(timeIntervalSince1970: 4_000_000)
        let jdtlsCacheURL = fixture.cacheURL.appendingPathComponent("jdtls", isDirectory: true)
        for key in [expiredKey, recentKey, activeKey] {
            try FileManager.default.createDirectory(
                at: jdtlsCacheURL.appendingPathComponent(key, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try FileManager.default.createSymbolicLink(
            at: jdtlsCacheURL.appendingPathComponent(linkedKey),
            withDestinationURL: jdtlsCacheURL.appendingPathComponent(recentKey, isDirectory: true)
        )
        try FileManager.default.createDirectory(
            at: jdtlsCacheURL.appendingPathComponent("not-a-cache-key", isDirectory: true),
            withIntermediateDirectories: true
        )
        try setModificationDate(
            Date(timeIntervalSince1970: 1_000_000),
            for: jdtlsCacheURL.appendingPathComponent(expiredKey, isDirectory: true)
        )
        try setModificationDate(
            Date(timeIntervalSince1970: 3_999_999),
            for: jdtlsCacheURL.appendingPathComponent(recentKey, isDirectory: true)
        )
        try setModificationDate(
            Date(timeIntervalSince1970: 1),
            for: jdtlsCacheURL.appendingPathComponent(activeKey, isDirectory: true)
        )

        let state = MacJdtWorkspaceState(
            cacheDirectoryURL: fixture.cacheURL,
            workspaceKeyResolver: { _, _ in activeKey },
            cacheRetentionPlanner: { nowUnixSeconds, activeWorkspaceKey, entries in
                #expect(nowUnixSeconds == 4_000_000)
                #expect(activeWorkspaceKey == activeKey)
                #expect(Set(entries.map(\.workspaceKey)) == Set([
                    expiredKey,
                    recentKey,
                    activeKey,
                ]))
                #expect(entries.first(where: { $0.workspaceKey == activeKey })?
                    .lastModifiedUnixSeconds == 4_000_000)
                return RustCoreBridge.JdtCacheRetentionPayload(
                    retentionDays: 30,
                    expiredWorkspaceKeys: [expiredKey]
                )
            }
        )

        let result = try state.pruneExpiredCaches(
            at: fixture.workspaceURL,
            workspaceFingerprint: "active-fingerprint",
            now: now
        )

        #expect(result == MacJdtCacheCleanupResult(
            retentionDays: 30,
            removedWorkspaceKeys: [expiredKey]
        ))
        #expect(!FileManager.default.fileExists(
            atPath: jdtlsCacheURL.appendingPathComponent(expiredKey).path
        ))
        for key in [recentKey, activeKey, linkedKey, "not-a-cache-key"] {
            #expect(FileManager.default.fileExists(
                atPath: jdtlsCacheURL.appendingPathComponent(key).path
            ))
        }
    }

    private func makeFixture() throws -> Fixture {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lithe-jdt-workspace-state-\(UUID().uuidString)",
            isDirectory: true
        )
        let workspaceURL = rootURL.appendingPathComponent("workspace", isDirectory: true)
        let cacheURL = rootURL.appendingPathComponent("cache", isDirectory: true)
        let jdtlsURL = rootURL.appendingPathComponent("jdtls", isDirectory: true)
        let binURL = jdtlsURL.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
        try write(#"{"version":"7.6.5"}"#, to: jdtlsURL.appendingPathComponent("manifest.json"))
        let executableURL = binURL.appendingPathComponent("jdtls")
        try write("#!/bin/zsh\n", to: executableURL)
        return Fixture(
            rootURL: rootURL,
            workspaceURL: workspaceURL,
            cacheURL: cacheURL,
            executableURL: executableURL
        )
    }

    private func write(_ value: String, to url: URL) throws {
        try Data(value.utf8).write(to: url)
    }

    private func setModificationDate(_ date: Date, for url: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: url.path
        )
    }
}

private final class FingerprintObservationCapture {
    struct Entry {
        let buildFiles: [RustCoreBridge.JdtBuildFileObservation]
        let modules: [String]
        let version: String
    }

    private(set) var last: Entry?

    func record(
        buildFiles: [RustCoreBridge.JdtBuildFileObservation],
        modules: [String],
        version: String
    ) {
        last = Entry(buildFiles: buildFiles, modules: modules, version: version)
    }
}

private struct Fixture {
    let rootURL: URL
    let workspaceURL: URL
    let cacheURL: URL
    let executableURL: URL

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
