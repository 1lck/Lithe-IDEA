import Foundation
import LitheGitModule

// Note: .agents/notes/implemented/architecture/2026-10-20-modular-application-logging.md
/// Owns one process's bounded queue. All log data is user-owned and remains outside
/// the signed bundle; module paths are fixed allowlisted names, never caller input.
final class MacApplicationLogWriter: ApplicationLogging, @unchecked Sendable {
    static let fileName = "lithe.log" // Read-only compatibility with older releases.
    static let categories = ["application", "language", "run", "git", "plugins", "performance"]
    private static let managedFilePattern = try! NSRegularExpression(
        pattern: #"^lithe\.[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}\.[0-9]{3}Z\.[a-f0-9]{32}\.[0-9]{20}\.log\z"#)
    private let queue = DispatchQueue(label: "dev.lithe.application-logs", qos: .utility)
    private let lock = NSLock()
    private let core = RustCoreBridge()
    private let defaultDirectory: URL
    private let now: @Sendable () -> Date
    private let diagnosticNow: @Sendable () -> TimeInterval
    private let onDirectoryFallback: @Sendable () -> Void
    private let fileLimit: Int
    private let totalLimit: Int
    private let sessionID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private var directory: URL?
    private var pending = 0
    private var controls = 0
    private var dropped = 0
    private var failures = 0
    // Remaining state belongs exclusively to queue.
    private var sequence: UInt64 = 0
    private var diagnosticUntil: TimeInterval = 0
    private var diagnosticCategory: String?
    private var activePaths: [String: URL] = [:]
    private var lastMaintenance = Date.distantPast
    private var lastEventKey: String?
    private var lastEventScope = "application"
    private var lastEventLevel = "info"
    private var firstEventTime = Date.distantPast
    private var lastEventTime = Date.distantPast
    private var repeatedEvents = 0
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(
        defaultDirectory: URL = MacLogDirectoryProvider().defaultLogDirectory,
        fileLimit: Int = 10 * 1024 * 1024,
        totalLimit: Int = 100 * 1024 * 1024,
        onDirectoryFallback: @escaping @Sendable () -> Void = {},
        diagnosticNow: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaultDirectory = defaultDirectory
        self.fileLimit = fileLimit
        self.totalLimit = totalLimit
        self.onDirectoryFallback = onDirectoryFallback
        self.now = now
        self.diagnosticNow = diagnosticNow
    }

    func redirect(to directory: URL) throws {
        // Probing is explicit; subsequent append failures can still trigger runtime fallback.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let probe = directory.appendingPathComponent(".lithe-probe-\(UUID().uuidString)")
        try Data().write(to: probe, options: [.withoutOverwriting])
        try FileManager.default.removeItem(at: probe)
        lock.withLock { self.directory = directory }
    }

    func redirectAsync(to directory: URL) async throws {
        try await perform { [self] in
            try flushRepeatedEvents()
            try redirect(to: directory)
            activePaths = [:]
        }
    }

    func changeDirectory(to directory: URL) async throws {
        try await redirectAsync(to: directory)
    }

    func record(level: String, scope: String, message: String, fields: [String: String] = [:]) {
        let accepted = lock.withLock { () -> Bool in
            // Reserve capacity for warnings/errors without ever writing on the caller.
            let capacity = ["warn", "error"].contains(level.lowercased()) ? 8000 : 6000
            guard pending < capacity else { dropped += 1; return false }
            pending += 1
            return true
        }
        guard accepted else { return }
        let timestamp = now()
        let boundedMessage = String(message.prefix(8192))
        let boundedFields = Dictionary(fields.sorted(by: { $0.key < $1.key }).prefix(24)
            .map { (String($0.key.prefix(80)), String($0.value.prefix(1024))) }, uniquingKeysWith: { first, _ in first })
        queue.async { [self] in
            defer { lock.withLock { pending -= 1 } }
            do { try write(level: level, scope: scope, message: boundedMessage, fields: boundedFields, timestamp: timestamp) }
            catch { lock.withLock { failures += 1 } }
        }
    }

    private func write(level: String, scope: String, message: String, fields: [String: String], timestamp: Date) throws {
        guard let event = core.prepareLogEvent(scope: scope, message: message, fields: fields) else {
            throw CocoaError(.coderInvalidValue)
        }
        if level == "debug" && (diagnosticNow() >= diagnosticUntil || (diagnosticCategory != nil && diagnosticCategory != event.category)) { return }
        let eventEncoder = JSONEncoder()
        eventEncoder.outputFormatting = [.sortedKeys]
        let eventKey = level + "|" + String(decoding: try eventEncoder.encode(event), as: UTF8.self)
        if lastEventKey == eventKey {
            repeatedEvents += 1
            lastEventTime = timestamp
            return
        }
        try flushRepeatedEvents()
        lastEventKey = eventKey
        lastEventScope = event.scope
        lastEventLevel = level
        firstEventTime = timestamp
        lastEventTime = timestamp
        sequence += 1
        let context = event.fields.sorted(by: { $0.key < $1.key }).map { key, value in
            let encoded = (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"<unavailable>\""
            return "\(key)=\(encoded)"
        }.joined(separator: " ")
        let line = "\(formatter.string(from: timestamp)) \(level.uppercased()) [session=\(sessionID)] [scope=\(event.scope)] [sequence=\(String(format: "%020llu", sequence))] \(event.message) schema_version=1 process_id=\(ProcessInfo.processInfo.processIdentifier) \(context)"
        var bytes = Array(line.utf8)
        if bytes.count > 4060 {
            bytes = Array(bytes.prefix(4060))
            while String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
            bytes += Array(" truncated=true".utf8)
        }
        bytes.append(10)
        guard let target = lock.withLock({ directory }) else { throw CocoaError(.fileNoSuchFile) }
        do { try writeData(Data(bytes), category: event.category, root: target, timestamp: timestamp) }
        catch {
            guard target != defaultDirectory else { throw error }
            try FileManager.default.createDirectory(at: defaultDirectory, withIntermediateDirectories: true)
            lock.withLock { directory = defaultDirectory; failures += 1 }
            onDirectoryFallback()
            activePaths = [:]
            try writeData(Data(bytes), category: event.category, root: defaultDirectory, timestamp: timestamp)
        }
    }

    private func flushRepeatedEvents() throws {
        guard repeatedEvents > 0 else { return }
        let count = repeatedEvents
        let scope = lastEventScope
        let level = lastEventLevel
        let first = firstEventTime
        let last = lastEventTime
        repeatedEvents = 0
        lastEventKey = nil
        try write(level: level == "debug" ? "info" : level, scope: scope, message: "last message repeated",
            fields: ["count": String(count), "first_timestamp": formatter.string(from: first),
                "last_timestamp": formatter.string(from: last)], timestamp: last)
    }

    private func writeData(_ data: Data, category: String, root: URL, timestamp: Date) throws {
        let folder = root.appendingPathComponent(category, isDirectory: true)
        guard (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let date = String(formatter.string(from: timestamp).prefix(10))
        var path = activePaths[category]
        let currentSize = path.map(fileSize) ?? 0
        if path?.deletingLastPathComponent() != folder || path?.lastPathComponent.contains(date) != true || currentSize + data.count > fileLimit {
            let stamp = formatter.string(from: timestamp).replacingOccurrences(of: ":", with: "-")
            path = folder.appendingPathComponent("lithe.\(stamp).\(sessionID).\(String(format: "%020llu", sequence)).log")
            activePaths[category] = path
            try maintain(root: root, timestamp: timestamp)
        } else if timestamp.timeIntervalSince(lastMaintenance) >= 60 {
            try maintain(root: root, timestamp: timestamp)
        }
        guard let path else { throw CocoaError(.fileNoSuchFile) }
        if !FileManager.default.fileExists(atPath: path.path) {
            guard FileManager.default.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        }
        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func managedFiles(root: URL) -> [URL] {
        let folders = ([root] + Self.categories.map { root.appendingPathComponent($0, isDirectory: true) }).filter {
            (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true
        }
        return folders.flatMap { folder in
            (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])) ?? []
        }.filter { url in
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return values?.isRegularFile == true && values?.isSymbolicLink != true &&
                (name == Self.fileName || Self.managedFilePattern.firstMatch(
                    in: name, range: NSRange(name.startIndex..., in: name)) != nil)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func fileSize(_ url: URL) -> Int {
        // URL resource values may cache the first observed size for an active
        // URL. Query filesystem attributes so rotation sees subsequent appends.
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    }

    private func maintain(root: URL, timestamp: Date) throws {
        lastMaintenance = timestamp
        let active = Set(activePaths.values)
        var files = managedFiles(root: root)
        for file in files where !active.contains(file) {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? timestamp
            if timestamp.timeIntervalSince(modified) >= 30 * 86400 { try FileManager.default.removeItem(at: file) }
        }
        files = managedFiles(root: root)
        var bytes = files.reduce(0) { $0 + fileSize($1) }
        var perfBytes = files.filter { $0.deletingLastPathComponent().lastPathComponent == "performance" }
            .reduce(0) { $0 + fileSize($1) }
        for file in files where !active.contains(file) {
            let performance = file.deletingLastPathComponent().lastPathComponent == "performance"
            guard bytes > totalLimit - fileLimit || (performance && perfBytes > 20 * 1024 * 1024 - fileLimit) else { continue }
            let size = fileSize(file)
            try FileManager.default.removeItem(at: file)
            bytes -= size
            if performance { perfBytes -= size }
        }
    }

    func configureDiagnostic(category: String?, enabled: Bool) async {
        do {
            try await perform { [self] in
                diagnosticCategory = Self.categories.contains(category ?? "") ? category : nil
                diagnosticUntil = enabled ? diagnosticNow() + 15 * 60 : 0
            }
        } catch { lock.withLock { failures += 1 } }
        record(level: "info", scope: "log.settings", message: enabled ? "diagnostic logging enabled for 15 minutes" : "diagnostic logging disabled")
    }

    func clear() async throws {
        try await perform { [self] in
            guard let root = lock.withLock({ directory }) else { throw CocoaError(.fileNoSuchFile) }
            for file in managedFiles(root: root) { try FileManager.default.removeItem(at: file) }
            activePaths = [:]
            repeatedEvents = 0
            lastEventKey = nil
        }
    }

    func collect(query: ApplicationLogQuery) async throws -> ApplicationLogCollection {
        try await perform { [self] in
            guard let root = lock.withLock({ directory }) else { throw CocoaError(.fileNoSuchFile) }
            try flushRepeatedEvents()
            let available = Array(managedFiles(root: root).reversed())
            let previousSession = available.compactMap { file -> String? in
                let parts = file.lastPathComponent.split(separator: ".")
                guard parts.count >= 5 else { return nil }
                let candidate = String(parts[parts.count - 3])
                return candidate != sessionID ? candidate : nil
            }.first
            let selectedSession: String? = query.session == "current" ? sessionID : query.session == "previous" ? (previousSession ?? "missing") : nil
            let eligible = available.filter { file in
                let category = Self.categories.contains(file.deletingLastPathComponent().lastPathComponent) ? file.deletingLastPathComponent().lastPathComponent : "application"
                return (query.category == nil || query.category == category) &&
                    (selectedSession == nil || file.lastPathComponent.contains(selectedSession!))
            }
            let candidates = eligible.prefix(200)
            var budget = 10 * 1024 * 1024
            var files: [ApplicationLogFile] = []
            var sources: [RustCoreBridge.LogSource] = []
            var truncated = eligible.count > candidates.count
            for file in candidates {
                let category = Self.categories.contains(file.deletingLastPathComponent().lastPathComponent) ? file.deletingLastPathComponent().lastPathComponent : "application"
                guard budget > 0 else { truncated = true; break }
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                let size = try handle.seekToEnd()
                let count = min(budget, 2 * 1024 * 1024)
                let offset = size > count ? size - UInt64(count) : 0
                try handle.seek(toOffset: offset)
                var data = try handle.read(upToCount: count) ?? Data()
                if offset > 0 { truncated = true; if let newline = data.firstIndex(of: 10) { data = data.suffix(from: data.index(after: newline)) } }
                budget -= data.count
                let text = String(decoding: data, as: UTF8.self)
                let source = RustCoreBridge.LogSource(category: category, text: text)
                guard let filtered = core.queryLogs(sources: [source], query: query, sessionID: selectedSession),
                      case .success(let redacted) = core.redactDiagnosticText(filtered.content) else { throw CocoaError(.coderInvalidValue) }
                truncated = truncated || filtered.truncated
                if !redacted.redacted.isEmpty {
                    files.append(ApplicationLogFile(relativePath: "logs/\(category)/\(file.lastPathComponent)", data: Data((redacted.redacted + "\n").utf8)))
                    sources.append(RustCoreBridge.LogSource(category: category, text: redacted.redacted))
                }
            }
            guard let timeline = core.queryLogs(sources: sources, query: query, sessionID: selectedSession) else { throw CocoaError(.coderInvalidValue) }
            let counts = lock.withLock { (dropped, failures) }
            let summary = "truncated=\(truncated || timeline.truncated) dropped_events=\(counts.0) write_failures=\(counts.1)\n"
            files.append(ApplicationLogFile(relativePath: "collection-status.txt", data: Data(summary.utf8)))
            return ApplicationLogCollection(files: files, content: timeline.content, truncated: truncated || timeline.truncated,
                effectiveDirectory: root, diagnosticEnabled: diagnosticNow() < diagnosticUntil,
                droppedEvents: counts.0, writeFailures: counts.1, diagnosticCategory: diagnosticCategory)
        }
    }

    func finishSession() async {
        record(level: "info", scope: "session", message: "session ended")
        do { try await perform(timeout: 2) {} }
        catch { lock.withLock { failures += 1 } }
    }

    private func perform<T: Sendable>(timeout seconds: Double = 10, _ body: @escaping @Sendable () throws -> T) async throws -> T {
        let accepted = lock.withLock { () -> Bool in
            guard controls < 4 else { return false }
            controls += 1
            return true
        }
        guard accepted else { throw CocoaError(.userCancelled) }
        return try await withCheckedThrowingContinuation { continuation in
            let completion = LogCompletion<T>(continuation)
            let timeout = DispatchWorkItem { completion.finish(.failure(CocoaError(.userCancelled))) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: timeout)
            queue.async { [self] in
                defer { timeout.cancel(); lock.withLock { controls -= 1 } }
                guard !completion.isFinished else { return }
                completion.finish(Result { try body() })
            }
        }
    }
}

private final class LogCompletion<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
    var isFinished: Bool { lock.withLock { continuation == nil } }
    func finish(_ result: Result<T, Error>) {
        let saved = lock.withLock { let saved = continuation; continuation = nil; return saved }
        saved?.resume(with: result)
    }
}

struct MacGitPerformanceLogger: GitPerformanceLogger, Sendable {
    private let writer: MacApplicationLogWriter
    init(writer: MacApplicationLogWriter) { self.writer = writer }
    func record(_ message: String) { writer.record(level: "debug", scope: "perf.git", message: message) }
}
