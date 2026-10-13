import Foundation
import CryptoKit
import Testing
@testable import Lithe

// Builds, signs, and mounts a real disk image, so its duration depends on the
// runner's diskutil and hdiutil. CI runs this suite in its own step and budget
// instead of letting it set the ceiling for every unit test.
@Suite("macOS stable rollback disk image integration")
struct StableRollbackDiskImageIntegrationTests {
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
        // Let diskutil build an uncompressed image directly from the already
        // signed payload. This avoids a second test-only mount/copy/unmount
        // cycle; StableRollbackPackage.prepare still exercises the production
        // hdiutil mount and validates the complete disk-image contract.
        try await runFixtureTool("/usr/sbin/diskutil", ["image", "create", "from", "--format", "UDRW",
                                                         root.appendingPathComponent("payload").path, dmg.path], timeoutMilliseconds: 20_000)
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
}

private func runFixtureTool(_ executable: String, _ arguments: [String], timeoutMilliseconds: Int = 10_000) async throws {
    let result: ProcessResult = await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            continuation.resume(returning: MacProcessRunner().run(ProcessRequest(executablePath: executable,
                arguments: arguments, timeoutMilliseconds: timeoutMilliseconds)))
        }
    }
    #expect(result.succeeded, "\(result.output)")
    guard result.succeeded else { throw UpdateCheckError.toolFailed(executable) }
}
