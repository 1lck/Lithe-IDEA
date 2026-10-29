import AppKit
import Foundation
import LitheModuleAPI
import LitheTerminalModule
import SwiftTerm

/// Reuses the native terminal renderer while its PTY lives on the workspace
/// host. No local process or local login environment is used for this surface.
@MainActor
final class MacRemoteTerminalTransport: TerminalTransport {
    private let renderer: MacTerminalTransport
    private let binding: RemoteWorkspaceBinding
    private let transport: any RemoteTerminalConnecting
    private var delegate: RemoteTerminalViewDelegate?
    private var run: Task<Void, Never>?
    private var controls: Task<Void, Never>?
    private var launch: CheckedContinuation<Void, Error>?
    private var terminalID: UInt64?
    private var generation = UUID()
    private var queuedInputBytes = 0
    private var pendingSize: (columns: UInt16, rows: UInt16)?
    private var resizeQueued = false
    private static let maximumQueuedInputBytes = 1024 * 1024

    private(set) var isRunning = false
    private(set) var processID: Int32?
    var shellName: String { "Shell" }
    var nativeView: AnyObject { renderer.nativeView }
    var termProgramVersion: String? { renderer.termProgramVersion }
    var reportsLightBackground: Bool? { renderer.reportsLightBackground }
    var requiresAsyncStart: Bool { true }
    var onTermination: ((Int32?) -> Void)?
    var onOutput: ((Data) -> Void)?
    var onTitle: ((String) -> Void)?
    var onDirectoryUpdate: ((String?) -> Void)?
    var onLink: ((String, [String: String]) -> Void)?

    init(renderer: MacTerminalTransport, binding: RemoteWorkspaceBinding, transport: any RemoteTerminalConnecting) {
        self.renderer = renderer
        self.binding = binding
        self.transport = transport
        let delegate = RemoteTerminalViewDelegate(view: renderer.view)
        self.delegate = delegate
        renderer.view.terminalDelegate = delegate
        delegate.onInput = { [weak self] data in try? self?.send(data) }
        delegate.onResize = { [weak self] columns, rows in self?.resize(columns: columns, rows: rows) }
        renderer.onOutput = { [weak self] data in self?.onOutput?(data) }
        renderer.onTitle = { [weak self] title in self?.onTitle?(title) }
        renderer.onDirectoryUpdate = { [weak self] directory in
            guard let self, let directory else { return }
            let path = URL(string: directory).flatMap { $0.isFileURL ? $0.path : nil } ?? directory
            onDirectoryUpdate?(localPath(forRemotePath: path) ?? binding.root.path)
        }
        renderer.onLink = { [weak self] link, params in
            guard let self else { return }
            onLink?(localPath(forRemotePath: link) ?? link, params)
        }
    }

    func configureInitialSurface(showsWorkbenchBackground: Bool) {
        renderer.configureInitialSurface(showsWorkbenchBackground: showsWorkbenchBackground)
    }

    func defaultShellPath() -> String { "Shell" }
    func defaultEnvironment() -> [String: String] { [:] }

    func start(workingDirectory: String, shellPath: String, environment: [String: String]) throws {
        throw RemoteTerminalFailure.asyncStartRequired
    }

    func startShell(workingDirectory: String, shellPath: String, environment: [String: String]) async throws {
        let size = renderer.view.getWindowSize()
        let request = RemoteTerminalRequest(
            argv: shellPath == defaultShellPath() ? nil : [shellPath] + MacTerminalShellDiscovery.startupArguments(for: shellPath),
            cwd: try remoteDirectory(workingDirectory, allowsHostPath: false),
            env: environment, columns: max(1, size.ws_col), rows: max(1, size.ws_row)
        )
        try await start(request)
    }

