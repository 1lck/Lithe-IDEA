import LitheGitModule
import Foundation
@preconcurrency import Dispatch
import LitheModuleAPI

/// Process-owned native I/O. The provider supplies the writable root; sessions
/// are runtime state, never bundle resources or reusable worktree artifacts.
final class MacLogStore: ApplicationLogging, LogSink, @unchecked Sendable {
    static let categories = ["application", "language", "run", "git", "plugins", "performance"]
    private let queue: DispatchQueue
    private let lock = NSLock()
    private let core = RustCoreBridge()
    private let defaultDirectory: URL
    private let now: @Sendable () -> Date
    private let diagnosticNow: @Sendable () -> TimeInterval
    private let onDirectoryFallback: @Sendable () -> Void
    private let fileLimit: Int
    private let totalLimit: Int
    private let capacity: Int
    private let reserved: Int
    private let handleLimit: Int
    private let batchSize = 256
    private let sessionID = UUID().uuidString.lowercased()
    private let started: Date
    // Ingress state: only this short critical section runs on callers.
    private var pending: [Pending] = []
    private var scheduled = false
    private var urgent = false
    private var dropped = 0
    private var unreportedDropped = 0
    private var failures = 0
    private var diagnosticUntil: TimeInterval = 0
    private var diagnosticCategory: String?
    private var stopped = false
    // Everything below is owned by the serial I/O queue.
    private var directory: URL?
    private var sequence: UInt64 = 0
    private var previousEvent: RustCoreBridge.LogInput?
    private var overflowPaths: [String]?
    private var sessionPath: String?
    private var channels: [String: [String]] = [:]
    private var headers: [String: String] = [:]
    private var controls = 0
    private var handles: [String: OpenLog] = [:]
    private var useCounter: UInt64 = 0
    private var lastMaintenance = Date.distantPast
    private var recent: [EncodedLogEntry] = []
    private var recentBytes = 0
    private var subscribers: [UUID: AsyncStream<[EncodedLogEntry]>.Continuation] = [:]
    private let formatter: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter()
        value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return value
    }()

    struct EncodedLogEntry: Sendable {
        let channel: String
        let line: String
    }
    private enum Pending: Sendable {
        case typed(any LogEvent, Date)
    }
    private struct OpenLog {
        let handle: FileHandle
        var size: Int
        var used: UInt64
    }

    init(
        directoryProvider: any LogDirectoryProviding = MacLogDirectoryProvider(),
        defaultDirectory: URL? = nil,
        fileLimit: Int = 10 * 1024 * 1024,
        totalLimit: Int = 100 * 1024 * 1024,
        capacity: Int = 8000, reserved: Int = 2000, handleLimit: Int = 32,
        queue: DispatchQueue = DispatchQueue(label: "dev.lithe.log-store", qos: .utility),
        onDirectoryFallback: @escaping @Sendable () -> Void = {},
        diagnosticNow: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaultDirectory = defaultDirectory ?? directoryProvider.defaultLogDirectory
        self.fileLimit = fileLimit; self.totalLimit = totalLimit
        self.capacity = max(1, capacity); self.reserved = min(max(0, reserved), max(0, capacity - 1))
        self.handleLimit = min(32, max(1, handleLimit)); self.queue = queue
        self.now = now; self.started = now(); self.diagnosticNow = diagnosticNow
        self.onDirectoryFallback = onDirectoryFallback
    }

    deinit {
        for value in handles.values { try? value.handle.close() }
        for value in subscribers.values { value.finish() }
    }

    func emit(_ event: any LogEvent) {
        enqueue(level: type(of: event).level.rawValue, category: event.channel.root.rawValue) {
            .typed(event, now())
        }
    }

    private func enqueue(level: String, category: String, make: () -> Pending) {
        let action = lock.withLock { () -> Int in
            guard !stopped else { return 0 }
            if level == "debug" && (diagnosticNow() >= diagnosticUntil ||
                (diagnosticCategory != nil && Self.channelCategory(category) != diagnosticCategory)) { return 0 }
            let limit = level == "warn" || level == "error" ? capacity : capacity - reserved
            guard pending.count < limit else { dropped += 1; unreportedDropped += 1; return 0 }
            pending.append(make())
            if pending.count >= batchSize && !urgent { urgent = true; scheduled = true; return 2 }
            if !scheduled { scheduled = true; return 1 }
            return 0
        }
        if action == 2 { queue.async { [weak self] in self?.drainSafely() } }
        if action == 1 {
            // One-shot only while work exists; no idle polling timer.
            queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in self?.drainSafely() }
        }
    }

    private static func channelCategory(_ channel: String) -> String {
        switch channel { case "app": return "application"; case "lsp", "editor": return "language"
        case "vcs": return "git"; case "perf": return "performance"; case "debug": return "run"
        default: return channel }
    }

    func redirect(to directory: URL) throws {
        // Startup-only synchronous adapter. Runtime callers use changeDirectory.
        try queue.sync {
            if self.directory != nil { try drain(token: LogOperation()) }
            try switchDirectory(directory)
        }
    }
    private func switchDirectory(_ target: URL) throws {
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let probe = target.appendingPathComponent(".lithe-probe-\(UUID().uuidString)")
        try Data().write(to: probe, options: .withoutOverwriting)
        try FileManager.default.removeItem(at: probe)
        closeHandles()
        directory = target
        previousEvent = nil
        lastMaintenance = .distantPast
    }
    func redirectAsync(to directory: URL) async throws { try await changeDirectory(to: directory) }
    func changeDirectory(to target: URL) async throws {
        try await perform { [self] token in
            try drain(token: token)
            try token.check()
            try switchDirectory(target)
        }
    }

    private func input(_ pending: Pending) -> RustCoreBridge.LogInput {
        sequence += 1
        switch pending {
        case .typed(let event, let timestamp):
            var fields: [String: RustCoreBridge.LogScalar] = [:]
            for (key, value) in event.fields {
                switch value {
                case .int(let v): fields[key] = .int(v)
                case .bool(let v): fields[key] = .bool(v)
                case .bytes(let v): fields[key] = .uint(v)
                case .duration(let v):
                    let parts = max(.zero, v).components
                    let seconds = UInt64(clamping: parts.seconds)
                    let ms = seconds.multipliedReportingOverflow(by: 1000)
                    fields[key + "_ms"] = .uint(ms.overflow ? UInt64.max : ms.partialValue.addingReportingOverflow(UInt64(max(0, parts.attoseconds / 1_000_000_000_000_000))).partialValue)
                case .id(let v): fields[key] = .string(v.rawValue)
                case .token(let v), .version(let v), .text(let v): fields[key] = .string(v)
                case .path(let v): fields[key] = .string(v.path)
                case .error(let v):
                    if let failure = v as? LitheModuleAPI.LogFailure {
                        fields[key] = .string("")
                        fields[key + "_code"] = .string(failure.code)
                        fields[key + "_domain"] = .string(failure.domain)
                    } else {
                        let error = v as NSError
                        fields[key] = .string(error.localizedDescription)
                        fields[key + "_code"] = .int(Int64(error.code))
                        fields[key + "_domain"] = .string(error.domain)
                    }
                }
            }
            return .init(ts: formatter.string(from: timestamp), level: type(of: event).level.rawValue.uppercased(),
                seq: sequence, event: type(of: event).id, op: event.operationID, msg: "", fields: fields,
                channel: event.channel.rawValue)
        }
    }

    private func drainSafely() {
        do { try drain(token: LogOperation()) }
        catch { lock.withLock { failures += 1 } }
    }
    private func drain(token control: LogOperation) throws {
        try control.check()
        // Accepted persistence is process-owned. A control lease may stop its
        // query/switch afterward, but cannot abandon the detached ingress snapshot.
        let token = LogOperation()
        let work = lock.withLock { () -> ([Pending], Int) in
            let values = pending; pending.removeAll(keepingCapacity: true)
            let count = unreportedDropped; unreportedDropped = 0
            scheduled = false; urgent = false
            return (values, count)
        }
        var batch: [RustCoreBridge.LogInput] = []
        for value in work.0 {
            try token.check()
            batch.append(input(value))
            if batch.count >= batchSize { try persist(batch, token: token); batch.removeAll(keepingCapacity: true) }
        }
        if work.1 > 0 {
            sequence += 1
            batch.append(.init(ts: formatter.string(from: now()), level: "WARN", seq: sequence,
                event: "log.dropped", msg: "Dropped events", fields: ["count": .int(Int64(work.1))], channel: "app"))
        }
        if !batch.isEmpty { try persist(batch, token: token) }
        if let root = directory, now().timeIntervalSince(lastMaintenance) >= 60 { try maintain(root, token: token) }
        for value in handles.values { try token.check(); try value.handle.synchronize() }
        try control.check()
    }

    private func persist(_ batch: [RustCoreBridge.LogInput], token: LogOperation) throws {
        let encoded = try core.encodeLogs(.init(events: batch, previousEvent: previousEvent))
        try token.check()
        previousEvent = batch.last
        var published: [EncodedLogEntry] = []
        for result in encoded.results {
            try token.check()
            guard let line = result.line, let channel = result.channel else {
                lock.withLock { failures += 1 }; continue
            }
            let entry = EncodedLogEntry(channel: channel, line: line)
            do { try append(entry, token: token) }
            catch {
                try token.check()
                lock.withLock { failures += 1 }
                guard directory != defaultDirectory else { continue }
                try switchDirectory(defaultDirectory)
                onDirectoryFallback()
                do { try append(entry, token: token) }
                catch { lock.withLock { failures += 1 } }
            }
            published.append(entry)
        }
        try token.check()
        recent.append(contentsOf: published)
        recentBytes += published.reduce(0) { $0 + $1.line.utf8.count }
        while recent.count > 2000 || recentBytes > 2 * 1024 * 1024 {
            recentBytes -= recent.removeFirst().line.utf8.count
        }
        for subscriber in subscribers.values { subscriber.yield(published) }
    }

    private func header(_ channel: String) throws -> String {
        if let cached = headers[channel] { return cached }
        let result = try core.encodeLogs(.init(events: [], headers: [.init(session: sessionID,
            pid: UInt32(ProcessInfo.processInfo.processIdentifier), app: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0",
            channel: channel, started: formatter.string(from: started))]))
        guard let line = result.headers.first?.line, let path = result.sessionPath else { throw CocoaError(.coderInvalidValue) }
        sessionPath = path
        let text = line + "\n"
        if headers.count < 129 { headers[channel] = text }
        return text
    }
    private func safeURL(root: URL, relative: String) throws -> URL {
        var result = root
        for part in relative.split(separator: "/") {
            guard part != ".", part != ".." else { throw CocoaError(.fileWriteNoPermission) }
            result.appendPathComponent(String(part))
            if (try? result.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                throw CocoaError(.fileWriteNoPermission)
            }
        }
        return result
    }
    private func append(_ entry: EncodedLogEntry, token: LogOperation) throws {
        if directory == nil { try switchDirectory(defaultDirectory) }
        guard let root = directory else { throw CocoaError(.fileNoSuchFile) }
        var paths = channels[entry.channel] ?? (channels.count >= 128 ? overflowPaths : nil)
        if paths == nil {
            let existing = Array(channels.keys)
            paths = try (0...2).map { try core.resolveLogChannel(entry.channel, rotation: $0, existing: existing) }
            // Cache only admitted identities; overflow identities must not grow memory forever.
            if paths?.first != "_overflow.log" { channels[entry.channel] = paths }
            else { overflowPaths = paths }
        }
        guard let paths else { throw CocoaError(.coderInvalidValue) }
        let headerText = try header(paths[0].hasPrefix("_overflow") ? "app" : entry.channel)
        guard let sessionPath else { throw CocoaError(.coderInvalidValue) }
        let relative = sessionPath + "/" + paths[0]
        let target = try safeURL(root: root, relative: relative)
        let data = Data((entry.line + "\n").utf8)
        try token.check()
        if let opened = handles[relative], opened.size + data.count > fileLimit { try rotate(root, sessionPath, paths, relative) }
        if handles[relative] == nil {
            let size = fileSize(target)
            if size > 0 && size + data.count > fileLimit { try rotate(root, sessionPath, paths, relative) }
            if handles.count >= handleLimit, let oldest = handles.min(by: { $0.value.used < $1.value.used }) {
                try oldest.value.handle.close(); handles.removeValue(forKey: oldest.key)
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: target.path) {
                guard FileManager.default.createFile(atPath: target.path, contents: Data(headerText.utf8), attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            }
            let handle = try FileHandle(forWritingTo: target)
            let openedSize = try handle.seekToEnd()
            handles[relative] = OpenLog(handle: handle, size: Int(openedSize), used: useCounter)
        }
        try token.check()
        guard var opened = handles[relative] else { throw CocoaError(.fileWriteUnknown) }
        try opened.handle.write(contentsOf: data)
        useCounter += 1; opened.used = useCounter; opened.size += data.count; handles[relative] = opened
    }
    private func rotate(_ root: URL, _ session: String, _ paths: [String], _ key: String) throws {
        if let value = handles.removeValue(forKey: key) { try value.handle.close() }
        let urls = try paths.map { try safeURL(root: root, relative: session + "/" + $0) }
        // Overflow also needs distinct physical segments although Core routes all overflow indices to one sink.
        guard Set(urls).count == 3 else { throw CocoaError(.fileWriteOutOfSpace) }
        if FileManager.default.fileExists(atPath: urls[2].path) { try FileManager.default.removeItem(at: urls[2]) }
        for i in stride(from: 1, through: 0, by: -1) where FileManager.default.fileExists(atPath: urls[i].path) {
            try FileManager.default.moveItem(at: urls[i], to: urls[i + 1])
        }
    }
    private func closeHandles() {
        for value in handles.values { do { try value.handle.close() } catch { lock.withLock { failures += 1 } } }
        handles.removeAll()
    }
    private func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    }

    private struct DiskFile {
        let url: URL
        let relative: String
        let session: String?
        let category: String
    }
    private func inventory(_ root: URL, token: LogOperation) throws -> [DiskFile] {
        var result: [DiskFile] = []
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return [] }
        let legacyPattern = #"^lithe\.[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}\.[0-9]{3}Z\.[a-f0-9]{32}\.[0-9]{20}\.log$"#
        for case let url as URL in enumerator {
            try token.check()
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
            let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolvedPath.hasPrefix(resolvedRoot + "/") else { continue }
            let relative = String(resolvedPath.dropFirst(resolvedRoot.count + 1))
            let parts = relative.split(separator: "/").map(String.init)
            if values.isDirectory == true {
                if parts.count == 1 && parts[0] != "sessions" && !Self.categories.contains(parts[0]) { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            if parts.count >= 3 && parts[0] == "sessions" {
                guard parts[1].range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}_[a-f0-9]{8}$"#, options: .regularExpression) != nil else { continue }
                // Core validates session names and source paths before using this inventory.
                let channelRoot = parts[2].split(whereSeparator: { $0 == "." || $0 == "~" }).first.map(String.init) ?? "app"
                result.append(DiskFile(url: url, relative: relative, session: parts[1], category: Self.channelCategory(channelRoot)))
            } else if parts.count <= 2 && (url.lastPathComponent == "lithe.log" || url.lastPathComponent.range(of: legacyPattern, options: .regularExpression) != nil) {
                result.append(DiskFile(url: url, relative: parts.count == 1 ? "application/" + relative : relative,
                    session: nil, category: parts.count == 1 ? "application" : parts[0]))
            }
        }
        return result.sorted { $0.relative > $1.relative }
    }
    private func maintain(_ root: URL, token: LogOperation) throws {
        let files = try inventory(root, token: token)
        var sessions: [String: [RustCoreBridge.LogRetentionFile]] = [:]
        var legacy: [RustCoreBridge.LogRetentionFile] = []
        for file in files {
            let modified = try file.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? now()
            let relative = file.session.map { String(file.relative.dropFirst("sessions/\($0)/".count)) } ?? file.relative
            let value = RustCoreBridge.LogRetentionFile(relativePath: relative, sizeBytes: fileSize(file.url), modifiedAt: formatter.string(from: modified))
            if let session = file.session { sessions[session, default: []].append(value) }
            else { legacy.append(value) }
        }
        if sessionPath == nil { _ = try header("app") }
        let plan = try core.planLogRetention(.init(sessions: sessions.map { .init(name: $0.key, files: $0.value) },
            legacyFiles: legacy, currentSession: sessionPath?.split(separator: "/").last.map(String.init) ?? "",
            now: formatter.string(from: now()), limits: .init(totalBytes: totalLimit), startupCleanup: lastMaintenance == .distantPast))
        for deletion in plan.deletions {
            try token.check()
            // A root-level v1 file has a virtual category for Core queries only.
            let original = files.first { $0.relative == deletion.relativePath }?.url
            do { try FileManager.default.removeItem(at: original ?? safeURL(root: root, relative: deletion.relativePath)) }
            catch { lock.withLock { failures += 1 } }
        }
        try token.check()
        lastMaintenance = now()
    }

    func configureDiagnostic(category: String?, enabled: Bool) async {
        lock.withLock {
            diagnosticCategory = Self.categories.contains(category ?? "") ? category : nil
            diagnosticUntil = enabled ? diagnosticNow() + 900 : 0
        }
    }
    func clear() async throws {
        try await perform { [self] token in
            try drain(token: token)
            guard let root = directory else { return }
            closeHandles()
            for file in try inventory(root, token: token) {
                try token.check()
                try FileManager.default.removeItem(at: file.url)
            }
            try token.check()
            recent.removeAll(); recentBytes = 0; previousEvent = nil
        }
    }
    func collect(query: ApplicationLogQuery) async throws -> ApplicationLogCollection {
        try await perform { [self] token in
            try drain(token: token)
            if directory == nil { try switchDirectory(defaultDirectory) }
            guard let root = directory else { throw CocoaError(.fileNoSuchFile) }
            let available = try inventory(root, token: token)
            let current = sessionPath?.split(separator: "/").last.map(String.init)
            let previous = available.compactMap(\.session).first { $0 != current }
            let eligible = available.filter { file in
                guard file.session != nil, file.url.pathExtension == "log", !file.relative.contains("/files/"),
                    query.category == nil || query.category == file.category else { return false }
                if query.session == "current" { return file.session == current && current != nil }
                if query.session == "previous" {
                    return previous != nil && file.session == previous
                }
                return true
            }
            var budget = 10 * 1024 * 1024
            var sources: [RustCoreBridge.LogSourceV2] = []
            var truncated = eligible.count > 200
            for file in eligible.prefix(200) {
                try token.check()
                guard budget > 0 else { truncated = true; break }
                let handle = try FileHandle(forReadingFrom: file.url)
                defer { try? handle.close() }
                let size = try handle.seekToEnd()
                let count = min(budget, 2 * 1024 * 1024)
                let offset = size > count ? size - UInt64(count) : 0
                try handle.seek(toOffset: offset)
                let data = try handle.read(upToCount: count) ?? Data()
                budget -= data.count
                sources.append(.init(relativePath: file.relative, text: String(decoding: data, as: UTF8.self), startsMidLine: offset > 0))
                truncated = truncated || offset > 0
            }
            let result = try core.queryLogsV2(.init(sources: sources, channelPrefixes: [],
                minimumLevel: query.minimumLevel?.uppercased(), since: query.since, until: query.until, search: query.search))
            try token.check()
            // Core returns redacted, canonical lines so exports never serialize raw input.
            let grouped = Dictionary(grouping: result.records, by: \.relativePath)
            var files = grouped.keys.sorted().map { path in
                ApplicationLogFile(relativePath: "logs/" + path, data: Data((grouped[path]!.map(\.line).joined(separator: "\n") + "\n").utf8))
            }
            let state = lock.withLock { (dropped, failures, diagnosticNow() < diagnosticUntil, diagnosticCategory) }
            truncated = truncated || result.truncated || result.skippedInvalidLines > 0
            let status = "truncated=\(truncated) dropped_events=\(state.0) write_failures=\(state.1) skipped_invalid_lines=\(result.skippedInvalidLines)\n"
            files.append(.init(relativePath: "collection-status.txt", data: Data(status.utf8)))
            return ApplicationLogCollection(files: files, content: result.records.map(\.line).joined(separator: "\n"),
                truncated: truncated, effectiveDirectory: root, diagnosticEnabled: state.2,
                droppedEvents: state.0, writeFailures: state.1, diagnosticCategory: state.3)
        }
    }

    func flush(timeout: TimeInterval = 10) async throws {
        try await perform(timeout: timeout) { [self] token in try drain(token: token) }
    }
    func finishSession() async {
        lock.withLock { stopped = true }
        // Termination bypasses the four-control admission limit and task cancellation.
        // Cleanup always runs on the I/O owner, including when draining fails.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                defer {
                    closeHandles()
                    for subscriber in subscribers.values { subscriber.finish() }
                    subscribers.removeAll()
                    continuation.resume()
                }
                do { try drain(token: LogOperation()) }
                catch { lock.withLock { failures += 1 } }
            }
        }
    }
    func subscribe() async throws -> AsyncStream<[EncodedLogEntry]> {
        try await perform { [self] token in
            try token.check()
            let id = UUID()
            let pair = AsyncStream<[EncodedLogEntry]>.makeStream(bufferingPolicy: .bufferingNewest(8))
            pair.continuation.onTermination = { [weak self] _ in
                self?.queue.async { [weak self] in self?.subscribers.removeValue(forKey: id) }
            }
            guard !lock.withLock({ stopped }), subscribers.count < 16 else { pair.continuation.finish(); return pair.stream }
            subscribers[id] = pair.continuation
            if !recent.isEmpty { pair.continuation.yield(recent) }
            return pair.stream
        }
    }

    private func perform<T: Sendable>(timeout: TimeInterval = 10,
        _ body: @escaping @Sendable (LogOperation) throws -> T) async throws -> T {
        let accepted = lock.withLock { () -> Bool in
            guard controls < 4 else { return false }
            controls += 1; return true
        }
        guard accepted else { throw CocoaError(.userCancelled) }
        defer { lock.withLock { controls -= 1 } }
        let token = LogOperation(deadline: diagnosticNow() + timeout, now: diagnosticNow)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    // Expired controls never start. Running work checks its lease after
                    // Core calls and before each I/O/state publication. Completion occurs
                    // only once the worker has stopped, never while it still mutates state.
                    continuation.resume(with: Result { try token.check(); return try body(token) })
                }
            }
        } onCancel: { token.cancel() }
    }
}

private final class LogOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let deadline: TimeInterval
    private let now: @Sendable () -> TimeInterval
    init(deadline: TimeInterval = .infinity, now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.deadline = deadline; self.now = now
    }
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws {
        if lock.withLock({ cancelled }) || now() >= deadline { throw CocoaError(.userCancelled) }
    }
}

extension MacLogStore: GitPerformanceLogger {}

extension MacLogStore: PerformanceMarkerWriting {
    func writePerformanceMarker(_ marker: String) { FileHandle.standardOutput.write(Data(marker.utf8)) }
}
