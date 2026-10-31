import Combine
import Foundation
import LitheCoreContracts
import LitheModuleAPI

// Note: 插件语法高亮与运行标记的决策见 .agents/notes/implemented/architecture/2026-10-31-plugin-grammars-and-run-markers.md

/// Collects the grammars (`languages` 2) and Run marker providers
/// (`runMarkers` 1) of the active plugins for the editors of every window.
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

    /// - Parameters:
    ///   - launchRegistered: Plugins in the module graph since launch. Their
    ///     grammars follow the grammars module, their providers the UI module
    ///     that owns the command.
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
            $0.descriptor.languages.contains { $0.grammarPath != nil } || !$0.descriptor.runMarkerProviders.isEmpty
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
            for language in package.descriptor.languages where language.grammarPath != nil {
                // Rust Core's catalog refuses two plugins declaring one
                // language; the first plugin by ID keeps it regardless.
                guard seen.insert(language.id).inserted, let value = grammar(of: language, in: package) else { continue }
                set.languages.append(value)
            }
        }
        for package in launchRegistered where isModuleUsable(ModuleID("\(package.descriptor.id.rawValue).ui")) {
            for provider in package.descriptor.runMarkerProviders where set.runMarkerProviders[provider.languageID] == nil {
                set.runMarkerProviders[provider.languageID] = PluginRunMarkerProvider(
                    pluginID: package.descriptor.id.rawValue, manifest: package.descriptor.normalizedManifest,
                    languageID: provider.languageID, functionID: provider.functionID, commandID: provider.commandID
                )
            }
        }
        return set
    }

    func decodeRunMarkers(
        _ provider: PluginRunMarkerProvider, lineCount: Int, result: ToolingJSONValue
    ) throws -> [PluginRunMarker] {
        try decoder.decodeRunMarkers(
            manifest: provider.manifest, languageID: provider.languageID, lineCount: lineCount, result: result
        )
    }

    private func grammar(of language: DeclarativePluginLanguage, in package: InstalledPluginPackage) -> ToolingJSONValue? {
        let fields = ["plugin": package.descriptor.id.rawValue, "language": language.id]
        guard let path = language.grammarPath, let url = Self.packageFile(path, in: package.packageURL) else {
            log("plugin grammar is outside its package", fields)
            return nil
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? -1
        let date = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(size)|\(date)|\(language.id)"
        if let cached = decoded[key] { return cached }
        let value: ToolingJSONValue?
        do {
            guard size >= 0, size <= Self.maximumGrammarBytes else {
                throw DeclarativePluginRejection(code: "plugin.grammar.invalid",
                    message: "The grammar file is missing or larger than 256 KiB.", field: "grammar.path")
            }
            guard let text = String(data: try Data(contentsOf: url), encoding: .utf8) else {
                throw DeclarativePluginRejection(code: "plugin.grammar.invalid",
                    message: "The grammar file is not UTF-8.", field: "grammar.path")
            }
            value = try decoder.decodeGrammar(manifest: package.descriptor.normalizedManifest,
                                              languageID: language.id, grammar: text)
        } catch {
            log("plugin grammar refused", fields.merging(["error": error.localizedDescription]) { _, new in new })
            value = nil
        }
        decoded[key] = value
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
