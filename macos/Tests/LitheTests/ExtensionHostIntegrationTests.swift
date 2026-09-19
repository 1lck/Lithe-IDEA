import Foundation
import LitheCoreContracts
import LitheLanguageIntelligenceModule
@testable import Lithe
import Testing

/// Explicit integration lane: the caller supplies Node and a built host directory.
@MainActor
struct ExtensionHostIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHE_EXTENSION_HOST_NODE"] != nil))
    func nativeSupervisorRunsUnmodifiedProbeAndCleansProcessGroup() async throws {
        let environment = ProcessInfo.processInfo.environment
        let node = URL(fileURLWithPath: try #require(environment["LITHE_EXTENSION_HOST_NODE"]))
        let host = URL(fileURLWithPath: try #require(environment["LITHE_EXTENSION_HOST_ROOT"]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record(error) }
        }
        let transport = MacExtensionHostTransport()
        let session = ExtensionHostSession(transport: transport)
        let connection = session.connection
        let manager = LanguageToolingSessionManager()
        manager.attachExtensionHostSession(session)
        defer { manager.detachExtensionHostSession(session) }
        let registered = TestGate()
        let registerProvider = session.onLanguageProviderRegistered
        session.onLanguageProviderRegistered = { kind, handle, languages in
            registerProvider?(kind, handle, languages)
            if kind == "completion" { registered.open() }
        }
        let diagnosticReceived = TestGate()
        let updateDiagnostics = session.onDiagnosticsChanged
        session.onDiagnosticsChanged = { id, delta in
            updateDiagnostics?(id, delta)
            diagnosticReceived.open()
        }
        var diagnostics = ""
        session.onDiagnostic = { diagnostics += $0 }
        let file = root.appendingPathComponent("Main.java")
        let document = EditorDocument(url: file, text: "class Main {}\n", modificationDate: nil)
        let documents = ExtensionHostDocumentBridge(connection: connection,
            find: { $0 == file ? document : nil }, open: { $0 == file ? document : nil },
            save: { try $0.save() }, changed: { _ in }, languageID: { _ in "java" })
        defer { documents.stop() }
        connection.onRequest = { method, params in
            if let result = try await documents.handle(method, params: params) { return result }
            guard method == "lithe/executeCommand" else {
                throw ExtensionHostFailure("methodNotFound", method)
            }
            return params
        }
        do {
            let initialized = try await session.start(ExtensionHostLaunchConfiguration(
                node: node, entrypoint: host.appendingPathComponent("dist/main.js"),
                workspace: root, environment: environment
            ), initialize: .object([
                "protocolVersion": .integer(1),
                "workspaceFolders": .array([.object(["uri": .string(root.absoluteString), "name": .string("probe")])]),
                "extensionPaths": .array([.string(host.appendingPathComponent("test/fixtures/extensions/lithe-probe").path)]),
                "storage": .object([
                    "globalStoragePath": .string(root.appendingPathComponent("global").path),
                    "workspaceStoragePath": .string(root.appendingPathComponent("workspace").path),
                    "logPath": .string(root.appendingPathComponent("logs").path)
                ]),
                "commands": .array([.string("lithe.echo")])
            ]))
            #expect(session.state == .ready)
            #expect(session.isModuleResourceActive)
            guard case .object(let result) = initialized else {
                throw ExtensionHostFailure("invalidParams", "Invalid initialize result")
            }
            #expect(result["failedExtensions"] == .array([]), "\(diagnostics)")
            _ = try await connection.request("host/activateByEvent", params: .object([
                "event": .string("onCommand:litheProbe.editAndSave")
            ]), timeout: .seconds(10))
            let echo = try await connection.request("host/executeCommand", params: .object([
                "command": .string("litheProbe.callLithe"),
                "arguments": .array([.string("lithe.echo"), .string("中文😀")])
            ]), timeout: .seconds(10))
            #expect(echo == .object(["command": .string("lithe.echo"), "arguments": .array([.string("中文😀")])]))
            let edited = try await connection.request("host/executeCommand", params: .object([
                "command": .string("litheProbe.editAndSave"),
                "arguments": .array([.object(["$uri": .string(file.absoluteString)])])
            ]), timeout: .seconds(10))
            guard case .object(let editResult) = edited else {
                throw ExtensionHostFailure("invalidParams", "Invalid edit command result")
            }
            #expect(editResult["applied"] == .bool(true))
            #expect(editResult["saved"] == .bool(true))
            #expect(editResult["isDirtyAfterSave"] == .bool(false))
            #expect(document.text == "// edited by extension\nclass Main {}\n")
            #expect(try String(contentsOf: file, encoding: .utf8) == document.text)
            #expect(!document.isDirty)
            #expect(await registered.waitUntilOpen(timeout: .seconds(5)), "No completion registration arrived")
            #expect(manager.features(for: file).contains(.completionResolve))
            let completionReceived = TestGate()
            var completionResult: Result<[LanguageServerCompletionItem], Error>?
            try manager.completions(fileURL: file, text: document.text,
                position: LanguageServerPosition(line: 1, utf16Column: 6), rootURL: root) {
                    completionResult = $0
                    completionReceived.open()
                }
            #expect(await completionReceived.waitUntilOpen(timeout: .seconds(5)), "Completion request did not finish")
            let items = try #require(completionResult).get()
            let probe = try #require(items.first { $0.label == "litheProbe" })
            #expect(probe.textEdit?.range.start.line == 1)
            #expect(probe.textEdit?.range.start.utf16Column == 6)
            let resolvedReceived = TestGate()
            var resolvedResult: Result<LanguageServerCompletionItem, Error>?
            try manager.resolveCompletion(probe, fileURL: file, text: document.text, rootURL: root) {
                resolvedResult = $0
                resolvedReceived.open()
            }
            #expect(await resolvedReceived.waitUntilOpen(timeout: .seconds(5)), "Completion resolution did not finish")
            let resolved = try #require(resolvedResult).get()
            #expect(resolved.detail == "resolved by extension")
            #expect(resolved.additionalTextEdits.first?.newText == "// import from resolve\n")
            #expect(resolved.additionalTextEdits.first?.range.start.line == 0)

            _ = try await connection.request("host/executeCommand", params: .object([
                "command": .string("litheProbe.diagnostics"),
                "arguments": .array([.object(["$uri": .string(file.absoluteString)])])
            ]), timeout: .seconds(5))
            #expect(await diagnosticReceived.waitUntilOpen(timeout: .seconds(5)), "No diagnostic notification arrived")
            #expect(manager.diagnostics[file]?.first?.message == "probe diagnostic")
            #expect(manager.diagnostics[file]?.first?.severity == 1)
            await session.stopModuleResource()
            #expect(manager.diagnostics[file] == nil)
            #expect(session.state == .stopped)
            #expect(!session.isModuleResourceActive)
        } catch {
            connection.close()
            let stopped = await session.stop()
            #expect(stopped, "Host process group survived failure cleanup")
            throw error
        }
        connection.close()
        let stopped = await session.stop()
        #expect(stopped, "Host process group survived shutdown")
    }
}
