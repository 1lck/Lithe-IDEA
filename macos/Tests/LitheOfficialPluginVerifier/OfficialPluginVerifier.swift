import Foundation
import LitheApplicationKernel
import LitheCoreContracts
import LitheModuleAPI

/// Checks a built official declarative plugin package before release. Rust
/// Core tests validate the declaration semantics; this verifier checks what
/// only the assembled package can prove: the host trust policy matches, every
/// packaged executable exists, native code is declared by the plugin, and
/// the synthesized modules join the built-in graph.
@main
struct OfficialPluginVerifier {
    @MainActor
    static func main() async {
        do {
            try await verify()
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    @MainActor
    private static func verify() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw VerificationError.usage
        }
        let packageURL = URL(
            fileURLWithPath: CommandLine.arguments[1],
            isDirectory: true
        ).standardizedFileURL.resolvingSymlinksInPath()
        let manifestData = try Data(contentsOf: packageURL.appendingPathComponent("plugin.json"))
        let descriptor = try DeclarativePluginDescriptor(normalizedManifest: manifestData)
        let manifest = descriptor.pluginManifest
        guard let policy = OfficialPluginCatalog.trustPolicy(for: manifest.id),
              policy.signatureRequirement == manifest.vendor.signatureRequirement,
              policy.bundledSignatureRequirement == manifest.vendor.bundledSignatureRequirement,
              packageURL.lastPathComponent == manifest.id.rawValue else {
            throw VerificationError.trustPolicyMismatch(manifest.id.rawValue)
        }

        var runtimeDirectories: [String] = []
        for server in descriptor.languageServers {
            switch server.launch {
            case .packaged(let relativePath):
                try requireFile(relativePath, in: packageURL, executable: true)
            case .runtime(_, let entryRelativePath, let packagedRuntime):
                try requireFile(entryRelativePath, in: packageURL, executable: false)
                guard let packagedRuntime else { continue }
                // A package may carry a runtime for one or both architectures;
                // each one that is present must be complete.
                let present = ["arm64", "x86_64"]
                    .map { packagedRuntime.replacingOccurrences(of: "${arch}", with: $0) }
                    .filter { FileManager.default.fileExists(atPath: packageURL.appendingPathComponent($0).path) }
                guard !present.isEmpty else { throw VerificationError.missingLaunch(packagedRuntime) }
                for relativePath in present {
                    try requireFile(relativePath, in: packageURL, executable: true)
                }
                if let directory = packagedRuntime.split(separator: "/").first {
                    runtimeDirectories.append(String(directory))
                }
            case .systemCommand, .backend:
                // The backend chooses the command when the server starts, so
                // there is no file to check in the package yet.
                continue
            }
        }
        try rejectSymbolicLinks(in: packageURL)
        var backendExecutables: Set<String> = []
        let artifact = try JSONDecoder().decode(BackendArtifact.self, from: manifestData)
        if let launch = artifact.backend?.launch, launch.kind == "packaged" {
            guard let path = launch.path, isSafeRelativePath(path) else {
                throw VerificationError.missingLaunch("backend")
            }
            try requireFile(path, in: packageURL, executable: true)
            backendExecutables.insert(path)
        }
        try rejectNativeCode(in: packageURL, exceptIn: runtimeDirectories, exceptFiles: backendExecutables)

        _ = try ValidatedPluginCatalog(
            manifests: BuiltInPluginCatalog.manifests + [manifest],
            hostVersion: BuiltInPluginCatalog.hostVersion
        )
        let runtime = ModuleRuntime()
        for declaration in (BuiltInPluginCatalog.manifests + [manifest]).flatMap(\.modules) {
            try runtime.register(ModuleFactory(
                manifest: declaration.manifest,
                contributions: declaration.contributions
            ) {
                throw VerificationError.factoryMustNotBeInvoked
            })
        }
        try runtime.validateGraph()
        await runtime.shutdownAll()
        print("Verified \(manifest.id) as a declarative package")
    }

    /// The verifier checks packaged artifacts only; Core owns launch planning.
    private struct BackendArtifact: Decodable {
        struct Backend: Decodable {
            struct Launch: Decodable { let kind: String; let path: String? }
            let launch: Launch
        }
        let backend: Backend?
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.contains("\\") && !path.contains("\0")
            && path.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func requireFile(_ relativePath: String, in packageURL: URL, executable: Bool) throws {
        let url = packageURL.appendingPathComponent(relativePath)
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values?.isRegularFile == true,
              values?.isSymbolicLink != true,
              !executable || FileManager.default.isExecutableFile(atPath: url.path) else {
            throw VerificationError.missingLaunch(relativePath)
        }
    }

    /// Paths inside the package, relative to its root. Resolving the root drops
    /// a leading `/private` (for example under `TMPDIR`), while a URL
    /// enumerator reports the `/private` form, so trimming the root from
    /// enumerated URLs would not yield a relative path. The path enumerator
    /// returns relative paths directly.
    private static func relativePaths(in packageURL: URL) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: packageURL.path) else {
            throw VerificationError.unreadablePackage
        }
        return enumerator.compactMap { $0 as? String }
    }

    /// The contract forbids symbolic links anywhere in a package.
    private static func rejectSymbolicLinks(in packageURL: URL) throws {
        for relativePath in try relativePaths(in: packageURL)
        where (try? packageURL.appendingPathComponent(relativePath)
            .resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw VerificationError.symbolicLink(relativePath)
        }
    }

    /// Permit only a declared backend executable or a declared packaged runtime.
    /// Bundled builds use the application's seal; independent packages require
    /// a publisher signature over the final artifacts.
    private static func rejectNativeCode(in packageURL: URL, exceptIn runtimeDirectories: [String],
                                         exceptFiles: Set<String>) throws {
        let machOMagics: Set<UInt32> = [0xfeedface, 0xfeedfacf, 0xcefaedfe, 0xcffaedfe, 0xcafebabe, 0xbebafeca]
        for relativePath in try relativePaths(in: packageURL) {
            let fileURL = packageURL.appendingPathComponent(relativePath)
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let handle = try? FileHandle(forReadingFrom: fileURL) else { continue }
            defer { try? handle.close() }
            guard let header = try handle.read(upToCount: 4), header.count == 4 else { continue }
            let magic = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            if machOMagics.contains(magic) || machOMagics.contains(magic.byteSwapped) {
                if exceptFiles.contains(relativePath)
                    || runtimeDirectories.contains(where: { relativePath.hasPrefix($0 + "/") }) { continue }
                throw VerificationError.nativeCode(relativePath)
            }
        }
    }
}

private enum VerificationError: Error, CustomStringConvertible {
    case usage
    case trustPolicyMismatch(String)
    case missingLaunch(String)
    case nativeCode(String)
    case symbolicLink(String)
    case unreadablePackage
    case factoryMustNotBeInvoked

    var description: String {
        switch self {
        case .usage: "Usage: LitheOfficialPluginVerifier <package-directory>"
        case .trustPolicyMismatch(let id): "\(id) does not match the host's official plugin trust policy."
        case .missingLaunch(let path): "A declared launch file is missing or not executable: \(path)"
        case .nativeCode(let path): "Native code is only allowed in a declared backend or packaged runtime: \(path)"
        case .symbolicLink(let path): "Plugin packages must not contain symbolic links: \(path)"
        case .unreadablePackage: "The plugin package could not be read."
        case .factoryMustNotBeInvoked: "A module factory was invoked during static validation."
        }
    }
}
