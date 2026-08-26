import Foundation
import LitheCoreContracts

public struct GenericDebugBreakpoint: Identifiable, Equatable, Sendable {
    public let fileURL: URL
    public let line: Int
    public var verified: Bool
    public var message: String?

    public var id: String { fileURL.standardizedFileURL.path + ":" + String(line) }
    public var title: String { fileURL.lastPathComponent + ":" + String(line) }
}

@MainActor
public final class GenericDebugFeatureModel: ObservableObject, GenericDebugFeatureTarget {
    @Published public private(set) var providerID: String?
    @Published public private(set) var targetTitle: String?
    @Published public private(set) var state: DebugAdapterState = .idle
    @Published public private(set) var output = ""
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var stoppedReason: String?
    @Published public private(set) var breakpoints: [GenericDebugBreakpoint] = []
    @Published public private(set) var threads: [DebugThread] = []
    @Published public private(set) var stackFrames: [DebugStackFrame] = []
    @Published public private(set) var scopes: [DebugScope] = []
    @Published public private(set) var variables: [DebugVariable] = []
    @Published public private(set) var selectedThreadID: Int?
    @Published public private(set) var selectedFrameID: Int?

    private let sessions: DebugAdapterSessionManager
    private var requestedLinesByFile: [URL: Set<Int>] = [:]
    private let maximumOutputCharacters = 400_000

    public init(sessions: DebugAdapterSessionManager) {
        self.sessions = sessions
        sessions.onStateChange = { [weak self] providerID, state in
            guard self?.providerID == providerID else { return }
            self?.state = state
        }
        sessions.onEvent = { [weak self] providerID, event in
            guard self?.providerID == providerID else { return }
            self?.consume(event)
        }
    }

    public var isSessionActive: Bool {
        ![.idle, .terminated, .failed].contains(state)
    }

    public var canControl: Bool { state == .running || state == .paused }

    public func start(
        fileURL: URL,
        rootURL: URL,
        configuration: DebugLaunchConfiguration
    ) -> Bool {
        stop()
        providerID = sessionsProviderID(for: fileURL)
        targetTitle = configuration.name
        output = ""
        errorMessage = nil
        stoppedReason = nil
        threads = []
        stackFrames = []
        scopes = []
        variables = []
        selectedThreadID = nil
        selectedFrameID = nil
        do {
            if let lines = requestedLinesByFile[fileURL.standardizedFileURL] {
                try sessions.setBreakpoints(
                    lines.sorted().map { DebugSourceBreakpoint(line: $0) },
                    in: fileURL
                )
            }
            let session = try sessions.launch(
                for: fileURL,
                rootURL: rootURL,
                configuration: configuration
            )
            state = session.state
            return true
        } catch {
            state = .failed
            errorMessage = error.localizedDescription
            append(error.localizedDescription + "\n")
            return false
        }
    }

    public func stop() {
        if let providerID {
            sessions.stop(providerID: providerID)
        }
        state = .idle
        stoppedReason = nil
        selectedThreadID = nil
        selectedFrameID = nil
        threads = []
        stackFrames = []
        scopes = []
        variables = []
    }

    public func reset() {
        stop()
        providerID = nil
        targetTitle = nil
        output = ""
        errorMessage = nil
        breakpoints = []
        requestedLinesByFile = [:]
    }

    public func toggleBreakpoint(fileURL: URL, line: Int) {
        guard line > 0 else { return }
        let normalizedURL = fileURL.standardizedFileURL
        var lines = requestedLinesByFile[normalizedURL] ?? []
        if lines.contains(line) {
            lines.remove(line)
        } else {
            lines.insert(line)
        }
        requestedLinesByFile[normalizedURL] = lines
        reconcileBreakpoints()
        try? sessions.setBreakpoints(
            lines.sorted().map { DebugSourceBreakpoint(line: $0) },
            in: normalizedURL
        )
    }

    public func execute(_ command: DebugExecutionCommand) {
        guard let providerID,
              let session = sessions.session(providerID: providerID) else { return }
        session.execute(command, threadID: selectedThreadID)
    }

