import Foundation
import LitheCoreContracts

public struct GenericDebugBreakpoint: Identifiable, Equatable, Sendable {
    public let fileURL: URL
    public let line: Int
    public let column: Int?
    public let enabled: Bool
    public let condition: String?
    public let hitCondition: String?
    public let logMessage: String?
    public var verified: Bool
    public var message: String?

    public var id: String {
        fileURL.standardizedFileURL.path + ":" + String(line) + ":" + String(column ?? 0)
    }
    public var title: String { fileURL.lastPathComponent + ":" + String(line) }
    public var isLogpoint: Bool { logMessage?.isEmpty == false }
}

public struct GenericDebugExceptionBreakpoint: Identifiable, Equatable, Sendable {
    public let filter: String
    public let label: String
    public let description: String?
    public let enabled: Bool
    public let condition: String?
    public let supportsCondition: Bool
    public let conditionDescription: String?

    public var id: String { filter }
}

public struct GenericDebugFunctionBreakpoint: Identifiable, Equatable, Sendable {
    public let name: String
    public let enabled: Bool
    public let condition: String?
    public let hitCondition: String?
    public var verified: Bool
    public var message: String?

    public var id: String { name }
}

public struct GenericDebugDataBreakpoint: Identifiable, Equatable, Sendable {
    public let dataID: String
    public let label: String
    public let enabled: Bool
    public let accessType: String?
    public let accessTypes: [String]
    public let condition: String?
    public let hitCondition: String?
    public let canPersist: Bool
    public var verified: Bool
    public var message: String?

    public var id: String { dataID + ":" + (accessType ?? "") }
}

public struct GenericDebugWatch: Identifiable, Equatable, Sendable {
    public let expression: String
    public var value: String?
    public var type: String?
    public var error: String?

    public var id: String { expression }
}

public enum GenericDebugVariableRowContent: Equatable, Sendable {
    case variable(DebugVariable)
    case loadMore(parentVariableID: String?, nextCount: Int, remainingCount: Int?)
}

public struct GenericDebugVariableRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let content: GenericDebugVariableRowContent
    public let depth: Int

    public var variable: DebugVariable? {
        guard case .variable(let variable) = content else { return nil }
        return variable
    }
}

public struct GenericDebugStackFrameRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let frame: DebugStackFrame?
    public let hiddenFrameCount: Int

    public var isHiddenGroup: Bool { frame == nil }
}

private struct GenericDebugVariablePageSegment: Equatable, Sendable {
    let filter: DebugVariableFilter?
    var nextStart: Int
    let totalCount: Int?
}

private struct GenericDebugVariablePageState: Equatable, Sendable {
    let reference: Int
    var segments: [GenericDebugVariablePageSegment]
    var loadedPageFingerprints: Set<[GenericDebugVariablePageItemFingerprint]>

    var remainingCount: Int? {
        var remaining = 0
        for segment in segments {
            guard let totalCount = segment.totalCount else { return nil }
            remaining += max(0, totalCount - segment.nextStart)
        }
        return remaining
    }
}

private struct GenericDebugVariablePageItemFingerprint: Hashable, Sendable {
    let name: String
    let value: String
    let type: String?
    let evaluateName: String?
    let variablesReference: Int
}

private struct GenericDebugStartRequest: Equatable, Sendable {
    let fileURL: URL
    let rootURL: URL
    let configuration: DebugLaunchConfiguration
}

private struct GenericDebugOutputNormalizer {
    private enum State {
        case normal
        case escape
        case controlSequence
        case operatingSystemCommand
        case operatingSystemCommandEscape
    }

    private var state = State.normal
    private var sawCarriageReturn = false

    mutating func normalize(_ rawOutput: String) -> String {
        var normalized = String()
        normalized.reserveCapacity(rawOutput.count)
        for scalar in rawOutput.unicodeScalars {
            switch state {
            case .normal:
                if scalar.value == 0x1B {
                    sawCarriageReturn = false
                    state = .escape
                } else if scalar.value == 0x0D {
                    normalized.append("\n")
                    sawCarriageReturn = true
                } else if scalar.value == 0x0A {
                    if !sawCarriageReturn { normalized.append("\n") }
                    sawCarriageReturn = false
                } else if scalar.value == 0x09 || scalar.value >= 0x20 {
                    normalized.unicodeScalars.append(scalar)
                    sawCarriageReturn = false
                }
            case .escape:
                sawCarriageReturn = false
                switch scalar.value {
                case 0x5B: // CSI: ESC [ ... final byte
                    state = .controlSequence
                case 0x5D: // OSC: ESC ] ... BEL or ST
                    state = .operatingSystemCommand
                default:
                    state = .normal
                }
            case .controlSequence:
                sawCarriageReturn = false
                if (0x40...0x7E).contains(scalar.value) {
                    state = .normal
                }
            case .operatingSystemCommand:
                sawCarriageReturn = false
                if scalar.value == 0x07 {
                    state = .normal
                } else if scalar.value == 0x1B {
                    state = .operatingSystemCommandEscape
                }
            case .operatingSystemCommandEscape:
                sawCarriageReturn = false
                state = scalar.value == 0x5C ? .normal : .operatingSystemCommand
            }
        }
        return normalized
    }

    mutating func reset() {
        state = .normal
        sawCarriageReturn = false
    }
}

/// Cached presentation state for an inactive session. Inspection data is
/// refreshed when the session becomes active so stale frame references are
/// never reused across adapter sessions.
private struct GenericDebugSessionSnapshot {
    let providerID: String
    let targetTitle: String?
    var state: DebugAdapterState
    var output: String
    var errorMessage: String?
    var stoppedReason: String?
    var exceptionInfo: DebugExceptionInfo?
    var capabilities: DebugAdapterCapabilities
    var activeFileURL: URL?
    var lastStartRequest: GenericDebugStartRequest?
    var normalizer: GenericDebugOutputNormalizer
}

@MainActor
public final class GenericDebugFeatureModel: ObservableObject, GenericDebugFeatureTarget {
    @Published public private(set) var providerID: String?
    @Published public private(set) var activeSessionID: DebugSessionID?
    @Published public private(set) var sessionSummaries: [DebugSessionSummary] = []
    @Published public private(set) var targetTitle: String?
    @Published public private(set) var state: DebugAdapterState = .idle
    @Published public private(set) var output = ""
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var stoppedReason: String?
    @Published public private(set) var exceptionInfo: DebugExceptionInfo?
    @Published public private(set) var breakpoints: [GenericDebugBreakpoint] = []
    @Published public private(set) var exceptionBreakpoints: [GenericDebugExceptionBreakpoint] = []
    @Published public private(set) var functionBreakpoints: [GenericDebugFunctionBreakpoint] = []
    @Published public private(set) var dataBreakpoints: [GenericDebugDataBreakpoint] = []
    @Published public private(set) var threads: [DebugThread] = []
    @Published public private(set) var stackFrames: [DebugStackFrame] = []
    @Published public private(set) var scopes: [DebugScope] = []
    @Published public private(set) var variables: [DebugVariable] = []
    @Published public private(set) var variableChildren: [String: [DebugVariable]] = [:]
    @Published public private(set) var expandedVariableIDs: Set<String> = []
    @Published public private(set) var loadingVariableIDs: Set<String> = []
    @Published private var variablePageStates: [String: GenericDebugVariablePageState] = [:]
    @Published private var loadingVariablePageIDs: Set<String> = []
    @Published public private(set) var watches: [GenericDebugWatch] = []
    @Published public private(set) var selectedThreadID: Int?
    @Published public private(set) var selectedFrameID: Int?
    @Published public private(set) var areBreakpointsMuted = false
    @Published public private(set) var capabilities: DebugAdapterCapabilities = .unknown
    @Published public private(set) var stoppedFrame: DebugStackFrame?
    /// The frame currently selected in the call stack, which may differ from
    /// the frame that initially caused the stop.
    @Published public private(set) var selectedFrame: DebugStackFrame?
    @Published public private(set) var javaSteppingFilters: DebugSteppingFilters?
    @Published public private(set) var consoleHistory: [String] = []
    @Published public private(set) var areFilteredStackFramesExpanded = false

    /// Delivers the selected stopped frame to the host editor for source
    /// navigation. The Debug module does not own editor presentation.
    public var onStoppedLocation: ((URL, Int, Int) -> Void)?
    /// Lets the host activate its native Terminal module without coupling
    /// Debug to a platform process or presentation implementation.
    public var onRunInTerminalRequest: DebugRunInTerminalRequestHandler? {
        get { sessions.onRunInTerminalRequest }
        set { sessions.onRunInTerminalRequest = newValue }
    }

    /// Routes an integrated-terminal reverse request with its owning session.
    public var onSessionRunInTerminalRequest: ((
        DebugSessionID,
        DebugRunInTerminalRequest,
        @escaping DebugRunInTerminalCompletion
    ) -> Void)? {
        get { sessions.onSessionRunInTerminalRequest }
        set { sessions.onSessionRunInTerminalRequest = newValue }
    }

