import Combine
import Foundation
import LitheExecutionModule

/// Owns the selected test worker, its live charts and one explicit JFR recording.
/// Collapsing stops live sampling; an explicitly started recording continues until
/// stopped or the worker exits. Replacing/closing the run disposes its recording.
@MainActor
final class TestJVMPerformanceFeatureModel: ObservableObject {
    let metrics: DebugPerformanceFeatureModel
    @Published private(set) var processes: [TestJVMProcess] = []
    @Published private(set) var selectedProcess: TestJVMProcess?
    @Published private(set) var recording: TestJVMRecording?
    @Published private(set) var isRecording = false
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?
    @Published var report: String?
    @Published private(set) var usesJVM = true
    private let provider: (any TestJVMPerformanceProviding)?
    private var runID: UUID?
    private var rootPID: Int32?
    private var active = false
    private var visible = false
    private var discovery: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var workerIDs: [String: UUID] = [:]
    private var generation = UUID()
    private weak var boundService: LanguageTestService?
    private var observation: AnyCancellable?
    private var discardRecording: (@Sendable () -> Void)?

    init(sampler: (any DebugPerformanceSampling)?, provider: (any TestJVMPerformanceProviding)?) {
        metrics = DebugPerformanceFeatureModel(sampler: sampler)
        self.provider = provider
    }

    func bind(to service: LanguageTestService) {
        guard boundService !== service else { return }
        boundService = service
        observation = Publishers.CombineLatest4(service.$runID, service.$processID, service.$state, service.$activePlan)
            .sink { [weak self] id, pid, state, plan in
                self?.update(runID: id, processID: pid, isRunning: state == .running,
                    isJava: (plan?.providerID ?? "java") == "java")
            }
    }

    var isProcessRunning: Bool { active && selectedProcess.map(processes.contains) == true }
    var canStartRecording: Bool { active && selectedProcess.map(processes.contains) == true && !isRecording && !isBusy }

    func update(runID: UUID?, processID: Int32?, isRunning: Bool, isJava: Bool) {
        if self.runID != runID {
            generation = UUID()
            discovery?.cancel(); discovery = nil
            operation?.cancel(); operation = nil
            discardRecording?(); discardRecording = nil
            self.recording = nil; recordingDuration = 0; isRecording = false; isBusy = false; report = nil
            processes = []; selectedProcess = nil; workerIDs = [:]; errorMessage = nil
            self.runID = runID
        }
        let changed = rootPID != processID || active != isRunning || usesJVM != isJava
        rootPID = processID; active = isRunning; usesJVM = isJava
        if !isJava {
            discovery?.cancel(); discovery = nil
            if let runID, let processID { metrics.register(DebugPerformanceTarget(processID: processID), sessionID: runID) }
            metrics.select(sessionID: runID, isActive: isRunning && processID != nil)
        } else if !isRunning || processID == nil {
            discovery?.cancel(); discovery = nil
            selectMetrics(active: false)
            if isRecording { stopRecording() }
        } else if changed { discover() }
    }

    func setVisible(_ value: Bool) {
        visible = value
        metrics.setVisible(value)
        reconcileDiscovery()
    }

    private func reconcileDiscovery() {
        if !visible && !isRecording && !isBusy {
            discovery?.cancel(); discovery = nil
        } else { discover() }
    }

    func select(_ process: TestJVMProcess) {
        guard !isRecording, !isBusy, processes.contains(process) else { return }
        selectedProcess = process
        selectMetrics(active: active)
    }

    private func selectMetrics(active: Bool) {
        guard let process = selectedProcess else { metrics.select(sessionID: nil, isActive: false); return }
        let id = workerIDs[process.id] ?? UUID()
        workerIDs[process.id] = id
        // ponytail: Match the shared chart owner's 16-worker history ceiling.
        for key in workerIDs.keys.sorted() where workerIDs.count > 16 && key != process.id {
            workerIDs.removeValue(forKey: key)
        }
        metrics.register(process.target, sessionID: id)
        metrics.select(sessionID: id, isActive: active && processes.contains(process))
    }

    private func discover() {
        guard usesJVM, active, let rootPID, let provider, discovery == nil, visible || isRecording || isBusy else { return }
        let current = generation
        discovery = Task { [weak self] in
            do {
                for try await workers in provider.processes(rootProcessID: rootPID) {
                    guard let self, !Task.isCancelled, generation == current else { return }
                    if processes != workers { processes = workers }
                    if let recording, isRecording, Date().timeIntervalSince(recording.startedAt) >= 120 { stopRecording() }
                    if let selectedProcess, !workers.contains(selectedProcess), isRecording { stopRecording() }
                    if !isRecording && !isBusy, let first = workers.first,
                       selectedProcess.map({ !workers.contains($0) }) ?? true {
                        selectedProcess = first
                    }
                    selectMetrics(active: active)
                }
                guard let self, !Task.isCancelled, generation == current else { return }
                discovery = nil
                active = false; processes = []
                selectMetrics(active: false)
                if isRecording { stopRecording() }
            } catch {
                guard let self, !Task.isCancelled, generation == current else { return }
                discovery = nil; errorMessage = error.localizedDescription
            }
        }
    }

    func startRecording() {
        guard let selectedProcess, let provider, active, !isBusy, !isRecording else { return }
        let current = generation
        isBusy = true; errorMessage = nil; report = nil
        let previous = recording
        discardRecording = nil
        recording = nil
        operation = Task { [weak self] in
            if let previous { await provider.discard(previous) }
            do {
                let value = try await provider.startRecording(selectedProcess)
                guard let self, !Task.isCancelled, generation == current else { await provider.discard(value); return }
                recording = value
                discardRecording = { Task { await provider.discard(value) } }
                recordingDuration = 0; isRecording = true; isBusy = false
                if !active || !processes.contains(selectedProcess) { stopRecording() }
                else { discover() }
            } catch {
                guard let self, generation == current else { return }
                isBusy = false; errorMessage = error.localizedDescription
                reconcileDiscovery()
            }
        }
    }

    func stopRecording() {
        guard let recording, let provider, isRecording, !isBusy else { return }
        let current = generation
        isBusy = true; errorMessage = nil
        operation = Task { [weak self] in
            do { try await provider.stopRecording(recording) }
            catch {
                guard let self, generation == current else { return }
                errorMessage = error.localizedDescription
                isBusy = false
                reconcileDiscovery()
                return
            }
            guard let self, generation == current else { return }
            recordingDuration = min(120, max(0, Date().timeIntervalSince(recording.startedAt)))
            isRecording = false; isBusy = false
            if let first = processes.first, selectedProcess.map({ !processes.contains($0) }) ?? true { selectedProcess = first }
            selectMetrics(active: active)
            reconcileDiscovery()
        }
    }

    func showResults() {
        guard let recording, let provider, !isRecording, !isBusy else { return }
        let current = generation
        isBusy = true; errorMessage = nil
        operation = Task { [weak self] in
            do {
                let result = try await provider.report(recording)
                guard let self, !Task.isCancelled, generation == current else { return }
                report = result; isBusy = false
                reconcileDiscovery()
            } catch {
                guard let self, generation == current else { return }
                errorMessage = error.localizedDescription; isBusy = false
                reconcileDiscovery()
            }
        }
    }

    deinit {
        discovery?.cancel(); operation?.cancel()
        discardRecording?()
    }
}
