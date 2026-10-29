import Foundation

/// Process-local cache owned by the native runtime adapter. In-flight probes
/// share one result; failed probes are retried on the next request.
final class MacRuntimeProbeCache: @unchecked Sendable {
    struct Key: Hashable {
        let executablePath: String
        let identity: String
    }

    private final class Flight {
        let generation: UInt64
        var completed = false
        var result: String?
        init(generation: UInt64) { self.generation = generation }
    }

    private let condition = NSCondition()
    private var generation: UInt64 = 0
    private var values: [Key: String] = [:]
    private var flights: [Key: Flight] = [:]
    // Native process probes have a five-second deadline plus termination grace.
    private static let waitTimeout: TimeInterval = 8

    func invalidate() {
        condition.lock()
        generation &+= 1
        values.removeAll()
        condition.unlock()
    }

    func value(for key: Key, probe: () -> String?) -> String? {
        condition.lock()
        if let value = values[key] {
            condition.unlock()
            return value
        }
        if let flight = flights[key], flight.generation == generation {
            let deadline = Date().addingTimeInterval(Self.waitTimeout)
            while !flight.completed {
                guard condition.wait(until: deadline) else {
                    condition.unlock()
                    return nil
                }
            }
            let result = flight.result
            condition.unlock()
            return result
        }
        let flight = Flight(generation: generation)
        flights[key] = flight
        condition.unlock()
        let result = probe()
        condition.lock()
        flight.result = result
        flight.completed = true
        if flight.generation == generation, let result {
            // Keep only the current file identity for each tool path.
            values = values.filter { $0.key.executablePath != key.executablePath }
            values[key] = result
        }
        if flights[key] === flight { flights.removeValue(forKey: key) }
        condition.broadcast()
        condition.unlock()
        return result
    }

    /// Variables that change which JDK or Maven distribution a probe runs.
    static let environmentIdentityKeys = [
        "JAVA_HOME", "PATH", "MAVEN_HOME", "M2_HOME", "MAVEN_OPTS", "MAVEN_ARGS", "JDK_JAVA_OPTIONS"
    ]

    /// Resolve aliases before fingerprinting. No state is written beside a tool
    /// or into the installed bundle; identities are read-only filesystem metadata.
    static func key(executable: URL, dependencies: [URL] = [], environment: [String: String]? = nil) -> Key {
        let canonical = executable.resolvingSymlinksInPath().standardizedFileURL
        let identity = ([canonical] + dependencies).map { url in
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path)
            let fields: [FileAttributeKey] = [.systemNumber, .systemFileNumber, .size, .modificationDate]
            return resolved.path + fields.map { String(describing: attributes?[$0]) }.joined(separator: "|")
        }.joined(separator: "\n") + environmentIdentity(environment)
        return Key(executablePath: canonical.path, identity: identity)
    }

    private static func environmentIdentity(_ environment: [String: String]?) -> String {
        guard let environment else { return "" }
        return "\nenv:" + environmentIdentityKeys.map { key in
            key + "=" + (environment[key].map { "\"" + $0 + "\"" } ?? "-")
        }.joined(separator: "\u{0}")
    }
}

/// Holds the login shell environment and `/usr/bin/java`'s default JDK that
/// background discovery read, keyed by the process environment it read them
/// for, so synchronous selection can reuse them without starting processes.
final class MacShellEnvironmentCache: @unchecked Sendable {
    private let lock = NSLock()
    private var source: [String: String]?
    private var shell: [String: String]?
    private var javaHome: String?

    func store(_ shellEnvironment: [String: String], for environment: [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        source = environment
        shell = shellEnvironment
    }

    func shellEnvironment(for environment: [String: String]) -> [String: String]? {
        lock.lock()
        defer { lock.unlock() }
        return source == environment ? shell : nil
    }

    func storeSystemJavaHome(_ path: String?) {
        lock.lock()
        defer { lock.unlock() }
        javaHome = path
    }

    func systemJavaHome() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return javaHome
    }
}
