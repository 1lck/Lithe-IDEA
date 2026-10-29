import Combine
import Foundation

/// Matching facts only: localization, plugin readiness and session state do not
/// change which files use a language, and must not invalidate this cache.
struct LSPProjectUsageRequest: Hashable, Sendable {
    enum Target: Hashable, Sendable {
        case provider(String)
        case plugin(String)

        fileprivate var sortKey: String {
            switch self {
            case .provider(let id): return "provider:" + id
            case .plugin(let id): return "plugin:" + id
            }
        }
    }

    struct Rule: Hashable, Sendable {
        let target: Target
        let fileExtensions: Set<String>
        let fileNames: Set<String>
        let fileNamePrefixes: Set<String>

        init(target: Target, fileExtensions: Set<String>, fileNames: Set<String> = [],
             fileNamePrefixes: Set<String> = []) {
            self.target = target
            self.fileExtensions = Set(fileExtensions.map { $0.lowercased() })
            self.fileNames = Set(fileNames.map { $0.lowercased() })
            self.fileNamePrefixes = Set(fileNamePrefixes.map { $0.lowercased() })
        }
    }

    let workspaceURL: URL?
    let snapshotID: UUID?
    let rules: [Rule]

    init(workspaceURL: URL?, snapshotID: UUID?, rules: [Rule]) {
        self.workspaceURL = workspaceURL
        self.snapshotID = snapshotID
        self.rules = rules.sorted { $0.target.sortKey < $1.target.sortKey }
    }
}

struct LSPProjectUsageSummary: Equatable, Sendable {
    var providerIDs: Set<String> = []
    var pluginIDs: Set<String> = []
}

/// Capture the identity and copy-on-write inventory from one applied snapshot.
/// Only the request participates in task identity; files are never hashed.
struct LSPProjectUsageInput: Sendable {
    let request: LSPProjectUsageRequest
    let files: [URL]
}

enum LSPProjectUsageScanner {
    /// The caller runs this on its owned worker. Inspect each URL at most once
    /// and retain only matched IDs, not an additional inventory of file names.
    static func scan(files: [URL], rules: [LSPProjectUsageRequest.Rule]) -> LSPProjectUsageSummary? {
        typealias Target = LSPProjectUsageRequest.Target
        var extensions: [String: Set<Target>] = [:]
        var names: [String: Set<Target>] = [:]
        var prefixes: [String: Set<Target>] = [:]
        for rule in rules {
            for value in rule.fileExtensions { extensions[value, default: []].insert(rule.target) }
            for value in rule.fileNames { names[value, default: []].insert(rule.target) }
            for value in rule.fileNamePrefixes { prefixes[value, default: []].insert(rule.target) }
        }
        let allTargets = Set(rules.map(\.target))
        var matched: Set<Target> = []
        for start in stride(from: 0, to: files.count, by: 256) {
            guard !Task.isCancelled else { return nil }
            if matched == allTargets { break }
            // Foundation's URL accessors can bridge through autoreleased NSURL
            // strings. Drain them within a batch, not at the end of 300k files.
            autoreleasepool {
                for index in start..<min(start + 256, files.count) {
                    let url = files[index]
                    if !extensions.isEmpty, let targets = extensions[url.pathExtension.lowercased()] {
                        matched.formUnion(targets)
                    }
                    if !names.isEmpty || !prefixes.isEmpty {
                        let name = url.lastPathComponent.lowercased()
                        if let targets = names[name] { matched.formUnion(targets) }
                        for (prefix, targets) in prefixes where name.hasPrefix(prefix) {
                            matched.formUnion(targets)
                        }
                    }
                }
            }
        }
        guard !Task.isCancelled else { return nil }
        var summary = LSPProjectUsageSummary()
        for target in matched {
            switch target {
            case .provider(let id): summary.providerIDs.insert(id)
            case .plugin(let id): summary.pluginIDs.insert(id)
            }
        }
        return summary
    }
}

