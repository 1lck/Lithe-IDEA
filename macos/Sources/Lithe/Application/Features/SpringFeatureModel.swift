import Combine
import Foundation
import LitheCoreContracts

/// Owns the workspace-level Spring semantic projection produced by Rust Core.
@MainActor
final class SpringFeatureModel: ObservableObject {
    @Published private(set) var properties: [SpringProperty] = []
    @Published private(set) var values: [SpringConfigurationValue] = []
    @Published private(set) var propertyReferences: [SpringPropertyReference] = []
    @Published private(set) var diagnostics: [SpringDiagnostic] = []
    @Published private(set) var beans: [SpringBean] = []
    @Published private(set) var injections: [SpringInjection] = []
    @Published private(set) var endpoints: [SpringEndpoint] = []
    @Published private(set) var isIndexing = false

    private let operations: any JavaMavenOperations
    private var generation = UUID()
    private var reloadTask: Task<Void, Never>?

    init(operations: any JavaMavenOperations) {
        self.operations = operations
    }

    func load(
        workspaceURL: URL,
        files: [URL],
        textOverrides: [URL: String] = [:],
        refreshDependencyMetadata: Bool = true
    ) async {
        generation = UUID()
        let currentGeneration = generation
        isIndexing = true
        let operations = self.operations
        let result = await Task.detached(priority: .utility) {
            operations.springIndex(
                at: workspaceURL,
                files: files,
                textOverrides: textOverrides,
                refreshDependencyMetadata: refreshDependencyMetadata
            )
        }.value ?? .empty
        guard generation == currentGeneration else { return }
        properties = result.properties
        values = result.values
        propertyReferences = result.propertyReferences
        diagnostics = result.diagnostics
        beans = result.beans
        injections = result.injections
        endpoints = result.endpoints
        isIndexing = false
    }

