import Foundation

/// Probes lightweight command-line metadata outside the main actor. Results
/// are cached by `RunExecutableResolver`, so resolving or launching a run
/// configuration never shells out synchronously.
struct ProcessRunToolchainMetadataResolver: RunToolchainMetadataResolving {
    let processRunner: any ProcessRunner

    func metadata(for executableURL: URL, toolchainType: String) -> RunToolchainMetadata {
        let probeURLs: [URL]
        let arguments: [String]
        switch toolchainType {
        case "java", "maven":
            // Java and Maven use RuntimeLocator's richer vendor-aware probes.
            return RunToolchainMetadata(version: "", vendor: "")
        case "go":
            arguments = ["version"]
        case "python", "node", "rust":
            arguments = ["--version"]
        default:
            return RunToolchainMetadata(version: "", vendor: "")
        }
        if toolchainType == "rust" {
            probeURLs = [
                executableURL.deletingLastPathComponent().appendingPathComponent("rustc"),
                executableURL
            ]
        } else {
            probeURLs = [executableURL]
        }
        for probeURL in probeURLs {
            let result = processRunner.run(ProcessRequest(
                executablePath: probeURL.path,
                arguments: arguments,
                timeoutMilliseconds: 1_500
            ))
            guard result.succeeded,
                  let version = Self.firstVersion(in: result.output) else { continue }
            return RunToolchainMetadata(version: version, vendor: "")
        }
        return RunToolchainMetadata(version: "", vendor: "")
    }

    private static func firstVersion(in output: String) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern: #"[0-9]+(?:\.[0-9]+)+(?:[-+._][A-Za-z0-9]+)*"#
        ), let match = expression.firstMatch(
            in: output,
            range: NSRange(output.startIndex..<output.endIndex, in: output)
        ), let range = Range(match.range, in: output) else { return nil }
        return String(output[range])
    }
}
