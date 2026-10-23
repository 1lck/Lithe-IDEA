import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@MainActor
struct AgentInstructionsCancellationTests {
    @Test func cancelledBeforeServiceEntryDoesNotSaveSharedInstructions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { remove(root) }
        let path = root.appendingPathComponent("Shared.md")
        try Data("original shared instructions".utf8).write(to: path)
        let service = RustAgentInstructionsService(core: RustCoreBridge(), sharedDirectory: root)
        let library = try await service.readShared()
        // No Agent targets: a non-cancelled request would write only our real
        // isolated source file, never the developer's native instruction files.
        let sourceOnly = SharedInstructionLibrary(file: library.file, agents: [])
        let task = Task { try await service.saveShared(content: "cancelled edit", library: sourceOnly) }
        task.cancel() // MainActor does not yield until cancellation is recorded.
        do {
            _ = try await task.value
            Issue.record("A cancelled save must not publish a result")
        } catch { #expect(error is CancellationError) }
        #expect(try String(contentsOf: path, encoding: .utf8) == library.file.content)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["Shared.md"])
    }

    @Test func cancellationDuringEncodingIsReplayedBeforeCoreDispatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { remove(root) }
        let service = RustAgentInstructionsService(core: RustCoreBridge(), sharedDirectory: root)
        let library = try await service.readShared()
        let core = RustCoreBridge()
        let operationID = UUID().uuidString
        let cancellation = RustCoreCancellation(core: core, operationID: operationID)
        // Encoding runs after the worker's entry check but before Core registers
        // the operation. The real registration callback must replay this cancel.
        let payload = CancelDuringEncoding(value: SharedSave(dataDirectory: root.path,
            content: "must not be written", expectedRevision: library.file.revision), cancellation: cancellation)
        let result: Result<SharedInstructionLibrary, RustCoreBridge.CoreCallError> = core.executeResult(
            command: "agent.instructions.shared", payload: payload, operationID: operationID,
            onEvent: { cancellation.receive($0) })
        switch result {
        case .success: Issue.record("Cancellation before registration must prevent dispatch")
        case .failure(let error): #expect(error.code == "cancelled")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        #expect(!core.cancel(operationID: operationID)) // Registration was released.

        // Prove the same valid snapshot can save, and an old cancellation does
        // not poison the next unique operation or any native Agent files.
        _ = try await service.saveShared(content: "allowed edit", library: SharedInstructionLibrary(file: library.file, agents: []))
        #expect(try String(contentsOf: root.appendingPathComponent("Shared.md"), encoding: .utf8) == "allowed edit")
    }

    private func remove(_ root: URL) {
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Instruction fixture cleanup failed: \(error)") }
    }
}

private struct SharedSave: Encodable {
    let dataDirectory: String
    let action = "save"
    let content: String
    let expectedRevision: String
    let files: [String] = []
}

private struct CancelDuringEncoding: Encodable {
    let value: SharedSave
    let cancellation: RustCoreCancellation
    func encode(to encoder: any Encoder) throws {
        try value.encode(to: encoder)
        cancellation.cancel()
    }
}