    func startProcessAsync(_ launch: TerminalProcessLaunch, environment: [String: String]) async throws -> Int32 {
        let size = renderer.view.getWindowSize()
        let request = RemoteTerminalRequest(
            argv: [remotePath(forLocalPath: launch.executablePath)] + launch.arguments,
            cwd: try remoteDirectory(launch.workingDirectory, allowsHostPath: true),
            env: environment, columns: max(1, size.ws_col), rows: max(1, size.ws_row)
        )
        try await start(request)
        guard let processID else { throw RemoteTerminalFailure.closedBeforeStart }
        return processID
    }

    private func start(_ request: RemoteTerminalRequest) async throws {
        let previousRun = run
        let previousControls = controls
        stop()
        let stoppedGeneration = generation
        await previousRun?.value
        await previousControls?.value
        // Closing this tab while its predecessor cleans up must not start a
        // replacement process after the close has already returned.
        guard generation == stoppedGeneration else { throw CancellationError() }
        try Task.checkCancellation()
        let generation = UUID()
        self.generation = generation
        let transport = transport
        let session = binding.sessionID
        renderer.clear()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                launch = continuation
                run = Task { [weak self] in
                    let result = await transport.runTerminal(request, session: session) { [weak self] event in
                        // The C observer runs on the adapter's blocking worker.
                        // Waiting for the renderer bounds buffered output and
                        // propagates backpressure through SSH to the remote PTY.
                        if Thread.isMainThread {
                            MainActor.assumeIsolated { self?.receive(event, generation: generation) }
                        } else {
                            DispatchQueue.main.sync {
                                MainActor.assumeIsolated { self?.receive(event, generation: generation) }
                            }
                        }
                    }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == generation else { return }
                        if let launch = self.launch {
                            self.launch = nil
                            switch result {
                            case .success: launch.resume(throwing: RemoteTerminalFailure.closedBeforeStart)
                            case .failure(let failure): launch.resume(throwing: failure)
                            }
                        }
                        // A failed connection may end without terminal.exit.
                        // Release the same identity and controls as an explicit stop.
                        let wasRunning = self.isRunning
                        self.stop()
                        if wasRunning { self.onTermination?(nil) }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                stop()
            }
        }
    }

    private func receive(_ event: RemoteTerminalEvent, generation: UUID) {
        guard self.generation == generation else { return }
        switch event {
        case .started(let id, let pid):
            terminalID = id
            processID = pid
            isRunning = true
            renderer.view.hasRemoteProcess = true
            let continuation = launch
            launch = nil
            continuation?.resume()
            let size = renderer.view.getWindowSize()
            resize(columns: Int(size.ws_col), rows: Int(size.ws_row))
        case .output(let data): renderer.view.dataReceived(slice: Array(data)[...])
        case .exited(let code):
            guard isRunning else { return }
            isRunning = false
            processID = nil
            terminalID = nil
            pendingSize = nil
            controls?.cancel()
            renderer.view.hasRemoteProcess = false
            onTermination?(code)
        }
    }

    func startProcess(_ launch: TerminalProcessLaunch, environment: [String: String]) throws -> Int32 {
        throw RemoteTerminalFailure.asyncStartRequired
    }

    func send(_ input: Data) throws {
        guard !input.isEmpty, isRunning, let id = terminalID else { return }
        guard queuedInputBytes + input.count <= Self.maximumQueuedInputBytes else {
            throw RemoteTerminalFailure.inputBusy
        }
        queuedInputBytes += input.count
        let transport = transport
        let session = binding.sessionID
        enqueue(inputBytes: input.count) {
            try await transport.writeTerminal(input, id: id, session: session)
        }
    }

    private func resize(columns: Int, rows: Int) {
        guard isRunning else { return }
        pendingSize = (UInt16(clamping: max(1, columns)), UInt16(clamping: max(1, rows)))
        guard !resizeQueued else { return }
        resizeQueued = true
        let transport = transport
        let session = binding.sessionID
        let generation = generation
        enqueue { [weak self] in
            guard let self else { return }
            defer { if self.generation == generation { resizeQueued = false } }
            while self.generation == generation, let size = pendingSize, let id = terminalID {
                pendingSize = nil
                try await transport.resizeTerminal(id: id, columns: size.columns, rows: size.rows, session: session)
            }
        }
    }

    private func enqueue(inputBytes: Int = 0, _ operation: @escaping @MainActor () async throws -> Void) {
        let previous = controls
        let generation = generation
        controls = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, self?.generation == generation else { return }
            defer {
                if self?.generation == generation { self?.queuedInputBytes -= inputBytes }
            }
            do { try await operation() }
            catch {
                guard let self, self.generation == generation else { return }
                let wasRunning = isRunning
                stop()
                if wasRunning { onTermination?(nil) }
            }
        }
    }

    func interrupt() throws { try send(Data([0x03])) }
    func focus() { renderer.focus() }
    func clear() { renderer.clear() }
    func stop() {
        generation = UUID()
        isRunning = false
        processID = nil
        terminalID = nil
        queuedInputBytes = 0
        pendingSize = nil
        resizeQueued = false
        renderer.view.hasRemoteProcess = false
        run?.cancel()
        controls?.cancel()
        let continuation = launch
        launch = nil
        continuation?.resume(throwing: CancellationError())
    }

    func stopAndWait() async {
        let run = run
        let controls = controls
        stop()
        await run?.value
        await controls?.value
    }

    private func localPath(forRemotePath path: String) -> String? {
        let root = binding.remoteRoot == "/" ? "" : binding.remoteRoot
        guard path == root || path.hasPrefix(root + "/") else { return nil }
        return binding.root.path + String(path.dropFirst(root.count))
    }

    private func remotePath(forLocalPath path: String) -> String {
        let root = binding.root.standardizedFileURL.path
        guard path == root || path.hasPrefix(root + "/") else { return path }
        let remote = binding.remoteRoot == "/" ? "" : binding.remoteRoot
        let mapped = remote + path.dropFirst(root.count)
        return mapped.isEmpty ? "/" : mapped
    }

    private func remoteDirectory(_ path: String, allowsHostPath: Bool) throws -> String {
        let normalized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        let root = binding.root.standardizedFileURL.path
        guard path.hasPrefix("/"), allowsHostPath || normalized == root || normalized.hasPrefix(root + "/") else {
            throw RemoteTerminalFailure.invalidDirectory
        }
        return remotePath(forLocalPath: normalized)
    }

    deinit { run?.cancel(); controls?.cancel() }
}

