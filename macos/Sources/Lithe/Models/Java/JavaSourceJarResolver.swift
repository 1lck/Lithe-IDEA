import Foundation

/// Reads a library class's source from a local `-sources.jar` for `jdt://` documents.
///
/// JDT LS answers `java.decompile` only after a process round trip, and the first
/// decompile of a framework class can take seconds. A sources jar that Maven or
/// Gradle already downloaded holds the real source, so navigation can open it with
/// a file read. Nothing is written to disk: sources jars stay in the caches the
/// build tools own, and lookups are kept in memory for the session.
enum JavaSourceJarResolver {
    /// Returns the source text for `jdt://contents/<jar>/<package>/<Type>.class`, or nil
    /// when the URI is not a jar class or no sources jar is available locally.
    static func sourceText(for uri: URL) async -> String? {
        guard let target = SourceTarget(uri: uri) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let sourcesJar = JavaSourceJarResolver.sourcesJar(forJarNamed: target.jarName) else { return nil }
            return JavaSourceJarResolver.text(of: target.sourceEntry, in: sourcesJar)
        }.value
    }

    /// Where a `jdt://` class points inside its library jar.
    struct SourceTarget: Equatable {
        let jarName: String
        /// Path of the top-level source file inside the sources jar, for example
        /// `org/springframework/jdbc/core/JdbcTemplate.java`. Inner classes such as
        /// `Map$Entry` resolve to their top-level file.
        let sourceEntry: String

        init?(uri: URL) {
            guard uri.scheme == "jdt", uri.host == "contents" else { return nil }
            let parts = uri.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard parts.count == 3, parts[0].hasSuffix(".jar"), parts[2].hasSuffix(".class") else { return nil }
            let className = String(parts[2].dropLast(".class".count))
            let topLevelName = className.split(separator: "$", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            guard !topLevelName.isEmpty else { return nil }
            jarName = parts[0]
            sourceEntry = parts[1].replacingOccurrences(of: ".", with: "/") + "/" + topLevelName + ".java"
        }
    }

    private static let cacheLock = NSLock()
    /// Sources jar lookups by jar name. A nil value records that none was found, so
    /// repeated navigation to the same library does not scan the caches again.
    nonisolated(unsafe) private static var sourcesJarCache: [String: URL?] = [:]

    private static func sourcesJar(forJarNamed jarName: String) -> URL? {
        cacheLock.lock()
        let cached = sourcesJarCache[jarName]
        cacheLock.unlock()
        if let cached { return cached }

        let sourcesName = String(jarName.dropLast(".jar".count)) + "-sources.jar"
        let found = findFile(named: sourcesName, under: searchRoots())

        cacheLock.lock()
        sourcesJarCache[jarName] = found
        cacheLock.unlock()
        return found
    }

    /// Maven and Gradle keep downloaded sources under their own caches.
    private static func searchRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".m2/repository", isDirectory: true),
            home.appendingPathComponent(".gradle/caches/modules-2/files-2.1", isDirectory: true)
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func findFile(named name: String, under roots: [URL]) -> URL? {
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator where url.lastPathComponent == name {
                return url
            }
        }
        return nil
    }

    /// Extracts one entry with the system `unzip`, which reads the zip directory and
    /// avoids linking a zip library into the app.
    private static func text(of entry: String, in jar: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", jar.path, entry]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // Read before waiting so a large source file cannot fill the pipe and stall.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