/// One workspace-owned cache survives Settings window recreation. A page owns
/// a cancellable lease on the worker, rather than a detached unowned scan.
// Note: .agents/notes/implemented/bug-fix/2026-10-28-lsp-project-usage-cancellation.md
@MainActor
final class LSPProjectUsageModel: ObservableObject {
    enum State: Equatable { case idle, loading, ready }
    typealias Scanner = @Sendable ([URL], [LSPProjectUsageRequest.Rule]) async -> LSPProjectUsageSummary?

    @Published private(set) var state: State = .idle
    private let scanner: Scanner
    private var cached: (request: LSPProjectUsageRequest, summary: LSPProjectUsageSummary)?
    private var work: Work?
    private var retiring: [UUID: Task<Void, Never>] = [:]

    private final class Work {
        let id: UUID
        let request: LSPProjectUsageRequest
        let task: Task<Void, Never>
        var consumers: [UUID: (cancellation: Cancellation, continuation: CheckedContinuation<Void, Never>)] = [:]

        init(id: UUID, request: LSPProjectUsageRequest, task: Task<Void, Never>) {
            self.id = id
            self.request = request
            self.task = task
        }
    }

    /// The cancellation handler runs outside the main actor. Mark the lease
    /// synchronously so a queued completion cannot publish for cancelled pages.
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    init(scanner: @escaping Scanner = { files, rules in
        LSPProjectUsageScanner.scan(files: files, rules: rules)
    }) {
        self.scanner = scanner
    }

    func summary(for request: LSPProjectUsageRequest) -> LSPProjectUsageSummary? {
        cached?.request == request ? cached?.summary : nil
    }

    func load(_ request: LSPProjectUsageRequest, files: [URL]) async {
        let consumer = UUID()
        let cancellation = Cancellation()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !cancellation.isCancelled, !Task.isCancelled else { continuation.resume(); return }
                if summary(for: request) != nil {
                    retireWork()
                    // @Published emits even for equal values. Warm loads must
                    // not schedule another SwiftUI update.
                    if state != .ready { state = .ready }
                    continuation.resume()
                    return
                }
                if work?.request != request {
                    retireWork()
                    let id = UUID()
                    let scanner = self.scanner
                    let task = Task.detached(priority: .utility) { [weak self] in
                        let value = Task.isCancelled ? nil : await scanner(files, request.rules)
                        await self?.complete(id: id, value: value)
                    }
                    work = Work(id: id, request: request, task: task)
                }
                work?.consumers[consumer] = (cancellation, continuation)
                if state != .loading { state = .loading }
            }
        } onCancel: { [weak self] in
            cancellation.cancel()
            Task { @MainActor in self?.cancel(consumer: consumer) }
        }
    }

    func reset() {
        retireWork()
        retiring.values.forEach { $0.cancel() }
        cached = nil
        state = .idle
    }

    private func cancel(consumer: UUID) {
        guard let work, let lease = work.consumers.removeValue(forKey: consumer) else { return }
        lease.continuation.resume()
        if work.consumers.isEmpty {
            retireWork()
            state = cached == nil ? .idle : .ready
        }
    }

    private func complete(id: UUID, value: LSPProjectUsageSummary?) {
        retiring[id] = nil
        guard let active = work, active.id == id else { return }
        work = nil
        if let value, active.consumers.values.contains(where: { !$0.cancellation.isCancelled }) {
            cached = (active.request, value)
        }
        state = cached == nil ? .idle : .ready
        active.consumers.values.forEach { $0.continuation.resume() }
    }

    private func retireWork() {
        guard let active = work else { return }
        work = nil
        // Cancellation is cooperative: own the worker until its next batch
        // exits, but never put that completion on the next page's critical path.
        retiring[active.id] = active.task
        active.task.cancel()
        active.consumers.values.forEach { $0.continuation.resume() }
    }

    deinit {
        work?.task.cancel()
        work?.consumers.values.forEach { $0.continuation.resume() }
        retiring.values.forEach { $0.cancel() }
    }
}
