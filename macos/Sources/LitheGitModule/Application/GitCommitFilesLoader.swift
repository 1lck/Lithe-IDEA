import Foundation

/// Describes the selected commit's changed-file loading lifecycle.
package enum GitCommitFilesLoadState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case failed
}

enum GitCommitFilesLoadOutcome: Equatable, Sendable {
    case ready([GitCommitFile])
    case failed
    case superseded
}

/// Coordinates commit-file reads with bounded concurrency and prioritizes the
/// latest visible selection over filtering and speculative prefetch work.
@MainActor
final class GitCommitFilesLoader {
    private enum RequestPurpose: Equatable {
        case selected
        case query
        case prefetch
    }

    private struct CacheKey: Hashable {
        let repositoryRoot: URL
        let commitHash: String
    }

    private struct Waiter {
        let id: UUID
        let purpose: RequestPurpose
        let continuation: AsyncStream<GitCommitFilesLoadOutcome>.Continuation
    }

    private struct Request {
        let id: UUID
        let key: CacheKey
        let commit: GitCommit
        let repositoryRoot: URL
        let generation: UInt64
        var purpose: RequestPurpose
        var waiters: [Waiter]
    }

    private let service: GitService
    private let cacheCapacity: Int
    private let physicalLoadLimit: Int
    private var cache: [CacheKey: [GitCommitFile]] = [:]
    private var cacheRecency: [CacheKey] = []
    private var generation: UInt64 = 0
    private var activeRequests: [UUID: Request] = [:]
    private var pendingSelectedRequest: Request?
    private var pendingQueryRequests: [Request] = []
    private var pendingPrefetchRequests: [Request] = []

    init(
        service: GitService,
        cacheCapacity: Int = 128,
        physicalLoadLimit: Int = 2
    ) {
        self.service = service
        self.cacheCapacity = max(1, cacheCapacity)
        self.physicalLoadLimit = max(1, physicalLoadLimit)
    }

    var hasActiveWork: Bool {
        !activeRequests.isEmpty
            || pendingSelectedRequest != nil
            || !pendingQueryRequests.isEmpty
            || !pendingPrefetchRequests.isEmpty
    }

    func cachedFiles(for commit: GitCommit, at repositoryRoot: URL) -> [GitCommitFile]? {
        let key = makeKey(for: commit, at: repositoryRoot)
        guard let files = cache[key] else { return nil }
        touch(key)
        return files
    }

    func requestSelectedFiles(
        for commit: GitCommit,
        at repositoryRoot: URL
    ) -> Task<GitCommitFilesLoadOutcome, Never> {
        let key = makeKey(for: commit, at: repositoryRoot)

        // A superseded physical read may be synchronous and therefore unable to
        // stop promptly. Its selected waiter is completed immediately, while the
        // read may still populate only its cache entry. The newest selection can
        // then use the second physical slot without waiting for stale work.
        supersedeSelectedWaiters(unlessMatching: key)
        pendingPrefetchRequests = []

        if let files = cachedFiles(for: commit, at: repositoryRoot) {
            return Task { .ready(files) }
        }
        return makeDemandTask(
            purpose: .selected,
            commit: commit,
            repositoryRoot: repositoryRoot
        )
    }