    public func inspectThreads() {
        guard let session = activeSession else { return }
        session.requestThreads { [weak self] result in
            switch result {
            case .success(let threads):
                self?.threads = threads
                if self?.selectedThreadID == nil { self?.selectedThreadID = threads.first?.id }
            case .failure(let error): self?.record(error)
            }
        }
    }

    public func selectThread(_ thread: DebugThread) {
        selectedThreadID = thread.id
        guard let session = activeSession else { return }
        session.requestStackTrace(threadID: thread.id) { [weak self] result in
            switch result {
            case .success(let frames):
                self?.stackFrames = frames
                self?.selectedFrameID = frames.first?.id
                if let frame = frames.first { self?.selectFrame(frame) }
            case .failure(let error): self?.record(error)
            }
        }
    }

    public func selectFrame(_ frame: DebugStackFrame) {
        selectedFrameID = frame.id
        guard let session = activeSession else { return }
        session.requestScopes(frameID: frame.id) { [weak self] result in
            switch result {
            case .success(let scopes):
                self?.scopes = scopes
                if let scope = scopes.first(where: { !$0.expensive }) ?? scopes.first {
                    self?.loadVariables(reference: scope.variablesReference)
                } else {
                    self?.variables = []
                }
            case .failure(let error): self?.record(error)
            }
        }
    }

    public func loadVariables(reference: Int) {
        guard let session = activeSession else { return }
        session.requestVariables(reference: reference) { [weak self] result in
            switch result {
            case .success(let variables): self?.variables = variables
            case .failure(let error): self?.record(error)
            }
        }
    }

    public func evaluate(_ expression: String) {
        let value = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let session = activeSession else { return }
        session.evaluate(value, frameID: selectedFrameID) { [weak self] result in
            switch result {
            case .success(let variable):
                self?.append("\(value) = \(variable.value)\n")
            case .failure(let error): self?.record(error)
            }
        }
    }

    public func clearOutput() { output = "" }

    private var activeSession: (any DebugAdapterControllingSession)? {
        guard let providerID else { return nil }
        return sessions.session(providerID: providerID)
    }

    private func sessionsProviderID(for fileURL: URL) -> String? {
        sessions.provider(for: fileURL)?.id
    }

    private func consume(_ event: DebugAdapterEvent) {
        switch event {
        case .initialized:
            break
        case .output(_, let text):
            append(text)
        case .stopped(let reason, let threadID, let description):
            stoppedReason = description ?? reason
            selectedThreadID = threadID
            inspectThreads()
            if let threadID,
               let thread = threads.first(where: { $0.id == threadID }) {
                selectThread(thread)
            } else if let threadID, let session = activeSession {
                session.requestStackTrace(threadID: threadID) { [weak self] result in
                    if case .success(let frames) = result {
                        self?.stackFrames = frames
                        if let frame = frames.first { self?.selectFrame(frame) }
                    }
                }
            }
        case .continued:
            stoppedReason = nil
        case .terminated(let exitCode):
            if let exitCode { append("Debug session exited with code \(exitCode).\n") }
        case .breakpoint(let resolved):
            guard let sourceURL = resolved.sourceURL, let line = resolved.line else { return }
            if let index = breakpoints.firstIndex(where: {
                $0.fileURL.standardizedFileURL == sourceURL.standardizedFileURL && $0.line == line
            }) {
                breakpoints[index].verified = resolved.verified
                breakpoints[index].message = resolved.message
            }
        }
    }

    private func reconcileBreakpoints() {
        breakpoints = requestedLinesByFile
            .flatMap { fileURL, lines in
                lines.map {
                    GenericDebugBreakpoint(
                        fileURL: fileURL,
                        line: $0,
                        verified: false,
                        message: nil
                    )
                }
            }
            .sorted {
                if $0.fileURL.path == $1.fileURL.path { return $0.line < $1.line }
                return $0.fileURL.path < $1.fileURL.path
            }
    }

    private func record(_ error: Error) {
        errorMessage = error.localizedDescription
        append(error.localizedDescription + "\n")
    }

    private func append(_ text: String) {
        output += text
        if output.count > maximumOutputCharacters {
            output.removeFirst(output.count - maximumOutputCharacters)
        }
    }
}