    /// Notifies the host when the visible debugger session changes.
    public var onSessionSelectionChanged: ((DebugSessionID?) -> Void)?
    /// Notifies the host after a debugger session has been stopped and its
    /// adapter resources have been released.
    public var onSessionStopped: ((DebugSessionID) -> Void)?

    private let sessions: DebugAdapterSessionManager
    private let breakpointPersistence: (any DebugBreakpointPersisting)?
    private let breakpointRelocator: (any DebugBreakpointRelocating)?
    private let steppingFilterResolver: (any DebugSteppingFilterResolving)?
    private let steppingFilterPersistence: (any DebugSteppingFilterPersisting)?
    private var requestedBreakpointsByFile: [URL: [Int: DebugSourceBreakpoint]] = [:]
    private var workspaceURL: URL?
    private var activeFileURL: URL?
    private var lastStartRequest: GenericDebugStartRequest?
    private var sessionSnapshots: [DebugSessionID: GenericDebugSessionSnapshot] = [:]
    private var consoleHistoryBySession: [DebugSessionID: [String]] = [:]
    private var consoleHistoryCursorBySession: [DebugSessionID: Int] = [:]
    private var consoleHistoryDraftBySession: [DebugSessionID: String] = [:]
    private let maximumConsoleHistoryEntries = 100
    private let maximumOutputCharacters = 400_000
    private let variablePageSize = 100
    private var watchGeneration = 0
    private var inspectionGeneration = 0
    private static let rootVariablePageID = "__lithe_debug_root_variables__"
    private var debuggeeOutputNormalizer = GenericDebugOutputNormalizer()

    public init(
        sessions: DebugAdapterSessionManager,
        breakpointPersistence: (any DebugBreakpointPersisting)? = nil,
        breakpointRelocator: (any DebugBreakpointRelocating)? = nil,
        steppingFilterResolver: (any DebugSteppingFilterResolving)? = nil,
        steppingFilterPersistence: (any DebugSteppingFilterPersisting)? = nil
    ) {
        self.sessions = sessions
        self.breakpointPersistence = breakpointPersistence
        self.breakpointRelocator = breakpointRelocator
        self.steppingFilterResolver = steppingFilterResolver
        self.steppingFilterPersistence = steppingFilterPersistence
        sessionSummaries = sessions.sessionSummaries
        sessions.onSessionStateChange = { [weak self] sessionID, providerID, state in
            guard let self else { return }
            self.sessionSummaries = self.sessions.sessionSummaries
            if self.activeSessionID == sessionID {
                self.providerID = providerID
                self.state = state
                self.saveActiveSessionSnapshot()
            } else {
                self.updateInactiveSessionState(
                    sessionID,
                    providerID: providerID,
                    state: state
                )
            }
        }
        sessions.onSessionEvent = { [weak self] sessionID, providerID, event in
            guard let self else { return }
            self.sessionSummaries = self.sessions.sessionSummaries
            if self.activeSessionID == sessionID {
                self.consume(event)
                self.saveActiveSessionSnapshot()
            } else {
                self.consumeInactiveSessionEvent(
                    sessionID,
                    providerID: providerID,
                    event: event
                )
            }
        }
        loadJavaSteppingFilters()
    }

    public var isSessionActive: Bool {
        ![.idle, .terminated, .failed].contains(state)
    }

    public var canControl: Bool { state == .running || state == .paused }
    public var canRestart: Bool {
        canControl && capabilities.supportsRestartRequest
    }
    public var canTerminate: Bool {
        canControl && capabilities.supportsTerminateRequest
    }
    public var canStepBack: Bool {
        state == .paused && capabilities.supportsStepBack
    }
    public var canRetry: Bool {
        lastStartRequest != nil && (state == .failed || state == .terminated)
    }
    public var visibleVariableRows: [GenericDebugVariableRow] {
        var rows: [GenericDebugVariableRow] = []
        appendVisibleVariables(variables, parentPath: "root", depth: 0, to: &rows)
        appendVariableLoadMoreRow(
            parentVariableID: nil,
            parentPath: "root",
            depth: 0,
            to: &rows
        )
        return rows
    }
    public var visibleStackFrameRows: [GenericDebugStackFrameRow] {
        guard javaSteppingFilters?.hideFilteredStackFrames == true,
              !areFilteredStackFramesExpanded else {
            return stackFrames.map(stackFrameRow)
        }
        var rows: [GenericDebugStackFrameRow] = []
        var hiddenCount = 0
        var hiddenStartID: Int?
        for frame in stackFrames {
            if frame.isFiltered {
                hiddenCount += 1
                hiddenStartID = hiddenStartID ?? frame.id
                continue
            }
            appendHiddenStackFrames(
                count: hiddenCount,
                startID: hiddenStartID,
                to: &rows
            )
            hiddenCount = 0
            hiddenStartID = nil
            rows.append(stackFrameRow(frame))
        }
        appendHiddenStackFrames(count: hiddenCount, startID: hiddenStartID, to: &rows)
        return rows
    }
    public var hiddenStackFrameCount: Int {
        stackFrames.lazy.filter(\.isFiltered).count
    }

    public func start(
        fileURL: URL,
        rootURL: URL,
        configuration: DebugLaunchConfiguration
    ) -> Bool {
        stop()
        return startSession(
            fileURL: fileURL,
            rootURL: rootURL,
            configuration: configuration
        )
    }

    /// Starts another debug session while keeping existing sessions alive.
    /// The new session becomes the active session shown by the Debug tool
    /// window.
    @discardableResult
    public func startAdditional(
        fileURL: URL,
        rootURL: URL,
        configuration: DebugLaunchConfiguration
    ) -> Bool {
        let previousSessionID = activeSessionID
        let previousSnapshot = previousSessionID.flatMap { sessionSnapshots[$0] }
        saveActiveSessionSnapshot()
        let started = startSession(
            fileURL: fileURL,
            rootURL: rootURL,
            configuration: configuration
        )
        guard !started,
              let previousSessionID,
              let previousSnapshot,
              let previousSummary = sessions.sessionSummaries.first(where: { $0.id == previousSessionID })
        else {
            return started
        }
        _ = sessions.select(sessionID: previousSessionID)
        activeSessionID = previousSessionID
        providerID = previousSnapshot.providerID
        onSessionSelectionChanged?(previousSessionID)
        sessionSnapshots[previousSessionID] = previousSnapshot
        restoreSessionSnapshot(
            previousSessionID,
            summary: previousSummary
        )
        sessionSummaries = sessions.sessionSummaries
        return false
    }

    /// Makes a registered session active without starting or stopping it.
    /// Paused sessions refresh their inspection context after the switch.
    @discardableResult
    public func selectSession(_ sessionID: DebugSessionID) -> Bool {
        guard sessionID != activeSessionID,
              let summary = sessions.sessionSummaries.first(where: { $0.id == sessionID })
        else { return false }
        saveActiveSessionSnapshot()
        invalidateInspectionRequests()
        guard sessions.select(sessionID: sessionID) else { return false }
        activeSessionID = sessionID
        providerID = summary.providerID
        onSessionSelectionChanged?(sessionID)
        publishConsoleHistory(for: sessionID)
        restoreSessionSnapshot(sessionID, summary: summary)
        sessionSummaries = sessions.sessionSummaries
        resetInspectionState()
        if state == .paused {
            let generation = inspectionGeneration
            loadStoppedContext(
                threadID: nil,
                generation: generation,
                shouldLoadExceptionInfo: false
            )
        }
        return true
    }

    /// Stops one session. Inactive sessions do not disturb the currently
    /// displayed debugger state.
    public func stopSession(_ sessionID: DebugSessionID) {
        if activeSessionID == sessionID {
            stop()
            return
        }
        sessions.stop(sessionID: sessionID)
        sessionSnapshots[sessionID] = nil
        sessionSummaries = sessions.sessionSummaries
        onSessionStopped?(sessionID)
    }

    private func startSession(
        fileURL: URL,
        rootURL: URL,
        configuration: DebugLaunchConfiguration
    ) -> Bool {
        let request = GenericDebugStartRequest(
            fileURL: fileURL.standardizedFileURL,
            rootURL: rootURL.standardizedFileURL,
            configuration: configuration
        )
        lastStartRequest = request
        activeFileURL = request.fileURL
        providerID = sessionsProviderID(for: fileURL)
        targetTitle = configuration.name
        output = ""
        debuggeeOutputNormalizer.reset()
        errorMessage = nil
        stoppedReason = nil
        exceptionInfo = nil
        threads = []
        stackFrames = []
        scopes = []
        resetVariableTree()
        invalidateWatchResults()
        capabilities = .unknown
        selectedThreadID = nil
        selectedFrameID = nil
        stoppedFrame = nil
        selectedFrame = nil
        do {
            if requestedBreakpointsByFile[request.fileURL] != nil {
                try sessions.setBreakpoints(
                    effectiveBreakpoints(for: request.fileURL),
                    in: request.fileURL
                )
            }
            if !dataBreakpoints.isEmpty {
                try sessions.setDataBreakpoints(coreDataBreakpoints, for: request.fileURL)
            }
            let effectiveConfiguration: DebugLaunchConfiguration
            if providerID == "java", let javaSteppingFilters {
                effectiveConfiguration = request.configuration.applying(
                    steppingFilters: javaSteppingFilters
                )
            } else {
                effectiveConfiguration = request.configuration
            }
            let launched = try sessions.launchNew(
                for: request.fileURL,
                rootURL: request.rootURL,
                configuration: effectiveConfiguration
            )
            activeSessionID = launched.id
            state = launched.session.state
            sessionSummaries = sessions.sessionSummaries
            publishConsoleHistory(for: launched.id)
            saveActiveSessionSnapshot()
            return true
        } catch {
            state = .failed
            errorMessage = error.localizedDescription
            append(error.localizedDescription + "\n")
            return false
        }
    }

