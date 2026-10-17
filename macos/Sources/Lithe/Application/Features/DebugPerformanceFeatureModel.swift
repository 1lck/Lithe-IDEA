import Combine
import Foundation

/// View-local live monitoring. Only an expanded, visible panel owns a sampler.
@MainActor
final class DebugPerformanceFeatureModel: ObservableObject {
    @Published private(set) var samples: [DebugPerformanceSample] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var isSampling = false
    private let sampler: (any DebugPerformanceSampling)?
    private var targets: [UUID: DebugPerformanceTarget] = [:]
    private var histories: [UUID: [DebugPerformanceSample]] = [:]
    private var targetOrder: [UUID] = []
    private var activeSessionID: UUID?
    private var isActive = false
    private var isVisible = false
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(sampler: (any DebugPerformanceSampling)?) { self.sampler = sampler }

    func register(_ target: DebugPerformanceTarget, sessionID: UUID) {
        guard target.processID > 0, (target.javaExecutable == nil || target.javaExecutable?.lastPathComponent == "java") else { return }
        guard targets[sessionID] != target else { return }
        // DAP restart can retain the session ID while launching a different JVM.
        if targets[sessionID] != nil {
            histories.removeValue(forKey: sessionID)
            if activeSessionID == sessionID { samples = [] }
        }
        targets[sessionID] = target
        if !targetOrder.contains(sessionID) { targetOrder.append(sessionID) }
        // ponytail: Retain 16 session histories, each capped at 600 samples. A larger
        // recording feature should own a separate on-disk store, not grow this UI cache.
        while targetOrder.count > 16 {
            let removed = targetOrder.removeFirst()
            targets.removeValue(forKey: removed)
            histories.removeValue(forKey: removed)
        }
        if activeSessionID == sessionID { restart() }
    }

    func select(sessionID: UUID?, isActive: Bool) {
        guard activeSessionID != sessionID || self.isActive != isActive else { return }
        activeSessionID = sessionID
        self.isActive = isActive
        samples = sessionID.flatMap { histories[$0] } ?? []
        restart()
    }

    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        restart()
    }

    private func restart() {
        generation = UUID()
        task?.cancel(); task = nil
        isSampling = false
        errorMessage = nil
        guard isVisible, isActive else { return }
        guard let id = activeSessionID, let target = targets[id], let sampler else {
            errorMessage = "Performance is available for local Java processes launched by Lithe."
            return
        }
        let current = generation
        isSampling = true
        task = Task { [weak self] in
            do {
                for try await sample in sampler.samples(for: target) {
                    guard let self, !Task.isCancelled, generation == current else { return }
                    samples.append(sample)
                    if samples.count > 600 { samples.removeFirst(samples.count - 600) }
                    histories[id] = samples
                }
                guard let self, generation == current else { return }
                isSampling = false
            } catch {
                guard let self, !Task.isCancelled, generation == current else { return }
                isSampling = false
                errorMessage = error.localizedDescription
            }
        }
    }

    deinit { task?.cancel() }
}
