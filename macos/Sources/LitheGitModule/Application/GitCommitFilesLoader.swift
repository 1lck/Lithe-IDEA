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

/// Serializes commit-file reads while prioritizing the latest visible selection
/// over filtering and speculative prefetch work.
@MainActor
final class GitCommitFilesLoader {
    private enum RequestPurpose {
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
    private var cache: [CacheKey: [GitCommitFile]] = [:]
    private var cacheRecency: [CacheKey] = []
    private var generation: UInt64 = 0
    private var inFlightRequest: Request?
    private var pendingSelectedRequest: Request?
    private var pendingQueryRequests: [Request] = []
    private var pendingPrefetchRequests: [Request] = []
    private var workerTask: Task<Void, Never>?

    init(service: GitService, cacheCapacity: Int = 128) {
        self.service = service
        self.cacheCapacity = max(1, cacheCapacity)
    }

    var hasActiveWork: Bool {
        workerTask != nil
            || inFlightRequest != nil
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

        // A visible selection invalidates queued speculative work immediately.
        // The synchronous Git operation already in flight is allowed to finish,
        // but no second operation starts beside it.
        supersedePendingSelectedRequest(unlessMatching: key)
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
        ensureWorker()
    }

    /// Invalidates queued work and cache entries without starting another
    /// operation beside a synchronous read that is already executing.
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
        if var inFlightRequest {
            resumeWaiters(in: inFlightRequest, with: .superseded)
            inFlightRequest.waiters = []
            self.inFlightRequest = inFlightRequest
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
        let waiter = Waiter(id: waiterID, continuation: streamContinuation)
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
        // A reset invalidates the result of the synchronous read that is
        // already running. Keep that read serialized, but never attach a new
        // generation's waiter to it or the new request could be completed as
        // stale without ever being retried.
        if inFlightRequest?.key == key,
           inFlightRequest?.generation == generation {
            inFlightRequest?.waiters.append(waiter)
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
                supersedePendingSelectedRequest(unlessMatching: key)
                request.purpose = .selected
                pendingSelectedRequest = request
            } else {
                pendingQueryRequests.insert(request, at: queryIndex)
            }
            ensureWorker()
            return
        }

        if let prefetchIndex = pendingPrefetchRequests.firstIndex(where: { $0.key == key }) {
            var request = pendingPrefetchRequests.remove(at: prefetchIndex)
            request.purpose = purpose
            request.waiters = [waiter]
            if purpose == .selected {
                supersedePendingSelectedRequest(unlessMatching: key)
                pendingSelectedRequest = request
            } else {
                pendingQueryRequests.append(request)
            }
            ensureWorker()
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
            supersedePendingSelectedRequest(unlessMatching: key)
            pendingSelectedRequest = request
        } else {
            pendingQueryRequests.append(request)
        }
        ensureWorker()
    }

    private func supersedePendingSelectedRequest(unlessMatching key: CacheKey) {
        guard let request = pendingSelectedRequest, request.key != key else { return }
        resumeWaiters(in: request, with: .superseded)
        pendingSelectedRequest = nil
    }

    private func ensureWorker() {
        guard workerTask == nil,
              inFlightRequest != nil
                || pendingSelectedRequest != nil
                || !pendingQueryRequests.isEmpty
                || !pendingPrefetchRequests.isEmpty else {
            return
        }
        workerTask = Task { @MainActor [weak self] in
            await self?.runWorker()
        }
    }

    private func runWorker() async {
        while let request = takeNextRequest() {
            inFlightRequest = request
            let files = await service.files(
                in: request.commit,
                at: request.repositoryRoot
            )
            finishInFlightRequest(requestID: request.id, files: files)
        }
        workerTask = nil
    }

    private func takeNextRequest() -> Request? {
        if let request = pendingSelectedRequest {
            pendingSelectedRequest = nil
            return request
        }
        if !pendingQueryRequests.isEmpty {
            return pendingQueryRequests.removeFirst()
        }
        if !pendingPrefetchRequests.isEmpty {
            return pendingPrefetchRequests.removeFirst()
        }
        return nil
    }

    private func finishInFlightRequest(requestID: UUID, files: [GitCommitFile]?) {
        guard let request = inFlightRequest, request.id == requestID else { return }
        inFlightRequest = nil
        guard request.generation == generation else {
            resumeWaiters(in: request, with: .superseded)
            return
        }
        guard let files else {
            resumeWaiters(in: request, with: .failed)
            return
        }
        cache(files, for: request.key)
        resumeWaiters(in: request, with: .ready(files))
    }

    private func cancelWaiter(_ waiterID: UUID) {
        if var request = inFlightRequest {
            request.waiters.removeAll { $0.id == waiterID }
            inFlightRequest = request
        }
        if var request = pendingSelectedRequest {
            request.waiters.removeAll { $0.id == waiterID }
            pendingSelectedRequest = request.waiters.isEmpty ? nil : request
        }
        for index in pendingQueryRequests.indices.reversed() {
            pendingQueryRequests[index].waiters.removeAll { $0.id == waiterID }
            if pendingQueryRequests[index].waiters.isEmpty {
                pendingQueryRequests.remove(at: index)
            }
        }
    }

    private func containsPendingOrActiveRequest(for key: CacheKey) -> Bool {
        (inFlightRequest?.key == key && inFlightRequest?.generation == generation)
            || pendingSelectedRequest?.key == key
            || pendingQueryRequests.contains(where: { $0.key == key })
            || pendingPrefetchRequests.contains(where: { $0.key == key })
    }

    private func resumeWaiters(
        in request: Request?,
        with outcome: GitCommitFilesLoadOutcome
    ) {
        guard let request else { return }
        for waiter in request.waiters {
            waiter.continuation.yield(outcome)
            waiter.continuation.finish()
        }
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
