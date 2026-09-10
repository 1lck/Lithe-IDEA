import Foundation
import CryptoKit
import Combine
import Testing
@testable import Lithe

@Suite("macOS stable rollback")
struct StableRollbackTests {
    @Test @MainActor
    func cancelledExitKeepsPreparedPackageAndDoesNotLaunchHelper() async throws {
        let fixture = try RollbackFixture()
        defer { fixture.remove() }
        let package = StableRollbackPackage(root: fixture.stage, target: fixture.target, version: "0.2.0")
        let ready = TestGate()
        let rollback = MacStableRollback { _, preparing in
            await preparing()
            return package
        }
        let observation = rollback.$state.sink { state in
            if case .ready = state { ready.open() }
        }
        defer { observation.cancel() }
        var requests = 0
        rollback.requestTermination = { requests += 1 }
        rollback.download(bundle: .main)
        #expect(await ready.waitUntilOpen())
        rollback.install()
        #expect(rollback.state == .requestingTermination)
        rollback.terminationCancelled()
        #expect(rollback.state == .ready("0.2.0"))
        rollback.install()
        rollback.terminationCancelled()
        #expect(requests == 2)
        #expect(!FileManager.default.fileExists(atPath: fixture.stage.appendingPathComponent("replace.sh").path))
        let cleanup = TestGate()
        let cleanupObservation = rollback.$state.sink { if $0 == .idle { cleanup.open() } }
        defer { cleanupObservation.cancel() }
        rollback.cancel()
        #expect(await cleanup.waitUntilOpen())
        #expect(!FileManager.default.fileExists(atPath: fixture.stage.path))
    }

    @Test @MainActor
    func cancelledDownloadDiscardsLatePreparedPackage() async throws {
        let fixture = try RollbackFixture()
        defer { fixture.remove() }
        let started = TestGate()
        let release = TestGate()
        let finished = TestGate()
        let package = StableRollbackPackage(root: fixture.stage, target: fixture.target, version: "0.2.0")
        let rollback = MacStableRollback { _, _ in
            started.open()
            _ = await release.waitUntilOpen()
            return package
        }
        defer { release.open() }
        rollback.download(bundle: .main)
        #expect(await started.waitUntilOpen())
        let observation = rollback.$state.sink { if $0 == .idle { finished.open() } }
        defer { observation.cancel() }
        rollback.cancel()
        release.open()
        #expect(await finished.waitUntilOpen())
        #expect(!FileManager.default.fileExists(atPath: fixture.stage.path))
    }