    /// Starts a workspace index without making the caller wait for it. Opening a
    /// project must not block build-system and run state behind Spring indexing,
    /// which scales with the number of Java sources in the workspace.
    func scheduleLoad(
        workspaceURL: URL,
        files: [URL],
        textOverrides: [URL: String] = [:],
        refreshDependencyMetadata: Bool = true
    ) {
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            // Cancellation is cooperative, so a schedule that was superseded
            // before it started must return here instead of running a second
            // full workspace index whose result the generation token discards.
            guard !Task.isCancelled, let self else { return }
            await self.load(
                workspaceURL: workspaceURL,
                files: files,
                textOverrides: textOverrides,
                refreshDependencyMetadata: refreshDependencyMetadata
            )
        }
    }

    func reset() {
        reloadTask?.cancel()
        reloadTask = nil
        generation = UUID()
        properties = []
        values = []
        propertyReferences = []
        diagnostics = []
        beans = []
        injections = []
        endpoints = []
        isIndexing = false
    }

    func scheduleReload(
        changedDocument: EditorDocument,
        workspaceURL: URL,
        files: [URL],
        openDocuments: [EditorDocument]
    ) {
        let name = changedDocument.url.lastPathComponent
        guard handles(changedDocument.url)
            || changedDocument.url.pathExtension.lowercased() == "java"
            || name == "spring-configuration-metadata.json"
            || name == "additional-spring-configuration-metadata.json" else { return }
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            let overrides = Dictionary(uniqueKeysWithValues: openDocuments.map {
                ($0.url.standardizedFileURL, $0.text)
            })
            await self.load(
                workspaceURL: workspaceURL,
                files: files,
                textOverrides: overrides,
                refreshDependencyMetadata: false
            )
        }
    }

    func handles(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name == "application.properties"
            || (name.hasPrefix("application-") && name.hasSuffix(".properties"))
            || ((name == "application.yml" || name == "application.yaml")
                || (name.hasPrefix("application-") && ["yml", "yaml"].contains(url.pathExtension.lowercased())))
    }

    func completions(
        document: EditorDocument,
        line: Int,
        utf16Column: Int
    ) -> [LanguageServerCompletionItem] {
        guard handles(document.url),
              let context = completionContext(
                text: document.text,
                extensionName: document.url.pathExtension.lowercased(),
                line: line,
                utf16Column: utf16Column
              ) else { return [] }
        return properties.compactMap { property in
            guard property.name.hasPrefix(context.parentPrefix) else { return nil }
            let insertText = String(property.name.dropFirst(context.parentPrefix.count))
            guard insertText.localizedCaseInsensitiveContains(context.typedPrefix) else { return nil }
            let detail = [property.typeName, property.defaultValue.map { "default: \($0)" }]
                .compactMap { $0 }.joined(separator: " · ")
            return LanguageServerCompletionItem(
                label: property.name,
                detail: detail.isEmpty ? "Spring Boot property" : detail,
                documentation: property.documentation,
                insertText: insertText,
                sortText: property.name,
                filterText: property.name,
                kind: 10,
                textEdit: LanguageServerTextEdit(
                    range: LanguageServerRange(
                        start: LanguageServerPosition(line: line, utf16Column: context.replacementStart),
                        end: LanguageServerPosition(line: line, utf16Column: utf16Column)
                    ),
                    newText: insertText
                ),
                additionalTextEdits: [],
                data: nil
            )
        }
    }

    func hover(for url: URL, line: Int) -> LanguageServerHover? {
        guard let value = values.first(where: {
            $0.url.standardizedFileURL == url.standardizedFileURL && $0.line == line + 1
        }), let property = properties.first(where: { $0.name == value.key }) else { return nil }
        var parts = ["`\(property.name)`"]
        if let typeName = property.typeName { parts.append("Type: `\(typeName)`") }
        if let defaultValue = property.defaultValue { parts.append("Default: `\(defaultValue)`") }
        if let documentation = property.documentation { parts.append(documentation) }
        if let profile = value.profile { parts.append("Profile: `\(profile)`") }
        if value.overridesBaseValue { parts.append("Overrides the base application value.") }
        return LanguageServerHover(contents: parts.joined(separator: "\n\n"), isMarkdown: true, range: nil)
    }

    func navigationLocations(for url: URL, line: Int) -> [LanguageServerLocation] {
        if let value = values.first(where: {
            $0.url.standardizedFileURL == url.standardizedFileURL && $0.line == line + 1
        }) {
            var locations: [LanguageServerLocation] = []
            if let targetURL = value.targetURL {
                locations.append(location(
                    targetURL,
                    line: value.targetLine,
                    column: value.targetColumn
                ))
            }
            locations.append(contentsOf: propertyReferences.filter { $0.key == value.key }.map {
                location($0.url, line: $0.line, column: $0.column)
            })
            if !locations.isEmpty { return unique(locations) }
        }
        if let reference = propertyReferences.first(where: {
            $0.url.standardizedFileURL == url.standardizedFileURL && $0.line == line + 1
        }) {
            return unique(values.filter { $0.key == reference.key }.map {
                location($0.url, line: $0.line, column: $0.column)
            })
        }
        if let injection = injections.first(where: {
            $0.url.standardizedFileURL == url.standardizedFileURL && abs($0.line - (line + 1)) <= 1
        }) {
            return injection.beanIDs.compactMap { id in
                beans.first(where: { $0.id == id }).map {
                    location($0.url, line: $0.line, column: $0.column)
                }
            }
        }
        let matchingProperties = properties.filter {
            $0.sourceURL?.standardizedFileURL == url.standardizedFileURL
                && $0.sourceLine.map { abs($0 - (line + 1)) <= 1 } == true
        }
        return matchingProperties.flatMap { property in
            values.filter { $0.key == property.name }.map {
                location($0.url, line: $0.line, column: $0.column)
            }
        }
    }

    var languageDiagnostics: [URL: [LanguageServerDiagnostic]] {
        Dictionary(grouping: diagnostics, by: { $0.url.standardizedFileURL }).mapValues { values in
            values.map { value in
                LanguageServerDiagnostic(
                    range: LanguageServerRange(
                        start: LanguageServerPosition(line: max(0, value.line - 1), utf16Column: max(0, value.column - 1)),
                        end: LanguageServerPosition(line: max(0, value.line - 1), utf16Column: max(0, value.column))
                    ),
                    severity: value.severity == "error" ? 1 : 2,
                    message: value.message,
                    source: "Spring",
                    code: "spring.configuration"
                )
            }
        }
    }

    private func location(_ url: URL, line: Int?, column: Int?) -> LanguageServerLocation {
        let position = LanguageServerPosition(
            line: max(0, (line ?? 1) - 1),
            utf16Column: max(0, (column ?? 1) - 1)
        )
        return LanguageServerLocation(
            url: url,
            range: LanguageServerRange(start: position, end: position)
        )
    }

    private func unique(_ locations: [LanguageServerLocation]) -> [LanguageServerLocation] {
        var seen = Set<String>()
        return locations.filter { location in
            let key = "\(location.url.standardizedFileURL.path):\(location.range.start.line):\(location.range.start.utf16Column)"
            return seen.insert(key).inserted
        }
    }

    private func completionContext(
        text: String,
        extensionName: String,
        line: Int,
        utf16Column: Int
    ) -> (parentPrefix: String, typedPrefix: String, replacementStart: Int)? {
        let lines = text.components(separatedBy: .newlines)
        guard lines.indices.contains(line) else { return nil }
        let current = lines[line] as NSString
        let column = min(max(0, utf16Column), current.length)
        var start = column
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        while start > 0,
              let scalar = UnicodeScalar(current.character(at: start - 1)),
              allowed.contains(scalar) {
            start -= 1
        }
        let typed = current.substring(with: NSRange(location: start, length: column - start))
        guard extensionName != "properties" else { return ("", typed, start) }
        let indent = lines[line].prefix { $0 == " " || $0 == "\t" }.count
        var stack: [(indent: Int, key: String)] = []
        for previous in lines.prefix(line) {
            let trimmed = previous.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), trimmed.hasSuffix(":") else { continue }
            let previousIndent = previous.prefix { $0 == " " || $0 == "\t" }.count
            while stack.last.map({ $0.indent >= previousIndent }) == true { stack.removeLast() }
            stack.append((previousIndent, String(trimmed.dropLast()).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))))
        }
        while stack.last.map({ $0.indent >= indent }) == true { stack.removeLast() }
        let parent = stack.map(\.key).joined(separator: ".")
        return (parent.isEmpty ? "" : parent + ".", typed, start)
    }
}
