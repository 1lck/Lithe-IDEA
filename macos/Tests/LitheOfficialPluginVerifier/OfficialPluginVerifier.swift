import Foundation
import LitheApplicationKernel
import LitheCoreContracts
import LitheModuleAPI

/// Checks a built official declarative plugin package before release. Rust
/// Core tests validate the declaration semantics; this verifier checks what
/// only the assembled package can prove: the host trust policy matches, every
/// packaged executable exists, native code appears only inside a runtime the
/// plugin declares, and the synthesized modules join the built-in graph.
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
            case .systemCommand:
                continue
            }
        }
        try rejectSymbolicLinks(in: packageURL)
        try rejectNativeCode(in: packageURL, exceptIn: runtimeDirectories)

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

    private static func requireFile(_ relativePath: String, in packageURL: URL, executable: Bool) throws {
        let url = packageURL.appendingPathComponent(relativePath)
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values?.isRegularFile == true,
              values?.isSymbolicLink != true,
              !executable || FileManager.default.isExecutableFile(atPath: url.path) else {
            throw VerificationError.missingLaunch(relativePath)
        }
    }

    /// The contract forbids symbolic links anywhere in a package.
    private static func rejectSymbolicLinks(in packageURL: URL) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: packageURL,
            includingPropertiesForKeys: [.isSymbolicLinkKey]
        ) else { throw VerificationError.unreadablePackage }
        for case let fileURL as URL in enumerator
        where (try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw VerificationError.symbolicLink(
                fileURL.path.replacingOccurrences(of: packageURL.path + "/", with: "")
            )
        }
    }

    /// The host never loads plugin code, so Mach-O files are allowed only in
    /// the top-level directory of a runtime the plugin declares with
    /// `packagedRuntime`. Such a package ships inside the signed application,
    /// whose code signature covers the runtime's binaries.
    private static func rejectNativeCode(in packageURL: URL, exceptIn runtimeDirectories: [String]) throws {
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
                let relativePath = fileURL.path.replacingOccurrences(of: packageURL.path + "/", with: "")
                if runtimeDirectories.contains(where: { relativePath.hasPrefix($0 + "/") }) { continue }
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
        case .nativeCode(let path): "Native code is only allowed inside a declared packaged runtime: \(path)"
        case .symbolicLink(let path): "Plugin packages must not contain symbolic links: \(path)"
        case .unreadablePackage: "The plugin package could not be read."
        case .factoryMustNotBeInvoked: "A module factory was invoked during static validation."
        }
    }
}