    @Test
    func fullSignedDiskImageStagesWithoutChangingInstalledApp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rollback-dmg-\(UUID().uuidString)")
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: root) }
        let app = root.appendingPathComponent("payload/Lithe.app")
        try manager.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        // System executables can be arm64e-only, which is not the product's
        // arm64 distribution. Build a tiny fixture with the actual target arch.
        let source = root.appendingPathComponent("main.c")
        try "int main(void) { return 0; }".write(to: source, atomically: true, encoding: .utf8)
        try await runFixtureTool("/usr/bin/clang", ["-arch", try #require(UpdateArchitecture.current).rawValue,
            source.path, "-o", app.appendingPathComponent("Contents/MacOS/Lithe").path])
        let info = ["CFBundleIdentifier": "example.lithe", "CFBundleShortVersionString": "0.2.0",
                    "CFBundleVersion": "1", "CFBundleExecutable": "Lithe", "CFBundlePackageType": "APPL",
                    "LitheUpdateChannel": "stable"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let dmg = root.appendingPathComponent("stable.dmg")
        try await runFixtureTool("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        try await runFixtureTool("/usr/bin/hdiutil", ["create", "-srcfolder", root.appendingPathComponent("payload").path,
                                                   "-format", "UDZO", dmg.path])
        let archiveData = try Data(contentsOf: dmg)
        let checksum = SHA256.hash(data: archiveData).map { String(format: "%02x", $0) }.joined()
        let publisher = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32))
        let publicKey = publisher.publicKey.rawRepresentation.base64EncodedString()
        let signature = try publisher.signature(for: archiveData).base64EncodedString()
        let target = root.appendingPathComponent("Installed.app")
        try manager.createDirectory(at: target, withIntermediateDirectories: false)
        // Valid checksum and ad-hoc signature cannot substitute for publisher
        // authentication, even if the attacker controls the entire manifest.
        for invalidSignature: String? in [nil, "invalid", Data(repeating: 0, count: 64).base64EncodedString()] {
            do {
                _ = try await StableRollbackPackage.prepare(download: dmg,
                    asset: UpdateManifestAsset(url: URL(string: "https://example.com/stable.dmg")!, sha256: checksum, edSignature: invalidSignature),
                    version: "0.2.0", target: target, identifier: "example.lithe",
                    architecture: try #require(UpdateArchitecture.current), publicKey: publicKey)
                Issue.record("Missing or forged publisher signatures must fail before mounting")
            } catch let failure as StableRollbackFailure {
                guard case .invalidPublisherSignature = failure else { throw failure }
            }
        }
        let package = try await StableRollbackPackage.prepare(download: dmg,
            asset: UpdateManifestAsset(url: URL(string: "https://example.com/stable.dmg")!, sha256: checksum, edSignature: signature),
            version: "0.2.0", target: target, identifier: "example.lithe", architecture: try #require(UpdateArchitecture.current), publicKey: publicKey)
        #expect(package.version == "0.2.0")
        #expect(manager.fileExists(atPath: package.root.appendingPathComponent("new.app/Contents/MacOS/Lithe").path))
        #expect(try manager.contentsOfDirectory(atPath: target.path).isEmpty)
        try await package.discard()
        #expect(!manager.fileExists(atPath: package.root.path))
    }

    @Test
    func acceptsOlderStableButRejectsPreviewAndMismatchedPackages() throws {
        let info: [String: Any] = ["CFBundleIdentifier": "example.lithe", "CFBundleShortVersionString": "0.2.0",
                                   "CFBundleExecutable": "Lithe", "LitheUpdateChannel": "stable"]
        try StableRollbackPackage.validateBundle(info, identifier: "example.lithe", version: "0.2.0")
        for (key, value) in [("CFBundleIdentifier", "example.other"), ("CFBundleShortVersionString", "0.3.0"),
                             ("LitheUpdateChannel", "preview"), ("LitheUpdateChannel", "unknown"),
                             ("LSMinimumSystemVersion", "999.0.0")] {
            var invalid = info
            invalid[key] = value
            #expect(throws: StableRollbackFailure.self) {
                try StableRollbackPackage.validateBundle(invalid, identifier: "example.lithe", version: "0.2.0")
            }
        }
    }

    @Test
    func checksumFailureNeverStagesOrReplacesTheApp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let download = root.appendingPathComponent("corrupt.dmg")
        try Data("corrupted".utf8).write(to: download)
        do {
            _ = try await StableRollbackPackage.prepare(download: download,
                asset: UpdateManifestAsset(url: URL(string: "https://example.com/stable.dmg")!, sha256: String(repeating: "0", count: 64)),
                version: "0.2.0", target: root.appendingPathComponent("Lithe.app"), identifier: "example.lithe", architecture: .arm64, publicKey: "invalid")
            Issue.record("A corrupted full download must never reach installation")
        } catch let error as UpdateCheckError {
            #expect(error == .checksumMismatch)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["corrupt.dmg"])
    }

    @Test(arguments: [true, false])
    func helperInstallsOrRestoresWithoutLaunchingFixtureApps(launchSucceeds: Bool) throws {
        let fixture = try RollbackFixture()
        defer { fixture.remove() }
        let result = fixture.run(pid: Int32.max, opener: launchSucceeds ? "/usr/bin/true" : "/usr/bin/false")
        #expect(result.succeeded == launchSucceeds)
        #expect(try String(contentsOf: fixture.target.appendingPathComponent("identity"), encoding: .utf8)
                == (launchSucceeds ? "stable" : "preview"))
        if launchSucceeds {
            #expect(try String(contentsOf: fixture.stage.appendingPathComponent("previous.app/identity"), encoding: .utf8) == "preview")
        }
    }

    @Test
    func preparationDiagnosticsPreserveFailureWithoutLocalPaths() throws {
        let fixture = try RollbackFixture()
        defer { fixture.remove() }
        let result = MacProcessRunner().run(ProcessRequest(executablePath: "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", fixture.target.path], timeoutMilliseconds: 3000))
        #expect(!result.succeeded)
        let diagnostic = StableRollbackPackage.preparationDiagnostic(executable: "/usr/bin/codesign",
            arguments: [fixture.target.path], exitCode: result.exitCode, output: result.output + String(repeating: "x", count: 3000))
        #expect(diagnostic.contains("stage=codesign"))
        #expect(diagnostic.contains("exit=\(result.exitCode)"))
        #expect(!diagnostic.contains(fixture.root.path))
        #expect(!diagnostic.contains(NSHomeDirectory()))
        #expect(diagnostic.count < 2200)
        #expect(diagnostic.contains("<path>"))
    }

    @Test
    func helperNeverReplacesOrKillsARunningApp() throws {
        let fixture = try RollbackFixture()
        defer { fixture.remove() }
        let result = fixture.run(pid: ProcessInfo.processInfo.processIdentifier, opener: "/usr/bin/true")
        #expect(!result.succeeded)
        #expect(try String(contentsOf: fixture.target.appendingPathComponent("identity"), encoding: .utf8) == "preview")
        #expect(!FileManager.default.fileExists(atPath: fixture.stage.appendingPathComponent("previous.app").path))
    }

    @Test @MainActor
    func unpreparedRollbackCannotRequestExitOrLaunchAHelper() {
        let rollback = MacStableRollback()
        var requested = false
        rollback.requestTermination = { requested = true }
        rollback.install()
        rollback.terminationCancelled()
        #expect(!requested)
        #expect(rollback.state == .idle)
        #expect(rollback.prepareConfirmedTermination())
    }
}

private func runFixtureTool(_ executable: String, _ arguments: [String]) async throws {
    let result: ProcessResult = await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            continuation.resume(returning: MacProcessRunner().run(ProcessRequest(executablePath: executable,
                arguments: arguments, timeoutMilliseconds: 10_000)))
        }
    }
    #expect(result.succeeded, "\(result.output)")
    guard result.succeeded else { throw UpdateCheckError.toolFailed(executable) }
}

private struct RollbackFixture {
    let root: URL
    let stage: URL
    let target: URL
    let script: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rollback space '\(UUID().uuidString)")
        stage = root.appendingPathComponent("stage")
        target = root.appendingPathComponent("Lithe.app")
        script = root.appendingPathComponent("replace.sh")
        do {
            try FileManager.default.createDirectory(at: stage.appendingPathComponent("new.app"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try "preview".write(to: target.appendingPathComponent("identity"), atomically: true, encoding: .utf8)
            try "stable".write(to: stage.appendingPathComponent("new.app/identity"), atomically: true, encoding: .utf8)
            try StableRollbackPackage.replacementScript.write(to: script, atomically: true, encoding: .utf8)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func run(pid: Int32, opener: String) -> ProcessResult {
        MacProcessRunner().run(ProcessRequest(executablePath: "/bin/sh",
            arguments: [script.path, String(pid), stage.path, target.path, opener, "0"], timeoutMilliseconds: 3000))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
