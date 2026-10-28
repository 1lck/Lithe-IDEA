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
@MainActor
final class LSPProjectUsageModel: ObservableObject {
    enum State: Equatable { case idle, loading, ready }
    typealias Scanner = @Sendable ([URL], [LSPProjectUsageRequest.Rule]) async -> LSPProjectUsageSummary?

    @Published private(set) var state: State = .idle
    private let scanner: Scanner
    private var cached: (request: LSPProjectUsageRequest, summary: LSPProjectUsageSummary)?
    private var work: Work?

    private final class Work {
        let id = UUID()
        let request: LSPProjectUsageRequest
        let task: Task<LSPProjectUsageSummary?, Never>
        var consumers: Set<UUID> = []

        init(request: LSPProjectUsageRequest, task: Task<LSPProjectUsageSummary?, Never>) {
            self.request = request
            self.task = task
        }
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
        guard !Task.isCancelled else { return }
        if summary(for: request) != nil {
            // A request for a cached snapshot can supersede a different scan.
            work?.task.cancel()
            // @Published also emits for equal values. A warm page already has
            // its summary, so avoid scheduling a second SwiftUI update.
            if state != .ready { state = .ready }
            return
        }
        let active: Work
        if let current = work, current.request == request, !current.task.isCancelled {
            active = current
        } else {
            let previous = work?.task
            previous?.cancel()
            let scanner = self.scanner
            let task = Task.detached(priority: .utility) {
                // Even on rapid changes there is only one scanner executing.
                if let previous { _ = await previous.value }
                guard !Task.isCancelled else { return nil as LSPProjectUsageSummary? }
                return await scanner(files, request.rules)
            }
            active = Work(request: request, task: task)
            work = active
        }
        let consumer = UUID()
        let workID = active.id
        let computation = active.task
        active.consumers.insert(consumer)
        state = .loading
        let value = await withTaskCancellationHandler {
            await computation.value
        } onCancel: { [weak self] in
            Task { @MainActor in self?.cancel(consumer: consumer, workID: workID) }
        }
        guard work?.id == active.id else { return }
        active.consumers.remove(consumer)
        guard !Task.isCancelled, !active.task.isCancelled, let value else {
            if active.consumers.isEmpty {
                work = nil
                state = cached == nil ? .idle : .ready
            }
            return
        }
        cached = (request, value)
        work = nil
        state = .ready
    }

    func reset() {
        work?.task.cancel()
        // Retain the cancelled task until it drains so a new workspace's worker
        // can await it instead of overlapping with its last batch.
        cached = nil
        state = .idle
    }

    private func cancel(consumer: UUID, workID: UUID) {
        guard let work, work.id == workID else { return }
        work.consumers.remove(consumer)
        if work.consumers.isEmpty {
            work.task.cancel()
            state = cached == nil ? .idle : .ready
        }
    }

    deinit { work?.task.cancel() }
}
