import Combine
import Foundation

/// Coordinates portable patch exchange through native file ports and Core's forward preflight.
@MainActor
package final class GitPatchFeatureModel: ObservableObject {
    package enum Surface { case changes, log }
    package enum Mode { case export, apply }

    @Published package private(set) var mode: Mode?
    @Published package private(set) var surface = Surface.changes
    @Published package private(set) var source = GitPatchSource.workingTree
    @Published package private(set) var target = GitPatchTarget.worktree
    @Published package private(set) var baseRevision = ""
    @Published package private(set) var targetRevision = ""
    @Published package private(set) var files: [GitPatchFile] = []
    @Published package private(set) var selectedPaths: Set<String> = []
    @Published package private(set) var exportPreview: GitPatchExport?
    @Published package private(set) var applyPreview: GitPatchPreview?
    @Published package private(set) var importedPatch = ""
    @Published package private(set) var importedName = ""
    @Published package private(set) var isWorking = false
    @Published package private(set) var isApplying = false
    @Published package private(set) var errorMessage: String?
    @Published package private(set) var notice: String?
    package var fileAccess: (any GitPatchFileAccess)?

    private let service: GitService
    private let apply: @MainActor (URL, String, GitPatchTarget, String) async -> GitService.CommandResult?
    private var root: URL?
    private var discoveredFiles = false
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?

    package init(service: GitService, apply: @escaping @MainActor (URL, String, GitPatchTarget, String) async -> GitService.CommandResult?) {
        self.service = service
        self.apply = apply
    }

    package var isBusy: Bool { isWorking || isApplying }
    package var canGenerateExport: Bool {
        !isBusy && (!discoveredFiles || !selectedPaths.isEmpty)
            && (source != .commits || (!baseRevision.isEmpty && !targetRevision.isEmpty))
    }
    package var canSave: Bool { !isBusy && exportPreview?.patch.isEmpty == false }
    package var canApply: Bool { !isBusy && applyPreview?.applicable == true && applyPreview?.expectedState != nil }
    package var patchText: String { mode == .export ? exportPreview?.patch ?? "" : importedPatch }

    package func beginExport(at root: URL) {
        guard !isBusy else { return }
        reset()
        self.root = root
        mode = .export
        surface = .changes
        setSource(.workingTree)
    }

    package func beginCommitExport(at root: URL, base: String, target: String) {
        guard !isBusy else { return }
        reset()
        self.root = root
        mode = .export
        surface = .log
        source = .commits
        baseRevision = base
        targetRevision = target
        generateExport(metadataOnly: true)
    }

    package func beginImport(at root: URL, surface: Surface) {
        guard !isBusy else { return }
        reset()
        self.root = root
        self.surface = surface
        mode = .apply
    }

    package func setSource(_ source: GitPatchSource) {
        guard !isBusy else { return }
        self.source = source
        refreshFiles()
    }

    /// Core discovers each source directly; the Changes sidebar can omit index-only states such as AD.
    package func refreshFiles() {
        guard !isBusy else { return }
        discoveredFiles = false
        files = []
        selectedPaths = []
        exportPreview = nil
        generateExport(metadataOnly: true)
    }

    package func selectPath(_ path: String, included: Bool) {
        guard !isBusy else { return }
        if included { selectedPaths.insert(path) } else { selectedPaths.remove(path) }
        exportPreview = nil
    }

    package func selectAllPaths(_ included: Bool) {
        guard !isBusy else { return }
        selectedPaths = included ? Set(files.map(\.path)) : []
        exportPreview = nil
    }

    package func swapRevisions() {
        guard !isBusy else { return }
        let previousBase = baseRevision
        baseRevision = targetRevision
        targetRevision = previousBase
        discoveredFiles = false
        files = []
        selectedPaths = []
        exportPreview = nil
        generateExport(metadataOnly: true)
    }

    package func generateExport(metadataOnly: Bool = false) {
        guard canGenerateExport, let root else { return }
        let requestGeneration = nextRequest()
        let source = source
        // A rename must include both pathspecs or Git may export only one side of the change.
        let paths = Set(files.filter { selectedPaths.contains($0.path) }.flatMap { file in
            [file.path, file.originalPath].compactMap { $0 }
        }).sorted()
        let base = source == .commits ? baseRevision : nil
        let target = source == .commits ? targetRevision : nil
        task = Task { [weak self, service] in
            let result = await service.exportPatch(at: root, source: source, paths: paths, base: base, target: target, metadataOnly: metadataOnly)
            guard let self, self.generation == requestGeneration, !Task.isCancelled else { return }
            self.isWorking = false
            self.task = nil
            switch result {
            case .success(let exported):
                self.exportPreview = metadataOnly ? nil : exported
                if !self.discoveredFiles {
                    self.files = exported.files
                    self.selectedPaths = Set(exported.files.map(\.path))
                    self.discoveredFiles = true
                }
                if exported.files.isEmpty { self.notice = "No differences were found for this selection." }
            case .failure(let error): self.errorMessage = error.message
            }
        }
    }

    package func saveExport() {
        guard canSave, let exported = exportPreview, let fileAccess,
              let destination = fileAccess.choosePatchDestination() else { return }
        let requestGeneration = nextRequest()
        task = Task { [weak self] in
            do {
                try await fileAccess.writePatch(exported.patch, at: destination)
                guard let self, self.generation == requestGeneration, !Task.isCancelled else { return }
                self.notice = "Saved \(destination.lastPathComponent)."
            } catch {
                guard let self, self.generation == requestGeneration, !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
            }
            self?.isWorking = false
            self?.task = nil
        }
    }

    package func chooseImportFile() {
        guard !isBusy, let fileAccess, let url = fileAccess.choosePatchFile() else { return }
        loadImportFile(url)
    }

    package func loadImportFile(_ url: URL) {
        guard !isBusy, let fileAccess else { return }
        applyPreview = nil
        let requestGeneration = nextRequest()
        task = Task { [weak self] in
            do {
                let patch = try await fileAccess.readPatch(at: url)
                guard let self, self.generation == requestGeneration, !Task.isCancelled else { return }
                self.importedPatch = patch
                self.importedName = url.lastPathComponent
                self.applyPreview = nil
                self.files = []
                self.isWorking = false
                self.task = nil
                self.inspectImport()
            } catch {
                guard let self, self.generation == requestGeneration, !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
                self.isWorking = false
                self.task = nil
            }
        }
    }

    package func pasteImport() {
        guard !isBusy, let text = fileAccess?.clipboardPatch() else { return }
        applyPreview = nil
        guard text.utf8.count <= GitPatchContent.maximumByteCount else {
            errorMessage = "Patches must be at most 32 MiB."
            return
        }
        importedPatch = text
        importedName = "Clipboard patch"
        files = []
        inspectImport()
    }

    package func setTarget(_ target: GitPatchTarget) {
        guard !isBusy else { return }
        self.target = target
        applyPreview = nil
        if !importedPatch.isEmpty { inspectImport() }
    }

    package func inspectImport() {
        guard !isBusy, !importedPatch.isEmpty, let root else { return }
        let requestGeneration = nextRequest()
        let patch = importedPatch
        let target = target
        applyPreview = nil
        task = Task { [weak self, service] in
            let result = await service.previewPatch(at: root, patch: patch, target: target)
            guard let self, self.generation == requestGeneration, !Task.isCancelled else { return }
            self.isWorking = false
            self.task = nil
            switch result {
            case .success(let preview):
                self.applyPreview = preview
                self.files = preview.files
            case .failure(let error): self.errorMessage = error.message
            }
        }
    }

    package func confirmApply() async {
        guard canApply, let root, let expectedState = applyPreview?.expectedState else { return }
        let requestGeneration = generation
        isApplying = true
        errorMessage = nil
        let result = await apply(root, importedPatch, target, expectedState)
        guard generation == requestGeneration else { return }
        isApplying = false
        applyPreview = nil
        guard let result else {
            errorMessage = "The repository changed or another Git operation is running. Preview the patch again."
            return
        }
        if result.succeeded {
            notice = "Patch applied. " + result.warnings.map(\.message).joined(separator: "\n")
        } else {
            errorMessage = result.output
        }
    }

    package func dismiss() {
        guard !isBusy else { return }
        reset()
    }

    package func reset() {
        generation &+= 1
        task?.cancel()
        task = nil
        mode = nil
        root = nil
        source = .workingTree
        target = .worktree
        baseRevision = ""
        targetRevision = ""
        files = []
        selectedPaths = []
        exportPreview = nil
        applyPreview = nil
        importedPatch = ""
        importedName = ""
        discoveredFiles = false
        isWorking = false
        isApplying = false
        errorMessage = nil
        notice = nil
    }

    private func nextRequest() -> UInt64 {
        generation &+= 1
        task?.cancel()
        isWorking = true
        errorMessage = nil
        notice = nil
        return generation
    }
}
