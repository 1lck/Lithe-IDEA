import Combine
import Foundation
import LitheApplicationKernel
import LitheCoreContracts
import LitheModuleAPI

// Note: 插件语法高亮与运行标记的决策见 .agents/notes/implemented/architecture/2026-10-31-plugin-editor-extension-apis.md

/// Collects independent static editor resources of enabled plugins.
///
/// Grammar files are read from the installed package, read-only and only
/// inside it; Rust Core validates them. Nothing is written: decoded grammars
/// live in memory for this launch, keyed by the file's path, size and date,
/// so an updated package is read again.
@MainActor
final class MacPluginEditorLanguages: PluginEditorLanguageProviding {
    /// Largest grammar file Rust Core accepts (`MAX_GRAMMAR_BYTES`).
    static let maximumGrammarBytes = 256 * 1024

    private let launchRegistered: [InstalledPluginPackage]
    private let isModuleUsable: @MainActor (ModuleID) -> Bool
    private let livePackages: @MainActor () -> [InstalledPluginPackage]
    private let decoder: any DeclarativeEditorContributionDecoding
    private let log: @MainActor (_ message: String, _ fields: [String: String]) -> Void
    private let changeSubject = PassthroughSubject<Void, Never>()
    private var subscriptions: Set<AnyCancellable> = []
    /// Decoded languages by file identity; nil records a refused grammar so
    /// it is reported once.
    private var decoded: [String: ToolingJSONValue?] = [:]

    var changes: AnyPublisher<Void, Never> { changeSubject.eraseToAnyPublisher() }

    /// The runtime owns this observer; the callback must not own the runtime.
    @discardableResult
    static func observeModuleChanges(
        on runtime: ModuleRuntime,
        changed: @escaping @MainActor () -> Void,
        refreshBackends: @escaping @MainActor (ModuleRuntime) -> Void
    ) -> UUID {
        runtime.observeEvents { [weak runtime] event in
            guard event.name == ModuleEvent.stateChangedName, let runtime else { return }
            changed()
            refreshBackends(runtime)
        }
    }

    /// - Parameters:
    ///   - launchRegistered: Plugins in the module graph since launch. Their editor resources follow the grammars module.
    ///   - livePackages: The enabled plugins of the live registry.
    ///   - triggers: Live registry and module state changes.
    init(
        launchRegistered: [InstalledPluginPackage],
        isModuleUsable: @escaping @MainActor (ModuleID) -> Bool,
        livePackages: @escaping @MainActor () -> [InstalledPluginPackage],
        decoder: any DeclarativeEditorContributionDecoding,
        triggers: [AnyPublisher<Void, Never>],
        log: @escaping @MainActor (_ message: String, _ fields: [String: String]) -> Void
    ) {
        self.launchRegistered = launchRegistered.filter {
            $0.descriptor.languages.contains { $0.hasEditorResources }
        }
        self.isModuleUsable = isModuleUsable
        self.livePackages = livePackages
        self.decoder = decoder
        self.log = log
        for trigger in triggers {
            trigger.sink { [weak self] in self?.changeSubject.send() }.store(in: &subscriptions)
        }
    }

    func current() -> PluginEditorLanguageSet {
        var set = PluginEditorLanguageSet()
        var seen: Set<String> = []
        let grammarPackages = (launchRegistered.filter {
            isModuleUsable(.grammarsExtension($0.descriptor.id.rawValue))
        } + livePackages()).sorted { $0.descriptor.id.rawValue < $1.descriptor.id.rawValue }
        for package in grammarPackages {
            for language in package.descriptor.languages where language.hasEditorResources {
                // Static editor contributions may coexist with a domain owner.
                // First enabled plugin ID wins deterministically for presentation.
                guard seen.insert(language.id).inserted, let value = grammar(of: language, in: package) else { continue }
                set.languages.append(value)
            }
        }
        return set
    }

    private func grammar(of language: DeclarativePluginLanguage, in package: InstalledPluginPackage) -> ToolingJSONValue? {
        let fields = ["plugin": package.descriptor.id.rawValue, "language": language.id]
        guard let path = language.grammarPath else {
            return try? decoder.decodeGrammar(manifest: package.descriptor.normalizedManifest, languageID: language.id, grammar: "")
        }
        guard let url = Self.packageFile(path, in: package.packageURL) else {
            log("plugin grammar is outside its package", fields)
            return nil
        }
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            log("plugin grammar is not a regular file", fields)
            return nil
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? -1
        let date = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(size)|\(date)|\(language.id)|\(package.descriptor.normalizedManifest.base64EncodedString())"
        if let cached = decoded[key] { return cached }
        let value: ToolingJSONValue?
        do {
            guard size >= 0, size <= Self.maximumGrammarBytes else {
                throw DeclarativePluginRejection(code: "plugin.grammar.invalid",
                    message: "The grammar file is missing or larger than 256 KiB.", field: "grammar.path")
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let bytes = try handle.read(upToCount: Self.maximumGrammarBytes + 1) ?? Data()
            guard bytes.count <= Self.maximumGrammarBytes,
                  let text = String(data: bytes, encoding: .utf8) else {
                throw DeclarativePluginRejection(code: "plugin.grammar.invalid",
                    message: "The grammar file is not UTF-8.", field: "grammar.path")
            }
            value = try decoder.decodeGrammar(manifest: package.descriptor.normalizedManifest,
                                              languageID: language.id, grammar: text)
        } catch {
            log("plugin grammar refused", fields.merging(["error": error.localizedDescription]) { _, new in new })
            value = nil
        }
        decoded[key] = .some(value)
        return value
    }

    /// `path` inside the package, after resolving links; nil when it leaves it.
    static func packageFile(_ path: String, in packageURL: URL) -> URL? {
        let root = packageURL.standardizedFileURL.resolvingSymlinksInPath().path
        let file = packageURL.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return file.path.hasPrefix(prefix) ? file : nil
    }
}
