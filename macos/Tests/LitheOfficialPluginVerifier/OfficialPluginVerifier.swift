import Foundation
import LitheApplicationKernel
import LitheCoreContracts
import LitheModuleAPI

/// Checks a built official declarative plugin package before release. Rust
/// Core tests validate the declaration semantics; this verifier checks what
/// only the assembled package can prove: the host trust policy matches, every
/// packaged executable exists, no native code is present, and the synthesized
/// modules join the built-in graph.
@main
struct OfficialPluginVerifier {
    @MainActor
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw VerificationError.usage
        }
        let packageURL = URL(
            fileURLWithPath: CommandLine.arguments[1],
            isDirectory: true
        ).standardizedFileURL.resolvingSymlinksInPath()
        let descriptor = try DeclarativePluginDescriptor(
            normalizedManifest: Data(contentsOf: packageURL.appendingPathComponent("plugin.json"))
        )
        let manifest = descriptor.pluginManifest
        guard let entry = OfficialPluginCatalog.entry(for: manifest.id),
              entry.signatureRequirement == manifest.vendor.signatureRequirement,
              packageURL.lastPathComponent == manifest.id.rawValue else {
            throw VerificationError.trustPolicyMismatch(manifest.id.rawValue)
        }

        for server in descriptor.languageServers {
            guard case .packaged(let relativePath) = server.launch else { continue }
            let executableURL = packageURL.appendingPathComponent(relativePath)
            let values = try executableURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  FileManager.default.isExecutableFile(atPath: executableURL.path) else {
                throw VerificationError.missingLaunch(relativePath)
            }
        }
        try rejectNativeCode(in: packageURL)

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

    /// A declarative package must not ship Mach-O code: the host never loads
    /// plugin code, and native binaries would need their own code signature.
    private static func rejectNativeCode(in packageURL: URL) throws {
        let machOMagics: Set<UInt32> = [0xfeedface, 0xfeedfacf, 0xcefaedfe, 0xcffaedfe, 0xcafebabe, 0xbebafeca]
        guard let enumerator = FileManager.default.enumerator(
            at: packageURL,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { throw VerificationError.unreadablePackage }
        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let handle = try? FileHandle(forReadingFrom: fileURL) else { continue }
            defer { try? handle.close() }
            guard let header = try handle.read(upToCount: 4), header.count == 4 else { continue }
            let magic = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            if machOMagics.contains(magic) || machOMagics.contains(magic.byteSwapped) {
                throw VerificationError.nativeCode(fileURL.path.replacingOccurrences(of: packageURL.path + "/", with: ""))
            }
        }
    }
}

private enum VerificationError: Error, CustomStringConvertible {
    case usage
    case trustPolicyMismatch(String)
    case missingLaunch(String)
    case nativeCode(String)
    case unreadablePackage
    case factoryMustNotBeInvoked

    var description: String {
        switch self {
        case .usage: "Usage: LitheOfficialPluginVerifier <package-directory>"
        case .trustPolicyMismatch(let id): "\(id) does not match the host's official plugin trust policy."
        case .missingLaunch(let path): "The packaged language server is missing or not executable: \(path)"
        case .nativeCode(let path): "Declarative packages must not contain native code: \(path)"
        case .unreadablePackage: "The plugin package could not be read."
        case .factoryMustNotBeInvoked: "A module factory was invoked during static validation."
        }
    }
}