    @discardableResult
    public func retry() -> Bool {
        guard let request = lastStartRequest else { return false }
        return start(
            fileURL: request.fileURL,
            rootURL: request.rootURL,
            configuration: request.configuration
        )
    }

    public func stop() {
        invalidateInspectionRequests()
        if let activeFileURL {
            dataBreakpoints.removeAll { !$0.canPersist }
            try? sessions.setDataBreakpoints(coreDataBreakpoints, for: activeFileURL)
        }
        if let activeSessionID {
            sessions.stop(sessionID: activeSessionID)
            sessionSnapshots[activeSessionID] = nil
            onSessionStopped?(activeSessionID)
        }
        sessionSummaries = sessions.sessionSummaries
        if let replacement = sessionSummaries.last,
           sessions.select(sessionID: replacement.id) {
            activeSessionID = replacement.id
            providerID = replacement.providerID
            onSessionSelectionChanged?(replacement.id)
            publishConsoleHistory(for: replacement.id)
            restoreSessionSnapshot(replacement.id, summary: replacement)
            resetInspectionState()
            if state == .paused {
                let generation = inspectionGeneration
                loadStoppedContext(
                    threadID: nil,
                    generation: generation,
                    shouldLoadExceptionInfo: false
                )
            }
            return
        }
        activeSessionID = nil
        onSessionSelectionChanged?(nil)
        consoleHistory = []
        state = .idle
        stoppedReason = nil
        exceptionInfo = nil
        selectedThreadID = nil
        selectedFrameID = nil
        stoppedFrame = nil
        selectedFrame = nil
        threads = []
        stackFrames = []
        areFilteredStackFramesExpanded = false
        scopes = []
        resetVariableTree()
        invalidateWatchResults()
        capabilities = .unknown
        activeFileURL = nil
        debuggeeOutputNormalizer.reset()
    }

    public func reset() {
        invalidateInspectionRequests()
        sessions.stopAll()
        sessionSnapshots.removeAll()
        activeSessionID = nil
        sessionSummaries = []
        consoleHistory = []
        consoleHistoryBySession.removeAll()
        consoleHistoryCursorBySession.removeAll()
        consoleHistoryDraftBySession.removeAll()
        state = .idle
        stoppedReason = nil
        exceptionInfo = nil
        selectedThreadID = nil
        selectedFrameID = nil
        stoppedFrame = nil
        selectedFrame = nil
        threads = []
        stackFrames = []
        areFilteredStackFramesExpanded = false
        scopes = []
        resetVariableTree()
        invalidateWatchResults()
        capabilities = .unknown
        activeFileURL = nil
        debuggeeOutputNormalizer.reset()
        providerID = nil
        targetTitle = nil
        output = ""
        debuggeeOutputNormalizer.reset()
        errorMessage = nil
        breakpoints = []
        exceptionBreakpoints = []
        functionBreakpoints = []
        dataBreakpoints = []
        watches = []
        requestedBreakpointsByFile = [:]
        areBreakpointsMuted = false
        workspaceURL = nil
        lastStartRequest = nil
    }

    public func openWorkspace(at workspaceURL: URL) {
        let root = workspaceURL.standardizedFileURL
        guard self.workspaceURL != root else { return }
        self.workspaceURL = root
        requestedBreakpointsByFile = [:]
        breakpoints = []
        areBreakpointsMuted = false
        guard let breakpointPersistence else { return }
        do {
            guard let snapshot = try breakpointPersistence.loadBreakpoints(for: root),
                  snapshot.version == DebugBreakpointSnapshot.currentVersion else { return }
            areBreakpointsMuted = snapshot.areBreakpointsMuted
            for persisted in snapshot.breakpoints {
                guard let fileURL = restoredFileURL(for: persisted.relativePath, root: root),
                      persisted.line > 0 else { continue }
                var values = requestedBreakpointsByFile[fileURL] ?? [:]
                values[persisted.line] = DebugSourceBreakpoint(
                    line: persisted.line,
                    column: persisted.column,
                    enabled: persisted.enabled,
                    condition: normalizedOptionalText(persisted.condition),
                    hitCondition: normalizedOptionalText(persisted.hitCondition),
                    logMessage: normalizedOptionalText(persisted.logMessage)
                )
                requestedBreakpointsByFile[fileURL] = values
            }
            reconcileBreakpoints()
        } catch {
            record(error)
        }
    }

    public func toggleBreakpoint(fileURL: URL, line: Int) {
        guard line > 0 else { return }
        let normalizedURL = fileURL.standardizedFileURL
        var values = requestedBreakpointsByFile[normalizedURL] ?? [:]
        if values[line] != nil {
            values[line] = nil
        } else {
            values[line] = DebugSourceBreakpoint(line: line)
        }
        requestedBreakpointsByFile[normalizedURL] = values.isEmpty ? nil : values
        reconcileBreakpoints()
        persistBreakpoints()
        synchronizeBreakpoints(for: normalizedURL)
    }

    public func updateBreakpoint(
        fileURL: URL,
        line: Int,
        enabled: Bool,
        condition: String?,
        hitCondition: String?,
        logMessage: String?
    ) {
        guard line > 0 else { return }
        let normalizedURL = fileURL.standardizedFileURL
        var values = requestedBreakpointsByFile[normalizedURL] ?? [:]
        values[line] = DebugSourceBreakpoint(
            line: line,
            enabled: enabled,
            condition: normalizedOptionalText(condition),
            hitCondition: normalizedOptionalText(hitCondition),
            logMessage: normalizedOptionalText(logMessage)
        )
        requestedBreakpointsByFile[normalizedURL] = values
        reconcileBreakpoints()
        persistBreakpoints()
        synchronizeBreakpoints(for: normalizedURL)
    }

    public func setBreakpointEnabled(_ breakpoint: GenericDebugBreakpoint, enabled: Bool) {
        updateBreakpoint(
            fileURL: breakpoint.fileURL,
            line: breakpoint.line,
            enabled: enabled,
            condition: breakpoint.condition,
            hitCondition: breakpoint.hitCondition,
            logMessage: breakpoint.logMessage
        )
    }

    public func removeBreakpoint(_ breakpoint: GenericDebugBreakpoint) {
        let fileURL = breakpoint.fileURL.standardizedFileURL
        var values = requestedBreakpointsByFile[fileURL] ?? [:]
        values[breakpoint.line] = nil
        requestedBreakpointsByFile[fileURL] = values.isEmpty ? nil : values
        reconcileBreakpoints()
        persistBreakpoints()
        synchronizeBreakpoints(for: fileURL)
    }

    public func removeAllBreakpoints() {
        let fileURLs = requestedBreakpointsByFile.keys.sorted { $0.path < $1.path }
        requestedBreakpointsByFile = [:]
        reconcileBreakpoints()
        persistBreakpoints()
        for fileURL in fileURLs { synchronizeBreakpoints(for: fileURL) }
    }

    public func toggleBreakpointMute() {
        areBreakpointsMuted.toggle()
        persistBreakpoints()
        for fileURL in requestedBreakpointsByFile.keys.sorted(by: { $0.path < $1.path }) {
            synchronizeBreakpoints(for: fileURL)
        }
    }

    public func applySourceEdit(
        fileURL: URL,
        source: String,
        edit: DebugSourceEdit
    ) {
        let normalizedURL = fileURL.standardizedFileURL
        guard let breakpointRelocator,
              let values = requestedBreakpointsByFile[normalizedURL],
              !values.isEmpty else { return }
        let current = values.values.sorted {
            ($0.line, $0.column ?? 0) < ($1.line, $1.column ?? 0)
        }
        guard sourceEditMayRelocateBreakpoints(source: source, edit: edit, breakpoints: current)
        else { return }
        do {
            let relocated = try breakpointRelocator.relocateDebugBreakpoints(
                source: source,
                edit: edit,
                breakpoints: current
            )
            guard relocated != current else { return }
            requestedBreakpointsByFile[normalizedURL] = Dictionary(
                uniqueKeysWithValues: relocated.map { ($0.line, $0) }
            )
            reconcileBreakpoints()
            persistBreakpoints()
            synchronizeBreakpoints(for: normalizedURL)
        } catch {
            record(error)
        }
    }