/// SwiftTerm's local delegate ignores size changes without a local child.
/// Forward rendering/clipboard behavior to it and route only PTY IO remotely.
@MainActor
private final class RemoteTerminalViewDelegate: @preconcurrency TerminalViewDelegate {
    private weak var view: LitheTerminalView?
    var onInput: ((Data) -> Void)?
    var onResize: ((Int, Int) -> Void)?
    init(view: LitheTerminalView) { self.view = view }
    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) { onResize?(newCols, newRows) }
    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) { onInput?(Data(data)) }
    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) { view?.setTerminalTitle(source: source, title: title) }
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) { view?.hostCurrentDirectoryUpdate(source: source, directory: directory) }
    func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) { view?.requestOpenLink(source: source, link: link, params: params) }
    func scrolled(source: SwiftTerm.TerminalView, position: Double) { view?.scrolled(source: source, position: position) }
    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) { view?.rangeChanged(source: source, startY: startY, endY: endY) }
    func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) { view?.clipboardCopy(source: source, content: content) }
    func clipboardRead(source: SwiftTerm.TerminalView) -> Data? { view?.clipboardRead(source: source) }
}

private enum RemoteTerminalFailure: LocalizedError {
    case asyncStartRequired, invalidDirectory, closedBeforeStart, inputBusy
    var errorDescription: String? {
        switch self {
        case .asyncStartRequired: L10n.string("The remote terminal must be started asynchronously.")
        case .invalidDirectory: L10n.string("The terminal directory is outside the remote workspace.")
        case .closedBeforeStart: L10n.string("The remote terminal closed before it started.")
        case .inputBusy: L10n.string("The remote terminal is busy. Wait before sending more input.")
        }
    }
}