    func loadSelectedFiles(
        for commit: GitCommit,
        at repositoryRoot: URL
    ) async -> GitCommitFilesLoadOutcome {
        let task = requestSelectedFiles(for: commit, at: repositoryRoot)
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func loadQueryFiles(
        for commit: GitCommit,
        at repositoryRoot: URL
    ) async -> GitCommitFilesLoadOutcome {
        if let files = cachedFiles(for: commit, at: repositoryRoot) {
            return .ready(files)
        }
        let task = makeDemandTask(
            purpose: .query,
            commit: commit,
            repositoryRoot: repositoryRoot
        )
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func replacePrefetchCandidates(
        _ commits: [GitCommit],
        at repositoryRoot: URL
    ) {
        pendingPrefetchRequests = []
        var includedKeys: Set<CacheKey> = []
        for commit in commits {
            let key = makeKey(for: commit, at: repositoryRoot)
            guard includedKeys.insert(key).inserted,
                  cache[key] == nil,
                  !containsPendingOrActiveRequest(for: key) else {
                continue
            }
            pendingPrefetchRequests.append(Request(
                id: UUID(),
                key: key,
                commit: commit,
                repositoryRoot: repositoryRoot,
                generation: generation,
                purpose: .prefetch,
                waiters: []
            ))
        }
        startPendingRequestsIfPossible()
    }

    /// Invalidates queued work and cache entries. Reads already executing may
    /// finish, but their generation prevents them from repopulating the cache.
    func reset() {
        generation &+= 1
        cache = [:]
        cacheRecency = []
        resumeWaiters(in: pendingSelectedRequest, with: .superseded)
        pendingSelectedRequest = nil
        for request in pendingQueryRequests {
            resumeWaiters(in: request, with: .superseded)
        }
        pendingQueryRequests = []
        pendingPrefetchRequests = []
        for requestID in Array(activeRequests.keys) {
            guard var request = activeRequests[requestID] else { continue }
            resumeWaiters(in: request, with: .superseded)
            request.waiters = []
            request.purpose = .prefetch
            activeRequests[requestID] = request
        }
    }

    private func makeDemandTask(
        purpose: RequestPurpose,
        commit: GitCommit,
        repositoryRoot: URL
    ) -> Task<GitCommitFilesLoadOutcome, Never> {
        let waiterID = UUID()
        var streamContinuation: AsyncStream<GitCommitFilesLoadOutcome>.Continuation?
        let stream = AsyncStream<GitCommitFilesLoadOutcome> { continuation in
            streamContinuation = continuation
        }
        guard let streamContinuation else {
            return Task { .failed }
        }
        streamContinuation.onTermination = { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cancelWaiter(waiterID)
            }
        }
        let waiter = Waiter(
            id: waiterID,
            purpose: purpose,
            continuation: streamContinuation
        )
        enqueueDemand(
            purpose: purpose,
            commit: commit,
            repositoryRoot: repositoryRoot,
            waiter: waiter
        )
        return Task {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next() ?? .superseded
        }
    }

    private func enqueueDemand(
        purpose: RequestPurpose,
        commit: GitCommit,
        repositoryRoot: URL,
        waiter: Waiter
    ) {
        let key = makeKey(for: commit, at: repositoryRoot)
        if let requestID = activeRequests.first(where: {
            $0.value.key == key && $0.value.generation == generation
        })?.key, var request = activeRequests[requestID] {
            request.waiters.append(waiter)
            if purpose == .selected {
                request.purpose = .selected
            } else if request.purpose == .prefetch {
                request.purpose = .query
            }
            activeRequests[requestID] = request
            return
        }
        if pendingSelectedRequest?.key == key {
            pendingSelectedRequest?.waiters.append(waiter)
            return
        }
        if let queryIndex = pendingQueryRequests.firstIndex(where: { $0.key == key }) {
            var request = pendingQueryRequests.remove(at: queryIndex)
            request.waiters.append(waiter)
            if purpose == .selected {
                supersedeSelectedWaiters(unlessMatching: key)
                request.purpose = .selected
                pendingSelectedRequest = request
            } else {
                pendingQueryRequests.insert(request, at: queryIndex)
            }
            startPendingRequestsIfPossible()
            return
        }

        if let prefetchIndex = pendingPrefetchRequests.firstIndex(where: { $0.key == key }) {
            var request = pendingPrefetchRequests.remove(at: prefetchIndex)
            request.purpose = purpose
            request.waiters = [waiter]
            if purpose == .selected {
                supersedeSelectedWaiters(unlessMatching: key)
                pendingSelectedRequest = request
            } else {
                pendingQueryRequests.append(request)
            }
            startPendingRequestsIfPossible()
            return
        }

        let request = Request(
            id: UUID(),
            key: key,
            commit: commit,
            repositoryRoot: repositoryRoot,
            generation: generation,
            purpose: purpose,
            waiters: [waiter]
        )
        if purpose == .selected {
            supersedeSelectedWaiters(unlessMatching: key)
            pendingSelectedRequest = request
        } else {
            pendingQueryRequests.append(request)
        }
        startPendingRequestsIfPossible()
    }

    private func supersedeSelectedWaiters(unlessMatching key: CacheKey) {
        if var request = pendingSelectedRequest, request.key != key {
            pendingSelectedRequest = nil
            let selectedWaiters = removeSelectedWaiters(from: &request)
            resumeWaiters(selectedWaiters, with: .superseded)
            if !request.waiters.isEmpty {
                request.purpose = .query
                enqueuePendingQueryRequest(request)
            }
        }

        for requestID in Array(activeRequests.keys) {
            guard var request = activeRequests[requestID], request.key != key else { continue }
            let selectedWaiters = removeSelectedWaiters(from: &request)
            guard !selectedWaiters.isEmpty else { continue }
            request.purpose = remainingPurpose(for: request)
            activeRequests[requestID] = request
            resumeWaiters(selectedWaiters, with: .superseded)
        }
    }

    private func removeSelectedWaiters(from request: inout Request) -> [Waiter] {
        let selectedWaiters = request.waiters.filter { $0.purpose == .selected }
        request.waiters.removeAll { $0.purpose == .selected }
        return selectedWaiters
    }

    private func remainingPurpose(for request: Request) -> RequestPurpose {
        if request.waiters.contains(where: { $0.purpose == .selected }) {
            return .selected
        }
        return request.waiters.contains(where: { $0.purpose == .query }) ? .query : .prefetch
    }

    private func startPendingRequestsIfPossible() {
        while activeRequests.count < physicalLoadLimit, let request = takeNextRequest() {
            activeRequests[request.id] = request
            let service = self.service
            Task { @MainActor [weak self] in
                let files = await service.files(
                    in: request.commit,
                    at: request.repositoryRoot
                )
                self?.finishActiveRequest(requestID: request.id, files: files)
            }
        }
    }

    private func takeNextRequest() -> Request? {
        if let request = pendingSelectedRequest {
            pendingSelectedRequest = nil
            return request
        }
        if !pendingQueryRequests.isEmpty {
            return pendingQueryRequests.removeFirst()
        }
        // One speculative read is enough to warm the cache while leaving room
        // for a newly selected commit to start without waiting for prefetch.
        if !pendingPrefetchRequests.isEmpty,
           !activeRequests.values.contains(where: { $0.purpose == .prefetch }) {
            return pendingPrefetchRequests.removeFirst()
        }
        return nil
    }

    private func finishActiveRequest(requestID: UUID, files: [GitCommitFile]?) {
        guard let request = activeRequests.removeValue(forKey: requestID) else { return }
        if request.generation != generation {
            resumeWaiters(in: request, with: .superseded)
        } else if let files {
            cache(files, for: request.key)
            resumeWaiters(in: request, with: .ready(files))
        } else {
            // Failures are deliberately not cached, so a retry can issue a new
            // physical read instead of treating the failure as an empty commit.
            resumeWaiters(in: request, with: .failed)
        }
        startPendingRequestsIfPossible()
    }

    private func cancelWaiter(_ waiterID: UUID) {
        for requestID in Array(activeRequests.keys) {
            guard var request = activeRequests[requestID] else { continue }
            request.waiters.removeAll { $0.id == waiterID }
            request.purpose = remainingPurpose(for: request)
            activeRequests[requestID] = request
        }
        if var request = pendingSelectedRequest {
            request.waiters.removeAll { $0.id == waiterID }
            pendingSelectedRequest = nil
            if request.waiters.contains(where: { $0.purpose == .selected }) {
                pendingSelectedRequest = request
            } else if !request.waiters.isEmpty {
                request.purpose = .query
                enqueuePendingQueryRequest(request)
            }
        }
        for index in pendingQueryRequests.indices.reversed() {
            pendingQueryRequests[index].waiters.removeAll { $0.id == waiterID }
            if pendingQueryRequests[index].waiters.isEmpty {
                pendingQueryRequests.remove(at: index)
            }
        }
    }

    private func containsPendingOrActiveRequest(for key: CacheKey) -> Bool {
        activeRequests.values.contains(where: {
            $0.key == key && $0.generation == generation
        })
            || pendingSelectedRequest?.key == key
            || pendingQueryRequests.contains(where: { $0.key == key })
            || pendingPrefetchRequests.contains(where: { $0.key == key })
    }

    private func resumeWaiters(
        in request: Request?,
        with outcome: GitCommitFilesLoadOutcome
    ) {
        guard let request else { return }
        resumeWaiters(request.waiters, with: outcome)
    }

    private func resumeWaiters(
        _ waiters: [Waiter],
        with outcome: GitCommitFilesLoadOutcome
    ) {
        for waiter in waiters {
            waiter.continuation.yield(outcome)
            waiter.continuation.finish()
        }
    }

    private func enqueuePendingQueryRequest(_ request: Request) {
        if let index = pendingQueryRequests.firstIndex(where: { $0.key == request.key }) {
            pendingQueryRequests[index].waiters.append(contentsOf: request.waiters)
        } else {
            pendingQueryRequests.append(request)
        }
        startPendingRequestsIfPossible()
    }

    private func makeKey(for commit: GitCommit, at repositoryRoot: URL) -> CacheKey {
        CacheKey(
            repositoryRoot: repositoryRoot.standardizedFileURL,
            commitHash: commit.hash
        )
    }

    private func cache(_ files: [GitCommitFile], for key: CacheKey) {
        cache[key] = files
        touch(key)
        while cacheRecency.count > cacheCapacity {
            let evictedKey = cacheRecency.removeFirst()
            cache.removeValue(forKey: evictedKey)
        }
    }

    private func touch(_ key: CacheKey) {
        cacheRecency.removeAll { $0 == key }
        cacheRecency.append(key)
    }
}