    private func sourceEditMayRelocateBreakpoints(
        source: String,
        edit: DebugSourceEdit,
        breakpoints: [DebugSourceBreakpoint]
    ) -> Bool {
        if breakpoints.contains(where: { $0.column != nil })
            || edit.replacement.utf16.contains(10) {
            return true
        }
        guard edit.startUTF16Offset >= 0,
              edit.endUTF16Offset >= edit.startUTF16Offset else { return true }
        guard edit.startUTF16Offset != edit.endUTF16Offset else { return false }
        let sourceUTF16 = source.utf16
        guard let start = sourceUTF16.index(
            sourceUTF16.startIndex,
            offsetBy: edit.startUTF16Offset,
            limitedBy: sourceUTF16.endIndex
        ), let end = sourceUTF16.index(
            sourceUTF16.startIndex,
            offsetBy: edit.endUTF16Offset,
            limitedBy: sourceUTF16.endIndex
        ) else { return true }
        return sourceUTF16[start..<end].contains(10)
    }

    public func updateExceptionBreakpoint(
        _ breakpoint: GenericDebugExceptionBreakpoint,
        enabled: Bool,
        condition: String?
    ) {
        guard let index = exceptionBreakpoints.firstIndex(where: { $0.filter == breakpoint.filter })
        else { return }
        exceptionBreakpoints[index] = GenericDebugExceptionBreakpoint(
            filter: breakpoint.filter,
            label: breakpoint.label,
            description: breakpoint.description,
            enabled: enabled,
            condition: breakpoint.supportsCondition ? normalizedOptionalText(condition) : nil,
            supportsCondition: breakpoint.supportsCondition,
            conditionDescription: breakpoint.conditionDescription
        )
        synchronizeExceptionBreakpoints()
    }

