import Foundation
import LitheCoreContracts
import LitheExecutionModule
import LitheLanguageIntelligenceModule

/// Resolved Java test target passed into the asynchronous debug preparation.
struct JavaTestDebugRequest {
    /// Source file containing the selected test.
    let fileURL: URL
    /// Optional semantic test identifier; `nil` means debug the whole file.
    let testIdentifier: String?
}

/// Owns cancellable state shared by Java test discovery and debug workflows.
@MainActor
final class JavaTestWorkflowState {
    private let notify: @MainActor (String) -> Void

    init(notify: @escaping @MainActor (String) -> Void) {
        self.notify = notify
    }

    enum DebugRequestResolution {
        case resolved(JavaTestDebugRequest)
        case rejected(String)
    }

    func resolveDebugRequest(
        providerID: String,
        scope: LanguageTestScope
    ) -> DebugRequestResolution {
        guard providerID == "java" else {
            return .rejected("Java test debugging is currently available for Java projects only")
        }
        switch scope {
        case .workspace:
            return .rejected("Select a Java test file or test case to debug")
        case .file(let url):
            return .resolved(
                JavaTestDebugRequest(
                    fileURL: url.standardizedFileURL,
                    testIdentifier: nil
                )
            )
        case .testCase(let identifier, let url):
            guard let url else {
                return .rejected("The selected Java test has no source file")
            }
            return .resolved(
                JavaTestDebugRequest(
                    fileURL: url.standardizedFileURL,
                    testIdentifier: identifier
                )
            )
        }
    }

    func projectDiscoveredItems(
        _ baseItems: [LanguageTestItem],
        workspaceURL: URL,
        sessions: LanguageToolingSessionManager,
        isCurrent: @MainActor (UUID) -> Bool,
        operationID: UUID
    ) async throws -> [LanguageTestItem] {
        let javaFiles = baseItems.filter { $0.kind == .file && $0.fileURL != nil }
        guard !javaFiles.isEmpty else { return baseItems }
        var projected = baseItems.filter { $0.kind == .workspace }
        var completedFileCount = 0
        for fileItem in javaFiles {
            try Task.checkCancellation()
            guard isCurrent(operationID), let fileURL = fileItem.fileURL else {
                throw CancellationError()
            }
            do {
                let details = try await sessions.discoverJavaTestItems(
                    fileURL: fileURL,
                    rootURL: workspaceURL
                )
                completedFileCount += 1
                if !details.isEmpty {
                    projected.append(fileItem)
                    projected.append(contentsOf: details)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                projected.append(fileItem)
            }
        }
        guard isCurrent(operationID) else { throw CancellationError() }
        if projected.allSatisfy({ $0.kind == .workspace }), completedFileCount > 0 {
            return []
        }
        return projected
    }

    /// Saves the test's source file when the editor holds unsaved changes, so
    /// the debug launch compiles what the user sees. Returns `false` only when
    /// the save failed, which must abort the launch.
    func prepareDirtyDocument(
        fileURL: URL,
        documents: [EditorDocument],
        saving: any EditorDocumentSaving
    ) -> Bool {
        guard let document = documents.first(where: {
            $0.url.standardizedFileURL == fileURL.standardizedFileURL
        }), document.isDirty else {
            return true
        }
        do {
            let previousText = document.savedText
            try saving.save(document)
            saving.recordSave(document, previousText: previousText)
            return true
        } catch {
            notify("Could not save \(document.url.lastPathComponent)")
            return false
        }
    }

    var resultServer: (any JavaTestResultServing)?
    var debugLaunchTask: Task<Void, Never>?
    var debugLaunchOperationID: UUID?
    var discoveryTask: Task<Void, Never>?
    var discoveryOperationID: UUID?

    func beginDiscovery() -> UUID {
        cancelDiscovery()
        let operationID = UUID()
        discoveryOperationID = operationID
        return operationID
    }

    func beginDebugLaunch() -> UUID {
        cancelDebugLaunch()
        let operationID = UUID()
        debugLaunchOperationID = operationID
        return operationID
    }

    func stopResultServer() {
        resultServer?.stop()
        resultServer = nil
    }

    func cancelDebugLaunch() {
        debugLaunchOperationID = nil
        debugLaunchTask?.cancel()
        debugLaunchTask = nil
        stopResultServer()
    }

    func finishDebugLaunch(_ operationID: UUID, stopResultServer: Bool) {
        guard debugLaunchOperationID == operationID else { return }
        debugLaunchOperationID = nil
        debugLaunchTask = nil
        if stopResultServer {
            self.stopResultServer()
        }
    }

    func isCurrentDebugLaunch(_ operationID: UUID) -> Bool {
        debugLaunchOperationID == operationID && !Task.isCancelled
    }

    func cancelDiscovery() {
        discoveryOperationID = nil
        discoveryTask?.cancel()
        discoveryTask = nil
    }

    func isCurrentDiscovery(_ operationID: UUID) -> Bool {
        discoveryOperationID == operationID && !Task.isCancelled
    }

    func finishDiscovery(_ operationID: UUID) {
        guard discoveryOperationID == operationID else { return }
        discoveryOperationID = nil
        discoveryTask = nil
    }
}
