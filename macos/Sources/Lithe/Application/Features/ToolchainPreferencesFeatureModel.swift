import Combine
import Foundation
import LitheCoreContracts

/// Edits remain workspace-owned drafts until an explicit Save. A draft keeps
/// its original native revision across reloads so external changes cannot
/// silently rebase a later write onto a newer document.
@MainActor
final class ToolchainPreferencesFeatureModel: ObservableObject {
    enum Mode: String, CaseIterable, Sendable { case inherited, workspace, consumer, installation, executable }
    struct Draft: Equatable {
        let snapshot: ToolchainPreferencesSnapshot
        var mode: Mode
        var path: String
        var originalMode: Mode
        var originalPath: String

        var isChanged: Bool { mode != originalMode || path != originalPath }
        var value: ToolingJSONValue? {
            switch mode {
            case .inherited: nil
            case .workspace: .object(["inherit": .string("workspace")])
            case .consumer: .object(["inherit": .string("consumer")])
            case .installation: .object(["home": .string(path)])
            case .executable: .object(["executable": .string(path)])
            }
        }
    }

    @Published private(set) var workspace: URL?
    @Published private(set) var address: ToolchainPreferenceAddress?
    @Published private(set) var draft: Draft?
    @Published private(set) var reading: ToolchainPreferenceReading?
    @Published private(set) var error: (any Error)?
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    private let store: (any ToolchainPreferencesStoring)?
    private var drafts: [ToolchainPreferenceAddress: Draft] = [:]
    private var generation = UUID()
    private var savingTask: Task<ToolchainPreferencesSnapshot, Error>?
    private var writeID: UUID?

    init(store: (any ToolchainPreferencesStoring)?) { self.store = store }
    var isAvailable: Bool { store != nil }

    func open(workspace: URL, address: ToolchainPreferenceAddress) async {
        let generation = UUID(); self.generation = generation
        if let savingTask { _ = await savingTask.result }
        guard self.generation == generation, !Task.isCancelled, let store else { return }
        if self.workspace != workspace { drafts.removeAll(); draft = nil }
        self.workspace = workspace; self.address = address
        isLoading = true; error = nil
        draft = drafts[address]; reading = nil
        defer { if self.generation == generation { isLoading = false } }
        do {
            guard drafts[address] != nil || drafts.count < 64 else { throw ToolchainPreferenceError.invalid }
            let latest = try await store.load(workspace: workspace)
            try Task.checkCancellation()
            guard self.generation == generation else { return }
            let existing = drafts[address]
            let baseline = existing?.snapshot ?? latest
            reading = try store.inspect(address, snapshot: baseline)
            guard let reading else { throw ToolchainPreferenceError.invalid }
            draft = try existing ?? Self.draft(reading: reading, snapshot: baseline)
            if let existing, existing.snapshot.revision != latest.revision { error = ToolchainPreferenceError.conflict }
        } catch is CancellationError { }
        catch { if self.generation == generation { self.error = error } }
    }

    func edit(mode: Mode? = nil, path: String? = nil) {
        guard !isLoading, !isSaving, var draft, let address else { return }
        if let mode { draft.mode = mode }
        if let path { draft.path = path }
        self.draft = draft
        if draft.isChanged { drafts[address] = draft } else { drafts.removeValue(forKey: address) }
    }

    func cancel() async {
        guard !isSaving, let workspace, let address else { return }
        drafts.removeValue(forKey: address); draft = nil
        await open(workspace: workspace, address: address)
    }

    func save(reset: Bool = false) async {
        guard let store, let address, let draft, !isSaving, !isLoading, reset || draft.isChanged else { return }
        let generation = self.generation
        let writeID = UUID(); self.writeID = writeID
        isSaving = true; error = nil
        let task = Task { try await store.save(reset ? nil : draft.value, at: address, expecting: draft.snapshot) }
        savingTask = task
        defer { if self.writeID == writeID { self.writeID = nil; savingTask = nil; isSaving = false } }
        do {
            let saved = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard self.generation == generation else { return }
            let reading = try store.inspect(address, snapshot: saved)
            self.reading = reading
            self.draft = try Self.draft(reading: reading, snapshot: saved)
            drafts.removeValue(forKey: address)
        } catch { if self.generation == generation { self.error = error } }
    }

    /// Hiding retains drafts. Closing a workspace revokes every in-flight read
    /// and drops that workspace's inputs, never another workspace's editor.
    func hide(_ address: ToolchainPreferenceAddress) {
        guard self.address == address else { return }
        savingTask?.cancel(); generation = UUID()
        self.address = nil; draft = nil; reading = nil; error = nil; isLoading = false
    }

    func close() {
        savingTask?.cancel()
        generation = UUID(); workspace = nil; address = nil; draft = nil; reading = nil
        drafts.removeAll(); error = nil; isLoading = false
    }

    /// Workspace shutdown waits for the native write owner to acknowledge
    /// cancellation before allowing its platform resources to be released.
    func drain() async {
        if let savingTask { _ = await savingTask.result }
    }

    private static func draft(reading: ToolchainPreferenceReading, snapshot: ToolchainPreferencesSnapshot) throws -> Draft {
        var mode: Mode = .inherited, path = ""
        if case .object(let stored) = reading.stored {
            if case .string(let value) = stored["home"] { mode = .installation; path = value }
            else if case .string(let value) = stored["executable"] { mode = .executable; path = value }
            else if stored["inherit"] == .string("workspace") { mode = .workspace }
            else if stored["inherit"] == .string("consumer") { mode = .consumer }
            else { throw ToolchainPreferenceError.invalid }
        } else if reading.stored != nil { throw ToolchainPreferenceError.invalid }
        return Draft(snapshot: snapshot, mode: mode, path: path, originalMode: mode, originalPath: path)
    }
}
