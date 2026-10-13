import Darwin
import Foundation
import LitheCoreContracts
import LitheExecutionModule

/// macOS owns the temporary file while Rust Core owns Java argument-file
/// eligibility, option placement, and quoting.
extension RustCoreBridge: JavaLaunchArgumentPreparing {
    private struct Request: Encodable {
        let executable: String
        let arguments: [String]
        let argfilePath: String
        let limit: Int?
        let javaFeatureVersion: UInt32?
    }

    private struct Response: Decodable {
        let kind: String
        let arguments: [String]?
        let argfileContents: String?
    }

    func prepareJavaLaunch(
        executablePath: String,
        arguments: [String]
    ) throws -> JavaLaunchArgumentPreparation {
        let path = Self.nextArgumentFileURL()
        let response: Response = try executeResult(
            command: "execution.planLaunchCommand",
            payload: Request(
                executable: executablePath,
                arguments: arguments,
                argfilePath: path.path,
                limit: nil,
                javaFeatureVersion: Self.javaFeatureVersion(executablePath)
            )
        ).get()

        if response.kind == "direct" {
            return JavaLaunchArgumentPreparation(arguments: arguments)
        }
        guard response.kind == "argfile",
              let shortened = response.arguments,
              let contents = response.argfileContents else {
            throw JavaLaunchArgumentError.invalidPlan
        }
        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard let data = contents.data(using: .utf8) else {
                throw JavaLaunchArgumentError.invalidEncoding
            }
            try Self.writeExclusively(data, to: path)
        } catch {
            throw JavaLaunchArgumentError.writeFailed(path: path.path, reason: error.localizedDescription)
        }
        return JavaLaunchArgumentPreparation(
            arguments: shortened,
            lease: MacJavaLaunchArgumentLease(url: path)
        )
    }

    private static func nextArgumentFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-run", isDirectory: true)
            .appendingPathComponent("launch-\(UUID().uuidString).argfile")
    }

    private static func writeExclusively(_ data: Data, to url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))]
            )
        }
        do {
            try data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        bytes.count - offset
                    )
                    guard written > 0 else {
                        throw NSError(
                            domain: NSPOSIXErrorDomain,
                            code: written < 0 ? Int(errno) : Int(EIO),
                            userInfo: [
                                NSLocalizedDescriptionKey: written < 0
                                    ? String(cString: strerror(errno))
                                    : "The Java launch argument file write made no progress."
                            ]
                        )
                    }
                    offset += written
                }
            }
        } catch {
            _ = Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        _ = Darwin.close(descriptor)
    }

    static func javaFeatureVersion(_ executablePath: String) -> UInt32? {
        var directory = URL(fileURLWithPath: executablePath)
            .deletingLastPathComponent()
        for _ in 0..<6 {
            let release = directory.appendingPathComponent("release")
            if let contents = try? String(contentsOf: release, encoding: .utf8),
               let value = contents.split(separator: "\n")
                    .first(where: {
                        $0.trimmingCharacters(in: .whitespaces).hasPrefix("JAVA_VERSION=")
                    })?
                    .split(separator: "=", maxSplits: 1)
                    .last?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) {
                let parts = value.split { $0 == "." || $0 == "_" || $0 == "-" || $0 == "+" }
                guard let first = parts.first.flatMap({ UInt32($0) }) else { return nil }
                return first == 1 ? parts.dropFirst().first.flatMap { UInt32($0) } : first
            }
            let parent = directory.deletingLastPathComponent()
            guard parent != directory else { break }
            directory = parent
        }
        return nil
    }
}

private enum JavaLaunchArgumentError: LocalizedError {
    case invalidPlan
    case invalidEncoding
    case writeFailed(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidPlan:
            "Rust Core returned an incomplete Java argument-file plan."
        case .invalidEncoding:
            "The Java argument file could not be encoded as UTF-8."
        case .writeFailed(let path, let reason):
            "Could not write Java launch argument file at \(path): \(reason)"
        }
    }
}

private final class MacJavaLaunchArgumentLease: JavaLaunchArgumentLease, @unchecked Sendable {
    private let url: URL

    init(url: URL) {
        self.url = url
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
