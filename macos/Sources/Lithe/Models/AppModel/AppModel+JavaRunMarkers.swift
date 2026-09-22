import Foundation
import LitheCoreContracts
import LitheLanguageIntelligenceModule

/// IDEA-style Run markers in the Java editor gutter: JDT decides which `main`
/// methods and tests exist, Core projects them with recorded test outcomes,
/// and these entry points launch them through the existing Run, Test, and
/// Debug workflows.
///
/// Note: 设计见 .agents/notes/implemented/architecture/2026-09-22-editor-run-markers-and-test-outcomes.md
@MainActor
extension AppModel {
    enum JavaRunMarkerAction: String {
        case run
        case debug
        case editConfiguration
    }

    func javaRunMarkers(for document: EditorDocument) async -> [JavaRunMarker] {
        guard document.url.pathExtension.lowercased() == "java",
              !languageToolingFeature.isDisabled("java"),
              let sessions = languageToolingSessionsIfActive,
              let workspaceURL else { return [] }
        do {
            try sessions.synchronizeLanguageServer(
                for: document.url,
                text: document.text,
                rootURL: workspaceURL
            )
        } catch {
            recordJavaRunMarkerFailure(error, sessions: sessions)
            return []
        }
        let fileURL = document.url
        let methods = await javaRunMarkerSource(sessions: sessions) { completion in
            try sessions.javaMainMethods(fileURL: fileURL) { completion($0.map(\.methods)) }
        } ?? []
        let items = await javaRunMarkerSource(sessions: sessions) { completion in
            try sessions.javaTestItems(fileURL: fileURL) { completion($0.map(\.items)) }
        } ?? []
        return services.javaMavenOperations.javaRunMarkers(
            mainMethods: methods,
            testItems: items,
            testCases: languageTestServiceIfActive?.testOutcomes ?? []
        ) ?? []
    }

    /// Runs, debugs, or edits what a gutter marker points at.
    func performJavaRunMarker(_ marker: JavaRunMarker, action: JavaRunMarkerAction, in fileURL: URL) {
        switch marker.kind {
        case .main:
            guard let mainClass = marker.mainClass else { return }
            Task { [weak self] in
                await self?.performJavaMain(mainClass, action: action, in: fileURL)
            }
        case .testClass, .testMethod:
            guard action != .editConfiguration,
                  let identifier = marker.testIdentifier(forDebugging: action == .debug) else { return }
            let scope = LanguageTestScope.testCase(identifier: identifier, fileURL: fileURL)
            if action == .debug {
                debugTest(providerID: "java", scope: scope)
            } else {
                runTest(providerID: "java", scope: scope)
            }
        }
    }

    private func performJavaMain(_ mainClass: String, action: JavaRunMarkerAction, in fileURL: URL) async {
        guard let workspaceURL,
              let runFeature = await activateExecutionModule()?.runFeature else { return }
        let rootPath = workspaceURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return }
        let sourcePath = String(filePath.dropFirst(rootPath.count + 1))
        var configuration = Self.javaMainConfiguration(
            in: runFeature.configurations,
            selectedID: runFeature.selectedConfigurationID,
            sourcePath: sourcePath,
            mainClass: mainClass,
            source: runFeature.source(for:)
        )
        if configuration == nil {
            // The marker proves JDT can launch the class; the configuration
            // list may predate that answer, so it is regenerated once.
            await generateRunConfigurations()
            configuration = Self.javaMainConfiguration(
                in: runFeature.configurations,
                selectedID: runFeature.selectedConfigurationID,
                sourcePath: sourcePath,
                mainClass: mainClass,
                source: runFeature.source(for:)
            )
        }
        guard let configuration else {
            showNotification(
                "No run configuration exists for \(mainClass) yet. Wait for the Java project to finish importing, then try again."
            )
            return
        }
        runFeature.select(configuration)
        switch action {
        case .run:
            await performStartRunConfiguration(configuration)
        case .debug:
            await startDebuggingAfterActivation(configuration: configuration)
        case .editConfiguration:
            runFeature.editingConfigurationID = configuration.id
            showSettings(category: .run)
        }
    }

    /// The configuration that launches `mainClass` from `sourcePath`: a user
    /// edited copy wins over the generated entry, and the selection among equals.
    static func javaMainConfiguration(
        in configurations: [RunConfiguration],
        selectedID: String,
        sourcePath: String,
        mainClass: String,
        source: (RunConfiguration) -> RunConfigurationSource
    ) -> RunConfiguration? {
        let matches = configurations.filter {
            !$0.disabled && $0.mainClass == mainClass && $0.sourcePath == sourcePath
        }
        return matches.min { left, right in
            let leftRank = (left.id == selectedID ? 0 : 2) + (source(left) == .generated ? 1 : 0)
            let rightRank = (right.id == selectedID ? 0 : 2) + (source(right) == .generated ? 1 : 0)
            return leftRank < rightRank
        }
    }

    private func javaRunMarkerSource<Value>(
        sessions: LanguageToolingSessionManager,
        _ request: (@escaping (Result<Value, Error>) -> Void) throws -> Void
    ) async -> Value? {
        await withCheckedContinuation { continuation in
            do {
                try request { result in
                    switch result {
                    case .success(let value):
                        continuation.resume(returning: value)
                    case .failure(let error):
                        self.recordJavaRunMarkerFailure(error, sessions: sessions)
                        continuation.resume(returning: nil)
                    }
                }
            } catch {
                recordJavaRunMarkerFailure(error, sessions: sessions)
                continuation.resume(returning: nil)
            }
        }
    }

    private func recordJavaRunMarkerFailure(_ error: Error, sessions: LanguageToolingSessionManager) {
        sessions.recordLanguageServerLog(
            providerID: "java",
            level: .warning,
            message: "Java Run marker request failed",
            detail: error.localizedDescription
        )
    }
}