    public func addFunctionBreakpoint(
        name: String,
        condition: String?,
        hitCondition: String?
    ) {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return }
        let breakpoint = GenericDebugFunctionBreakpoint(
            name: normalizedName,
            enabled: true,
            condition: normalizedOptionalText(condition),
            hitCondition: normalizedOptionalText(hitCondition),
            verified: false,
            message: nil
        )
        if let index = functionBreakpoints.firstIndex(where: { $0.name == normalizedName }) {
            functionBreakpoints[index] = breakpoint
        } else {
            functionBreakpoints.append(breakpoint)
        }
        functionBreakpoints.sort { $0.name < $1.name }
        synchronizeFunctionBreakpoints()
    }

    public func updateFunctionBreakpoint(
        _ breakpoint: GenericDebugFunctionBreakpoint,
        name: String,
        enabled: Bool,
        condition: String?,
        hitCondition: String?
    ) {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return }
        let previousVerification = functionBreakpoints.first { $0.name == breakpoint.name }
        functionBreakpoints.removeAll {
            $0.name == breakpoint.name || $0.name == normalizedName
        }
        functionBreakpoints.append(GenericDebugFunctionBreakpoint(
            name: normalizedName,
            enabled: enabled,
            condition: normalizedOptionalText(condition),
            hitCondition: normalizedOptionalText(hitCondition),
            verified: previousVerification?.verified ?? breakpoint.verified,
            message: previousVerification?.message ?? breakpoint.message
        ))
        functionBreakpoints.sort { $0.name < $1.name }
        synchronizeFunctionBreakpoints()
    }

    public func setFunctionBreakpointEnabled(
        _ breakpoint: GenericDebugFunctionBreakpoint,
        enabled: Bool
    ) {
        updateFunctionBreakpoint(
            breakpoint,
            name: breakpoint.name,
            enabled: enabled,
            condition: breakpoint.condition,
            hitCondition: breakpoint.hitCondition
        )
    }

    public func removeFunctionBreakpoint(_ breakpoint: GenericDebugFunctionBreakpoint) {
        functionBreakpoints.removeAll { $0.name == breakpoint.name }
        synchronizeFunctionBreakpoints()
    }

    public func requestDataBreakpoint(for variable: DebugVariable) {
        guard state == .paused,
              capabilities.supportsDataBreakpoints,
              let session = activeSession else { return }
        session.requestDataBreakpointInfo(
            name: variable.name,
            variablesReference: variable.containerReference,
            frameID: selectedFrameID
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let info):
                guard let dataID = info.dataID, !dataID.isEmpty else {
                    record(DebugAdapterProtocolError.requestFailed(
                        command: "dataBreakpointInfo",
                        message: info.description
                    ))
                    return
                }
                let preferredAccess = info.accessTypes.contains("write")
                    ? "write" : info.accessTypes.first
                let breakpoint = GenericDebugDataBreakpoint(
                    dataID: dataID,
                    label: info.description.isEmpty ? variable.name : info.description,
                    enabled: true,
                    accessType: preferredAccess,
                    accessTypes: info.accessTypes,
                    condition: nil,
                    hitCondition: nil,
                    canPersist: info.canPersist,
                    verified: false,
                    message: nil
                )
                dataBreakpoints.removeAll { $0.id == breakpoint.id }
                dataBreakpoints.append(breakpoint)
                sortDataBreakpoints()
                synchronizeDataBreakpoints()
            case .failure(let error):
                record(error)
            }
        }
    }

    public func updateDataBreakpoint(
        _ breakpoint: GenericDebugDataBreakpoint,
        enabled: Bool,
        accessType: String?,
        condition: String?,
        hitCondition: String?
    ) {
        guard let index = dataBreakpoints.firstIndex(where: { $0.id == breakpoint.id }) else { return }
        let replacement = GenericDebugDataBreakpoint(
            dataID: breakpoint.dataID,
            label: breakpoint.label,
            enabled: enabled,
            accessType: normalizedOptionalText(accessType),
            accessTypes: breakpoint.accessTypes,
            condition: normalizedOptionalText(condition),
            hitCondition: normalizedOptionalText(hitCondition),
            canPersist: breakpoint.canPersist,
            verified: breakpoint.verified,
            message: breakpoint.message
        )
        dataBreakpoints.remove(at: index)
        dataBreakpoints.removeAll { $0.id == replacement.id }
        dataBreakpoints.append(replacement)
        sortDataBreakpoints()
        synchronizeDataBreakpoints()
    }

    public func setDataBreakpointEnabled(
        _ breakpoint: GenericDebugDataBreakpoint,
        enabled: Bool
    ) {
        updateDataBreakpoint(
            breakpoint,
            enabled: enabled,
            accessType: breakpoint.accessType,
            condition: breakpoint.condition,
            hitCondition: breakpoint.hitCondition
        )
    }

    public func removeDataBreakpoint(_ breakpoint: GenericDebugDataBreakpoint) {
        dataBreakpoints.removeAll { $0.id == breakpoint.id }
        synchronizeDataBreakpoints()
    }

    public func execute(_ command: DebugExecutionCommand) {
        guard let session = activeSession else { return }
        session.execute(command, threadID: selectedThreadID)
    }

    public func updateJavaSteppingFilters(_ filters: DebugSteppingFilters) {
        do {
            let normalized = try steppingFilterResolver?.resolveDebugSteppingFilters(
                adapterID: "java",
                filters: filters
            ) ?? filters
            javaSteppingFilters = normalized
            areFilteredStackFramesExpanded = false
            try steppingFilterPersistence?.saveSteppingFilters(normalized, adapterID: "java")
        } catch {
            record(error)
        }
    }

    public func resetJavaSteppingFilters() {
        guard let steppingFilterResolver else { return }
        do {
            let defaults = try steppingFilterResolver.resolveDebugSteppingFilters(
                adapterID: "java",
                filters: nil
            )
            updateJavaSteppingFilters(defaults)
        } catch {
            record(error)
        }
    }

    public func expandFilteredStackFrames() {
        areFilteredStackFramesExpanded = true
    }

    public func collapseFilteredStackFrames() {
        areFilteredStackFramesExpanded = false
    }

    public func executeThread(_ command: DebugExecutionCommand, thread: DebugThread) {
        guard capabilities.supportsSingleThreadExecutionRequests,
              (command == .continueExecution && state == .paused)
                || (command == .pause && state == .running),
              let session = activeSession else { return }
        session.execute(
            command,
            threadID: thread.id,
            targetID: nil,
            singleThread: true
        )
    }

    public func requestSmartStepInto(
        completion: @escaping (Result<[DebugStepInTarget], Error>) -> Void
    ) {
        guard state == .paused,
              capabilities.supportsStepInTargetsRequest,
              let selectedFrameID,
              let session = activeSession else {
            completion(.failure(DebugAdapterCapabilityError.unsupported("smart step into")))
            return
        }
        session.requestStepInTargets(frameID: selectedFrameID) { [weak self] result in
            if case .failure(let error) = result { self?.record(error) }
            completion(result)
        }
    }

    public func smartStepInto(_ target: DebugStepInTarget) {
        guard let selectedThreadID, let session = activeSession else { return }
        session.execute(.stepIn, threadID: selectedThreadID, targetID: target.id)
    }

    public func requestRunToCursor(
        fileURL: URL,
        line: Int,
        column: Int?,
        completion: @escaping (Result<[DebugGotoTarget], Error>) -> Void
    ) {
        guard state == .paused,
              capabilities.supportsGotoTargetsRequest,
              let session = activeSession else {
            completion(.failure(DebugAdapterCapabilityError.unsupported("run to cursor")))
            return
        }
        session.requestGotoTargets(
            fileURL: fileURL,
            line: line,
            column: column
        ) { [weak self] result in
            if case .failure(let error) = result { self?.record(error) }
            completion(result)
        }
    }

    public func runToCursor(_ target: DebugGotoTarget) {
        guard let selectedThreadID, let session = activeSession else { return }
        session.execute(.goto, threadID: selectedThreadID, targetID: target.id)
    }

    public func inspectThreads() {
        guard let session = activeSession else { return }
        let generation = inspectionGeneration
        session.requestThreads { [weak self] result in
            guard let self, self.inspectionGeneration == generation else { return }
            switch result {
            case .success(let threads):
                self.threads = threads
                if self.selectedThreadID == nil { self.selectedThreadID = threads.first?.id }
            case .failure(let error): self.record(error)
            }
        }
    }

    public func selectThread(_ thread: DebugThread) {
        let generation = beginInspectionTransition()
        exceptionInfo = nil
        selectedThreadID = thread.id
        selectedFrameID = nil
        selectedFrame = nil
        stackFrames = []
        areFilteredStackFramesExpanded = false
        scopes = []
        resetVariableTree()
        invalidateWatchResults()
        guard let session = activeSession else { return }
        session.requestStackTrace(threadID: thread.id) { [weak self] result in
            guard let self,
                  self.inspectionGeneration == generation,
                  self.selectedThreadID == thread.id else { return }
            switch result {
            case .success(let frames):
                self.stackFrames = frames
                self.areFilteredStackFramesExpanded = false
                self.selectedFrameID = frames.first?.id
                if let frame = frames.first {
                    self.selectFrame(frame, generation: generation)
                } else {
                    self.selectedFrame = nil
                }
            case .failure(let error): self.record(error)
            }
        }
    }

    public func selectFrame(_ frame: DebugStackFrame) {
        let generation = beginInspectionTransition()
        selectFrame(frame, generation: generation)
    }

    private func selectFrame(_ frame: DebugStackFrame, generation: Int) {
        selectedFrameID = frame.id
        selectedFrame = frame
        scopes = []
        resetVariableTree()
        invalidateWatchResults()
        publishStoppedLocation(frame)
        refreshWatches()
        guard let session = activeSession else { return }
        session.requestScopes(frameID: frame.id) { [weak self] result in
            guard let self,
                  self.inspectionGeneration == generation,
                  self.selectedFrameID == frame.id else { return }
            switch result {
            case .success(let scopes):
                self.scopes = scopes
                if let scope = scopes.first(where: { !$0.expensive }) ?? scopes.first {
                    self.loadVariables(
                        reference: scope.variablesReference,
                        namedVariables: scope.namedVariables,
                        indexedVariables: scope.indexedVariables,
                        frameID: frame.id,
                        generation: generation
                    )
                } else {
                    self.resetVariableTree()
                }
            case .failure(let error): self.record(error)
            }
        }
    }

    public func loadVariables(reference: Int) {
        loadVariables(
            reference: reference,
            namedVariables: 0,
            indexedVariables: 0,
            frameID: selectedFrameID,
            generation: inspectionGeneration
        )
    }

    private func loadVariables(
        reference: Int,
        namedVariables: Int,
        indexedVariables: Int,
        frameID: Int?,
        generation: Int
    ) {
        resetVariableTree()
        variablePageStates[Self.rootVariablePageID] = makeVariablePageState(
            reference: reference,
            namedVariables: namedVariables,
            indexedVariables: indexedVariables
        )
        requestVariablePage(
            parentVariableID: nil,
            frameID: frameID,
            generation: generation,
            expandsParent: false
        )
    }

    public func toggleVariableExpansion(_ variable: DebugVariable) {
        guard variable.isExpandable else { return }
        if expandedVariableIDs.contains(variable.id) {
            expandedVariableIDs.remove(variable.id)
            return
        }
        if variableChildren[variable.id] != nil {
            expandedVariableIDs.insert(variable.id)
            return
        }
        guard !loadingVariableIDs.contains(variable.id), activeSession != nil else { return }
        loadingVariableIDs.insert(variable.id)
        variablePageStates[variable.id] = makeVariablePageState(
            reference: variable.variablesReference,
            namedVariables: variable.namedVariables,
            indexedVariables: variable.indexedVariables
        )
        requestVariablePage(
            parentVariableID: variable.id,
            frameID: selectedFrameID,
            generation: inspectionGeneration,
            expandsParent: true
        )
    }

    public func loadMoreVariables(parentVariableID: String?) {
        requestVariablePage(
            parentVariableID: parentVariableID,
            frameID: selectedFrameID,
            generation: inspectionGeneration,
            expandsParent: parentVariableID != nil
        )
    }

    public func isVariablePageLoading(parentVariableID: String?) -> Bool {
        loadingVariablePageIDs.contains(variablePageID(parentVariableID))
    }

    public func children(of variable: DebugVariable) -> [DebugVariable] {
        variableChildren[variable.id] ?? []
    }

    public func isVariableExpanded(_ variable: DebugVariable) -> Bool {
        expandedVariableIDs.contains(variable.id)
    }

    public func isVariableLoading(_ variable: DebugVariable) -> Bool {
        loadingVariableIDs.contains(variable.id)
    }

    public func setVariable(_ variable: DebugVariable, value: String) {
        guard state == .paused,
              capabilities.supportsSetVariable,
              let containerReference = variable.containerReference,
              let session = activeSession else { return }
        let frameID = selectedFrameID
        let generation = inspectionGeneration
        session.setVariable(
            variablesReference: containerReference,
            name: variable.name,
            value: value
        ) { [weak self] result in
            guard let self,
                  self.inspectionGeneration == generation,
                  self.selectedFrameID == frameID else { return }
            switch result {
            case .success(let replacement):
                let updated = DebugVariable(
                    id: variable.id,
                    name: variable.name,
                    value: replacement.value,
                    type: replacement.type ?? variable.type,
                    evaluateName: variable.evaluateName,
                    variablesReference: replacement.variablesReference,
                    containerReference: containerReference,
                    namedVariables: replacement.namedVariables,
                    indexedVariables: replacement.indexedVariables
                )
                self.replaceVariable(updated)
                self.refreshWatches()
            case .failure(let error):
                self.record(error)
            }
        }
    }

    public func addWatch(_ expression: String) {
        let expression = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty else { return }
        if !watches.contains(where: { $0.expression == expression }) {
            watches.append(GenericDebugWatch(
                expression: expression,
                value: nil,
                type: nil,
                error: nil
            ))
        }
        refreshWatches()
    }

    public func updateWatch(_ watch: GenericDebugWatch, expression: String) {
        let expression = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty else { return }
        watches.removeAll { $0.expression == watch.expression || $0.expression == expression }
        watches.append(GenericDebugWatch(expression: expression, value: nil, type: nil, error: nil))
        refreshWatches()
    }

    public func removeWatch(_ watch: GenericDebugWatch) {
        watches.removeAll { $0.expression == watch.expression }
        refreshWatches()
    }

    public func refreshWatches() {
        watchGeneration += 1
        let generation = watchGeneration
        let expressions = watches.map(\.expression)
        for expression in expressions {
            evaluateWatch(expression, generation: generation)
        }
    }

    public func evaluate(_ expression: String) {
        let value = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let session = activeSession else { return }
        recordConsoleExpression(value)
        session.evaluate(value, frameID: selectedFrameID) { [weak self] result in
            switch result {
            case .success(let variable):
                self?.append("\(value) = \(variable.value)\n")
            case .failure(let error): self?.record(error)
            }
        }
    }

    /// Returns the previous expression for the active session's console.
    public func previousConsoleExpression(current: String) -> String? {
        guard let activeSessionID else { return nil }
        let history = consoleHistoryBySession[activeSessionID] ?? []
        guard !history.isEmpty else { return nil }
        let cursor = consoleHistoryCursorBySession[activeSessionID] ?? history.count
        if cursor == history.count, !current.isEmpty {
            consoleHistoryDraftBySession[activeSessionID] = current
        }
        let next = max(0, cursor - 1)
        consoleHistoryCursorBySession[activeSessionID] = next
        return history[next]
    }

    /// Returns the next expression for the active session's console.
    public func nextConsoleExpression() -> String? {
        guard let activeSessionID else { return nil }
        let history = consoleHistoryBySession[activeSessionID] ?? []
        guard !history.isEmpty else { return nil }
        let cursor = consoleHistoryCursorBySession[activeSessionID] ?? history.count
        let next = min(history.count, cursor + 1)
        consoleHistoryCursorBySession[activeSessionID] = next
        if next < history.count { return history[next] }
        return consoleHistoryDraftBySession[activeSessionID] ?? ""
    }

    private func recordConsoleExpression(_ expression: String) {
        guard let activeSessionID else { return }
        var history = consoleHistoryBySession[activeSessionID] ?? []
        history.removeAll { $0 == expression }
        history.append(expression)
        if history.count > maximumConsoleHistoryEntries {
            history.removeFirst(history.count - maximumConsoleHistoryEntries)
        }
        consoleHistoryBySession[activeSessionID] = history
        consoleHistoryCursorBySession[activeSessionID] = history.count
        consoleHistoryDraftBySession[activeSessionID] = nil
        consoleHistory = history
    }

    private func publishConsoleHistory(for sessionID: DebugSessionID) {
        consoleHistory = consoleHistoryBySession[sessionID] ?? []
        consoleHistoryCursorBySession[sessionID] = consoleHistory.count
        consoleHistoryDraftBySession[sessionID] = nil
    }

    public func evaluateForHover(
        _ expression: String,
        completion: @escaping (DebugVariable?) -> Void
    ) {
        let value = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              state == .paused,
              let session = activeSession else {
            completion(nil)
            return
        }
        let frameID = selectedFrameID
        session.evaluate(value, frameID: frameID) { [weak self] result in
            guard let self,
                  self.state == .paused,
                  self.selectedFrameID == frameID else {
                completion(nil)
                return
            }
            completion(try? result.get())
        }
    }

    public func clearOutput() {
        output = ""
        debuggeeOutputNormalizer.reset()
    }

    /// Mirrors output emitted by a debuggee running in the host terminal into
    /// the Debug Console. PTY control sequences are meaningful to the terminal
    /// emulator but would otherwise render as noise in the text console.
    public func appendDebuggeeOutput(_ rawOutput: String) {
        let normalized = debuggeeOutputNormalizer.normalize(rawOutput)
        guard !normalized.isEmpty else { return }
        append(normalized)
    }

    private func resetInspectionState() {
        stoppedReason = state == .paused ? stoppedReason : nil
        exceptionInfo = nil
        selectedThreadID = nil
        selectedFrameID = nil
        stoppedFrame = nil
        selectedFrame = nil
        threads = []
        stackFrames = []
        areFilteredStackFramesExpanded = false
        scopes = []
        resetVariableTree()
        invalidateWatchResults()
    }

    private func saveActiveSessionSnapshot() {
        guard let activeSessionID, let providerID else { return }
        sessionSnapshots[activeSessionID] = GenericDebugSessionSnapshot(
            providerID: providerID,
            targetTitle: targetTitle,
            state: state,
            output: output,
            errorMessage: errorMessage,
            stoppedReason: stoppedReason,
            exceptionInfo: exceptionInfo,
            capabilities: capabilities,
            activeFileURL: activeFileURL,
            lastStartRequest: lastStartRequest,
            normalizer: debuggeeOutputNormalizer
        )
    }

    private func restoreSessionSnapshot(
        _ sessionID: DebugSessionID,
        summary: DebugSessionSummary
    ) {
        guard let snapshot = sessionSnapshots[sessionID] else {
            providerID = summary.providerID
            targetTitle = summary.targetTitle
            state = summary.state
            output = ""
            errorMessage = nil
            stoppedReason = nil
            exceptionInfo = nil
            capabilities = .unknown
            activeFileURL = nil
            lastStartRequest = nil
            debuggeeOutputNormalizer.reset()
            return
        }
        providerID = snapshot.providerID
        targetTitle = snapshot.targetTitle
        state = snapshot.state
        output = snapshot.output
        errorMessage = snapshot.errorMessage
        stoppedReason = snapshot.stoppedReason
        exceptionInfo = snapshot.exceptionInfo
        capabilities = snapshot.capabilities
        activeFileURL = snapshot.activeFileURL
        lastStartRequest = snapshot.lastStartRequest
        debuggeeOutputNormalizer = snapshot.normalizer
    }

    private func updateInactiveSessionState(
        _ sessionID: DebugSessionID,
        providerID: String,
        state: DebugAdapterState
    ) {
        var snapshot = sessionSnapshots[sessionID] ?? GenericDebugSessionSnapshot(
            providerID: providerID,
            targetTitle: nil,
            state: state,
            output: "",
            errorMessage: nil,
            stoppedReason: nil,
            exceptionInfo: nil,
            capabilities: .unknown,
            activeFileURL: nil,
            lastStartRequest: nil,
            normalizer: GenericDebugOutputNormalizer()
        )
        snapshot.state = state
        sessionSnapshots[sessionID] = snapshot
    }

    private func consumeInactiveSessionEvent(
        _ sessionID: DebugSessionID,
        providerID: String,
        event: DebugAdapterEvent
    ) {
        var snapshot = sessionSnapshots[sessionID] ?? GenericDebugSessionSnapshot(
            providerID: providerID,
            targetTitle: nil,
            state: sessions.sessionSummaries.first(where: { $0.id == sessionID })?.state ?? .idle,
            output: "",
            errorMessage: nil,
            stoppedReason: nil,
            exceptionInfo: nil,
            capabilities: .unknown,
            activeFileURL: nil,
            lastStartRequest: nil,
            normalizer: GenericDebugOutputNormalizer()
        )
        switch event {
        case .initialized:
            break
        case .capabilities(let capabilities):
            snapshot.capabilities = capabilities
        case .output(_, let text):
            let normalized = snapshot.normalizer.normalize(text)
            append(normalized, to: &snapshot.output)
        case .stopped(let reason, _, let description):
            snapshot.state = .paused
            snapshot.stoppedReason = description ?? reason
            snapshot.exceptionInfo = nil
        case .continued:
            snapshot.state = .running
            snapshot.stoppedReason = nil
            snapshot.exceptionInfo = nil
        case .terminated(let exitCode):
            snapshot.state = .terminated
            snapshot.stoppedReason = nil
            snapshot.exceptionInfo = nil
            if let exitCode {
                append("Debug session exited with code \(exitCode).\n", to: &snapshot.output)
            }
        case .breakpoint:
            break
        }
        sessionSnapshots[sessionID] = snapshot
    }

    private var activeSession: (any DebugAdapterControllingSession)? {
        if let activeSessionID {
            return sessions.session(id: activeSessionID)
        }
        guard let providerID else { return nil }
        return sessions.session(providerID: providerID)
    }

    private func evaluateWatch(_ expression: String, generation: Int) {
        guard state == .paused, let session = activeSession else { return }
        let frameID = selectedFrameID
        session.evaluate(expression, frameID: frameID) { [weak self] result in
            guard let self,
                  self.watchGeneration == generation,
                  self.selectedFrameID == frameID,
                  let index = self.watches.firstIndex(where: { $0.expression == expression })
            else { return }
            switch result {
            case .success(let variable):
                self.watches[index].value = variable.value
                self.watches[index].type = variable.type
                self.watches[index].error = nil
            case .failure(let error):
                self.watches[index].value = nil
                self.watches[index].type = nil
                self.watches[index].error = error.localizedDescription
            }
        }
    }

    private func invalidateWatchResults() {
        watchGeneration += 1
        watches = watches.map {
            GenericDebugWatch(expression: $0.expression, value: nil, type: nil, error: nil)
        }
    }

    private func sessionsProviderID(for fileURL: URL) -> String? {
        sessions.provider(for: fileURL)?.id
    }

    private func consume(_ event: DebugAdapterEvent) {
        switch event {
        case .initialized:
            break
        case .capabilities(let capabilities):
            self.capabilities = capabilities
            reconcileExceptionBreakpoints(with: capabilities.exceptionBreakpointFilters)
            synchronizeExceptionBreakpoints()
        case .output(_, let text):
            append(text)
        case .stopped(let reason, let threadID, let description):
            let generation = beginInspectionTransition()
            stoppedReason = description ?? reason
            exceptionInfo = nil
            selectedThreadID = threadID
            selectedFrameID = nil
            selectedFrame = nil
            threads = []
            stackFrames = []
            areFilteredStackFramesExpanded = false
            scopes = []
            resetVariableTree()
            invalidateWatchResults()
            if reason == "exception", let threadID {
                loadExceptionInfo(threadID: threadID, generation: generation)
            }
            loadStoppedContext(
                threadID: threadID,
                generation: generation,
                shouldLoadExceptionInfo: reason == "exception" && threadID == nil
            )
        case .continued:
            invalidateInspectionRequests()
            stoppedReason = nil
            exceptionInfo = nil
            selectedThreadID = nil
            selectedFrameID = nil
            stoppedFrame = nil
            selectedFrame = nil
            threads = []
            stackFrames = []
            areFilteredStackFramesExpanded = false
            scopes = []
            resetVariableTree()
            invalidateWatchResults()
        case .terminated(let exitCode):
            invalidateInspectionRequests()
            stoppedReason = nil
            exceptionInfo = nil
            selectedThreadID = nil
            selectedFrameID = nil
            stoppedFrame = nil
            selectedFrame = nil
            threads = []
            stackFrames = []
            areFilteredStackFramesExpanded = false
            scopes = []
            resetVariableTree()
            invalidateWatchResults()
            if let exitCode { append("Debug session exited with code \(exitCode).\n") }
        case .breakpoint(let resolved):
            if let dataID = resolved.dataID,
               let index = dataBreakpoints.firstIndex(where: { $0.dataID == dataID }) {
                dataBreakpoints[index].verified = resolved.verified
                dataBreakpoints[index].message = resolved.message
                return
            }
            if let functionName = resolved.functionName,
               let index = functionBreakpoints.firstIndex(where: { $0.name == functionName }) {
                functionBreakpoints[index].verified = resolved.verified
                functionBreakpoints[index].message = resolved.message
                return
            }
            guard let sourceURL = resolved.sourceURL, let line = resolved.line else { return }
            if let index = breakpoints.firstIndex(where: {
                $0.fileURL.standardizedFileURL == sourceURL.standardizedFileURL && $0.line == line
            }) {
                breakpoints[index].verified = resolved.verified
                breakpoints[index].message = resolved.message
            }
        }
    }

    private func loadStoppedContext(
        threadID: Int?,
        generation: Int,
        shouldLoadExceptionInfo: Bool
    ) {
        guard let session = activeSession else { return }
        session.requestThreads { [weak self] result in
            guard let self, self.inspectionGeneration == generation else { return }
            switch result {
            case .success(let threads):
                self.threads = threads
                let selectedThreadID = threadID.flatMap { stoppedID in
                    threads.first(where: { $0.id == stoppedID })?.id
                } ?? threads.first?.id ?? threadID
                self.selectedThreadID = selectedThreadID
                if let selectedThreadID {
                    if shouldLoadExceptionInfo {
                        self.loadExceptionInfo(
                            threadID: selectedThreadID,
                            generation: generation
                        )
                    }
                    self.loadStoppedStack(threadID: selectedThreadID, generation: generation)
                }
            case .failure(let error):
                self.record(error)
                if let threadID {
                    self.loadStoppedStack(threadID: threadID, generation: generation)
                }
            }
        }
    }

    private func loadStoppedStack(threadID: Int, generation: Int) {
        activeSession?.requestStackTrace(threadID: threadID) { [weak self] result in
            guard let self,
                  self.inspectionGeneration == generation,
                  self.selectedThreadID == threadID else { return }
            switch result {
            case .success(let frames):
                self.stackFrames = frames
                self.areFilteredStackFramesExpanded = false
                self.selectedFrameID = frames.first?.id
                if let frame = frames.first {
                    self.selectFrame(frame, generation: generation)
                } else {
                    self.selectedFrame = nil
                }
            case .failure(let error):
                self.record(error)
            }
        }
    }

    private func loadExceptionInfo(threadID: Int, generation: Int) {
        guard capabilities.supportsExceptionInfoRequest,
              let session = activeSession else { return }
        session.requestExceptionInfo(threadID: threadID) { [weak self] result in
            guard let self, self.inspectionGeneration == generation else { return }
            switch result {
            case .success(let info):
                self.exceptionInfo = info
            case .failure(let error):
                self.record(error)
            }
        }
    }

    private func beginInspectionTransition() -> Int {
        inspectionGeneration &+= 1
        activeSession?.cancelPendingOperations()
        return inspectionGeneration
    }

    private func loadJavaSteppingFilters() {
        guard let steppingFilterResolver else { return }
        let persisted: DebugSteppingFilters?
        do {
            persisted = try steppingFilterPersistence?.loadSteppingFilters(adapterID: "java")
        } catch {
            record(error)
            loadDefaultJavaSteppingFilters(using: steppingFilterResolver)
            return
        }
        do {
            javaSteppingFilters = try steppingFilterResolver.resolveDebugSteppingFilters(
                adapterID: "java",
                filters: persisted
            )
        } catch {
            record(error)
            if persisted != nil {
                loadDefaultJavaSteppingFilters(using: steppingFilterResolver)
            }
        }
    }

    private func loadDefaultJavaSteppingFilters(
        using steppingFilterResolver: any DebugSteppingFilterResolving
    ) {
        do {
            javaSteppingFilters = try steppingFilterResolver.resolveDebugSteppingFilters(
                adapterID: "java",
                filters: nil
            )
        } catch {
            record(error)
        }
    }

    private func stackFrameRow(_ frame: DebugStackFrame) -> GenericDebugStackFrameRow {
        GenericDebugStackFrameRow(
            id: "frame-\(frame.id)",
            frame: frame,
            hiddenFrameCount: 0
        )
    }

    private func appendHiddenStackFrames(
        count: Int,
        startID: Int?,
        to rows: inout [GenericDebugStackFrameRow]
    ) {
        guard count > 0, let startID else { return }
        rows.append(GenericDebugStackFrameRow(
            id: "filtered-\(startID)",
            frame: nil,
            hiddenFrameCount: count
        ))
    }

    private func invalidateInspectionRequests() {
        _ = beginInspectionTransition()
    }

    private func publishStoppedLocation(_ frame: DebugStackFrame) {
        stoppedFrame = frame
        guard let sourceURL = frame.sourceURL else { return }
        onStoppedLocation?(sourceURL, frame.line, frame.column)
    }

    private func reconcileBreakpoints() {
        let previous = Dictionary(uniqueKeysWithValues: breakpoints.map { ($0.id, $0) })
        breakpoints = requestedBreakpointsByFile
            .flatMap { fileURL, values in
                values.values.map { configuration in
                    let id = fileURL.standardizedFileURL.path + ":"
                        + String(configuration.line) + ":" + String(configuration.column ?? 0)
                    return GenericDebugBreakpoint(
                        fileURL: fileURL,
                        line: configuration.line,
                        column: configuration.column,
                        enabled: configuration.enabled,
                        condition: configuration.condition,
                        hitCondition: configuration.hitCondition,
                        logMessage: configuration.logMessage,
                        verified: previous[id]?.verified ?? false,
                        message: previous[id]?.message
                    )
                }
            }
            .sorted {
                if $0.fileURL.path == $1.fileURL.path { return $0.line < $1.line }
                return $0.fileURL.path < $1.fileURL.path
            }
    }

    private func persistBreakpoints() {
        guard let breakpointPersistence, let workspaceURL else { return }
        let values = breakpoints.compactMap { breakpoint -> PersistedDebugBreakpoint? in
            guard let relativePath = workspaceRelativePath(
                for: breakpoint.fileURL,
                root: workspaceURL
            ) else { return nil }
            return PersistedDebugBreakpoint(
                relativePath: relativePath,
                line: breakpoint.line,
                column: breakpoint.column,
                enabled: breakpoint.enabled,
                condition: breakpoint.condition,
                hitCondition: breakpoint.hitCondition,
                logMessage: breakpoint.logMessage
            )
        }.sorted {
            ($0.relativePath, $0.line, $0.column ?? 0)
                < ($1.relativePath, $1.line, $1.column ?? 0)
        }
        do {
            try breakpointPersistence.saveBreakpoints(
                DebugBreakpointSnapshot(
                    areBreakpointsMuted: areBreakpointsMuted,
                    breakpoints: values
                ),
                for: workspaceURL
            )
        } catch {
            record(error)
        }
    }

    private func workspaceRelativePath(for fileURL: URL, root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return nil }
        let value = String(filePath.dropFirst(rootPath.count + 1))
        guard !value.isEmpty else { return nil }
        return value.replacingOccurrences(of: "\\", with: "/")
    }

    private func restoredFileURL(for relativePath: String, root: URL) -> URL? {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\") else { return nil }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        let value = components.reduce(root) { partial, component in
            partial.appendingPathComponent(String(component), isDirectory: false)
        }.standardizedFileURL
        guard value.path.hasPrefix(root.path + "/") else { return nil }
        return value
    }

    private func effectiveBreakpoints(for fileURL: URL) -> [DebugSourceBreakpoint] {
        (requestedBreakpointsByFile[fileURL]?.values ?? [:].values)
            .map { breakpoint in
                DebugSourceBreakpoint(
                    line: breakpoint.line,
                    column: breakpoint.column,
                    enabled: breakpoint.enabled && !areBreakpointsMuted,
                    condition: breakpoint.condition,
                    hitCondition: breakpoint.hitCondition,
                    logMessage: breakpoint.logMessage
                )
            }
            .sorted {
                ($0.line, $0.column ?? 0) < ($1.line, $1.column ?? 0)
            }
    }

    private func synchronizeBreakpoints(for fileURL: URL) {
        do {
            try sessions.setBreakpoints(effectiveBreakpoints(for: fileURL), in: fileURL)
        } catch {
            record(error)
        }
    }

    private func reconcileExceptionBreakpoints(
        with filters: [DebugExceptionBreakpointFilter]
    ) {
        let previous = Dictionary(uniqueKeysWithValues: exceptionBreakpoints.map { ($0.filter, $0) })
        exceptionBreakpoints = filters.map { filter in
            let existing = previous[filter.filter]
            return GenericDebugExceptionBreakpoint(
                filter: filter.filter,
                label: filter.label,
                description: filter.description,
                enabled: existing?.enabled ?? filter.isDefault,
                condition: filter.supportsCondition ? existing?.condition : nil,
                supportsCondition: filter.supportsCondition,
                conditionDescription: filter.conditionDescription
            )
        }
    }

    private func synchronizeExceptionBreakpoints() {
        guard let activeFileURL else { return }
        do {
            try sessions.setExceptionBreakpoints(
                exceptionBreakpoints.map {
                    DebugExceptionBreakpoint(
                        filter: $0.filter,
                        enabled: $0.enabled,
                        condition: $0.condition
                    )
                },
                for: activeFileURL
            )
        } catch {
            record(error)
        }
    }

    private func synchronizeFunctionBreakpoints() {
        guard let activeFileURL else { return }
        do {
            try sessions.setFunctionBreakpoints(
                functionBreakpoints.map {
                    DebugFunctionBreakpoint(
                        name: $0.name,
                        enabled: $0.enabled,
                        condition: $0.condition,
                        hitCondition: $0.hitCondition
                    )
                },
                for: activeFileURL
            )
        } catch {
            record(error)
        }
    }

    private var coreDataBreakpoints: [DebugDataBreakpoint] {
        dataBreakpoints.map {
            DebugDataBreakpoint(
                dataID: $0.dataID,
                label: $0.label,
                enabled: $0.enabled,
                accessType: $0.accessType,
                condition: $0.condition,
                hitCondition: $0.hitCondition
            )
        }
    }

    private func synchronizeDataBreakpoints() {
        guard let activeFileURL else { return }
        do {
            try sessions.setDataBreakpoints(coreDataBreakpoints, for: activeFileURL)
        } catch {
            record(error)
        }
    }

    private func sortDataBreakpoints() {
        dataBreakpoints.sort { ($0.label, $0.id) < ($1.label, $1.id) }
    }

    private func makeVariablePageState(
        reference: Int,
        namedVariables: Int,
        indexedVariables: Int
    ) -> GenericDebugVariablePageState {
        var segments: [GenericDebugVariablePageSegment] = []
        if namedVariables > 0 {
            segments.append(GenericDebugVariablePageSegment(
                filter: .named,
                nextStart: 0,
                totalCount: namedVariables
            ))
        }
        if indexedVariables > 0 {
            segments.append(GenericDebugVariablePageSegment(
                filter: .indexed,
                nextStart: 0,
                totalCount: indexedVariables
            ))
        }
        if segments.isEmpty {
            segments.append(GenericDebugVariablePageSegment(
                filter: nil,
                nextStart: 0,
                totalCount: nil
            ))
        }
        return GenericDebugVariablePageState(
            reference: reference,
            segments: segments,
            loadedPageFingerprints: []
        )
    }

    private func requestVariablePage(
        parentVariableID: String?,
        frameID: Int?,
        generation: Int,
        expandsParent: Bool
    ) {
        let pageID = variablePageID(parentVariableID)
        guard !loadingVariablePageIDs.contains(pageID),
              let state = variablePageStates[pageID],
              let segment = state.segments.first,
              let session = activeSession else { return }
        let remaining = segment.totalCount.map { max(0, $0 - segment.nextStart) }
        let requestedCount = min(variablePageSize, remaining ?? variablePageSize)
        guard requestedCount > 0 else { return }
        loadingVariablePageIDs.insert(pageID)
        session.requestVariables(
            reference: state.reference,
            filter: segment.filter,
            start: segment.nextStart,
            count: requestedCount
        ) { [weak self] result in
            guard let self,
                  self.inspectionGeneration == generation,
                  self.selectedFrameID == frameID else { return }
            self.loadingVariablePageIDs.remove(pageID)
            if let parentVariableID {
                self.loadingVariableIDs.remove(parentVariableID)
            }
            switch result {
            case .success(let values):
                self.mergeVariablePage(
                    values,
                    parentVariableID: parentVariableID,
                    requestedFilter: segment.filter,
                    requestedStart: segment.nextStart,
                    requestedCount: requestedCount
                )
                if expandsParent, let parentVariableID {
                    self.expandedVariableIDs.insert(parentVariableID)
                }
            case .failure(let error):
                self.record(error)
            }
        }
    }

    private func mergeVariablePage(
        _ page: [DebugVariable],
        parentVariableID: String?,
        requestedFilter: DebugVariableFilter?,
        requestedStart: Int,
        requestedCount: Int
    ) {
        let pageID = variablePageID(parentVariableID)
        guard var state = variablePageStates[pageID],
              let currentSegment = state.segments.first,
              currentSegment.filter == requestedFilter,
              currentSegment.nextStart == requestedStart else { return }

        let pageFingerprint = page.map {
            GenericDebugVariablePageItemFingerprint(
                name: $0.name,
                value: $0.value,
                type: $0.type,
                evaluateName: $0.evaluateName,
                variablesReference: $0.variablesReference
            )
        }
        if !page.isEmpty, !state.loadedPageFingerprints.insert(pageFingerprint).inserted {
            variablePageStates.removeValue(forKey: pageID)
            return
        }

        let existing = parentVariableID.map { variableChildren[$0] ?? [] } ?? variables
        var knownIDs = Set(existing.map(\.id))
        let additions = page.filter { knownIDs.insert($0.id).inserted }
        if let parentVariableID {
            variableChildren[parentVariableID] = existing + additions
        } else {
            variables = existing + additions
        }

        if page.count > requestedCount || (!page.isEmpty && additions.isEmpty) {
            state.segments = []
        } else {
            var segment = state.segments.removeFirst()
            segment.nextStart = requestedStart + page.count
            let reachedReportedTotal = segment.totalCount.map {
                segment.nextStart >= $0
            } ?? false
            let shouldContinue = !page.isEmpty
                && !reachedReportedTotal
                && (segment.totalCount != nil || page.count == requestedCount)
            if shouldContinue {
                state.segments.insert(segment, at: 0)
            }
        }
        if state.segments.isEmpty {
            variablePageStates.removeValue(forKey: pageID)
        } else {
            variablePageStates[pageID] = state
        }
    }

    private func variablePageID(_ parentVariableID: String?) -> String {
        parentVariableID ?? Self.rootVariablePageID
    }

    private func resetVariableTree() {
        variables = []
        variableChildren = [:]
        expandedVariableIDs = []
        loadingVariableIDs = []
        variablePageStates = [:]
        loadingVariablePageIDs = []
    }

    private func replaceVariable(_ replacement: DebugVariable) {
        if let index = variables.firstIndex(where: { $0.id == replacement.id }) {
            variables[index] = replacement
            return
        }
        for parentID in variableChildren.keys.sorted() {
            guard var children = variableChildren[parentID],
                  let index = children.firstIndex(where: { $0.id == replacement.id }) else {
                continue
            }
            children[index] = replacement
            variableChildren[parentID] = children
            return
        }
    }

    private func appendVisibleVariables(
        _ values: [DebugVariable],
        parentPath: String,
        depth: Int,
        to rows: inout [GenericDebugVariableRow]
    ) {
        for (index, variable) in values.enumerated() {
            let path = "\(parentPath)/\(index):\(variable.id)"
            rows.append(GenericDebugVariableRow(
                id: path,
                content: .variable(variable),
                depth: depth
            ))
            if expandedVariableIDs.contains(variable.id) {
                appendVisibleVariables(
                    variableChildren[variable.id] ?? [],
                    parentPath: path,
                    depth: depth + 1,
                    to: &rows
                )
                appendVariableLoadMoreRow(
                    parentVariableID: variable.id,
                    parentPath: path,
                    depth: depth + 1,
                    to: &rows
                )
            }
        }
    }

    private func appendVariableLoadMoreRow(
        parentVariableID: String?,
        parentPath: String,
        depth: Int,
        to rows: inout [GenericDebugVariableRow]
    ) {
        let pageID = variablePageID(parentVariableID)
        guard let pageState = variablePageStates[pageID],
              !pageState.segments.isEmpty else { return }
        rows.append(GenericDebugVariableRow(
            id: "\(parentPath)/load-more",
            content: .loadMore(
                parentVariableID: parentVariableID,
                nextCount: min(variablePageSize, pageState.remainingCount ?? variablePageSize),
                remainingCount: pageState.remainingCount
            ),
            depth: depth
        ))
    }

    private func normalizedOptionalText(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
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
        saveActiveSessionSnapshot()
    }

    private func append(_ text: String, to output: inout String) {
        output += text
        if output.count > maximumOutputCharacters {
            output.removeFirst(output.count - maximumOutputCharacters)
        }
    }
}
